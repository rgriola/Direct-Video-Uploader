# Upload Setups — PM Ticket Board (Sprint 1)
- Last updated: May 9, 2026 - 11:09pm - GPT-5.3-Codex

Status: Draft for leadership review

Sprint goal:
- Ship camera-library multiclip video using queue + grouped form + existing upload endpoints.

Assumptions:
- Sprint length: 2 weeks
- 1 iOS engineer, 1 server engineer, shared QA support
- Keep current auth model and existing video endpoints

## Ticket Table

| Ticket ID | Setup | Ticket | Owner | Estimate | Depends On | Demo Criteria |
|---|---|---|---|---|---|---|
| UPL-S1-01 | Camera Library Video | Upgrade library picker to multiclip selection and staged batch confirm flow | iOS | 2d | None | User selects 5+ videos and confirms a single batch payload from the library sheet |
| UPL-S1-02 | Camera Library Video | Add batch domain models and persistent queue store | iOS | 1.5d | UPL-S1-01 | App relaunch restores pending batch with per-item statuses |
| UPL-S1-03 | Camera Library Video | Add grouped context form and one-to-many apply logic | iOS | 2d | UPL-S1-02 | One submitted form is applied to all assets in a batch |
| UPL-S1-04 | Camera Library Video | Add batch upload coordinator (bounded concurrency and retry failed only) | iOS | 2d | UPL-S1-02 | Batch uploads run with concurrency 2-3 and retry failed items without re-uploading successful items |
| UPL-S1-05 | Camera Library Video | Add batch progress UX in chat/archive surfaces | iOS | 1.5d | UPL-S1-04 | UI shows batch progress, per-file status, and retry action for failed files |
| UPL-S1-06 | Existing Endpoint Reuse | Validate and harden existing asset endpoints for multiclip burst usage | Server | 1.5d | UPL-S1-04 | 20-file burst test passes using existing /api/assets, /mux-upload, and /form contracts |
| UPL-S1-07 | SD Card Readiness | Build source-handle abstraction layer usable by library and SD sources | iOS | 1.5d | UPL-S1-02 | Library source works through abstraction with no behavior regressions |
| UPL-S1-08 | Program/QA | Run sprint demo script and publish pass/fail matrix | QA + PM | 1d | UPL-S1-01..UPL-S1-07 | Demo script executed end-to-end with evidence clips and issue list |

## Demo Script (Sprint Review)

1. Select 8 camera-library videos.
2. Fill one grouped context form.
3. Start upload and observe per-file progress.
4. Force one file failure and retry only that file.
5. Relaunch app and show queue restore.
6. Verify all assets have form data applied.

## Risks and Mitigations

1. Risk: Per-asset form requests repeatedly pop UI.
- Mitigation: Gate ws form presentation during batch apply mode.

2. Risk: Concurrency causes memory pressure.
- Mitigation: Cap concurrency to 2-3 and monitor memory in profiling runs.

3. Risk: Existing endpoint rate limits throttle multiclip runs.
- Mitigation: Validate burst behavior and tune limits in the same sprint.

## Decision Gate at Sprint End

Go/No-Go for Sprint 2 chunk-resume work:
- Go if multiclip batch flow is stable in foreground mode and retry behavior is predictable.
