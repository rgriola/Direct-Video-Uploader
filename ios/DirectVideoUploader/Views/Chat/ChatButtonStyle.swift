import SwiftUI

/// Reusable action button — used for "Metadata", "View", etc. across chat bubbles and archive rows.
struct ChatActionButton: View {
    let icon: String
    let label: String
    let color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(Theme.icon13)
                Text(label)
                    .font(Theme.font13Semibold)
            }
            .padding(.horizontal, Theme.buttonPaddingH)
            .padding(.vertical, Theme.buttonPaddingV)
            .background(color)
            .foregroundStyle(Theme.white)
            .clipShape(RoundedRectangle(cornerRadius: Theme.buttonCornerRadius))
            .tapTarget()
        }
    }
}

/// Expands the hit area to Apple's 44 pt minimum (scaled with Dynamic Type)
/// without changing the visible size. Apply after visual styling, inside a Button label.
struct MinimumTapTarget: ViewModifier {
    var alignment: Alignment = .center
    @ScaledMetric(relativeTo: .body) private var minSize: CGFloat = 44

    func body(content: Content) -> some View {
        content
            .frame(minWidth: minSize, minHeight: minSize, alignment: alignment)
            .contentShape(Rectangle())
    }
}

extension View {
    func tapTarget(alignment: Alignment = .center) -> some View {
        modifier(MinimumTapTarget(alignment: alignment))
    }
}

/// Reusable badge — used for Slack #channel and @mention tags.
struct ChatBadge: View {
    let symbol: String   // "#" or "@"
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Text(symbol)
                .font(Theme.font16Bold)
            Text(text)
                .font(Theme.font16Medium)
        }
        .padding(.horizontal, Theme.badgePaddingH)
        .padding(.vertical, Theme.badgePaddingV)
        .background(color)
        .foregroundStyle(Theme.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.badgeCornerRadius))
    }
}
