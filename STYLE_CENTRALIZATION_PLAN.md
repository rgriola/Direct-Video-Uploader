# Centralize Chat Layout Styles — Typography, Colors, and Button Tokens

The iOS app currently scatters **50+ ad-hoc `.font(.system(size: …))` calls** and **10+ raw `Color(hex:)` values** across 10+ Swift view files. There are no shared typography tokens, no reusable button styles, and no design-system constants for spacing/corner radii. The result: changing a single font size requires editing many files, and visual consistency is impossible to maintain.

**Goal:** Extend `Theme.swift` into a single-source-of-truth design system so that all chat message layouts — text, dates, buttons, badges, metadata rows — use named tokens. Changing a font size, weight, or color becomes a one-line edit in `Theme.swift`.

## Current Problems (Audit Summary)

| Problem | Example |
|---|---|
| **Font sizes are magic numbers** | `.font(.system(size: 16))`, `.font(.system(size: 13, weight: .semibold))` appear 50+ times with no shared constant |
| **Same role, different sizes** | Timestamp: `size: 10` in `MessageBubble`, `size: 12` in `SentUploadBubble`, `size: 12` in `ArchiveRowView` |
| **Hardcoded colors bypass Theme** | `InputBar.swift` uses `Color(hex: "#1C3A5F")`, `Color(hex: "#D4D4D4")`, `Color(hex: "#ADADAD")` instead of Theme tokens |
| **Duplicated button styling** | Metadata + View buttons are copy-pasted across `MessageBubble.confirmationContent`, `formRequestContent`, and `ArchiveRowView` |
| **No shared button style** | Every button manually sets `.padding`, `.background`, `.foregroundStyle`, `.clipShape` individually |
| **Inconsistent badge styling** | Slack channel/mention badges define their own padding/radius inline |

---

## Proposed Changes

### Theme & Design Tokens

#### [MODIFY] [Theme.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/App/Theme.swift)

Add three new sections to the existing `Theme` enum:

**1. Typography tokens** — Named `Font` constants for every text role:

```swift
// MARK: - Typography
static let bodyFont        = Font.system(size: 16)                           // chat message body
static let bodyMediumFont  = Font.system(size: 15, weight: .medium)          // video content, form text
static let captionFont     = Font.system(size: 13)                           // general captions
static let captionBoldFont = Font.system(size: 13, weight: .semibold)        // button labels, section headers
static let timestampFont   = Font.system(size: 11)                           // timestamps under bubbles
static let badgeFont       = Font.system(size: 11, weight: .medium)          // channel/mention badge text
static let badgeSymbolFont = Font.system(size: 11, weight: .bold, design: .monospaced) // #/@ in badges
static let monoSmallFont   = Font.system(size: 13, weight: .medium, design: .monospaced) // filenames, slugs
static let monoIdFont      = Font.system(size: 14, weight: .bold, design: .monospaced)   // mediasource IDs
static let urlFont         = Font.system(size: 11)                           // URL text
static let labelFont       = Font.system(size: 11, weight: .semibold)        // form field labels
static let iconSmallFont   = Font.system(size: 12)                           // small icons (🔗, copy)
static let iconMediumFont  = Font.system(size: 13)                           // button icons
static let iconLargeFont   = Font.system(size: 34)                           // checkmark/send icons
static let titleFont       = Font.system(size: 20, weight: .bold)            // sheet/page titles
static let headerNameFont  = Font.system(size: 16, weight: .semibold)        // chat header name
static let headerStatusFont = Font.system(size: 12)                          // connection status text
static let locationFont    = Font.system(size: 11)                           // "Location included"
static let locationIconFont = Font.system(size: 10)                          // location pin icon
```

**2. Missing color tokens** — Bring hardcoded hex values under `Theme`:

```swift
// InputBar colors
static let inputBarBg       = Color(hex: "ADADAD")
static let inputFieldBg     = Color(hex: "D4D4D4")
static let actionBlue       = Color(hex: "1C3A5F")  // attachment/send button color (already used for outgoingBubble)
```

**3. Button style tokens** — Constants for padding, corner radius:

```swift
// MARK: - Button Layout
static let buttonPaddingH: CGFloat = 14
static let buttonPaddingV: CGFloat = 8
static let buttonCornerRadius: CGFloat = 8
static let badgePaddingH: CGFloat = 12
static let badgePaddingV: CGFloat = 6
static let badgeCornerRadius: CGFloat = 6
```

