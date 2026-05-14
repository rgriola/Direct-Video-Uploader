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
    var lastStagedCreatedDate: String?
    var lastStagedHasLocation: Bool = false
    var pendingPHAssetIdentifier: String?
    var uploadTask: Task<Void, Never>?
    var pendingBatchFormData: [String: String]?
    var awaitingGroupedFormForBatch = false
    var batchBubbleAnchorMessageId: String?
    var batchClipDisplayByAssetId: [String: BatchClipDisplayState] = [:]
    var sentUploadsByAssetId: [String: SentUploadInfo] = [:]
    var assetDetailCache: [String: Asset] = [:]
    let messagePolicy = MessagePolicyCoordinator()
    let batchCoordinator = VideoBatchUploadCoordinator(maxConcurrentUploads: 2)
    let chatOwnership = ChatOwnershipRouter(maxArchivedAssetOwnership: 250)
    let assetDetailService = AssetDetailService()
    let assetDetailSyncService = AssetDetailSyncService()
    let connectivityIssues = ConnectivityIssueTracker()
    let serverErrorReporter = ServerErrorReporter()
    let uploadQueueRecovery = UploadQueueRecoveryService()
    let uploadQueueRehydratePlanService = UploadQueueRehydratePlanService()
    let uploadQueueRehydrateExecutionService = UploadQueueRehydrateExecutionService()
    let pendingFormRecovery = PendingFormRecoveryService()
    let pendingBatchRestoreService = PendingBatchRestoreService()
    let batchStateTransitionService = BatchStateTransitionService()
    let workflowStageTracker = WorkflowStageTracker()
    let batchClipDisplayService = BatchClipDisplayService()
    let batchCompletionMessageService = BatchCompletionMessageService()
    let batchItemStateService = BatchItemStateService()
    let batchItemLifecycleService = BatchItemLifecycleService()
    let batchItemExecutionService = BatchItemExecutionService()
    let batchItemProcessingService = BatchItemProcessingService()
    let groupedFormService = GroupedFormService()
    let batchUploadTransportService = BatchUploadTransportService()
    let batchAssetPresentationService = BatchAssetPresentationService()
    let batchAssetFlowService = BatchAssetFlowService()
    let webSocketMessageEventService = WebSocketMessageEventService()
    let webSocketConnectionStateService = WebSocketConnectionStateService()
    let webSocketUploadLifecycleEventService = WebSocketUploadLifecycleEventService()
    let webSocketFormRequestEventService = WebSocketFormRequestEventService()
    let webSocketFormConfirmedEventService = WebSocketFormConfirmedEventService()
    let webSocketStreamReadyEventService = WebSocketStreamReadyEventService()
    let readyWorkflowStateService = ReadyWorkflowStateService()
    let workflowReconcilePlanService = WorkflowReconcilePlanService()
    let workflowReconcileExecutionService = WorkflowReconcileExecutionService()
    let batchRunExecutionService = BatchRunExecutionService()
    let singleUploadFlowService = SingleUploadFlowService()
    let conversationResetService = ConversationResetService()
    let formSubmissionService = FormSubmissionService()
    let transcriptSubmissionService = TranscriptSubmissionService()
    let textMessageFlowService = TextMessageFlowService()
    let reconnectWarningThreshold = 3

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
}
