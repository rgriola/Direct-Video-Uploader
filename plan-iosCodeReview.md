# iOS Code Review — `ios/DirectVideoUploader`

Scope: Swift structure & best practices, plus a forward-looking read on whether the upload pipeline is reusable for new media types.

## 1. Project layout & “no import / few directories” feel

What you’re seeing is normal for a Swift app target, but the shape inside `Services/` is currently working against you.

- Swift has no `import` of sibling files in the same module — every file in the app target is implicitly visible. That’s not a bug; it’s the language. The cost is that **directory structure is the only signal of architecture**, and right now `Services/` is one flat folder with ~50 files spanning auth, WebSocket transport, batch orchestration, transcription, persistence, and recovery.
- The view side is well-organized (`Views/Chat`, `Views/Auth`, `Views/Form`, etc.). The service side is not, and that asymmetry is what feels “odd.”
- `Models/` is also mixed-purpose: domain models (`Asset.swift`, `ChatMessage.swift`, `VideoBatch.swift`) sit next to environment config (`ServerConfig.swift`), which is really infrastructure.

Recommended grouping (folder-only, no module split needed):

- `Services/Networking/` — `AuthService`, `WebSocketService`, `ServerErrorReporter`, plus a new `APIClient` (see §3).
- `Services/Upload/` — `VideoUploadService`, `BatchUploadTransportService`, `VideoBatchUploadCoordinator`, retry/queue files.
- `Services/Upload/Batch/` — every `Batch*Service`, `BatchClipDisplayService`, `PendingBatchRestoreService`.
- `Services/Workflow/` — `WorkflowStageTracker`, `WorkflowReconcile*`, `ReadyWorkflowStateService`, `ChatOwnershipRouter`.
- `Services/Chat/` — `ChatViewModel`, `MessagePolicyCoordinator`, `MessageCatalog`, `WebSocket*EventService`.
- `Services/Recovery/` — `UploadQueueRecoveryService`, `UploadQueueRehydrate*`, `PendingFormRecoveryService`.
- `Services/Permissions/` — `PermissionManager`, `KeychainHelper`, `AppearanceService`.
- `Infrastructure/` (or move into `Services/Networking/`) — `ServerConfig`, `UserDefaultsKeys`, `PHAssetIdentifierStore`, `PendingForm`.

Because XcodeGen sources the whole `DirectVideoUploader/` tree, you can do this purely with Finder/Xcode moves + `xcodegen generate`; no code changes required.

## 2. Architecture observations on `ChatViewModel.swift`

The recent refactor extracted a lot of services, which is good. But the file is still ~2,400 lines and shows clear signs of being the seam between many subsystems rather than a focused VM.

- **God-object tendency.** `ChatViewModel` conforms to 6 WS runtime protocols and exposes ~40 `ws*` shim methods. That’s a code smell that the protocols are too granular and `ChatViewModel` is being used as a “service bus.”
- **Dependency injection is ad-hoc.** Every service is `private let foo = FooService()` constructed in-place. This blocks unit testing, makes mocking impossible, and silently couples lifetimes. Move to constructor injection of a small `ChatServices` aggregate, defaulted for production.
- **`Dependencies` struct pattern is overused.** `BatchItemProcessingService.Dependencies`, `WorkflowReconcileExecutionService.Dependencies`, etc. are essentially closure bags built inline by `ChatViewModel`. They’re a workaround for not having proper DI. A single protocol per service (e.g. `BatchItemProcessingHost`) that `ChatViewModel` adopts would be more idiomatic Swift and remove the `make…Dependencies()` boilerplate.
- **State ownership is leaky.** Many helpers take `inout batchItems`, `inout batchClipDisplayByAssetId`, `inout batchProgress` (see `BatchItemStateService.swift`). That’s effectively passing `ChatViewModel`’s private state across a service boundary. Either:
  - keep state inside the VM and have services return pure values (you already do this in `BatchStateTransitionService` — that’s the right pattern), or
  - move the state into the service entirely (e.g. a `BatchSession` actor that owns `batchItems`).
