// May 14, 2026 - 2:05pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

/// Concrete `IngestTransport` for Mux direct upload (the streaming-playback path).
/// Wraps `VideoUploadService.uploadViaMux` so the rest of the app can talk to a vendor-neutral
/// `IngestTransport`. The byte-level Mux/tus logic still lives in `VideoUploadService`; this
/// file is intentionally thin so swapping streaming vendors later is a one-file change.
@MainActor
final class MuxStreamingTransport: IngestTransport {
    let kind: IngestTransportKind = .streamingMux

    private let uploaderFactory: @MainActor () -> VideoUploadService

    init(uploaderFactory: @escaping @MainActor () -> VideoUploadService = { VideoUploadService() }) {
        self.uploaderFactory = uploaderFactory
    }

    func upload(
        assetId: String,
        fileURL: URL,
        token: String,
        metadata: VideoMetadata,
        onProgress: @escaping (Double) -> Void
    ) async throws -> IngestUploadResult {
        let uploader = uploaderFactory()

        // TODO (Priority 5+): replace this poll loop with an `AsyncStream<Double>` exposed by
        // `VideoUploadService`. Polling a published property is a known anti-pattern; preserved
        // here only to keep the Priority 3 diff to "introduce the seam, do not change behavior."
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                onProgress(uploader.uploadProgress)
                if !uploader.isUploading {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { progressTask.cancel() }

        do {
            let response = try await uploader.uploadViaMux(
                assetId: assetId,
                fileURL: fileURL,
                token: token,
                metadata: metadata
            )
            onProgress(0.95)
            return IngestUploadResult(
                clipId: response.clipId,
                providerUploadId: response.muxUploadId
            )
        } catch {
            throw IngestError.providerError(underlying: error)
        }
    }
}
