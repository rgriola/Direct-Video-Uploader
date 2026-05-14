// May 14, 2026 - 12:15am - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
protocol WebSocketUploadLifecycleEventRuntime: AnyObject {
    func wsShouldSuppressMutation(assetId: String?, event: String) -> Bool
    func wsClearBlockingConnectivityIssue(assetId: String?)
    func wsPromoteProcessingStage(assetId: String)
    func wsIsBatchAssetId(assetId: String?) -> Bool
    func wsSetBatchClipPhase(assetId: String?, phase: VideoBubblePhase)
    func wsFetchAssetDetail(assetId: String)
    func wsRegisterActiveAsset(assetId: String?)
    func wsPromoteFailedStage(assetId: String?)
    func wsMarkBatchClipFailed(assetId: String?, reason: String)
    func wsAppendUploadFailedBubble(assetId: String?, reason: String)
}

@MainActor
final class WebSocketUploadLifecycleEventService {
    func handleUploadComplete(data: [String: Any], runtime: WebSocketUploadLifecycleEventRuntime) {
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

    func handleStreamErrored(data: [String: Any], runtime: WebSocketUploadLifecycleEventRuntime) {
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
