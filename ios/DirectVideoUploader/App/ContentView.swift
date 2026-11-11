// May 10, 2026 - 3:07pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

/// Root view — shows Login or Chat/Archive tabs depending on auth state.
struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    @Environment(AppearanceService.self) private var appearance
    @Environment(PermissionManager.self) private var permissions
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundDisconnectTask: Task<Void, Never>?
    @State private var sessionCheckComplete = false
    @State private var formPresentation = FormPresentationState(isSceneActive: false)
    @State private var activeChatViewModel: ChatViewModel?
    @State private var archiveMediaTasks = ArchiveMediaTaskOwner()

    var body: some View {
        @Bindable var formPresentation = formPresentation
        Group {
            if !sessionCheckComplete {
                // Resolving stored token — show a neutral loading screen
                Theme.black.ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .tint(Theme.white.opacity(0.4))
                    }
            } else if auth.isAuthenticated && auth.currentUser != nil {
                TabView(selection: $formPresentation.selectedTab) {
                    ChatView(formPresentation: formPresentation) { viewModel in
                        activeChatViewModel = viewModel
                    }
                        .tabItem {
                            Image(systemName: "bubble.left.fill")
                            Text("Chat")
                        }
                        .tag(FormPresentationState.Tab.chat)

                    ArchiveListView(presentationState: formPresentation, mediaTasks: archiveMediaTasks)
                        .tabItem {
                            Image(systemName: "archivebox.fill")
                            Text("Archive")
                        }
                        .tag(FormPresentationState.Tab.archive)

                    PhotosView()
                        .tabItem {
                            Image(systemName: "photo.fill")
                            Text("Photos")
                        }
                        .tag(FormPresentationState.Tab.photos)

                    ProfileView()
                        .tabItem {
                            Image(systemName: "person.fill")
                            Text("Profile")
                        }
                        .tag(FormPresentationState.Tab.profile)
                }
                .tint(Theme.purple)
                .id(auth.sessionGeneration)
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(appearance.preferredColorScheme)
        .task {
            protectPendingFormFiles()
            await auth.restoreSavedSession()
            sessionCheckComplete = true
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            if newPhase != .active { formPresentation.isSceneActive = false }
            switch newPhase {
            case .active:
                protectPendingFormFiles()
                formPresentation.isSceneActive = true
                // Permissions may have changed in Settings or from a prompt elsewhere in the app.
                permissions.refreshStatuses()
                // Cancel pending disconnect — user came back quickly
                backgroundDisconnectTask?.cancel()
                backgroundDisconnectTask = nil
                // Reconnect only when fully disconnected. If we're already in
                // .connecting, allow that in-flight attempt to finish.
                if sessionCheckComplete, auth.currentUser != nil,
                   auth.isAuthenticated, ws.isDisconnected {
                    do {
                        let snapshot = try auth.authenticatedSnapshot()
                        let sessionAuth = auth
                        Log.debug("🔄 [Scene] Returned to foreground — reconnecting WebSocket", logger: Log.app)
                        ws.reconnectFromForeground(
                            token: snapshot.token, isCurrent: { sessionAuth.isCurrent(snapshot) })
                    } catch {
                        Log.error("Could not reconnect the current session: \(Log.describe(error))", logger: Log.auth)
                    }
                }
            case .background:
                // 30s grace period — quick tab switches won't disconnect
                if ws.isConnected {
                    backgroundDisconnectTask = Task {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { return }
                        Log.debug("💤 [Scene] Background timeout — closing WebSocket", logger: Log.app)
                        ws.backgroundDisconnect()
                    }
                }
            default:
                break
            }
        }
        .onChange(of: auth.isAuthenticated) { _, authenticated in
            if !authenticated {
                backgroundDisconnectTask?.cancel()
                backgroundDisconnectTask = nil
                ws.disconnect()
            }
        }
        .onChange(of: auth.sessionGeneration) { _, _ in
            archiveMediaTasks.cancelAll()
            if activeChatViewModel?.invalidateIfSessionChanged() == true {
                activeChatViewModel = nil
            }
            formPresentation.selectedTab = .chat
            formPresentation.archiveFormVisible = false
            formPresentation.completedDetailsAssetIDs.removeAll()
            formPresentation.clearUploadRecoveryState()
            formPresentation.photoAssociatedAssetIDs.removeAll()
            formPresentation.clearChatUploadFailures()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification)
        ) { _ in
            protectPendingFormFiles()
            if auth.signOutRequiresRetry {
                auth.logout()
            } else {
                Task { await auth.restoreSavedSession() }
            }
        }
        .alert(
            "Saved recovery information needs attention",
            isPresented: $formPresentation.pendingFormProtectionWarning
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Saved recovery information couldn't be protected or updated. Unlock this device and reopen the app to retry.")
        }
    }

    private func protectPendingFormFiles() {
        var protectionFailed = false
        do {
            try PendingFormStore.shared.prepareExistingFiles()
        } catch {
            Log.error("⚠️ [Form] Could not prepare saved recovery state: \(Log.describe(error))", logger: Log.upload)
            protectionFailed = true
        }
        do {
            try ScopedPHAssetIdentifierStore.shared.protectLegacyFile()
        } catch {
            Log.error("⚠️ [Archive] Could not protect legacy photo associations: \(Log.describe(error))", logger: Log.media)
            protectionFailed = true
        }
        formPresentation.pendingFormProtectionWarning = protectionFailed
    }
}
