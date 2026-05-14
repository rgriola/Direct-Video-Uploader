// May 13, 2026 - 11:59pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation
import UIKit

@MainActor
final class BatchAssetFlowService {
    struct CreateBatchAssetDependencies {
        let registerAsset: (Asset) -> Void
        let appendOutgoingMessage: (ChatMessage) -> Void
        let storeUploadInfo: (_ messageId: String, _ assetId: String, _ uploadInfo: SentUploadInfo)
            -> Void
        let markBatchUploadStarted: (_ assetId: String) -> Void
        let savePHAssetIdentifier: (_ assetId: String, _ identifier: String) -> Void
        let sendVideoUpload: (_ assetId: String, _ fileName: String, _ fileSize: Int64) -> Void
        let isConnectivityIssue: (Error) -> Bool
        let noteBlockingConnectivityIssue: (_ operation: String, _ assetId: String?) -> Void
        let appendStartErrorBubble: () -> Void
        let reportStartError: (_ errorDescription: String, _ fileName: String) async -> Void
    }

    struct UploadBatchVideoDependencies {
        let markAssetFailed: (_ assetId: String, _ reason: String) -> Void
        let isConnectivityIssue: (Error) -> Bool
        let noteBlockingConnectivityIssue: (_ operation: String, _ assetId: String?) -> Void
        let reportUploadError: (_ errorDescription: String, _ assetId: String) async -> Void
    }

    func createBatchAsset(
        fileName: String,
        fileURL: URL,
        thumbnail: UIImage?,
        createdDate: String?,
        hasLocation: Bool,
        phAssetIdentifier: String?,
        auth: AuthService,
        transport: BatchUploadTransportService,
        presentation: BatchAssetPresentationService,
        dependencies: CreateBatchAssetDependencies
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
                hasLocation: hasLocation
            )
            dependencies.appendOutgoingMessage(assetPresentation.message)
            dependencies.storeUploadInfo(
                assetPresentation.messageId,
                asset.id,
                assetPresentation.uploadInfo
            )
            dependencies.markBatchUploadStarted(asset.id)

            if let phAssetIdentifier {
                dependencies.savePHAssetIdentifier(asset.id, phAssetIdentifier)
            }

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

    func uploadBatchVideo(
        assetId: String,
        fileURL: URL,
        metadata: VideoMetadata,
        authToken: String?,
        transport: BatchUploadTransportService,
        onProgress: @escaping (Double) -> Void,
        dependencies: UploadBatchVideoDependencies
    ) async -> Bool {
        guard let token = authToken else { return false }

        do {
            let clipId = try await transport.uploadViaMux(
                assetId: assetId,
                fileURL: fileURL,
                token: token,
                metadata: metadata,
                onProgress: onProgress
            )
            print(
                "✅ [Batch Upload] Mux direct upload completed for asset: \(assetId), clipId: \(clipId)"
            )
            return true
        } catch {
            print("❌ [Batch Upload] Failed for asset \(assetId): \(error)")
            dependencies.markAssetFailed(assetId, error.localizedDescription)

            if dependencies.isConnectivityIssue(error) {
                dependencies.noteBlockingConnectivityIssue("uploading video", assetId)
            } else {
                // Batch clips surface failure directly on their own upload cards.
            }

            await dependencies.reportUploadError(error.localizedDescription, assetId)
            return false
        }
    }
}
