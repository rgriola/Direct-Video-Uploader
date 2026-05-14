// May 14, 2026 - 3:10pm - GitHub Copilot (Claude Opus 4.7)
// Runtime protocol consolidated into Services/Chat/WebSocketEventRuntime.swift (Priority 5).
import Foundation

@MainActor
final class WebSocketUploadLifecycleEventService {
    func handleUploadComplete(data: [String: Any], runtime: WebSocketEventRuntime) {
        let assetId = data["assetId"] as? String ?? ""
        print("✅ Upload complete for asset: \(assetId)")

        runtime.wsClearBlockingConnectivityIssue(assetId: assetId)

        if runtime.wsShouldSuppressMutation(assetId: assetId, event: "upload:complete") {
            return
        }

        if !assetId.isEmpty {
            runtime.wsPromoteProcessingStage(assetId: assetId)
            if runtime.wsIsBatchAssetId(assetId: assetId) {
                runtime.wsSetBatchClipPhase(assetId: assetId, phase: .processing)
            }
        }

        runtime.wsFetchAssetDetail(assetId: assetId)
    }

    func handleStreamErrored(data: [String: Any], runtime: WebSocketEventRuntime) {
        let assetId = data["assetId"] as? String
        let reason =
            data["reason"] as? String
            ?? data["error"] as? String
            ?? data["message"] as? String
            ?? "Processing error"

        runtime.wsClearBlockingConnectivityIssue(assetId: assetId)

        if runtime.wsShouldSuppressMutation(assetId: assetId, event: "mux:errored") {
            return
        }

        runtime.wsRegisterActiveAsset(assetId: assetId)
        runtime.wsPromoteFailedStage(assetId: assetId)

        if runtime.wsIsBatchAssetId(assetId: assetId) {
            runtime.wsMarkBatchClipFailed(assetId: assetId, reason: reason)
            return
        }

        runtime.wsAppendUploadFailedBubble(assetId: assetId, reason: reason)
    }
}
