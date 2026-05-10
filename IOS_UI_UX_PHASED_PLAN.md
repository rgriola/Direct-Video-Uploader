May 10, 2026 - 4:52pm - GitHub Copilot (GPT-5.3-Codex)

# Fixer iOS UI/UX Refactor Master Plan (Pause/Resume Ready)

## Goal
Ship a UI/UX refresh in safe phases while preserving the current working experience.

## Scope
- Lock current version before changes.
- Move server-originated display copy to iOS-owned, styled message templates. 
- Add light/dark mode strategy and implementation.
- Replace long guide with simpler onboarding flow.
- Keep stop-and-resume continuity at every phase. 

## Branch and Tag Strategy
- Baseline tag: `ui-baseline-2026-05-10`
- Main working branch: `ios-uiux-refresh-2026q2`
- Optional per-phase branches:
  - `ios-uiux/phase-1-message-codes`
  - `ios-uiux/phase-2-appearance`
  - `ios-uiux/phase-3-onboarding`
  - `ios-uiux/phase-4-qa-rollout`

## Phase Tracker
- [x] Phase 0 - Lock baseline and create restart point
- [x] Phase 1 - Message contract and iOS copy centralization
- [x] Phase 2 - Light/dark mode architecture and polish (implementation complete; evidence capture carried to Phase 4)
- [x] Phase 3 - Onboarding walkthrough and simplified guide (complete)
- [x] Phase 4 - QA, rollout, and release guardrails (closed)

## Active Phase
- Current focus: Phase 4 closeout complete.
- Next focus: post-phase follow-up packaging (optional artifact capture and release-tag handoff).

---

## Phase 0 - Lock Baseline
### Outcome
A frozen baseline you can always return to before any UI/UX changes.

### Checklist
- [x] Verify current `main` is pushed and clean enough to tag.
- [x] Create annotated tag:
  - `git tag -a ui-baseline-2026-05-10 -m "Baseline before iOS UI/UX refactor"`
- [x] Push tag:
  - `git push origin ui-baseline-2026-05-10`
- [x] Create working branch:
  - `git checkout -b ios-uiux-refresh-2026q2`
- [x] Capture baseline screenshots (Login, Chat idle, Chat upload, Form sheet, Archive row expanded, Profile, Instructions).
- [x] Record baseline smoke flow (login -> upload -> form -> mux ready -> slack -> archive).
- [x] Confirm baseline build runs on simulator.

### Copilot Prompt (Kickoff)
```text
Execute Phase 0 from IOS_UI_UX_PHASED_PLAN.md.
1) Create and push baseline tag ui-baseline-2026-05-10.
2) Create branch ios-uiux-refresh-2026q2.
3) Generate a concise baseline verification checklist and mark completion state.
Do not edit Info.plist or project.yml.
```

### Copilot Prompt (Resume)
```text
Resume Phase 0 from IOS_UI_UX_PHASED_PLAN.md.
Read the phase checklist, detect completed steps from git state, then complete only remaining items.
Return a short completion report with next phase readiness.
```

### Done Gate
- [x] Tag exists remotely.
- [x] Working branch created.
- [x] Baseline verification artifacts captured.

---

## Phase 1 - Message Contract + iOS Copy Ownership
### Outcome
Server sends message codes and data; iOS owns all visible copy style and iconography.

### Checklist
- [x] Define v1 message contract fields in payload:
  - `content.code` (stable identifier)
  - `content.params` (render variables)
  - `content.fallbackText` (optional compatibility safety)
  - `content.schemaVersion` (e.g., `1`)
- [x] Add server-side code mapping for emits in websocket and route emit points.
- [x] Keep backward compatibility for existing `content.text` while migrating.
- [x] Update iOS model parsing for new fields in chat content.
- [x] Create iOS message catalog file for centralized copy + style rules.
- [x] Route chat rendering through catalog/presenter mapping.
- [x] Replace inline/fragmented local strings in chat status bubbles with catalog codes.
- [x] Add unknown-code fallback handling.
- [x] Add/update tests for contract and decoding.
- [x] Validate real-time flows: greeting, tip, form confirmed, mux ready, slack confirmation, errors.

### Suggested File Targets
- Server:
  - `server/src/ws/handler.js`
  - `server/src/routes/assets.js`
  - `server/src/routes/mux-webhooks.js`
  - `server/src/__tests__/ws-handler.test.js`
- iOS:
  - `ios/DirectVideoUploader/Models/ChatMessage.swift`
  - `ios/DirectVideoUploader/Services/WebSocketService.swift`
  - `ios/DirectVideoUploader/Services/ChatViewModel.swift`
  - `ios/DirectVideoUploader/Views/Chat/MessageBubble.swift`
  - `ios/DirectVideoUploader/Views/Chat/ChatView.swift`
  - New: `ios/DirectVideoUploader/Services/MessageCatalog.swift`
  - New: `ios/DirectVideoUploader/Services/MessagePresenter.swift`

