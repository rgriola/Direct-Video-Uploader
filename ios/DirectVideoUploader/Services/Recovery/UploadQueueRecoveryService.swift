// May 13, 2026 - 5:37pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

struct RecoveredBatchItemState {
    let status: VideoBatchItemStatus
    let progress: Double
    let error: String?
    let hasRecoverableRunningWork: Bool
}

struct UploadQueueTaskRecoveryPlan {
    enum Kind {
        case uploading
        case processing
        case failed(reason: String)
    }

    let assetId: String
    let kind: Kind
}

struct UploadQueueRehydrateBatchEffects {
    let updatedBatchItems: [VideoBatchItem]
    let shouldPersistBatch: Bool
    let hasUploadingBatchWork: Bool
    let hasBatchFailures: Bool
    let assetIdsToReconcile: Set<String>
    let failedWithoutBatchItem: [(assetId: String, reason: String)]
}

struct UploadQueueRehydrateSnapshot {
    let newestAssetId: String?
    let recoveryPlans: [UploadQueueTaskRecoveryPlan]
    let summaryMessage: ChatMessage?
}

final class UploadQueueRecoveryService {
    private let interruptedUploadMessage =
        "Upload interrupted by app restart. Tap Retry Failed."

    func latestTasksByAssetId() -> [String: PersistedUploadTask] {
        var latestByAssetId: [String: PersistedUploadTask] = [:]

        for task in UploadQueueStore.all() {
            if let existing = latestByAssetId[task.assetId], existing.updatedAt >= task.updatedAt {
                continue
            }
            latestByAssetId[task.assetId] = task
        }

        return latestByAssetId
    }

    func makeRehydrateSnapshot(existingMessages: [ChatMessage]) -> UploadQueueRehydrateSnapshot? {
        let latestByAssetId = latestTasksByAssetId()
        guard !latestByAssetId.isEmpty else { return nil }

        let tasks = Array(latestByAssetId.values)
        let recoveryPlans = tasks.compactMap { task in
            taskRecoveryPlan(for: task)
        }
        let newestAssetId = latestByAssetId.values.max(by: { $0.updatedAt < $1.updatedAt })?.assetId
        let summaryMessage = makeRestoreSummaryMessageIfNeeded(
            tasks: tasks,
            existingMessages: existingMessages
        )

        return UploadQueueRehydrateSnapshot(
            newestAssetId: newestAssetId,
            recoveryPlans: recoveryPlans,
            summaryMessage: summaryMessage
        )
    }

    func taskRecoveryPlan(for task: PersistedUploadTask) -> UploadQueueTaskRecoveryPlan? {
        let assetId = task.assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assetId.isEmpty else { return nil }

        switch task.state {
        case .pending, .running:
            return UploadQueueTaskRecoveryPlan(assetId: assetId, kind: .uploading)

        case .completed:
            return UploadQueueTaskRecoveryPlan(assetId: assetId, kind: .processing)

        case .failed:
            let trimmedReason = task.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = (trimmedReason?.isEmpty == false) ? trimmedReason! : interruptedUploadMessage
            return UploadQueueTaskRecoveryPlan(assetId: assetId, kind: .failed(reason: reason))
        }
    }

    func applyRehydratePlansToBatchItems(
        plans: [UploadQueueTaskRecoveryPlan],
        batchItems: [VideoBatchItem]
    ) -> UploadQueueRehydrateBatchEffects {
        var updatedBatchItems = batchItems
        var shouldPersistBatch = false
        var hasUploadingBatchWork = false
        var hasBatchFailures = false
        var assetIdsToReconcile: Set<String> = []
        var failedWithoutBatchItem: [(assetId: String, reason: String)] = []

        for plan in plans {
            let assetId = plan.assetId
            let batchIndex = updatedBatchItems.firstIndex(where: { $0.assetId == assetId })

            switch plan.kind {
            case .uploading:
                guard let batchIndex, updatedBatchItems[batchIndex].status != .complete else {
                    assetIdsToReconcile.insert(assetId)
                    continue
                }

                updatedBatchItems[batchIndex].status = .uploading
                updatedBatchItems[batchIndex].error = nil
                updatedBatchItems[batchIndex].progress = max(updatedBatchItems[batchIndex].progress, 0.05)
                shouldPersistBatch = true
                hasUploadingBatchWork = true
                assetIdsToReconcile.insert(assetId)

            case .processing:
                guard let batchIndex, updatedBatchItems[batchIndex].status != .complete else {
                    assetIdsToReconcile.insert(assetId)
                    continue
                }

                updatedBatchItems[batchIndex].status = .applyingForm
                updatedBatchItems[batchIndex].error = nil
                updatedBatchItems[batchIndex].progress = max(updatedBatchItems[batchIndex].progress, 0.97)
                shouldPersistBatch = true
                hasUploadingBatchWork = true
                assetIdsToReconcile.insert(assetId)

            case .failed(let reason):
                guard let batchIndex else {
                    failedWithoutBatchItem.append((assetId: assetId, reason: reason))
                    continue
                }

                updatedBatchItems[batchIndex].status = .failed
                updatedBatchItems[batchIndex].error = reason
                updatedBatchItems[batchIndex].progress = 0
                shouldPersistBatch = true
                hasBatchFailures = true
            }
        }

        return UploadQueueRehydrateBatchEffects(
            updatedBatchItems: updatedBatchItems,
            shouldPersistBatch: shouldPersistBatch,
            hasUploadingBatchWork: hasUploadingBatchWork,
            hasBatchFailures: hasBatchFailures,
            assetIdsToReconcile: assetIdsToReconcile,
            failedWithoutBatchItem: failedWithoutBatchItem
        )
    }

