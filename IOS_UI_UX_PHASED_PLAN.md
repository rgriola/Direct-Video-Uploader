May 10, 2026 - 10:40am - GitHub Copilot (GPT-5.3-Codex)

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
- [ ] Phase 2 - Light/dark mode architecture and polish
- [ ] Phase 3 - Onboarding walkthrough and simplified guide
- [ ] Phase 4 - QA, rollout, and release guardrails

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
- [ ] Define `AppearanceMode` enum: `system`, `light`, `dark`.
- [ ] Persist setting in `UserDefaults` and expose in Profile screen.
- [ ] Replace global forced dark mode with selected appearance policy.
- [ ] Extend Theme tokens to semantic dual palettes (not raw literals in views).
- [ ] Validate contrast and readability in Chat, Archive, Profile, Form, Metadata, Instructions.
- [ ] Keep brand tone while balancing readability in both modes.
- [ ] Capture before/after screenshots per key screen in both modes.

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
- [ ] Appearance selector works and persists.
- [ ] Key screens are visually complete in both modes.
- [ ] No major contrast/accessibility regressions.

---

## Phase 3 - Onboarding Walkthrough + Guide Simplification
### Outcome
Fast first-run walkthrough, with deep guide moved to optional reference.

### Checklist
- [ ] Design concise 3-step onboarding flow:
  - Step 1: Pick and upload
  - Step 2: Add details
  - Step 3: Share and archive
- [ ] Move verbose instructional content out of first-run mandatory path.
- [ ] Keep full guide accessible from header/help.
- [ ] Introduce onboarding completion state and reset hook for QA.
- [ ] Standardize onboarding copy style through message/catalog system.
- [ ] Validate first-run completion under 45 seconds.

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
- [ ] New onboarding is short and clear.
- [ ] Legacy guide remains available but no longer blocks first use.
- [ ] First-run state is stable across relaunch.

---

## Phase 4 - QA and Rollout
### Outcome
Controlled rollout with quality checks and rollback safety.

### Checklist
- [ ] Run full iOS smoke scenarios in light/dark.
- [ ] Validate websocket message code rendering across all chat event types.
- [ ] Validate fallback behavior by forcing unknown code.
- [ ] Validate onboarding paths: first run, repeat run, reset state.
- [ ] Update project status notes with final architecture decisions.
- [ ] Prepare release notes and rollback instructions.
- [ ] Tag release candidate and push.

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
- [ ] QA pass complete.
- [ ] Release notes complete.
- [ ] Rollback path verified.

---

## Pause/Resume Snapshot Template
Copy this block into your running notes before any stop:

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
