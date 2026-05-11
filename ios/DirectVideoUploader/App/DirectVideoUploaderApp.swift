// May 10, 2026 - 12:59pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

@main
struct DirectVideoUploaderApp: App {
    // MARK: - Services (app-level singletons)

    @State private var auth = AuthService()
    @State private var ws = WebSocketService()
    @State private var permissions = PermissionManager()
    @State private var appearance = AppearanceService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(ws)
                .environment(permissions)
                .environment(appearance)
        }
    }
}
