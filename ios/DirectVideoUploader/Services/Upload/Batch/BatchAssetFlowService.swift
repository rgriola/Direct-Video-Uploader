// May 14, 2026 - 10:30am - GitHub Copilot (Claude Opus 4.7)
// Priority 5b: Dependencies closure-bags replaced with BatchAssetFlowHost protocol.
import Foundation
import UIKit

@MainActor
protocol BatchAssetFlowHost: AnyObject {
    // createBatchAsset
    func bafRegisterAsset(_ asset: Asset)
    func bafAppendOutgoingMessage(_ message: ChatMessage)
    func bafStoreUploadInfo(messageId: String, assetId: String, uploadInfo: SentUploadInfo)
    func bafMarkBatchUploadStarted(assetId: String)
    func bafSavePHAssetIdentifier(assetId: String, identifier: String)
    func bafSendVideoUpload(assetId: String, fileName: String, fileSize: Int64)
    func bafAppendStartErrorBubble()
    func bafReportStartError(errorDescription: String, fileName: String) async

    // uploadBatchVideo
    func bafMarkAssetFailed(assetId: String, reason: String)
    func bafReportUploadError(errorDescription: String, assetId: String) async

    // shared
    func bafIsConnectivityIssue(_ error: Error) -> Bool
    func bafNoteBlockingConnectivityIssue(operation: String, assetId: String?)
}

@MainActor
final class BatchAssetFlowService {
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
        host: BatchAssetFlowHost
    ) async -> Asset? {
        let fileSize = transport.fileSize(for: fileURL)

        do {
            let asset = try await transport.createAsset(auth: auth, fileName: fileName)
            host.bafRegisterAsset(asset)

            let assetPresentation = presentation.makePresentation(
                userId: auth.currentUser?.id,
                assetId: asset.id,
                fileName: fileName,
                thumbnail: thumbnail,
                createdDate: createdDate,
                hasLocation: hasLocation
            )
            host.bafAppendOutgoingMessage(assetPresentation.message)
            host.bafStoreUploadInfo(
                messageId: assetPresentation.messageId,
                assetId: asset.id,
                uploadInfo: assetPresentation.uploadInfo
            )
            host.bafMarkBatchUploadStarted(assetId: asset.id)

            if let phAssetIdentifier {
                host.bafSavePHAssetIdentifier(assetId: asset.id, identifier: phAssetIdentifier)
            }

            host.bafSendVideoUpload(
                assetId: asset.id,
                fileName: fileName,
                fileSize: fileSize
            )
            return asset
        } catch {
            if host.bafIsConnectivityIssue(error) {
                host.bafNoteBlockingConnectivityIssue(
                    operation: "starting upload",
                    assetId: nil
                )
            } else {
                host.bafAppendStartErrorBubble()
            }

            await host.bafReportStartError(
                errorDescription: error.localizedDescription,
                fileName: fileName
            )
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
        host: BatchAssetFlowHost
    ) async -> Bool {
        guard let token = authToken else { return false }

        do {
            let result = try await transport.runIngest(
                kind: .streamingMux,
                assetId: assetId,
                fileURL: fileURL,
                token: token,
                metadata: metadata,
                onProgress: onProgress
            )
            AppLog.upload.info(
                "[Batch Upload] Mux direct upload completed for asset: \(assetId), clipId: \(result.clipId)"
            )
            return true
        } catch {
            AppLog.upload.error("[Batch Upload] Failed for asset \(assetId): \(error.localizedDescription)")
            host.bafMarkAssetFailed(assetId: assetId, reason: error.localizedDescription)

            if host.bafIsConnectivityIssue(error) {
                host.bafNoteBlockingConnectivityIssue(
                    operation: "uploading video",
                    assetId: assetId
                )
            } else {
                // Batch clips surface failure directly on their own upload cards.
            }

            await host.bafReportUploadError(
                errorDescription: error.localizedDescription,
                assetId: assetId
            )
            return false
        }
    }
}
