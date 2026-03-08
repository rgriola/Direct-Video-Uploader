import SwiftUI

// MARK: - Color Theme

/// Centralized color palette. Use `Theme.blue` instead of `Color(hex: "007AFF")` everywhere.
enum Theme {
    // Primary actions
    static let black       = Color(hex: "000000")
    static let white       = Color(hex: "FFFFFF")
    static let blue        = Color(hex: "007AFF")
    static let green       = Color(hex: "30D158")
    static let red         = Color(hex: "FF453A")
    static let yellow      = Color(hex: "FFD60A")
    static let purple      = Color(hex: "5856D6")
    static let tint        = Color(hex: "0A84FF")
    static let viewGreen   = Color(hex: "34C759")

    // Backgrounds
    static let darkBg      = Color(hex: "1C1C1E")
    static let cardBg      = Color(hex: "2C2C2E")
    static let deepBg      = Color(hex: "0A0E1A")
    static let formBg      = Color(hex: "1A2544")
    static let separator   = Color(hex: "38383A")
    static let chatScreen  = Color(hex: "F3F2F2")

    // Incoming bubble
    static let incomingBubble = Color(hex: "DBDBDB")
    static let incomingText   = Color(hex: "2F2D2D")

    static let outgoingBubble = Color(hex: "1C3A5F")
    static let outgoingText   = Color.white
    // Gradients
    static let bubbleBlueHi  = Color(hex: "007AFF")
    static let bubbleBlueLo  = Color(hex: "0063D1")
    static let videoBubbleHi = Color(hex: "1C3A5F")
    static let videoBubbleLo = Color(hex: "0A1E3D")

    // Text
    static let primaryText   = Color.white
    static let secondaryText = Color(hex: "98989D")
    static let tertiaryText  = Color(hex: "636366")
    static let lightText     = Color(hex: "E5E5EA")
    static let metaText      = Color(hex: "EBEBF5")
    static let typingDot     = Color(hex: "A0A0A0")
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
