# Fixer Roadmap — iOS Modernization → Web App Expansion

_Drafted: October 19, 2026 · Updated: November 7, 2026_
_Owner: Rod_
_Status: **In progress** — Step 1 verified; Steps 2.1 and 2.3 deployed; Steps 2.2 and 2.4 implemented, deployment pending; Step 2.2 migration pending_

```mermaid
flowchart TD
    A["Step 1: iOS 18.6+ and Swift 6 cleanup"] -->|iOS stable, baseline captured| B["Step 2: Roles, moderation and soft delete (server)"]
    B -->|SUPER_ADMIN / ADMIN / USER enforced on server| C["Step 3: Role-separated web UI and thumbnails"]
    C --> D["Step 4: Original-file storage and store-first upload"]
    D -->|originals on disk| E["Step 5: Expiring download links"]

    subgraph S1["Step 1: iOS"]
    A1["1.1 iOS 18.6 target"] --> A4["1.4 Baseline tests and device capture"]
    A4 --> A2["1.2 Remove concurrency escape hatches"]
    A2 --> A3["1.3 iOS 18 APIs that replace workarounds"]
    end

    subgraph S2["Step 2: Server RBAC"]
    B0["2.0 Baseline migrations"] --> B1["2.1 Roles and Super Admin seed"]
    B1 --> B2["2.2 Pause, flag, remove"]
    B2 --> B3["2.3 requireRole and team scoping"]
    B3 --> B4["2.4 Socket scoping"]
    end

    subgraph S4["Step 4: Storage"]
    D1["4.1 StorageDriver: local folder"] --> D2["4.2 Store-first upload protocol"]
    D2 --> D3["4.3 iOS and desktop uploaders"]
    end
```

---

## Locked Decisions (from Rod, Oct 19)

| Topic | Decision |
| --- | --- |
| Hosting | **Home server is live.** Fastify + Postgres 18 run on the MacBook Air behind a Cloudflare Tunnel (`dev.ms-fixer.com`). Cloud Run / Cloud SQL are no longer the primary target. |
| Super Admin | **Rod Griola** (only one). Promotes/demotes any user, sees all videos, can pause, flag, or remove any video. |
| Team Admin | Manages **only their organization's** videos and members. Can promote and demote other Team Admins in that organization and pause members when moderation is implemented. |
| Users | **Every user gets web access** once their account exists. |
| Shared clip links | Signed-in members of the same organization may view each other's shared clips. Regular list views remain limited to the user's own records. |
| Permanent user deletion | **Super Admin only**, including deletion of associated data. |
| iOS role | **Upload only.** All management (users, moderation, sharing, downloads) happens in the desktop web app. |
| Original video | The native original file is **stored by us**, not just by Mux. Mux is for playback only. **Local folder on the home server for testing**, cloud object storage later. |
| "URL downloads" | Means **expiring download links** to the native original, for a person or a server. It does **not** mean importing videos from external URLs. (Removed from the plan.) |

---

## Current State (Oct 19 audit; iOS baseline updated Nov 6, 2026)

| Area | Finding | Impact on plan |
| --- | --- | --- |
| Home server | Postgres 18 running via `brew services`, loopback-only (`127.0.0.1` / `::1:5432`) ✅ | Matches the Home Server Plan. That doc needs a status update (done separately). |
| iOS language mode | `SWIFT_VERSION = 6.0` already set | Strict concurrency is **already on**. Step 1 is cleanup, not a migration. |
| iOS observation | No `ObservableObject` / `@Published` found; observable app state uses `@Observable` | No broad observation migration is needed. |
| iOS deployment target | `project.yml` and the generated Debug/Release app settings now agree on `18.6` | Build and test on iOS 18.6 as well as iOS 27. |
| iOS escape hatches | 2× `@unchecked Sendable`, 3× `nonisolated(unsafe)` (including two date formatters), 2× `DispatchQueue.main.async*`, 2× `MainActor.run` in views, 1 Combine `NotificationCenter` publisher | The real Step 1 work. |
| iOS tests | Swift Testing target and shared scheme added; 41 tests pass on iOS 27 Simulator; the Step 1 physical-device checklist passed | Minimum-version testing remains open. |
| iOS hot spot | `ChatViewModel.swift` is 1,582 lines | Don't touch in Step 1. |
| iOS ↔ roles | iOS `User` model doesn't decode `role` | New roles won't break the app. ✅ |
| Server roles | `SUPER_ADMIN`, `ADMIN`, and `USER` are deployed; one Team Admin has no organization | Assign that account an organization before deploying team scoping. |
| Server auth | Role guards and HTTP team scoping were deployed on Nov 7, 2026 (per Rod); Step 2.4 socket scoping is implemented in the workspace | Deploy Step 2.4 with the matching dashboard after the Step 2.2 migration. |
| User status | `UserStatus { ACTIVE, SUSPENDED }` already exists | "Pause a member" maps to `SUSPENDED`. Label it **Paused** in the UI. No enum change needed. |
| Video moderation | Step 2.2 moderation states and server/admin controls are implemented; migration is not yet applied | Pause/flag/remove revokes Mux public playback IDs; unpause/restore issues a new ID. Apply the migration before deploying. |
| Migrations | Versioned migrations are committed and applied on the home server | Cloud Build and Render are no longer used; their legacy scripts still need safe migration workflows if reused. |
| Original files | iOS uploads **straight to Mux** (direct-upload PUT). The original never reaches our server. Mux doesn't give back the byte-exact original | Keeping originals means changing the upload pipeline (Step 4). |
| Legacy local path | `Clip.storageUrl` + an `uploads/` folder exist. The Mux webhook **deletes** the local file after `mux:ready` (`mux-webhooks.js:145`) | Reuse the idea, but keep the file instead of deleting it. |
| ⚠️ Public uploads folder | `index.js:267` serves `uploads/` with `@fastify/static` and **no auth**. Through the tunnel, anything placed there is publicly downloadable by URL | Must be removed or put behind auth **before** originals are stored (Step 4.1). |
| Thumbnails | Webhook already writes `Clip.thumbnailUrl` (`image.mux.com/<id>/thumbnail.png?width=640`) | Thumbnails are frontend-only work. |
| Mux settings | Uploads still begin with `playback_policy: public`, `cors_origin: '*'` | Step 2.2 deletes public playback IDs when an asset is paused, flagged, or removed; restoring playback creates a new ID, so old public URLs stay revoked. |
| Admin web app | One `App.tsx`, no router. Active theme: `theme-a-editorial.css` (imported in `main.tsx`). Three alternates sit unused | See the Themes note in Step 3. |

---

## Implementation Review (November 6, 2026)

