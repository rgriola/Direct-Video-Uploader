// May 14, 2026 - 2:05pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

@MainActor
final class BatchUploadTransportService {
    private let api: APIClient
    private let transportRegistry: IngestTransportRegistry

    init(
        api: APIClient = .shared,
        transportRegistry: IngestTransportRegistry = .shared
    ) {
        self.api = api
        self.transportRegistry = transportRegistry
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
                AppLog.upload.error("createBatchAsset: \(error.localizedDescription)")
                throw error
            }
        }
    }

    /// Run an ingest upload through the vendor-neutral transport registry.
    ///
    /// `kind` defaults to `.streamingMux` to preserve current behavior. When the server starts
    /// emitting an explicit transport hint, the call site can pass it through unchanged.
    func runIngest(
        kind: IngestTransportKind = .streamingMux,
        assetId: String,
        fileURL: URL,
        token: String,
        metadata: VideoMetadata,
        onProgress: @escaping (Double) -> Void
    ) async throws -> IngestUploadResult {
        guard let transport = transportRegistry.transport(for: kind) else {
            throw IngestError.unsupportedTransport(kind)
        }
        return try await transport.upload(
            assetId: assetId,
            fileURL: fileURL,
            token: token,
            metadata: metadata,
            onProgress: onProgress
        )
    }

    /// Backward-compatible shim for callers still naming the streaming path "Mux".
    /// Delegates through `runIngest(kind: .streamingMux, ...)`. Will be removed after
    /// Priority 3.5's vendor-name cleanup pass.
    @available(*, deprecated, message: "Use runIngest(kind:...). Will be removed after Priority 3.5.")
    func uploadViaMux(
        assetId: String,
        fileURL: URL,
        token: String,
        metadata: VideoMetadata,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        let result = try await runIngest(
            kind: .streamingMux,
            assetId: assetId,
            fileURL: fileURL,
            token: token,
            metadata: metadata,
            onProgress: onProgress
        )
        return result.clipId
    }
}
