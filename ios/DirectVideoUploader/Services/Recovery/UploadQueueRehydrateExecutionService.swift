// May 14, 2026 - 3:35pm - GitHub Copilot (Claude Opus 4.7)
// Priority 5b: Dependencies closure-bag replaced with UploadQueueRehydrateHost protocol.
import Foundation

@MainActor
protocol UploadQueueRehydrateHost: AnyObject {
    func uqrHasCurrentAsset() -> Bool
    func uqrSetCurrentAsset(assetId: String)
    func uqrRegisterActiveAsset(assetId: String?)
    func uqrAppendSummaryMessage(_ message: ChatMessage)
    func uqrPromoteWorkflowStage(assetId: String, targetStage: WorkflowStage)
    func uqrSetBatchItems(_ items: [VideoBatchItem])
    func uqrSyncBatchDisplayState(assetId: String)
    func uqrHasUploadFailureMessage(assetId: String) -> Bool
    func uqrAppendUploadFailedBubble(assetId: String, reason: String)
    func uqrHasActiveBatch() -> Bool
    func uqrSetBatchState(_ state: VideoBatchState)
    func uqrUpdateBatchProgress()
    func uqrPersistBatchState()
    func uqrReconcileAssetDetails(assetIds: [String])
}

@MainActor
final class UploadQueueRehydrateExecutionService {
    func execute(plan: UploadQueueRehydratePlan, host: UploadQueueRehydrateHost) {
        if !host.uqrHasCurrentAsset(),
            let newestAssetId = plan.newestAssetId
        {
            host.uqrSetCurrentAsset(assetId: newestAssetId)
            host.uqrRegisterActiveAsset(assetId: newestAssetId)
        }

        if let summaryMessage = plan.summaryMessage {
            host.uqrAppendSummaryMessage(summaryMessage)
        }

        for transition in plan.workflowTransitions {
            if transition.shouldRegisterActiveAsset {
                host.uqrRegisterActiveAsset(assetId: transition.assetId)
            }
            host.uqrPromoteWorkflowStage(
                assetId: transition.assetId,
                targetStage: transition.targetStage
            )
        }

        host.uqrSetBatchItems(plan.updatedBatchItems)

        for assetId in plan.assetIdsForDisplaySync {
            host.uqrSyncBatchDisplayState(assetId: assetId)
        }

        for failedAsset in plan.failedNotices {
            if !host.uqrHasUploadFailureMessage(assetId: failedAsset.assetId) {
                host.uqrAppendUploadFailedBubble(
                    assetId: failedAsset.assetId,
                    reason: failedAsset.reason
                )
            }
        }

        if host.uqrHasActiveBatch() {
            if plan.hasUploadingBatchWork {
                host.uqrSetBatchState(.uploading)
            } else if plan.hasBatchFailures {
                host.uqrSetBatchState(.partialFailed)
            }

            host.uqrUpdateBatchProgress()

            if plan.shouldPersistBatch {
                host.uqrPersistBatchState()
            }
        }

        guard !plan.assetIdsToReconcile.isEmpty else { return }
        host.uqrReconcileAssetDetails(assetIds: plan.assetIdsToReconcile.sorted())
    }
}
