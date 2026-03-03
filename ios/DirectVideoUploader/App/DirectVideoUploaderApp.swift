import SwiftUI

@main
struct DirectVideoUploaderApp: App {
    // MARK: - Services (app-level singletons)
    
    @State private var auth = AuthService()
    @State private var ws = WebSocketService()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(ws)
        }
    }
}
