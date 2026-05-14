// May 13, 2026 - 10:33pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class WorkflowReconcilePlanService {
    struct Plan {
        let failureReason: String?
        let shouldUpdateBatchMetadataToProcessing: Bool
        let shouldMarkBatchReady: Bool
        let shouldAppendFormConfirmed: Bool
        let shouldResetReadyMessagePolicy: Bool
        let shouldApplyReadyWorkflowState: Bool
    }

    func makePlan(
        asset: Asset,
        reconciledStage: WorkflowStage,
        previousStage: WorkflowStage,
        isBatchAsset: Bool,
        hasReadySummary: Bool,
        hasReadyFollowup: Bool
    ) -> Plan {
        let isNewFailure = reconciledStage == .failed && previousStage != .failed
        if isNewFailure {
            return Plan(
                failureReason: "Processing error",
                shouldUpdateBatchMetadataToProcessing: false,
                shouldMarkBatchReady: false,
                shouldAppendFormConfirmed: false,
                shouldResetReadyMessagePolicy: false,
                shouldApplyReadyWorkflowState: false
            )
        }

        if isBatchAsset {
            return Plan(
                failureReason: nil,
                shouldUpdateBatchMetadataToProcessing:
                    asset.formResponse != nil
                    && reconciledStage.rawValue >= WorkflowStage.formConfirmed.rawValue,
                shouldMarkBatchReady: reconciledStage == .ready,
                shouldAppendFormConfirmed: false,
                shouldResetReadyMessagePolicy: false,
                shouldApplyReadyWorkflowState: false
            )
        }

        let shouldAppendFormConfirmed =
            asset.formResponse != nil
            && reconciledStage.rawValue >= WorkflowStage.formConfirmed.rawValue

        guard reconciledStage == .ready else {
            return Plan(
                failureReason: nil,
                shouldUpdateBatchMetadataToProcessing: false,
                shouldMarkBatchReady: false,
                shouldAppendFormConfirmed: shouldAppendFormConfirmed,
                shouldResetReadyMessagePolicy: false,
                shouldApplyReadyWorkflowState: false
            )
        }

        let stageAlreadyReady =
            previousStage != .failed
            && previousStage.rawValue >= WorkflowStage.ready.rawValue
        let messagesMissing = !hasReadySummary || !hasReadyFollowup
        let shouldApplyReadyWorkflowState = !stageAlreadyReady || messagesMissing

        return Plan(
            failureReason: nil,
            shouldUpdateBatchMetadataToProcessing: false,
            shouldMarkBatchReady: false,
            shouldAppendFormConfirmed: shouldAppendFormConfirmed,
            shouldResetReadyMessagePolicy: stageAlreadyReady && messagesMissing,
            shouldApplyReadyWorkflowState: shouldApplyReadyWorkflowState
        )
    }
}
