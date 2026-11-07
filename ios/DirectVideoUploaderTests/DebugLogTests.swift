import Foundation
import Testing
@testable import DirectVideoUploader

@Suite("Debug log failure categories")
struct DebugLogTests {
    @Test("Network errors", arguments: [
        (URLError(.notConnectedToInternet), Log.Failure.offline),
        (URLError(.networkConnectionLost), .offline),
        (URLError(.timedOut), .timedOut),
        (URLError(.cancelled), .cancelled),
        (URLError(.badServerResponse), .transport),
    ])
    func network(error: URLError, expected: Log.Failure) {
        #expect(Log.failure(error) == expected)
    }

    @Test("HTTP status codes", arguments: [
        (401, Log.Failure.unauthorized), (403, .unauthorized), (404, .notFound),
        (422, .rejected), (500, .server), (503, .server),
    ])
    func status(code: Int, expected: Log.Failure) {
        #expect(Log.failure(UploadError.serverError(code, "body")) == expected)
    }

    @Test("App errors")
    func appErrors() {
        #expect(Log.failure(CancellationError()) == .cancelled)
        #expect(Log.failure(AuthError.tokenExpired) == .unauthorized)
        #expect(Log.failure(AuthError.loginFailed("Wrong PIN")) == .rejected)
        #expect(Log.failure(WebSocketError.handshakeFailed) == .transport)
        #expect(Log.failure(OriginalVideoLoader.LoaderError.addAccessDenied) == .permission)
        #expect(Log.failure(PassthroughExporter.ExportError.cancelled) == .cancelled)
        #expect(Log.failure(PassthroughExporter.ExportError.exportFailed("x")) == .media)
        #expect(Log.failure(NSError(domain: "Other", code: 1)) == .other)
    }

    @Test("Descriptions never include the error message")
    func describeOmitsMessage() {
        let error = UploadError.serverError(500, "secret server text")
        let text = Log.describe(error)
        #expect(text.hasPrefix("server ("))
        #expect(!text.contains("secret"))
        #expect(!Log.describe(AuthError.loginFailed("Wrong PIN 1234")).contains("1234"))
    }
}