- **Deployment versus SDK:** The selected minimum is **iOS 18.6**; the app must also build and be tested with the iOS 27 SDK/runtime. Raising the minimum intentionally drops support for iOS 17 and iOS 18.0–18.5.
- **Baseline before refactoring:** Debug and Release builds with Xcode 27.2 and the iOS 27.2 SDK succeed without signing, but have five distinct existing warnings: two main-actor isolation warnings in `Theme.swift` and three deprecated export API warnings in `VideoTrimView.swift`. The new baseline suite passes 18 tests on iOS 27.0 Simulator. Existing `ios/baseline-artifacts/phase0/` captures predate this migration and do not replace a fresh physical-device baseline.
- **Preserve behavior:** The current Debug server defaults are localhost for the simulator and a LAN address for devices. Switching the default to the home server is a separate behavior change and requires an explicit decision; preserve the existing defaults during this baseline phase.
- **Fixtures:** Use synthetic or sanitized server-contract fixtures; do not commit real user data, credentials, or tokens. Capturing sanitized responses from the dev server remains a separate validation task.
- **Test isolation:** App-hosted tests can restore an existing Keychain session and contact its configured server, so use a disposable simulator. Date tests compile the same production source into the test target with separate formatter instances; they cover formatting behavior, not production formatter thread safety. The existing `VideoMetadataExtractor.extract` can access the shared formatter off the main actor.
- **Release gates:** Test both the oldest supported iOS version and iOS 27, and complete the physical-device checklist. A successful simulator build or unit test run alone does not satisfy those gates.

### Pre-existing Risks Requiring Follow-up

- **Trimmed re-uploads:** The app uploads the trimmed file but stores the source Photos identifier. Archive re-upload can fetch that source without reapplying the selected trim, potentially uploading footage the user excluded. Verify and fix this before using sensitive footage in retry tests. See [VideoLibraryView.swift](ios/DirectVideoUploader/Views/Chat/VideoLibraryView.swift) and [ArchiveRowView.swift](ios/DirectVideoUploader/Views/Archive/ArchiveRowView.swift).
- **Transcription privacy:** The implementation tries Apple's server-based speech recognition first and falls back to on-device recognition when supported; it is not guaranteed to stay on-device. Decide whether local-only recognition is required, and review disclosure and consent before release. See [TranscriptionService.swift](ios/DirectVideoUploader/Services/TranscriptionService.swift).
- **Trim accessibility:** The trim handles use drag gestures without explicit VoiceOver adjustable actions. Verify the flow with VoiceOver and Dynamic Type, and involve the accessibility specialist before changing it.

---

# Step 1: Fixer iOS Modernization (iOS 18.6+ / Swift 6)

**Objective:** Raise the floor to iOS 18.6, remove concurrency escape hatches, and replace workarounds with iOS 18 APIs. Preserve current behavior on supported devices.

> **Scope note:** iOS is upload-only going forward. Step 1 still preserves the current feature set exactly. Trimming or redesigning screens is a later iOS UI phase. No admin/management features get added to iOS.

**Definition of done:**
- Zero concurrency warnings in a clean build.
- No `@unchecked Sendable` / `nonisolated(unsafe)` without a written justification next to it.
- Regression checklist (1.4) passes on a physical device.

### 1.1 Project & Tooling Target Bump

- [x] `project.yml`: `deploymentTarget.iOS: "17.0"` → `"18.6"`
- [x] Regenerate with XcodeGen. Confirm the effective app target is `18.6` for both Debug and Release, with no conflicting project/target overrides
- [x] Keep `SWIFT_VERSION = 6.0`. A separate `SWIFT_STRICT_CONCURRENCY` setting is not needed because Swift 6 mode already includes it
- [x] Remove target-level `DEVELOPMENT_TEAM: xxxxxxxxxx` from `project.yml` so the target inherits the existing base-level team
- [x] Remove iOS 18.6-and-earlier availability branches only when their behavior is covered by tests and the relevant specialist reviews *(Nov 6, 2026: the three remaining checks — iOS 16 on-device speech, iOS 18 `symbolEffect` — were always true at 18.6; no `#available` remains)*
- [x] Decide separately whether to point the Debug server default at `https://dev.ms-fixer.com` *(Nov 6, 2026: yes — Debug defaults to dev for simulator and device; the login-screen override and `DVU_SERVER_URL` still take priority for a local server)*
- [x] **Optional decision:** Swift 6.2 "approachable concurrency" (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). *(Nov 6, 2026: adopted, with `SWIFT_APPROACHABLE_CONCURRENCY = YES`, for both targets. Value types, Codable models and background helpers are marked `nonisolated`; previously off-main async work (`OriginalVideoLoader`, `PassthroughExporter`, `VideoMetadataExtractor`, speech recognition) is `@concurrent`; system callbacks are `@Sendable`. Zero warnings; 41/41 tests pass. Needs a full device regression pass because isolation mistakes here surface as runtime crashes, not compile errors.)*
- [x] Commit: "iOS 18.6 deployment target and baseline tests" *(landed in `8206766`)*

XcodeGen 2.46 rewrites the app product's existing `explicitFileType` metadata to `lastKnownFileType`; the pre-existing value was retained after regeneration. Check it when regenerating the project again.

### 1.2 Remove Concurrency Escape Hatches

| File | Current | Target |
| --- | --- | --- |
| `Services/VideoUploadService.swift:226` | `UploadDelegate: … @unchecked Sendable` | Final class, immutable `let` closures. Put mutable buffers behind `Mutex` (`Synchronization`, iOS 18+). Drop `@unchecked`. |
| `Services/TranscriptionService.swift:153` | `ResumeGuard: @unchecked Sendable` (stops a continuation resuming twice) | `Mutex<Bool>`, or restructure so only one callback can resume |
| `Views/Chat/VideoTrimView.swift:643` | `nonisolated(unsafe) let pollSession` polls export progress | iOS 18 async export API (1.3). Removes the polling loop. |
| `App/DVUDateFormatting.swift` | Two shared `ISO8601DateFormatter` instances use `nonisolated(unsafe)` | Audit concurrent access and replace with safe isolation, or document a verified justification. |
| `Views/Chat/VideoTrimView.swift:175,180` | `await MainActor.run { … }` in view tasks | Move the work into `TrimViewModel` (`@MainActor`) and drop the hops |
| `Views/Form/ContextFormView.swift:324` | `DispatchQueue.main.asyncAfter(0.5)` | Use a task cancelled on disappear; return on cancellation instead of performing the delayed action. |
| `Views/Onboarding/OnboardingWalkthroughView.swift:93` | `DispatchQueue.main.async` | Direct call, or `Task { @MainActor in … }` if a deferral is really needed |
| `Views/Profile/ProfileView.swift:50` | Combine `willEnterForeground` publisher | `@Environment(\.scenePhase)` + `.onChange` |
| `Services/WebSocketService.swift:489,522` | `NWPathMonitor` on a private queue + `MainActor.run` | Acceptable as is. Optionally wrap in an `AsyncStream<NWPath>`. |
| `Views/Chat/VideoLibraryView.swift:287` | `Task.detached` for temp-file delete | **Keep.** Legitimate off-main file I/O. |

- [x] Mark the immutable `Codable` models (`ChatMessage`, `Asset`, `Clip`, `User`, `FormResponse`, …) as `Sendable`
- [x] `SentUploadInfo` holds a `UIImage`, so keep it main-actor-only
- [x] Grep gate: `@unchecked|nonisolated\(unsafe\)|DispatchQueue\.main|MainActor\.run` should return only justified hits *(zero hits, Nov 6, 2026)*

