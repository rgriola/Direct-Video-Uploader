May 11, 2026 - 5:21pm - GitHub Copilot (GPT-5.3-Codex)

# iOS Upload Queue Execution Plan (Future Reuse)

## Objective

Build and maintain a reliable Fixer iOS upload queue that survives app lifecycle events,
handles weak networks safely, and keeps ingest latency predictable.

## Locked Product Decisions

- Transport decision is locked to custom URLSession direct PUT uploads.
- Mux iOS Upload SDK path is out of scope for now and tracked as N/A.
- This plan is reusable for future reliability passes by updating status, owner, and evidence.

## Baseline Snapshot (Current)

- [x] Background URLSession upload path exists.
- [x] waitsForConnectivity and sessionSendsLaunchEvents are enabled.
- [x] Queue concurrency is currently capped at 2 in batch coordinator usage.
- [x] Upload target is server-provided Mux direct upload URL.

## Execution Tracker

Update the fields during each pass.

| Item | Priority | Status | Owner | Evidence | Last Updated |
| --- | --- | --- | --- | --- | --- |
| P0.1 One persistent background session identifier | P0 | Implemented (needs QA) | iOS | VideoUploadService shared coordinator | 2026-05-11 |
| P0.2 Background relaunch lifecycle handling | P0 | Implemented (needs QA) | iOS | App delegate bridge + completion handoff | 2026-05-11 |
| P0.3 Persisted queue mapping and task reconciliation | P0 | Implemented (needs QA) | iOS | Upload queue store + reconcile method | 2026-05-11 |
| P0.4 Error-class retry policy | P0 | Implemented (needs QA) | iOS | VideoUploadService retry classifier + in-flight dedupe guard | 2026-05-11 |
| P1.5 Adaptive concurrency policy | P1 | Not Started | iOS | N/A | 2026-05-11 |
| P1.6 URLSession network policy tuning | P1 | Not Started | iOS | N/A | 2026-05-11 |
| P1.7 Task priority and expected-byte hints | P1 | Not Started | iOS | N/A | 2026-05-11 |
| P2.8 Transport strategy lock | P2 | Done (A) / N/A (B) | iOS | Custom URLSession PUT retained | 2026-05-11 |
| P2.9 Input standardization policy | P2 | Not Started | Product + iOS | N/A | 2026-05-11 |
| Obs.10 Upload telemetry and correlation | P1 | Implemented (needs QA) | iOS + Server | URLSessionTaskMetrics capture + iOS/server correlation IDs through mux webhook telemetry | 2026-05-11 |

## Work Items

### P0.1 One Persistent Background Session Identifier

- [x] Replace per-upload UUID session identifiers with one stable identifier.
- [x] Centralize task creation in one shared upload session coordinator.
- [x] Ensure all upload tasks use the shared coordinator.

Touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift

### P0.2 Background Relaunch Lifecycle Handling

- [x] Add app lifecycle capture for handleEventsForBackgroundURLSession.
- [x] Store completion handler and resolve it in urlSessionDidFinishEventsForBackgroundURLSession.
- [x] Trigger queue reconciliation on relaunch events.

Touch points:
- ios/DirectVideoUploader/App/DirectVideoUploaderApp.swift
- ios/DirectVideoUploader/Services/VideoUploadService.swift

### P0.3 Persist Queue State and Reconcile

- [x] Persist mapping localUploadId -> assetId -> fileURL -> remoteUploadURL -> taskIdentifier.
- [x] Rehydrate and reconcile persisted running tasks against URLSession.getAllTasks.
- [x] Keep queue persistence independent from chat bubble presentation state.

Touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift
- ios/DirectVideoUploader/Services/ChatViewModel.swift

### P0.4 Improve Retry Policy

- [x] Add retry policy by error class:
  - transient network: exponential backoff with jitter,
  - auth/expired URL: refresh and resume safely,
  - validation/permanent: fail fast.
- [x] Cap retries per upload unit and report actionable user state.
- [x] Prevent duplicate clip creation during retries.

Touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift
- ios/DirectVideoUploader/Utilities/RetryHelper.swift

### P1.5 Adaptive Concurrency

- [ ] Dynamic queue policy:
  - Wi-Fi + charging: 2,
  - cellular or Low Power Mode: 1.
- [ ] Manual debug override for diagnostics.

Touch points:
- ios/DirectVideoUploader/Services/VideoBatchUploadCoordinator.swift
- ios/DirectVideoUploader/Services/ChatViewModel.swift

### P1.6 URLSession Network Policy Tuning

- [ ] Set allowsExpensiveNetworkAccess.
- [ ] Set allowsConstrainedNetworkAccess.
- [ ] Set allowsCellularAccess.
- [ ] Set httpMaximumConnectionsPerHost (start at 2).
- [ ] Add policy mode split: user initiated vs deferred backlog.

Touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift

### P1.7 Task Scheduling Hints

- [ ] Set task.priority by urgency.
- [ ] Set countOfBytesClientExpectsToSend.
- [ ] Validate timeout settings for large clips.

Touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift

### P2.8 Transport Strategy

- [x] A) Keep custom URLSession PUT path.
- [ ] B) Mux iOS Upload SDK pilot.

Decision:
- B is intentionally N/A unless product direction changes.

### P2.9 Input Standardization

- [ ] Define default newsroom input profile.
- [ ] Align QA scenarios and metadata reporting.

Touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift
- server/src/routes/mux-webhooks.js

### Obs.10 Upload Telemetry

- [x] Capture URLSessionTaskMetrics per upload.
- [x] Log queue wait, transfer duration, retry count, and final status.
- [x] Correlate with server events (upload created, asset_created, asset.ready).

Touch points:
- ios/DirectVideoUploader/Services/VideoUploadService.swift
- server/src/routes/mux-webhooks.js

## QA Matrix

### Reliability Runs

- [ ] Start upload, lock device, wait, unlock.
- [ ] Start upload, background app for 5+ minutes.
- [ ] Start upload, drop network (Wi-Fi to cellular).
- [ ] Start upload, terminate app (not force quit), relaunch and reconcile.
- [ ] Start 5-10 clip batch and verify ordering, retries, and no duplicates.

### Performance Runs

- [ ] Compare 500MB upload on Wi-Fi vs cellular.
- [ ] Compare throughput at concurrency 1 vs 2.
- [ ] Compare readiness time for 4K vs 1080p source.

## Definition of Done

- [ ] Uploads continue reliably across background/suspension scenarios.
- [ ] Queue mapping survives relaunch and reconciles correctly.
- [ ] Retry path does not create duplicate clips/assets.
- [ ] Field success rate and completion time show measurable improvement.
- [ ] Team can diagnose regressions with upload telemetry.

## Rollout

- [ ] Stage 1: internal QA build behind feature flag.
- [ ] Stage 2: pilot users in one org/team.
- [ ] Stage 3: full rollout after 48 hours stable telemetry.
