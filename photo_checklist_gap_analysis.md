# Photo Checklist — Gap Analysis vs. Current Codebase

> Audit date: May 15, 2026  
> Compared: [CAMERA_LIBRARY_MULTICLIP_PHOTO_CHECKLIST.md](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/CAMERA_LIBRARY_MULTICLIP_PHOTO_CHECKLIST.md) + [PHOTO_UPLOAD_ARCHITECTURE.md](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/PHOTO_UPLOAD_ARCHITECTURE.md) against the live codebase

---

## Executive Summary

**Nothing from the photo checklist has been implemented.** All 8 steps remain at zero. The checklist was written May 9 as a "draft for planning and dependency review" and the codebase has not started any photo-specific work since then.

However, the **video side** has matured significantly since the plan was written, and that changes how several steps should be approached. The batch upload infrastructure is now far more sophisticated than the checklist assumed, which means some steps can be simplified by reusing existing primitives, while others need plan updates to avoid duplicating architecture that already exists in a more general form.

---

## Step-by-Step Status

### Step 1 — Photo Domain Models (iOS)

| Planned File | Exists? | Notes |
|---|---|---|
| `Models/PhotoProject.swift` | ❌ | Not created |
| `Models/PhotoAsset.swift` | ❌ | Not created |
| `Models/PhotoSidecar.swift` | ❌ | Not created |
| `Models/PhotoBatch.swift` | ❌ | Not created |

> [!IMPORTANT]
> **Plan update needed:** The plan calls for `PhotoBatch.swift` but the video side now has a mature `VideoBatch` / `VideoBatchItem` / `VideoBatchContext` / `VideoBatchEnums` model family. The question is whether photo batches should share a generic `MediaBatch` type or remain a parallel set of photo-specific models. Given the architecture doc's "project-first" flow (which is conceptually different from video's "select-then-batch" flow), separate models are likely correct — but the plan should explicitly call out which fields to share vs. diverge.

---

### Step 2 — Replace Photos Placeholder with Project-First Flow

| Planned File | Exists? | Notes |
|---|---|---|
| `Views/Photos/PhotosView.swift` | ✅ Exists — **still a placeholder** | "Coming Soon" screen with zero functionality ([PhotosView.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Photos/PhotosView.swift)) |
| `Views/Photos/PhotoProjectListView.swift` | ❌ | Not created |
| `Views/Photos/PhotoProjectDetailView.swift` | ❌ | Not created |
| `Views/Photos/PhotoGridCell.swift` | ❌ | Not created |

> [!NOTE]
> The architecture doc (§5.1) envisions a **project-first** UX: name project → pick photos → metadata → upload. This is a fundamentally different interaction model from the video batch flow (which is chat-initiated). The checklist should clarify where in the tab bar this lives and whether it integrates with the existing chat UI at all.

---

### Step 3 — Photo Picker + Indexing

| Planned File | Exists? | Notes |
|---|---|---|
| `Views/Photos/PhotoPickerView.swift` | ❌ | Not created |
| `Services/PhotoLibraryIndexer.swift` | ❌ | Not created |

> [!TIP]
> **Reuse opportunity:** The video side now has a mature `PHAssetIdentifierStore` in [Services/Persistence/](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/Persistence/PHAssetIdentifierStore.swift) for tracking which library assets have been processed. Photo picker dedup should leverage this pattern rather than building a parallel store.

---

### Step 4 — Grouped Context Form for Photos

| Planned File | Exists? | Notes |
|---|---|---|
| `Views/Photos/PhotoContextFormView.swift` | ❌ | Not created |

> [!IMPORTANT]
> **Plan gap:** The video batch infrastructure has evolved significantly since this plan. The video path now has:
> - `BatchStateTransitionService` — sophisticated state machine for grouped forms
> - `GroupedBatchFormSubmissionState` / `GroupedBatchFormPromptState` structs
> - `PendingForm` persistence
> 
> The photo form could reuse the existing [ContextFormView.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Views/Form/ContextFormView.swift) directly (it's already 17KB and handles slug, type, description, priority). The checklist says "reuse concepts from ContextFormView" but should be updated to say **"reuse ContextFormView itself"** with a photo-specific field set (add caption, keywords, copyright per the architecture doc's `PhotoSidecar` spec).

