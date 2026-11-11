// May 10, 2026 - 12:59pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

@main
struct DirectVideoUploaderApp: App {
    // MARK: - Services (app-level singletons)

    @State private var auth: AuthService?
    @State private var ws = WebSocketService()
    @State private var permissions = PermissionManager()
    @State private var appearance = AppearanceService()

    var body: some Scene {
        WindowGroup {
            AuthSessionRoot(auth: $auth)
                .environment(ws)
                .environment(permissions)
                .environment(appearance)
        }
    }

    private struct AuthSessionRoot: View {
        @Binding var auth: AuthService?
        @AppStorage(UserDefaultsKeys.authToken) private var legacyAuthToken: String?

        var body: some View {
            Group {
                if let auth {
                    ContentView()
                        .environment(auth)
                } else {
                    Theme.black.ignoresSafeArea()
                        .overlay {
                            ProgressView("Checking sign-in")
                        }
                }
            }
            .task {
                guard auth == nil else { return }
                let hadLegacyToken = legacyAuthToken != nil
                legacyAuthToken = nil
                let service = AuthService()
                if hadLegacyToken, service.token == nil, service.errorMessage == nil {
                    service.errorMessage = "For security, please sign in again."
                }
                auth = service
            }
        }
    }
}
