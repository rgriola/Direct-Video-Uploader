// May 14, 2026 - 2:50pm - GitHub Copilot (Claude Opus 4.7)
import SwiftUI

/// Root view — shows Login or Chat/Archive tabs depending on auth state.
struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    @Environment(AppearanceService.self) private var appearance
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundDisconnectTask: Task<Void, Never>?
    @State private var didRevalidateSession = false

    var body: some View {
        Group {
            if auth.isAuthenticated && auth.currentUser != nil {
                // Token + cached user — render authenticated UI immediately.
                // Silent /api/me revalidation runs in .task below.
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
                // No token, or token without cached user — show login immediately.
                // (currentUser is persisted alongside token, so this branch is rare.)
                LoginView()
            }
        }
        .preferredColorScheme(appearance.preferredColorScheme)
        .task {
            // Background revalidation — runs once per cold launch when authenticated.
            // Does NOT block the UI. Only logs the user out on a confirmed 401/403.
            // Network errors leave the cached session intact.
            guard !didRevalidateSession else { return }
            didRevalidateSession = true
            guard auth.token != nil else { return }
            do {
                try await auth.fetchMe()
            } catch AuthError.tokenExpired {
                AppLog.auth.info("[Session] Token expired — logged out")
            } catch {
                AppLog.auth.warning(
                    "[Session] Revalidation failed (keeping cached session): \(error.localizedDescription)"
                )
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Cancel pending disconnect — user came back quickly
                backgroundDisconnectTask?.cancel()
                backgroundDisconnectTask = nil
                // Reconnect only when fully disconnected. If we're already in
                // .connecting, allow that in-flight attempt to finish.
                if auth.isAuthenticated, let token = auth.token, ws.isDisconnected {
                    AppLog.ws.info("[Scene] Returned to foreground — reconnecting WebSocket")
                    ws.reconnectFromForeground(token: token)
                }
            case .background:
                // 30s grace period — quick tab switches won't disconnect
                if ws.isConnected {
                    backgroundDisconnectTask = Task {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { return }
                        AppLog.ws.info("[Scene] Background timeout — closing WebSocket")
                        ws.backgroundDisconnect()
                    }
                }
            default:
                break
            }
        }
    }
}
