// May 14, 2026 - 1:35pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

@MainActor
final class BatchUploadTransportService {
    private let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func fileSize(for fileURL: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attrs?[.size] as? Int64 ?? 0
    }

    func createAsset(auth: AuthService, fileName: String) async throws -> Asset {
        let request = auth.authenticatedRequest(for: ServerConfig.assetsURL, method: "POST")
        let body = CreateAssetRequest(fileName: fileName)

        return try await withRetry(attempts: 3) { [api] _ in
            do {
                let response = try await api.sendJSON(
                    request,
                    body: body,
                    expecting: CreateAssetResponse.self
                )
                return response.asset
            } catch {
                print("❌ createBatchAsset: \(error.localizedDescription)")
                throw error
            }
        }
    }

    func uploadViaMux(
        assetId: String,
        fileURL: URL,
        token: String,
        metadata: VideoMetadata,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        let uploader = VideoUploadService()

        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                onProgress(uploader.uploadProgress)
                if !uploader.isUploading {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        defer {
            progressTask.cancel()
        }

        let muxResult = try await uploader.uploadViaMux(
            assetId: assetId,
            fileURL: fileURL,
            token: token,
            metadata: metadata
        )
        onProgress(0.95)
        return muxResult.clipId
    }
}
