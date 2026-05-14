// May 13, 2026 - 11:59pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation
import UIKit

@MainActor
final class SingleUploadFlowService {
    struct CreateAssetDependencies {
        let registerAsset: (Asset) -> Void
        let appendOutgoingMessage: (ChatMessage) -> Void
        let storeUploadInfo: (_ messageId: String, _ assetId: String, _ uploadInfo: SentUploadInfo)
            -> Void
        let sendVideoUpload: (_ assetId: String, _ fileName: String, _ fileSize: Int64) -> Void
        let isConnectivityIssue: (Error) -> Bool
        let noteBlockingConnectivityIssue: (_ operation: String, _ assetId: String?) -> Void
        let appendStartErrorBubble: () -> Void
        let reportStartError: (_ errorDescription: String, _ fileName: String) async -> Void
    }

    struct UploadVideoDependencies {
        let setUploading: (Bool) -> Void
        let updateProgress: (Double) -> Void
        let markAssetFailed: () -> Void
        let isConnectivityIssue: (Error) -> Bool
        let noteBlockingConnectivityIssue: (_ operation: String, _ assetId: String?) -> Void
        let appendUploadErrorBubble: (_ reason: String) -> Void
        let reportUploadError: (_ errorDescription: String) async -> Void
    }

    func createAsset(
        fileName: String,
        fileURL: URL,
        thumbnail: UIImage?,
        createdDate: String?,
        hasLocation: Bool,
        transcribeEnabled: Bool,
        auth: AuthService,
        transport: BatchUploadTransportService,
        presentation: BatchAssetPresentationService,
        dependencies: CreateAssetDependencies
    ) async -> Asset? {
        let fileSize = transport.fileSize(for: fileURL)

        do {
            let asset = try await transport.createAsset(auth: auth, fileName: fileName)
            dependencies.registerAsset(asset)

            let assetPresentation = presentation.makePresentation(
                userId: auth.currentUser?.id,
                assetId: asset.id,
                fileName: fileName,
                thumbnail: thumbnail,
                createdDate: createdDate,
                hasLocation: hasLocation,
                transcribeEnabled: transcribeEnabled
            )

            dependencies.appendOutgoingMessage(assetPresentation.message)
            dependencies.storeUploadInfo(
                assetPresentation.messageId,
                asset.id,
                assetPresentation.uploadInfo
            )
            dependencies.sendVideoUpload(asset.id, fileName, fileSize)
            return asset
        } catch {
            if dependencies.isConnectivityIssue(error) {
                dependencies.noteBlockingConnectivityIssue("starting upload", nil)
            } else {
                dependencies.appendStartErrorBubble()
            }

            await dependencies.reportStartError(error.localizedDescription, fileName)
            return nil
        }
    }

    func uploadVideo(
        assetId: String,
        fileURL: URL,
        metadata: VideoMetadata?,
        token: String?,
        uploader: VideoUploadService,
        dependencies: UploadVideoDependencies
    ) async {
        guard let token else { return }

        dependencies.setUploading(true)
        dependencies.updateProgress(0)
        defer { dependencies.setUploading(false) }

        let progressTask = Task { @MainActor in
            while uploader.isUploading {
                dependencies.updateProgress(uploader.uploadProgress)
                try? await Task.sleep(for: .milliseconds(100))
            }
            dependencies.updateProgress(uploader.uploadProgress)
        }

        defer { progressTask.cancel() }

        do {
            let muxResult = try await uploader.uploadViaMux(
                assetId: assetId,
                fileURL: fileURL,
                token: token,
                metadata: metadata
            )
            print(
                "✅ [Upload] Mux direct upload completed for asset: \(assetId), clipId: \(muxResult.clipId)"
            )
        } catch {
            print("❌ [Upload] Failed for asset \(assetId): \(error)")
            dependencies.markAssetFailed()

            if dependencies.isConnectivityIssue(error) {
                dependencies.noteBlockingConnectivityIssue("uploading video", assetId)
            } else {
                dependencies.appendUploadErrorBubble(error.localizedDescription)
            }

            await dependencies.reportUploadError(error.localizedDescription)
        }
    }
}