**Done (Nov 6, 2026):** `UploadDelegate` and the transcription resume guard use `Mutex` (checked `Sendable`); `DVUDateFormatting` uses `Date.ISO8601FormatStyle`; `ContextFormView` focus uses a cancellable `.task`; the walkthrough defers with `Task { @MainActor in }`; redundant `MainActor.run` hops removed from `VideoTrimView` and the `WebSocketService` ping watchdog (both already main-actor); `Theme`'s dynamic color reads `UIScreen` only on the main thread. `NWPathMonitor` and `Task.detached` file delete kept as planned. Clean Debug and Release builds have zero Swift warnings; 41/41 tests pass; concurrency review found no issues.

### 1.3 Adopt iOS 18 APIs That Replace Workarounds

Only APIs that **remove** code or risk.

- [x] `AVAssetExportSession.export(to:as:)` + `states(updateInterval:)` replaces the polling loop in `PassthroughExporter` / `VideoTrimView`
- [x] `Synchronization.Mutex` replaces the hand-rolled `@unchecked Sendable` guards
- [x] Review `withCheckedContinuation` wrappers. Remaining: background upload delegate (no async API for background sessions), `OriginalVideoLoader` (`PHAssetResourceManager`), `TranscriptionService` recognition (`ResumeGate`) and `SFSpeechRecognizer.requestAuthorization` (no async API). Each resumes exactly once (concurrency review).
- [x] **Keep** the background `URLSession` + delegate upload. Step 4 changes *where* it uploads to, not *how*

### 1.4 Test Target & Regression

- [x] Add a `DirectVideoUploaderTests` target (Swift Testing) and a shared test scheme to `project.yml`
- [ ] Tests:
  - [x] JSON decoding of `User`, `Asset`, `Clip`, `ChatMessage`, and `MessagesResponse` using synthetic server-contract fixtures
  - [ ] Verify sanitized fixtures captured from `dev.ms-fixer.com` against those contracts
  - [x] `MessagePolicyCoordinator` / `MessageCatalog`
  - [x] `DVUDateFormatting`
- [x] Configure CI to run the Swift tests on an available iOS 18.6+ iPhone simulator
- The iOS CI job uses GitHub's `xcode-27` preview runner and selects an available
  iPhone using CoreSimulator runtime version metadata, including device-specific
  runtimes. It is configured to exercise the iOS 27 SDK and real background-upload
  tests. The preview runner may have limited capacity; it does not replace testing
  on the oldest supported iOS version.
- [ ] Verify the CI job on GitHub and run the suite on an iOS 18.6 simulator or device
- [ ] ~~Before 1.2, capture a fresh baseline (screen recordings of key flows) in `ios/baseline-artifacts/`~~ *(skipped: 1.2 shipped first; device regression covers it)*

**Manual regression on a physical device, after each sub-step:**
- [ ] Login (phone + PIN + company code), Keychain restore, legacy token migration
- [x] Permission prompts and denied states: Photos, Camera, Location, Speech, Mic
- [x] Onboarding (fresh install)
- [ ] Library pick: PHAsset fast path and Transferable fallback
- [ ] Trim → passthrough export → upload
- [ ] Upload: create asset (POST) → Mux direct upload (background PUT). Background the app mid-upload
- [ ] Re-upload a trimmed video from Archive and verify that no excluded footage is uploaded
- [ ] Transcription: verify server-first and on-device fallback behavior, and resolve the privacy decision before claiming local-only processing
- [ ] WebSocket connect / reconnect (airplane mode), `upload:progress`, `message:new`
- [ ] Context form → Mux ready → summary bubble → Slack share
- [ ] Archive / metadata / profile / appearance (light & dark)
- [ ] VoiceOver and Dynamic Type, including adjusting trim handles

### 1.5 Upload Fidelity, Onboarding Permissions & Archive Re-upload Safety

**Decisions (Nov 6, 2026):**
- **Untrimmed uploads** send the camera's untouched original file and its metadata, without conversion or compression.
- **Trimmed uploads** send a passthrough (no re-encode) copy cut from that original, named `<original>-edited.<ext>`, with the original's metadata. The `-edited` filename is what the web app stores.
- **Before creating an upload,** save a trimmed copy to Photos as a new item; the original is untouched. Keep the preview for retry or cancellation if the save fails.
- **Photo Library access is recommended, not required;** Speech Recognition is optional.
- **Without access,** ask at the first upload; if declined, upload the current version with a notice that Photos edits may be included.
- Fix Archive permission handling and the trimmed re-upload issue in this phase.

**Current behavior (traced Nov 6, 2026; no code changed):**
- `VideoUploadService` uploads the given file byte-for-byte; it is not the cause.
- Tapping **Next** always runs `PassthroughExporter`, even with no trim, so every upload is a re-packaged `-edited` copy. Its metadata is not explicitly copied, and the upload's metadata is re-read from that copy.
- `PhotosPicker` is created without `photoLibrary:`, so `itemIdentifier` is likely `nil`. The direct Photos path is then skipped, and the `loadTransferable` fallback uses the default `.automatic` encoding, which may transcode. When the direct path runs, it requests `version = .current` (the Photos-edited version) and disallows iCloud downloads.
- Archive re-upload fetches the edited `.current` version and ignores the trim.
- Nothing currently retrieves the untouched original.

**Implemented (workspace; latest device checks pending):** `OriginalVideoLoader` reads the `.video` resource (iCloud allowed, with progress); full-length selections upload that file unchanged; trims are passthrough copies with the original's metadata and the trimmed duration. Trims are saved to Photos before creating a server asset, with the copy and potential location/iCloud sync disclosed before upload; a failed save or asset creation leaves the preview available for retry. Archive retries now always require selecting and confirming the video. Scoped, fingerprint-verified photo links remain stored locally but are not used to auto-select, because they cannot prove which upload another device last submitted. Older links are also preserved without auto-selection. The earlier device checks predate these changes and must be repeated.

**Why access is recommended:** The system `PhotosPicker` runs out of process and can supply a selected video without broad library access. Access is needed to read the untouched original via `PHAssetResource` (`.video`); Archive retries use the representation selected in the picker. A trim also requires permission to add its copy to Photos before upload. For videos never edited in Photos, the current version equals the original. The App Review specialist should review the wording against Guideline 5.1.1(iv).

**Without access (decided Nov 6, 2026):** Without access, or with Limited access to a video outside the selection, the app cannot fetch the `PHAsset`, so it cannot tell whether a video was edited in Photos. Ask for access at the first upload. If the person declines, upload the current version (`.current` encoding, no transcode) and show a notice that Photos edits may be included.

**Proposed behavior**
- One **Permissions** screen in the app's theme after login, reusing the Profile permission-row design.
  - **Photo Library** is marked *Recommended* and explains that access lets the app upload originals and re-upload from Archive.
  - **Speech Recognition** is marked *Optional*.
  - A single neutral **Continue** button shows the system prompt for each undecided permission (Photo Library first); people decline in the system dialog. There is no skip/close and no "Allow" label (App Review Guideline 5.1.1(iv), decided Nov 6, 2026). Persist that the screen was seen with `@AppStorage`; both permissions stay available from Profile.
  - Presented from `ChatView` after the walkthrough and guide close (or at launch when onboarding is already complete), never over another sheet.
- Show the screen once to new and existing users while either permission is still undecided (`.notDetermined`).
- **Limited:** Explain that originals are available only for shared videos, other picker selections may include Photos edits, and Archive re-upload requires selecting a video; offer to manage the selection or open Settings.
- **Denied** and **Restricted:** Show **Open Settings** on the Permissions screen and in Profile. Recheck status whenever the app becomes active.

