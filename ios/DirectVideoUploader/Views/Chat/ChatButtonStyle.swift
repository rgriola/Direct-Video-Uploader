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
                    .font(Theme.iconMediumFont)
                Text(label)
                    .font(Theme.captionBoldFont)
            }
            .padding(.horizontal, Theme.buttonPaddingH)
            .padding(.vertical, Theme.buttonPaddingV)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: Theme.buttonCornerRadius))
        }
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
                .font(Theme.badgeSymbolFont)
            Text(text)
                .font(Theme.badgeFont)
        }
        .padding(.horizontal, Theme.badgePaddingH)
        .padding(.vertical, Theme.badgePaddingV)
        .background(color)
        .foregroundStyle(Theme.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.badgeCornerRadius))
    }
}
