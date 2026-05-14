// May 14, 2026 - 2:05pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

// MARK: - Transport Kind

/// Vendor-neutral identifier for an ingest transport mechanism.
/// The server returns this in an upload descriptor so the client knows how to dispatch.
/// Adding a new kind is the *only* iOS change required to support a new vendor.
enum IngestTransportKind: String, Codable, Sendable {
    /// Streaming playback target (today: Mux direct upload, tus-style PATCH to Mux CDN).
    case streamingMux = "streaming-mux"

    /// Full-resolution archive target via S3 multipart upload. Not yet implemented.
    case archiveS3Multipart = "archive-s3-multipart"

    /// Full-resolution archive target via a single signed PUT (B2/R2/etc). Not yet implemented.
    case archivePut = "archive-put"

    /// True if this transport is intended to deliver bytes for streaming playback.
    var isStreaming: Bool {
        switch self {
        case .streamingMux: return true
        case .archiveS3Multipart, .archivePut: return false
        }
    }

    /// True if this transport is intended to deliver the full-resolution master.
    var isArchive: Bool { !isStreaming }
}

// MARK: - Descriptor (server → client)

/// What the server tells the client to do. Vendor-agnostic surface.
/// The server today returns Mux-specific fields (`uploadUrl`, `muxUploadId`); a thin adapter
/// in the streaming transport maps those into this descriptor.
struct IngestUploadDescriptor: Sendable {
    let kind: IngestTransportKind
    /// The signed URL to PUT/PATCH bytes to.
    let uploadURL: URL
    /// Provider-side upload identifier (e.g. Mux upload ID, S3 multipart `UploadId`).
    /// `nil` for transports that do not expose one.
    let providerUploadId: String?
    /// Asset/clip identifier the server already minted.
    let clipId: String
}

// MARK: - Result (client → caller)

/// Result of a successful ingest, vendor-neutral.
struct IngestUploadResult: Sendable {
    let clipId: String
    let providerUploadId: String?
}

// MARK: - Errors

enum IngestError: LocalizedError {
    case notImplemented(IngestTransportKind)
    case unsupportedTransport(IngestTransportKind)
    case providerError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let kind):
            return "Ingest transport '\(kind.rawValue)' is not implemented yet."
        case .unsupportedTransport(let kind):
            return "Ingest transport '\(kind.rawValue)' is not supported on this client."
        case .providerError(let error):
            return error.localizedDescription
        }
    }
}

// MARK: - Protocol

/// One ingest target. iOS today uses `streamingMux` for playback; future builds will add
/// an archive transport for full-resolution storage. Both conform to this protocol so
/// callers (`BatchUploadTransportService`, future `MediaUploadCoordinator`) stay vendor-agnostic.
///
/// Default fan-out model (per plan-iosCodeReview.md Priority 3): the phone uploads the master once
/// to an archive transport; the server pulls it into Mux for streaming. Until the archive transport
/// lands, callers default to `streamingMux` and the existing flow is unchanged.
protocol IngestTransport: Sendable {
    var kind: IngestTransportKind { get }

    /// Perform the upload. Progress is delivered via `onProgress` (0.0 – 1.0).
    /// Implementations must surface vendor errors as `IngestError.providerError(underlying:)`.
    @MainActor
    func upload(
        assetId: String,
        fileURL: URL,
        token: String,
        metadata: VideoMetadata,
        onProgress: @escaping (Double) -> Void
    ) async throws -> IngestUploadResult
}
