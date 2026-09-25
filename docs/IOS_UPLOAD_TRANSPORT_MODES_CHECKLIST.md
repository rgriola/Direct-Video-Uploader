# iOS Upload Transport Modes — Foreground Stream vs Chunk Resume
- Last updated: May 9, 2026 - 11:01pm - GPT-5.3-Codex

Status: Decision and implementation checklist

## Why This Document Exists

We are deciding between two transport modes for large media uploads:

1. Direct foreground streaming
2. Chunked resumable uploads

Both can coexist. This checklist defines where each mode fits and exactly what to change.

## Mode A — Direct Foreground Streaming

### Best fit

- Fastest MVP
- Lowest backend complexity
- Works well when user can keep app active

### Current baseline already present

- ios/DirectVideoUploader/Services/VideoUploadService.swift
  - uploadViaMux(assetId:fileURL:token:metadata:)
- ios/DirectVideoUploader/Services/ChatViewModel.swift
  - uploadVideo(assetId:fileURL:metadata:)

### Implementation checklist

1. Add batch coordinator on top of existing uploadViaMux.
2. Add bounded concurrency (2-3 parallel files).
3. Add per-file retry without restarting successful uploads.
4. Persist lightweight queue state only.
5. Keep memory pressure low (no large byte buffers).

### Risks

- App termination can interrupt in-flight uploads.
- Long sessions are sensitive to source-handle lifetime and network changes.

## Mode B — Chunked Resumable Uploads

### Best fit

- Large sessions (100GB+)
- Frequent disconnect/reconnect
- True resume requirements

### iOS changes required

Modify:
- ios/DirectVideoUploader/Services/VideoUploadService.swift

Add methods:
- createUploadSession(file:)
- uploadChunk(sessionId:offset:data:)
- queryUploadOffset(sessionId:)
- finalizeUpload(sessionId:)

Create service:
- ios/DirectVideoUploader/Services/ChunkUploadCoordinator.swift

### Server changes required

Create route module:
- server/src/routes/chunk-uploads.js

Endpoints:
- POST /api/uploads/sessions
- PATCH /api/uploads/sessions/:id/chunks
- GET /api/uploads/sessions/:id
- POST /api/uploads/sessions/:id/complete
- DELETE /api/uploads/sessions/:id

Storage + integrity:
- Chunk temp storage with TTL cleanup
- SHA-256 verification per file and optional per chunk
- Idempotent chunk writes by offset

### Risks

- Highest implementation complexity
- Requires robust cleanup and quota controls

## Decision Matrix

| Requirement | Foreground stream | Chunk resume |
|---|---|---|
| Ship quickly | Strong | Medium |
| Resume mid-file after crash | Weak | Strong |
| Backend complexity | Low | High |
| Operational reliability (multi-hour) | Medium | Strong |
| Best first step | Yes | No |

## Recommended Rollout

Phase 1:
- Ship direct foreground streaming with multiclip queue.

Phase 2:
- Add chunk-resume behind a feature flag for large-batch users.

Phase 3:
- Promote chunk-resume to default for SD-card and long-duration workloads.

## Concrete Method Mapping to Existing App

Primary integration points:

- ios/DirectVideoUploader/Services/VideoUploadService.swift
  - existing uploadViaMux(...) remains Mode A path
  - add chunk methods for Mode B path
- ios/DirectVideoUploader/Services/ChatViewModel.swift
  - uploadVideo(...) chooses mode by feature flag or batch profile
- ios/DirectVideoUploader/Models/ServerConfig.swift
  - add chunk session endpoint builders when Mode B starts

## Exit Criteria Before Defaulting to Chunk Mode

1. Resume success rate meets target after forced app kill.
2. 100GB-160GB test runs complete without data corruption.
3. Chunk temp cleanup and TTL enforcement are verified.
4. Observability dashboards expose stuck sessions and retry churn.