    func hasQueueMappingsForBatch(
        items: [VideoBatchItem],
        persistedTasksByAssetId: [String: PersistedUploadTask]
    ) -> Bool {
        items.contains { item in
            guard let assetId = item.assetId, !assetId.isEmpty else { return false }
            return persistedTasksByAssetId[assetId] != nil
        }
    }

    func recoveredBatchItemState(
        currentItem: VideoBatchItem,
        persistedTask: PersistedUploadTask?
    ) -> RecoveredBatchItemState {
        if currentItem.status == .complete {
            return RecoveredBatchItemState(
                status: .complete,
                progress: currentItem.progress,
                error: currentItem.error,
                hasRecoverableRunningWork: false
            )
        }

        guard let persistedTask else {
            let fallbackError =
                (currentItem.error?.isEmpty ?? true)
                ? interruptedUploadMessage
                : currentItem.error

            return RecoveredBatchItemState(
                status: .failed,
                progress: 0,
                error: fallbackError,
                hasRecoverableRunningWork: false
            )
        }

        switch persistedTask.state {
        case .pending, .running:
            return RecoveredBatchItemState(
                status: .uploading,
                progress: max(currentItem.progress, 0.05),
                error: nil,
                hasRecoverableRunningWork: true
            )

        case .completed:
            return RecoveredBatchItemState(
                status: .applyingForm,
                progress: max(currentItem.progress, 0.97),
                error: nil,
                hasRecoverableRunningWork: true
            )

        case .failed:
            return RecoveredBatchItemState(
                status: .failed,
                progress: 0,
                error: persistedTask.errorMessage ?? interruptedUploadMessage,
                hasRecoverableRunningWork: false
            )
        }
    }

    func makeRestoreSummaryMessageIfNeeded(
        tasks: [PersistedUploadTask],
        existingMessages: [ChatMessage]
    ) -> ChatMessage? {
        guard !tasks.isEmpty else { return nil }

        let hasExistingSummary = existingMessages.contains { message in
            message.content.code == "IOS_UPLOAD_RESTORE_SUMMARY"
        }
        guard !hasExistingSummary else { return nil }

        let activeCount = tasks.filter { $0.state == .pending || $0.state == .running }.count
        let awaitingMetadataCount = tasks.filter { $0.state == .completed }.count
        let failedCount = tasks.filter { $0.state == .failed }.count

        var summaryParts: [String] = []
        if activeCount > 0 {
            summaryParts.append("\(activeCount) active")
        }
        if awaitingMetadataCount > 0 {
            summaryParts.append("\(awaitingMetadataCount) awaiting sync")
        }
        if failedCount > 0 {
            summaryParts.append("\(failedCount) failed")
        }

        guard !summaryParts.isEmpty else { return nil }

        var text =
            "Recovered upload queue from your last session: \(summaryParts.joined(separator: ", "))."
        if failedCount > 0 {
            text += " Retry failed clips when ready."
        }

        let queueWaitSamples = tasks.compactMap(\.queueWaitMs)
        let transferSamples = tasks.compactMap(\.transferDurationMs)
        if let avgQueueWaitMs = average(queueWaitSamples),
            let avgTransferMs = average(transferSamples)
        {
            text +=
                " Recent averages - queue wait \(formatDurationMsForSummary(avgQueueWaitMs)), transfer \(formatDurationMsForSummary(avgTransferMs))."
        }

        return ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: nil,
            direction: .incoming,
            messageType: .systemNote,
            content: MessageContent(
                text: text,
                code: "IOS_UPLOAD_RESTORE_SUMMARY",
                params: [
                    "activeCount": "\(activeCount)",
                    "awaitingMetadataCount": "\(awaitingMetadataCount)",
                    "failedCount": "\(failedCount)",
                ],
                fallbackText: text,
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
    }

    private func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let total = values.reduce(0, +)
        return total / values.count
    }

    private func formatDurationMsForSummary(_ durationMs: Int) -> String {
        if durationMs < 1000 {
            return "\(durationMs)ms"
        }

        let seconds = Double(durationMs) / 1000
        return String(format: "%.1fs", seconds)
    }
}
