import Foundation
import UIKit
import Observation

/// Central chat view model — manages messages, assets, and coordinates services.
@MainActor
@Observable
final class ChatViewModel {
    // MARK: - State
    
    var messages: [ChatMessage] = []
    var isLoadingHistory = false
    var currentAssetId: String?
    var showFormSheet = false
    var showMetadataSheet = false
    var formFields: [FormField] = []
    var uploadProgress: Double = 0
    var isUploading = false
    var lastClip: Clip?
    var lastAsset: Asset?
    
    // Staged video — preview before upload (iOS 26.3 flow)
    var stagedVideo: StagedVideo?
    var isProcessingVideo = false
    
    // Form context (passed to ContextFormView header)
    var formOriginalFileName: String?
    var formCapturedAt: String?
    var formClipCount: Int?
    var formDuration: Int?
    var formThumbnail: UIImage?
    var formSubmitError: String?
    
    /// Thumbnails + metadata for sent-upload cards keyed by message ID
    var sentUploadThumbnails: [String: UIImage] = [:]
    var sentUploadFileNames: [String: String] = [:]
    var sentUploadDates: [String: String] = [:]
    var sentUploadHasLocation: [String: Bool] = [:]
    
    /// Temp staging data preserved across confirmStagedUpload → createAsset
    private var lastStagedCreatedDate: String?
    private var lastStagedHasLocation: Bool = false
    
    // MARK: - Dependencies
    
    let auth: AuthService
    let ws: WebSocketService
    let uploader = VideoUploadService()
    
    init(auth: AuthService, ws: WebSocketService) {
        self.auth = auth
        self.ws = ws
        setupWebSocketHandlers()
        setupConnectionHandlers()
        checkPendingForm() // Check for form that was pending when app was killed
    }
    
    // MARK: - WebSocket Handlers
    
