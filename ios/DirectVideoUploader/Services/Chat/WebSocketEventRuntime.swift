// May 14, 2026 - 3:10pm - GitHub Copilot (Claude Opus 4.7)
//
// Unified runtime protocol consumed by all WebSocket *event* services
// (FormRequest, FormConfirmed, Message, StreamReady, UploadLifecycle).
//
// Priority 5 consolidation: replaces five near-identical per-event protocols
// (`WebSocket{FormRequest,FormConfirmed,Message,StreamReady,UploadLifecycle}EventRuntime`).
// `WebSocketConnectionStateRuntime` is intentionally kept separate — it is
// async + lifecycle-shaped, not an event handler.
//
// `ChatViewModel` already implements every method below; the only conformance
// change there is collapsing five protocol names to one.

import Foundation

@MainActor
protocol WebSocketEventRuntime: AnyObject {
    // Shared across multiple event services
    func wsShouldSuppressMutation(assetId: String?, event: String) -> Bool
    func wsClearBlockingConnectivityIssue(assetId: String?)
    func wsRegisterActiveAsset(assetId: String?)
    func wsIsBatchAssetId(assetId: String?) -> Bool
    func wsUpdateBatchClipMetadata(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    )
    func wsSetBatchClipPhase(assetId: String?, phase: VideoBubblePhase)
    func wsMarkBatchClipReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    )
    func wsHasWorkflowMessage(code: String, assetId: String?, mediasourceId: String?) -> Bool

    // Form request / confirm
    func wsParseStringParams(_ value: Any?) -> [String: String]?
    func wsPromoteFormConfirmedStage(assetId: String?) -> WorkflowStage
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
    )
    func wsSetCurrentAssetId(_ assetId: String?)
    func wsPromoteFormRequestedStage(assetId: String)
    func wsSetFormContext(
        originalFileName: String?,
        clipCount: Int?,
        duration: Int?,
        capturedAt: String?
    )
    func wsLogSuppressedFormRequest(assetId: String)
    func wsHideFormSheet()
    func wsShowFormSheet()
    func wsSavePendingForm(_ pendingForm: PendingForm)
    func wsMakeFormThumbnailJPEGData() -> Data?

    // Inbound message handling (text + Slack mirror)
    func wsMarkLatestOutgoingSlackAsConfirmed()
    func wsAppendWebSocketMessage(_ message: ChatMessage)
    func wsDownloadSlackThumbnail(url: URL, messageId: String)

    // Stream ready
    func wsEnsureFormConfirmedForReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?
    )
    func wsPromoteReadyStage(assetId: String?) -> WorkflowStage
    func wsResetMessagePolicyAssetScope(assetId: String?)
    func wsApplyReadyWorkflowState(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        formSlug: String?,
        duration: Int?,
        resolution: String?,
        fileSize: String?
    )

    // Upload lifecycle
    func wsPromoteProcessingStage(assetId: String)
    func wsFetchAssetDetail(assetId: String)
    func wsPromoteFailedStage(assetId: String?)
    func wsMarkBatchClipFailed(assetId: String?, reason: String)
    func wsAppendUploadFailedBubble(assetId: String?, reason: String)
}
