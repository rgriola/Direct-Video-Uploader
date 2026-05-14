// May 13, 2026 - 7:00pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class BatchUploadTransportService {
    func fileSize(for fileURL: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attrs?[.size] as? Int64 ?? 0
    }

    func createAsset(auth: AuthService, fileName: String) async throws -> Asset {
        var request = auth.authenticatedRequest(for: ServerConfig.assetsURL, method: "POST")
        let body = CreateAssetRequest(fileName: fileName)
        request.httpBody = try? JSONEncoder().encode(body)

        return try await withRetry(attempts: 3) { _ in
            let (data, httpResponse) = try await URLSession.shared.data(for: request)
            let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0

            guard statusCode >= 200, statusCode < 300 else {
                let body = String(data: data, encoding: .utf8) ?? "(empty)"
                print("❌ createBatchAsset HTTP \(statusCode): \(body)")
                throw NSError(
                    domain: "createBatchAsset",
                    code: statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Server returned \(statusCode)"]
                )
            }

            let response = try JSONDecoder().decode(CreateAssetResponse.self, from: data)
            return response.asset
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
