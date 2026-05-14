// May 13, 2026 - 8:36pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation
import UIKit

struct BatchItemSelectedContext {
    let localId: String
    let itemIndex: Int
    let selectedVideo: SelectedVideo
}

struct BatchItemCreationContext {
    let localId: String
    let itemIndex: Int
    let fileName: String
    let fileURL: URL
    let metadata: VideoMetadata
    let hasLocation: Bool
    let phAssetIdentifier: String?
    let thumbnail: UIImage?
    let createdDate: String?
}

enum BatchItemPreparationResult {
    case ready(BatchItemSelectedContext)
    case markFailed(index: Int, message: String)
    case skip
}

@MainActor
final class BatchItemExecutionService {
    func prepareForProcessing(
        localId: String,
        batchItems: inout [VideoBatchItem],
        stagedBatchVideos: [SelectedVideo],
        lifecycle: BatchItemLifecycleService
    ) -> BatchItemPreparationResult {
        guard let itemIndex = batchItems.firstIndex(where: { $0.localId == localId }) else {
            return .skip
        }

        guard let selected = stagedBatchVideos.first(where: { $0.id == localId }) else {
            return .markFailed(index: itemIndex, message: "Clip reference was lost.")
        }

        guard lifecycle.beginCreatingAsset(localId: localId, batchItems: &batchItems) else {
            return .skip
        }

        return .ready(
            BatchItemSelectedContext(localId: localId, itemIndex: itemIndex, selectedVideo: selected)
        )
    }

    func buildCreationContext(from selectedContext: BatchItemSelectedContext) async -> BatchItemCreationContext {
        let selected = selectedContext.selectedVideo
        let thumbnail = await StagedVideo.generateThumbnail(from: selected.fileURL)
        let createdDate = selected.metadata.capturedAt.map { DVUDateFormatting.longDate($0) }

        return BatchItemCreationContext(
            localId: selectedContext.localId,
            itemIndex: selectedContext.itemIndex,
            fileName: selected.fileName,
            fileURL: selected.fileURL,
            metadata: selected.metadata,
            hasLocation: selected.metadata.gpsLat != nil,
            phAssetIdentifier: selected.phAssetIdentifier,
            thumbnail: thumbnail,
            createdDate: createdDate
        )
    }

    func prepareForUpload(
        localId: String,
        assetId: String,
        batchItems: inout [VideoBatchItem],
        lifecycle: BatchItemLifecycleService
    ) -> Bool {
        lifecycle.beginUploading(localId: localId, assetId: assetId, batchItems: &batchItems)
    }

    func pendingFailureIndex(
        localId: String,
        batchItems: [VideoBatchItem],
        skipAlreadyFailed: Bool = true
    ) -> Int? {
        guard let index = batchItems.firstIndex(where: { $0.localId == localId }) else {
            return nil
        }

        if skipAlreadyFailed, batchItems[index].status == .failed {
            return nil
        }

        return index
    }

    func prepareForApplyingForm(
        localId: String,
        batchItems: inout [VideoBatchItem],
        lifecycle: BatchItemLifecycleService
    ) -> BatchItemProgressUpdate? {
        lifecycle.beginApplyingForm(localId: localId, batchItems: &batchItems)
    }

    func prepareForCompletion(
        localId: String,
        batchItems: inout [VideoBatchItem],
        lifecycle: BatchItemLifecycleService
    ) -> BatchItemProgressUpdate? {
        lifecycle.markComplete(localId: localId, batchItems: &batchItems)
    }
}
