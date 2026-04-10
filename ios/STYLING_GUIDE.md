# iOS Design System — Styling Guide

> Drop this file into any new iOS project to enforce consistent, centralized styling.
> All agents and contributors should follow these rules when writing SwiftUI views.

---

## 1. Architecture: `Theme.swift`

All styling lives in a single file: **`App/Theme.swift`** — an `enum Theme` with no cases (namespace only). No styling should be defined inline in views.

### Rules

| ✅ Do | ❌ Don't |
|---|---|
| `.font(Theme.font16Medium)` | `.font(.system(size: 16, weight: .medium))` |
| `.foregroundStyle(Theme.white)` | `.foregroundStyle(.white)` |
| `.clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))` | `.clipShape(RoundedRectangle(cornerRadius: 12))` |
| `.padding(.horizontal, Theme.space16)` | `.padding(.horizontal, 16)` |
| `.background(Theme.glassOverlay)` | `.background(Color.white.opacity(0.05))` |

---

## 2. FontFamily Lever

A single line controls the entire app's typeface:

```swift
enum FontFamily {
    case system                // SF Pro (default)
    case custom(String)        // e.g. "Inter", "Outfit"

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .system:       return .system(size: size, weight: weight)
        case .custom(let n): return .custom(n, size: size)
        }
    }

    func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

enum Theme {
    static let fontFamily: FontFamily = .system   // ← change here to restyle everything
}
```

To swap to a custom font, bundle the font files, register in `Info.plist`, then change:
```swift
static let fontFamily: FontFamily = .custom("Inter")
```

---

## 3. Typography — 5-Size Scale

Every text element maps to one of **5 point sizes**. No exceptions.

| Tier | Size | Use Cases |
|------|------|-----------|
| **xs** | 11pt | Timestamps, URL hints, status dots, location labels |
| **sm** | 13pt | Captions, metadata labels, badges, error text, archive status |
| **md** | 16pt | Body text, chat bubbles, buttons, nav titles, input fields, forms |
| **lg** | 20pt | Section titles, screen headers, profile names |
| **xl** | 28pt | Hero/login headings, large initials |

### Naming Convention

All font tokens follow the pattern: **`font{size}{Weight}`**

```swift
// xs — 11pt
static let font11Regular   = fontFamily.font(size: 11)
static let font11Medium    = fontFamily.font(size: 11, weight: .medium)
static let font11Semibold  = fontFamily.font(size: 11, weight: .semibold)

// sm — 13pt
static let font13Regular   = fontFamily.font(size: 13)
static let font13Medium    = fontFamily.font(size: 13, weight: .medium)
static let font13Semibold  = fontFamily.font(size: 13, weight: .semibold)

// md — 16pt
static let font16Regular   = fontFamily.font(size: 16)
static let font16Medium    = fontFamily.font(size: 16, weight: .medium)
static let font16Semibold  = fontFamily.font(size: 16, weight: .semibold)
static let font16Bold      = fontFamily.font(size: 16, weight: .bold)

// lg — 20pt
static let font20Semibold  = fontFamily.font(size: 20, weight: .semibold)
static let font20Bold      = fontFamily.font(size: 20, weight: .bold)

// xl — 28pt
static let font28Light     = fontFamily.font(size: 28, weight: .light)
static let font28Bold      = fontFamily.font(size: 28, weight: .bold)
```

> **Adding a weight:** If you need `font13Bold`, add it to Theme.swift and use it everywhere — never inline.

---

## 4. Monospaced Fonts

For IDs, codes, timecodes, and technical values. Always uses system monospaced regardless of FontFamily.

Pattern: **`mono{size}{Weight}`**

```swift
static let mono11Medium = fontFamily.mono(size: 11, weight: .medium)
static let mono13Medium = fontFamily.mono(size: 13, weight: .medium)
static let mono16Medium = fontFamily.mono(size: 16, weight: .medium)
static let mono16Bold   = fontFamily.mono(size: 16, weight: .bold)
```

Special case for animated counters:
```swift
static let progressFont = Font.caption.monospacedDigit()
```

---

## 5. Icons

SF Symbols are sized by font. Icon tokens mirror the text scale.

Pattern: **`icon{size}`**

```swift
static let icon11 = fontFamily.font(size: 11)   // inline status indicators
static let icon13 = fontFamily.font(size: 13)   // metadata row icons, action buttons
static let icon16 = fontFamily.font(size: 16)   // standard inline icons
static let icon20 = fontFamily.font(size: 20)   // header action icons
```

Usage:
```swift
Image(systemName: "arrow.clockwise")
    .font(Theme.icon20)
    .foregroundStyle(Theme.blue)
```

---

## 6. Display Tier

For emoji, hero graphics, and decorative elements that sit **outside** the type scale.

Pattern: **`display{size}`**

```swift
static let display24 = fontFamily.font(size: 24)
static let display32 = fontFamily.font(size: 32)
static let display44 = fontFamily.font(size: 44, weight: .bold)   // play/pause overlays
static let display64 = fontFamily.font(size: 64)                  // empty state emoji
```