---

### Step 5 — Photo Upload Queue

| Planned File | Exists? | Notes |
|---|---|---|
| `Services/PhotoUploadService.swift` | ❌ | Not created |
| `Services/PhotoBatchQueueStore.swift` | ❌ | Not created |

> [!WARNING]
> **Biggest plan gap.** The video upload infrastructure has evolved dramatically since the plan was written. What exists now:
> 
> | Component | File | What it does |
> |---|---|---|
> | Transport abstraction | [IngestTransport.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/Upload/Transports/IngestTransport.swift) | Vendor-neutral upload protocol |
> | Transport registry | [IngestTransportRegistry.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/Upload/Transports/IngestTransportRegistry.swift) | Pluggable transport dispatch |
> | Mux transport | [MuxStreamingTransport.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/Upload/Transports/MuxStreamingTransport.swift) | Concrete Mux implementation |
> | Archive transport | [ArchiveIngestTransport.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/Upload/Transports/ArchiveIngestTransport.swift) | Stub for archive uploads |
> | Batch execution (12 services) | [Services/Upload/Batch/](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/Upload/Batch) | Full batch lifecycle |
> | Queue persistence | [UploadQueueStore.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/Persistence/UploadQueueStore.swift) | Persist/restore/reconcile |
> | Background sessions | `BackgroundUploadSessionCoordinator` | URLSession background uploads |
> | Retry/telemetry | `UploadRetryPolicy`, `UploadTelemetryRecorder` | Exp. backoff, rate-limit handling |
> 
> **The plan should NOT duplicate this infrastructure.** Instead, photos should:
> 1. Create a new `IngestTransportKind` (e.g. `.photoMultipart`) 
> 2. Create a `PhotoMultipartTransport` conforming to `IngestTransport`
> 3. Reuse `BackgroundUploadSessionCoordinator` and `UploadQueueStore` directly
> 
> However, there's a design tension: `IngestTransport.upload()` currently takes a `VideoMetadata` parameter, which would need to be generalized to a `MediaMetadata` protocol to support photos.

---

### Step 6 — Server Photo Endpoints

| Planned File | Exists? | Notes |
|---|---|---|
| `server/src/routes/photos.js` | ❌ | Not created |
| `server/src/lib/photoValidation.js` | ❌ | Not created |
| `server/src/lib/photoStorage.js` | ❌ | Not created |

**No server-side photo code exists at all.** The server routes are exclusively video-oriented:
- `assets.js` — video asset CRUD + Mux direct upload
- `clips.js` — video clip management
- `mux-webhooks.js` — Mux webhook processing
- `admin.js` — video admin panel

> [!NOTE]
> The architecture doc (§7.2) specs 10+ endpoints. The checklist's Step 6 is an MVP subset of 6 endpoints. This is reasonable for a first pass but the plan should clarify which architecture doc endpoints are deferred vs. dropped.

---

### Step 7 — Processing Job for Derivatives

| Planned File | Exists? | Notes |
|---|---|---|
| `server/src/jobs/process-photo.js` | ❌ | Not created |

Existing server jobs are video-only: `mux-sync.js` and `upload-cleanup.js`. No `exiftool` or Sharp dependencies are present in the server `package.json`.

---

### Step 8 — Prisma Schema for Photo Models

| Planned Change | Done? | Notes |
|---|---|---|
| `PhotoProject` model | ❌ | Not in schema |
| `Photo` model | ❌ | Not in schema |
| Status/delivery enums | ❌ | Not in schema |

Current Prisma models: `Organization`, `User`, `Asset`, `Clip`, `FormResponse`, `ChatMessage`, `ErrorLog`. **Zero photo models.**

