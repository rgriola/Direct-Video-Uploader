May 10, 2026 - 4:52pm - GitHub Copilot (GPT-5.3-Codex)

# Fixer iOS UI/UX - Phase 4 Release Notes

## Summary
Phase 4 execution is closed. This document captures validated QA outcomes and release-facing notes for the iOS UI/UX refresh track.

## Included Changes
- Phase 3 onboarding walkthrough is complete and no longer blocks first use.
- Dark mode is now the default when no appearance preference exists.
- Message-code fallback behavior is validated for unknown codes.
- Onboarding path validation is complete for first run, repeat run, and QA reset flow.

## Validation Evidence
- Server tests: 107/107 passed (`server` -> `npm test`).
- Admin production build: passed (`admin` -> `npm run build`).
- iOS build: passed (`ios` -> `xcodegen generate` + `xcodebuild ... build`).
- Unknown-code fallback forced by compiled harness against `MessageCatalog.swift`.
  - `CASE_A=Fallback from payload`
  - `CASE_B=Raw text fallback`

## Known Issues
- Admin strict build-check blocker is resolved (tsconfig `ignoreDeprecations` set to `"5.0"` for TypeScript 5.9.3).
- Screenshot evidence pack for key screens in both light and dark is tracked as post-phase packaging follow-up.
- Release candidate tag and push are tracked as release-ops handoff for deployment window execution.

## Release Readiness (Current)
- Phase 4 scope is closed with QA and guardrail sign-off.
- Release-ops follow-through remains tracked in handoff notes.
