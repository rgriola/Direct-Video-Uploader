import Foundation
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
    
    // MARK: - Dependencies
    
    let auth: AuthService
    let ws: WebSocketService
    let uploader = VideoUploadService()
    
    init(auth: AuthService, ws: WebSocketService) {
        self.auth = auth
        self.ws = ws
        setupWebSocketHandlers()
    }
    
    // MARK: - WebSocket Handlers
    
    private func setupWebSocketHandlers() {
        ws.onMessage = { [weak self] message in
            self?.messages.append(message)
        }
        
        ws.onGreeting = { [weak self] text in
            guard let self else { return }
            let greeting = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: nil,
                direction: .incoming,
                messageType: .greeting,
                content: MessageContent(text: text),
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            self.messages.append(greeting)
        }
        
        ws.onUploadComplete = { [weak self] assetId in
            guard let self else { return }
            print("✅ Upload complete for asset: \(assetId)")
            
            // Fetch the full asset (with clips) so MetadataView can display it
            Task { @MainActor in
                await self.fetchAssetDetail(assetId: assetId)
            }
        }
        
        ws.onFormRequest = { [weak self] data in
            guard let self else { return }
            self.currentAssetId = data["assetId"] as? String
            
            var fields: [FormField] = []
            
            // Server sends prefilledData as key-value pairs
            if let prefilled = data["prefilledData"] as? [String: Any] {
                // Read-only metadata display rows
                let metadataKeys = ["sender", "phone", "gps", "capturedAt", "device", "duration", "codec", "resolution", "orientation"]
                for key in metadataKeys {
                    if let value = prefilled[key] {
                        fields.append(FormField(
                            id: key,
                            label: key.capitalized,
                            type: "text",
                            value: "\(value)",
                            isReadOnly: true
                        ))
                    }
                }
                
                // Editable slug (prefilled from server)
                let prefillSlug = prefilled["slug"] as? String
                fields.append(FormField(id: "slug", label: "Slug / Title", type: "text", value: prefillSlug))
            }
            
            // Editable fields the server expects
            fields.append(FormField(
                id: "type",
                label: "Content Type",
                type: "select",
                options: ["Raw", "Interview", "Standup", "B-Roll", "Live Shot", "Other"]
            ))
            fields.append(FormField(id: "description", label: "Description / Notes", type: "textarea"))
            fields.append(FormField(
                id: "priority",
                label: "Priority",
                type: "select",
                value: "Medium",
                options: ["Low", "Medium", "High", "Critical"]
            ))
            
            self.formFields = fields
            self.showFormSheet = true
        }
        
        ws.onFormConfirmed = { [weak self] data in
            guard let self else { return }
            let text = data["message"] as? String ?? "🙌 High Five! Form received."
            let mediasourceId = data["mediasourceId"] as? String
            let mediasourceUrl = data["mediasourceUrl"] as? String
            
            let confirmation = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: data["assetId"] as? String,
                direction: .incoming,
                messageType: .confirmation,
                content: MessageContent(
                    text: text,
                    mediasourceId: mediasourceId,
                    mediasourceUrl: mediasourceUrl
                ),
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            self.messages.append(confirmation)
        }
        
        ws.onSlackConfirmed = { [weak self] data in
            guard let self else { return }
            let channel = data["channel"] as? String ?? "#team-alerts"
            let slackMsg = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: data["assetId"] as? String,
                direction: .incoming,
                messageType: .text,
                content: MessageContent(text: "📡 Posted to Slack \(channel)"),
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            self.messages.append(slackMsg)
        }
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
        }
    }
    
    // MARK: - Send Text Message
    
    func sendTextMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // Optimistic UI — add message locally
        let localMessage = ChatMessage(
            id: UUID().uuidString,
            userId: auth.currentUser?.id,
            assetId: nil,
            direction: .outgoing,
            messageType: .text,
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
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(CreateAssetResponse.self, from: data)
            currentAssetId = response.asset.id
            
            // Add outgoing video message locally
            let videoMessage = ChatMessage(
                id: UUID().uuidString,
                userId: auth.currentUser?.id,
                assetId: response.asset.id,
                direction: .outgoing,
                messageType: .video,
                content: MessageContent(text: "📹 \(fileName)", fileName: fileName),
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            messages.append(videoMessage)
            
            // Notify WebSocket with real file size
            ws.sendVideoUpload(
                assetId: response.asset.id,
                fileName: fileName,
                fileSize: fileSize
            )
            
            return response.asset
        } catch {
            print("❌ Failed to create asset:", error)
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
            let _ = try await uploader.upload(assetId: assetId, fileURL: fileURL, token: token, metadata: metadata)
            print("✅ [Upload] Completed successfully for asset: \(assetId)")
        } catch {
            print("❌ [Upload] Failed for asset \(assetId): \(error)")
            print("❌ [Upload] Error details: \(error.localizedDescription)")
            // Show error in chat
            let errorMsg = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: assetId,
                direction: .incoming,
                messageType: .text,
                content: MessageContent(text: "⚠️ Upload failed: \(error.localizedDescription)"),
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            messages.append(errorMsg)
        }
        
        progressTask.cancel()
    }
    
    // MARK: - Submit Form
    
    func submitForm(assetId: String, formData: [String: String]) async {
        var request = auth.authenticatedRequest(for: ServerConfig.formURL(assetId), method: "POST")
        request.httpBody = try? JSONSerialization.data(withJSONObject: formData)
        
        do {
            let (_, _) = try await URLSession.shared.data(for: request)
            
            // Add local confirmation
            let formMessage = ChatMessage(
                id: UUID().uuidString,
                userId: auth.currentUser?.id,
                assetId: assetId,
                direction: .outgoing,
                messageType: .formSubmitted,
                content: MessageContent(text: "📋 Form submitted"),
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            messages.append(formMessage)
            
            // Notify via WebSocket
            ws.sendFormSubmit(assetId: assetId, formData: formData)
            
            showFormSheet = false
        } catch {
            print("❌ Failed to submit form:", error)
        }
    }
    
    // MARK: - Connect
    
    func connectWebSocket() {
        guard let token = auth.token else { return }
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
        }
    }
    
    func showMetadata() {
        guard lastClip != nil else { return }
        showMetadataSheet = true
    }
}