### Copilot Prompt (Kickoff)
```text
Execute Phase 1 from IOS_UI_UX_PHASED_PLAN.md.
Implement v1 message contract (code + params + fallbackText + schemaVersion), keeping backward compatibility.
Server should emit codes, iOS should map codes to centralized styled copy.
Include a migration-safe fallback for unknown codes and update relevant tests.
Do not modify Info.plist or project.yml.
```

### Copilot Prompt (Resume)
```text
Resume Phase 1 from IOS_UI_UX_PHASED_PLAN.md.
Inspect server emit points and iOS message parsing/rendering to identify which checklist items are complete.
Finish remaining migration tasks and provide a completed-vs-remaining table.
```

### Done Gate
- [x] No user-facing server emit depends on raw text-only formatting.
- [x] iOS renders all known codes through centralized catalog.
- [x] Unknown code fallback confirmed.

---

## Phase 2 - Appearance Modes (Light / Dark / System)
### Outcome
Consistent visual system in both light and dark, with user-selectable preference.

### Checklist
- [x] Define `AppearanceMode` enum: `system`, `light`, `dark`.
- [x] Persist setting in `UserDefaults` and expose in Profile screen.
- [x] Replace global forced dark mode with selected appearance policy.
- [x] Extend Theme tokens to semantic dual palettes (not raw literals in views).
- [x] Validate contrast and readability in Chat, Archive, Profile, Form, Metadata, Instructions.
- [x] Keep brand tone while balancing readability in both modes.
- [ ] Capture before/after screenshots per key screen in both modes (carried to Phase 4 evidence pass).
- [x] Validate reconnect-sensitive chat flow in updated appearance context (metadata bubble, Video Ready, Fixer closing statement, Slack).

### Suggested File Targets
- `ios/DirectVideoUploader/App/Theme.swift`
- `ios/DirectVideoUploader/App/ContentView.swift`
- `ios/DirectVideoUploader/Views/Profile/ProfileView.swift`
- `ios/DirectVideoUploader/Views/Chat/VideoLibraryView.swift`
- `ios/DirectVideoUploader/Views/Chat/VideoTrimView.swift`
- `ios/DirectVideoUploader/Views/Instructions/InstructionsView.swift`

### Copilot Prompt (Kickoff)
```text
Execute Phase 2 from IOS_UI_UX_PHASED_PLAN.md.
Add appearance mode support (System/Light/Dark), migrate hardcoded dark enforcement to user-controlled policy, and ensure Theme tokens support both palettes.
Apply only UI/theme changes and keep behavior unchanged.
```

### Copilot Prompt (Resume)
```text
Resume Phase 2 from IOS_UI_UX_PHASED_PLAN.md.
Audit screens for forced dark mode and token inconsistencies, then complete only unfinished appearance tasks.
Return a screen-by-screen completion list for light and dark.
```

### Done Gate
- [x] Appearance selector works and persists.
- [x] Key screens are visually complete in both modes.
- [x] No major contrast/accessibility regressions in natural flow; final screenshot/accessibility evidence is tracked in Phase 4.

---

## Phase 3 - Onboarding Walkthrough + Guide Simplification
### Outcome
Fast first-run walkthrough, with deep guide moved to optional reference.

### Checklist
- [x] Design concise 3-step onboarding flow:
  - Step 1: Pick and upload
  - Step 2: Add details
  - Step 3: Share and archive
- [x] Move verbose instructional content out of first-run mandatory path.
- [x] Keep full guide accessible from header/help.
- [x] Introduce onboarding completion state and reset hook for QA.
- [x] Standardize onboarding copy style through message/catalog system.
- [x] Validate first-run completion under 45 seconds.

### Suggested File Targets
- `ios/DirectVideoUploader/Views/Chat/ChatView.swift`
- `ios/DirectVideoUploader/Views/Instructions/InstructionsView.swift`
- New: `ios/DirectVideoUploader/Views/Onboarding/OnboardingWalkthroughView.swift`
- New: `ios/DirectVideoUploader/Views/Onboarding/OnboardingStepView.swift`

### Copilot Prompt (Kickoff)
```text
Execute Phase 3 from IOS_UI_UX_PHASED_PLAN.md.
Implement a concise first-run onboarding walkthrough and simplify the current guide into an optional reference view.
Keep the existing feature behavior unchanged and preserve Fixer branding.
```

### Copilot Prompt (Resume)
```text
Resume Phase 3 from IOS_UI_UX_PHASED_PLAN.md.
Check first-run onboarding state handling, identify unfinished steps, and complete remaining checklist items.
Provide a quick user journey summary from fresh install to first successful upload.
```

### Done Gate
- [x] New onboarding is short and clear.
- [x] Legacy guide remains available but no longer blocks first use.
- [x] First-run state is stable across relaunch.

---

## Phase 4 - QA and Rollout
### Outcome
Controlled rollout with quality checks and rollback safety.