    private func setupWebSocketHandlers() {
        ws.onMessage = { [weak self] message in
            self?.messages.append(message)
        }
        
        ws.onUploadComplete = { [weak self] data in
            guard let self else { return }
            let assetId = data["assetId"] as? String ?? ""
            print("✅ Upload complete for asset: \(assetId)")
            
            // Fetch the full asset (with clips) so MetadataView can display it
            Task { @MainActor in
                await self.fetchAssetDetail(assetId: assetId)
            }
        }
        
        ws.onFormRequest = { [weak self] data in
            guard let self else { return }
            let assetId = data["assetId"] as? String
            self.currentAssetId = assetId
            
            // Store form context for ContextFormView header
            self.formOriginalFileName = data["originalFileName"] as? String
            self.formClipCount = data["clipCount"] as? Int
            self.formDuration = data["duration"] as? Int
            if let dateVal = data["capturedAt"] as? String {
                self.formCapturedAt = dateVal
            }
            
            self.formFields = self.buildFormFields()
            self.showFormSheet = true
            
            // Persist form state so it survives app kill
            if let assetId {
                PendingForm.save(PendingForm(
                    assetId: assetId,
                    originalFileName: self.formOriginalFileName,
                    capturedAt: self.formCapturedAt,
                    clipCount: self.formClipCount,
                    duration: self.formDuration,
                    thumbnailJPEG: self.formThumbnail?.jpegData(compressionQuality: 0.5),
                    savedAt: Date()
                ))
            }
        }
        
        ws.onFormConfirmed = { [weak self] data in
            guard let self else { return }
            let text = data["message"] as? String ?? "🙌 High Five! Form received."
            let mediasourceId = data["mediasourceId"] as? String
            let mediasourceUrl = data["mediasourceUrl"] as? String
            let originalFileName = data["originalFileName"] as? String
            let capturedAt = data["capturedAt"] as? String
            let formType = data["formType"] as? String
            let formDescription = data["formDescription"] as? String
            let formPriority = data["formPriority"] as? String
            
            let confirmation = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: data["assetId"] as? String,
                direction: .incoming,
                messageType: .confirmation,
                content: MessageContent(
                    text: text,
                    slug: nil,
                    mediasourceId: mediasourceId,
                    mediasourceUrl: mediasourceUrl,
                    originalFileName: originalFileName,
                    capturedAt: capturedAt,
                    formType: formType,
                    formDescription: formDescription,
                    formPriority: formPriority
                ),
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            self.messages.append(confirmation)
            
            // After 1 second, append a random fun follow-up message
            let firstName = self.auth.currentUser?.name.components(separatedBy: " ").first ?? "Friend"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                let phrases = [
                    "\(firstName), you are working hard today, but I am here when your next video is ready.",
                    "\(firstName), that upload was smoother than a dolly shot. Send another whenever you're ready.",
                    "\(firstName), another one in the can! I'll be here when the next masterpiece drops.",
                    "\(firstName), that's a wrap! Take five — or send five more videos, I don't judge.",
                    "\(firstName), you're on fire today 🔥 I'll keep the upload lane open for you.",
                    "\(firstName), video received and locked. I'm basically your cloud butler — at your service.",
                    "\(firstName), if uploads were Olympic events, you'd be on the podium right now 🥇",
                    "\(firstName), that one's safe with me. Go grab coffee — I'll hold down the fort.",
                    "\(firstName), filed and processed! You make this look easy. Ready when you are.",
                    "\(firstName), boom — done! I'll just be here, staring at the upload button, waiting for you."
                ]
                let message = phrases.randomElement()! + "\n\nRemember you can #Slack the clip from here."
                let followUp = ChatMessage(
                    id: UUID().uuidString,
                    userId: nil,
                    assetId: nil,
                    direction: .incoming,
                    messageType: .greeting,
                    content: MessageContent(text: message),
                    createdAt: ISO8601DateFormatter().string(from: Date())
                )
                self.messages.append(followUp)
            }
        }
        
    }
    
    // MARK: - Connection State Handlers
    
    private func setupConnectionHandlers() {
        ws.onReconnecting = { [weak self] attempt, maxAttempts in
            guard let self else { return }
            // Connection state is reflected in ChatHeaderView (Ready / Working / Trying to connect)
            // Report to server DB (best-effort — may fail if offline)
            Task {
                await self.reportError(
                    category: "websocket",
                    message: "WebSocket reconnecting (attempt \(attempt)/\(maxAttempts))",
                    severity: "WARNING"
                )
            }
        }
        
        ws.onConnectionLost = { [weak self] in
            guard let self else { return }
            // Connection state is reflected in ChatHeaderView (red dot + "Trying to connect...")
            Task {
                await self.reportError(
                    category: "websocket",
                    message: "WebSocket max reconnect attempts exhausted — connection lost",
                    severity: "CRITICAL"
                )
            }
        }
    }
    
    // MARK: - Error Helpers
    
    /// Show an error message to the user as a chat bubble.
    private func appendErrorBubble(_ text: String, assetId: String? = nil) {
        let errorMsg = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(text: text),
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        messages.append(errorMsg)
    }
    
    /// Report an error to the server's error_logs table (best-effort, fire-and-forget).
    /// Future: server will send text/email for CRITICAL errors.
    func reportError(
        category: String,
        message: String,
        severity: String = "WARNING",
        assetId: String? = nil,
        details: [String: String]? = nil
    ) async {
        guard auth.isAuthenticated else { return }
        var request = auth.authenticatedRequest(for: ServerConfig.errorsURL, method: "POST")
        var body: [String: Any] = [
            "source": "ios",
            "category": category,
            "message": message,
            "severity": severity,
        ]
        if let assetId { body["assetId"] = assetId }
        if let details { body["details"] = details }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        // Fire-and-forget — don't let logging failures cascade
        _ = try? await URLSession.shared.data(for: request)
    }
    
    // MARK: - Load History
    
    func loadMessageHistory() async {
        guard auth.isAuthenticated else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        
        let request = auth.authenticatedRequest(for: ServerConfig.messagesURL)
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(MessagesResponse.self, from: data)
            messages = response.messages
        } catch {
            print("❌ Failed to load messages:", error)
            appendErrorBubble("⚠️ Could not load message history.")
        }
    }
    
    // MARK: - Send Text Message
    
    func sendTextMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // Detect Slack commands: #channel or @user
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSlackCommand = trimmed.hasPrefix("#") || trimmed.hasPrefix("@")
        
        // Optimistic UI — add message locally
        let localMessage = ChatMessage(
            id: UUID().uuidString,
            userId: auth.currentUser?.id,
            assetId: nil,
            direction: .outgoing,
            messageType: isSlackCommand ? .slackPost : .text,
            content: MessageContent(text: text),
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        messages.append(localMessage)
        
        // Send via WebSocket
        ws.sendMessage(text: text)
    }
    
    // MARK: - Create Asset (Video Upload Flow)
    
    func createAsset(fileName: String, fileURL: URL) async -> Asset? {
        var request = auth.authenticatedRequest(for: ServerConfig.assetsURL, method: "POST")
        let body = CreateAssetRequest(fileName: fileName)
        request.httpBody = try? JSONEncoder().encode(body)
        
        // Get actual file size before notifying server
        let fileSize: Int64 = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            return attrs?[.size] as? Int64 ?? 0
        }()
        
        // Retry up to 2 times on transient network/decode failures
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let (data, httpResponse) = try await URLSession.shared.data(for: request)
                let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0
                
                guard statusCode >= 200, statusCode < 300 else {
                    let body = String(data: data, encoding: .utf8) ?? "(empty)"
                    print("❌ createAsset HTTP \(statusCode): \(body)")
                    lastError = NSError(domain: "createAsset", code: statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: "Server returned \(statusCode)"])
                    if statusCode >= 500 {
                        try? await Task.sleep(for: .seconds(Double(attempt)))
                        continue
                    }
                    break
                }
                
                let asset: Asset
                do {
                    let response = try JSONDecoder().decode(CreateAssetResponse.self, from: data)
                    asset = response.asset
                } catch {
                    let raw = String(data: data, encoding: .utf8) ?? "(non-utf8, \(data.count) bytes)"
                    print("❌ createAsset decode failed (attempt \(attempt)): \(error)\nRaw: \(raw)")
                    lastError = error
                    if attempt < 3 {
                        try? await Task.sleep(for: .seconds(Double(attempt)))
                        continue
                    }
                    break
                }
                
                currentAssetId = asset.id
            
                // Add outgoing video message locally — also cache thumbnail for SentUploadBubble
                let msgId = UUID().uuidString
                let videoMessage = ChatMessage(
                    id: msgId,
                    userId: auth.currentUser?.id,
                    assetId: asset.id,
                    direction: .outgoing,
                    messageType: .video,
                    content: MessageContent(text: "📹 \(fileName)", fileName: fileName),
                    createdAt: ISO8601DateFormatter().string(from: Date())
                )
                messages.append(videoMessage)
                
                // Cache thumbnail + metadata so SentUploadBubble can render the card
                if let thumb = formThumbnail {
                    sentUploadThumbnails[msgId] = thumb
                }
                sentUploadFileNames[msgId] = fileName
                sentUploadDates[msgId] = lastStagedCreatedDate ?? {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MMM d, yyyy h:mm a"
                    return formatter.string(from: Date())
                }()
                sentUploadHasLocation[msgId] = lastStagedHasLocation
                
                // Notify WebSocket with real file size
                ws.sendVideoUpload(
                    assetId: asset.id,
                    fileName: fileName,
                    fileSize: fileSize
                )
                
                return asset
            } catch {
                print("❌ createAsset attempt \(attempt) network error:", error)
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(Double(attempt)))
                    continue
                }
            }
        }
        
        // All attempts exhausted
        let errorDesc = lastError?.localizedDescription ?? "Unknown error"
        appendErrorBubble("⚠️ Could not start upload. Please try again.")
        Task {
            await reportError(
                category: "upload",
                message: "Asset creation failed after 3 attempts: \(errorDesc)",
                severity: "ERROR",
                details: ["fileName": fileName]
            )
        }
        return nil
    }
    
    // MARK: - Upload Video
    
    func uploadVideo(assetId: String, fileURL: URL, metadata: VideoMetadata? = nil) async {
        guard let token = auth.token else { return }
        isUploading = true
        uploadProgress = 0
        defer { isUploading = false }
        
        // Poll uploader progress on main actor
        let progressTask = Task { @MainActor in
            while self.uploader.isUploading {
                self.uploadProgress = self.uploader.uploadProgress
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.uploadProgress = self.uploader.uploadProgress
        }
        
        do {
            // Single path: Mux direct upload via background URLSession.
            // iOS handles network interruptions automatically (waitsForConnectivity).
            let muxResult = try await uploader.uploadViaMux(assetId: assetId, fileURL: fileURL, token: token, metadata: metadata)
            print("✅ [Upload] Mux direct upload completed for asset: \(assetId), clipId: \(muxResult.clipId)")
        } catch {
            print("❌ [Upload] Failed for asset \(assetId): \(error)")
            appendErrorBubble("⚠️ Upload failed: \(error.localizedDescription)", assetId: assetId)
            Task {
                await reportError(
                    category: "upload",
                    message: "File upload failed: \(error.localizedDescription)",
                    severity: "ERROR",
                    assetId: assetId
                )
            }
        }
        
        progressTask.cancel()
    }
    
    // MARK: - Submit Form
    
    func submitForm(assetId: String, formData: [String: String]) async {
        var request = auth.authenticatedRequest(for: ServerConfig.formURL(assetId), method: "POST")
        request.httpBody = try? JSONSerialization.data(withJSONObject: formData)
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            // Check HTTP status code
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                throw URLError(.badServerResponse)
            }
            
            // Form sheet closes — server will push form:confirmed via WS
            // with the "High Five!" confirmation bubble + metadata
            showFormSheet = false
            PendingForm.clear()
        } catch {
            print("❌ Failed to submit form:", error)
            // Keep form open so user can retry — show error in chat too
            formSubmitError = "Failed to send form. Please try again."
            appendErrorBubble("⚠️ Form submission failed. The form is still open — please retry.", assetId: assetId)
            Task {
                await reportError(
                    category: "form",
                    message: "Form submission failed: \(error.localizedDescription)",
                    severity: "ERROR",
                    assetId: assetId
                )
            }
        }
    }
    
    // MARK: - Connect
    
    func connectWebSocket() {
        guard let token = auth.token else { return }
        // Fresh conversation — clear old messages
        messages.removeAll()
        // Tear down any existing connection/reconnect loop before connecting with fresh token
        ws.disconnect()
        ws.connect(token: token)
    }
    
    func disconnectWebSocket() {
        ws.disconnect()
    }
    
    // MARK: - Fetch Asset Detail
    
    func fetchAssetDetail(assetId: String) async {
        let request = auth.authenticatedRequest(for: ServerConfig.assetURL(assetId))
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(AssetDetailResponse.self, from: data)
            self.lastAsset = response.asset
            self.lastClip = response.asset.clips?.first
        } catch {
            print("❌ Failed to fetch asset detail:", error)
            appendErrorBubble("⚠️ Could not load video details.", assetId: assetId)
        }
    }
    
    func showMetadata() {
        guard lastClip != nil else { return }
        showMetadataSheet = true
    }
    
    // MARK: - Video Staging (iOS 26.3 Flow)
    
    /// Stage a video for preview in chat — called after user confirms in the library picker.
    func stageVideo(fileURL: URL, fileName: String, metadata: VideoMetadata) async {
        isProcessingVideo = true
        defer { isProcessingVideo = false }
        
        // Generate thumbnail from video
        let thumbnail = await StagedVideo.generateThumbnail(from: fileURL)
        
        // Format creation date for display
        let createdDate: String? = {
            guard let capturedAt = metadata.capturedAt else { return nil }
            return DVUDateFormatting.longDate(capturedAt)
        }()
        
        stagedVideo = StagedVideo(
            tempFileURL: fileURL,
            fileName: fileName,
            createdDate: createdDate,
            thumbnail: thumbnail,
            metadata: metadata
        )
    }
    
    /// User confirmed upload — proceed with create asset + upload.
    func confirmStagedUpload() async {
        guard let staged = stagedVideo else { return }
        
        // Save thumbnail + metadata for form & sent card
        let fileURL = staged.tempFileURL
        let fileName = staged.fileName
        let metadata = staged.metadata
        formThumbnail = staged.thumbnail
        lastStagedCreatedDate = staged.createdDate
        lastStagedHasLocation = metadata.gpsLat != nil
        stagedVideo = nil  // Clear immediately — SentUploadBubble takes over
        
        // Create asset on server
        if let asset = await createAsset(fileName: fileName, fileURL: fileURL) {
            print("✅ Asset created: \(asset.mediasourceId ?? asset.id)")
            await uploadVideo(assetId: asset.id, fileURL: fileURL, metadata: metadata)
            
            // Clean up temp video file after upload (#18)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
    
    /// User cancelled staged video — discard and clean up.
    func cancelStagedVideo() {
        if let staged = stagedVideo {
            try? FileManager.default.removeItem(at: staged.tempFileURL)
        }
        stagedVideo = nil
    }
    
    // MARK: - Pending Form Recovery
    
    /// Check for a form that was pending when app was killed.
    private func checkPendingForm() {
        guard let pendingForm = PendingForm.load() else { return }
        
        print("🔄 [Recovery] Found pending form for asset: \(pendingForm.assetId)")
        
        Task {
            let request = auth.authenticatedRequest(for: ServerConfig.assetURL(pendingForm.assetId))
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                
                if statusCode == 200,
                   let json = try? JSONDecoder().decode(AssetDetailResponse.self, from: data) {
                    if json.asset.formResponse != nil {
                        // Form already submitted — clear
                        print("🔄 [Recovery] Form already submitted for \(pendingForm.assetId) — clearing")
                        PendingForm.clear()
                    } else {
                        // Restore form UI
                        print("🔄 [Recovery] Restoring pending form for \(pendingForm.assetId)")
                        restoreFormFromPending(pendingForm)
                    }
                } else {
                    PendingForm.clear()
                }
            } catch {
                print("🔄 [Recovery] Could not check pending form: \(error.localizedDescription)")
            }
        }
    }
    
    /// Restore form UI from persisted PendingForm state.
    private func restoreFormFromPending(_ pendingForm: PendingForm) {
        currentAssetId = pendingForm.assetId
        formOriginalFileName = pendingForm.originalFileName
        formCapturedAt = pendingForm.capturedAt
        formClipCount = pendingForm.clipCount
        formDuration = pendingForm.duration
        if let jpegData = pendingForm.thumbnailJPEG {
            formThumbnail = UIImage(data: jpegData)
        }
        formFields = buildFormFields()
        showFormSheet = true
    }
    
    /// Build the standard form fields (used for both live and recovery).
    private func buildFormFields() -> [FormField] {
        var fields: [FormField] = []
        fields.append(FormField(id: "slug", label: "Slug / Title", type: "text", value: nil))
        fields.append(FormField(
            id: "type", label: "Content Type", type: "select", options: ["Raw", "Cut"]
        ))
        fields.append(FormField(id: "description", label: "Description / Notes", type: "textarea"))
        fields.append(FormField(
            id: "priority", label: "Priority", type: "select", value: "Low",
            options: ["Low", "Medium", "High", "Critical"]
        ))
        return fields
    }
}
