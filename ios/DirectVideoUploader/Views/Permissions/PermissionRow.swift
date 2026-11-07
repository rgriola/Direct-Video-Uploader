import SwiftUI

/// Visual state of a permission, independent of the framework's status type.
enum PermissionRowState {
    case granted
    case limited
    case blocked
    case undecided
}

/// One permission line: icon, title, explanation, optional badge and a status pill.
/// Shared by Profile and the onboarding Permissions screen.
struct PermissionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var badge: String? = nil
    let statusLabel: String
    let state: PermissionRowState
    /// When set, the row is a button (for example to request access or open Settings).
    var actionHint: String? = nil
    var action: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var iconSize: CGFloat = 32

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityHint(actionHint ?? "")
        } else {
            content
        }
    }

    private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }

    private var content: some View {
        HStack(spacing: Theme.space12) {
            Image(systemName: icon)
                .font(Theme.icon16)
                .foregroundStyle(iconColor)
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                let titleLayout = isLargeText
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(spacing: Theme.space8))
                titleLayout {
                    Text(title)
                        .font(Theme.font16Medium)
                        .foregroundStyle(Theme.primaryText)
                    if let badge {
                        Text(badge)
                            .font(Theme.font11Semibold)
                            .foregroundStyle(Theme.purpleText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.purple.opacity(0.15), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(Theme.font13Regular)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if isLargeText {
                    statusPill.padding(.top, Theme.space8)
                }
            }

            Spacer(minLength: Theme.space8)

            if !isLargeText {
                statusPill
            }

            if action != nil, state != .undecided {
                Image(systemName: "arrow.up.forward.app")
                    .font(Theme.icon13)
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.space16)
        .padding(.vertical, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, badge, subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(statusLabel)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(Theme.font13Medium)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.glassOverlay, in: Capsule())
    }

    private var iconColor: Color {
        switch state {
        case .granted, .limited: Theme.green
        case .blocked: Theme.red
        case .undecided: Theme.tertiaryText
        }
    }

    private var dotColor: Color {
        switch state {
        case .granted: Theme.green
        case .limited: Theme.amber
        case .blocked: Theme.red
        case .undecided: Theme.tertiaryText
        }
    }
}

extension PermissionManager {
    var photoLibraryRowState: PermissionRowState {
        switch photoLibraryStatus {
        case .authorized: .granted
        case .limited: .limited
        case .denied, .restricted: .blocked
        default: .undecided
        }
    }

    var speechRowState: PermissionRowState {
        switch speechStatus {
        case .authorized: .granted
        case .denied, .restricted: .blocked
        default: .undecided
        }
    }
}
