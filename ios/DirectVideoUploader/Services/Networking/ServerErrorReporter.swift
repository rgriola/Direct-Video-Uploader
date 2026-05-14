// May 14, 2026 - 1:35pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

@MainActor
final class ServerErrorReporter {
    private let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

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
        await api.fireAndForget(request)
    }
}
