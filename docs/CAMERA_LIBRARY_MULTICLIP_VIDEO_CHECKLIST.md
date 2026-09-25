# Camera Library Multiclip Video — Implementation Checklist
- Last updated: May 9, 2026 - 11:01pm - GPT-5.3-Codex

Status: Draft for execution tomorrow

## Objective

Ship multiclip video uploads from iOS Photo Library first, using:

- Queue-based upload orchestration
- One grouped context form
- Existing server endpoints (no backend rewrite)

## Existing Reusable Path (Already Working)

Current single-clip flow and exact insertion points:

- iOS picker and confirm callback: ios/DirectVideoUploader/Views/Chat/VideoLibraryView.swift
- Sheet wiring to ViewModel: ios/DirectVideoUploader/Views/Chat/ChatView.swift
- Asset create + upload + form flow: ios/DirectVideoUploader/Services/ChatViewModel.swift
  - createAsset(fileName:fileURL:)
  - uploadVideo(assetId:fileURL:metadata:)
  - submitForm(assetId:formData:)
  - ws.onFormRequest handler in setupWebSocketHandlers()
- Upload transport: ios/DirectVideoUploader/Services/VideoUploadService.swift
  - uploadViaMux(assetId:fileURL:token:metadata:)
- Existing API endpoints:
  - POST /api/assets
  - POST /api/assets/:id/mux-upload
  - POST /api/assets/:id/form

## Minimal Change Sequence (Video Only)

### Step 1 — Add Batch Models (iOS)

Create file:
- ios/DirectVideoUploader/Models/VideoBatch.swift

Add:
- VideoBatchContext (slug, type, description, priority,destination)
- VideoBatchItem (localId, fileName, status, progress, assetId, error, org)
- VideoBatchState (queued, indexing, uploading, paused, complete, partialFailed)

Acceptance:
- Models compile and support serialization to disk. 

### Step 2 — Add Batch Persistence (iOS)

Create file:
- ios/DirectVideoUploader/Services/PendingBatchStore.swift

Add methods:
- save(batch)
- load(batchId)
- loadLatest()
- clear(batchId)

Acceptance:
- Batch state survives app relaunch. 

### Step 3 — Upgrade VideoLibraryView to Multiselect 

Modify:
- ios/DirectVideoUploader/Views/Chat/VideoLibraryView.swift

Changes:
- Keep selectedItems as array, remove single-item assumptions.
- Update callback signature:
  - from onConfirm: (URL, String, VideoMetadata, String?) -> Void
  - to onConfirmBatch: ([SelectedVideo]) -> Void
- Add lightweight SelectedVideo struct with:
  - fileURL
  - fileName
  - metadata
  - phAssetIdentifier

Methods to update:
- handleConfirm()
- handleSelectionChange(_:)
- footerBar totals display (count + estimated total bytes)

Acceptance:
- User can select many camera-library videos and confirm one batch.

### Step 4 — Wire Multiclip Callback in ChatView

Modify:
- ios/DirectVideoUploader/Views/Chat/ChatView.swift

Changes:
- Replace single-clip onConfirm callback usage with batch callback.
- Call new ViewModel entrypoint:
  - stageVideoBatch(selectedVideos:)

Acceptance:
- Batch preview appears and no regressions for existing chat screen.

### Step 5 — Add Batch State to ChatViewModel

Modify:
- ios/DirectVideoUploader/Services/ChatViewModel.swift

Add state:
- currentBatchId
- batchItems
- batchContext
- batchProgress
- isBatchUploading
- suppressPerAssetFormSheet (bool gate)

Add methods:
- stageVideoBatch(selectedVideos:)
- confirmBatchUpload()
- uploadBatchItemsSequentialOrBoundedConcurrency()
- applyGroupedFormToAsset(assetId:)
- retryFailedBatchItems()

Keep and reuse:
- createAsset(fileName:fileURL:)
- uploadVideo(assetId:fileURL:metadata:)
- submitForm(assetId:formData:)

Acceptance:
- ViewModel can run batch upload lifecycle without breaking single-upload path.

### Step 6 — Grouped Context Form (Single Entry, Multi-Apply)

Modify:
- ios/DirectVideoUploader/Services/ChatViewModel.swift
- ios/DirectVideoUploader/Views/Form/ContextFormView.swift

Flow:
- Show form once at batch start.
- Persist formData as batchContext.
- For each created asset in batch, call submitForm(assetId:formData:) with same payload.

Important guard:
- In ws.onFormRequest handler, skip repeated form sheet presentation when suppressPerAssetFormSheet is true.

Acceptance:
- User fills one form and it applies to all clips in the batch.

### Step 7 — Queue Coordinator for Uploads

Create file:
- ios/DirectVideoUploader/Services/VideoBatchUploadCoordinator.swift

Responsibilities:
- Bounded concurrency (2-3)
- Per-item state transitions
- Retry policy (failed only)
- Calls into existing ChatViewModel methods

Acceptance:
- Partial failures do not cancel successful uploads.

### Step 8 — Progress UI for Batch and Per-File

Modify:
- ios/DirectVideoUploader/Views/Chat/VideoBubble.swift
- ios/DirectVideoUploader/Views/Chat/MessageBubble.swift

Add:
- Batch-level progress row
- Per-file status summary
- Retry failed action

Acceptance:
- User sees clear queue/upload/complete/error states per clip.

### Step 9 — Server Compatibility Validation (No New Endpoints Required)

Confirm against:
- server/src/routes/assets.js

Checks:
- /api/assets supports many calls per session.
- /api/assets/:id/mux-upload handles repeated requests safely.
- /api/assets/:id/form can be called repeatedly with grouped context payload.

Acceptance:
- Multiclip flow works against current API contract.

## Test Checklist

1. Select 1 clip, upload still works as before.
2. Select 5 clips, one grouped form, all clips upload.
3. Kill app mid-batch, relaunch, batch state restores.
4. One clip fails, others complete, retry failed succeeds.
5. Group form fields are present on all uploaded assets.

## Executive Summary (One Slide Version)

- We can deliver multiclip video without backend rewrite.
- We reuse existing upload endpoints and add an iOS queue + grouped form layer.
- This creates the same pattern we can mirror for photo uploads next.
