import SwiftUI

/// One-time onboarding screen explaining Photo Library (recommended) and Speech Recognition
/// (optional). Continue shows the system prompt for each undecided permission; people can
/// decline there, and both remain available in Profile.
struct PermissionsView: View {
    @Environment(PermissionManager.self) private var permissions
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PermissionsPrompt.seenKey) private var hasSeenPermissions = false
    @State private var isRequesting = false

    var body: some View {
        ZStack {
            Theme.deepBg.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.space20) {
                        VStack(alignment: .leading, spacing: Theme.space8) {
                            Text("Before You Upload")
                                .font(Theme.font20Bold)
                                .foregroundStyle(Theme.primaryText)
                                .accessibilityAddTraits(.isHeader)
                            Text("Fixer works best with these. You can change them anytime in Profile.")
                                .font(Theme.font13Regular)
                                .foregroundStyle(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(spacing: 0) {
                            PermissionRow(
                                icon: "photo.on.rectangle.angled",
                                title: "Photo Library",
                                subtitle: "Used to upload videos from the photo library.",
                                badge: "Recommended",
                                statusLabel: permissions.photoLibraryLabel,
                                state: permissions.photoLibraryRowState,
                                actionHint: settingsHint(blocked: permissions.isPhotoLibraryBlocked),
                                action: settingsAction(blocked: permissions.isPhotoLibraryBlocked)
                            )

                            Divider()
                                .background(Theme.glassBorder)
                                .padding(.leading, 52)

                            PermissionRow(
                                icon: "mic.fill",
                                title: "Speech Recognition",
                                subtitle: "Fixer can transcribe video audio.",
                                badge: "Optional",
                                statusLabel: permissions.speechLabel,
                                state: permissions.speechRowState,
                                actionHint: settingsHint(blocked: permissions.isSpeechBlocked),
                                action: settingsAction(blocked: permissions.isSpeechBlocked)
                            )
                        }
                        .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: Theme.radiusMd))

                        if let note = photoLibraryNote {
                            VStack(alignment: .leading, spacing: Theme.space8) {
                                Label(note, systemImage: "info.circle.fill")
                                    .font(Theme.font13Regular)
                                    .foregroundStyle(Theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button {
                                    permissions.openAppSettings()
                                } label: {
                                    Text("Open Settings")
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .font(Theme.font13Semibold)
                                .foregroundStyle(Theme.purpleText)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.space20)
                    .padding(.top, Theme.space24)
                }

                Button(action: handleContinue) {
                    Group {
                        if isRequesting {
                            ProgressView().tint(Theme.white)
                        } else {
                            Text("Continue")
                        }
                    }
                    .font(Theme.font16Semibold)
                    .foregroundStyle(Theme.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.space16)
                    .background(Theme.purpleFill)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                }
                .disabled(isRequesting)
                .accessibilityLabel("Continue")
                .padding(.horizontal, Theme.space24)
                .padding(.top, Theme.space8)
                .padding(.bottom, Theme.space24)
            }
        }
        .interactiveDismissDisabled()
    }

    private var photoLibraryNote: String? {
        switch permissions.photoLibraryStatus {
        case .limited:
            "With limited access, originals and Archive re-upload work only for videos you've shared with Fixer. Other videos upload as their current version, which may include Photos edits."
        case .denied:
            "Without access, videos upload as their current version, which may include Photos edits, and Archive re-upload asks you to pick the video."
        default:
            nil
        }
    }

    private func settingsAction(blocked: Bool) -> (() -> Void)? {
        blocked ? { permissions.openAppSettings() } : nil
    }

    private func settingsHint(blocked: Bool) -> String? {
        blocked ? "Opens Settings" : nil
    }

    private func handleContinue() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            await permissions.requestUndecidedPermissions()
            hasSeenPermissions = true
            dismiss()
        }
    }
}
