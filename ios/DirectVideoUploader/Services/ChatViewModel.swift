import Foundation
import UIKit
import Observation

/// Metadata for a sent-upload card, cached by message ID.
struct SentUploadInfo {
    let thumbnail: UIImage?
    let fileName: String
    let createdDate: String
    let hasLocation: Bool
    let transcribeEnabled: Bool
}

/// Metadata cached after mux:ready for Slack sharing and summary bubble.
struct ArchiveState {
    var assetId: String?
    var mediasourceId: String?
    var originalFileName: String?
    var formSlug: String?
    var duration: Int?
    var resolution: String?
    var fileSize: String?
}

/// Context passed to ContextFormView header.
struct FormContext {
    var originalFileName: String?
    var capturedAt: String?
    var clipCount: Int?
    var duration: Int?
    var thumbnail: UIImage?
    var submitError: String?
}

/// Central chat view model — manages messages, assets, and coordinates services.
@MainActor
@Observable
final class ChatViewModel {
    // MARK: - State
    
    var messages: [ChatMessage] = []
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
    var transcribeOnUpload = false
    
    // Archive state — conversation closed after mux:ready or new upload
    var isArchived = false
    var showSlackShareSheet = false
    var archive = ArchiveState()
    
    // Form context (passed to ContextFormView header)
    var form = FormContext()
    
    /// Metadata for sent-upload cards, keyed by message ID
    var sentUploads: [String: SentUploadInfo] = [:]

    /// Cached thumbnails for Slack confirmation bubbles, keyed by message ID
    var slackThumbnails: [String: UIImage] = [:]

    /// IDs of outgoing Slack messages that have been confirmed by the server
    var slackConfirmedIds: Set<String> = []
    
    /// Temp staging data preserved across confirmStagedUpload → createAsset
    private var lastStagedCreatedDate: String?
    private var lastStagedHasLocation: Bool = false
    private var pendingPHAssetIdentifier: String?
    private var uploadTask: Task<Void, Never>?
    
    // MARK: - Dependencies
    
    let auth: AuthService
    let ws: WebSocketService
    let uploader = VideoUploadService()
    let transcriber = TranscriptionService()
    
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
            // When server confirms a Slack post, mark the last outgoing
            // .slackPost as confirmed so the bubble switches to "Sent".
            if message.messageType == .slackPost,
               message.direction == .incoming {
                if let outId = self?.messages.last(where: {
                    $0.messageType == .slackPost && $0.direction == .outgoing && !(self?.slackConfirmedIds.contains($0.id) ?? true)
                })?.id {
                    self?.slackConfirmedIds.insert(outId)
                }
            }
            // Auto-download thumbnail for Slack confirmation bubbles
            if message.messageType == .slackPost,
               message.direction == .incoming,
               let urlStr = message.content.thumbnailUrl,
               let url = URL(string: urlStr) {
                self?.downloadSlackThumbnail(url: url, messageId: message.id)
            }
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
            self.form.originalFileName = data["originalFileName"] as? String
            self.form.clipCount = data["clipCount"] as? Int
            self.form.duration = data["duration"] as? Int
            if let dateVal = data["capturedAt"] as? String {
                self.form.capturedAt = dateVal
            }
            
            self.formFields = self.buildFormFields()
            self.showFormSheet = true
            
