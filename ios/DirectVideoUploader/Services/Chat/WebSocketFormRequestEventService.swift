// May 13, 2026 - 11:58pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
protocol WebSocketFormRequestEventRuntime: AnyObject {
    func wsShouldSuppressMutation(assetId: String?, event: String) -> Bool
    func wsSetCurrentAssetId(_ assetId: String?)
    func wsRegisterActiveAsset(assetId: String?)
    func wsClearBlockingConnectivityIssue(assetId: String?)
    func wsPromoteFormRequestedStage(assetId: String)
    func wsSetFormContext(
        originalFileName: String?,
        clipCount: Int?,
        duration: Int?,
        capturedAt: String?
    )
    func wsLogSuppressedFormRequest(assetId: String)
    func wsHideFormSheet()
    func wsShowFormSheet()
    func wsSavePendingForm(_ pendingForm: PendingForm)
    func wsMakeFormThumbnailJPEGData() -> Data?
}

@MainActor
final class WebSocketFormRequestEventService {
    func handle(
        data: [String: Any],
        suppressPerAssetFormSheet: Bool,
        runtime: WebSocketFormRequestEventRuntime
    ) {
        let assetId = data["assetId"] as? String

        if runtime.wsShouldSuppressMutation(assetId: assetId, event: "form:request") {
            return
        }

        runtime.wsSetCurrentAssetId(assetId)
        runtime.wsRegisterActiveAsset(assetId: assetId)
        runtime.wsClearBlockingConnectivityIssue(assetId: assetId)

        if let assetId {
            runtime.wsPromoteFormRequestedStage(assetId: assetId)
        }

        let originalFileName = data["originalFileName"] as? String
        let clipCount = data["clipCount"] as? Int
        let duration = data["duration"] as? Int
        let capturedAt = data["capturedAt"] as? String

        runtime.wsSetFormContext(
            originalFileName: originalFileName,
            clipCount: clipCount,
            duration: duration,
            capturedAt: capturedAt
        )

        if suppressPerAssetFormSheet {
            if let assetId {
                runtime.wsLogSuppressedFormRequest(assetId: assetId)
            }
            runtime.wsHideFormSheet()
            return
        }

        runtime.wsShowFormSheet()

        if let assetId {
            runtime.wsSavePendingForm(
                PendingForm(
                    assetId: assetId,
                    originalFileName: originalFileName,
                    capturedAt: capturedAt,
                    clipCount: clipCount,
                    duration: duration,
                    thumbnailJPEG: runtime.wsMakeFormThumbnailJPEGData(),
                    savedAt: Date()
                )
            )
        }
    }
}
