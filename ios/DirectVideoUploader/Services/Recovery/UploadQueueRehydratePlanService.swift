// May 13, 2026 - 9:16pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

struct UploadQueueRehydrateWorkflowTransition {
    let assetId: String
    let targetStage: WorkflowStage
    let shouldRegisterActiveAsset: Bool
}

struct UploadQueueRehydrateFailedNotice {
    let assetId: String
    let reason: String
}

struct UploadQueueRehydratePlan {
    let newestAssetId: String?
    let summaryMessage: ChatMessage?
    let workflowTransitions: [UploadQueueRehydrateWorkflowTransition]
    let updatedBatchItems: [VideoBatchItem]
    let hasUploadingBatchWork: Bool
    let hasBatchFailures: Bool
    let shouldPersistBatch: Bool
    let failedNotices: [UploadQueueRehydrateFailedNotice]
    let assetIdsForDisplaySync: [String]
    let assetIdsToReconcile: [String]
}

@MainActor
final class UploadQueueRehydratePlanService {
    func makePlan(
        existingMessages: [ChatMessage],
        batchItems: [VideoBatchItem],
        uploadQueueRecovery: UploadQueueRecoveryService
    ) -> UploadQueueRehydratePlan? {
        guard let rehydrateSnapshot = uploadQueueRecovery.makeRehydrateSnapshot(
            existingMessages: existingMessages
        ) else { return nil }

        let recoveryPlans = rehydrateSnapshot.recoveryPlans
        let workflowTransitions = recoveryPlans.map { recoveryPlan in
            switch recoveryPlan.kind {
            case .uploading:
                return UploadQueueRehydrateWorkflowTransition(
                    assetId: recoveryPlan.assetId,
                    targetStage: .uploading,
                    shouldRegisterActiveAsset: true
                )
            case .processing:
                return UploadQueueRehydrateWorkflowTransition(
                    assetId: recoveryPlan.assetId,
                    targetStage: .processing,
                    shouldRegisterActiveAsset: true
                )
            case .failed:
                return UploadQueueRehydrateWorkflowTransition(
                    assetId: recoveryPlan.assetId,
                    targetStage: .failed,
                    shouldRegisterActiveAsset: false
                )
            }
        }

        let rehydrateEffects = uploadQueueRecovery.applyRehydratePlansToBatchItems(
            plans: recoveryPlans,
            batchItems: batchItems
        )

        let failedNotices = rehydrateEffects.failedWithoutBatchItem.map { failedAsset in
            UploadQueueRehydrateFailedNotice(
                assetId: failedAsset.assetId,
                reason: failedAsset.reason
            )
        }

        return UploadQueueRehydratePlan(
            newestAssetId: rehydrateSnapshot.newestAssetId,
            summaryMessage: rehydrateSnapshot.summaryMessage,
            workflowTransitions: workflowTransitions,
            updatedBatchItems: rehydrateEffects.updatedBatchItems,
            hasUploadingBatchWork: rehydrateEffects.hasUploadingBatchWork,
            hasBatchFailures: rehydrateEffects.hasBatchFailures,
            shouldPersistBatch: rehydrateEffects.shouldPersistBatch,
            failedNotices: failedNotices,
            assetIdsForDisplaySync: recoveryPlans.map(\.assetId),
            assetIdsToReconcile: Array(rehydrateEffects.assetIdsToReconcile)
        )
    }
}
