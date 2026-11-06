// May 10, 2026 - 3:34pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

/// Profile screen — user info, permission toggles, app info, and logout.
struct ProfileView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    @Environment(PermissionManager.self) private var permissions
    @Environment(AppearanceService.self) private var appearance
    @State private var showLogoutConfirm = false
    @State private var showOnboardingResetConfirm = false

    var body: some View {
        ZStack {
            Theme.screenGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                Text("Profile")
                    .font(Theme.font16Semibold)
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.space16)
                    .background(Theme.cardBg)

                ScrollView {
                    VStack(spacing: Theme.space20) {
                        // User info card
                        userInfoSection

                        // Permissions
                        permissionsSection

                        // Appearance
                        appearanceSection

                        // App info
                        appInfoSection

                        // Logout
                        logoutSection
                    }
                    .padding(.horizontal, Theme.space20)
                    .padding(.top, Theme.space16)
                    .padding(.bottom, 40)
                }
            }
        }
        .confirmationDialog(
            "Reset onboarding?",
            isPresented: $showOnboardingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Onboarding", role: .destructive) {
                OnboardingCatalog.resetForQA()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The onboarding walkthrough will show again on next app launch.")
        }
    }

    // MARK: - User Info

    private var userInfoSection: some View {
        VStack(spacing: Theme.space12) {
            // Avatar circle with initial
            ZStack {
                Circle()
                    .fill(Theme.purple.opacity(0.3))
                    .frame(width: 72, height: 72)
                    .overlay(Circle().stroke(Theme.purple.opacity(0.6), lineWidth: 2))

                Text(userInitial)
                    .font(Theme.font28Bold)
                    .foregroundStyle(Theme.white)
            }

            // Name
            if let user = auth.currentUser {
                Text(user.name)
                    .font(Theme.font20Semibold)
                    .foregroundStyle(Theme.primaryText)

                Text(user.phoneNumber)
                    .font(Theme.mono13Medium)
                    .foregroundStyle(Theme.secondaryText)

                if let companyName = user.companyName {
                    Text(companyName)
                        .font(Theme.font13Medium)
                        .foregroundStyle(Theme.purple.opacity(0.8))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.space20)
        .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: Theme.radiusLg))
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Permissions")

            VStack(spacing: 0) {
                PermissionRow(
                    icon: "photo.on.rectangle.angled",
                    title: "Photo Library",
                    subtitle: "Upload originals and re-upload from Archive",
                    statusLabel: permissions.photoLibraryLabel,
                    state: permissions.photoLibraryRowState,
                    actionHint: permissions.photoLibraryStatus == .notDetermined
                        ? "Asks for access" : "Opens Settings"
                ) {
                    Task { await permissions.requestPhotoLibrary() }
                }

                Divider()
                    .background(Theme.glassBorder)
                    .padding(.leading, 52)

                PermissionRow(
                    icon: "mic.fill",
                    title: "Speech Recognition",
                    subtitle: "Transcribe video audio",
                    statusLabel: permissions.speechLabel,
                    state: permissions.speechRowState,
                    actionHint: permissions.speechStatus == .notDetermined
                        ? "Asks for access" : "Opens Settings"
                ) {
                    Task { await permissions.requestSpeechRecognition() }
                }
            }
            .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        }
    }

    // MARK: - App Info

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Appearance")

            VStack(alignment: .leading, spacing: Theme.space12) {
                Picker("Appearance", selection: appearanceModeBinding) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("Choose System, Light, or Dark for Fixer.")
                    .font(Theme.font13Regular)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(Theme.space16)
            .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        }
    }

    private var appInfoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("App")

            VStack(spacing: 0) {
                infoRow(icon: "link", label: "Server", value: ServerConfig.currentURLString)

                Divider()
                    .background(Theme.glassBorder)
                    .padding(.leading, 52)

                infoRow(
                    icon: "info.circle",
                    label: "Version",
                    value:
                        "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))"
                )

                Divider()
                    .background(Theme.glassBorder)
                    .padding(.leading, 52)

                Button {
                    showOnboardingResetConfirm = true
                } label: {
                    HStack(spacing: Theme.space12) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(Theme.icon16)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset Onboarding")
                                .font(Theme.font16Medium)
                                .foregroundStyle(Theme.primaryText)

                            Text("QA tool: show first-run walkthrough again")
                                .font(Theme.font13Regular)
                                .foregroundStyle(Theme.secondaryText)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, Theme.space16)
                    .padding(.vertical, Theme.space12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        }
    }

    // MARK: - Logout

    private var logoutSection: some View {
        Button {
            showLogoutConfirm = true
        } label: {
            Text("Logout")
                .font(Theme.font16Semibold)
                .foregroundStyle(Theme.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        }
        .confirmationDialog("Positive?", isPresented: $showLogoutConfirm, titleVisibility: .visible)
        {
            Button("Logout", role: .destructive) {
                auth.logout()
                ws.disconnect()
            }
        }
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.font13Semibold)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, Theme.space4)
            .padding(.bottom, Theme.space8)
            .accessibilityAddTraits(.isHeader)
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: Theme.space12) {
            Image(systemName: icon)
                .font(Theme.icon16)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 32, height: 32)

            Text(label)
                .font(Theme.font16Medium)
                .foregroundStyle(Theme.primaryText)

            Spacer()

            Text(value)
                .font(Theme.mono13Medium)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Theme.space16)
        .padding(.vertical, Theme.space12)
    }

    private var userInitial: String {
        guard let name = auth.currentUser?.name, let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    private var appearanceModeBinding: Binding<AppearanceMode> {
        Binding(
            get: { appearance.mode },
            set: { appearance.mode = $0 }
        )
    }
}
