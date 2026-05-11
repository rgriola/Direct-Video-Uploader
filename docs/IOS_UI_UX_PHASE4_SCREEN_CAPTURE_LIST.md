May 10, 2026 - 4:43pm - GitHub Copilot (GPT-5.3-Codex)

# Fixer iOS UI/UX - Phase 4 Screen Capture List

## Goal
Capture before and after evidence for key iOS screens in both Light and Dark modes.

## Capture Rules
- Use natural flow only (no forced Mux simulation).
- Use the same simulator/device for all captures in this set.
- Capture portrait orientation unless a screen is inherently landscape.
- Keep status bar and safe-area framing consistent across shots.

## Metadata To Record
- Branch: ios-uiux-refresh-2026q2
- Device: iPhone 17 Pro simulator
- Capture date and time:
- App version and build:
- Tester:

## File Naming Convention
- before-light-SXX-name.png
- before-dark-SXX-name.png
- after-light-SXX-name.png
- after-dark-SXX-name.png

## Screen Matrix
| ID | Screen | Before Light | Before Dark | After Light | After Dark | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| S01 | Login screen | [ ] | [ ] | [ ] | [ ] | Include server field and login button state |
| S02 | Chat idle connected | [ ] | [ ] | [ ] | [ ] | Header status visible, no active upload |
| S03 | Chat upload in progress | [ ] | [ ] | [ ] | [ ] | Video bubble uploading state with progress |
| S04 | Form sheet open | [ ] | [ ] | [ ] | [ ] | Slug and Description fields visible |
| S05 | Metadata sheet | [ ] | [ ] | [ ] | [ ] | Metadata rows visible (duration/resolution/codec) |
| S06 | Video Ready summary state | [ ] | [ ] | [ ] | [ ] | Include summary bubble and follow-up text |
| S07 | Archive list collapsed row | [ ] | [ ] | [ ] | [ ] | Status indicator visible |
| S08 | Archive row expanded | [ ] | [ ] | [ ] | [ ] | Actions and details visible |
| S09 | Profile screen | [ ] | [ ] | [ ] | [ ] | Appearance control + onboarding reset row |
| S10 | Instructions guide | [ ] | [ ] | [ ] | [ ] | One representative instruction page |
| S11 | Onboarding step 1 | [ ] | [ ] | [ ] | [ ] | Pick and Upload step |
| S12 | Onboarding step 3 | [ ] | [ ] | [ ] | [ ] | Share and Archive step |

## Completion Criteria
- All S01-S12 rows have both after captures complete in Light and Dark.
- Before captures are either completed or explicitly marked as reused baseline artifacts.
- Notes column explains any intentional visual differences.
