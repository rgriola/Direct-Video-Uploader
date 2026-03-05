import SwiftUI

/// Root view — shows Login or Chat/Archive tabs depending on auth state.
struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    
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
    }
}
