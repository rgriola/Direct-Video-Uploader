// May 14, 2026 - 1:35pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

@MainActor
final class FormSubmissionService {
    private let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func submitForm(assetId: String, formData: [String: String], auth: AuthService) async throws {
        let request = auth.authenticatedRequest(for: ServerConfig.formURL(assetId), method: "POST")
        _ = try await api.sendJSON(
            request,
            body: formData,
            expecting: EmptyResponse.self,
            validStatus: 200..<400
        )
    }
}

/// Decodes any successful response — used when the body is ignored.
private struct EmptyResponse: Decodable {
    init(from decoder: Decoder) throws {}
}