- **Mixed naming conventions.** “Service,” “Coordinator,” “Tracker,” “Router,” “Reporter,” “Manager” are used somewhat interchangeably. Pick a small vocabulary (`Service` for stateless logic, `Store` for persistence, `Coordinator` for multi-step flows, `Client` for transport) and apply consistently.
- **Error handling.** Lots of `try?` and `print(…)` for failures (see `BatchUploadTransportService.swift` and `VideoUploadService.swift`). Standardize a typed error per subsystem (`UploadError`, `WebSocketError`) and route logs through one logger (e.g. `os.Logger` with subsystem/category) instead of `print`.
- **`@MainActor` blanket.** Almost every service is `@MainActor`. That’s safe but forces all work onto main. Pure-logic services (`BatchStateTransitionService`, `UploadQueueRecoveryService`, `WorkflowReconcilePlanService`, `WorkflowStageTracker`) should be plain actors or `Sendable` structs so heavy work doesn’t hop the main actor.

## 3. Networking layer — biggest reuse risk

This is the area most relevant to your concern about reusing the pipeline for new media. Today the HTTP layer is duplicated and Mux/video-specific.

- Each service builds its own `URLRequest`, encodes a body, calls `URLSession.shared.data(for:)`, status-checks, and decodes. See `AssetDetailService.swift`, `BatchUploadTransportService.swift`, `FormSubmissionService.swift`, `GroupedFormService.swift`, `TranscriptSubmissionService.swift`, `ServerErrorReporter.swift`. That’s 6+ near-identical patterns.
- No central `APIClient` means: no shared auth retry, no shared 401 handling, no shared decoding strategy, no test seam, and no consistent timeout/cache policy.
- `BatchUploadTransportService` instantiates a fresh `VideoUploadService()` per call and **polls `uploader.uploadProgress` in a `Task` loop** rather than using a progress callback or `AsyncStream`. That works but it’s fragile and not how SDK-style code should look.
- `VideoUploadService` mixes Mux protocol (tus-style direct upload), retry policy, classifier, and persistence model definitions in one ~600-line file. For reuse this should split into:
  - `UploadTransport` protocol (PUT/PATCH bytes, report progress).
  - `MuxDirectUploadTransport` implementation.
  - `UploadRetryPolicy` (already separated — good).
  - `UploadQueueStore` persistence.

What “good” looks like for the next media type (photos, audio, screen recordings, SD-card offload):

1. `APIClient` (one file): `func send<Req: Encodable, Res: Decodable>(_ endpoint: Endpoint<Req, Res>) async throws -> Res`. Owns auth header, retry, decoding, error mapping.
2. `MediaUploadCoordinator<M: UploadableMedia>` protocol: stage → createAsset → upload bytes → applyForm → notify. Today’s `BatchItemProcessingService` is almost this, just specialized to video.
3. `UploadableMedia` protocol with associated `Metadata`, `Thumbnail`, `Transport`. A new media type implements one struct plus a transport.
4. Move per-domain services (chat bubbles, completion messages) **out** of the upload coordinator so the coordinator is media-agnostic.

Right now too many “upload-pipeline” classes know about `ChatMessage`, `BatchClipDisplayState`, `VideoBubblePhase`, etc. Those are presentation concerns and should be wired in by the caller, not baked into the upload services.

## 4. Models / domain layer

- `VideoBatch.swift` mixes enums, structs, and persistence in one file (~200+ lines). Split into `VideoBatch.swift`, `VideoBatchItem.swift`, `SelectedVideo.swift`, `VideoMetadata.swift`. That makes them trivially reusable for `PhotoBatch`, `AudioBatch`, etc.
- `PHAssetIdentifierStore` and `PendingForm` are defined inside `VideoUploadService.swift`. They should be top-level files in `Services/Persistence/` or `Infrastructure/`. Burying persistence types inside an unrelated service is a major reuse blocker.
- Domain enums (`WorkflowStage`, `VideoBatchState`, `VideoBatchItemStatus`) live in services. Move to `Models/` so non-service code can reference them without importing service intent.

## 5. Concurrency & Swift 6