---

## What the Video Side Built That Changes the Plan

Since this checklist was written (May 9), the video batch infrastructure has grown into a substantial, well-factored system. Here's what the plan didn't anticipate:

### 1. Transport Abstraction Layer
The `IngestTransport` protocol + registry pattern was designed to be vendor-neutral. Photos should plug into this rather than building a parallel upload stack. **But the protocol currently hardcodes `VideoMetadata`** — that needs to become generic.

### 2. 12-Service Batch Architecture
The `Services/Upload/Batch/` directory now has 12 focused services covering the full batch lifecycle:

```
BatchAssetFlowService          BatchItemExecutionService
BatchAssetPresentationService  BatchItemLifecycleService
BatchClipDisplayService        BatchItemProcessingService
BatchCompletionMessageService  BatchItemStateService
BatchRunExecutionService       BatchStateTransitionService
PendingBatchRestoreService     PendingBatchStore
```

These are tightly coupled to `VideoBatchItem` / `SelectedVideo` types. Making them media-generic would be a large refactor. **The pragmatic path is to create a parallel `PhotoBatch` set that follows the same patterns** but doesn't try to share code at the service layer.

### 3. Persistence Layer
`UploadQueueStore`, `PendingBatchStore`, `PendingForm`, and `PHAssetIdentifierStore` are all functional and battle-tested. Photos should use the same persistence patterns but may need separate stores (photo upload tasks shouldn't intermingle with video upload tasks in the same queue).

---

## Recommended Plan Updates

| # | Update | Why |
|---|---|---|
| 1 | **Add Step 0: Generalize `IngestTransport`** | Change `VideoMetadata` → `MediaMetadata` protocol so photos can use the existing transport layer |
| 2 | **Step 5: Don't duplicate upload infra** | Reuse `BackgroundUploadSessionCoordinator`, `UploadRetryPolicy`, `UploadTelemetryRecorder`. Create a `PhotoMultipartTransport` conforming to `IngestTransport` |
| 3 | **Step 4: Reuse `ContextFormView` directly** | It's already 17KB with sanitization, validation, and persistence. Add photo-specific fields (caption, keywords, copyright) rather than building a new form |
| 4 | **Step 1: Drop `PhotoBatch.swift`** | Follow the video pattern: `PhotoBatch` + `PhotoBatchItem` + `PhotoBatchContext` + `PhotoBatchEnums` as 4 separate model files |
| 5 | **Add Step 8.5: Server dependencies** | `exiftool-vendored` and `sharp` npm packages need to be added; deployment infra (Render) needs `exiftool` binary |
| 6 | **Step 6: Clarify transport mode** | Architecture doc says per-photo multipart upload (no Mux). The server endpoint is a standard file upload, not a Mux direct upload flow. The checklist should explicitly note this difference |
| 7 | **Ordering: Move Step 8 (Prisma) before Step 6** | Schema must exist before routes can use it |

---

## Summary: What's Done vs. What's Left

| Area | Status |
|---|---|
| iOS photo models | ❌ **0% — nothing exists** |
| iOS photo UI | ❌ **0% — placeholder only** |
| iOS photo picker | ❌ **0% — not started** |
| iOS photo form | ❌ **0% — not started** (but reusable form exists) |
| iOS photo upload service | ❌ **0% — not started** (but reusable infra exists) |
| Server photo routes | ❌ **0% — not started** |
| Server photo processing | ❌ **0% — not started** |
| Prisma photo schema | ❌ **0% — not started** |
| **Reusable video infra that photos can leverage** | ✅ **Substantial** — transport layer, batch patterns, persistence, retry, telemetry, background sessions, form UI |

The good news: the video side has built the hard parts (background upload coordination, retry policies, queue persistence, transport abstraction). The photo pipeline's biggest lift is the **server side** (routes, exiftool integration, storage adapter, Prisma models) and the **photo-specific iOS UI** (project flow, photo picker, metadata editor). The upload plumbing itself can largely be reused.
