// May 11, 2026 - 6:34pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation
import Observation
import UIKit

/// Metadata for a sent-upload card, cached by message ID.
struct SentUploadInfo {
    let thumbnail: UIImage?
    let fileName: String
    let createdDate: String
    let hasLocation: Bool
    let transcribeEnabled: Bool
}

/// Per-clip state for batch upload cards rendered in the chat timeline.
struct BatchClipDisplayState {
    var phase: VideoBubblePhase
    var progress: Double
    var mediasourceId: String?
    var mediasourceUrl: String?
    var formSlug: String?
    var errorText: String?
}

/// Metadata cached after mux:ready for Slack sharing and summary bubble.
struct ArchiveState {
    var assetId: String?
    var mediasourceId: String?
    var mediasourceUrl: String?
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
    var metadataSheetThumbnail: UIImage?
    var formFields: [FormField] = []
    var uploadProgress: Double = 0
    var isUploading = false
    var lastClip: Clip?
    var lastAsset: Asset?

    // Staged video — preview before upload (iOS 26.3 flow)
    var stagedVideo: StagedVideo?
    var isProcessingVideo = false
    var transcribeOnUpload = false

    // Batch upload state (multiclip flow)
    var currentBatchId: String?
    var stagedBatchVideos: [SelectedVideo] = []
    var batchItems: [VideoBatchItem] = []
    var batchContext: VideoBatchContext?
    var batchProgress: Double = 0
    var isBatchUploading = false
    var suppressPerAssetFormSheet = false
    var batchState: VideoBatchState = .queued

    var hasActiveBatch: Bool {
        currentBatchId != nil && !batchItems.isEmpty
    }

    /// Timeline visibility for the batch bubble.
    /// Keep visible for the full active batch lifecycle so users retain context.
    var showsBatchBubbleInTimeline: Bool {
        hasActiveBatch
    }

    var shouldRenderBatchQueueBeforeMessages: Bool {
        showsBatchBubbleInTimeline && messages.isEmpty
    }

    func shouldRenderBatchQueue(after messageId: String) -> Bool {
        guard showsBatchBubbleInTimeline else { return false }

        if let anchorId = batchBubbleAnchorMessageId {
            return messageId == anchorId
        }

        return messageId == messages.last?.id
    }

    var shouldRenderBatchQueueAtEnd: Bool {
        guard showsBatchBubbleInTimeline else { return false }
        guard let anchorId = batchBubbleAnchorMessageId else { return false }
        return !messages.contains(where: { $0.id == anchorId })
    }

    var batchCompletedCount: Int {
        batchItems.filter { $0.status == .complete }.count
    }

    var batchFailedCount: Int {
        batchItems.filter { $0.status == .failed }.count
    }

    var batchDisplayFileNames: [String] {
        Array(batchItems.prefix(3).map(\.fileName))
    }

    var canRetryFailedBatchItems: Bool {
        !isBatchUploading && batchItems.contains { $0.status == .failed }
    }

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
    private var pendingBatchFormData: [String: String]?
    private var awaitingGroupedFormForBatch = false
    private var groupedFormSubmitAttemptCountByAssetId: [String: Int] = [:]
    private var batchBubbleAnchorMessageId: String?
    private var batchClipDisplayByAssetId: [String: BatchClipDisplayState] = [:]
    private var sentUploadsByAssetId: [String: SentUploadInfo] = [:]
    private var assetDetailCache: [String: Asset] = [:]
    private let messagePolicy = MessagePolicyCoordinator()
    private let batchCoordinator = VideoBatchUploadCoordinator(maxConcurrentUploads: 2)
    private static let groupedFormDebugTruthyValues: Set<String> = ["1", "true", "yes", "on"]

    private enum WorkflowStage: Int {
        case unknown = 0
        case uploading = 10
        case formRequested = 20
        case formConfirmed = 30
        case processing = 40
        case ready = 50
        case failed = 60
    }