**Tasks**
- [x] Device check: confirm `itemIdentifier` is `nil` without `photoLibrary:`, whether `.automatic` transcodes, and whether passthrough export keeps metadata; test an iCloud-only video and one edited in Photos
- [x] Picker: create with `photoLibrary: .shared()` and `preferredItemEncoding: .current`
- [x] Original retrieval: with access, write the `.video` `PHAssetResource` to a temp file via `PHAssetResourceManager` with network access allowed (iCloud) and progress; use the original filename and `PHAsset` metadata (`OriginalVideoLoader`). A failed original load shows an error and never falls back to an edited copy.
- [x] Trim: skip export when the range is the full duration and upload the original; otherwise export from the original, copy its metadata explicitly, and verify on device *(device verification pending)*
- [x] Save the trimmed copy to Photos before creating a server asset (`PHAssetCreationRequest`); request add-only access if read/write access is not granted. On failure, retain the preview for retry or cancellation. If Photos succeeds without returning an identifier, require explicit confirmation that Archive recovery will be manual.
- [x] `PermissionManager`: inject the authorization provider (`PermissionAuthorizing`) for tests; make it the sole source of Speech authorization, including `TranscriptionService`; refresh status app-wide when the app becomes active (`ContentView`). Concurrency review: no issues.
- [x] Extract a shared `PermissionRow` from `ProfileView`; build `PermissionsView` and its presentation in `ChatView`. Accessibility review applied: status as VoiceOver value, contrast-safe `Theme.purpleText`/`purpleFill`, stacked layout and scaled icon at accessibility text sizes, 44 pt targets, header traits.
- [x] Archive retry (revised): require a manual Photos selection and explicit confirmation; upload the selected representation rather than silently substituting an original. Reject known duration mismatches (±1 s); an unknown duration does not prove a match.
- [x] Preserve legacy links without trusting them; new account/server-scoped links include a SHA-256 fingerprint and byte count. A selected representation is linked only when it matches the Photos original, but even verified local links are not auto-selected until the server can establish authoritative attempt identity.
- [x] Swift Testing: full-range trim detection, duration matching (legacy no-auto-retry rule), metadata merge and trimmed-duration rules (`UploadFidelityTests`)
- [x] Swift Testing: permission status mapping, row states, presentation decision, undecided-only requests and `TranscriptionService` authorization (`PermissionTests`, fake authorizer). 41/41 tests pass on the iOS 27 simulator; Debug and Release builds pass.
- [ ] Repeat the device matrix after the latest Photos-first and scoped-recovery changes: Allow Full, Limited, Don't Allow, Speech Allow/Don't Allow, change in Settings, and an existing installation. Exercise untrimmed, trimmed, iCloud-only and Photos-edited videos, cancellation and retry, and Archive recovery. Compare bytes and metadata. *(The previous implementation passed on device Nov 6, 2026.)*

### 1.6 Accessibility

**Objective:** Meet Apple's Human Interface Guidelines and the App Store Accessibility Nutrition Labels for VoiceOver, Voice Control, Larger Text, Sufficient Contrast, Differentiate Without Color and Reduced Motion. Preserve the visual design.

**Definition of done:**
- Every interactive control has a hit area of at least 44×44 pt and a meaningful VoiceOver label.
- Every flow, including trimming, can be completed with VoiceOver, Voice Control and Switch Control.
- Text scales with Dynamic Type up to AX5 without clipping.
- Text and icons meet WCAG AA contrast (4.5:1 for text, 3:1 for large text and icons) in light and dark mode.
- The accessibility specialist reviews every SwiftUI change, as the project rules require.

**Audit (Nov 7, 2026, from the code; sizes are estimates).** 25 controls are below 44 pt.

| Priority | Screen | Controls | Estimated hit area |
| --- | --- | --- | --- |
| High | Chat input (`InputBar:20, :43`) | Attach (+), Send | ~32×38 |
| High | Staged video (`VideoBubble:63, :180, :192`) | Remove ✕, Transcribe toggle, Upload | ~24×28, ~28×28, ~32×38 |
| High | Trim (`VideoTrimView:481, :503, :121`) | Left/right trim handles, Next | 18×60, 18×60, ~55×22 |
| High | Library footer (`VideoLibraryView:198`) | Confirm ✓ | ~32×38 |
| Medium | Trim (`VideoTrimView:107, :530`) | Cancel, playhead | ~55×22, 24×68 |
| Medium | Chat (`ChatButtonStyle:11`, `ChatHeaderView:59`) | Metadata/View pills, Instructions | ~100×31, ~24×24 |
| Medium | Archive (`ArchiveRowView:468, :263`, `ArchiveListView:54, :100`) | Re-upload/View/Slack/Details pills, Copy transcript, Refresh, Retry | ~⅓ row×31, ~14×15, ~22×24, ~35×15 |
| Medium | Context form (`ContextFormView:206`) | Priority buttons | ~70×35 |
| Medium | Onboarding (`OnboardingWalkthroughView:25`) | Skip | ~28×15 |
| Low | Onboarding, Slack, Login (Debug only) | Open Full Guide, Share to Slack (~43 tall), server Save/Reset/edit | Mostly ~31 tall or less |

Other issues found on the same controls:
- Icon-only buttons have no `accessibilityLabel`: Attach, Send, Remove, Upload, Instructions (read aloud as "service dog"), Copy, Refresh and the ✕ close buttons.
- **Trim handles and playhead can't be used with VoiceOver or Switch Control.** They only respond to drag gestures.
- **Missing traits and values:**
  - The video play/pause tap area isn't announced as a button.
  - The Transcribe toggle and the Priority buttons have no on/off or selected state.
  - Archive rows don't say whether they're expanded or collapsed.
- Archive "Details" can't be tapped but is still announced as a button.
- The trim screen's Next button reads ">>" aloud.

Compliant: system toolbars, tab bar, alerts and confirmation dialogs, the full-width primary buttons (Sign In, Continue, Send form, Next, Logout, Got it), `PermissionRow` and Profile rows.

**Plan**

*Phase A: touch targets and labels (no visual change)*
- [x] Add a shared 44×44 hit area with a required label to the icon-only buttons. *(Done as the `tapTarget()` modifier in `ChatButtonStyle.swift` instead of an `IconButton` type. It enlarges the hit area without changing visuals; labels are added at each call site.)*
- [x] Add `.frame(minHeight: 44)` once in `ChatActionButton` and once in `archiveButton`, which fixes 8 call sites.
- [x] Use `.toolbar` for the trim screen's Cancel/Next, or give them a 44 pt minimum height. Label Next as "Next".
- [x] Fix the remaining text buttons: Skip, Retry, Open Full Guide, Share to Slack, Priority, and the Debug server controls.
- [x] Add `.contentShape(Rectangle())` to every `.buttonStyle(.plain)` row so taps on empty space register (Archive row).
- [x] Size minimum targets with `@ScaledMetric` so they grow with text size.

