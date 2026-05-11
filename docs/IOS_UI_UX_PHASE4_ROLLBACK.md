May 10, 2026 - 4:26pm - GitHub Copilot (GPT-5.3-Codex)

# Fixer iOS UI/UX - Phase 4 Rollback Instructions

## Purpose
Provide a fast rollback path for the iOS UI/UX refresh branch if Phase 4 QA finds release-blocking regressions.

## Preconditions
- Verify the target rollback point exists (`ui-baseline-2026-05-10` or a known good commit).
- Confirm whether rollback is local-only, branch-only, or production-facing.
- Preserve current work by creating a safety branch before switching.

## Safe Rollback Workflow
1. Create a safety branch from current HEAD.
2. Checkout the known-good commit or baseline tag.
3. Rebuild server, admin, and iOS artifacts.
4. Re-run smoke validation before sharing rollback output.

## Commands
```bash
# 1) Safety branch from current state
git checkout -b rollback-safety-$(date +%Y%m%d-%H%M)

# 2) Return to baseline tag (or replace with known-good commit)
git checkout ui-baseline-2026-05-10

# 3) Validate project still builds
cd server && npm test
cd ../admin && npm run build
cd ../ios && xcodegen generate && xcodebuild -project DirectVideoUploader.xcodeproj -scheme DirectVideoUploader -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Partial Rollback Option (iOS UI/UX Only)
If only iOS UI/UX changes must be reverted while keeping backend changes:
```bash
# Example: restore iOS app folder to baseline tag
git checkout ui-baseline-2026-05-10 -- ios/DirectVideoUploader

# Regenerate project and rebuild
cd ios && xcodegen generate && xcodebuild -project DirectVideoUploader.xcodeproj -scheme DirectVideoUploader -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Exit Criteria
- Baseline behavior confirmed for chat flow, onboarding gate, and appearance mode.
- Build/test status is green for server/admin/iOS.
- Rollback commit or branch is documented in project notes.
