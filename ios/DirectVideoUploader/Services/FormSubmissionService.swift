// May 13, 2026 - 11:59pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class FormSubmissionService {
    func submitForm(assetId: String, formData: [String: String], auth: AuthService) async throws {
        var request = auth.authenticatedRequest(for: ServerConfig.formURL(assetId), method: "POST")
        request.httpBody = try? JSONSerialization.data(withJSONObject: formData)

        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
    }
}