            // Persist form state so it survives app kill
            if let assetId {
                PendingForm.save(PendingForm(
                    assetId: assetId,
                    originalFileName: self.form.originalFileName,
                    capturedAt: self.form.capturedAt,
                    clipCount: self.form.clipCount,
                    duration: self.form.duration,
                    thumbnailJPEG: self.form.thumbnail?.jpegData(compressionQuality: 0.5),
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
                    capturedAt: capturedAt
                ),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            self.messages.append(confirmation)
        }
        
        ws.onMuxReady = { [weak self] data in
            guard let self else { return }
            let assetId = data["assetId"] as? String
            let mediasourceId = data["mediasourceId"] as? String
            let originalFileName = data["originalFileName"] as? String
            let formSlug = data["formSlug"] as? String
            let duration = data["duration"] as? Int
            let resolution = data["resolution"] as? String
            let fileSize = data["fileSize"] as? String
            
            print("✅ [Mux Ready] Asset \(assetId ?? "?") confirmed on Mediasource")
            
            // Store archive metadata
            self.archive.assetId = assetId
            self.archive.mediasourceId = mediasourceId
            self.archive.originalFileName = originalFileName
            self.archive.formSlug = formSlug
            self.archive.duration = duration
            self.archive.resolution = resolution
            self.archive.fileSize = fileSize
            
            // Append the summary bubble as a chat message
            let summaryMessage = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: assetId,
                direction: .incoming,
                messageType: .muxReady,
                content: MessageContent(
                    text: "Mediasource Confirmed ✅",
                    mediasourceId: mediasourceId,
                    originalFileName: originalFileName,
                    duration: duration,
                    resolution: resolution
                ),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            self.messages.append(summaryMessage)
            self.isArchived = true
            
            // After 1 second, append a random fun follow-up as the final message
            let firstName = self.auth.currentUser?.name.components(separatedBy: " ").first ?? "Friend"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                let phrases = [
                    "\(firstName), you are working hard today, send and I'll recieve.",
                    "\(firstName), nice clip, send another whenever you're ready.",
                    "\(firstName), its in the can! I'd like to see more dailies.",
                    "\(firstName), take five — or send five more videos, I don't judge.",
                    "\(firstName), you're are en fuego 🔥! Firetrucks are on standby.",
                    "\(firstName), basically I'm your cloud butler — at your service.",
                    "\(firstName), that was golden, where is the podium? 🥇",
                    "\(firstName), go grab coffee all is good, we have the file.",
                    "\(firstName), we are such a good team, Ready when you are.",
                    "\(firstName), thanks for that. I'll just be here, waiting. For your next video."
                ]
                let message = phrases.randomElement()! + "\n\nAlso go ahead and #Slack this."
                let followUp = ChatMessage(
                    id: UUID().uuidString,
                    userId: nil,
                    assetId: nil,
                    direction: .incoming,
                    messageType: .greeting,
                    content: MessageContent(text: message),
                    createdAt: DVUDateFormatting.isoString(from: Date())
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
            createdAt: DVUDateFormatting.isoString(from: Date())
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
    
    
    // MARK: - Send Text Message
    
    // Matches #channel or @mention anywhere in the text (mirrors server-side regex)
    private static let slackCommandPattern = try? NSRegularExpression(pattern: "[#@][\\w.-]+")
    
    func sendTextMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // Detect Slack commands: #channel or @user (anywhere in the message, matching server-side regex)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let isSlackCommand = Self.slackCommandPattern?.firstMatch(in: trimmed, range: range) != nil
        
        // If Slack command but no current upload, tell user to upload first
        if isSlackCommand && currentAssetId == nil && !isArchived {
            let localOut = ChatMessage(
                id: UUID().uuidString,
                userId: auth.currentUser?.id,
                assetId: nil,
                direction: .outgoing,
                messageType: .slackPost,
                content: MessageContent(text: text),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            messages.append(localOut)
            let reply = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: nil,
                direction: .incoming,
                messageType: .text,
                content: MessageContent(text: "Upload a video first and I can grab the metadata so you can Slack it. Previous uploads are in your Archive — you can Slack from there."),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            messages.append(reply)
            return
        }
        
        // Optimistic UI — add message locally
        let localMessage = ChatMessage(
            id: UUID().uuidString,
            userId: auth.currentUser?.id,
            assetId: nil,
            direction: .outgoing,
            messageType: isSlackCommand ? .slackPost : .text,
            content: MessageContent(text: text),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        messages.append(localMessage)
        
        // Send via WebSocket — always pass explicit assetId so the server
        // doesn't fall back to "most recent READY asset" (wrong metadata bug).
        ws.sendMessage(text: text, assetId: currentAssetId ?? archive.assetId)
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
        
        do {
            let asset = try await withRetry(attempts: 3) { attempt in
                let (data, httpResponse) = try await URLSession.shared.data(for: request)
                let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0
                
                guard statusCode >= 200, statusCode < 300 else {
                    let body = String(data: data, encoding: .utf8) ?? "(empty)"
                    print("❌ createAsset HTTP \(statusCode): \(body)")
                    throw NSError(domain: "createAsset", code: statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "Server returned \(statusCode)"])
                }
                
                let response = try JSONDecoder().decode(CreateAssetResponse.self, from: data)
                return response.asset
            }
            
            currentAssetId = asset.id
        
            // Add outgoing video message locally — also cache thumbnail for VideoBubble
            let msgId = UUID().uuidString
            let videoMessage = ChatMessage(
                id: msgId,
                userId: auth.currentUser?.id,
                assetId: asset.id,
                direction: .outgoing,
                messageType: .video,
                content: MessageContent(text: "📹 \(fileName)", fileName: fileName),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            messages.append(videoMessage)
            
            // Cache metadata so VideoBubble can render the card
            sentUploads[msgId] = SentUploadInfo(
                thumbnail: form.thumbnail,
                fileName: fileName,
                createdDate: lastStagedCreatedDate ?? DVUDateFormatting.longDate(from: Date()),
                hasLocation: lastStagedHasLocation,
                transcribeEnabled: transcribeOnUpload
            )
            
            // Notify WebSocket with real file size
            ws.sendVideoUpload(
                assetId: asset.id,
                fileName: fileName,
                fileSize: fileSize
            )
            
            return asset
        } catch {
            let errorDesc = error.localizedDescription
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
    
    // MARK: - Send Transcript
    
    /// Send transcript text + timestamped segments to the server (non-fatal).
    func sendTranscript(assetId: String, result: TranscriptionResult) async {
        var request = auth.authenticatedRequest(for: ServerConfig.transcriptURL(assetId), method: "PATCH")
        
        // Encode segments as JSON array
        let segmentsData = try? JSONEncoder().encode(result.segments)
        let segmentsJSON = segmentsData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        
        let body: [String: Any] = [
            "transcript": result.text,
            "segments": segmentsJSON ?? []
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                print("✅ Transcript saved for asset \(assetId) (\(result.segments.count) segments)")
            }
        } catch {
            print("⚠️ Failed to save transcript: \(error)")
            // Non-fatal — don't show error bubble for transcript failure
        }
    }
    
    // MARK: - Video Staging (iOS 26.3 Flow)
    
    /// Stage a video for preview in chat — called after user confirms in the library picker.
    func stageVideo(fileURL: URL, fileName: String, metadata: VideoMetadata, phAssetIdentifier: String? = nil) async {
        // If a conversation is archived, start fresh
        if isArchived {
            startNewConversation()
        }
        
        isProcessingVideo = true
        defer { isProcessingVideo = false }
        
        // Store PHAsset identifier for re-upload recovery
        self.pendingPHAssetIdentifier = phAssetIdentifier
        
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
        
        // Auto-archive previous upload so state doesn't leak between uploads
        if isArchived || currentAssetId != nil {
            startNewConversation()
        }
        
        let fileURL = staged.tempFileURL
        let fileName = staged.fileName
        let metadata = staged.metadata
        
        prepareStagedContext(staged)
        
        uploadTask = Task {
            guard let asset = await createAsset(fileName: fileName, fileURL: fileURL) else { return }
            print("✅ Asset created: \(asset.mediasourceId ?? asset.id)")
            
            savePHAssetIdentifier(for: asset.id)
            await uploadVideo(assetId: asset.id, fileURL: fileURL, metadata: metadata)
            
            guard !Task.isCancelled else { return }
            
            if transcribeOnUpload {
                await transcribeAndReport(assetId: asset.id, fileURL: fileURL)
                transcribeOnUpload = false
            }
            
            cleanupTempFile(fileURL)
        }
        await uploadTask?.value
        uploadTask = nil
    }
    
    /// Cancel an in-progress upload.
    func cancelUpload() {
        uploadTask?.cancel()
        uploadTask = nil
        isUploading = false
        uploadProgress = 0
        appendErrorBubble("Upload cancelled.")
    }
    
    /// User cancelled staged video — discard and clean up.
    func cancelStagedVideo() {
        if let staged = stagedVideo {
            try? FileManager.default.removeItem(at: staged.tempFileURL)
        }
        stagedVideo = nil
    }
    
    // MARK: - Private Helpers
    
    /// Save thumbnail + metadata from staged video, clear the preview.
    private func prepareStagedContext(_ staged: StagedVideo) {
        form.thumbnail = staged.thumbnail
        lastStagedCreatedDate = staged.createdDate
        lastStagedHasLocation = staged.metadata.gpsLat != nil
        stagedVideo = nil  // Clear immediately — VideoBubble (.uploading) takes over
    }
    
    /// Persist PHAsset identifier so re-upload can find the original video.
    private func savePHAssetIdentifier(for assetId: String) {
        if let phId = pendingPHAssetIdentifier {
            PHAssetIdentifierStore.save(assetId: assetId, phAssetIdentifier: phId)
        }
        pendingPHAssetIdentifier = nil
    }
    
    /// Transcribe audio and update the status bubble in-place.
    private func transcribeAndReport(assetId: String, fileURL: URL) async {
        let transcribingMsg = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(text: "🎙️ Transcribing audio..."),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        messages.append(transcribingMsg)
        
        if let result = await transcriber.transcribe(videoURL: fileURL) {
            await sendTranscript(assetId: assetId, result: result)
            updateTranscriptionBubble(id: transcribingMsg.id, assetId: assetId,
                                       text: "✅ Transcript sent to Mediasource. (\(result.segments.count) words.) Transcript available in Archive.",
                                       createdAt: transcribingMsg.createdAt)
        } else {
            let statusText: String
            switch transcriber.state {
            case .noSpeech:
                statusText = "🎙️ No clear audio detected in video."
            case .failed(let reason):
                statusText = "⚠️ Transcription failed: \(reason)."
            default:
                statusText = "⚠️ Transcription did not produce results."
            }
            updateTranscriptionBubble(id: transcribingMsg.id, assetId: assetId,
                                       text: statusText, createdAt: transcribingMsg.createdAt)
        }
    }
    
    /// Replace the content of a transcription status bubble.
    private func updateTranscriptionBubble(id: String, assetId: String, text: String, createdAt: String?) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx] = ChatMessage(
                id: id, userId: nil, assetId: assetId,
                direction: .incoming, messageType: .text,
                content: MessageContent(text: text),
                createdAt: createdAt
            )
        }
    }
    
    /// Clean up the temporary video file after upload + transcription.
    private func cleanupTempFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
    
    // MARK: - Cancel Form (skip details → archive)
    
    /// User chose to skip the form. Archive the conversation immediately.
    /// PendingForm stays on disk so the form can be reopened later from Archive.
    /// Video continues uploading in background.
    func cancelForm() {
        showFormSheet = false
        isArchived = true
        
        // Add a chat bubble confirming the skip
        let msg = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: currentAssetId,
            direction: .incoming,
            messageType: .systemNote,
            content: MessageContent(text: "No worries — your video is still uploading. You can add details from your Archive anytime."),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        messages.append(msg)
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
            form.submitError = nil
            showFormSheet = false
            PendingForm.clear()
        } catch {
            print("❌ Failed to submit form:", error)
            // Keep form open so user can retry — show error in chat too
            form.submitError = "Failed to send form. Please try again."
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
        form.originalFileName = pendingForm.originalFileName
        form.capturedAt = pendingForm.capturedAt
        form.clipCount = pendingForm.clipCount
        form.duration = pendingForm.duration
        if let jpegData = pendingForm.thumbnailJPEG {
            form.thumbnail = UIImage(data: jpegData)
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
    
    // MARK: - Archive / New Conversation
    
    /// Clear current conversation and start fresh for a new upload.
    func startNewConversation() {
        messages.removeAll()
        currentAssetId = nil
        isArchived = false
        archive = ArchiveState()
        form = FormContext()
        lastAsset = nil
        lastClip = nil
        stagedVideo = nil
        isUploading = false
        uploadProgress = 0
        showFormSheet = false
        showMetadataSheet = false
        showSlackShareSheet = false
        sentUploads.removeAll()
        slackThumbnails.removeAll()
        slackConfirmedIds.removeAll()
        lastStagedCreatedDate = nil
        lastStagedHasLocation = false
        
        // Re-send greeting for the fresh conversation
        let firstName = auth.currentUser?.name.components(separatedBy: " ").first ?? "there"
        let greeting = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: nil,
            direction: .incoming,
            messageType: .greeting,
            content: MessageContent(text: "Hey \(firstName)! You are busy today. Upload away."),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        messages.append(greeting)
    }
    
    /// Send a Slack share for the archived asset.
    func shareToSlack(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // Optimistic UI — add Slack post message locally
        let localMessage = ChatMessage(
            id: UUID().uuidString,
            userId: auth.currentUser?.id,
            assetId: archive.assetId,
            direction: .outgoing,
            messageType: .slackPost,
            content: MessageContent(text: text),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        messages.append(localMessage)
        showSlackShareSheet = false
        
        // Send via WebSocket — server detects #channel/@mention pattern
        ws.sendMessage(text: text, assetId: archive.assetId)
    }

    /// Download a thumbnail image and cache it for the Slack bubble.
    private func downloadSlackThumbnail(url: URL, messageId: String) {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    self.slackThumbnails[messageId] = image
                }
            } catch {
                print("⚠️ Failed to download Slack thumbnail: \(error.localizedDescription)")
            }
        }
    }
}
