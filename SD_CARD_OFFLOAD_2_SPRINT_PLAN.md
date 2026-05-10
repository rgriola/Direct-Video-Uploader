# SD Card Offload + Grouped Context Form — 2 Sprint Plan
- Last updated: May 9, 2026 - 10:42pm - GPT-5.3-Codex

Status: Draft for discussion

## Problem Statement

We need an iOS workflow that supports offloading a full SD card of video files without copying the entire card to iPhone storage first.

Core constraints:

- No full pre-copy of SD card files to local device storage.
- Thumbnail-first browsing for large card contents.
- Select All and per-file selection both required.
- One grouped context form should apply to a selected batch of files.
- Upload path should stream from SD card source handles to destination.

## Guiding Decisions

1. Transfer model
- Stream selected files directly from external source to destination.
- Persist only lightweight state (manifest, statuses, metadata), not media bytes.

2. Grouping model
- User creates one upload group (assignment/batch).
- Files are linked to the group before transfer starts.
- Group-level context is required; file-level override is optional in Sprint 2.

3. UX model
- Index first, then choose files.
- Show live totals (file count and total bytes) before upload.

## Sprint 1 (2 Weeks) — MVP: Direct SD Offload + Group Form

Goal: Working end-to-end batch offload from SD card with grouped context form and basic resilience.

### S1-01 External Source Access Layer
Description:
- Add SD card / Files provider access and persistent handle strategy.

Acceptance criteria:
- User can open an SD-backed folder and enumerate video files.
- Access survives app relaunch where platform allows restoration.
- Clear error state when source handle expires.

Dependencies:
- None

### S1-02 Indexer + Thumbnail Pipeline
Description:
- Build progressive indexer for large folders (filename, duration, size, thumbnail).

Acceptance criteria:
- First thumbnails appear quickly while indexing continues.
- Supports 500+ files without UI lockups.
- Unsupported/corrupt files are marked, not blocking the index.

Dependencies:
- S1-01

### S1-03 Selection UX (Select All + Individual)
Description:
- Add grid/list selection model with Select All, Deselect All, and individual toggles.

Acceptance criteria:
- Accurate selected count and selected total size.
- Select All works across full indexed result set.
- User can remove individual files after Select All.

Dependencies:
- S1-02

### S1-04 Group Context Form v1
Description:
- Add required batch form before upload (assignment, slug/title, destination, priority, notes).

Acceptance criteria:
- Upload cannot start until required fields are complete.
- Form is tied to batchId and persists through relaunch.
- One form applies to all selected files.

Dependencies:
- S1-03

### S1-05 Upload Manifest + Queue State
Description:
- Persist lightweight per-batch manifest: file refs, upload status, retry count, timestamps.

Acceptance criteria:
- Relaunch restores queued/in-progress/completed/failed statuses.
- No full media file copy is performed by queue layer.
- Manifest can be garbage-collected after completion.

Dependencies:
- S1-04

### S1-06 Server Batch API v1
Description:
- Add batch endpoints and link each uploaded file to the batch context.

Acceptance criteria:
- Create batch, attach file records, update progress, complete batch.
- Existing auth model enforced with org scoping.
- Server returns per-file status and batch summary.

Dependencies:
- S1-04

### S1-07 Direct Upload Worker v1
Description:
- Stream file handles to destination with bounded concurrency and retry.

Acceptance criteria:
- Offloads large sets without device storage blow-up.
- Per-file retries do not restart successful files.
- Upload continues reliably across transient network loss.

Dependencies:
- S1-05, S1-06

### S1-08 Batch Progress + Error UX
Description:
- Show per-file and batch-level states in UI.

Acceptance criteria:
- States: queued, uploading, complete, failed, retrying.
- User can retry failed files only.
- Errors are actionable and human-readable.

Dependencies:
- S1-07

Sprint 1 definition of done:
- User can select many SD card videos, apply one context form, and upload directly to destination without pre-copying full files to iPhone storage.

## Sprint 2 (2 Weeks) — Reliability + Operational Scale

Goal: Harden for real newsroom usage with resume, reconnect, and observability.

### S2-01 Resume-Capable Transfer Strategy
Description:
- Add resumable upload strategy (offset/chunk aware) for interrupted large files.

Acceptance criteria:
- Mid-file interruption resumes without restarting from zero.
- Resume survives app relaunch and temporary disconnect.

Dependencies:
- S1-07

### S2-02 SD Detach/Reattach Recovery
Description:
- Pause queue when source card is removed; recover when reconnected.

Acceptance criteria:
- Queue enters blocked state on detach with clear prompt.
- On reattach, matching files can continue without rebuilding entire batch.

Dependencies:
- S1-05, S2-01

### S2-03 Adaptive Concurrency + Backpressure
Description:
- Auto-tune upload concurrency based on network behavior and error rate.

Acceptance criteria:
- Throughput improves on strong networks.
- Failure storms reduce by backing off automatically.

Dependencies:
- S1-07

### S2-04 Group Form v2 (Optional File Overrides)
Description:
- Keep group defaults but allow optional per-file override for selected fields.

Acceptance criteria:
- Group defaults apply to all files initially.
- User can override selected files without duplicating whole form.

Dependencies:
- S1-04

### S2-05 Batch Notifications + Completion Semantics
Description:
- Finalize batch-level success/partial/failure with sender/receiver notifications.

Acceptance criteria:
- Batch completion reflects actual terminal states of all files.
- Notification sends are idempotent and retry-safe.

Dependencies:
- S1-06, S2-01

### S2-06 Admin Batch Visibility
Description:
- Add admin screens/API for grouped upload observability.

Acceptance criteria:
- Admin can view batch summary + per-file outcomes.
- Org-scoped admins only see their org data.

Dependencies:
- S1-06

### S2-07 Soak + Scale Validation
Description:
- Run large-card simulations and resilience tests.

Acceptance criteria:
- Validate reliability target on 100GB-160GB scenario tests.
- Publish known limits and operational runbook notes.

Dependencies:
- S2-01, S2-03

Sprint 2 definition of done:
- System can reliably handle large SD card offload sessions with resume/recovery, clear batch semantics, and admin visibility.

## API Draft (For Discussion)

Batch endpoints:

- POST /api/video-batches
- GET /api/video-batches
- GET /api/video-batches/:id
- PATCH /api/video-batches/:id/context
- POST /api/video-batches/:id/files
- PATCH /api/video-batches/:id/files/:fileId/status
- POST /api/video-batches/:id/complete

Notes:
- Keep existing asset upload route flow intact for initial integration.
- Batch layer orchestrates many file uploads, not a full backend rewrite.

## Risks to Watch

1. External file handle invalidation after long idle periods.
2. Thumbnail generation cost on very large cards.
3. Memory pressure if too many previews load simultaneously.
4. Inconsistent behavior across SD adapters and Files providers.
5. Network variability for multi-hour offload sessions.

## Open Questions for Next Discussion

1. Should Sprint 1 support background transfer only while app is foregrounded, with full resilient resume in Sprint 2?
2. Should grouped context fields be strictly required for all batches, or can destination be optional for certain workflows?
3. Do we need per-file context overrides in Sprint 1 for breaking-news exceptions?
4. What is acceptable user experience when SD card is detached mid-transfer?
5. What should be the hard limits for file count and total batch size per job?

## Suggested First Execution Order

1. S1-01 External source access
2. S1-02 Indexer + thumbnails
3. S1-03 Selection UX
4. S1-04 Group context form
5. S1-06 Server batch API v1
6. S1-05 Manifest + queue state
7. S1-07 Direct upload worker
8. S1-08 Progress + errors UI