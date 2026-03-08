import SwiftUI

/// Root view — shows Login or Chat/Archive tabs depending on auth state.
struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        Group {
            if auth.isAuthenticated {
                TabView {
                    ChatView()
                        .tabItem {
                            Image(systemName: "bubble.left.fill")
                            Text("Chat")
                        }
                    
                    ArchiveListView()
                        .tabItem {
                            Image(systemName: "archivebox.fill")
                            Text("Archive")
                        }
                }
                .tint(Theme.tint)
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
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Reconnect WebSocket if it died while backgrounded
                if auth.isAuthenticated, let token = auth.token, !ws.isConnected {
                    print("🔄 [Scene] Returned to foreground — reconnecting WebSocket")
                    ws.reconnectFromForeground(token: token)
                }
            case .background:
                // Graceful close — saves server resources, triggers clean disconnect
                if ws.isConnected {
                    print("💤 [Scene] Entering background — closing WebSocket gracefully")
                    ws.backgroundDisconnect()
                }
            default:
                break
            }
        }
    }
}
