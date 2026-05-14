// May 13, 2026 - 7:46pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

struct BatchRunCompletion {
    let failedCount: Int
    let nextState: VideoBatchState
    let shouldClearDraftState: Bool
    let batchIdToClear: String?
}

@MainActor
final class BatchRunExecutionService {
    func shouldStartRun(
        isBatchUploading: Bool,
        batchItems: [VideoBatchItem],
        pendingBatchFormData: [String: String]?
    ) -> Bool {
        guard !isBatchUploading else { return false }
        guard !batchItems.isEmpty else { return false }
        return pendingBatchFormData != nil
    }

    func completionState(batchItems: [VideoBatchItem], currentBatchId: String?) -> BatchRunCompletion {
        let failedCount = batchItems.filter { $0.status == .failed }.count
        return BatchRunCompletion(
            failedCount: failedCount,
            nextState: failedCount > 0 ? .partialFailed : .complete,
            shouldClearDraftState: failedCount == 0,
            batchIdToClear: failedCount == 0 ? currentBatchId : nil
        )
    }
}
