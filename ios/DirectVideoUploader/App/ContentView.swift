import SwiftUI

/// Root view — shows Login or Chat/Archive tabs depending on auth state.
struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundDisconnectTask: Task<Void, Never>?
    
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
                    
                    PhotosView()
                        .tabItem {
                            Image(systemName: "photo.fill")
                            Text("Photos")
                        }
                    
                    ProfileView()
                        .tabItem {
                            Image(systemName: "person.fill")
                            Text("Profile")
                        }
                }
                .tint(Theme.purple)
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
                // Cancel pending disconnect — user came back quickly
                backgroundDisconnectTask?.cancel()
                backgroundDisconnectTask = nil
                // Reconnect only if socket actually closed
                if auth.isAuthenticated, let token = auth.token, !ws.isConnected {
                    print("🔄 [Scene] Returned to foreground — reconnecting WebSocket")
                    ws.reconnectFromForeground(token: token)
                }
            case .background:
                // 30s grace period — quick tab switches won't disconnect
                if ws.isConnected {
                    backgroundDisconnectTask = Task {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { return }
                        print("💤 [Scene] Background timeout — closing WebSocket")
                        ws.backgroundDisconnect()
                    }
                }
            default:
                break
            }
        }
    }
}
