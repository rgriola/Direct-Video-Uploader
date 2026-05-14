// May 13, 2026 - 10:59pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class BatchItemProcessingService {
    struct Dependencies {
        let prepareForProcessing: (String) -> BatchItemPreparationResult
        let noteItemPreparedForCreation: () -> Void
        let buildCreationContext: (BatchItemSelectedContext) async -> BatchItemCreationContext
        let createBatchAsset: (BatchItemCreationContext) async -> Asset?
        let prepareForUpload: (String, String) -> Bool
        let noteItemPreparedForUpload: (String) -> Void
        let uploadBatchVideo: (String, BatchItemCreationContext) async -> Bool
        let pendingFailureIndex: (String, Bool) -> Int?
        let markFailedAtIndex: (Int, String) -> Void
        let noteUploadSucceeded: (String) -> Void
        let prepareForApplyingForm: (String) -> BatchItemProgressUpdate?
        let noteItemPreparedForApplyingForm: (String, BatchItemProgressUpdate) -> Void
        let applyGroupedFormToAsset: (String) async -> Bool
        let prepareForCompletion: (String) -> BatchItemProgressUpdate?
        let noteItemCompleted: (BatchItemProgressUpdate, URL) -> Void
    }

    func process(localId: String, dependencies: Dependencies) async {
        let preparation = dependencies.prepareForProcessing(localId)

        switch preparation {
        case .skip:
            return

        case .markFailed(let index, let message):
            dependencies.markFailedAtIndex(index, message)
            return

        case .ready(let selectedContext):
            dependencies.noteItemPreparedForCreation()

            let creationContext = await dependencies.buildCreationContext(selectedContext)

            guard let asset = await dependencies.createBatchAsset(creationContext) else {
                dependencies.markFailedAtIndex(
                    creationContext.itemIndex,
                    "Could not create upload asset."
                )
                return
            }

            guard dependencies.prepareForUpload(localId, asset.id) else { return }

            dependencies.noteItemPreparedForUpload(asset.id)

            let didUpload = await dependencies.uploadBatchVideo(asset.id, creationContext)

            if !didUpload {
                if let index = dependencies.pendingFailureIndex(localId, true) {
                    dependencies.markFailedAtIndex(index, "Upload failed.")
                }
                return
            }

            dependencies.noteUploadSucceeded(asset.id)

            guard
                let applyingUpdate = dependencies.prepareForApplyingForm(localId)
            else {
                return
            }

            dependencies.noteItemPreparedForApplyingForm(asset.id, applyingUpdate)

            let didApplyForm = await dependencies.applyGroupedFormToAsset(asset.id)
            if !didApplyForm {
                if let index = dependencies.pendingFailureIndex(localId, false) {
                    dependencies.markFailedAtIndex(index, "Could not apply grouped form.")
                }
                return
            }

            guard
                let completedUpdate = dependencies.prepareForCompletion(localId)
            else {
                return
            }

            dependencies.noteItemCompleted(completedUpdate, creationContext.fileURL)
        }
    }
}
