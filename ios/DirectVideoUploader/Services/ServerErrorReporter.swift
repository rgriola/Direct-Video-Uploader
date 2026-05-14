// May 13, 2026 - 4:45pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class ServerErrorReporter {
    func report(
        auth: AuthService,
        category: String,
        message: String,
        severity: String = "WARNING",
        assetId: String? = nil,
        details: [String: String]? = nil
    ) async {
        guard auth.isAuthenticated else { return }

        var request = auth.authenticatedRequest(for: ServerConfig.errorsURL, method: "POST")
        var body: [String: Any] = [
            "source": "ios",
            "category": category,
            "message": message,
            "severity": severity,
        ]

        if let assetId {
            body["assetId"] = assetId
        }
        if let details {
            body["details"] = details
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Fire-and-forget — logging should never block primary user workflows.
        _ = try? await URLSession.shared.data(for: request)
    }
}
