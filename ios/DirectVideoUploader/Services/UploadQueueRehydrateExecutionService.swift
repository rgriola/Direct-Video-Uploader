// May 13, 2026 - 11:39pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class UploadQueueRehydrateExecutionService {
    struct Dependencies {
        let hasCurrentAsset: () -> Bool
        let setCurrentAsset: (String) -> Void
        let registerActiveAsset: (String?) -> Void
        let appendSummaryMessage: (ChatMessage) -> Void
        let promoteWorkflowStage: (String, WorkflowStage) -> Void
        let setBatchItems: ([VideoBatchItem]) -> Void
        let syncBatchDisplayState: (String) -> Void
        let hasUploadFailureMessage: (String) -> Bool
        let appendUploadFailedBubble: (String, String) -> Void
        let hasActiveBatch: () -> Bool
        let setBatchState: (VideoBatchState) -> Void
        let updateBatchProgress: () -> Void
        let persistBatchState: () -> Void
        let reconcileAssetDetails: ([String]) -> Void
    }

    func execute(plan: UploadQueueRehydratePlan, dependencies: Dependencies) {
        if !dependencies.hasCurrentAsset(),
            let newestAssetId = plan.newestAssetId
        {
            dependencies.setCurrentAsset(newestAssetId)
            dependencies.registerActiveAsset(newestAssetId)
        }

        if let summaryMessage = plan.summaryMessage {
            dependencies.appendSummaryMessage(summaryMessage)
        }

        for transition in plan.workflowTransitions {
            if transition.shouldRegisterActiveAsset {
                dependencies.registerActiveAsset(transition.assetId)
            }
            dependencies.promoteWorkflowStage(transition.assetId, transition.targetStage)
        }

        dependencies.setBatchItems(plan.updatedBatchItems)

        for assetId in plan.assetIdsForDisplaySync {
            dependencies.syncBatchDisplayState(assetId)
        }

        for failedAsset in plan.failedNotices {
            if !dependencies.hasUploadFailureMessage(failedAsset.assetId) {
                dependencies.appendUploadFailedBubble(failedAsset.assetId, failedAsset.reason)
            }
        }

        if dependencies.hasActiveBatch() {
            if plan.hasUploadingBatchWork {
                dependencies.setBatchState(.uploading)
            } else if plan.hasBatchFailures {
                dependencies.setBatchState(.partialFailed)
            }

            dependencies.updateBatchProgress()

            if plan.shouldPersistBatch {
                dependencies.persistBatchState()
            }
        }

        guard !plan.assetIdsToReconcile.isEmpty else { return }
        dependencies.reconcileAssetDetails(plan.assetIdsToReconcile.sorted())
    }
}
