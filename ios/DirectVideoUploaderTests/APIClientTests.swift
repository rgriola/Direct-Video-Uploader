// May 14, 2026 - 9:55am - GitHub Copilot (Claude Opus 4.7)
import XCTest

@testable import DirectVideoUploader

/// Mock URLProtocol that returns a canned response/data for any request.
/// Install on a `URLSessionConfiguration` to intercept all traffic.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stub: (status: Int, body: Data, headers: [String: String])?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = MockURLProtocol.stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class APIClientTests: XCTestCase {
    private struct Echo: Decodable, Equatable {
        let message: String
    }

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return APIClient(session: session)
    }

    override func tearDown() {
        MockURLProtocol.stub = nil
        super.tearDown()
    }

    func test_send_decodesSuccessBody() async throws {
        MockURLProtocol.stub = (
            status: 200,
            body: #"{"message":"hello"}"#.data(using: .utf8)!,
            headers: ["Content-Type": "application/json"]
        )
        let request = URLRequest(url: URL(string: "https://example.com/echo")!)
        let result = try await makeClient().send(request, expecting: Echo.self)
        XCTAssertEqual(result, Echo(message: "hello"))
    }

    func test_send_throwsHTTPErrorForNon2xx() async {
        MockURLProtocol.stub = (
            status: 500,
            body: Data("boom".utf8),
            headers: [:]
        )
        let request = URLRequest(url: URL(string: "https://example.com/fail")!)
        do {
            _ = try await makeClient().send(request, expecting: Echo.self)
            XCTFail("Expected APIError to be thrown")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 500)
        } catch {
            XCTFail("Expected APIError, got \(error)")
        }
    }

    func test_send_throwsDecodingErrorOnMalformedBody() async {
        MockURLProtocol.stub = (
            status: 200,
            body: Data("not json".utf8),
            headers: [:]
        )
        let request = URLRequest(url: URL(string: "https://example.com/bad")!)
        do {
            _ = try await makeClient().send(request, expecting: Echo.self)
            XCTFail("Expected decoding APIError")
        } catch let error as APIError {
            if case .decoding = error.kind {
                // success
            } else {
                XCTFail("Expected .decoding, got \(error.kind)")
            }
        } catch {
            XCTFail("Expected APIError, got \(error)")
        }
    }
}
