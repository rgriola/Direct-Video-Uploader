// May 14, 2026 - 2:30pm - GitHub Copilot (Claude Opus 4.7)
import Foundation
import Observation
import UIKit

/// Central chat view model — manages messages, assets, and coordinates services.
@MainActor
@Observable
final class ChatViewModel: WebSocketConnectionStateRuntime, WebSocketEventRuntime
{
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
    private var batchBubbleAnchorMessageId: String?
    private var batchClipDisplayByAssetId: [String: BatchClipDisplayState] = [:]
    private var sentUploadsByAssetId: [String: SentUploadInfo] = [:]
    private var assetDetailCache: [String: Asset] = [:]
    private let messagePolicy = MessagePolicyCoordinator()
    private let batchCoordinator = VideoBatchUploadCoordinator(maxConcurrentUploads: 2)
    private let chatOwnership = ChatOwnershipRouter(maxArchivedAssetOwnership: 250)
    private let assetDetailService = AssetDetailService()
    private let assetDetailSyncService = AssetDetailSyncService()
    private let connectivityIssues = ConnectivityIssueTracker()
    private let serverErrorReporter = ServerErrorReporter()
    private let uploadQueueRecovery = UploadQueueRecoveryService()
    private let uploadQueueRehydratePlanService = UploadQueueRehydratePlanService()
    private let uploadQueueRehydrateExecutionService = UploadQueueRehydrateExecutionService()
    private let pendingFormRecovery = PendingFormRecoveryService()
    private let pendingBatchRestoreService = PendingBatchRestoreService()
    private let batchStateTransitionService = BatchStateTransitionService()
    private let workflowStageTracker = WorkflowStageTracker()
    private let batchClipDisplayService = BatchClipDisplayService()
    private let batchCompletionMessageService = BatchCompletionMessageService()
    private let batchItemStateService = BatchItemStateService()
    private let batchItemLifecycleService = BatchItemLifecycleService()
    private let batchItemExecutionService = BatchItemExecutionService()
    private let batchItemProcessingService = BatchItemProcessingService()
    private let groupedFormService = GroupedFormService()
    private let batchUploadTransportService = BatchUploadTransportService()
    private let batchAssetPresentationService = BatchAssetPresentationService()
    private let batchAssetFlowService = BatchAssetFlowService()
    private let webSocketMessageEventService = WebSocketMessageEventService()
    private let webSocketConnectionStateService = WebSocketConnectionStateService()
    private let webSocketUploadLifecycleEventService = WebSocketUploadLifecycleEventService()
    private let webSocketFormRequestEventService = WebSocketFormRequestEventService()
    private let webSocketFormConfirmedEventService = WebSocketFormConfirmedEventService()
    private let webSocketStreamReadyEventService = WebSocketStreamReadyEventService()
    private let readyWorkflowStateService = ReadyWorkflowStateService()
    private let workflowReconcilePlanService = WorkflowReconcilePlanService()
    private let workflowReconcileExecutionService = WorkflowReconcileExecutionService()
    private let batchRunExecutionService = BatchRunExecutionService()
    private let singleUploadFlowService = SingleUploadFlowService()
    private let conversationResetService = ConversationResetService()
    private let formSubmissionService = FormSubmissionService()
    private let transcriptSubmissionService = TranscriptSubmissionService()
    private let textMessageFlowService = TextMessageFlowService()
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
        rehydratePersistedUploadQueueState()
    }

    // MARK: - WebSocket Handlers

    private func setupWebSocketHandlers() {
        registerOnMessageHandler()
        registerOnUploadCompleteHandler()
        registerOnFormRequestHandler()
        registerOnFormConfirmedHandler()
        registerOnStreamReadyHandler()
        registerOnStreamErroredHandler()
    }

    private func shouldSuppressMutation(assetId: String?, event: String) -> Bool {
        chatOwnership.shouldSuppressChatMutation(
            for: assetId,
            currentAssetId: currentAssetId,
            hasActiveBatch: hasActiveBatch,
            isBatchAssetId: { self.isBatchAssetId($0) },
            event: event,
            log: { self.debugLogChatOwnership($0) }
        )
    }

    private func registerOnMessageHandler() {
        ws.onMessage = { [weak self] message in
            guard let self else { return }

            self.webSocketMessageEventService.handle(message: message, runtime: self)
        }
    }

    private func registerOnUploadCompleteHandler() {
        ws.onUploadComplete = { [weak self] data in
            guard let self else { return }
            self.webSocketUploadLifecycleEventService.handleUploadComplete(data: data, runtime: self)
        }
    }

    private func registerOnFormRequestHandler() {
        ws.onFormRequest = { [weak self] data in
            guard let self else { return }

            self.webSocketFormRequestEventService.handle(
                data: data,
                suppressPerAssetFormSheet: self.suppressPerAssetFormSheet,
                runtime: self
            )
        }
    }

    private func registerOnFormConfirmedHandler() {
        ws.onFormConfirmed = { [weak self] data in
            guard let self else { return }
            self.webSocketFormConfirmedEventService.handle(data: data, runtime: self)
        }
    }

    private func registerOnStreamReadyHandler() {
        ws.onStreamReady = { [weak self] data in
            guard let self else { return }

            self.webSocketStreamReadyEventService.handle(data: data, runtime: self)
        }
    }

    private func registerOnStreamErroredHandler() {
        ws.onStreamErrored = { [weak self] data in
            guard let self else { return }

            self.webSocketUploadLifecycleEventService.handleStreamErrored(data: data, runtime: self)
        }
    }

    // MARK: - Connection State Handlers

    private func setupConnectionHandlers() {
        ws.onConnected = { [weak self] in
            guard let self else { return }
            self.webSocketConnectionStateService.handleConnected(runtime: self)
        }

        ws.onReconnecting = { [weak self] attempt, maxAttempts in
            guard let self else { return }
            self.webSocketConnectionStateService.handleReconnecting(
                attempt: attempt,
                maxAttempts: maxAttempts,
                warningThreshold: self.reconnectWarningThreshold,
                runtime: self
            )
        }

        ws.onConnectionLost = { [weak self] in
            guard let self else { return }
            self.webSocketConnectionStateService.handleConnectionLost(runtime: self)
        }
    }

    // MARK: - Error Helpers

    private func noteBlockingConnectivityIssue(operation: String, assetId: String?) {
        guard
            let connectivityMessage = connectivityIssues.noteBlockingIssue(
                operation: operation,
                assetId: assetId
            )
        else { return }

        appendMessage(connectivityMessage, source: .workflow)
    }

    private func clearBlockingConnectivityIssueIfNeeded(assetId: String?) {
        guard
            let recoveredMessage = connectivityIssues.clearBlockingIssueIfNeeded(assetId: assetId)
        else { return }

        appendMessage(recoveredMessage, source: .workflow)
    }

    private func debugLogChatOwnership(_ message: String) {
        #if DEBUG
            AppLog.chat.debug("\(message)")
        #endif
    }

    private func promoteWorkflowStage(for assetId: String?, to stage: WorkflowStage) -> WorkflowStage {
        let previous = workflowStageTracker.promote(assetId: assetId, to: stage)

        if stage == .failed,
            previous != .failed,
            let assetId,
            !assetId.isEmpty
        {
            messagePolicy.resetAssetScope(assetId: assetId)
        }

        return previous
    }

    func wsShouldSuppressMutation(assetId: String?, event: String) -> Bool {
        shouldSuppressMutation(assetId: assetId, event: event)
    }

    func wsShouldWarnReconnectAttempt(attempt: Int, threshold: Int) -> Bool {
        attempt >= threshold
    }

    func wsReconcileActiveWorkflowStateAfterReconnect() async {
        await reconcileActiveWorkflowStateAfterReconnect()
    }

    func wsReportWebSocketReconnecting(attempt: Int, maxAttempts: Int) async {
        await reportError(
            category: "websocket",
            message: "WebSocket reconnecting (attempt \(attempt)/\(maxAttempts))",
            severity: "WARNING"
        )
    }

    func wsReportWebSocketConnectionLost() async {
        await reportError(
            category: "websocket",
            message: "WebSocket max reconnect attempts exhausted — connection lost",
            severity: "CRITICAL"
        )
    }

    func wsClearBlockingConnectivityIssue(assetId: String?) {
        clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
    }

    func wsRegisterActiveAsset(assetId: String?) {
        chatOwnership.registerActiveAsset(assetId)
    }

    func wsSetCurrentAssetId(_ assetId: String?) {
        currentAssetId = assetId
    }

    func wsPromoteFormRequestedStage(assetId: String) {
        _ = promoteWorkflowStage(for: assetId, to: .formRequested)
    }

    func wsSetFormContext(
        originalFileName: String?,
        clipCount: Int?,
        duration: Int?,
        capturedAt: String?
    ) {
        form.originalFileName = originalFileName
        form.clipCount = clipCount
        form.duration = duration
        form.capturedAt = capturedAt
    }

    func wsLogSuppressedFormRequest(assetId: String) {
        groupedFormService.logSubmitDebug(assetId: assetId, event: .suppressedFormRequest)
    }

    func wsHideFormSheet() {
        showFormSheet = false
    }

    func wsShowFormSheet() {
        formFields = buildFormFields()
        showFormSheet = true
    }

    func wsSavePendingForm(_ pendingForm: PendingForm) {
        PendingForm.save(pendingForm)
    }

    func wsMakeFormThumbnailJPEGData() -> Data? {
        form.thumbnail?.jpegData(compressionQuality: 0.5)
    }

    func wsParseStringParams(_ value: Any?) -> [String: String]? {
        parseStringParams(value)
    }

    func wsPromoteFormConfirmedStage(assetId: String?) -> WorkflowStage {
        promoteWorkflowStage(for: assetId, to: .formConfirmed)
    }

    func wsIsBatchAssetId(assetId: String?) -> Bool {
        isBatchAssetId(assetId)
    }

    func wsUpdateBatchClipMetadata(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    ) {
        updateBatchClipMetadata(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            formSlug: formSlug
        )
    }

    func wsSetBatchClipPhase(assetId: String?, phase: VideoBubblePhase) {
        setBatchClipPhase(assetId: assetId, phase: phase)
    }

    func wsMarkLatestOutgoingSlackAsConfirmed() {
        if let outId = messages.last(where: {
            $0.messageType == .slackPost && $0.direction == .outgoing
                && !slackConfirmedIds.contains($0.id)
        })?.id {
            slackConfirmedIds.insert(outId)
        }
    }

    func wsAppendWebSocketMessage(_ message: ChatMessage) {
        appendMessage(message, source: .websocket)
    }

    func wsDownloadSlackThumbnail(url: URL, messageId: String) {
        downloadSlackThumbnail(url: url, messageId: messageId)
    }

    func wsPromoteProcessingStage(assetId: String) {
        _ = promoteWorkflowStage(for: assetId, to: .processing)
    }

    func wsFetchAssetDetail(assetId: String) {
        // Fetch the full asset (with clips) so MetadataView can display it.
        Task { @MainActor in
            await fetchAssetDetail(assetId: assetId)
        }
    }

    func wsPromoteFailedStage(assetId: String?) {
        _ = promoteWorkflowStage(for: assetId, to: .failed)
    }

    func wsMarkBatchClipFailed(assetId: String?, reason: String) {
        markBatchClipFailed(assetId: assetId, reason: reason)
    }

    func wsAppendUploadFailedBubble(assetId: String?, reason: String) {
        appendErrorBubble(
            "Upload failed: \(reason)",
            assetId: assetId,
            code: "IOS_UPLOAD_FAILED",
            params: ["reason": reason]
        )
    }

    func wsHasWorkflowMessage(code: String, assetId: String?, mediasourceId: String?) -> Bool {
        hasWorkflowMessage(code: code, assetId: assetId, mediasourceId: mediasourceId)
    }

    func wsEnsureFormConfirmedMessage(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        capturedAt: String?,
        fallbackText: String?,
        code: String,
        params: [String: String]?,
        schemaVersion: Int?
    ) {
        ensureFormConfirmedMessage(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            originalFileName: originalFileName,
            capturedAt: capturedAt,
            fallbackText: fallbackText,
            code: code,
            params: params,
            schemaVersion: schemaVersion,
            source: .workflow
        )
    }

    func wsMarkBatchClipReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    ) {
        markBatchClipReady(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            formSlug: formSlug
        )
    }

    func wsEnsureFormConfirmedForReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?
    ) {
        ensureFormConfirmedMessage(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            originalFileName: originalFileName,
            capturedAt: nil,
            fallbackText: nil,
            source: .workflow
        )
    }

    func wsPromoteReadyStage(assetId: String?) -> WorkflowStage {
        promoteWorkflowStage(for: assetId, to: .ready)
    }

    func wsResetMessagePolicyAssetScope(assetId: String?) {
        messagePolicy.resetAssetScope(assetId: assetId)
    }

    func wsApplyReadyWorkflowState(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        formSlug: String?,
        duration: Int?,
        resolution: String?,
        fileSize: String?
    ) {
        applyReadyWorkflowState(
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
        let hasSummary = hasWorkflowMessage(
            code: "IOS_MUX_READY_SUMMARY",
            assetId: assetId,
            mediasourceId: mediasourceId
        )
        let hasFollowup = hasWorkflowMessage(
            code: "IOS_MUX_READY_FOLLOWUP",
            assetId: assetId,
            mediasourceId: mediasourceId
        )

        let plan = readyWorkflowStateService.makePlan(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            originalFileName: originalFileName,
            formSlug: formSlug,
            duration: duration,
            resolution: resolution,
            fileSize: fileSize,
            hasSummary: hasSummary,
            hasFollowup: hasFollowup
        )

        archive.assetId = plan.archiveSnapshot.assetId
        archive.mediasourceId = plan.archiveSnapshot.mediasourceId
        archive.mediasourceUrl = plan.archiveSnapshot.mediasourceUrl
        archive.originalFileName = plan.archiveSnapshot.originalFileName
        archive.formSlug = plan.archiveSnapshot.formSlug
        archive.duration = plan.archiveSnapshot.duration
        archive.resolution = plan.archiveSnapshot.resolution
        archive.fileSize = plan.archiveSnapshot.fileSize
        isArchived = true

        if let summaryMessage = plan.summaryMessage {
            appendMessage(summaryMessage, source: source)
        }

        guard plan.shouldScheduleFollowup else { return }

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

            let followUp = self.readyWorkflowStateService.makeFollowupMessage(
                assetId: assetId,
                firstName: firstName
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
        let reconciledStage = WorkflowStageTracker.inferredStage(from: asset)
        let previousStage = promoteWorkflowStage(for: asset.id, to: reconciledStage)
        let isBatchAsset = isBatchAssetId(asset.id)

        var hasReadySummary = false
        var hasReadyFollowup = false
        let shouldCheckReadyMessages =
            !isBatchAsset
            && reconciledStage == .ready
            && previousStage != .failed
            && previousStage.rawValue >= WorkflowStage.ready.rawValue

        if shouldCheckReadyMessages {
            hasReadySummary = hasWorkflowMessage(
                code: "IOS_MUX_READY_SUMMARY",
                assetId: asset.id,
                mediasourceId: asset.mediasourceId
            )
            hasReadyFollowup = hasWorkflowMessage(
                code: "IOS_MUX_READY_FOLLOWUP",
                assetId: asset.id,
                mediasourceId: asset.mediasourceId
            )
        }

        let plan = workflowReconcilePlanService.makePlan(
            asset: asset,
            reconciledStage: reconciledStage,
            previousStage: previousStage,
            isBatchAsset: isBatchAsset,
            hasReadySummary: hasReadySummary,
            hasReadyFollowup: hasReadyFollowup
        )

        workflowReconcileExecutionService.execute(
            asset: asset,
            plan: plan,
            isBatchAsset: isBatchAsset,
            source: source,
            host: self
        )
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
        batchClipDisplayService.displayState(
            for: assetId,
            states: batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    private func isBatchAssetId(_ assetId: String?) -> Bool {
        batchClipDisplayService.isBatchAssetId(
            assetId,
            states: batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    private func phaseForBatchItemStatus(_ status: VideoBatchItemStatus) -> VideoBubblePhase {
        batchClipDisplayService.phase(for: status)
    }

    private func setBatchClipPhase(assetId: String?, phase: VideoBubblePhase) {
        batchClipDisplayService.setPhase(
            assetId: assetId,
            phase: phase,
            states: &batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    private func updateBatchClipProgress(assetId: String?, progress: Double) {
        batchClipDisplayService.updateProgress(
            assetId: assetId,
            progress: progress,
            states: &batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    private func updateBatchClipMetadata(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    ) {
        batchClipDisplayService.updateMetadata(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            formSlug: formSlug,
            states: &batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    private func markBatchClipReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    ) {
        batchClipDisplayService.markReady(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            formSlug: formSlug,
            states: &batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    private func markBatchClipFailed(assetId: String?, reason: String) {
        guard let assetId, !assetId.isEmpty else { return }

        markBatchItemFailedByAssetId(assetId: assetId, message: reason)
        batchClipDisplayService.markFailedDisplay(
            assetId: assetId,
            reason: reason,
            states: &batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    private func markBatchItemFailedByAssetId(assetId: String, message: String) {
        guard let index = batchItems.firstIndex(where: { $0.assetId == assetId }) else {
            return
        }

        markBatchItemFailedAtIndex(index: index, message: message)

        if batchState != .partialFailed {
            batchState = .partialFailed
            persistBatchState()
        }
    }

    private func reconcileActiveWorkflowStateAfterReconnect() async {
        guard auth.isAuthenticated else { return }
        guard let assetId = currentAssetId ?? archive.assetId else { return }

        do {
            let result = try await assetDetailService.fetchAssetDetail(auth: auth, assetId: assetId)
            guard result.statusCode == 200, let asset = result.asset else { return }
            lastAsset = asset
            lastClip = asset.clips?.first
            assetDetailCache[asset.id] = asset

            clearBlockingConnectivityIssueIfNeeded(assetId: asset.id)
            reconcileWorkflowState(from: asset, source: .workflow)
        } catch {
            if connectivityIssues.isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(operation: "syncing workflow state", assetId: assetId)
            }
            AppLog.workflow.warning("[Reconnect] State reconcile skipped: \(error.localizedDescription)")
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
                AppLog.chat.warning(
                    "[Chat] Dropped message by policy: code=\(message.content.code ?? "n/a") source=\(String(describing: source)) target=\(identity)"
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
            AppLog.chat.debug(
                "[Chat] Appended message: code=\(message.content.code ?? "n/a") source=\(String(describing: source)) target=\(identity) total=\(self.messages.count)"
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
        await serverErrorReporter.report(
            auth: auth,
            category: category,
            message: message,
            severity: severity,
            assetId: assetId,
            details: details
        )
    }

    // MARK: - Send Text Message

    // Matches #channel or @mention anywhere in the text (mirrors server-side regex)
    private static let slackCommandPattern = try? NSRegularExpression(pattern: "[#@][\\w.-]+")

    func sendTextMessage(_ text: String) {
        let slackTargetAssetId = activeSlackTargetAssetId()
        let slackTargetAssetIds = activeSlackTargetAssetIds()

        guard
            let sendPlan = textMessageFlowService.makePlan(
                text: text,
                slackCommandPattern: Self.slackCommandPattern,
                currentAssetId: currentAssetId,
                slackTargetAssetId: slackTargetAssetId,
                slackTargetAssetIds: slackTargetAssetIds
            )
        else {
            return
        }

        if sendPlan.shouldWarnNoUploadContext {
            appendMessage(
                textMessageFlowService.makeOutgoingMessage(
                    text: text,
                    userId: auth.currentUser?.id,
                    messageType: .slackPost
                ),
                source: .outgoing
            )
            appendMessage(textMessageFlowService.makeSlackRequiresUploadReply(), source: .workflow)
            return
        }

        appendMessage(
            textMessageFlowService.makeOutgoingMessage(
                text: text,
                userId: auth.currentUser?.id,
                messageType: sendPlan.outgoingMessageType
            ),
            source: .outgoing
        )

        // Send via WebSocket — always pass explicit assetId so the server
        // doesn't fall back to "most recent READY asset" (wrong metadata bug).
        ws.sendMessage(
            text: text,
            assetId: sendPlan.messageAssetId,
            assetIds: sendPlan.messageAssetIds
        )
    }
    // MARK: - Create Asset (Video Upload Flow)

    func createAsset(fileName: String, fileURL: URL) async -> Asset? {
        await singleUploadFlowService.createAsset(
            fileName: fileName,
            fileURL: fileURL,
            thumbnail: form.thumbnail,
            createdDate: lastStagedCreatedDate,
            hasLocation: lastStagedHasLocation,
            transcribeEnabled: transcribeOnUpload,
            auth: auth,
            transport: batchUploadTransportService,
            presentation: batchAssetPresentationService,
            host: self
        )
    }

    // MARK: - Upload Video

    func uploadVideo(assetId: String, fileURL: URL, metadata: VideoMetadata? = nil) async {
        await singleUploadFlowService.uploadVideo(
            assetId: assetId,
            fileURL: fileURL,
            metadata: metadata,
            token: auth.token,
            uploader: uploader,
            host: self
        )
    }

    // MARK: - Send Transcript

    /// Send transcript text + timestamped segments to the server (non-fatal).
    func sendTranscript(assetId: String, result: TranscriptionResult) async {
        await transcriptSubmissionService.sendTranscript(assetId: assetId, result: result, auth: auth)
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

        let stagedSession = batchStateTransitionService.makeStagedBatchSession(
            selectedVideos: selectedVideos,
            anchorMessageId: messages.last?.id
        )
        applyBatchSessionState(
            batchStateTransitionService.makeBatchSessionAssignmentState(from: stagedSession)
        )

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
        applyGroupedBatchFormPromptState(
            batchStateTransitionService.makeGroupedBatchFormPromptState()
        )
    }

    /// Retry only failed batch items.
    func retryFailedBatchItems() async {
        guard canRetryFailedBatchItems else { return }
        await runBatchUpload(retryFailedOnly: true)
    }

    /// Entry-point for ContextFormView submits; routes to batch or single-asset flow.
    func submitCurrentForm(formData: [String: String]) async {
        if awaitingGroupedFormForBatch {
            applyGroupedBatchFormSubmissionState(
                batchStateTransitionService.makeGroupedBatchFormSubmissionState(formData: formData)
            )
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

    private func applyGroupedBatchFormSubmissionState(
        _ submissionState: GroupedBatchFormSubmissionState
    ) {
        awaitingGroupedFormForBatch = submissionState.awaitingGroupedFormForBatch
        pendingBatchFormData = submissionState.pendingBatchFormData
        batchContext = submissionState.batchContext
        persistBatchState()
        showFormSheet = submissionState.showFormSheet
    }

    private func applyGroupedBatchFormPromptState(_ promptState: GroupedBatchFormPromptState) {
        awaitingGroupedFormForBatch = promptState.awaitingGroupedFormForBatch
        if promptState.shouldRebuildFormFields {
            formFields = buildFormFields()
        }
        form.submitError = promptState.submitError
        showFormSheet = promptState.showFormSheet
    }

    /// Apply one grouped form payload to a specific asset.
    func applyGroupedFormToAsset(assetId: String) async -> Bool {
        guard
            let formData = groupedFormService.buildSequencedFormData(
                for: assetId,
                pendingBatchFormData: pendingBatchFormData,
                batchItems: batchItems
            )
        else { return false }
        return await groupedFormService.submitPayload(
            assetId: assetId,
            formData: formData,
            auth: auth,
            isConnectivityIssue: { self.connectivityIssues.isConnectivityIssue($0) },
            clearBlockingConnectivityIssue: { self.clearBlockingConnectivityIssueIfNeeded(assetId: $0) },
            noteBlockingConnectivityIssue: { operation, assetId in
                self.noteBlockingConnectivityIssue(operation: operation, assetId: assetId)
            },
            reportFailure: { [weak self] errorDescription in
                guard let self else { return }
                await self.reportError(
                    category: "form",
                    message: "Grouped form apply failed: \(errorDescription)",
                    severity: "ERROR",
                    assetId: assetId
                )
            }
        )
    }

    /// Cancel a staged batch before upload starts.
    func cancelStagedBatch() {
        resetBatchState(clearDisk: true)
        showFormSheet = false
    }

    private func runBatchUpload(retryFailedOnly: Bool) async {
        guard shouldStartBatchRun() else { return }

        applyBatchRunStartState(batchStateTransitionService.makeRunStartState())
        await processBatchRunChunks(retryFailedOnly: retryFailedOnly)

        let runFinishState = makeBatchRunFinishState()
        applyBatchRunFinishState(runFinishState)
    }

    private func shouldStartBatchRun() -> Bool {
        batchRunExecutionService.shouldStartRun(
            isBatchUploading: isBatchUploading,
            batchItems: batchItems,
            pendingBatchFormData: pendingBatchFormData
        )
    }

    private func processBatchRunChunks(retryFailedOnly: Bool) async {
        for chunk in batchCoordinator.chunked(
            batchCoordinator.executionOrder(
                for: batchItems,
                retryFailedOnly: retryFailedOnly
            )
        ) {
            await withTaskGroup(of: Void.self) { group in
                for localId in chunk {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.processBatchItem(localId: localId)
                    }
                }
            }
        }
    }

    private func applyBatchRunFinishState(_ runFinishState: BatchRunFinishState) {
        isBatchUploading = runFinishState.toggleState.isBatchUploading
        suppressPerAssetFormSheet = runFinishState.toggleState.suppressPerAssetFormSheet
        applyBatchProgressIfPresent(runFinishState.toggleState.batchProgress)
        applyBatchRunCompletionState(runFinishState.finalizationState.completionState)
        applyBatchCompletionMessageTrigger(
            runFinishState.finalizationState.completionMessageTriggerState
        )
    }

    private func applyBatchRunStartState(_ startState: BatchRunStartState) {
        isBatchUploading = startState.isBatchUploading
        suppressPerAssetFormSheet = startState.suppressPerAssetFormSheet
        batchState = startState.batchState
        form.submitError = startState.submitError

        if startState.shouldPersistBatchState {
            persistBatchState()
        }
    }

    private func makeBatchRunFinishState() -> BatchRunFinishState {
        let completion = batchRunExecutionService.completionState(
            batchItems: batchItems,
            currentBatchId: currentBatchId
        )

        return batchStateTransitionService.makeRunFinishState(
            batchItems: batchItems,
            nextState: completion.nextState,
            shouldClearDraftState: completion.shouldClearDraftState,
            batchIdToClear: completion.batchIdToClear,
            fullName: auth.currentUser?.name
        )
    }

    private func applyBatchCompletionMessageTrigger(
        _ triggerState: BatchCompletionMessageTriggerState
    ) {
        guard triggerState.shouldAppendCompletionMessages else { return }
        appendBatchCompletionMessages(firstName: triggerState.firstName)
    }

    private func applyBatchRunCompletionState(_ completionState: BatchRunCompletionState) {
        batchState = completionState.batchState

        if completionState.shouldPersistBatchState {
            persistBatchState()
            return
        }

        if completionState.shouldClearStagedBatchVideos {
            stagedBatchVideos.removeAll()
        }
        if completionState.shouldClearPendingBatchFormData {
            pendingBatchFormData = nil
        }
        if let batchIdToClear = completionState.batchIdToClear {
            PendingBatchStore.clear(batchId: batchIdToClear)
        }
    }

    private func applyBatchSessionState(_ state: BatchSessionAssignmentState) {
        currentBatchId = state.currentBatchId
        stagedBatchVideos = state.stagedBatchVideos
        batchItems = state.batchItems
        batchContext = state.batchContext
        pendingBatchFormData = state.pendingBatchFormData
        batchState = state.batchState
        isBatchUploading = state.isBatchUploading
        suppressPerAssetFormSheet = state.suppressPerAssetFormSheet
        awaitingGroupedFormForBatch = state.awaitingGroupedFormForBatch
        batchBubbleAnchorMessageId = state.batchBubbleAnchorMessageId
        applyBatchProgressIfPresent(state.batchProgress)
    }

    private func applyBatchProgressIfPresent(_ nextBatchProgress: Double?) {
        if let nextBatchProgress {
            batchProgress = nextBatchProgress
        }
    }

    private func appendBatchCompletionMessages(firstName: String) {
        guard !batchItems.isEmpty else { return }

        let completionMessages = batchCompletionMessageService.makeCompletionMessages(
            batchItems: batchItems,
            firstName: firstName,
            batchClipDisplayByAssetId: batchClipDisplayByAssetId
        )

        for message in completionMessages {
            appendMessage(message, source: .workflow)
        }
    }

    private func processBatchItem(localId: String) async {
        await batchItemProcessingService.process(
            localId: localId,
            host: self
        )
    }

    private func noteBatchItemPreparedForCreation() {
        batchProgress = computeBatchProgress()
        persistBatchState()
    }

    private func noteBatchItemPreparedForUpload(assetId: String) {
        setBatchClipPhase(assetId: assetId, phase: .uploading)
        updateBatchClipProgress(assetId: assetId, progress: 0)
        batchProgress = computeBatchProgress()
        persistBatchState()
    }

    private func updateBatchUploadProgress(localId: String, progress: Double) {
        guard
            let update = batchItemLifecycleService.updateUploadProgress(
                localId: localId,
                progress: progress,
                batchItems: &batchItems
            )
        else {
            return
        }

        // Reserve final progress for grouped-form apply so the UI has clear phase transitions.
        updateBatchClipProgress(assetId: update.assetId, progress: update.progress)
        batchProgress = computeBatchProgress()
    }

    private func noteBatchItemPreparedForApplyingForm(
        assetId: String,
        applyingUpdate: BatchItemProgressUpdate
    ) {
        setBatchClipPhase(assetId: assetId, phase: .processing)
        updateBatchClipProgress(
            assetId: applyingUpdate.assetId,
            progress: applyingUpdate.progress
        )
        batchProgress = computeBatchProgress()
        persistBatchState()
    }

    private func noteBatchItemCompleted(completedUpdate: BatchItemProgressUpdate, fileURL: URL) {
        updateBatchClipProgress(
            assetId: completedUpdate.assetId,
            progress: completedUpdate.progress
        )
        cleanupTempFileIfNeeded(fileURL)
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
        await batchAssetFlowService.createBatchAsset(
            fileName: fileName,
            fileURL: fileURL,
            thumbnail: thumbnail,
            createdDate: createdDate,
            hasLocation: hasLocation,
            phAssetIdentifier: phAssetIdentifier,
            auth: auth,
            transport: batchUploadTransportService,
            presentation: batchAssetPresentationService,
            host: self
        )
    }

    private func uploadBatchVideo(
        assetId: String,
        fileURL: URL,
        metadata: VideoMetadata,
        onProgress: @escaping (Double) -> Void
    ) async -> Bool {
        await batchAssetFlowService.uploadBatchVideo(
            assetId: assetId,
            fileURL: fileURL,
            metadata: metadata,
            authToken: auth.token,
            transport: batchUploadTransportService,
            onProgress: onProgress,
            host: self
        )
    }

    private func markBatchItemFailedAtIndex(index: Int, message: String) {
        batchItemStateService.markFailedAtIndex(
            index: index,
            message: message,
            batchItems: &batchItems,
            batchState: &batchState,
            batchProgress: &batchProgress,
            batchClipDisplayByAssetId: &batchClipDisplayByAssetId,
            batchClipDisplayService: batchClipDisplayService
        )

        persistBatchState()
    }

    private func computeBatchProgress() -> Double {
        batchItemStateService.computeProgress(items: batchItems)
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

        let restoredSnapshot = pendingBatchRestoreService.makeSnapshot(
            pending: pending,
            uploadQueueRecovery: uploadQueueRecovery
        )

        let restoredSession = batchStateTransitionService.makeRestoredBatchSession(
            snapshot: restoredSnapshot,
            existingAnchorMessageId: batchBubbleAnchorMessageId,
            fallbackAnchorMessageId: messages.last?.id
        )
        applyBatchSessionState(
            batchStateTransitionService.makeBatchSessionAssignmentState(from: restoredSession)
        )

        applyRestoredBatchAssetOwnership(
            batchStateTransitionService.makeRestoredActiveAssetIds(batchItems: batchItems)
        )

        if restoredSnapshot.shouldClearAfterRestore {
            PendingBatchStore.clear(batchId: restoredSnapshot.batchId)
            return
        }

        persistBatchState()
    }

    private func applyRestoredBatchAssetOwnership(_ assetIds: [String]) {
        for assetId in assetIds {
            chatOwnership.registerActiveAsset(assetId)
        }
    }

    private func rehydratePersistedUploadQueueState() {
        guard let rehydratePlan = uploadQueueRehydratePlanService.makePlan(
            existingMessages: messages,
            batchItems: batchItems,
            uploadQueueRecovery: uploadQueueRecovery
        ) else { return }

        uploadQueueRehydrateExecutionService.execute(
            plan: rehydratePlan,
            host: self
        )
    }

    private func reconcileAssetDetailsAfterUploadQueueRehydrate(_ assetIds: [String]) {
        Task { @MainActor in
            for assetId in assetIds {
                await fetchAssetDetail(
                    assetId: assetId,
                    presentErrorsInChat: false,
                    reason: "upload-queue-rehydrate"
                )
            }
        }
    }

    private func syncBatchDisplayStateForRehydratedAsset(assetId: String) {
        guard let index = batchItems.firstIndex(where: { $0.assetId == assetId }) else {
            return
        }

        guard batchItems[index].status != .complete else {
            return
        }

        setBatchClipPhase(assetId: assetId, phase: phaseForBatchItemStatus(batchItems[index].status))
        updateBatchClipProgress(assetId: assetId, progress: batchItems[index].progress)
    }

    private func resetBatchState(clearDisk: Bool) {
        let batchIdToClear = currentBatchId
        let videosToCleanup = stagedBatchVideos

        for video in videosToCleanup {
            cleanupTempFileIfNeeded(video.fileURL)
        }

        let resetState = batchStateTransitionService.makeResetState()
        applyBatchSessionState(
            batchStateTransitionService.makeBatchSessionAssignmentState(from: resetState)
        )
        groupedFormService.resetSubmitAttempts()

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
            AppLog.upload.info("Asset created: \(asset.mediasourceId ?? asset.id)")

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
            _ = promoteWorkflowStage(for: assetId, to: .failed)
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
        do {
            try await formSubmissionService.submitForm(assetId: assetId, formData: formData, auth: auth)

            // Form sheet closes — server will push form:confirmed via WS
            // with the "High Five!" confirmation bubble + metadata
            form.submitError = nil
            showFormSheet = false
            PendingForm.clear()
            clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
        } catch {
            AppLog.chat.error("Failed to submit form: \(error.localizedDescription)")
            // Keep form open so user can retry — show error in chat too
            form.submitError = "Failed to send form. Please try again."
            if connectivityIssues.isConnectivityIssue(error) {
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
        workflowStageTracker.reset()
        messagePolicy.resetForFreshConnection()
        connectivityIssues.reset()
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

    func fetchAssetDetail(
        assetId: String,
        presentErrorsInChat: Bool = true,
        reason: String = "manual"
    ) async {
        await assetDetailSyncService.sync(
            assetId: assetId,
            presentErrorsInChat: presentErrorsInChat,
            reason: reason,
            host: self
        )
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

        AppLog.chat.info("[Recovery] Found pending form for asset: \(pendingForm.assetId)")

        Task {
            do {
                let recoveryDecision = try await pendingFormRecovery.evaluate(
                    auth: auth,
                    pendingForm: pendingForm
                )

                switch recoveryDecision {
                case .clear:
                    AppLog.chat.info(
                        "[Recovery] Form already submitted for \(pendingForm.assetId) — clearing"
                    )
                    PendingForm.clear()

                case .restore:
                    AppLog.chat.info("[Recovery] Restoring pending form for \(pendingForm.assetId)")
                    restoreFormFromPending(pendingForm)
                }
            } catch {
                AppLog.chat.warning("[Recovery] Could not check pending form: \(error.localizedDescription)")
            }
        }
    }

    /// Restore form UI from persisted PendingForm state.
    private func restoreFormFromPending(_ pendingForm: PendingForm) {
        currentAssetId = pendingForm.assetId
        chatOwnership.registerActiveAsset(pendingForm.assetId)
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

    private func applyConversationResetScalars(_ scalarReset: ConversationResetScalars) {
        currentAssetId = scalarReset.currentAssetId
        isArchived = scalarReset.isArchived
        archive = scalarReset.archive
        form = scalarReset.form
        lastAsset = scalarReset.lastAsset
        lastClip = scalarReset.lastClip
        stagedVideo = scalarReset.stagedVideo
        isUploading = scalarReset.isUploading
        uploadProgress = scalarReset.uploadProgress
        showFormSheet = scalarReset.showFormSheet
        showMetadataSheet = scalarReset.showMetadataSheet
        metadataSheetThumbnail = scalarReset.metadataSheetThumbnail
        showSlackShareSheet = scalarReset.showSlackShareSheet
        lastStagedCreatedDate = scalarReset.lastStagedCreatedDate
        lastStagedHasLocation = scalarReset.lastStagedHasLocation
    }

    private func applyConversationResetCollections(_ collectionReset: ConversationResetCollections) {
        sentUploads = collectionReset.sentUploads
        batchClipDisplayByAssetId = collectionReset.batchClipDisplayByAssetId
        sentUploadsByAssetId = collectionReset.sentUploadsByAssetId
        slackThumbnails = collectionReset.slackThumbnails
        slackConfirmedIds = collectionReset.slackConfirmedIds
        assetDetailCache = collectionReset.assetDetailCache
    }

    // MARK: - Archive / New Conversation

    /// Clear current conversation and start fresh for a new upload.
    func startNewConversation() {
        chatOwnership.archiveCurrentOwnership(
            currentAssetId: currentAssetId,
            batchAssetIds: batchItems.map(\.assetId)
        )
        resetBatchState(clearDisk: true)
        workflowStageTracker.reset()
        messagePolicy.resetForNewConversation()
        connectivityIssues.reset()
        messages.removeAll()

        let scalarReset = conversationResetService.makeScalarReset()
        applyConversationResetScalars(scalarReset)

        let collectionReset = conversationResetService.makeCollectionReset()
        applyConversationResetCollections(collectionReset)

        // Re-send greeting for the fresh conversation
        let firstName = auth.currentUser?.name.components(separatedBy: " ").first ?? "there"
        let greeting = conversationResetService.makeNewConversationGreeting(firstName: firstName)
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
                AppLog.chat.warning("Failed to download Slack thumbnail: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Priority 5b: Upload/Workflow Host Conformances
// These extensions are inlined in this file so they can access ChatViewModel's
// private members (Swift's `private` is file-scoped). Each extension replaces
// the closure-bag `Dependencies` struct that previously sat on each service.

// MARK: WorkflowReconcileExecutionHost

extension ChatViewModel: WorkflowReconcileExecutionHost {
    func wreMarkBatchClipFailed(assetId: String?, reason: String) {
        markBatchClipFailed(assetId: assetId, reason: reason)
    }

    func wreAppendUploadFailedBubble(assetId: String, reason: String) {
        wsAppendUploadFailedBubble(assetId: assetId, reason: reason)
    }

    func wreUpdateBatchMetadataToProcessing(asset: Asset) {
        updateBatchClipMetadata(
            assetId: asset.id,
            mediasourceId: asset.mediasourceId,
            mediasourceUrl: asset.mediasourceUrl,
            formSlug: asset.formResponse?.slug
        )
        setBatchClipPhase(assetId: asset.id, phase: .processing)
    }

    func wreMarkBatchClipReady(asset: Asset) {
        markBatchClipReady(
            assetId: asset.id,
            mediasourceId: asset.mediasourceId,
            mediasourceUrl: asset.mediasourceUrl,
            formSlug: asset.formResponse?.slug
        )
    }

    func wreAppendFormConfirmed(asset: Asset, source: MessagePolicyCoordinator.Source) {
        appendReconciledFormConfirmed(asset: asset, source: source)
    }

    func wreResetReadyMessagePolicy(assetId: String) {
        messagePolicy.resetAssetScope(assetId: assetId)
    }

    func wreApplyReadyWorkflowState(asset: Asset, source: MessagePolicyCoordinator.Source) {
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

// MARK: SingleUploadFlowHost

extension ChatViewModel: SingleUploadFlowHost {
    // createAsset
    func sufRegisterAsset(_ asset: Asset) {
        currentAssetId = asset.id
        chatOwnership.registerActiveAsset(asset.id)
        _ = promoteWorkflowStage(for: asset.id, to: .uploading)
        clearBlockingConnectivityIssueIfNeeded(assetId: asset.id)
    }

    func sufAppendOutgoingMessage(_ message: ChatMessage) {
        appendMessage(message, source: .outgoing)
    }

    func sufStoreUploadInfo(messageId: String, assetId: String, uploadInfo: SentUploadInfo) {
        sentUploads[messageId] = uploadInfo
        sentUploadsByAssetId[assetId] = uploadInfo
    }

    func sufSendVideoUpload(assetId: String, fileName: String, fileSize: Int64) {
        ws.sendVideoUpload(assetId: assetId, fileName: fileName, fileSize: fileSize)
    }

    func sufAppendStartErrorBubble() {
        appendErrorBubble(
            "Could not start upload. Please try again.",
            code: "IOS_UPLOAD_START_FAILED"
        )
    }

    func sufReportStartError(errorDescription: String, fileName: String) async {
        await reportError(
            category: "upload",
            message: "Asset creation failed after 3 attempts: \(errorDescription)",
            severity: "ERROR",
            details: ["fileName": fileName]
        )
    }

    // uploadVideo
    func sufSetUploading(_ isUploading: Bool) {
        self.isUploading = isUploading
    }

    func sufUpdateProgress(_ progress: Double) {
        uploadProgress = progress
    }

    func sufMarkAssetFailed(assetId: String) {
        _ = promoteWorkflowStage(for: assetId, to: .failed)
    }

    func sufAppendUploadErrorBubble(assetId: String, reason: String) {
        appendErrorBubble(
            "Upload failed: \(reason)",
            assetId: assetId,
            code: "IOS_UPLOAD_FAILED",
            params: ["reason": reason]
        )
    }

    func sufReportUploadError(assetId: String, errorDescription: String) async {
        await reportError(
            category: "upload",
            message: "File upload failed: \(errorDescription)",
            severity: "ERROR",
            assetId: assetId
        )
    }

    // shared
    func sufIsConnectivityIssue(_ error: Error) -> Bool {
        connectivityIssues.isConnectivityIssue(error)
    }

    func sufNoteBlockingConnectivityIssue(operation: String, assetId: String?) {
        noteBlockingConnectivityIssue(operation: operation, assetId: assetId)
    }
}

// MARK: BatchAssetFlowHost

extension ChatViewModel: BatchAssetFlowHost {
    // createBatchAsset
    func bafRegisterAsset(_ asset: Asset) {
        currentAssetId = asset.id
        chatOwnership.registerActiveAsset(asset.id)
        _ = promoteWorkflowStage(for: asset.id, to: .uploading)
        clearBlockingConnectivityIssueIfNeeded(assetId: asset.id)
    }

    func bafAppendOutgoingMessage(_ message: ChatMessage) {
        appendMessage(message, source: .outgoing)
    }

    func bafStoreUploadInfo(messageId: String, assetId: String, uploadInfo: SentUploadInfo) {
        sentUploads[messageId] = uploadInfo
        sentUploadsByAssetId[assetId] = uploadInfo
    }

    func bafMarkBatchUploadStarted(assetId: String) {
        setBatchClipPhase(assetId: assetId, phase: .uploading)
        updateBatchClipProgress(assetId: assetId, progress: 0)
    }

    func bafSavePHAssetIdentifier(assetId: String, identifier: String) {
        PHAssetIdentifierStore.save(assetId: assetId, phAssetIdentifier: identifier)
    }

    func bafSendVideoUpload(assetId: String, fileName: String, fileSize: Int64) {
        ws.sendVideoUpload(assetId: assetId, fileName: fileName, fileSize: fileSize)
    }

    func bafAppendStartErrorBubble() {
        appendErrorBubble(
            "Could not start batch upload. Please try again.",
            code: "IOS_BATCH_UPLOAD_START_FAILED"
        )
    }

    func bafReportStartError(errorDescription: String, fileName: String) async {
        await reportError(
            category: "upload",
            message: "Batch asset creation failed after 3 attempts: \(errorDescription)",
            severity: "ERROR",
            details: ["fileName": fileName]
        )
    }

    // uploadBatchVideo
    func bafMarkAssetFailed(assetId: String, reason: String) {
        _ = promoteWorkflowStage(for: assetId, to: .failed)
        markBatchClipFailed(assetId: assetId, reason: reason)
    }

    func bafReportUploadError(errorDescription: String, assetId: String) async {
        await reportError(
            category: "upload",
            message: "Batch file upload failed: \(errorDescription)",
            severity: "ERROR",
            assetId: assetId
        )
    }

    // shared
    func bafIsConnectivityIssue(_ error: Error) -> Bool {
        connectivityIssues.isConnectivityIssue(error)
    }

    func bafNoteBlockingConnectivityIssue(operation: String, assetId: String?) {
        noteBlockingConnectivityIssue(operation: operation, assetId: assetId)
    }
}

// MARK: BatchItemProcessingHost

extension ChatViewModel: BatchItemProcessingHost {
    func bipPrepareForProcessing(localId: String) -> BatchItemPreparationResult {
        batchItemExecutionService.prepareForProcessing(
            localId: localId,
            batchItems: &batchItems,
            stagedBatchVideos: stagedBatchVideos,
            lifecycle: batchItemLifecycleService
        )
    }

    func bipNoteItemPreparedForCreation() {
        noteBatchItemPreparedForCreation()
    }

    func bipBuildCreationContext(
        from selectedContext: BatchItemSelectedContext
    ) async -> BatchItemCreationContext {
        await batchItemExecutionService.buildCreationContext(from: selectedContext)
    }

    func bipCreateBatchAsset(creationContext: BatchItemCreationContext) async -> Asset? {
        await createBatchAsset(
            fileName: creationContext.fileName,
            fileURL: creationContext.fileURL,
            thumbnail: creationContext.thumbnail,
            createdDate: creationContext.createdDate,
            hasLocation: creationContext.hasLocation,
            phAssetIdentifier: creationContext.phAssetIdentifier
        )
    }

    func bipPrepareForUpload(localId: String, assetId: String) -> Bool {
        batchItemExecutionService.prepareForUpload(
            localId: localId,
            assetId: assetId,
            batchItems: &batchItems,
            lifecycle: batchItemLifecycleService
        )
    }

    func bipNoteItemPreparedForUpload(assetId: String) {
        noteBatchItemPreparedForUpload(assetId: assetId)
    }

    func bipUploadBatchVideo(
        localId: String,
        assetId: String,
        creationContext: BatchItemCreationContext
    ) async -> Bool {
        await uploadBatchVideo(
            assetId: assetId,
            fileURL: creationContext.fileURL,
            metadata: creationContext.metadata,
            onProgress: { progress in
                self.updateBatchUploadProgress(localId: localId, progress: progress)
            }
        )
    }

    func bipPendingFailureIndex(localId: String, skipAlreadyFailed: Bool) -> Int? {
        batchItemExecutionService.pendingFailureIndex(
            localId: localId,
            batchItems: batchItems,
            skipAlreadyFailed: skipAlreadyFailed
        )
    }

    func bipMarkFailedAtIndex(index: Int, message: String) {
        markBatchItemFailedAtIndex(index: index, message: message)
    }

    func bipNoteUploadSucceeded(assetId: String) {
        setBatchClipPhase(assetId: assetId, phase: .processing)
    }

    func bipPrepareForApplyingForm(localId: String) -> BatchItemProgressUpdate? {
        batchItemExecutionService.prepareForApplyingForm(
            localId: localId,
            batchItems: &batchItems,
            lifecycle: batchItemLifecycleService
        )
    }

    func bipNoteItemPreparedForApplyingForm(
        assetId: String,
        applyingUpdate: BatchItemProgressUpdate
    ) {
        noteBatchItemPreparedForApplyingForm(
            assetId: assetId,
            applyingUpdate: applyingUpdate
        )
    }

    func bipApplyGroupedFormToAsset(assetId: String) async -> Bool {
        await applyGroupedFormToAsset(assetId: assetId)
    }

    func bipPrepareForCompletion(localId: String) -> BatchItemProgressUpdate? {
        batchItemExecutionService.prepareForCompletion(
            localId: localId,
            batchItems: &batchItems,
            lifecycle: batchItemLifecycleService
        )
    }

    func bipNoteItemCompleted(completedUpdate: BatchItemProgressUpdate, fileURL: URL) {
        noteBatchItemCompleted(completedUpdate: completedUpdate, fileURL: fileURL)
    }
}

// MARK: UploadQueueRehydrateHost

extension ChatViewModel: UploadQueueRehydrateHost {
    func uqrHasCurrentAsset() -> Bool {
        currentAssetId != nil
    }

    func uqrSetCurrentAsset(assetId: String) {
        currentAssetId = assetId
    }

    func uqrRegisterActiveAsset(assetId: String?) {
        chatOwnership.registerActiveAsset(assetId)
    }

    func uqrAppendSummaryMessage(_ message: ChatMessage) {
        appendMessage(message, source: .workflow)
    }

    func uqrPromoteWorkflowStage(assetId: String, targetStage: WorkflowStage) {
        _ = promoteWorkflowStage(for: assetId, to: targetStage)
    }

    func uqrSetBatchItems(_ items: [VideoBatchItem]) {
        batchItems = items
    }

    func uqrSyncBatchDisplayState(assetId: String) {
        syncBatchDisplayStateForRehydratedAsset(assetId: assetId)
    }

    func uqrHasUploadFailureMessage(assetId: String) -> Bool {
        hasWorkflowMessage(
            code: "IOS_UPLOAD_FAILED",
            assetId: assetId,
            mediasourceId: nil
        )
    }

    func uqrAppendUploadFailedBubble(assetId: String, reason: String) {
        wsAppendUploadFailedBubble(assetId: assetId, reason: reason)
    }

    func uqrHasActiveBatch() -> Bool {
        hasActiveBatch
    }

    func uqrSetBatchState(_ state: VideoBatchState) {
        batchState = state
    }

    func uqrUpdateBatchProgress() {
        batchProgress = computeBatchProgress()
    }

    func uqrPersistBatchState() {
        persistBatchState()
    }

    func uqrReconcileAssetDetails(assetIds: [String]) {
        reconcileAssetDetailsAfterUploadQueueRehydrate(assetIds)
    }
}

// MARK: AssetDetailSyncHost

extension ChatViewModel: AssetDetailSyncHost {
    func adsFetchAssetDetail(assetId: String) async throws -> AssetDetailFetchResult {
        try await assetDetailService.fetchAssetDetail(auth: auth, assetId: assetId)
    }

    func adsHasDetailLoadFailureMessage(assetId: String) -> Bool {
        hasWorkflowMessage(
            code: "IOS_ASSET_DETAILS_LOAD_FAILED",
            assetId: assetId,
            mediasourceId: nil
        )
    }

    func adsAppendDetailLoadFailureBubble(assetId: String) {
        appendErrorBubble(
            "Could not load video details.",
            assetId: assetId,
            code: "IOS_ASSET_DETAILS_LOAD_FAILED"
        )
    }

    func adsCacheAsset(_ asset: Asset) {
        lastAsset = asset
        lastClip = asset.clips?.first
        assetDetailCache[asset.id] = asset
    }

    func adsClearBlockingConnectivityIssue(assetId: String) {
        clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
    }

    func adsReconcileWorkflowState(asset: Asset) {
        reconcileWorkflowState(from: asset, source: .workflow)
    }

    func adsIsConnectivityIssue(_ error: Error) -> Bool {
        connectivityIssues.isConnectivityIssue(error)
    }

    func adsNoteBlockingConnectivityIssue(operation: String, assetId: String?) {
        noteBlockingConnectivityIssue(operation: operation, assetId: assetId)
    }
}