---

## 7. Color Architecture

### Core Palette (never use bare system colors)

```swift
static let black   = Color(hex: "#111111")    // NOT Color.black
static let white   = Color(hex: "#F5F5F5")    // NOT Color.white / .white
static let purple  = Color(hex: "#8576EE")
static let blue    = Color(hex: "#007AFF")
static let green   = Color(hex: "#30D158")
static let red     = Color(hex: "#FF453A")
static let yellow  = Color(hex: "#FFD60A")
static let amber   = Color(hex: "#FF9F0A")
```

### Semantic Colors

```swift
// Backgrounds
static let cardBg     = Color(hex: "#2C2C2E")
static let deepBg     = Color(hex: "#0A0E1A")
static let formBg     = Color(hex: "#1A2544")
static let separator  = Color(hex: "#38383A")
static let chatScreen = Color(hex: "#F3F2F2")

// Text hierarchy
static let primaryText   = Color(hex: "#F5F5F5")
static let secondaryText = Color(hex: "#98989D")
static let tertiaryText  = Color(hex: "#636366")

// Glass effects
static let glassOverlay = Color.white.opacity(0.05)
static let glassBorder  = Color.white.opacity(0.1)
```

### Enforcement Rules

- **No bare system colors:** `.white`, `.red`, `.blue`, `Color.black` → always `Theme.white`, `Theme.red` etc.
- **No `Color(hex:)` in views:** All hex values live in Theme.swift only.
- **Opacity is OK inline:** `Theme.white.opacity(0.6)` is fine — the base color is still a Theme token.

---

## 8. Corner Radii — 4 Tokens

```swift
static let radiusSm: CGFloat = 6     // thumbnails, small chips
static let radiusMd: CGFloat = 12    // cards, inputs, buttons
static let radiusLg: CGFloat = 16    // sheets, modals, large cards
static let radiusXl: CGFloat = 18    // hero elements, bubble containers
```

**Rule:** Never write a raw `cornerRadius` number in a view. Always use `Theme.radius*`.

---

## 9. Spacing — 8px Grid

```swift
static let space4:  CGFloat = 4
static let space8:  CGFloat = 8
static let space12: CGFloat = 12
static let space16: CGFloat = 16
static let space20: CGFloat = 20
static let space24: CGFloat = 24
static let space32: CGFloat = 32
```

**When to use tokens vs. raw values:** Use tokens for repeated horizontal/vertical padding. Raw values are OK for one-off layout tweaks (e.g., `.padding(.top, 50)` for toolbar inset).

---

## 10. Composite Constants

Repeated patterns get promoted to static constants:

```swift
// Gradients
static let screenGradient = LinearGradient(
    colors: [Theme.black, Theme.purple],
    startPoint: .top, endPoint: .bottom
)

static let loginGradient = LinearGradient(
    colors: [Theme.purple, Theme.black],
    startPoint: .top, endPoint: .bottom
)

static let buttonGradient = LinearGradient(
    colors: [Theme.bubbleBlueHi, Theme.bubbleBlueLo],
    startPoint: .top, endPoint: .bottom
)

// Button layout
static let buttonPaddingH:    CGFloat = 14
static let buttonPaddingV:    CGFloat = 8
static let buttonCornerRadius: CGFloat = radiusMd
```

**Rule:** If you see the same gradient, padding combo, or background pattern used 3+ times, extract it to Theme.swift.

---

## 11. Quick Reference: Choosing a Token

| I need to style... | Token to use |
|---|---|
| Body text in a chat bubble | `Theme.font16Regular` |
| A small gray timestamp | `Theme.font11Regular` + `Theme.secondaryText` |
| A section title | `Theme.font20Bold` + `Theme.white` |
| A button label | `Theme.font16Semibold` + `Theme.white` |
| An error message | `Theme.font13Regular` + `Theme.red` |
| A metadata ID | `Theme.mono13Medium` + `Theme.secondaryText` |
| An SF Symbol in a button | `Theme.icon13` |
| A header refresh icon | `Theme.icon20` + `Theme.blue` |
| A large empty-state emoji | `Theme.display64` |
| A card background | `Theme.cardBg` with `Theme.radiusMd` |
| A glass overlay panel | `Theme.glassOverlay` with `Theme.glassBorder` |

---

## 12. Hex Color Extension

Include this in Theme.swift to support `Color(hex:)`:

```swift
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
        self.init(.sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
```

---

## 13. Checklist for New Views

Before merging any new SwiftUI view, verify:

- [ ] **Zero** `.font(.system(size:))` calls — all fonts use `Theme.font*`
- [ ] **Zero** bare system colors (`.white`, `.red`, `Color.black`) — all use `Theme.*`
- [ ] **Zero** raw `cornerRadius` numbers — all use `Theme.radius*`
- [ ] **Zero** inline gradients — reuse `Theme.*Gradient` or add a new one
- [ ] Icons use `Theme.icon*` sizing, not inline `.font(.system(size:))`
- [ ] Repeated padding values use `Theme.space*` tokens
