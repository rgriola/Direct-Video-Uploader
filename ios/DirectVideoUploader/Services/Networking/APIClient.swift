// May 14, 2026 - 1:35pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

/// Structured error type for all `APIClient` operations.
/// Callers can switch on `kind` to distinguish transport, HTTP, and decoding failures.
struct APIError: LocalizedError {
    enum Kind {
        case transport(URLError)
        case http(status: Int, body: Data)
        case decoding(Error)
        case invalidResponse
    }

    let kind: Kind
    let url: URL?

    var errorDescription: String? {
        switch kind {
        case .transport(let urlError):
            return urlError.localizedDescription
        case .http(let status, let body):
            let bodyText = String(data: body, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if bodyText.isEmpty {
                return "Server returned HTTP \(status)"
            }
            return "Server returned HTTP \(status): \(bodyText.prefix(200))"
        case .decoding(let error):
            return "Response decoding failed: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid server response"
        }
    }

    /// Convenience for callers that want the HTTP status code (or `nil` for non-HTTP errors).
    var statusCode: Int? {
        if case .http(let status, _) = kind { return status }
        return nil
    }
}

/// Central HTTP client. Owns:
///   - sending a prepared `URLRequest`
///   - validating the HTTP status code
///   - decoding JSON responses
///   - mapping all failure modes to a single `APIError` type
///
/// Callers continue to build authenticated requests via `AuthService.authenticatedRequest(for:method:)`;
/// `APIClient` only handles transport + parsing. This keeps migration incremental.
@MainActor
final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder()
    ) {
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
    }

    // MARK: - Core send

    /// Send a prepared request, validate the status code, and return the raw body + status.
    /// - Parameters:
    ///   - request: the prepared `URLRequest` (typically from `AuthService.authenticatedRequest`).
    ///   - validStatus: status range considered successful. Pass `nil` to skip validation
    ///                  (caller will inspect the returned status itself).
    @discardableResult
    func sendRaw(
        _ request: URLRequest,
        validStatus: Range<Int>? = 200..<300
    ) async throws -> (data: Data, status: Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError(kind: .invalidResponse, url: request.url)
            }
            if let validStatus, !validStatus.contains(http.statusCode) {
                throw APIError(
                    kind: .http(status: http.statusCode, body: data),
                    url: request.url
                )
            }
            return (data, http.statusCode)
        } catch let apiError as APIError {
            throw apiError
        } catch let urlError as URLError {
            throw APIError(kind: .transport(urlError), url: request.url)
        } catch {
            throw APIError(kind: .invalidResponse, url: request.url)
        }
    }

    /// Send a prepared request and decode the JSON body into `T`.
    func send<T: Decodable>(
        _ request: URLRequest,
        expecting: T.Type,
        validStatus: Range<Int> = 200..<300
    ) async throws -> T {
        let (data, _) = try await sendRaw(request, validStatus: validStatus)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError(kind: .decoding(error), url: request.url)
        }
    }

    // MARK: - JSON body conveniences

    /// Encode an `Encodable` body, attach to the request, send, and decode the response.
    func sendJSON<Body: Encodable, T: Decodable>(
        _ request: URLRequest,
        body: Body,
        expecting: T.Type,
        validStatus: Range<Int> = 200..<300
    ) async throws -> T {
        var mutable = request
        mutable.httpBody = try encoder.encode(body)
        if mutable.value(forHTTPHeaderField: "Content-Type") == nil {
            mutable.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await send(mutable, expecting: expecting, validStatus: validStatus)
    }

    /// Encode a `[String: Any]` body via `JSONSerialization` and send.
    /// Use only when the body cannot be expressed as `Encodable` (mixed-type dictionaries).
    func sendJSONObject(
        _ request: URLRequest,
        body: [String: Any],
        validStatus: Range<Int> = 200..<300
    ) async throws -> (data: Data, status: Int) {
        var mutable = request
        mutable.httpBody = try JSONSerialization.data(withJSONObject: body)
        if mutable.value(forHTTPHeaderField: "Content-Type") == nil {
            mutable.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await sendRaw(mutable, validStatus: validStatus)
    }

    // MARK: - Fire-and-forget

    /// Send a request without throwing or decoding. Use for non-critical telemetry where
    /// failures must never block the caller.
    func fireAndForget(_ request: URLRequest) async {
        _ = try? await session.data(for: request)
    }
}
