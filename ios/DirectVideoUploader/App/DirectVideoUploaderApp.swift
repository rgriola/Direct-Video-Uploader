// May 14, 2026 - 2:50pm - GitHub Copilot (Claude Opus 4.7)
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

    // App init intentionally does no service work — get the user to the
    // login screen as fast as possible. Background-upload reconciliation runs
    // post-login (see ChatView.task) and on system relaunch via
    // BackgroundUploadAppDelegate.application(_:handleEventsForBackgroundURLSession:).

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
