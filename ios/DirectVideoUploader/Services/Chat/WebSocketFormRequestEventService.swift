// May 14, 2026 - 3:10pm - GitHub Copilot (Claude Opus 4.7)
// Runtime protocol consolidated into Services/Chat/WebSocketEventRuntime.swift (Priority 5).
import Foundation

@MainActor
final class WebSocketFormRequestEventService {
    func handle(
        data: [String: Any],
        suppressPerAssetFormSheet: Bool,
        runtime: WebSocketEventRuntime
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
