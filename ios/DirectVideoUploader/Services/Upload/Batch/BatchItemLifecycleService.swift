// May 13, 2026 - 7:11pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

struct BatchItemProgressUpdate {
    let assetId: String?
    let progress: Double
}

@MainActor
final class BatchItemLifecycleService {
    func beginCreatingAsset(localId: String, batchItems: inout [VideoBatchItem]) -> Bool {
        guard let index = batchItems.firstIndex(where: { $0.localId == localId }) else {
            return false
        }

        batchItems[index].status = .creatingAsset
        batchItems[index].error = nil
        batchItems[index].progress = 0
        return true
    }

    func beginUploading(localId: String, assetId: String, batchItems: inout [VideoBatchItem]) -> Bool {
        guard let index = batchItems.firstIndex(where: { $0.localId == localId }) else {
            return false
        }

        batchItems[index].assetId = assetId
        batchItems[index].status = .uploading
        batchItems[index].progress = 0
        return true
    }

    func updateUploadProgress(
        localId: String,
        progress: Double,
        batchItems: inout [VideoBatchItem]
    ) -> BatchItemProgressUpdate? {
        guard let index = batchItems.firstIndex(where: { $0.localId == localId }) else {
            return nil
        }

        let clamped = min(max(progress, 0), 0.95)
        batchItems[index].progress = clamped
        return BatchItemProgressUpdate(assetId: batchItems[index].assetId, progress: clamped)
    }

    func beginApplyingForm(localId: String, batchItems: inout [VideoBatchItem]) -> BatchItemProgressUpdate? {
        guard let index = batchItems.firstIndex(where: { $0.localId == localId }) else {
            return nil
        }

        batchItems[index].status = .applyingForm
        batchItems[index].progress = 0.97
        return BatchItemProgressUpdate(assetId: batchItems[index].assetId, progress: 0.97)
    }

    func markComplete(localId: String, batchItems: inout [VideoBatchItem]) -> BatchItemProgressUpdate? {
        guard let index = batchItems.firstIndex(where: { $0.localId == localId }) else {
            return nil
        }

        batchItems[index].status = .complete
        batchItems[index].progress = 1
        return BatchItemProgressUpdate(assetId: batchItems[index].assetId, progress: 1)
    }

    func failedCount(batchItems: [VideoBatchItem]) -> Int {
        batchItems.filter { $0.status == .failed }.count
    }
}