- Good: `@Observable`, `@MainActor`, `Task { @MainActor in … }` — modern Swift 6 patterns.
- Risk: closures capturing `self` strongly inside `make…Dependencies()`. Most use `self.foo` directly without `[weak self]`. Inside a `@MainActor` `final class` this is usually fine, but the closures are stored on services that outlive single calls — verify there’s no retain cycle (especially in `make…ProcessingDependencies` where service-held closures all `self.…`).
- The progress polling `Task` in `BatchUploadTransportService.uploadViaMux` should be replaced by `AsyncStream<Double>` exposed by `VideoUploadService`. Polling a published property from a task is an anti-pattern in Swift 6.
- `withRetry` in `RetryHelper.swift` is `@MainActor` — that forces all retried work onto main. Make it generic over isolation (`isolated (any Actor)?`) or just non-isolated.

## 6. Testing

- Tests in `ios/tests` compile via raw `swiftc`, not XCTest. They re-declare stub structs (`VideoMetadata`, `BatchClipDisplayState`) per file. That works for now but won’t scale and gives you no Xcode test runner integration.
- Add a real test target (`xcodegen` supports it via a second `targets:` entry). Once `APIClient` exists, you can mock it with a single protocol and test every service for free.

## 7. Small but worth fixing

- `print` statements with emoji are everywhere. Replace with `Logger(subsystem: "com.directvideo", category: "upload")` — searchable, filterable, redactable.
- `as? NSError` + `URLError.Code(rawValue: nsError.code)` in `ConnectivityIssueTracker.swift` duplicates the `URLError` branch just below. The two switches can be one helper.
- `BatchAssetPresentationService` and `BatchAssetFlowService` overlap in name/intent. Consolidate.
- `Models/ServerConfig.swift` has 5-level conditional URL resolution. Consider a single `ServerEnvironment` enum value resolved once at launch.

---

## Priorities (in order)

1. **Introduce a shared `APIClient`** and migrate all `URLSession.shared.data(for:)` callers. Single biggest reuse win.
2. **Reorganize `Services/` into subfolders** (Networking, Upload, Workflow, Chat, Recovery, Persistence). Pure XcodeGen + folder move.
3. **Extract a media-agnostic `IngestTransport` protocol with built-in streaming/archive split.** Two concrete transports from day one: `StreamingIngestTransport` (today: Mux direct upload via tus) and `ArchiveIngestTransport` (future: full-res master to S3/B2/R2 or server-resumable). Server returns a transport hint (`tus`, `s3-multipart`, `put`) plus a signed URL; iOS dispatches on the hint — no vendor SDKs on device, no `Mux` token in client code paths. Default fan-out model: phone uploads master once to archive, server pulls into Mux for streaming. WebSocket emits both `stream:ready` and `archive:ready`. Wraps the original `MediaUploadCoordinator<M: UploadableMedia>` idea so a new media type implements one `UploadableMedia` struct + reuses both transports.

3.5. **Vendor-name cleanup pass.** Rename client-visible `mux:*` surfaces to vendor-neutral names: `onMuxReady` → `onStreamReady`, `MessageType.muxReady` → `.streamReady`, `IOS_MUX_READY_*` codes → `IOS_STREAM_READY_*`. Server emits both old and new event names during cutover, then drops `mux:*`. Cheap to do alongside Priority 3, expensive later. 4. **Lift `PHAssetIdentifierStore` / `PendingForm` / `UploadQueueStore`** into a `Persistence/` folder, away from `VideoUploadService`. 5. **Replace closure-bag `Dependencies` structs with host protocols** that `ChatViewModel` adopts; consolidate the 6 `WebSocket*Runtime` protocols into 1–2. 6. **Replace `print` with `os.Logger`** and add a real XCTest target. 7. **Split large model files** (`VideoBatch.swift`) and move enums into `Models/`.

The codebase is in solid shape for a fast-moving product — recent refactors are clearly headed in the right direction. The flat `Services/` directory and the duplicated URLSession plumbing are the two structural issues that will hurt most as you add new media pipelines.