    private var workflowStages: [String: WorkflowStage] = [:]
    private var hasBlockingConnectivityIssue = false
    private var blockingConnectivityAssetId: String?
    private let reconnectWarningThreshold = 3

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
        checkPendingForm()  // Check for form that was pending when app was killed
        restorePendingBatchState()
    }

    // MARK: - WebSocket Handlers

    private func setupWebSocketHandlers() {
        ws.onMessage = { [weak self] message in
            guard let self else { return }

            self.clearBlockingConnectivityIssueIfNeeded(assetId: message.assetId)

            if self.isBatchAssetId(message.assetId) {
                if message.messageType == .confirmation {
                    self.updateBatchClipMetadata(
                        assetId: message.assetId,
                        mediasourceId: message.content.mediasourceId,
                        mediasourceUrl: message.content.mediasourceUrl,
                        formSlug: message.content.slug
                    )
                    self.setBatchClipPhase(assetId: message.assetId, phase: .processing)
                    return
                }

                if message.messageType == .muxReady {
                    self.markBatchClipReady(
                        assetId: message.assetId,
                        mediasourceId: message.content.mediasourceId,
                        mediasourceUrl: message.content.mediasourceUrl,
                        formSlug: message.content.slug
                    )
                    return
                }

                if message.content.code == "IOS_MUX_READY_FOLLOWUP"
                    || message.content.code == "IOS_MUX_READY_SUMMARY"
                    || message.content.code == "WS_FORM_CONFIRMED"
                {
                    return
                }
            }

            // When server confirms a Slack post, mark the last outgoing
            // .slackPost as confirmed so the bubble switches to "Sent".
            if message.messageType == .slackPost,
                message.direction == .incoming
            {
                if let outId = self.messages.last(where: {
                    $0.messageType == .slackPost && $0.direction == .outgoing
                        && !self.slackConfirmedIds.contains($0.id)
                })?.id {
                    self.slackConfirmedIds.insert(outId)
                }
            }

            self.appendMessage(message, source: .websocket)

            // Auto-download thumbnail for Slack confirmation bubbles
            if message.messageType == .slackPost,
                message.direction == .incoming,
                let urlStr = message.content.thumbnailUrl,
                let url = URL(string: urlStr)
            {
                self.downloadSlackThumbnail(url: url, messageId: message.id)
            }
        }

        ws.onUploadComplete = { [weak self] data in
            guard let self else { return }
            let assetId = data["assetId"] as? String ?? ""
            print("✅ Upload complete for asset: \(assetId)")

            self.clearBlockingConnectivityIssueIfNeeded(assetId: assetId)

            if !assetId.isEmpty {
                _ = self.promoteStage(for: assetId, to: .processing)
                if self.isBatchAssetId(assetId) {
                    self.setBatchClipPhase(assetId: assetId, phase: .processing)
                }
            }

            // Fetch the full asset (with clips) so MetadataView can display it
            Task { @MainActor in
                await self.fetchAssetDetail(assetId: assetId)
            }
        }

        ws.onFormRequest = { [weak self] data in
            guard let self else { return }
            let assetId = data["assetId"] as? String
            self.currentAssetId = assetId

            self.clearBlockingConnectivityIssueIfNeeded(assetId: assetId)

            if let assetId {
                _ = self.promoteStage(for: assetId, to: .formRequested)
            }

            // Store form context for ContextFormView header
            self.form.originalFileName = data["originalFileName"] as? String
            self.form.clipCount = data["clipCount"] as? Int
            self.form.duration = data["duration"] as? Int
            if let dateVal = data["capturedAt"] as? String {
                self.form.capturedAt = dateVal
            }

            if self.suppressPerAssetFormSheet {
                if let assetId {
                    self.debugLogGroupedFormSubmit(
                        assetId: assetId,
                        event: .suppressedFormRequest
                    )
                }
                self.showFormSheet = false
                return
            }

            self.formFields = self.buildFormFields()
            self.showFormSheet = true

            // Persist form state so it survives app kill
            if let assetId {
                PendingForm.save(
                    PendingForm(
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
            let assetId = data["assetId"] as? String

            self.clearBlockingConnectivityIssueIfNeeded(assetId: assetId)

            let fallbackText =
                data["messageFallbackText"] as? String
                ?? data["message"] as? String
                ?? "High five. Form received."
            let messageCode = data["messageCode"] as? String ?? "WS_FORM_CONFIRMED"
            let messageParams = self.parseStringParams(data["messageParams"])
            let messageSchemaVersion =
                data["messageSchemaVersion"] as? Int ?? MessageCatalog.schemaVersion
            let mediasourceId = data["mediasourceId"] as? String
            let mediasourceUrl = data["mediasourceUrl"] as? String
            let originalFileName = data["originalFileName"] as? String
            let capturedAt = data["capturedAt"] as? String
            let formSlug = (data["formSlug"] as? String) ?? (data["slug"] as? String)

            let previousStage = self.promoteStage(for: assetId, to: .formConfirmed)

            if self.isBatchAssetId(assetId) {
                self.updateBatchClipMetadata(
                    assetId: assetId,
                    mediasourceId: mediasourceId,
                    mediasourceUrl: mediasourceUrl,
                    formSlug: formSlug
                )
                self.setBatchClipPhase(assetId: assetId, phase: .processing)
                return
            }

            let hasExistingFormConfirmation = self.hasWorkflowMessage(
                code: messageCode,
                assetId: assetId,
                mediasourceId: mediasourceId
            )

            if previousStage != .failed,
                previousStage.rawValue >= WorkflowStage.formConfirmed.rawValue,
                hasExistingFormConfirmation
            {
                return
            }

            self.ensureFormConfirmedMessage(
                assetId: assetId,
                mediasourceId: mediasourceId,
                mediasourceUrl: mediasourceUrl,
                originalFileName: originalFileName,
                capturedAt: capturedAt,
                fallbackText: fallbackText,
                code: messageCode,
                params: messageParams,
                schemaVersion: messageSchemaVersion,
                source: .workflow
            )
        }

        ws.onMuxReady = { [weak self] data in
            guard let self else { return }
            let assetId = data["assetId"] as? String
            let mediasourceId = data["mediasourceId"] as? String
            let mediasourceUrl = data["mediasourceUrl"] as? String
            let originalFileName = data["originalFileName"] as? String
            let formSlug = data["formSlug"] as? String
            let duration = data["duration"] as? Int
            let resolution = data["resolution"] as? String
            let fileSize = data["fileSize"] as? String

            self.clearBlockingConnectivityIssueIfNeeded(assetId: assetId)

            if self.isBatchAssetId(assetId) {
                self.markBatchClipReady(
                    assetId: assetId,
                    mediasourceId: mediasourceId,
                    mediasourceUrl: mediasourceUrl,
                    formSlug: formSlug
                )
                return
            }

            let hasSubmittedForm =
                !(formSlug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if hasSubmittedForm {
                // If form:confirmed arrives late (or is missed), ensure the metadata
                // confirmation bubble still appears before the ready summary.
                self.ensureFormConfirmedMessage(
                    assetId: assetId,
                    mediasourceId: mediasourceId,
                    mediasourceUrl: mediasourceUrl,
                    originalFileName: originalFileName,
                    capturedAt: nil,
                    fallbackText: nil,
                    source: .workflow
                )
            }

            print("✅ [Mux Ready] Asset \(assetId ?? "?") confirmed on Mediasource")

            let previousStage = self.promoteStage(for: assetId, to: .ready)
            if previousStage != .failed,
                previousStage.rawValue >= WorkflowStage.ready.rawValue
            {
                let missingSummary = !self.hasWorkflowMessage(
                    code: "IOS_MUX_READY_SUMMARY",
                    assetId: assetId,
                    mediasourceId: mediasourceId
                )
                let missingFollowup = !self.hasWorkflowMessage(
                    code: "IOS_MUX_READY_FOLLOWUP",
                    assetId: assetId,
                    mediasourceId: mediasourceId
                )

                if !missingSummary, !missingFollowup {
                    return
                }

                // Recovery path for reconnect churn: if stage is already READY but
                // UI messages are missing, clear asset dedupe and backfill them.
                self.messagePolicy.resetAssetScope(assetId: assetId)
            }

            self.applyReadyWorkflowState(
                assetId: assetId,
                mediasourceId: mediasourceId,
                mediasourceUrl: mediasourceUrl,
                originalFileName: originalFileName,
                formSlug: formSlug,
                duration: duration,
                resolution: resolution,
                fileSize: fileSize,
                source: .workflow
            )
        }

        ws.onMuxErrored = { [weak self] data in
            guard let self else { return }

            let assetId = data["assetId"] as? String
            let reason =
                data["reason"] as? String
                ?? data["error"] as? String
                ?? data["message"] as? String
                ?? "Processing error"

            self.clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
            _ = self.promoteStage(for: assetId, to: .failed)

            if self.isBatchAssetId(assetId) {
                self.markBatchClipFailed(assetId: assetId, reason: reason)
                return
            }

            self.appendErrorBubble(
                "Upload failed: \(reason)",
                assetId: assetId,
                code: "IOS_UPLOAD_FAILED",
                params: ["reason": reason]
            )
        }

    }

    // MARK: - Connection State Handlers

    private func setupConnectionHandlers() {
        ws.onConnected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.reconcileActiveWorkflowStateAfterReconnect()
            }
        }

        ws.onReconnecting = { [weak self] attempt, maxAttempts in
            guard let self else { return }
            guard attempt >= self.reconnectWarningThreshold else { return }
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

    private func isConnectivityIssue(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .notConnectedToInternet,
                .networkConnectionLost,
                .timedOut,
                .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed,
                .resourceUnavailable,
                .internationalRoamingOff,
                .callIsActive,
                .dataNotAllowed,
                .secureConnectionFailed:
                return true
            default:
                break
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                .networkConnectionLost,
                .timedOut,
                .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed,
                .resourceUnavailable,
                .internationalRoamingOff,
                .callIsActive,
                .dataNotAllowed,
                .secureConnectionFailed:
                return true
            default:
                break
            }
        }

        return false
    }

    private func noteBlockingConnectivityIssue(operation: String, assetId: String?) {
        guard !hasBlockingConnectivityIssue else { return }

        hasBlockingConnectivityIssue = true
        blockingConnectivityAssetId = assetId

        let connectivityMessage = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text:
                    "Connection interrupted while \(operation). Upload and metadata sync are paused until reconnection.",
                code: "IOS_CONNECTIVITY_BLOCKING",
                params: ["operation": operation],
                fallbackText:
                    "Connection interrupted while \(operation). Upload and metadata sync are paused until reconnection.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(connectivityMessage, source: .workflow)
    }

    private func clearBlockingConnectivityIssueIfNeeded(assetId: String?) {
        guard hasBlockingConnectivityIssue else { return }

        hasBlockingConnectivityIssue = false
        let recoveredAssetId = assetId ?? blockingConnectivityAssetId
        blockingConnectivityAssetId = nil

        let recoveredMessage = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: recoveredAssetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: "Connection restored. Upload and metadata sync resumed.",
                code: "IOS_CONNECTIVITY_RECOVERED",
                fallbackText: "Connection restored. Upload and metadata sync resumed.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(recoveredMessage, source: .workflow)
    }

    private func promoteStage(for assetId: String?, to stage: WorkflowStage) -> WorkflowStage {
        guard let assetId, !assetId.isEmpty else { return .unknown }

        let previous = workflowStages[assetId] ?? .unknown

        if stage == .failed {
            if previous != .failed {
                workflowStages[assetId] = .failed
                messagePolicy.resetAssetScope(assetId: assetId)
            }
            return previous
        }

        if previous == .failed {
            workflowStages[assetId] = stage
            return previous
        }

        if stage.rawValue > previous.rawValue {
            workflowStages[assetId] = stage
        }
        return previous
    }

    private func inferredStage(from asset: Asset) -> WorkflowStage {
        switch asset.status {
        case .error:
            return .failed
        case .ready:
            return .ready
        case .processing:
            return .processing
        case .uploading:
            if asset.formResponse != nil {
                return .formConfirmed
            }
            return .uploading
        }
    }

    private func applyReadyWorkflowState(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        formSlug: String?,
        duration: Int?,
        resolution: String?,
        fileSize: String?,
        source: MessagePolicyCoordinator.Source
    ) {
        // Store archive metadata
        archive.assetId = assetId
        archive.mediasourceId = mediasourceId
        archive.mediasourceUrl = mediasourceUrl
        archive.originalFileName = originalFileName
        archive.formSlug = formSlug
        archive.duration = duration
        archive.resolution = resolution
        archive.fileSize = fileSize
        isArchived = true

        let hasSummary = hasWorkflowMessage(
            code: "IOS_MUX_READY_SUMMARY",
            assetId: assetId,
            mediasourceId: mediasourceId
        )

        if !hasSummary {
            let summaryMessage = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: assetId,
                direction: .incoming,
                messageType: .muxReady,
                content: MessageContent(
                    text: "Mediasource confirmed.",
                    code: "IOS_MUX_READY_SUMMARY",
                    params: mediasourceId.map { ["mediasourceId": $0] },
                    fallbackText: "Mediasource confirmed.",
                    schemaVersion: MessageCatalog.schemaVersion,
                    slug: formSlug,
                    mediasourceId: mediasourceId,
                    mediasourceUrl: mediasourceUrl,
                    originalFileName: originalFileName,
                    duration: duration,
                    resolution: resolution,
                    fileSize: fileSize
                ),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            appendMessage(summaryMessage, source: source)
        }

        // After 1 second, append a normalized follow-up message.
        let hasFollowup = hasWorkflowMessage(
            code: "IOS_MUX_READY_FOLLOWUP",
            assetId: assetId,
            mediasourceId: mediasourceId
        )
        guard !hasFollowup else { return }

        let firstName = auth.currentUser?.name.components(separatedBy: " ").first ?? "there"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))

            guard
                !self.hasWorkflowMessage(
                    code: "IOS_MUX_READY_FOLLOWUP",
                    assetId: assetId,
                    mediasourceId: mediasourceId
                )
            else {
                return
            }

            let message = "You're a rock star. Send another video when ready."
            let followUp = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: assetId,
                direction: .incoming,
                messageType: .greeting,
                content: MessageContent(
                    text: message,
                    code: "IOS_MUX_READY_FOLLOWUP",
                    params: ["firstName": firstName],
                    fallbackText: message,
                    schemaVersion: MessageCatalog.schemaVersion
                ),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            self.appendMessage(followUp, source: source)
        }
    }

    private func activeSlackTargetAssetId() -> String? {
        if let currentAssetId, !currentAssetId.isEmpty {
            return currentAssetId
        }

        if isArchived,
            let archivedAssetId = archive.assetId,
            !archivedAssetId.isEmpty
        {
            return archivedAssetId
        }

        return nil
    }

    private func activeSlackTargetAssetIds() -> [String]? {
        let ids =
            batchItems
            .filter { $0.status == .complete }
            .compactMap(\.assetId)

        guard ids.count > 1 else { return nil }

        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func ensureFormConfirmedMessage(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        capturedAt: String?,
        fallbackText: String?,
        code: String = "WS_FORM_CONFIRMED",
        params: [String: String]? = nil,
        schemaVersion: Int? = nil,
        source: MessagePolicyCoordinator.Source
    ) {
        guard
            !hasWorkflowMessage(
                code: code,
                assetId: assetId,
                mediasourceId: mediasourceId
            )
        else {
            return
        }

        let resolvedFallback =
            fallbackText
            ?? MessageCatalog.resolve(code: code, params: params ?? [:])
            ?? "High five. I will text when the video is done. Metadata is ready, and you can Slack your team below."

        let confirmation = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .confirmation,
            content: MessageContent(
                text: resolvedFallback,
                code: code,
                params: params,
                fallbackText: resolvedFallback,
                schemaVersion: schemaVersion ?? MessageCatalog.schemaVersion,
                slug: nil,
                mediasourceId: mediasourceId,
                mediasourceUrl: mediasourceUrl,
                originalFileName: originalFileName,
                capturedAt: capturedAt
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(confirmation, source: source)
    }

    private func appendReconciledFormConfirmed(
        asset: Asset,
        source: MessagePolicyCoordinator.Source = .workflow
    ) {
        guard asset.formResponse != nil else { return }

        let fallback =
            MessageCatalog.resolve(code: "WS_FORM_CONFIRMED", params: [:])
            ?? "High five. I will text when the video is done. Metadata is ready, and you can Slack your team below."

        ensureFormConfirmedMessage(
            assetId: asset.id,
            mediasourceId: asset.mediasourceId,
            mediasourceUrl: asset.mediasourceUrl,
            originalFileName: asset.originalFileName ?? asset.clips?.first?.originalFileName,
            capturedAt: asset.clips?.first?.capturedAt,
            fallbackText: fallback,
            source: source
        )
    }

    private func reconcileWorkflowState(
        from asset: Asset,
        source: MessagePolicyCoordinator.Source = .workflow
    ) {
        let reconciledStage = inferredStage(from: asset)
        let previousStage = promoteStage(for: asset.id, to: reconciledStage)
        let isBatchAsset = isBatchAssetId(asset.id)

        if reconciledStage == .failed,
            previousStage != .failed
        {
            if isBatchAsset {
                markBatchClipFailed(assetId: asset.id, reason: "Processing error")
                return
            }

            appendErrorBubble(
                "Upload failed: Processing error",
                assetId: asset.id,
                code: "IOS_UPLOAD_FAILED",
                params: ["reason": "Processing error"]
            )
            return
        }

        if isBatchAsset {
            if asset.formResponse != nil,
                reconciledStage.rawValue >= WorkflowStage.formConfirmed.rawValue
            {
                updateBatchClipMetadata(
                    assetId: asset.id,
                    mediasourceId: asset.mediasourceId,
                    mediasourceUrl: asset.mediasourceUrl,
                    formSlug: asset.formResponse?.slug
                )
                setBatchClipPhase(assetId: asset.id, phase: .processing)
            }

            if reconciledStage == .ready {
                markBatchClipReady(
                    assetId: asset.id,
                    mediasourceId: asset.mediasourceId,
                    mediasourceUrl: asset.mediasourceUrl,
                    formSlug: asset.formResponse?.slug
                )
            }
            return
        }

        if asset.formResponse != nil,
            reconciledStage.rawValue >= WorkflowStage.formConfirmed.rawValue
        {
            appendReconciledFormConfirmed(asset: asset, source: source)
        }

        if reconciledStage == .ready {
            if previousStage != .failed,
                previousStage.rawValue >= WorkflowStage.ready.rawValue
            {
                let missingSummary = !hasWorkflowMessage(
                    code: "IOS_MUX_READY_SUMMARY",
                    assetId: asset.id,
                    mediasourceId: asset.mediasourceId
                )
                let missingFollowup = !hasWorkflowMessage(
                    code: "IOS_MUX_READY_FOLLOWUP",
                    assetId: asset.id,
                    mediasourceId: asset.mediasourceId
                )

                if !missingSummary, !missingFollowup {
                    return
                }

                messagePolicy.resetAssetScope(assetId: asset.id)
            }

            applyReadyWorkflowState(
                assetId: asset.id,
                mediasourceId: asset.mediasourceId,
                mediasourceUrl: asset.mediasourceUrl,
                originalFileName: asset.originalFileName
                    ?? asset.clips?.first?.originalFileName,
                formSlug: asset.formResponse?.slug,
                duration: asset.clips?.first?.duration,
                resolution: asset.clips?.first?.resolution,
                fileSize: asset.clips?.first?.fileSize,
                source: source
            )
        }
    }

    private func hasWorkflowMessage(
        code: String,
        assetId: String?,
        mediasourceId: String?
    ) -> Bool {
        messages.contains { message in
            guard message.content.code == code else { return false }

            if let assetId, !assetId.isEmpty,
                message.assetId == assetId
            {
                return true
            }

            if let mediasourceId, !mediasourceId.isEmpty,
                message.content.mediasourceId == mediasourceId
            {
                return true
            }

            return false
        }
    }

    func batchClipDisplayState(for assetId: String?) -> BatchClipDisplayState? {
        guard let assetId, !assetId.isEmpty else { return nil }

        if let stored = batchClipDisplayByAssetId[assetId] {
            return stored
        }

        guard let item = batchItems.first(where: { $0.assetId == assetId }) else {
            return nil
        }

        return BatchClipDisplayState(
            phase: phaseForBatchItemStatus(item.status),
            progress: min(max(item.progress, 0), 1),
            mediasourceId: nil,
            mediasourceUrl: nil,
            formSlug: nil,
            errorText: item.error
        )
    }

    private func isBatchAssetId(_ assetId: String?) -> Bool {
        guard let assetId, !assetId.isEmpty else { return false }
        if batchClipDisplayByAssetId[assetId] != nil {
            return true
        }
        return batchItems.contains(where: { $0.assetId == assetId })
    }

    private func phaseForBatchItemStatus(_ status: VideoBatchItemStatus) -> VideoBubblePhase {
        switch status {
        case .failed:
            return .failed
        case .queued, .creatingAsset, .uploading:
            return .uploading
        case .applyingForm, .complete:
            return .processing
        }
    }

    private func setBatchClipPhase(assetId: String?, phase: VideoBubblePhase) {
        guard let assetId, !assetId.isEmpty else { return }
        var state =
            batchClipDisplayState(for: assetId)
            ?? BatchClipDisplayState(
                phase: .uploading,
                progress: 0,
                mediasourceId: nil,
                mediasourceUrl: nil,
                formSlug: nil,
                errorText: nil
            )
        state.phase = phase

        if phase == .sent {
            state.progress = 1
            state.errorText = nil
        }

        batchClipDisplayByAssetId[assetId] = state
    }

    private func updateBatchClipProgress(assetId: String?, progress: Double) {
        guard let assetId, !assetId.isEmpty else { return }
        var state =
            batchClipDisplayState(for: assetId)
            ?? BatchClipDisplayState(
                phase: .uploading,
                progress: 0,
                mediasourceId: nil,
                mediasourceUrl: nil,
                formSlug: nil,
                errorText: nil
            )
        state.progress = min(max(progress, 0), 1)
        batchClipDisplayByAssetId[assetId] = state
    }

    private func updateBatchClipMetadata(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    ) {
        guard let assetId, !assetId.isEmpty else { return }
        var state =
            batchClipDisplayState(for: assetId)
            ?? BatchClipDisplayState(
                phase: .processing,
                progress: 1,
                mediasourceId: nil,
                mediasourceUrl: nil,
                formSlug: nil,
                errorText: nil
            )

        if let mediasourceId,
            !mediasourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            state.mediasourceId = mediasourceId
        }

        if let mediasourceUrl,
            !mediasourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            state.mediasourceUrl = mediasourceUrl
        }

        if let formSlug,
            !formSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            state.formSlug = formSlug
        }

        batchClipDisplayByAssetId[assetId] = state
    }

    private func markBatchClipReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    ) {
        guard let assetId, !assetId.isEmpty else { return }

        updateBatchClipMetadata(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            formSlug: formSlug
        )
        setBatchClipPhase(assetId: assetId, phase: .sent)
        updateBatchClipProgress(assetId: assetId, progress: 1)
    }

    private func markBatchClipFailed(assetId: String?, reason: String) {
        guard let assetId, !assetId.isEmpty else { return }

        markBatchItemFailed(assetId: assetId, message: reason)

        var state =
            batchClipDisplayState(for: assetId)
            ?? BatchClipDisplayState(
                phase: .failed,
                progress: 1,
                mediasourceId: nil,
                mediasourceUrl: nil,
                formSlug: nil,
                errorText: nil
            )
        state.phase = .failed
        state.errorText = reason
        batchClipDisplayByAssetId[assetId] = state
    }

    private func markBatchItemFailed(assetId: String, message: String) {
        guard let index = batchItems.firstIndex(where: { $0.assetId == assetId }) else {
            return
        }

        markBatchItemFailed(index: index, message: message)

        if batchState != .partialFailed {
            batchState = .partialFailed
            persistBatchState()
        }
    }

    private func reconcileActiveWorkflowStateAfterReconnect() async {
        guard auth.isAuthenticated else { return }
        guard let assetId = currentAssetId ?? archive.assetId else { return }

        let request = auth.authenticatedRequest(for: ServerConfig.assetURL(assetId))
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else { return }

            let detail = try JSONDecoder().decode(AssetDetailResponse.self, from: data)
            let asset = detail.asset
            lastAsset = asset
            lastClip = asset.clips?.first
            assetDetailCache[asset.id] = asset

            clearBlockingConnectivityIssueIfNeeded(assetId: asset.id)
            reconcileWorkflowState(from: asset, source: .workflow)
        } catch {
            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(operation: "syncing workflow state", assetId: assetId)
            }
            print("⚠️ [Reconnect] State reconcile skipped: \(error.localizedDescription)")
        }
    }

    /// Central append gate for progressive messaging and dedupe policy.
    private func appendMessage(_ message: ChatMessage, source: MessagePolicyCoordinator.Source) {
        let shouldDebugCode = {
            guard let code = message.content.code else { return false }
            return code == "WS_FORM_CONFIRMED"
                || code == "IOS_MUX_READY_SUMMARY"
                || code == "IOS_MUX_READY_FOLLOWUP"
        }()

        guard messagePolicy.shouldPresent(message, source: source) else {
            if shouldDebugCode {
                let identity = message.assetId ?? message.content.mediasourceId ?? "n/a"
                print(
                    "⚠️ [Chat] Dropped message by policy: code=\(message.content.code ?? "n/a") source=\(source) target=\(identity)"
                )
            }
            return
        }

        messages.append(message)

        if hasActiveBatch && batchBubbleAnchorMessageId == nil {
            batchBubbleAnchorMessageId = message.id
        }

        if shouldDebugCode {
            let identity = message.assetId ?? message.content.mediasourceId ?? "n/a"
            print(
                "💬 [Chat] Appended message: code=\(message.content.code ?? "n/a") source=\(source) target=\(identity) total=\(messages.count)"
            )
        }
    }

    /// Show an error message to the user as a chat bubble.
    private func appendErrorBubble(
        _ text: String,
        assetId: String? = nil,
        code: String? = nil,
        params: [String: String]? = nil
    ) {
        let errorMsg = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: text,
                code: code,
                params: params,
                fallbackText: code == nil ? nil : text,
                schemaVersion: code == nil ? nil : MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(errorMsg, source: .error)
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
        let slackTargetAssetId = isSlackCommand ? activeSlackTargetAssetId() : nil
        let slackTargetAssetIds = isSlackCommand ? activeSlackTargetAssetIds() : nil

        // If Slack command but no current upload, tell user to upload first
        if isSlackCommand && slackTargetAssetId == nil && (slackTargetAssetIds?.isEmpty ?? true) {
            let localOut = ChatMessage(
                id: UUID().uuidString,
                userId: auth.currentUser?.id,
                assetId: nil,
                direction: .outgoing,
                messageType: .slackPost,
                content: MessageContent(text: text),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            appendMessage(localOut, source: .outgoing)
            let reply = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: nil,
                direction: .incoming,
                messageType: .text,
                content: MessageContent(
                    text:
                        "Upload a video first and I can grab the metadata so you can Slack it. Previous uploads are in your Archive, and you can Slack from there.",
                    code: "IOS_SLACK_REQUIRES_UPLOAD",
                    fallbackText:
                        "Upload a video first and I can grab the metadata so you can Slack it. Previous uploads are in your Archive, and you can Slack from there.",
                    schemaVersion: MessageCatalog.schemaVersion
                ),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            appendMessage(reply, source: .workflow)
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
        appendMessage(localMessage, source: .outgoing)

        let messageAssetId: String? = {
            if let currentAssetId, !currentAssetId.isEmpty {
                return currentAssetId
            }
            if let firstBatchAssetId = slackTargetAssetIds?.first {
                return firstBatchAssetId
            }
            if isSlackCommand {
                return slackTargetAssetId
            }
            return nil
        }()

        // Send via WebSocket — always pass explicit assetId so the server
        // doesn't fall back to "most recent READY asset" (wrong metadata bug).
        ws.sendMessage(
            text: text,
            assetId: messageAssetId,
            assetIds: isSlackCommand ? slackTargetAssetIds : nil
        )
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
                    throw NSError(
                        domain: "createAsset", code: statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Server returned \(statusCode)"])
                }

                let response = try JSONDecoder().decode(CreateAssetResponse.self, from: data)
                return response.asset
            }

            currentAssetId = asset.id
            _ = promoteStage(for: asset.id, to: .uploading)
            clearBlockingConnectivityIssueIfNeeded(assetId: asset.id)

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
            appendMessage(videoMessage, source: .outgoing)

            // Cache metadata so VideoBubble can render the card
            let uploadInfo = SentUploadInfo(
                thumbnail: form.thumbnail,
                fileName: fileName,
                createdDate: lastStagedCreatedDate ?? DVUDateFormatting.longDate(from: Date()),
                hasLocation: lastStagedHasLocation,
                transcribeEnabled: transcribeOnUpload
            )
            sentUploads[msgId] = uploadInfo
            sentUploadsByAssetId[asset.id] = uploadInfo

            // Notify WebSocket with real file size
            ws.sendVideoUpload(
                assetId: asset.id,
                fileName: fileName,
                fileSize: fileSize
            )

            return asset
        } catch {
            let errorDesc = error.localizedDescription
            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(operation: "starting upload", assetId: nil)
            } else {
                appendErrorBubble(
                    "Could not start upload. Please try again.",
                    code: "IOS_UPLOAD_START_FAILED"
                )
            }
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
            let muxResult = try await uploader.uploadViaMux(
                assetId: assetId, fileURL: fileURL, token: token, metadata: metadata)
            print(
                "✅ [Upload] Mux direct upload completed for asset: \(assetId), clipId: \(muxResult.clipId)"
            )
        } catch {
            print("❌ [Upload] Failed for asset \(assetId): \(error)")
            _ = promoteStage(for: assetId, to: .failed)
            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(operation: "uploading video", assetId: assetId)
            } else {
                appendErrorBubble(
                    "Upload failed: \(error.localizedDescription)",
                    assetId: assetId,
                    code: "IOS_UPLOAD_FAILED",
                    params: ["reason": error.localizedDescription]
                )
            }
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
        var request = auth.authenticatedRequest(
            for: ServerConfig.transcriptURL(assetId), method: "PATCH")

        // Encode segments as JSON array
        let segmentsData = try? JSONEncoder().encode(result.segments)
        let segmentsJSON = segmentsData.flatMap { try? JSONSerialization.jsonObject(with: $0) }

        let body: [String: Any] = [
            "transcript": result.text,
            "segments": segmentsJSON ?? [],
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
    func stageVideo(
        fileURL: URL, fileName: String, metadata: VideoMetadata, phAssetIdentifier: String? = nil
    ) async {
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

    /// Stage one or more selected videos. Single-item selection keeps the existing flow.
    func stageVideoBatch(selectedVideos: [SelectedVideo]) async {
        guard !selectedVideos.isEmpty else { return }

        if selectedVideos.count == 1, let single = selectedVideos.first {
            resetBatchState(clearDisk: true)
            await stageVideo(
                fileURL: single.fileURL,
                fileName: single.fileName,
                metadata: single.metadata,
                phAssetIdentifier: single.phAssetIdentifier
            )
            return
        }

        if isArchived || currentAssetId != nil {
            startNewConversation()
        }

        cancelStagedVideo()
        resetBatchState(clearDisk: true)

        currentBatchId = UUID().uuidString
        stagedBatchVideos = selectedVideos
        batchItems = selectedVideos.map {
            VideoBatchItem(localId: $0.id, fileName: $0.fileName, org: nil)
        }
        batchState = .queued
        batchProgress = 0
        isBatchUploading = false
        suppressPerAssetFormSheet = false
        awaitingGroupedFormForBatch = false
        pendingBatchFormData = nil
        batchBubbleAnchorMessageId = messages.last?.id
        batchContext = nil

        form.originalFileName = "\(selectedVideos.count) videos"
        form.capturedAt = selectedVideos.first?.metadata.capturedAt
        form.clipCount = selectedVideos.count
        form.duration = selectedVideos.reduce(0) { $0 + $1.metadata.duration }
        form.submitError = nil
        if let first = selectedVideos.first {
            form.thumbnail = await StagedVideo.generateThumbnail(from: first.fileURL)
        }

        persistBatchState()
    }

    /// Open the grouped context form for a staged batch.
    func confirmBatchUpload() async {
        guard !stagedBatchVideos.isEmpty else { return }
        guard !isBatchUploading else { return }
        awaitingGroupedFormForBatch = true
        formFields = buildFormFields()
        form.submitError = nil
        showFormSheet = true
    }

    /// Retry only failed batch items.
    func retryFailedBatchItems() async {
        guard canRetryFailedBatchItems else { return }
        await runBatchUpload(retryFailedOnly: true)
    }

    /// Entry-point for ContextFormView submits; routes to batch or single-asset flow.
    func submitCurrentForm(formData: [String: String]) async {
        if awaitingGroupedFormForBatch {
            awaitingGroupedFormForBatch = false
            pendingBatchFormData = formData
            batchContext = VideoBatchContext(
                slug: formData["slug"] ?? "",
                type: formData["type"] ?? "Raw",
                description: formData["description"] ?? "",
                priority: formData["priority"] ?? "Low",
                destination: formData["destination"],
                org: formData["org"]
            )
            persistBatchState()
            showFormSheet = false
            await uploadBatchItemsSequentialOrBoundedConcurrency()
            return
        }

        guard let assetId = currentAssetId else { return }
        await submitForm(assetId: assetId, formData: formData)
    }

    /// Run the staged batch upload queue.
    func uploadBatchItemsSequentialOrBoundedConcurrency() async {
        await runBatchUpload(retryFailedOnly: false)
    }

    /// Apply one grouped form payload to a specific asset.
    func applyGroupedFormToAsset(assetId: String) async -> Bool {
        guard let formData = buildSequencedBatchFormData(for: assetId) else { return false }
        return await submitGroupedFormPayload(assetId: assetId, formData: formData)
    }

    /// Cancel a staged batch before upload starts.
    func cancelStagedBatch() {
        resetBatchState(clearDisk: true)
        showFormSheet = false
    }

    private func runBatchUpload(retryFailedOnly: Bool) async {
        guard !isBatchUploading else { return }
        guard !batchItems.isEmpty else { return }
        guard pendingBatchFormData != nil else { return }

        isBatchUploading = true
        suppressPerAssetFormSheet = true
        batchState = .uploading
        form.submitError = nil
        persistBatchState()

        let localIds = batchCoordinator.executionOrder(
            for: batchItems, retryFailedOnly: retryFailedOnly)
        let chunks = batchCoordinator.chunked(localIds)

        for chunk in chunks {
            await withTaskGroup(of: Void.self) { group in
                for localId in chunk {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.processBatchItem(localId: localId)
                    }
                }
            }
        }

        isBatchUploading = false
        suppressPerAssetFormSheet = false
        batchProgress = computeBatchProgress()

        let failedCount = batchItems.filter { $0.status == .failed }.count
        batchState = failedCount > 0 ? .partialFailed : .complete

        if failedCount == 0 {
            stagedBatchVideos.removeAll()
            pendingBatchFormData = nil
            if let currentBatchId {
                PendingBatchStore.clear(batchId: currentBatchId)
            }
        } else {
            persistBatchState()
        }

        appendBatchCompletionMessages()
    }

    private func appendBatchCompletionMessages() {
        guard !batchItems.isEmpty else { return }

        let confirmedItems = batchItems.filter { $0.status == .complete }
        let unconfirmedItems = batchItems.filter { $0.status != .complete }

        let summaryText = buildBatchCompletionSummaryText(
            confirmedItems: confirmedItems,
            unconfirmedItems: unconfirmedItems
        )

        let summaryMessage = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: nil,
            direction: .incoming,
            messageType: .systemNote,
            content: MessageContent(
                text: summaryText,
                code: "IOS_BATCH_SUMMARY",
                fallbackText: summaryText,
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(summaryMessage, source: .workflow)

        let highFiveText: String
        if unconfirmedItems.isEmpty {
            highFiveText = "High five. Batch upload complete."
        } else if !confirmedItems.isEmpty {
            highFiveText = "High five. Most clips landed, and I flagged what needs attention."
        } else {
            highFiveText = "High five for sticking with it. This batch needs a retry pass."
        }

        let highFiveMessage = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: nil,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: highFiveText,
                code: "IOS_BATCH_HIGH_FIVE",
                params: [
                    "confirmedCount": "\(confirmedItems.count)",
                    "failedCount": "\(unconfirmedItems.count)",
                ],
                fallbackText: highFiveText,
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(highFiveMessage, source: .workflow)

        let firstName = auth.currentUser?.name.components(separatedBy: " ").first ?? "there"
        let closingFallback =
            "\(firstName), you can Slack updates from this chat with #channel or @person, and I am ready for your next upload."
        let closingMessage = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: nil,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: closingFallback,
                code: "IOS_BATCH_CLOSING",
                params: [
                    "firstName": firstName,
                    "confirmedCount": "\(confirmedItems.count)",
                    "failedCount": "\(unconfirmedItems.count)",
                ],
                fallbackText: closingFallback,
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(closingMessage, source: .workflow)
    }

    private func buildBatchCompletionSummaryText(
        confirmedItems: [VideoBatchItem],
        unconfirmedItems: [VideoBatchItem]
    ) -> String {
        var lines: [String] = []
        lines.append("Batch Summary")

        for item in confirmedItems {
            let msToken: String = {
                guard let assetId = item.assetId,
                    let state = batchClipDisplayState(for: assetId),
                    let msId = state.mediasourceId,
                    !msId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    return "MS# pending"
                }
                return "MS# \(msId)"
            }()

            let msColumn = msToken.padding(toLength: 14, withPad: " ", startingAt: 0)
            lines.append("🔗 \(msColumn) \(item.fileName)")
        }

        if !unconfirmedItems.isEmpty {
            lines.append("")
            lines.append("Unverified (\(unconfirmedItems.count))")

            for item in unconfirmedItems {
                let reason =
                    (item.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        == false)
                    ? item.error! : "Needs retry"
                lines.append("⚠️ \(item.fileName) • \(reason)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func processBatchItem(localId: String) async {
        guard let itemIndex = batchItems.firstIndex(where: { $0.localId == localId }) else {
            return
        }
        guard let selected = stagedBatchVideos.first(where: { $0.id == localId }) else {
            markBatchItemFailed(index: itemIndex, message: "Clip reference was lost.")
            return
        }

        batchItems[itemIndex].status = .creatingAsset
        batchItems[itemIndex].error = nil
        batchItems[itemIndex].progress = 0
        batchProgress = computeBatchProgress()
        persistBatchState()

        let thumbnail = await StagedVideo.generateThumbnail(from: selected.fileURL)
        let createdDate = selected.metadata.capturedAt.map { DVUDateFormatting.longDate($0) }

        guard
            let asset = await createBatchAsset(
                fileName: selected.fileName,
                fileURL: selected.fileURL,
                thumbnail: thumbnail,
                createdDate: createdDate,
                hasLocation: selected.metadata.gpsLat != nil,
                phAssetIdentifier: selected.phAssetIdentifier
            )
        else {
            markBatchItemFailed(index: itemIndex, message: "Could not create upload asset.")
            return
        }

        guard let updatedIndex = batchItems.firstIndex(where: { $0.localId == localId }) else {
            return
        }
        batchItems[updatedIndex].assetId = asset.id
        batchItems[updatedIndex].status = .uploading
        batchItems[updatedIndex].progress = 0
        setBatchClipPhase(assetId: asset.id, phase: .uploading)
        updateBatchClipProgress(assetId: asset.id, progress: 0)
        batchProgress = computeBatchProgress()
        persistBatchState()

        let didUpload = await uploadBatchVideo(
            assetId: asset.id,
            fileURL: selected.fileURL,
            metadata: selected.metadata,
            onProgress: { [weak self] progress in
                guard let self else { return }
                guard let index = self.batchItems.firstIndex(where: { $0.localId == localId })
                else {
                    return
                }
                // Reserve final progress for grouped-form apply so the UI has clear phase transitions.
                self.batchItems[index].progress = min(max(progress, 0), 0.95)
                self.updateBatchClipProgress(
                    assetId: self.batchItems[index].assetId,
                    progress: self.batchItems[index].progress
                )
                self.batchProgress = self.computeBatchProgress()
            }
        )
        if !didUpload {
            if let index = batchItems.firstIndex(where: { $0.localId == localId }),
                batchItems[index].status != .failed
            {
                markBatchItemFailed(index: index, message: "Upload failed.")
            }
            return
        }

        setBatchClipPhase(assetId: asset.id, phase: .processing)

        guard let formIndex = batchItems.firstIndex(where: { $0.localId == localId }) else {
            return
        }
        batchItems[formIndex].status = .applyingForm
        batchItems[formIndex].progress = 0.97
        setBatchClipPhase(assetId: asset.id, phase: .processing)
        updateBatchClipProgress(assetId: asset.id, progress: 0.97)
        batchProgress = computeBatchProgress()
        persistBatchState()

        let didApplyForm = await applyGroupedFormToAsset(assetId: asset.id)
        if !didApplyForm {
            if let index = batchItems.firstIndex(where: { $0.localId == localId }) {
                markBatchItemFailed(index: index, message: "Could not apply grouped form.")
            }
            return
        }

        guard let completeIndex = batchItems.firstIndex(where: { $0.localId == localId }) else {
            return
        }
        batchItems[completeIndex].status = .complete
        batchItems[completeIndex].progress = 1
        updateBatchClipProgress(assetId: asset.id, progress: 1)
        cleanupTempFileIfNeeded(selected.fileURL)

        batchProgress = computeBatchProgress()
        persistBatchState()
    }

    private func createBatchAsset(
        fileName: String,
        fileURL: URL,
        thumbnail: UIImage?,
        createdDate: String?,
        hasLocation: Bool,
        phAssetIdentifier: String?
    ) async -> Asset? {
        var request = auth.authenticatedRequest(for: ServerConfig.assetsURL, method: "POST")
        let body = CreateAssetRequest(fileName: fileName)
        request.httpBody = try? JSONEncoder().encode(body)

        let fileSize: Int64 = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            return attrs?[.size] as? Int64 ?? 0
        }()

        do {
            let asset = try await withRetry(attempts: 3) { _ in
                let (data, httpResponse) = try await URLSession.shared.data(for: request)
                let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0

                guard statusCode >= 200, statusCode < 300 else {
                    let body = String(data: data, encoding: .utf8) ?? "(empty)"
                    print("❌ createBatchAsset HTTP \(statusCode): \(body)")
                    throw NSError(
                        domain: "createBatchAsset", code: statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Server returned \(statusCode)"])
                }

                let response = try JSONDecoder().decode(CreateAssetResponse.self, from: data)
                return response.asset
            }

            currentAssetId = asset.id
            _ = promoteStage(for: asset.id, to: .uploading)
            clearBlockingConnectivityIssueIfNeeded(assetId: asset.id)

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
            appendMessage(videoMessage, source: .outgoing)

            let uploadInfo = SentUploadInfo(
                thumbnail: thumbnail,
                fileName: fileName,
                createdDate: createdDate ?? DVUDateFormatting.longDate(from: Date()),
                hasLocation: hasLocation,
                transcribeEnabled: false
            )
            sentUploads[msgId] = uploadInfo
            sentUploadsByAssetId[asset.id] = uploadInfo
            setBatchClipPhase(assetId: asset.id, phase: .uploading)
            updateBatchClipProgress(assetId: asset.id, progress: 0)

            if let phAssetIdentifier {
                PHAssetIdentifierStore.save(assetId: asset.id, phAssetIdentifier: phAssetIdentifier)
            }

            ws.sendVideoUpload(assetId: asset.id, fileName: fileName, fileSize: fileSize)
            return asset
        } catch {
            let errorDesc = error.localizedDescription
            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(operation: "starting upload", assetId: nil)
            } else {
                appendErrorBubble(
                    "Could not start batch upload. Please try again.",
                    code: "IOS_BATCH_UPLOAD_START_FAILED"
                )
            }
            Task {
                await reportError(
                    category: "upload",
                    message: "Batch asset creation failed after 3 attempts: \(errorDesc)",
                    severity: "ERROR",
                    details: ["fileName": fileName]
                )
            }
            return nil
        }
    }

    private func uploadBatchVideo(
        assetId: String,
        fileURL: URL,
        metadata: VideoMetadata,
        onProgress: @escaping (Double) -> Void
    ) async -> Bool {
        guard let token = auth.token else { return false }
        let uploader = VideoUploadService()

        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                onProgress(uploader.uploadProgress)
                if !uploader.isUploading {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        do {
            let muxResult = try await uploader.uploadViaMux(
                assetId: assetId,
                fileURL: fileURL,
                token: token,
                metadata: metadata
            )
            print(
                "✅ [Batch Upload] Mux direct upload completed for asset: \(assetId), clipId: \(muxResult.clipId)"
            )
            onProgress(0.95)
            progressTask.cancel()
            return true
        } catch {
            print("❌ [Batch Upload] Failed for asset \(assetId): \(error)")
            _ = promoteStage(for: assetId, to: .failed)
            markBatchClipFailed(assetId: assetId, reason: error.localizedDescription)
            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(operation: "uploading video", assetId: assetId)
            } else {
                // Batch clips surface failure directly on their own upload cards.
            }
            Task {
                await reportError(
                    category: "upload",
                    message: "Batch file upload failed: \(error.localizedDescription)",
                    severity: "ERROR",
                    assetId: assetId
                )
            }
            progressTask.cancel()
            return false
        }
    }

    private enum GroupedFormDebugEvent {
        case attempt
        case suppressedFormRequest
        case success
        case failure
    }

    private var isGroupedFormSubmitDebugEnabled: Bool {
        #if DEBUG
            if let envRaw = ProcessInfo.processInfo.environment["DVU_DEBUG_GROUPED_FORM_SUBMITS"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !envRaw.isEmpty
            {
                return Self.groupedFormDebugTruthyValues.contains(envRaw)
            }
            return UserDefaults.standard.bool(forKey: UserDefaultsKeys.debugGroupedFormSubmits)
        #else
            return false
        #endif
    }

    private func debugLogGroupedFormSubmit(
        assetId: String,
        event: GroupedFormDebugEvent,
        formData: [String: String]? = nil,
        statusCode: Int? = nil,
        error: Error? = nil
    ) {
        guard isGroupedFormSubmitDebugEnabled else { return }

        switch event {
        case .attempt:
            let nextAttempt = (groupedFormSubmitAttemptCountByAssetId[assetId] ?? 0) + 1
            groupedFormSubmitAttemptCountByAssetId[assetId] = nextAttempt
            let slug = formData?["slug"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            print(
                "[GroupedFormDebug] submit attempt #\(nextAttempt) assetId=\(assetId) slug=\"\(slug)\""
            )

        case .suppressedFormRequest:
            let attempts = groupedFormSubmitAttemptCountByAssetId[assetId] ?? 0
            print(
                "[GroupedFormDebug] ws form:request suppressed assetId=\(assetId) attempts=\(attempts)"
            )

        case .success:
            let attempts = groupedFormSubmitAttemptCountByAssetId[assetId] ?? 0
            let status = statusCode.map(String.init) ?? "n/a"
            print(
                "[GroupedFormDebug] submit success assetId=\(assetId) attempt=\(attempts) status=\(status)"
            )

        case .failure:
            let attempts = groupedFormSubmitAttemptCountByAssetId[assetId] ?? 0
            let status = statusCode.map(String.init) ?? "n/a"
            let reason = error?.localizedDescription ?? "unknown"
            print(
                "[GroupedFormDebug] submit failure assetId=\(assetId) attempt=\(attempts) status=\(status) error=\(reason)"
            )
        }
    }

    private func submitGroupedFormPayload(assetId: String, formData: [String: String]) async -> Bool
    {
        debugLogGroupedFormSubmit(assetId: assetId, event: .attempt, formData: formData)

        var request = auth.authenticatedRequest(for: ServerConfig.formURL(assetId), method: "POST")
        request.httpBody = try? JSONSerialization.data(withJSONObject: formData)
        var responseStatusCode: Int?

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            responseStatusCode = statusCode
            guard statusCode >= 200, statusCode < 300 else {
                throw URLError(.badServerResponse)
            }
            debugLogGroupedFormSubmit(assetId: assetId, event: .success, statusCode: statusCode)
            clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
            return true
        } catch {
            debugLogGroupedFormSubmit(
                assetId: assetId,
                event: .failure,
                statusCode: responseStatusCode,
                error: error
            )
            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(operation: "applying grouped form", assetId: assetId)
            }
            Task {
                await reportError(
                    category: "form",
                    message: "Grouped form apply failed: \(error.localizedDescription)",
                    severity: "ERROR",
                    assetId: assetId
                )
            }
            return false
        }
    }

    private func buildSequencedBatchFormData(for assetId: String) -> [String: String]? {
        guard var formData = pendingBatchFormData else { return nil }
        guard batchItems.count > 1 else { return formData }
        guard let itemIndex = batchItems.firstIndex(where: { $0.assetId == assetId }) else {
            return formData
        }

        let sequenceNumber = itemIndex + 1
        let baseTitle = (formData["slug"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseTitle.isEmpty {
            formData["slug"] = makeSequencedTitle(
                baseTitle: baseTitle, sequenceNumber: sequenceNumber)
        }

        return formData
    }

    private func makeSequencedTitle(baseTitle: String, sequenceNumber: Int) -> String {
        let trimmed = baseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")

        if parts.count > 1, let trailingNumber = Int(parts.last ?? ""), trailingNumber > 0 {
            let root = parts.dropLast().joined(separator: " ")
            return "\(root) \(sequenceNumber)"
        }

        return "\(trimmed) \(sequenceNumber)"
    }

    private func markBatchItemFailed(index: Int, message: String) {
        guard batchItems.indices.contains(index) else { return }
        let assetId = batchItems[index].assetId
        batchItems[index].status = .failed
        batchItems[index].error = message
        batchItems[index].progress = 0
        batchProgress = computeBatchProgress()

        if batchState != .partialFailed {
            batchState = .partialFailed
        }

        if let assetId {
            var state =
                batchClipDisplayState(for: assetId)
                ?? BatchClipDisplayState(
                    phase: .failed,
                    progress: 1,
                    mediasourceId: nil,
                    mediasourceUrl: nil,
                    formSlug: nil,
                    errorText: nil
                )
            state.phase = .failed
            state.errorText = message
            batchClipDisplayByAssetId[assetId] = state
        }

        persistBatchState()
    }

    private func computeBatchProgress() -> Double {
        guard !batchItems.isEmpty else { return 0 }
        let total = batchItems.reduce(0) { partial, item in
            partial + min(max(item.progress, 0), 1)
        }
        return total / Double(batchItems.count)
    }

    private func persistBatchState() {
        guard let currentBatchId else { return }
        let snapshot = VideoBatch(
            id: currentBatchId,
            createdAt: Date(),
            state: batchState,
            items: batchItems,
            context: batchContext,
            stagedVideos: stagedBatchVideos.isEmpty ? nil : stagedBatchVideos,
            groupedFormData: pendingBatchFormData
        )
        PendingBatchStore.save(snapshot)
    }

    private func restorePendingBatchState() {
        guard let pending = PendingBatchStore.loadLatest() else { return }
        if pending.state == .complete {
            PendingBatchStore.clear(batchId: pending.id)
            return
        }

        currentBatchId = pending.id
        batchItems = pending.items
        batchContext = pending.context
        stagedBatchVideos = pending.stagedVideos ?? []
        pendingBatchFormData = pending.groupedFormData
        batchState = pending.state
        isBatchUploading = false
        suppressPerAssetFormSheet = false
        awaitingGroupedFormForBatch = false
        if batchBubbleAnchorMessageId == nil {
            batchBubbleAnchorMessageId = messages.last?.id
        }

        let hasRecoveryInputs = !stagedBatchVideos.isEmpty && pendingBatchFormData != nil

        if hasRecoveryInputs && (pending.state == .uploading || pending.state == .paused) {
            for index in batchItems.indices where batchItems[index].status != .complete {
                batchItems[index].status = .failed
                if batchItems[index].error?.isEmpty ?? true {
                    batchItems[index].error =
                        "Upload interrupted by app restart. Tap Retry Failed."
                }
                batchItems[index].progress = 0
            }
            batchState = .partialFailed
        } else if !hasRecoveryInputs, pending.state != .queued {
            // Older snapshots may not include enough data to retry; keep the batch clearable.
            batchState = .paused
        }

        batchProgress = computeBatchProgress()

        if batchItems.allSatisfy({ $0.status == .complete }) {
            PendingBatchStore.clear(batchId: pending.id)
            return
        }

        persistBatchState()
    }

    private func resetBatchState(clearDisk: Bool) {
        let batchIdToClear = currentBatchId
        let videosToCleanup = stagedBatchVideos

        for video in videosToCleanup {
            cleanupTempFileIfNeeded(video.fileURL)
        }

        currentBatchId = nil
        stagedBatchVideos.removeAll()
        batchItems.removeAll()
        batchContext = nil
        batchProgress = 0
        isBatchUploading = false
        suppressPerAssetFormSheet = false
        batchState = .queued
        pendingBatchFormData = nil
        awaitingGroupedFormForBatch = false
        groupedFormSubmitAttemptCountByAssetId.removeAll()
        batchBubbleAnchorMessageId = nil

        if clearDisk, let batchIdToClear {
            PendingBatchStore.clear(batchId: batchIdToClear)
        }
    }

    private func cleanupTempFileIfNeeded(_ url: URL) {
        let tempDir = FileManager.default.temporaryDirectory.path
        if url.path.hasPrefix(tempDir) {
            cleanupTempFile(url)
        }
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
            guard let asset = await createAsset(fileName: fileName, fileURL: fileURL) else {
                return
            }
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
        if let assetId = currentAssetId {
            _ = promoteStage(for: assetId, to: .failed)
        }
        appendErrorBubble("Upload cancelled.", code: "IOS_UPLOAD_CANCELLED")
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

    /// Parse dynamic payload params into a string-only dictionary for template rendering.
    private func parseStringParams(_ value: Any?) -> [String: String]? {
        guard let dict = value as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (key, raw) in dict {
            switch raw {
            case let s as String:
                out[key] = s
            case let b as Bool:
                out[key] = b ? "true" : "false"
            case let n as NSNumber:
                out[key] = n.stringValue
            default:
                continue
            }
        }
        return out.isEmpty ? nil : out
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
            content: MessageContent(
                text: "Transcribing audio...",
                code: "IOS_TRANSCRIBE_START",
                fallbackText: "Transcribing audio...",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(transcribingMsg, source: .workflow)

        if let result = await transcriber.transcribe(videoURL: fileURL) {
            await sendTranscript(assetId: assetId, result: result)
            updateTranscriptionBubble(
                id: transcribingMsg.id, assetId: assetId,
                text:
                    "Transcript sent to Mediasource. (\(result.segments.count) words.) Transcript is available in Archive.",
                code: "IOS_TRANSCRIBE_SUCCESS",
                params: ["wordCount": "\(result.segments.count)"],
                createdAt: transcribingMsg.createdAt)
        } else {
            let statusText: String
            let statusCode: String
            var statusParams: [String: String]? = nil
            switch transcriber.state {
            case .noSpeech:
                statusText = "No clear audio detected in video."
                statusCode = "IOS_TRANSCRIBE_NO_SPEECH"
            case .failed(let reason):
                statusText = "Transcription failed: \(reason)"
                statusCode = "IOS_TRANSCRIBE_FAILED"
                statusParams = ["reason": reason]
            default:
                statusText = "Transcription did not produce results."
                statusCode = "IOS_TRANSCRIBE_EMPTY"
            }
            updateTranscriptionBubble(
                id: transcribingMsg.id, assetId: assetId,
                text: statusText,
                code: statusCode,
                params: statusParams,
                createdAt: transcribingMsg.createdAt)
        }
    }

    /// Replace the content of a transcription status bubble.
    private func updateTranscriptionBubble(
        id: String,
        assetId: String,
        text: String,
        code: String? = nil,
        params: [String: String]? = nil,
        createdAt: String?
    ) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx] = ChatMessage(
                id: id, userId: nil, assetId: assetId,
                direction: .incoming, messageType: .text,
                content: MessageContent(
                    text: text,
                    code: code,
                    params: params,
                    fallbackText: code == nil ? nil : text,
                    schemaVersion: code == nil ? nil : MessageCatalog.schemaVersion
                ),
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
        if awaitingGroupedFormForBatch {
            showFormSheet = false
            form.submitError = nil
            resetBatchState(clearDisk: true)
            return
        }

        showFormSheet = false
        isArchived = true

        // Add a chat bubble confirming the skip
        let msg = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: currentAssetId,
            direction: .incoming,
            messageType: .systemNote,
            content: MessageContent(
                text:
                    "No worries. Your video is still uploading. You can add details from your Archive anytime.",
                code: "IOS_FORM_SKIPPED",
                fallbackText:
                    "No worries. Your video is still uploading. You can add details from your Archive anytime.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(msg, source: .workflow)
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
            clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
        } catch {
            print("❌ Failed to submit form:", error)
            // Keep form open so user can retry — show error in chat too
            form.submitError = "Failed to send form. Please try again."
            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(
                    operation: "submitting form details", assetId: assetId)
            } else {
                appendErrorBubble(
                    "Form submission failed. The form is still open. Please retry.",
                    assetId: assetId,
                    code: "IOS_FORM_SUBMIT_FAILED"
                )
            }
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
        workflowStages.removeAll()
        messagePolicy.resetForFreshConnection()
        hasBlockingConnectivityIssue = false
        blockingConnectivityAssetId = nil
        // Fresh conversation — clear old messages
        messages.removeAll()
        batchBubbleAnchorMessageId = nil
        batchClipDisplayByAssetId.removeAll()
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
            self.assetDetailCache[response.asset.id] = response.asset
            clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
            reconcileWorkflowState(from: response.asset, source: .workflow)
        } catch {
            print("❌ Failed to fetch asset detail:", error)
            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(operation: "syncing metadata", assetId: assetId)
            } else {
                appendErrorBubble(
                    "Could not load video details.",
                    assetId: assetId,
                    code: "IOS_ASSET_DETAILS_LOAD_FAILED"
                )
            }
        }
    }

    private func metadataThumbnail(for assetId: String?) -> UIImage? {
        guard let assetId, !assetId.isEmpty else {
            return form.thumbnail
        }
        return sentUploadsByAssetId[assetId]?.thumbnail ?? form.thumbnail
    }

    func showMetadata(for assetId: String? = nil) {
        let targetAssetId = assetId ?? currentAssetId ?? archive.assetId

        if let targetAssetId,
            let cachedAsset = assetDetailCache[targetAssetId]
        {
            lastAsset = cachedAsset
            lastClip = cachedAsset.clips?.first
            metadataSheetThumbnail = metadataThumbnail(for: targetAssetId)
            guard lastClip != nil else { return }
            showMetadataSheet = true
            return
        }

        if let targetAssetId {
            metadataSheetThumbnail = metadataThumbnail(for: targetAssetId)
            Task { @MainActor in
                await fetchAssetDetail(assetId: targetAssetId)
                metadataSheetThumbnail = metadataThumbnail(for: targetAssetId)
                showMetadataSheet = lastClip != nil
            }
            return
        }

        guard lastClip != nil else { return }
        metadataSheetThumbnail = form.thumbnail
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
                    let json = try? JSONDecoder().decode(AssetDetailResponse.self, from: data)
                {
                    if json.asset.formResponse != nil {
                        // Form already submitted — clear
                        print(
                            "🔄 [Recovery] Form already submitted for \(pendingForm.assetId) — clearing"
                        )
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

        // Reconcile immediately after restoring pending form so relaunches after
        // force-quit can catch up missed state changes without waiting for another reconnect.
        Task { @MainActor in
            await reconcileActiveWorkflowStateAfterReconnect()
        }
    }

    /// Build the standard form fields (used for both live and recovery).
    private func buildFormFields() -> [FormField] {
        FormField.defaultVideoFields()
    }

    // MARK: - Archive / New Conversation

    /// Clear current conversation and start fresh for a new upload.
    func startNewConversation() {
        resetBatchState(clearDisk: true)
        workflowStages.removeAll()
        messagePolicy.resetForNewConversation()
        hasBlockingConnectivityIssue = false
        blockingConnectivityAssetId = nil
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
        metadataSheetThumbnail = nil
        showSlackShareSheet = false
        sentUploads.removeAll()
        batchClipDisplayByAssetId.removeAll()
        sentUploadsByAssetId.removeAll()
        slackThumbnails.removeAll()
        slackConfirmedIds.removeAll()
        assetDetailCache.removeAll()
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
            content: MessageContent(
                text: "Hey \(firstName). Upload away.",
                code: "IOS_GREETING_NEW_CONVERSATION",
                params: ["firstName": firstName],
                fallbackText: "Hey \(firstName). Upload away.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(greeting, source: .workflow)
    }

    /// Send a Slack share for the archived asset.
    func shareToSlack(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let archiveAssetId = archive.assetId, !archiveAssetId.isEmpty else {
            appendErrorBubble(
                "Upload a video first and I can grab the metadata so you can Slack it. Previous uploads are in your Archive, and you can Slack from there.",
                code: "IOS_SLACK_REQUIRES_UPLOAD"
            )
            return
        }

        // Optimistic UI — add Slack post message locally
        let localMessage = ChatMessage(
            id: UUID().uuidString,
            userId: auth.currentUser?.id,
            assetId: archiveAssetId,
            direction: .outgoing,
            messageType: .slackPost,
            content: MessageContent(text: text),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(localMessage, source: .outgoing)
        showSlackShareSheet = false

        // Send via WebSocket — server detects #channel/@mention pattern
        ws.sendMessage(text: text, assetId: archiveAssetId, assetIds: activeSlackTargetAssetIds())
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
