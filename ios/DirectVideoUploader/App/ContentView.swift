import SwiftUI

/// Root view — shows Login or Chat/Archive tabs depending on auth state.
struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundDisconnectTask: Task<Void, Never>?
    @State private var sessionCheckComplete = false
    
    var body: some View {
        Group {
            if !sessionCheckComplete {
                // Resolving stored token — show a neutral loading screen
                Theme.black.ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .tint(Theme.white.opacity(0.4))
                    }
            } else if auth.isAuthenticated && auth.currentUser != nil {
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
            // Validate stored token before showing any UI
            if auth.token != nil {
                do {
                    try await auth.fetchMe()
                } catch {
                    // fetchMe already calls logout() on 401/403;
                    // any other error (network down) also forces login
                    // so the user doesn't get stuck on a blank profile.
                    print("⚠️ [Session] Restore failed: \(error.localizedDescription) — clearing session")
                    auth.logout()
                }
            }
            sessionCheckComplete = true
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
