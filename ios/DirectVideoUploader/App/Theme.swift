import SwiftUI

// MARK: - Font Family

/// Single lever to swap the entire app's typeface.
/// Change `Theme.fontFamily` to `.custom("Inter")` etc. once font files are bundled.
enum FontFamily {
    case system
    case custom(String)

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .system:
            return .system(size: size, weight: weight)
        case .custom(let name):
            return .custom(name, size: size)
        }
    }

    func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Mono always uses system monospaced regardless of family
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Design System

/// Centralized design system. Every color, font, radius, and layout token lives here.
enum Theme {

    /// Change this one line to restyle every font in the app.
    static let fontFamily: FontFamily = .system

    // ──────────────────────────────────────────────
    // MARK: – Colors
    // ──────────────────────────────────────────────

    // Core palette
    static let black       = Color(hex: "#111111")
    static let white       = Color(hex: "#F5F5F5")
    static let purple      = Color(hex: "#8576EE")
    static let blue        = Color(hex: "#007AFF")
    static let green       = Color(hex: "#30D158")
    static let red         = Color(hex: "#FF453A")
    static let yellow      = Color(hex: "#FFD60A")
    static let amber       = Color(hex: "#FF9F0A")

    // Semantic greens (view indicator vs. success)
    static let viewGreen   = Color(hex: "#34C759")

    // Backgrounds
    static let cardBg      = Color(hex: "#2C2C2E")
    static let deepBg      = Color(hex: "#0A0E1A")
    static let formBg      = Color(hex: "#1A2544")
    static let separator   = Color(hex: "#38383A")
    static let chatScreen  = Color(hex: "#F3F2F2")

    // Grays
    static let lightGray   = Color(hex: "#ECECEC")
    static let darkGray    = Color(hex: "#CACACA")

    // Chat bubbles
    static let incomingBubble = Color(hex: "#DBDBDB")

    // Gradient endpoints
    static let bubbleBlueHi  = Color(hex: "#007AFF")
    static let bubbleBlueLo  = Color(hex: "#0063D1")
    static let videoBubbleHi = Color(hex: "#1C3A5F")
    static let videoBubbleLo = Color(hex: "#0A1E3D")

    // Text hierarchy
    static let primaryText   = Color(hex: "#F5F5F5")
    static let secondaryText = Color(hex: "#98989D")
    static let tertiaryText  = Color(hex: "#636366")
    static let lightText     = Color(hex: "#E5E5EA")
    static let metaText      = Color(hex: "#EBEBF5")

    // Input bar
    static let inputBarBg    = Color(hex: "#ADADAD")
    static let inputFieldBg  = Color(hex: "#CCCCCC")

    // Glass / overlays
    static let glassOverlay  = Color.white.opacity(0.05)
    static let glassBorder   = Color.white.opacity(0.1)

    // ──────────────────────────────────────────────
    // MARK: – Typography (5 sizes × weights)
    // ──────────────────────────────────────────────

    // xs — 11pt: timestamps, URL hints, status text, location
    static let font11Regular   = fontFamily.font(size: 11)
    static let font11Medium    = fontFamily.font(size: 11, weight: .medium)
    static let font11Semibold  = fontFamily.font(size: 11, weight: .semibold)

    // sm — 13pt: captions, badges, metadata labels, archive status
    static let font13Regular   = fontFamily.font(size: 13)
    static let font13Medium    = fontFamily.font(size: 13, weight: .medium)
    static let font13Semibold  = fontFamily.font(size: 13, weight: .semibold)

    // md — 16pt: body, chat bubbles, buttons, nav, input fields, forms
    static let font16Regular   = fontFamily.font(size: 16)
    static let font16Medium    = fontFamily.font(size: 16, weight: .medium)
    static let font16Semibold  = fontFamily.font(size: 16, weight: .semibold)
    static let font16Bold      = fontFamily.font(size: 16, weight: .bold)

    // lg — 20pt: titles, section headers, profile name
    static let font20Semibold  = fontFamily.font(size: 20, weight: .semibold)
    static let font20Bold      = fontFamily.font(size: 20, weight: .bold)

    // xl — 28pt: login hero, profile avatar initial
    static let font28Light     = fontFamily.font(size: 28, weight: .light)
    static let font28Bold      = fontFamily.font(size: 28, weight: .bold)

    // ──────────────────────────────────────────────
    // MARK: – Monospaced
    // ──────────────────────────────────────────────

    static let mono11Medium    = fontFamily.mono(size: 11, weight: .medium)
    static let mono13Medium    = fontFamily.mono(size: 13, weight: .medium)
    static let mono16Medium    = fontFamily.mono(size: 16, weight: .medium)
    static let mono16Bold      = fontFamily.mono(size: 16, weight: .bold)

    // Progress counter (caption-size, monospaced digits)
    static let progressFont    = Font.caption.monospacedDigit()

    // ──────────────────────────────────────────────
    // MARK: – Icons (match text scale)
    // ──────────────────────────────────────────────

    static let icon11          = fontFamily.font(size: 11)
    static let icon13          = fontFamily.font(size: 13)
    static let icon16          = fontFamily.font(size: 16)
    static let icon20          = fontFamily.font(size: 20)

    // ──────────────────────────────────────────────
    // MARK: – Display (emoji, hero — outside type scale)
    // ──────────────────────────────────────────────

    static let display24       = fontFamily.font(size: 24)
    static let display32       = fontFamily.font(size: 32)
    static let display44       = fontFamily.font(size: 44, weight: .bold)
    static let display64       = fontFamily.font(size: 64)

    // ──────────────────────────────────────────────
    // MARK: – Corner Radii
    // ──────────────────────────────────────────────

    static let radiusSm: CGFloat  = 6
    static let radiusMd: CGFloat  = 12
    static let radiusLg: CGFloat  = 16
    static let radiusXl: CGFloat  = 18

    // ──────────────────────────────────────────────
    // MARK: – Spacing
    // ──────────────────────────────────────────────

    static let space4:  CGFloat = 4
    static let space8:  CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32

    // ──────────────────────────────────────────────
    // MARK: – Layout Constants
    // ──────────────────────────────────────────────

    static let statusDotSize: CGFloat = 7

    // Button layout
    static let buttonPaddingH:    CGFloat = 14
    static let buttonPaddingV:    CGFloat = 8
    static let buttonCornerRadius: CGFloat = radiusMd
    static let badgePaddingH:     CGFloat = 12
    static let badgePaddingV:     CGFloat = 6
    static let badgeCornerRadius: CGFloat = radiusSm

    // ──────────────────────────────────────────────
    // MARK: – Gradients
    // ──────────────────────────────────────────────

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

    static let loginGradient = LinearGradient(
        colors: [Theme.purple, Theme.black],
        startPoint: .top,
        endPoint: .bottom
    )

    static let buttonGradient = LinearGradient(
        colors: [Theme.bubbleBlueHi, Theme.bubbleBlueLo],
        startPoint: .top,
        endPoint: .bottom
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
