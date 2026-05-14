// May 14, 2026 - 2:05pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

/// Placeholder `IngestTransport` for full-resolution archive uploads (S3 multipart, B2, R2, or
/// a server-resumable endpoint). Not yet implemented — the seam exists so the registry, server
/// contract, and call sites can be wired and reviewed without waiting on the archive vendor.
///
/// Default product model (per plan-iosCodeReview.md Priority 3): phone uploads the full-res master
/// here once; server pulls into Mux for streaming. Phone never uploads twice.
@MainActor
final class ArchiveIngestTransport: IngestTransport {
    let kind: IngestTransportKind

    init(kind: IngestTransportKind = .archiveS3Multipart) {
        precondition(
            kind.isArchive,
            "ArchiveIngestTransport requires an archive transport kind, got \(kind.rawValue)"
        )
        self.kind = kind
    }

    func upload(
        assetId: String,
        fileURL: URL,
        token: String,
        metadata: VideoMetadata,
        onProgress: @escaping (Double) -> Void
    ) async throws -> IngestUploadResult {
        throw IngestError.notImplemented(kind)
    }
}