*Phase B: VoiceOver and Voice Control semantics*
- [x] Trim: make each trim handle and the playhead adjustable with `.accessibilityAdjustableAction`, in steps of about 0.5 s or 1 s, announcing the time as the value. Hide the filmstrip tap-to-seek from VoiceOver. Widen the handles' hit areas, and decide which handle wins where they overlap at the 1 s minimum. *(Done. Steps are 0.5 s under 1 min, 1 s under 5 min, else 5 s. Handle hit areas are 44 pt and extend outward, so they never overlap; handles win over the playhead. Drags are relative to touch-down so the wider target doesn't jump.)*
- [ ] Add traits and values:
  - Video tap: the button trait and a Play/Pause label. *(Done with the trim work.)*
  - Transcribe: toggle semantics. *(Done in Phase A.)*
  - Priority: the selected trait. *(Done in Phase A.)*
  - Archive rows: an expanded/collapsed value.
  - Disabled "Details": `.disabled(true)`.
- [ ] Group composite rows (message bubbles, Archive rows, Metadata rows) into single elements with a label and value, and add custom actions for secondary buttons.
- [ ] Announce status changes such as upload progress milestones, upload complete or failed, transcription done and reconnecting. Use `AccessibilityNotification.Announcement`, throttled.
- [ ] Manage focus: when a sheet opens, move VoiceOver focus to its title; after an error, move focus to the error message.
- [ ] Voice Control: make sure each visible label matches its spoken name (no "plus.circle.fill").

*Phase C: Dynamic Type and layout*
- [ ] Map each `Theme` font token to a text style (`.system(.body)` or `relativeTo:`), and cap the size only where the layout truly requires it.
- [ ] At accessibility sizes, switch horizontal layouts to vertical with `ViewThatFits` or `dynamicTypeSize.isAccessibilitySize`, as `PermissionRow` already does. Pay particular attention to the chat input, Archive pills, context form and trim toolbar.
- [ ] Scale fixed icon frames with `@ScaledMetric`.

*Phase D: color, motion and preferences*
- [ ] Contrast check of every `Theme` color pair in light and dark mode. Known issues: `secondaryText` on the always-black picker footer, and brand `purple` used as text. Use `purpleText` and `purpleFill`.
- [ ] Differentiate Without Color: status dots, the upload error state and the Priority selection need a symbol or text as well as color.
- [ ] Reduce Motion: skip `symbolEffect` bounces and animated transitions when `accessibilityReduceMotion` is on.
- [ ] Respect Increase Contrast (`colorSchemeContrast`) and Reduce Transparency (`.ultraThinMaterial` overlays).

*Phase E: verification*
- [ ] Run Xcode Accessibility Inspector audits on every screen in light and dark mode at AX5.
- [ ] Add a UI test smoke check that calls `XCUIApplication().performAccessibilityAudit()` on the main screens (iOS 17+) in CI.
- [ ] Manual device passes:
  - VoiceOver: login, then pick, trim, upload, form, Archive re-upload, Slack share.
  - Voice Control and Switch Control: the same flow.
  - Larger Text at AX5.
  - Bold Text.
  - Reduce Motion.
- [ ] Fill in the App Store Connect Accessibility Nutrition Labels once each item above passes.

**Order:** Phase A and the trim part of Phase B first, because they block core upload flows. Then Phase C, which affects the whole app (do it after the "upload only" UI redesign if that comes first). Then D and E.

> **Later (not Step 1):** split `ChatViewModel.swift`, iOS UI redesign around "upload only", and remove `NSAllowsArbitraryLoads: true` now that the server is HTTPS via the tunnel.

---

# Step 2: Roles, Moderation & Soft Delete (Server)

**Objective:** The **server** decides who can see and do what. This step also adds reversible "pause" and the flag/remove workflow.

**Definition of done:**
- Every dashboard/admin route declares its allowed roles.
- Team scoping happens server-side.
- Paused/removed content is hidden by default.
- A role × endpoint test matrix passes in CI.

### 2.0 Prerequisite — Versioned Migrations (TASKS.md 0.5)

- [x] Baseline migration: `migrations/20260928133253_init` (from `main`) matches `schema.prisma` and is applied on the home server (`prisma migrate status`: up to date)
- [x] Commit `server/prisma/migrations/`
- [x] Home server uses `prisma migrate deploy` only (runbook). Removed the `db:push` npm script
- [ ] Before reusing the legacy Cloud Build or Render workflows, replace their `db push --accept-data-loss` commands and verify the database migration baseline. The Render script also seeds demo accounts.
- [x] Take a `pg_dump` before the first real migration (`scripts/pg-backup.sh`)

**Legacy cloud workflows:** The owner confirmed on Nov 7, 2026 that Cloud Build and Render
are no longer used. Their configuration files remain in the repository and must be
reviewed and migrated safely before either workflow is reused.

### 2.1 Roles & Super Admin Seed

| Role | Scope | Can |
| --- | --- | --- |
| `SUPER_ADMIN` (Rod) | Everything | Promote/demote users between `USER` and `ADMIN`, pause/unpause users, see all videos, pause/flag/remove videos, manage teams/orgs, server health & logs, create share links for any video |
| `ADMIN` (Team Admin) | Own team only | See team videos, pause/unpause team videos, flag team videos for removal, add members, **promote and demote Team Admins within the team**, pause/unpause team members, create share links for team videos |
| `USER` | Own records | Web access: view own videos, transcripts, form data, profile/PIN. Upload from iOS (and desktop in Step 4). Create share links for own videos *(confirm)* |

- [x] Migration `20261107150000_add_super_admin_role`: `ALTER TYPE "UserRole" ADD VALUE 'SUPER_ADMIN'`
- [x] **Seed Rod as Super Admin from an env var** (`SUPER_ADMIN_PHONE`): `npm run bootstrap:super-admin` (`server/src/scripts/bootstrap-super-admin.js`, idempotent). Rod's account removed from `seed.js`
- [x] Apply the migration and bootstrap the Super Admin on the home server
- [x] Role helpers in `server/src/lib/roles.js` (`isAdminRole`, `isSuperAdmin`, `checkRoleChange`). Every former `role === 'ADMIN'` check (server + dashboard) now also accepts SUPER_ADMIN
- [ ] Existing `ADMIN` accounts become team-scoped Team Admins (lands with 2.3). Tell them first. One current ADMIN has no organization
- [x] Promotion to `ADMIN` requires `companyCode`, and `PATCH /api/admin/users/:id` can't clear an admin's organization. The legacy unassigned admin still needs assignment.
- [x] `PATCH /api/admin/users/:id/role` `{ role: 'USER' | 'ADMIN' }` with guardrails:
  - Only SUPER_ADMIN can change roles outside their own organization (team admins get **404**)
  - Team Admin **can** promote and demote other Team Admins in their organization *(decided)*
  - Nobody can grant `SUPER_ADMIN` through the API (env/script only)
  - A SUPER_ADMIN's role can't be changed through the API, so the last one can't be demoted. Pausing is guarded in 2.2
  - Nobody can change their own role

### 2.2 Pause, Flag & Remove (Soft Delete)

**Members:**
- [x] Pause = `User.status = SUSPENDED` (shown as **Paused**)
- [x] Add `pausedAt`, `pausedById`
- [x] Paused users can't log in (the `authenticate` check already enforces `status`). Their videos stay visible to admins; active WebSocket sessions are disconnected on pause.

