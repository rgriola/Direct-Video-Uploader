import Foundation
import OSLog

/// Xcode-console logging, compiled out of Release builds. Filter by category in the console.
/// Never log tokens, credentials, response bodies, transcript text or `localizedDescription`;
/// describe errors with `Log.describe(_:)`.
nonisolated enum Log {
    static let subsystem = "com.directvideo.uploader"
    static let app = Logger(subsystem: subsystem, category: "App")
    static let auth = Logger(subsystem: subsystem, category: "Auth")
    static let network = Logger(subsystem: subsystem, category: "Network")
    static let upload = Logger(subsystem: subsystem, category: "Upload")
    static let media = Logger(subsystem: subsystem, category: "Media")
    static let transcription = Logger(subsystem: subsystem, category: "Transcription")

    enum Failure: String, Sendable {
        case cancelled, offline, timedOut, transport, decoding
        case unauthorized, notFound, permission, invalidResponse, server, rejected, media, other
    }

    static func failure(_ error: Error) -> Failure {
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return .offline
            case .timedOut: return .timedOut
            default: return .transport
            }
        }
        if error is DecodingError { return .decoding }
        if let error = error as? UploadError {
            switch error {
            case .invalidResponse, .unverifiedMode: return .invalidResponse
            case .serverError(let status, _): return failure(forStatus: status)
            case .fileNotFound: return .notFound
            case .sessionChanged: return .unauthorized
            }
        }
        if let error = error as? AuthError {
            switch error {
            case .invalidResponse: return .invalidResponse
            case .loginFailed, .loginInProgress, .restoreInProgress, .invalidServer: return .rejected
            case .notAuthenticated, .tokenExpired, .sessionChanged, .identityMismatch: return .unauthorized
            case .secureStorageFailed, .secureStorageCleanupIncomplete, .secureSignOutIncomplete:
                return .permission
            case .restoreUnavailable: return .transport
            }
        }
        if error is WebSocketError { return .transport }
        if let error = error as? OriginalVideoLoader.LoaderError {
            switch error {
            case .assetNotFound, .originalResourceMissing: return .notFound
            case .addAccessDenied: return .permission
            case .invalidOriginalFilename: return .media
            }
        }
        if let error = error as? PassthroughExporter.ExportError {
            if case .cancelled = error { return .cancelled }
            return .media
        }
        return .other
    }

    static func failure(forStatus status: Int) -> Failure {
        switch status {
        case 401, 403: .unauthorized
        case 404: .notFound
        case 500...: .server
        default: .rejected
        }
    }

    /// Failure category plus the error's domain and code; never its message or user info.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(failure(error).rawValue) (\(nsError.domain) \(nsError.code))"
    }

    static func debug(_ message: @autoclosure () -> String, logger: Logger = app) {
        #if DEBUG
        let resolved = message()
        logger.debug("\(resolved, privacy: .private)")
        #endif
    }

    /// Error level, so Xcode highlights it. Still Debug-only.
    static func error(_ message: @autoclosure () -> String, logger: Logger = app) {
        #if DEBUG
        let resolved = message()
        logger.error("\(resolved, privacy: .private)")
        #endif
    }
}
