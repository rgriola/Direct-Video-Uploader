// May 14, 2026 - 3:10pm - GitHub Copilot (Claude Opus 4.7)
// Runtime protocol consolidated into Services/Chat/WebSocketEventRuntime.swift (Priority 5).
import Foundation

@MainActor
final class WebSocketStreamReadyEventService {
    func handle(data: [String: Any], runtime: WebSocketEventRuntime) {
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