**Videos:** add a moderation state that is separate from processing `status`:

| `Asset.moderation` | Set by | Visible to | Reversible |
| --- | --- | --- | --- |
| `ACTIVE` (default) | — | Owner, team admins, super admin | — |
| `PAUSED` | Team Admin, Super Admin | Team admins, super admin (greyed out). Stays in owner's list marked **Paused**, with playback and share links disabled *(decided)* | Yes, unpause |
| `FLAGGED_FOR_REMOVAL` | Team Admin, Super Admin | Super admin removal queue | Yes, Super Admin can restore |
| `REMOVED` | **Super Admin only** | Nobody (audit row kept) | No. Original file and Mux asset are deleted |

- [x] Fields: `moderation`, `moderatedAt`, `moderatedById`, `moderationReason`
- [x] Asset lists default to active for admins; owners continue to see their active and paused assets. Admins can opt in to paused assets; only Super Admin can view flagged assets. The iOS Archive keeps older paused assets visible, labels them **Paused**, and suppresses playback, sharing, and retry actions.
- [ ] Removal marks a tombstone, deletes Mux media and any legacy local original, and supports retry from the Super Admin audit log when cleanup fails. Share-link revocation is deferred until Step 5 adds share links; Step 4 must wire original-file storage into removal.
- [x] Audit log table records actor, target, action, reason, and time; Super Admin can view the log.

**Implementation/rollout status (Nov 7, 2026):**
Server, dashboard, and iOS Archive changes are implemented; the additive migration has not been applied and Step 2.2 is not deployed. The iOS Archive decodes moderation, keeps paused assets visible regardless of age, and suppresses their playback, sharing, and retry actions.

**Deployment is blocked on Mux moderation reconciliation:**
Mux can create a public playback ID when a paused upload finishes processing. The ready webhook attempts to revoke it, but a missed or repeatedly failing webhook can leave that ID public; the sync job currently logs this condition without revoking it.

Concurrent pause, unpause, and ready events can also race remote Mux operations. Resolve and test these cases before relying on pause or deploying Step 2.2. Revocation is not instantaneous for viewers already playing a video; Mux may let an existing session continue briefly after its playback ID is deleted.

The unauthenticated `/uploads/` static path remains a separate exposure: legacy local files reachable there cannot be paused reliably until Step 4.1 replaces or protects that path. Apply the migration on the home server before deploying the code.

### 2.3 API Authorization & Team Scoping

**Deployment status (Nov 7, 2026):** Rod reports that Step 2.3 was deployed. Step 2 as a
whole is not complete.

- [x] `requireRole` replaces `authorizeAdmin` and the inline admin check.
- [x] `userScope(user)` and `teamScope(user)` produce Prisma filters: Super Admin sees all,
  Team Admin sees their organization, and User sees their own records. An unassigned Team
  Admin sees only their own records and cannot manage a team.
- [x] Apply scoping to dashboard lists, statistics, asset details, Mux status, and shared
  clip pages. Out-of-scope record IDs return **404**. Transcript updates remain owner-only.
- [x] Same-organization members may view a shared clip link; viewer authorization reloads
  the current account and organization instead of trusting an old cookie.
- [x] Restrict global diagnostics, cleanup, organization changes, and permanent user
  deletion to Super Admin. Team Admins can create members only in their own organization.
- [x] **Decided: team = Organization** (`companyCode`). The free-text `User.team` field is a label only
- [ ] SKIP >> Before rollout, assign the existing unassigned Team Admin to an organization and notify
  affected admins that their global access will become team-scoped.

**iOS compatibility (workspace only):** Pending-form metadata is stored per account and
server, and failed lookups or submissions leave it intact. Recovery verifies ownership,
the active session, and the particular saved record before restoring or clearing it.
Legacy `pending-form.json` files lack account/server provenance: they are preserved, not
automatically restored or deleted, and the app directs users to add details manually in
Archive. The app requests complete protection for a legacy file when it encounters one;
Archive also offers an explicitly confirmed action to remove that local copy. Older uploads
that need details or upload recovery remain visible beyond the usual seven-day window, with
both actions available when needed. Archive owns the details sheet independently of its
filtered rows. Form submissions are coordinated by account, server, and asset. Saved forms
are cleared only after a response identifies the expected asset; redirects and invalid
receipts are rejected. Leaving an unfinished form requires explicit confirmation, and a
failed send keeps the entered values open. Requests have a bounded timeout; a timeout
does not prove the server failed to save the details. Scoped recovery and transcript
requests also reject redirects. The new pending-form file requests complete file protection;
hardware enforcement must be checked on a physical device. Submission coordination is
within one app process; simultaneous submissions on different devices remain last-write-wins.
If the user explicitly skips a form, its recovery record stays in Archive instead of
automatically reopening on a later launch.

Transcript delivery targets the uploaded clip and reports success only after a matching
server receipt, so it cannot silently save to a replacement clip. **Deploy the server
update before distributing the iOS update**: older servers lack the new clip-specific
route, so the updated app reports transcript delivery failure until the server is updated.
Their legacy route can ignore a clip ID supplied in the request body. There is no Archive
transcript-retry action yet. A matching receipt does not prove that the clip is still the
current upload attempt; retained older clips and delayed Mux events need attempt-aware
coordination before concurrent retries are safe. The existing retry path can return a
waiting Mux upload URL while an earlier transfer is still active; do not re-upload while
the original transfer may still be running. Already-started background transfers are not
guaranteed to retract bytes already sent. The workspace app now requests cancellation of
all tracked transfers on logout and retains their temporary files until the transfer
callbacks finish; physical-device verification remains required.

**Additional client release blockers found in review:**

- Photos-first trimming and account/server-scoped, fingerprint-verified photo associations are implemented in the workspace; physical-device validation remains required. Failed saves and asset creation retain the preview. Cancelling an already-submitted Photos
  transaction may still leave a copy in Photos. Legacy associations are preserved but
  never auto-selected, including earlier scoped v2 links whose provenance cannot be proved.
  Every Archive retry requires selecting and confirming a Photos representation. A v3 local
  link is retained only when that representation matches the original bytes, preserving its
  metadata, but it is not used for automatic retry because another device can change the
  server upload. An explicitly confirmed repair preserves a corrupt scoped file separately.
  A force-quit or indeterminate
  Photos result can still make a later save duplicate a copy; asset creation retries can
  also duplicate server assets after a lost response.
- Temporary video copies request **complete until first user authentication** protection,
  the selected tradeoff for background uploads. After the first unlock following a restart,
  these files can remain accessible while the device is locked. The simulator cannot verify
  the protection class; verify the class and locked-device behavior on physical hardware.
  Scoped association and pending-form files separately request complete protection.
- If iOS terminates the app during a background transfer, its completion is not reattached
  to the original job, so a requested transcript may not resume after relaunch.
- Trim source readers and exports retain a temporary-file lease through cancellation; the
  handoff waits for the trim cover's dismissal and discards superseded results. Validate
  teardown and dismissal on a physical device.
