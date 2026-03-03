import SwiftUI

/// Root view — shows Login or Chat depending on auth state.
struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    
    var body: some View {
        Group {
            if auth.isAuthenticated {
                ChatView()
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Try to restore session on launch
            if auth.token != nil {
                try? await auth.fetchMe()
            }
        }
    }
}
