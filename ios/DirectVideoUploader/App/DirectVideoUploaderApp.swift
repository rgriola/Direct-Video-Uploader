// May 11, 2026 - 4:47pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI
import UIKit

final class BackgroundUploadAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundUploadSessionCoordinator.shared.handleBackgroundEvents(
            for: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct DirectVideoUploaderApp: App {
    // MARK: - Services (app-level singletons)

    @UIApplicationDelegateAdaptor(BackgroundUploadAppDelegate.self) private var appDelegate

    @State private var auth = AuthService()
    @State private var ws = WebSocketService()
    @State private var permissions = PermissionManager()
    @State private var appearance = AppearanceService()

    init() {
        // Ensure stale running tasks are reconciled on app launch.
        BackgroundUploadSessionCoordinator.shared.reconcileOutstandingTasks()
    }

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