- A waiting Mux URL may also retain metadata from the earlier attempt, including location,
  when a different video is selected. Upload attempts and their metadata are not yet
  versioned or bound to the selected bytes; do not rely on manual replacement until that
  server-side behavior is resolved. An active Chat upload is now tracked within the same app
  process and account/server scope to suppress its Archive retry, including while a
  cancellation drains after logout. Archive rechecks its latest fetched asset before
  retry side effects, tracks observed changes and reversions, and validates again immediately
  before starting the background PUT. A detected change stops the retry and asks for a refresh;
  this can include an update caused by the retry's own server request. The earlier URL-creation
  POST may already have sent metadata and created or reused a waiting clip even if the final
  guard rejects the PUT. These checks do not
  protect against another device, a terminated app, an unfetched server change, or a transfer
  that the server still considers active.
- Archive can observe the retry's own server-created processing clip before its URL response
  and abort the PUT. Until server-issued attempts can be distinguished safely, this fail-closed
  case may leave a processing record without uploaded bytes and delay another retry. An observed
  replacement during the PUT can also be followed by a stale completion notice; the post-upload
  refresh currently holds the transfer barrier and temporary file until it finishes. Resolve
  these cases before relying on recovery.
- Chat may continue to present an earlier failure while an Archive retry is in progress, and a
  later Mux-ready event does not yet clear every locally recorded failure by verified attempt.
  Reconcile these states without attributing another attempt's success to the failed upload.
- A repeated live form request, such as one caused by re-upload, can reopen a form whose
  details were already submitted. Since the server currently upserts form data, submitting
  that form can overwrite the existing details. Verify completion before presenting it.
- The background video PUT uses a separate session that can follow redirects and handle
  cookies, and its destination is not yet validated. Establish an approved HTTPS upload
  destination and a redirect-safe background-transfer strategy before client release.
- WebSocket connections and queued frames are not fully bound to the original account,
  server, and session generation. Keychain write/delete failures are also not reliably
  surfaced; a restored token is not bound to its issuing server, and a legacy token
  can be restored after logout. These require the planned transport and authentication
  hardening.
- The app has no app-owned privacy manifest in the workspace. Review required-reason API
  declarations and bundled SDK manifests with the App Review specialist before submission.
- Temporary video cleanup depends on normal completion, and protected association staging
  cleanup runs on a later write. Design task-aware cleanup for abandoned files without
  deleting files still needed by background transfers.
- The root recovery-protection alert and the legacy-form confirmation dialog do not expose
  a reliable dismissal-completion signal to the shared presentation gate. VoiceOver focus,
  queued announcements, and competing sheets need a lifecycle-safe solution before release.

**Validation:** The current server coverage suite passed 209 tests in 24 files, including
the disposable PostgreSQL authorization and Socket.IO tests. The latest full iOS 27 simulator suite passed
227 tests in 29 suites, including the real background PUT, Photos-link, and retry-intent
regressions; Swift source and test hashes were unchanged during the run. The Release simulator
build also passed. The admin production build and iOS launch-screen guard also passed.
Physical-device validation remains required, including VoiceOver focus and announcements
across tabs and sheets, keyboard validation, form dismissal, upload and recovery, staging,
locked/unlocked file protection, and actual Socket.IO redirect behavior. Testing on the oldest
supported iOS version also remains open.

**Isolation is not complete:** Step 2.4 socket scoping is implemented but not deployed;
Mux playback URLs are public, and `/uploads/` is unauthenticated (4.1). Do not treat HTTP
and socket scoping as end-to-end media isolation. Dashboard sign-in still uses phone and PIN without
a company code; the planned web-login policy remains part of Step 3. Stored auth tokens
are not bound to their issuing server across launches, and existing transport and logout
hardening still need a separate review. Cloud Build and Render are no longer used, per
the owner; their legacy scripts retain destructive schema-push behavior and must be
reviewed before any reuse. The Render build script also seeds demo accounts.

### 2.4 Real-Time (Socket.IO) Scoping

**Implementation/rollout status:** Implemented in the workspace; not yet deployed. Resolve the
Step 2.2 Mux moderation blocker and apply its pending migration before deploying the server,
then rebuild the dashboard and restart the server as described in the home-server runbook.

- [x] Audit server emits. The existing rich upload, form, and Mux notifications were already
  owner-targeted, rather than global dashboard broadcasts; keep their iOS payloads owner-only.
- [x] Authenticate socket connections against current database status, role, and organization;
  disconnect expired sessions and invalidate affected sockets on authorization changes.
- [x] Join `user:<id>`, `team:<companyCode>`, and `super` rooms using server-checked identity.
  Active-asset changes send a **payload-free** refresh to current team admins and super admins;
  unassigned owners' changes go only to super admins. The dashboard rechecks access and clears
  stale scoped data when its socket is invalidated.
- [x] Exercise delivery, reauthorization, suspension, expiration, and cross-team isolation with
  real Socket.IO clients; verify dashboard refresh and scope changes in a browser.
- [ ] Deploy the server and dashboard and verify the behavior on the home server.

Refresh delivery is best-effort; the dashboard also polls. Rooms, socket tracking, and
revocation are process-local and assume the current single-process deployment. Multiple
server instances would need a shared adapter and coordinated authorization invalidation.
Authorization changes made directly in the database bypass socket invalidation; restart the
server after such changes so existing connections must authenticate again.

### 2.5 Tests

- [ ] Role × endpoint matrix (3 roles × 2 teams × each route → 200/403/404)
- [x] Escalation and guardrail tests (2.1): `admin-role-routes.test.js`, `roles.test.js`, `bootstrap-super-admin.test.js`
- [x] HTTP authorization integration tests use a disposable PostgreSQL database for multiple
  organizations, role scopes, shared clips, stale cookies, and destructive-operation guards.
  CI provisions that database and runs migrations before the coverage suite.
- [x] Socket.IO integration tests cover owner-only payloads and scoped dashboard refreshes.
- [ ] Moderation visibility tests (paused/flagged/removed hidden correctly)
- [ ] Complete the full per-endpoint matrix, including moderation and Socket.IO.

---

# Step 3: Role-Separated Web UI & Thumbnails

**Objective:** One web app with three experiences. Every user gets web access. The client only hides UI; the server enforces.

### 3.1 Routing & Layouts

- [ ] Add a router (TanStack Router pairs with the existing TanStack Query)
- [ ] Split `App.tsx` into `AuthProvider` + role route trees
- [ ] Web login = the same phone + PIN + company code as iOS. Confirm that `USER` logins are accepted by the dashboard (today the dashboard expects admins)

| Layout | Contents |
| --- | --- |
| **Super Admin** | Team switcher, global stats, all users (promote/demote/pause), all videos, **Removal queue** (flagged items → restore / remove), audit log, triad/server health, error log, dev tools (`QuickActions`, `EndpointTable`) |
| **Team Admin** | Team stats, team members (add / promote / pause), team videos (pause / flag), share links |
| **User** | "My Videos" grid, video detail (player, transcript, form data, download/share), profile & PIN |

- [ ] Shared: header, login, 403/404, toasts, video detail page
- [ ] Moderation actions require a confirm dialog and an optional reason

**Themes:** the admin app has four theme files in `admin/src/`. Only one is active:

| File | Name | Status |
| --- | --- | --- |
| `theme-a-editorial.css` | Editorial | **Active** (imported in `main.tsx`) |
| `theme-b-lavender.css` | Lavender | Unused |
| `theme-c-newsroom.css` | Newsroom | Unused |
| `theme-d-dark.css` | "Midnight Studio" dark | Commented out in `main.tsx` |

