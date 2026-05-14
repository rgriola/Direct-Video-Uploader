// May 14, 2026 - 3:35pm - GitHub Copilot (Claude Opus 4.7)
// Priority 5b: Dependencies closure-bag replaced with BatchItemProcessingHost protocol.
import Foundation

@MainActor
protocol BatchItemProcessingHost: AnyObject {
    func bipPrepareForProcessing(localId: String) -> BatchItemPreparationResult
    func bipNoteItemPreparedForCreation()
    func bipBuildCreationContext(
        from selectedContext: BatchItemSelectedContext
    ) async -> BatchItemCreationContext
    func bipCreateBatchAsset(creationContext: BatchItemCreationContext) async -> Asset?
    func bipPrepareForUpload(localId: String, assetId: String) -> Bool
    func bipNoteItemPreparedForUpload(assetId: String)
    func bipUploadBatchVideo(
        localId: String,
        assetId: String,
        creationContext: BatchItemCreationContext
    ) async -> Bool
    func bipPendingFailureIndex(localId: String, skipAlreadyFailed: Bool) -> Int?
    func bipMarkFailedAtIndex(index: Int, message: String)
    func bipNoteUploadSucceeded(assetId: String)
    func bipPrepareForApplyingForm(localId: String) -> BatchItemProgressUpdate?
    func bipNoteItemPreparedForApplyingForm(
        assetId: String,
        applyingUpdate: BatchItemProgressUpdate
    )
    func bipApplyGroupedFormToAsset(assetId: String) async -> Bool
    func bipPrepareForCompletion(localId: String) -> BatchItemProgressUpdate?
    func bipNoteItemCompleted(completedUpdate: BatchItemProgressUpdate, fileURL: URL)
}

@MainActor
final class BatchItemProcessingService {
    func process(localId: String, host: BatchItemProcessingHost) async {
        let preparation = host.bipPrepareForProcessing(localId: localId)

        switch preparation {
        case .skip:
            return

        case .markFailed(let index, let message):
            host.bipMarkFailedAtIndex(index: index, message: message)
            return

        case .ready(let selectedContext):
            host.bipNoteItemPreparedForCreation()

            let creationContext = await host.bipBuildCreationContext(from: selectedContext)

            guard let asset = await host.bipCreateBatchAsset(creationContext: creationContext)
            else {
                host.bipMarkFailedAtIndex(
                    index: creationContext.itemIndex,
                    message: "Could not create upload asset."
                )
                return
            }

            guard host.bipPrepareForUpload(localId: localId, assetId: asset.id) else { return }

            host.bipNoteItemPreparedForUpload(assetId: asset.id)

            let didUpload = await host.bipUploadBatchVideo(
                localId: localId,
                assetId: asset.id,
                creationContext: creationContext
            )

            if !didUpload {
                if let index = host.bipPendingFailureIndex(
                    localId: localId,
                    skipAlreadyFailed: true
                ) {
                    host.bipMarkFailedAtIndex(index: index, message: "Upload failed.")
                }
                return
            }

            host.bipNoteUploadSucceeded(assetId: asset.id)

            guard
                let applyingUpdate = host.bipPrepareForApplyingForm(localId: localId)
            else {
                return
            }

            host.bipNoteItemPreparedForApplyingForm(
                assetId: asset.id,
                applyingUpdate: applyingUpdate
            )

            let didApplyForm = await host.bipApplyGroupedFormToAsset(assetId: asset.id)
            if !didApplyForm {
                if let index = host.bipPendingFailureIndex(
                    localId: localId,
                    skipAlreadyFailed: false
                ) {
                    host.bipMarkFailedAtIndex(
                        index: index,
                        message: "Could not apply grouped form."
                    )
                }
                return
            }

            guard
                let completedUpdate = host.bipPrepareForCompletion(localId: localId)
            else {
                return
            }

            host.bipNoteItemCompleted(
                completedUpdate: completedUpdate,
                fileURL: creationContext.fileURL
            )
        }
    }
}
