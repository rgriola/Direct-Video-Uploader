import SwiftUI

/// Profile screen — user info, permission toggles, app info, and logout.
struct ProfileView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    @Environment(PermissionManager.self) private var permissions
    @State private var showLogoutConfirm = false

    var body: some View {
        ZStack {
            Theme.screenGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                Text("Profile")
                    .font(Theme.headerNameFont)
                    .foregroundStyle(Theme.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.black.opacity(0.94))

                ScrollView {
                    VStack(spacing: 20) {
                        // User info card
                        userInfoSection

                        // Permissions
                        permissionsSection

                        // App info
                        appInfoSection

                        // Logout
                        logoutSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // User may have changed permissions in Settings.app
            permissions.refreshStatuses()
        }
    }

    // MARK: - User Info

    private var userInfoSection: some View {
        VStack(spacing: 12) {
            // Avatar circle with initial
            ZStack {
                Circle()
                    .fill(Theme.purple.opacity(0.3))
                    .frame(width: 72, height: 72)
                    .overlay(Circle().stroke(Theme.purple.opacity(0.6), lineWidth: 2))

                Text(userInitial)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.white)
            }

            // Name
            if let user = auth.currentUser {
                Text(user.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.white)

                Text(user.phoneNumber)
                    .font(Theme.monoSmallFont)
                    .foregroundStyle(Theme.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Theme.black, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Permissions")

            VStack(spacing: 0) {
                // Photo Library toggle
                permissionRow(
                    icon: "photo.on.rectangle.angled",
                    title: "Photo Library",
                    subtitle: "Access your video library",
                    statusLabel: permissions.photoLibraryLabel,
                    isGranted: permissions.isPhotoLibraryGranted,
                    isDenied: permissions.photoLibraryStatus == .denied,
                    isLimited: permissions.photoLibraryStatus == .limited
                ) {
                    Task { await permissions.requestPhotoLibrary() }
                }

                Divider()
                    .background(Theme.white.opacity(0.1))
                    .padding(.leading, 52)

                // Speech Recognition toggle
                permissionRow(
                    icon: "mic.fill",
                    title: "Speech Recognition",
                    subtitle: "Transcribe video audio",
                    statusLabel: permissions.speechLabel,
                    isGranted: permissions.isSpeechGranted,
                    isDenied: permissions.speechStatus == .denied,
                    isLimited: false
                ) {
                    Task { await permissions.requestSpeechRecognition() }
                }
            }
            .background(Theme.black, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - App Info

    private var appInfoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("App")

            VStack(spacing: 0) {
                infoRow(icon: "link", label: "Server", value: ServerConfig.currentURLString)

                Divider()
                    .background(Theme.white.opacity(0.1))
                    .padding(.leading, 52)

                infoRow(
                    icon: "info.circle",
                    label: "Version",
                    value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))"
                )
            }
            .background(Theme.black, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Logout

    private var logoutSection: some View {
        Button {
            showLogoutConfirm = true
        } label: {
            Text("Logout")
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.black, in: RoundedRectangle(cornerRadius: 12))
        }
        .confirmationDialog("Positive?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Logout", role: .destructive) {
                auth.logout()
                ws.disconnect()
            }
        }
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.white.opacity(0.5))
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
    }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        statusLabel: String,
        isGranted: Bool,
        isDenied: Bool,
        isLimited: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Icon
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(isGranted ? Theme.green : (isDenied ? Theme.red : Theme.white.opacity(0.5)))
                    .frame(width: 32, height: 32)

                // Labels
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.white)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.white.opacity(0.5))
                }

                Spacer()

                // Status pill
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusDotColor(isGranted: isGranted, isDenied: isDenied, isLimited: isLimited))
                        .frame(width: 8, height: 8)
                    Text(statusLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.white.opacity(0.08), in: Capsule())

                // Chevron — if denied, hint that it opens Settings
                if isDenied {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.white.opacity(0.5))
                .frame(width: 32, height: 32)

            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.white)

            Spacer()

            Text(value)
                .font(Theme.monoSmallFont)
                .foregroundStyle(Theme.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func statusDotColor(isGranted: Bool, isDenied: Bool, isLimited: Bool) -> Color {
        if isGranted && !isLimited { return Theme.green }
        if isLimited { return .orange }
        if isDenied { return Theme.red }
        return Theme.white.opacity(0.4)  // not determined
    }

    private var userInitial: String {
        guard let name = auth.currentUser?.name, let first = name.first else { return "?" }
        return String(first).uppercased()
    }
}