- [ ] Decide: keep Editorial (and optionally D as a dark mode), then delete the rest so the new layouts are only styled once

### 3.2 Thumbnails

- [ ] Render `clip.thumbnailUrl`. Make sure the asset list endpoints `select` it
- [ ] List-sized images: `thumbnail.webp?width=320&fit_mode=smartcrop`. Optional hover preview: `animated.webp?width=320&end=4`
- [ ] `loading="lazy"` with fixed aspect-ratio boxes
- [ ] Status fallbacks:
  - `UPLOADING`: progress
  - `PROCESSING`: shimmer
  - `ERROR`: error tile
  - `PAUSED`: dimmed with a badge
- [ ] Live refresh on socket `mux:ready` / `upload:complete`

---

# Step 4: Original-File Storage & Store-First Upload

**Objective:** Keep every **native original** in our storage. Mux becomes playback-only. Use a **local folder on the home server** for testing, and make moving to cloud storage a config change.

### Target flow

```mermaid
sequenceDiagram
    participant C as iOS / Desktop
    participant S as Fastify (home server)
    participant D as Storage (local folder → cloud later)
    participant M as Mux
    C->>S: POST /api/assets (create asset + clip)
    S-->>C: upload session (part URLs, signed, short-lived)
    C->>S: PUT parts (each under 100 MB)
    S->>D: write parts → assemble original
    C->>S: POST complete
    S->>M: create asset with input = signed read URL to original
    M->>S: fetch original (signed URL, expires)
    M-->>S: webhook video.asset.ready (playback ID, thumbnail)
    Note over S,D: Original is KEPT (no delete after Mux ready)
```

### 4.1 StorageDriver Abstraction + Local Driver

- [ ] Server interface `StorageDriver`:
  - `createUpload`, `uploadPart`, `completeUpload`, `abortUpload`
  - `getReadStream(range)`, `signedReadUrl(key, ttl)`
  - `delete(key)`, `stat(key)`
- [ ] `local` driver: root folder from env `STORAGE_LOCAL_ROOT`
  - Recommend an **external SSD** path, not the Air's internal disk
  - Layout: `originals/<teamId>/<assetId>/<clipId>/<originalFileName>`
- [ ] Replace `Clip.storageUrl` (a public path) with `storageKey` + `storageDriver` + `sha256` + `sizeBytes`
- [ ] **Remove the public `/uploads/` static route** (`index.js:267`). All file access goes through authenticated or signed routes
- [ ] Stop deleting originals in the `mux:ready` webhook (`mux-webhooks.js:145`)
- [ ] Update `upload-cleanup.js` so it only removes **incomplete** uploads
- [ ] Disk guardrails:
  - Free-space check before accepting an upload
  - Super Admin dashboard shows storage used
  - Alert below a threshold
- [ ] Backups: originals are **not** covered by the nightly `pg_dump`. Decide on a copy target (second drive, or the future cloud bucket)
- [ ] Future `s3` driver (Cloudflare R2 / S3 / GCS): implements the same interface using real presigned multipart URLs. Clients don't change

### 4.2 Upload Protocol (Why Parts)

- [ ] ⚠️ **The Cloudflare plan caps request bodies at 100 MB** (Free/Pro). A single PUT of a large video through `dev.ms-fixer.com` will fail. The upload protocol must send **parts under 100 MB** (e.g. 50 MB)
- [ ] Model the protocol on S3 multipart:
  1. Create session
  2. PUT each part to a signed part URL
  3. Complete
- [ ] Local driver: part URLs are HMAC-signed Fastify routes. S3/R2 driver later: real presigned URLs that bypass the tunnel entirely
- [ ] Resumable: client can ask which parts already arrived and only send the missing ones (covers the "Mode B" goal in `IOS_UPLOAD_TRANSPORT_MODES_CHECKLIST.md`)
- [ ] After complete: server verifies size/checksum, then creates the Mux asset with `input: [{ url: signedReadUrl }]` (short TTL). Mux pulls the original through the tunnel. Downloads aren't subject to the 100 MB upload cap

### 4.3 Clients

- [ ] **iOS** (after Step 1): `VideoUploadService` uploads parts to our server instead of one PUT to Mux
  - Each part is its own background `URLSession` upload task from a file slice, so it still survives app suspension
  - Progress, transcription, form, and WebSocket flow stay the same
- [ ] **Desktop web**: drag-and-drop, multi-file queue, same part protocol, context form on web, `source: 'web'` on the asset
- [ ] Keep the old direct-to-Mux path behind a server flag until the new path is proven

---

# Step 5: Expiring Download Links (Native Original)

**Objective:** Let an authorized user create a link that gives a person **or a server** a download of the native original. The link has an expiry date and can be revoked.

- [ ] `ShareLink` table:
  - `id`, `assetId` / `clipId`, `tokenHash` (store only the hash, never the raw token), `createdById`
  - `expiresAt`, `maxDownloads?`, `downloadCount`, `revokedAt`, `lastAccessedAt`, `note` (e.g. "for CNN ingest server")
- [ ] Create: `POST /api/assets/:id/share-links { expiresIn }`
  - Presets: 1 h / 24 h / 7 d, max 30 d
  - Allowed: SUPER_ADMIN (any video), ADMIN (team videos), USER (own videos, *confirm*)
- [ ] Public download: `GET /d/:token`
  - Validate: not expired, not revoked, asset `ACTIVE`, download limit not reached
  - Local driver: stream the file with **HTTP Range** support (resumable, works with `curl`/`wget` for servers) and `Content-Disposition: attachment; filename="<original>"`
  - Cloud driver later: 302 redirect to a short-lived presigned URL
- [ ] Machine-friendly: plain URL, no cookies or JS, so `curl -O` works. Optionally offer a SHA-256 for verification
- [ ] Rate-limit `/d/*` and log every download (IP, user agent) for the owner and admins
- [ ] Links die automatically when a video is paused, flagged, or removed, or when its owner is paused *(confirm owner rule)*
- [ ] Web UI: "Share original" dialog (expiry picker, copy link), list of active links per video with revoke

> Mux static MP4 renditions are **not needed**. Downloads come from our stored original.

---

## Sequencing Note

Until Step 4 ships, **new uploads keep no original**. They only exist in Mux, which doesn't return the byte-exact file. That's fine while pre-production. If real content starts flowing sooner, consider moving **Step 4.1–4.2 ahead of Step 3**. It only depends on Step 2.0 (migrations), not on the new UI.

---

## Open Questions

- [ ] **Team = Organization?** Or a sub-group within an org? (2.3)
- [ ] Can a Team Admin demote another Team Admin, or only promote? (2.1)
- [ ] Does a paused video disappear from the **owner's** own list, or only show as paused? (2.2)
- [ ] Can regular USERs create share links for their own videos? (5)
- [ ] When a user is paused, do their existing share links stop working? (5)
- [ ] Theme: keep Editorial only, or Editorial + Midnight dark mode? (3.1)
- [ ] Originals backup target while on the local driver (second drive vs early cloud bucket)? (4.1)
- [ ] Which cloud storage later: Cloudflare R2 (no egress fees, same Cloudflare account) vs S3 vs GCS?
