// May 13, 2026 - 9:02pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

struct PendingBatchRestoreSnapshot {
    let batchId: String
    let batchItems: [VideoBatchItem]
    let batchContext: VideoBatchContext?
    let stagedBatchVideos: [SelectedVideo]
    let pendingBatchFormData: [String: String]?
    let batchState: VideoBatchState
    let shouldClearAfterRestore: Bool
}

@MainActor
final class PendingBatchRestoreService {
    func makeSnapshot(
        pending: VideoBatch,
        uploadQueueRecovery: UploadQueueRecoveryService
    ) -> PendingBatchRestoreSnapshot {
        var updatedItems = pending.items
        var restoredState = pending.state
        let restoredStagedVideos = pending.stagedVideos ?? []
        let restoredFormData = pending.groupedFormData

        let persistedQueueByAssetId = uploadQueueRecovery.latestTasksByAssetId()
        let hasQueueMappingsForBatch = uploadQueueRecovery.hasQueueMappingsForBatch(
            items: updatedItems,
            persistedTasksByAssetId: persistedQueueByAssetId
        )

        let hasRecoveryInputs =
            (!restoredStagedVideos.isEmpty && restoredFormData != nil) || hasQueueMappingsForBatch

        if hasRecoveryInputs && (pending.state == .uploading || pending.state == .paused) {
            var hasRecoverableRunningWork = false

            for index in updatedItems.indices where updatedItems[index].status != .complete {
                let persistedTask: PersistedUploadTask?
                if let assetId = updatedItems[index].assetId {
                    persistedTask = persistedQueueByAssetId[assetId]
                } else {
                    persistedTask = nil
                }

                let recoveredState = uploadQueueRecovery.recoveredBatchItemState(
                    currentItem: updatedItems[index],
                    persistedTask: persistedTask
                )

                updatedItems[index].status = recoveredState.status
                updatedItems[index].error = recoveredState.error
                updatedItems[index].progress = recoveredState.progress

                if recoveredState.hasRecoverableRunningWork {
                    hasRecoverableRunningWork = true
                }
            }

            restoredState = hasRecoverableRunningWork ? .uploading : .partialFailed
        } else if !hasRecoveryInputs, pending.state != .queued {
            // Older snapshots may not include enough data to retry; keep the batch clearable.
            restoredState = .paused
        }

        return PendingBatchRestoreSnapshot(
            batchId: pending.id,
            batchItems: updatedItems,
            batchContext: pending.context,
            stagedBatchVideos: restoredStagedVideos,
            pendingBatchFormData: restoredFormData,
            batchState: restoredState,
            shouldClearAfterRestore: updatedItems.allSatisfy { $0.status == .complete }
        )
    }
}
