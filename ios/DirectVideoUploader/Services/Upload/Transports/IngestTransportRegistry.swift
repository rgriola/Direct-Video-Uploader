// May 14, 2026 - 2:05pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

/// Resolves an `IngestTransportKind` to a concrete `IngestTransport`.
///
/// Today the server does not yet send a transport hint, so callers default to `.streamingMux`
/// and the registry returns `MuxStreamingTransport`. When the server starts emitting hints
/// (Priority 3 follow-up + server work), the call site simply passes the hint through.
@MainActor
final class IngestTransportRegistry {
    static let shared = IngestTransportRegistry()

    private var transports: [IngestTransportKind: IngestTransport]

    init(transports: [IngestTransport] = IngestTransportRegistry.defaultTransports()) {
        self.transports = Dictionary(uniqueKeysWithValues: transports.map { ($0.kind, $0) })
    }

    /// Default transport set: streaming Mux today, archive stubs registered so unsupported-kind
    /// errors surface as `IngestError.notImplemented` (intentional, swap-friendly) rather than
    /// `IngestError.unsupportedTransport` (means "client doesn't know about this kind at all").
    private static func defaultTransports() -> [IngestTransport] {
        [
            MuxStreamingTransport(),
            ArchiveIngestTransport(kind: .archiveS3Multipart),
            ArchiveIngestTransport(kind: .archivePut),
        ]
    }

    func transport(for kind: IngestTransportKind) -> IngestTransport? {
        transports[kind]
    }

    /// Test/runtime injection point. Replaces or adds a transport for a given kind.
    func register(_ transport: IngestTransport) {
        transports[transport.kind] = transport
    }
}