---

### Reusable Button Styles

#### [NEW] [ChatButtonStyle.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Chat/ChatButtonStyle.swift)

Create reusable SwiftUI `View` helpers for the two repeated button patterns:

```swift
/// Reusable action button — used for "Metadata", "View", etc.
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

/// Reusable badge — used for Slack #channel and @mention
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
```

---

### Chat View Updates

#### [MODIFY] [MessageBubble.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Chat/MessageBubble.swift)

- Replace all `.font(.system(size: …))` with `Theme.*Font` tokens
- Replace duplicated button code with `ChatActionButton`
- Replace duplicated badge code with `ChatBadge`
- Unify timestamp font to `Theme.timestampFont`

#### [MODIFY] [SentUploadBubble.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Chat/SentUploadBubble.swift)

- Replace all ad-hoc fonts with `Theme.*Font` tokens
- Use `Theme.timestampFont` for date, `Theme.monoSmallFont` for filename

#### [MODIFY] [VideoPreviewBubble.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Chat/VideoPreviewBubble.swift)

- Same token replacements as `SentUploadBubble`

#### [MODIFY] [InputBar.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Chat/InputBar.swift)

- Replace `Color(hex: "#1C3A5F")` → `Theme.actionBlue`
- Replace `Color(hex: "#D4D4D4")` → `Theme.inputFieldBg`
- Replace `Color(hex: "#ADADAD")` → `Theme.inputBarBg`
- Replace font `.system(size:)` calls → `Theme.*Font` tokens

#### [MODIFY] [ChatHeaderView.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Chat/ChatHeaderView.swift)

- Replace font calls → `Theme.headerNameFont`, `Theme.headerStatusFont`

#### [MODIFY] [TypingIndicatorBubble.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Chat/TypingIndicatorBubble.swift)

- No font changes needed (no text), but already uses `Theme.typingDot` ✅

---

### Non-Chat Views (Secondary Scope)

These views also use ad-hoc fonts. We'll update them for full consistency:

#### [MODIFY] [ArchiveRowView.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Archive/ArchiveRowView.swift)

- Replace button code with `ChatActionButton`
- Replace `.font(.system(size:))` → `Theme.*Font` tokens

#### [MODIFY] [ArchiveListView.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Archive/ArchiveListView.swift)

- Replace header/status fonts → `Theme.titleFont`, `Theme.captionFont`

#### [MODIFY] [MetadataView.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Metadata/MetadataView.swift)

- Replace all ad-hoc fonts → Theme tokens

#### [MODIFY] [ContextFormView.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Form/ContextFormView.swift)

- Replace fonts → `Theme.bodyMediumFont`, `Theme.labelFont`, etc.

#### [MODIFY] [LoginView.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Auth/LoginView.swift)

- Replace fonts → Theme tokens

---

## What Changes After This

| Before | After |
|---|---|
| Change a timestamp font → edit 4 files | Change `Theme.timestampFont` → one line |
| Change button style → edit 5 button instances | Change `ChatActionButton` → one place |
| Hardcoded `Color(hex:)` in `InputBar` | `Theme.inputBarBg` / `Theme.actionBlue` |
| 10+ different font sizes for similar roles | Named tokens: `bodyFont`, `captionFont`, `timestampFont` |

---

## Verification Plan

> [!IMPORTANT]
> There are **no existing unit tests** in this project. The verification is build-based + visual.

### Build Verification
1. Open `ios/DirectVideoUploader.xcodeproj` in Xcode
2. Build for iPhone simulator (⌘B) — must compile with **zero errors**
3. The refactoring is pure visual-token replacement; no logic changes

### Manual Visual Verification
After building, run on the simulator and verify these screens look **identical** to the current version:

1. **Login screen** — fonts and layout unchanged
2. **Chat screen** — send a text message, verify bubble font, timestamp, spacing
3. **Slack message bubble** — verify channel/mention badges render correctly
4. **Confirmation bubble** — verify Metadata + View buttons appear correctly
5. **Video preview bubble** — verify filename, date, location badge
6. **Sent upload bubble** — verify thumbnail card layout
7. **Archive list** — expand a row, verify metadata rows and View button
8. **Metadata sheet** — verify all rows render correctly
9. **Context form** — verify field labels, slug/description inputs, priority buttons

> [!TIP]
> Since this is a purely cosmetic refactoring (replacing inline values with named constants holding the same values), every screen should look **pixel-identical** before and after.
