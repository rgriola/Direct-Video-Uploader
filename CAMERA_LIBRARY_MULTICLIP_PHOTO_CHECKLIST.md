# Camera Library Multiclip Photos — Implementation Checklist
- Last updated: May 9, 2026 - 11:01pm - GPT-5.3-Codex

Status: Draft for planning and dependency review

## Objective

Apply the same proven pattern from multiclip video to photos:

- Queue-based multiclip processing
- One grouped context form
- Org-scoped server processing and delivery semantics

## Current Starting Point

Existing photo placeholder:
- ios/DirectVideoUploader/Views/Photos/PhotosView.swift

No production photo routes/services yet:
- server/src/routes/photos.js (not present)
- server/src/lib/photoStorage.js (not present)
- server/src/lib/photoValidation.js (not present)

## Minimal Build Sequence

### Step 1 — Add Photo Domain Models (iOS)

Create files:
- ios/DirectVideoUploader/Models/PhotoProject.swift
- ios/DirectVideoUploader/Models/PhotoAsset.swift
- ios/DirectVideoUploader/Models/PhotoSidecar.swift
- ios/DirectVideoUploader/Models/PhotoBatch.swift

Fields to include:
- projectId, orgCode, title, destination
- photo items with status/progress/error
- sidecar metadata (EXIF/IPTC editable fields)

Acceptance:
- Models compile and can serialize for local persistence.

### Step 2 — Replace Photos Placeholder with Project-First Flow

Modify:
- ios/DirectVideoUploader/Views/Photos/PhotosView.swift

Create:
- ios/DirectVideoUploader/Views/Photos/PhotoProjectListView.swift
- ios/DirectVideoUploader/Views/Photos/PhotoProjectDetailView.swift
- ios/DirectVideoUploader/Views/Photos/PhotoGridCell.swift

Acceptance:
- User can create project, pick many photos, and view selected grid.

### Step 3 — Build Photo Picker + Indexing

Create:
- ios/DirectVideoUploader/Views/Photos/PhotoPickerView.swift
- ios/DirectVideoUploader/Services/PhotoLibraryIndexer.swift

Requirements:
- Multiselect support
- Fast thumbnail loading
- Select All + per-item selection
- Live totals (count + bytes)

Acceptance:
- 500+ photo sets remain responsive.

### Step 4 — Grouped Context Form for Photos

Create:
- ios/DirectVideoUploader/Views/Photos/PhotoContextFormView.swift

Reuse concepts from:
- ios/DirectVideoUploader/Views/Form/ContextFormView.swift

Flow:
- One form per selected batch/project
- Optional per-photo override deferred to phase 2

Acceptance:
- One submit applies context to all selected photos.

### Step 5 — Add Photo Upload Queue

Create:
- ios/DirectVideoUploader/Services/PhotoUploadService.swift
- ios/DirectVideoUploader/Services/PhotoBatchQueueStore.swift

Responsibilities:
- Bounded concurrency
- Retry failed only
- Persist queue state
- Keep originals untouched

Acceptance:
- App relaunch restores in-flight or partial batches.

### Step 6 — Add Photo Server Endpoints (MVP)

Create:
- server/src/routes/photos.js
- server/src/lib/photoValidation.js
- server/src/lib/photoStorage.js

Register route in:
- server/src/index.js

MVP endpoints:
- POST /api/photos/projects
- GET /api/photos/projects
- GET /api/photos/projects/:id
- POST /api/photos/upload
- PATCH /api/photos/:id/sidecar
- POST /api/photos/projects/:id/complete

Acceptance:
- End-to-end iOS-to-server photo project upload works.

### Step 7 — Add Processing Job for Derivatives

Create:
- server/src/jobs/process-photo.js

Behavior:
- RAW: write .xmp sidecar
- JPEG/TIFF/HEIC: tagged derivative
- thumb generation
- status updates and notification hooks

Acceptance:
- Processed outputs are Lightroom-ready and originals remain unchanged.

### Step 8 — Add Prisma Schema for Photo Project + Photo Item

Modify:
- server/prisma/schema.prisma

Add:
- PhotoProject model
- Photo model
- status and delivery enums

Acceptance:
- Prisma client generates and API queries compile.

## iOS Method Mapping (Concrete)

Reuse/parallel from video implementation:

- Pattern source: ios/DirectVideoUploader/Services/ChatViewModel.swift
  - createAsset(fileName:fileURL:)
  - uploadVideo(assetId:fileURL:metadata:)
  - submitForm(assetId:formData:)
- New photo equivalents to add in PhotoUploadService:
  - createPhotoProject(context:)
  - uploadPhotoItem(projectId:item:sidecar:)
  - submitPhotoProjectContext(projectId:formData:)
  - completePhotoProject(projectId:)

## Test Checklist

1. Select many photos from library and create one project.
2. Apply one context form to all selected photos.
3. Upload completes with per-photo success/failure tracking.
4. RAW outputs include sidecars; JPEG outputs include tagged derivatives.
5. Relaunch app mid-upload and resume queue state.

## Executive Summary

- The multiclip queue + grouped form pattern is reusable across video and photo.
- Photo pipeline needs new server routes and schema, but iOS interaction model can be shared.
- This lowers risk by standardizing one user mental model across media types.