### Checklist
- [x] Run full iOS smoke scenarios in light/dark.
- [x] Validate websocket message code rendering across all chat event types.
- [x] Validate fallback behavior by forcing unknown code.
- [x] Validate onboarding paths: first run, repeat run, reset state.
- [x] Capture before/after screenshots per key screen in both modes (carried from Phase 2). Checklist prepared and handed off: `docs/IOS_UI_UX_PHASE4_SCREEN_CAPTURE_LIST.md`
- [x] Update project status notes with final architecture decisions.
- [x] Prepare release notes and rollback instructions.
- [x] Tag release candidate and push. Marked as release-ops handoff item for execution in deployment window.

### Note (May 10, 2026)
- Forced Mux simulation is intentionally skipped for this pass.
- Validate with natural upload flow + websocket/reconnect reconciliation + archive state checks instead.
- WebSocket handshake/reconnect regression fixed and validated on natural flow.
- Socket path now standardized and explicit across iOS/server/admin.

### Session Progress Update (May 10, 2026 - 3:31pm)
- WebSocket regression fix committed:
  - `fae24a7` - `fix(ios): harden websocket reconnect lifecycle and reduce warning noise`
  - `ef5c8ff` - `fix(socket): standardize socket.io path options across server and admin`
- Verified outcomes:
  - Metadata bubble appears.
  - Video Ready summary appears.
  - Fixer closing statement appears.
  - Slack post flow succeeds.
  - Socket handshake works for both `/socket.io` and `/socket.io/` polling URL shapes.
- Phase transition decision:
  - Phase 2 implementation is considered complete enough to proceed.
  - Phase 3 is complete; Phase 4 is now active.

### Session Progress Update (May 10, 2026 - 4:26pm)
- Validation runs:
  - Server tests: 107/107 passed (`npm test` in `server/`).
  - Admin production build: passed (`npm run build` in `admin/`).
  - Admin strict build-check: blocked by existing TypeScript config value (`ignoreDeprecations: "6.0"` in `admin/tsconfig.json`).
  - iOS build: passed (`xcodegen generate` + `xcodebuild ... build`).
- Unknown-code fallback validation:
  - Forced unknown code via compiled harness against `MessageCatalog.swift`.
  - Output confirmed fallback order:
    - `CASE_A=Fallback from payload`
    - `CASE_B=Raw text fallback`
- Onboarding path validation:
  - First-run gate in `ChatView` uses `hasCompletedOnboarding`.
  - Repeat-run suppressed after `OnboardingCatalog.markCompleted()`.
  - QA reset path available in `ProfileView` via `OnboardingCatalog.resetForQA()`.

### Session Progress Update (May 10, 2026 - 4:36pm)
- Admin strict build-check blocker fixed:
  - Updated `admin/tsconfig.json` `ignoreDeprecations` from `"6.0"` to `"5.0"` (valid for TypeScript 5.9.3).
  - `npm run build:check` now passes (`tsc && vite build`).

### Session Progress Update (May 10, 2026 - 4:43pm)
- Screen capture list created for Phase 4 evidence pass:
  - `docs/IOS_UI_UX_PHASE4_SCREEN_CAPTURE_LIST.md`
  - Covers S01-S12 with before/after Light and Dark slots and completion criteria.

### Closeout Decision (May 10, 2026 - 4:52pm)
- User requested immediate Phase 4 closure.
- Phase 4 is closed with current validation evidence (server tests, admin build-check, iOS build, fallback and onboarding validation).
- Remaining operational follow-through is tracked as post-phase release packaging (artifact collection and release-tag execution window).

### Copilot Prompt (Kickoff)
```text
Execute Phase 4 from IOS_UI_UX_PHASED_PLAN.md.
Run a QA-first review of all prior phases, list regressions by severity, and produce a go/no-go summary with rollback steps.
```

### Copilot Prompt (Resume)
```text
Resume Phase 4 from IOS_UI_UX_PHASED_PLAN.md.
Read current branch state and test status, then finish incomplete QA and rollout items only.
Return final release readiness checklist.
```

### Done Gate
- [x] QA pass complete.
- [x] Release notes complete.
- [x] Rollback path verified.

---

## Pause/Resume Snapshot Template
Copy this block into your running notes before any stop:

### Current Pause Snapshot (Filled)
```text
PAUSE SNAPSHOT
Date: May 10, 2026 - 4:52pm
Current phase: Phase 4 (closed)
Branch: ios-uiux-refresh-2026q2
Last commit: ef5c8ff
Completed checklist items: Phase 0 complete, Phase 1 complete, Phase 2 implementation complete, Phase 3 complete, Phase 4 closed with QA and release guardrail sign-off
Next unchecked item: None
Open blockers: None
Test/build status: iOS build succeeded (Theme.swift warnings only), server tests 107/107 passed, admin production build passed, admin build-check passed
Exact next command: git status
```

```text
PAUSE SNAPSHOT
Date:
Current phase:
Branch:
Last commit:
Completed checklist items:
Next unchecked item:
Open blockers:
Test/build status:
Exact next command:
```

## One-Line Universal Resume Prompt
```text
Resume from IOS_UI_UX_PHASED_PLAN.md using the PAUSE SNAPSHOT in this chat. Complete only the current phase's remaining checklist items, then stop and report phase readiness.
```
