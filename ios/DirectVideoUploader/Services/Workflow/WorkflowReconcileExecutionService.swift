// May 14, 2026 - 3:35pm - GitHub Copilot (Claude Opus 4.7)
// Priority 5b: Dependencies closure-bag replaced with WorkflowReconcileExecutionHost protocol.
import Foundation

@MainActor
protocol WorkflowReconcileExecutionHost: AnyObject {
    func wreMarkBatchClipFailed(assetId: String?, reason: String)
    func wreAppendUploadFailedBubble(assetId: String, reason: String)
    func wreUpdateBatchMetadataToProcessing(asset: Asset)
    func wreMarkBatchClipReady(asset: Asset)
    func wreAppendFormConfirmed(asset: Asset, source: MessagePolicyCoordinator.Source)
    func wreResetReadyMessagePolicy(assetId: String)
    func wreApplyReadyWorkflowState(asset: Asset, source: MessagePolicyCoordinator.Source)
}

@MainActor
final class WorkflowReconcileExecutionService {
    func execute(
        asset: Asset,
        plan: WorkflowReconcilePlanService.Plan,
        isBatchAsset: Bool,
        source: MessagePolicyCoordinator.Source,
        host: WorkflowReconcileExecutionHost
    ) {
        if let failureReason = plan.failureReason {
            if isBatchAsset {
                host.wreMarkBatchClipFailed(assetId: asset.id, reason: failureReason)
            } else {
                host.wreAppendUploadFailedBubble(assetId: asset.id, reason: failureReason)
            }
            return
        }

        if isBatchAsset {
            if plan.shouldUpdateBatchMetadataToProcessing {
                host.wreUpdateBatchMetadataToProcessing(asset: asset)
            }

            if plan.shouldMarkBatchReady {
                host.wreMarkBatchClipReady(asset: asset)
            }
            return
        }

        if plan.shouldAppendFormConfirmed {
            host.wreAppendFormConfirmed(asset: asset, source: source)
        }

        if plan.shouldResetReadyMessagePolicy {
            host.wreResetReadyMessagePolicy(assetId: asset.id)
        }

        if plan.shouldApplyReadyWorkflowState {
            host.wreApplyReadyWorkflowState(asset: asset, source: source)
        }
    }
}
