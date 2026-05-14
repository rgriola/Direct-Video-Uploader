// May 14, 2026 - 3:35pm - GitHub Copilot (Claude Opus 4.7)
// Priority 5b: Dependencies closure-bags replaced with SingleUploadFlowHost protocol.
import Foundation
import UIKit

@MainActor
protocol SingleUploadFlowHost: AnyObject {
    // createAsset
    func sufRegisterAsset(_ asset: Asset)
    func sufAppendOutgoingMessage(_ message: ChatMessage)
    func sufStoreUploadInfo(messageId: String, assetId: String, uploadInfo: SentUploadInfo)
    func sufSendVideoUpload(assetId: String, fileName: String, fileSize: Int64)
    func sufAppendStartErrorBubble()
    func sufReportStartError(errorDescription: String, fileName: String) async

    // uploadVideo
    func sufSetUploading(_ isUploading: Bool)
    func sufUpdateProgress(_ progress: Double)
    func sufMarkAssetFailed(assetId: String)
    func sufAppendUploadErrorBubble(assetId: String, reason: String)
    func sufReportUploadError(assetId: String, errorDescription: String) async

    // shared
    func sufIsConnectivityIssue(_ error: Error) -> Bool
    func sufNoteBlockingConnectivityIssue(operation: String, assetId: String?)
}

@MainActor
final class SingleUploadFlowService {
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
        host: SingleUploadFlowHost
    ) async -> Asset? {
        let fileSize = transport.fileSize(for: fileURL)

        do {
            let asset = try await transport.createAsset(auth: auth, fileName: fileName)
            host.sufRegisterAsset(asset)

            let assetPresentation = presentation.makePresentation(
                userId: auth.currentUser?.id,
                assetId: asset.id,
                fileName: fileName,
                thumbnail: thumbnail,
                createdDate: createdDate,
                hasLocation: hasLocation,
                transcribeEnabled: transcribeEnabled
            )

            host.sufAppendOutgoingMessage(assetPresentation.message)
            host.sufStoreUploadInfo(
                messageId: assetPresentation.messageId,
                assetId: asset.id,
                uploadInfo: assetPresentation.uploadInfo
            )
            host.sufSendVideoUpload(
                assetId: asset.id,
                fileName: fileName,
                fileSize: fileSize
            )
            return asset
        } catch {
            if host.sufIsConnectivityIssue(error) {
                host.sufNoteBlockingConnectivityIssue(
                    operation: "starting upload",
                    assetId: nil
                )
            } else {
                host.sufAppendStartErrorBubble()
            }

            await host.sufReportStartError(
                errorDescription: error.localizedDescription,
                fileName: fileName
            )
            return nil
        }
    }

    func uploadVideo(
        assetId: String,
        fileURL: URL,
        metadata: VideoMetadata?,
        token: String?,
        uploader: VideoUploadService,
        host: SingleUploadFlowHost
    ) async {
        guard let token else { return }

        host.sufSetUploading(true)
        host.sufUpdateProgress(0)
        defer { host.sufSetUploading(false) }

        let progressTask = Task { @MainActor in
            while uploader.isUploading {
                host.sufUpdateProgress(uploader.uploadProgress)
                try? await Task.sleep(for: .milliseconds(100))
            }
            host.sufUpdateProgress(uploader.uploadProgress)
        }

        defer { progressTask.cancel() }

        do {
            let muxResult = try await uploader.uploadViaMux(
                assetId: assetId,
                fileURL: fileURL,
                token: token,
                metadata: metadata
            )
            AppLog.upload.info(
                "[Upload] Mux direct upload completed for asset: \(assetId), clipId: \(muxResult.clipId)"
            )
        } catch {
            AppLog.upload.error("[Upload] Failed for asset \(assetId): \(error.localizedDescription)")
            host.sufMarkAssetFailed(assetId: assetId)

            if host.sufIsConnectivityIssue(error) {
                host.sufNoteBlockingConnectivityIssue(
                    operation: "uploading video",
                    assetId: assetId
                )
            } else {
                host.sufAppendUploadErrorBubble(
                    assetId: assetId,
                    reason: error.localizedDescription
                )
            }

            await host.sufReportUploadError(
                assetId: assetId,
                errorDescription: error.localizedDescription
            )
        }
    }
}
