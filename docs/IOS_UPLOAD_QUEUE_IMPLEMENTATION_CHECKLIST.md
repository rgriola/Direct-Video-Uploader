May 11, 2026 - 4:22pm - GitHub Copilot (GPT-5.3-Codex)

# iOS Video Upload Queue Implementation Checklist

## Goal

Build a fast and resilient iOS upload queue for large video files that:
- survives app backgrounding/termination,
- gives predictable progress behavior,
- retries safely on bad networks,
- and reduces time-to-playable in Mux.

## Current Baseline (Already in Place)

- [x] Background URLSession upload is used in VideoUploadService.
- [x] waitsForConnectivity and sessionSendsLaunchEvents are set.
- [x] Batch queue concurrency is capped at 2 uploads in ChatViewModel + VideoBatchUploadCoordinator.
- [x] Upload flow already targets Mux direct upload URLs from server.

## Phase P0 - Reliability First (Required)

### 1) Use one persistent background session identifier

- [ ] Replace per-upload UUID session identifiers with one stable identifier.
- [ ] Centralize session creation in one shared uploader/session manager.
- [ ] Ensure all upload tasks are created from this shared session.

Suggested touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift

### 2) Implement background URLSession relaunch handling

- [ ] Add background URLSession event capture in app lifecycle delegate.
- [ ] Store completion handler from application handleEventsForBackgroundURLSession.
- [ ] Call completion handler from urlSessionDidFinishEventsForBackgroundURLSession.
- [ ] Re-associate tasks to local queue state after relaunch.

Suggested touch points:
- ios/DirectVideoUploader/App/DirectVideoUploaderApp.swift (or app delegate bridge)
- ios/DirectVideoUploader/Services/VideoUploadService.swift

### 3) Persist queue state on disk

- [ ] Add UploadQueueStore persisted model (pending/running/paused/failed/completed).
- [ ] Save mapping: localUploadId -> assetId -> fileURL -> remote upload URL -> taskIdentifier.
- [ ] Rehydrate queue on launch and reconcile with URLSession.getAllTasks.
- [ ] Keep this independent from chat bubble memory so uploads survive app restarts.

Suggested touch points:
- ios/DirectVideoUploader/Services (new UploadQueueStore.swift)
- ios/DirectVideoUploader/Services/ChatViewModel.swift

### 4) Improve retry behavior

- [ ] Define retry policy by error type:
  - transient network: retry with exponential backoff + jitter,
  - auth errors: refresh/recreate upload URL,
  - permanent validation errors: fail fast.
- [ ] Set max retries per upload unit and surface actionable user state.
- [ ] Ensure retry does not create duplicate server assets.

Suggested touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift
- ios/DirectVideoUploader/Utilities/RetryHelper.swift

## Phase P1 - Throughput and Scheduling (High Value)

### 5) Add adaptive concurrency policy

- [ ] Keep queue-level max concurrency dynamic:
  - Wi-Fi + charging: 2,
  - cellular or Low Power Mode: 1.
- [ ] Use network path and power state signals to adjust queue safely.
- [ ] Keep manual override for debug builds.

Suggested touch points:
- ios/DirectVideoUploader/Services/VideoBatchUploadCoordinator.swift
- ios/DirectVideoUploader/Services/ChatViewModel.swift

### 6) Tune URLSession network policy

- [ ] Explicitly set:
  - allowsExpensiveNetworkAccess,
  - allowsConstrainedNetworkAccess,
  - allowsCellularAccess,
  - httpMaximumConnectionsPerHost (start at 2 for upload host).
- [ ] Define policy modes:
  - User initiated upload now (more permissive),
  - Deferred backlog upload (more restrictive).

Suggested touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift

### 7) Set task hints and priorities

- [ ] Set task.priority for urgent foreground uploads vs backlog uploads.
- [ ] Set countOfBytesClientExpectsToSend for scheduler hints.
- [ ] Keep resource timeout suitable for large clips and poor connectivity.

Suggested touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift

## Phase P2 - Fastest Time-to-Playable (Optional but Strong)

### 8) Choose upload transport strategy explicitly

- [ ] Decide one of:
  - A) Keep custom URLSession PUT path,
  - B) Adopt Mux iOS Upload SDK for chunking/retry/pause-resume semantics.
- [ ] If choosing SDK path, run small pilot behind feature flag and compare metrics.

Suggested touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift
- package dependency config (if SDK adopted)

### 9) Optimize input standardization for speed

- [ ] Decide default profile for newsroom speed:
  - 1080p SDR preferred for faster ingest,
  - preserve 4K only when required.
- [ ] Surface this policy in product requirements and QA scenarios.
- [ ] Keep metadata reporting so ops can correlate ingest delays with input type.

Suggested touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift
- server webhook/status reporting for non-standard input reasons

## Observability Checklist (Do Before Final Tuning)

### 10) Add upload telemetry

- [ ] Capture URLSessionTaskMetrics per upload.
- [ ] Log key timings:
  - queue wait time,
  - transfer duration,
  - retries count,
  - final status.
- [ ] Correlate with server-side timestamps:
  - mux upload created,
  - asset_created webhook,
  - asset.ready webhook.

Suggested touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift
- server/src/routes/mux-webhooks.js

## QA Matrix (Required)

### 11) Reliability test runs

- [ ] Start upload, lock device, wait, unlock.
- [ ] Start upload, background app for 5+ minutes.
- [ ] Start upload, force poor network (Wi-Fi drop -> cellular).
- [ ] Start upload, kill app (not user force-quit), relaunch and reconcile.
- [ ] Start 5-10 clip batch and verify ordering, retries, and no duplicates.

### 12) Performance test runs

- [ ] Compare single 500MB upload on Wi-Fi vs cellular.
- [ ] Compare queue throughput with concurrency 1 vs 2.
- [ ] Compare ingest readiness time with 4K vs 1080p inputs.

## Definition of Done

- [ ] Uploads reliably continue across background/suspension scenarios.
- [ ] Queue state survives app relaunch and reconciles correctly.
- [ ] No duplicate clips/assets from retry paths.
- [ ] Median upload success rate and completion time improve in field tests.
- [ ] Team has metrics dashboards/logs to diagnose regressions quickly.

## Rollout Plan

- [ ] Stage 1: internal QA build behind feature flag.
- [ ] Stage 2: limited pilot users (single org/team).
- [ ] Stage 3: full rollout after 48-hour stability window.
