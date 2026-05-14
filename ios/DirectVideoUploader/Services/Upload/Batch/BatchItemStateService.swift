// May 13, 2026 - 6:38pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class BatchItemStateService {
    func computeProgress(items: [VideoBatchItem]) -> Double {
        guard !items.isEmpty else { return 0 }
        let total = items.reduce(0) { partial, item in
            partial + min(max(item.progress, 0), 1)
        }
        return total / Double(items.count)
    }

    func markFailedAtIndex(
        index: Int,
        message: String,
        batchItems: inout [VideoBatchItem],
        batchState: inout VideoBatchState,
        batchProgress: inout Double,
        batchClipDisplayByAssetId: inout [String: BatchClipDisplayState],
        batchClipDisplayService: BatchClipDisplayService
    ) {
        guard batchItems.indices.contains(index) else { return }

        let assetId = batchItems[index].assetId
        batchItems[index].status = .failed
        batchItems[index].error = message
        batchItems[index].progress = 0
        batchProgress = computeProgress(items: batchItems)

        if batchState != .partialFailed {
            batchState = .partialFailed
        }

        if let assetId {
            batchClipDisplayService.markFailedDisplay(
                assetId: assetId,
                reason: message,
                states: &batchClipDisplayByAssetId,
                batchItems: batchItems
            )
        }
    }
}
