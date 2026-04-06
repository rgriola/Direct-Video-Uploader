import SwiftUI

// MARK: - Color Theme

/// Centralized color palette. Use `Theme.blue` instead of `Color(hex: "007AFF")` everywhere.
enum Theme {
    // Primary actions
  
    static let black       = Color(hex: "111111")
    static let white       = Color(hex: "F5F5F5")
    static let purple      = Color(hex: "8576EE")

    static let blue        = Color(hex: "007AFF")
    static let green       = Color(hex: "30D158")
    static let red         = Color(hex: "FF453A")
    static let yellow      = Color(hex: "FFD60A")
    static let tint        = Color(hex: "0A84FF") // blue 
    static let viewGreen   = Color(hex: "34C759") 

    // Backgrounds
    static let darkBg      = Color(hex: "111111")
    static let cardBg      = Color(hex: "2C2C2E")
    static let deepBg      = Color(hex: "0A0E1A")
    static let formBg      = Color(hex: "1A2544")
    static let separator   = Color(hex: "38383A")
    static let chatScreen  = Color(hex: "F3F2F2")

    // Grays
    static let whiteBk      = Color(hex: "F5F5F5")
    static let lightGrayBk  = Color(hex: "ECECEC")
    static let darkGrayBk   = Color(hex: "CACACA")

    // Incoming bubble
    static let incomingBubble = Color(hex: "DBDBDB")
    static let incomingText   = Color(hex: "111111")

    // Outgoing bubble  
    static let outgoingBubble = Color(hex: "8576EE")
    static let outgoingText   = Color(hex: "F5F5F5")

    // Gradients
    static let bubbleBlueHi  = Color(hex: "007AFF")
    static let bubbleBlueLo  = Color(hex: "0063D1")
    static let videoBubbleHi = Color(hex: "1C3A5F")
    static let videoBubbleLo = Color(hex: "0A1E3D")

    // Text
    static let primaryText   = Color(hex: "F5F5F5")
    static let secondaryText = Color(hex: "98989D")
    static let tertiaryText  = Color(hex: "636366")
    static let lightText     = Color(hex: "E5E5EA")
    static let metaText      = Color(hex: "EBEBF5")

    // InputBar
    static let inputBarBg    = Color(hex: "ADADAD")
    static let inputFieldBg  = Color(hex: "CCCCCC")
    static let actionBlue    = Color(hex: "8576EE")

    // MARK: - Typography

    // Body
    static let bodyFont          = Font.system(size: 18)
    static let bodyMediumFont    = Font.system(size: 18, weight: .medium)
    static let bodySmallFont     = Font.system(size: 18)

    // Captions
    static let captionFont       = Font.system(size: 13)
    static let captionBoldFont   = Font.system(size: 13, weight: .semibold)

    // Timestamps
    static let timestampFont     = Font.system(size: 11)

    // Badges
    static let badgeFont         = Font.system(size: 16, weight: .medium)
    static let badgeSymbolFont   = Font.system(size: 16, weight: .bold, design: .monospaced)

    // Monospaced
    static let monoSmallFont     = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let monoIdFont        = Font.system(size: 14, weight: .bold, design: .monospaced)
    static let monoValueFont     = Font.system(size: 12, design: .monospaced)
    static let monoLargeFont     = Font.system(size: 14, weight: .medium, design: .monospaced)
    static let monoURLFont       = Font.system(size: 12, weight: .medium, design: .monospaced)

    // URLs
    static let urlFont           = Font.system(size: 11)

    // Labels
    static let labelFont         = Font.system(size: 11, weight: .semibold)

    // Icons
    static let iconTinyFont      = Font.system(size: 10)
    static let iconSmallFont     = Font.system(size: 12)
    static let iconMediumFont    = Font.system(size: 13)
    static let iconFont          = Font.system(size: 14)
    static let iconHeaderFont    = Font.system(size: 16)
    static let iconXLFont        = Font.system(size: 24)
    static let iconLargeFont     = Font.system(size: 34)

    // Titles
    static let titleFont         = Font.system(size: 20, weight: .bold)
    static let subtitleFont      = Font.system(size: 18, weight: .semibold)

    // Chat Header
    static let headerNameFont    = Font.system(size: 16, weight: .semibold)
    static let headerAvatarFont  = Font.system(size: 14, weight: .bold)
    static let headerStatusFont  = Font.system(size: 12)
    static let headerChevronFont = Font.system(size: 11, weight: .semibold)

    // Login
    static let loginTitleFont    = Font.system(size: 28, weight: .bold)
    static let loginSubtitleFont = Font.system(size: 28, weight: .light)
    static let loginTaglineFont  = Font.system(size: 14, weight: .medium)
    static let loginFieldFont    = Font.system(size: 16, weight: .medium)
    static let loginButtonFont   = Font.system(size: 16, weight: .semibold)
    static let loginHintFont     = Font.system(size: 12, weight: .semibold)
    static let loginHintMonoFont = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let loginEmojiFont    = Font.system(size: 64)
    static let loginServerFont   = Font.system(size: 11, weight: .medium, design: .monospaced)

    // Form
    static let formFieldFont     = Font.system(size: 15)
    static let formPriorityFont  = Font.system(size: 13)
    static let formClipFont      = Font.system(size: 15, weight: .semibold)
    static let formErrorFont     = Font.system(size: 14)

    // Archive
    static let archiveTitleFont   = Font.system(size: 15, weight: .medium)
    static let archiveMetaLabelFont = Font.system(size: 12, weight: .medium)
    static let archiveMetaValueFont = Font.system(size: 12)
    static let archiveStatusFont    = Font.system(size: 12, weight: .medium)
    static let archiveEmojiFont     = Font.system(size: 22)

    // Metadata
    static let metaIconFont      = Font.system(size: 16)
    static let metaLabelFont     = Font.system(size: 14)
    static let metaValueFont     = Font.system(size: 14, weight: .medium)
    static let metaIdFont        = Font.system(size: 15, weight: .bold, design: .monospaced)
    static let metaFileFont         = Font.system(size: 14, weight: .medium, design: .monospaced)
    static let metaEmptyEmojiFont   = Font.system(size: 44)
    static let metaEmptyTitleFont   = Font.system(size: 18, weight: .semibold)
    static let metaLinkFont         = Font.system(size: 15, weight: .medium)

    // Misc
    static let statusDotSize: CGFloat   = 7
    static let locationFont      = Font.system(size: 11)
    static let locationIconFont  = Font.system(size: 10)
    static let progressFont      = Font.caption.monospacedDigit()
    static let emojiLargeFont    = Font.system(size: 32)
    static let emptyStateFont    = Font.system(size: 16, weight: .medium)
    static let emptyEmojiFont    = Font.system(size: 40)

    // Attachment buttons
    static let attachButtonFont  = Font.system(size: 32)
    static let sendButtonFont    = Font.system(size: 32)

    // MARK: - Button Layout

    static let buttonPaddingH: CGFloat    = 14
    static let buttonPaddingV: CGFloat    = 8
    static let buttonCornerRadius: CGFloat = 8
    static let badgePaddingH: CGFloat     = 12
    static let badgePaddingV: CGFloat     = 6
    static let badgeCornerRadius: CGFloat = 6

    // Screen gradients
    static let screenGradient = LinearGradient(
            colors: [Theme.black, Theme.purple],
            startPoint: .top,
            endPoint: .bottom
            )

    static let videoBubbleGradient = LinearGradient(
                        colors: [Theme.purple, Theme.black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
