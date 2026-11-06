// May 10, 2026 - 2:15pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI
import UIKit

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

    private static func resolvedInterfaceStyle(from traits: UITraitCollection)
        -> UIUserInterfaceStyle
    {
        switch traits.userInterfaceStyle {
        case .dark, .light:
            return traits.userInterfaceStyle
        case .unspecified:
            let current = UITraitCollection.current.userInterfaceStyle
            if current == .dark || current == .light {
                return current
            }

            let screen = UIScreen.main.traitCollection.userInterfaceStyle
            if screen == .dark || screen == .light {
                return screen
            }

            return .light
        @unknown default:
            return .light
        }
    }

    private static func adaptive(_ lightHex: String, _ darkHex: String) -> Color {
        Color(
            uiColor: UIColor { traits in
                let style = resolvedInterfaceStyle(from: traits)
                let hex = style == .dark ? darkHex : lightHex
                return UIColor(hex: hex)
            })
    }

    // ──────────────────────────────────────────────
    // MARK: – Colors
    // ──────────────────────────────────────────────

    // Core palette
    static let black = Color(hex: "#111111")
    static let white = Color(hex: "#F5F5F5")
    static let purple = Color(hex: "#8576EE")
    /// Purple for text on light/dark backgrounds (≥ 4.5:1 contrast).
    static let purpleText = adaptive("#5B4BD1", "#A99FF5")
    /// Purple fill behind white text (≥ 4.5:1 contrast).
    static let purpleFill = Color(hex: "#5B4BD1")
    static let blue = Color(hex: "#007AFF")
    static let green = Color(hex: "#30D158")
    static let red = Color(hex: "#FF453A")
    static let yellow = Color(hex: "#FFD60A")
    static let amber = Color(hex: "#FF9F0A")

    // Semantic greens (view indicator vs. success)
    static let viewGreen = Color(hex: "#34C759")

    // Backgrounds
    static let cardBg = adaptive("#F7F7FA", "#2C2C2E")
    static let deepBg = adaptive("#EEF2F8", "#0A0E1A")
    static let formBg = adaptive("#ECEFF7", "#1A2544")
    static let separator = adaptive("#D9D9DE", "#38383A")
    static let chatScreen = adaptive("#F3F2F2", "#111217")

    // Grays
    static let lightGray = Color(hex: "#ECECEC")
    static let darkGray = Color(hex: "#CACACA")

    // Chat bubbles
    static let incomingBubble = adaptive("#DBDBDB", "#2B2E35")

    // Gradient endpoints
    static let bubbleBlueHi = Color(hex: "#007AFF")
    static let bubbleBlueLo = Color(hex: "#0063D1")
    static let videoBubbleHi = Color(hex: "#1C3A5F")
    static let videoBubbleLo = Color(hex: "#0A1E3D")

    // Text hierarchy
    static let primaryText = adaptive("#111111", "#F5F5F5")
    static let secondaryText = adaptive("#616167", "#98989D")
    /// Warning text that keeps 4.5:1 contrast on light and dark card backgrounds.
    static let warningText = adaptive("#8A6D00", "#FFD60A")
    static let tertiaryText = adaptive("#8A8A90", "#636366")
    static let lightText = adaptive("#2A2A2E", "#E5E5EA")
    static let metaText = adaptive("#4A4A4F", "#EBEBF5")

    // Input bar
    static let inputBarBg = Color(hex: "#ADADAD")
    static let inputFieldBg = Color(hex: "#CCCCCC")

    // Glass / overlays
    static let glassOverlay = adaptive("#000000", "#FFFFFF").opacity(0.06)
    static let glassBorder = adaptive("#000000", "#FFFFFF").opacity(0.12)

    // ──────────────────────────────────────────────
    // MARK: – Typography (5 sizes × weights)
    // ──────────────────────────────────────────────

    // xs — 11pt: timestamps, URL hints, status text, location
    static let font11Regular = fontFamily.font(size: 11)
    static let font11Medium = fontFamily.font(size: 11, weight: .medium)
    static let font11Semibold = fontFamily.font(size: 11, weight: .semibold)

    // sm — 13pt: captions, badges, metadata labels, archive status
    static let font13Regular = fontFamily.font(size: 13)
    static let font13Medium = fontFamily.font(size: 13, weight: .medium)
    static let font13Semibold = fontFamily.font(size: 13, weight: .semibold)

    // md — 16pt: body, chat bubbles, buttons, nav, input fields, forms
    static let font16Regular = fontFamily.font(size: 16)
    static let font16Medium = fontFamily.font(size: 16, weight: .medium)
    static let font16Semibold = fontFamily.font(size: 16, weight: .semibold)
    static let font16Bold = fontFamily.font(size: 16, weight: .bold)

    // lg — 20pt: titles, section headers, profile name
    static let font20Semibold = fontFamily.font(size: 20, weight: .semibold)
    static let font20Bold = fontFamily.font(size: 20, weight: .bold)

    // xl — 28pt: login hero, profile avatar initial
    static let font28Light = fontFamily.font(size: 28, weight: .light)
    static let font28Bold = fontFamily.font(size: 28, weight: .bold)

    // ──────────────────────────────────────────────
    // MARK: – Monospaced
    // ──────────────────────────────────────────────

    static let mono11Medium = fontFamily.mono(size: 11, weight: .medium)
    static let mono13Medium = fontFamily.mono(size: 13, weight: .medium)
    static let mono16Medium = fontFamily.mono(size: 16, weight: .medium)
    static let mono16Bold = fontFamily.mono(size: 16, weight: .bold)

    // Progress counter (caption-size, monospaced digits)
    static let progressFont = Font.caption.monospacedDigit()

    // ──────────────────────────────────────────────
    // MARK: – Icons (match text scale)
    // ──────────────────────────────────────────────

    static let icon11 = fontFamily.font(size: 11)
    static let icon13 = fontFamily.font(size: 13)
    static let icon16 = fontFamily.font(size: 16)
    static let icon20 = fontFamily.font(size: 20)

    // ──────────────────────────────────────────────
    // MARK: – Display (emoji, hero — outside type scale)
    // ──────────────────────────────────────────────

    static let display24 = fontFamily.font(size: 24)
    static let display32 = fontFamily.font(size: 32)
    static let display44 = fontFamily.font(size: 44, weight: .bold)
    static let display64 = fontFamily.font(size: 64)

    // ──────────────────────────────────────────────
    // MARK: – Corner Radii
    // ──────────────────────────────────────────────

    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 12
    static let radiusLg: CGFloat = 16
    static let radiusXl: CGFloat = 18

    // ──────────────────────────────────────────────
    // MARK: – Spacing
    // ──────────────────────────────────────────────

    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
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
    static let buttonPaddingH: CGFloat = 14
    static let buttonPaddingV: CGFloat = 8
    static let buttonCornerRadius: CGFloat = radiusMd
    static let badgePaddingH: CGFloat = 12
    static let badgePaddingV: CGFloat = 6
    static let badgeCornerRadius: CGFloat = radiusSm

    // ──────────────────────────────────────────────
    // MARK: – Gradients
    // ──────────────────────────────────────────────

    static let screenGradient = LinearGradient(
        colors: [adaptive("#F6F7FB", "#111111"), adaptive("#C9C2FF", "#8576EE")],
        startPoint: .top,
        endPoint: .bottom
    )

    static let videoBubbleGradient = LinearGradient(
        colors: [Theme.purple, Theme.black],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let loginGradient = LinearGradient(
        colors: [adaptive("#D1C9FF", "#8576EE"), adaptive("#F5F6FA", "#111111")],
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
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
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

extension UIColor {
    fileprivate convenience init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64

        switch sanitized.count {
        case 6:
            a = 255
            r = value >> 16
            g = (value >> 8) & 0xFF
            b = value & 0xFF
        case 8:
            a = value >> 24
            r = (value >> 16) & 0xFF
            g = (value >> 8) & 0xFF
            b = value & 0xFF
        default:
            a = 255
            r = 0
            g = 0
            b = 0
        }

        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}
