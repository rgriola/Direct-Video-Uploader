// May 13, 2026 - 11:13pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class WorkflowReconcileExecutionService {
    struct Dependencies {
        let markBatchClipFailed: (String?, String) -> Void
        let appendUploadFailedBubble: (String, String) -> Void
        let updateBatchMetadataToProcessing: (Asset) -> Void
        let markBatchClipReady: (Asset) -> Void
        let appendFormConfirmed: (Asset, MessagePolicyCoordinator.Source) -> Void
        let resetReadyMessagePolicy: (String) -> Void
        let applyReadyWorkflowState: (Asset, MessagePolicyCoordinator.Source) -> Void
    }

    func execute(
        asset: Asset,
        plan: WorkflowReconcilePlanService.Plan,
        isBatchAsset: Bool,
        source: MessagePolicyCoordinator.Source,
        dependencies: Dependencies
    ) {
        if let failureReason = plan.failureReason {
            if isBatchAsset {
                dependencies.markBatchClipFailed(asset.id, failureReason)
            } else {
                dependencies.appendUploadFailedBubble(asset.id, failureReason)
            }
            return
        }

        if isBatchAsset {
            if plan.shouldUpdateBatchMetadataToProcessing {
                dependencies.updateBatchMetadataToProcessing(asset)
            }

            if plan.shouldMarkBatchReady {
                dependencies.markBatchClipReady(asset)
            }
            return
        }

        if plan.shouldAppendFormConfirmed {
            dependencies.appendFormConfirmed(asset, source)
        }

        if plan.shouldResetReadyMessagePolicy {
            dependencies.resetReadyMessagePolicy(asset.id)
        }

        if plan.shouldApplyReadyWorkflowState {
            dependencies.applyReadyWorkflowState(asset, source)
        }
    }
}
