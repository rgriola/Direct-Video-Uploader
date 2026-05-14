// May 13, 2026 - 11:59pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
protocol WebSocketMuxReadyEventRuntime: AnyObject {
    func wsShouldSuppressMutation(assetId: String?, event: String) -> Bool
    func wsClearBlockingConnectivityIssue(assetId: String?)
    func wsRegisterActiveAsset(assetId: String?)
    func wsIsBatchAssetId(assetId: String?) -> Bool
    func wsMarkBatchClipReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    )
    func wsEnsureFormConfirmedForReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?
    )
    func wsPromoteReadyStage(assetId: String?) -> WorkflowStage
    func wsHasWorkflowMessage(code: String, assetId: String?, mediasourceId: String?) -> Bool
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
}

@MainActor
final class WebSocketMuxReadyEventService {
    func handle(data: [String: Any], runtime: WebSocketMuxReadyEventRuntime) {
        let assetId = data["assetId"] as? String
        let mediasourceId = data["mediasourceId"] as? String
        let mediasourceUrl = data["mediasourceUrl"] as? String
        let originalFileName = data["originalFileName"] as? String
        let formSlug = data["formSlug"] as? String
        let duration = data["duration"] as? Int
        let resolution = data["resolution"] as? String
        let fileSize = data["fileSize"] as? String
        let uploadTelemetry = data["uploadTelemetry"] as? [String: Any]

        if let uploadTelemetry {
            let correlationId = uploadTelemetry["correlationId"] as? String ?? "n/a"
            let muxUploadId = uploadTelemetry["muxUploadId"] as? String ?? "n/a"
            let serverToReadyMs = uploadTelemetry["serverToReadyMs"] as? Int
            let serverToAssetCreatedMs = uploadTelemetry["serverToAssetCreatedMs"] as? Int
            let readyText = serverToReadyMs.map { "\($0)ms" } ?? "n/a"
            let assetCreatedText = serverToAssetCreatedMs.map { "\($0)ms" } ?? "n/a"
            print(
                "📊 [UploadCorrelation] correlation=\(correlationId) muxUploadId=\(muxUploadId) serverToAssetCreated=\(assetCreatedText) serverToReady=\(readyText)"
            )
        }

        runtime.wsClearBlockingConnectivityIssue(assetId: assetId)

        if runtime.wsShouldSuppressMutation(assetId: assetId, event: "mux:ready") {
            return
        }

        runtime.wsRegisterActiveAsset(assetId: assetId)

        if runtime.wsIsBatchAssetId(assetId: assetId) {
            runtime.wsMarkBatchClipReady(
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
            runtime.wsEnsureFormConfirmedForReady(
                assetId: assetId,
                mediasourceId: mediasourceId,
                mediasourceUrl: mediasourceUrl,
                originalFileName: originalFileName
            )
        }

        print("✅ [Mux Ready] Asset \(assetId ?? "?") confirmed on Mediasource")

        let previousStage = runtime.wsPromoteReadyStage(assetId: assetId)
        if previousStage != .failed,
            previousStage.rawValue >= WorkflowStage.ready.rawValue
        {
            let missingSummary = !runtime.wsHasWorkflowMessage(
                code: "IOS_MUX_READY_SUMMARY",
                assetId: assetId,
                mediasourceId: mediasourceId
            )
            let missingFollowup = !runtime.wsHasWorkflowMessage(
                code: "IOS_MUX_READY_FOLLOWUP",
                assetId: assetId,
                mediasourceId: mediasourceId
            )

            if !missingSummary, !missingFollowup {
                return
            }

            // Recovery path for reconnect churn: if stage is already READY but
            // UI messages are missing, clear asset dedupe and backfill them.
            runtime.wsResetMessagePolicyAssetScope(assetId: assetId)
        }

        runtime.wsApplyReadyWorkflowState(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            originalFileName: originalFileName,
            formSlug: formSlug,
            duration: duration,
            resolution: resolution,
            fileSize: fileSize
        )
    }
}
