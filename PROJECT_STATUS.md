May 10, 2026 - 4:26pm - GitHub Copilot (GPT-5.3-Codex)

# Direct Video Uploader — Project Status

**iOS readiness planning (October 28, 2026):** The [iOS 27 Readiness Plan](docs/IOS_27_READINESS_PLAN.md) tracks the new native-readiness workstream, decisions, and release gates. Execution has not started; historical status below is preserved as context.

> **Last Updated:** May 10, 2026 · PT
> **Current Phase:** Phase 4 (QA + Rollout) — iOS UI/UX refresh validation and release-readiness checks
> **Overall Progress:** ████████████████████ 100% (Phase 2) · Phase 3 complete · Phase 4 in progress

---

## Quick Summary

The **Direct Video Uploader** is a mobile-first video upload platform disguised as a text conversation. Field crew members "text" videos to the **Mediasource Fixer** server, which processes them the way a news assignment desk operates - fast, structured, and integrated with Slack.

We've completed the **interactive chat demo** (HTML prototype), **project specification** (v4), the **Phase 1 server foundation** (Node.js API, WebSocket, PostgreSQL, auth, admin dashboard), the **Phase 2 - iOS Demo App** core flow (login -> chat -> video upload -> form -> confirmation -> archive), and the **Web Clip Viewer** (server-rendered at `/clips/:slug`). Latest session (May 10): **Phase 4 QA execution started**. Server tests passed (107/107), admin production build passed, iOS build passed, and unknown message-code fallback was validated with a forced unknown-code runtime harness against `MessageCatalog`. New docs were added for release notes and rollback instructions under `docs/IOS_UI_UX_PHASE4_RELEASE_NOTES.md` and `docs/IOS_UI_UX_PHASE4_ROLLBACK.md`. Remaining Phase 4 work is focused on screenshot evidence capture, final light/dark smoke scenarios, and release candidate tag/push.

---

## Running the Project

```bash
# render deploy commands
./server
npm ci && npx prisma generate
npm run startnp


# Daily workflow — launches the full triad (DB + Server + Admin)
npm run dev

# What the triad does automatically:
#   1. Kills any existing processes on :3000 and :5173
#   2. Starts PostgreSQL via `prisma dev --detach`
#   3. Pushes schema changes (`prisma db push`)
#   4. Regenerates Prisma client (`prisma generate`)
#   5. Seeds demo users if database is empty
#   6. Starts Fastify server on :3000 (API + WebSocket)
#   7. Starts Vite dev server on :5173 (React admin with HMR)

# Build iOS app
cd ios && xcodegen generate && xcodebuild -project DirectVideoUploader.xcodeproj \
  -scheme DirectVideoUploader -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

**Root-level scripts** (run from project root):

| Command               | What it does                                                           |
| --------------------- | ---------------------------------------------------------------------- |
| `npm run dev`         | **Triad launcher** — DB + Server `:3000` + Admin `:5173` (recommended) |
| `npm run dev:admin`   | Starts Vite dev server only on `:5173` (proxies API to `:3000`)        |
| `npm run build:admin` | Production build of React admin → `server/public/`                     |
| `npm run server`      | Starts Fastify server only (no DB, no admin)                           |
| `npm run setup`       | Fresh setup: install deps, push schema, generate client, seed          |

---

## Milestones

### ✅ Milestone 0 — Project Definition

**Completed: Feb 28, 2026**

| Deliverable                           | Status  | File                      |
| ------------------------------------- | ------- | ------------------------- |
| Initial concept & user flow           | ✅ Done | `first-file.md`           |
| Project Spec v1 (MMS approach)        | ✅ Done | `docs/PROJECT_SPEC_v1.md` |
| Project Spec v2 (Direct Upload pivot) | ✅ Done | `docs/PROJECT_SPEC_v2.md` |

**Key Decisions:**

- Pivoted from MMS-based upload to direct app upload (better quality, richer UX)
- Established the "app IS a text conversation" design principle
- Defined the Mediasource Fixer branding and 800# contact identity

---

### ✅ Milestone 1 — Interactive Chat Demo

**Completed: Mar 1, 2026**

| Deliverable                        | Status  | File                                          |
| ---------------------------------- | ------- | --------------------------------------------- |
| Chat UI (iPhone mockup)            | ✅ Done | `chat-demo.html`                              |
| Step-by-step demo controls         | ✅ Done | Sidebar in `chat-demo.html`                   |
| Slack message sidebar              | ✅ Done | `#team-alerts` + thread reply                 |
| Metadata sheet                     | ✅ Done | Slide-up overlay with GPS, device, codec info |
| Context form sheet                 | ✅ Done | Type, slug, description, priority fields      |
| Confirmation bubble                | ✅ Done | Mediasource link + "High Five" message        |
| Video thumbnail (dual orientation) | ✅ Done | Handles horizontal & vertical video           |
| User profile header                | ✅ Done | Avatar + name/subtitle layout                 |

**Tech:** Single-file HTML/CSS/JS with no dependencies. Fully self-contained demo.

---

### ✅ Milestone 2 — Project Spec v4

**Completed: Mar 2, 2026**

| Deliverable                    | Status  | File                                  |
| ------------------------------ | ------- | ------------------------------------- |
| Full spec rewrite (v3 → v4)    | ✅ Done | `PROJECT_SPEC.md`                     |
| WebSocket architecture defined | ✅ Done | Replaces hardcoded polling            |
| Demo-first approach documented | ✅ Done | Phased plan with clear scope          |
| Tech stack recommendations     | ✅ Done | Render, Mux, Prisma, Socket.IO        |
| Data model (6 entities)        | ✅ Done | Users, Assets, Clips, Forms, Messages |
| API surface (10 endpoints)     | ✅ Done | REST + WebSocket events               |
| iOS demo requirements          | ✅ Done | SwiftUI + WebSocket client            |
| Hosting strategy               | ✅ Done | Render (server/DB/WS) + Vercel (web)  |

---

### ✅ Milestone 3 — Server Foundation (Phase 1)

**Completed: Mar 2, 2026**

| Deliverable                      | Status       | File                                                        |
| -------------------------------- | ------------ | ----------------------------------------------------------- |
| Node.js + Fastify server         | ✅ Running   | `server/src/index.js`                                       |
| PostgreSQL database (Prisma 7)   | ✅ Running   | `server/prisma/schema.prisma`                               |
| Database schema (6 models)       | ✅ Synced    | Users, Assets, Clips, FormResponses, ChatMessages           |
| Auth: Phone# + PIN → JWT         | ✅ Working   | `server/src/routes/auth.js`                                 |
| Asset CRUD + Upload              | ✅ Working   | `server/src/routes/assets.js`                               |
| Form submission                  | ✅ Working   | `POST /api/assets/:id/form`                                 |
| Chat message history             | ✅ Working   | `GET /api/messages`                                         |
| WebSocket (Socket.IO)            | ✅ Connected | `server/src/ws/handler.js`                                  |
| Real-time greeting message       | ✅ Working   | Sent on WS connect                                          |
| Slack post simulation            | ✅ Working   | `slack:post` → `slack:confirmed` events                     |
| Admin API (stats, users, assets) | ✅ Working   | `server/src/routes/admin.js`                                |
| Admin triad status endpoint      | ✅ Working   | `GET /api/admin/status` — DB, Server, iOS, Admin            |
| Admin dashboard (React)          | ✅ Working   | React 19 + Vite 6 + TypeScript + Tailwind v4                |
| Demo users seeded (4)            | ✅ Seeded    | David Burgess, Carrie Smith, Admin User, Rod Griola (ADMIN) |
| Local dev database               | ✅ Running   | `prisma dev` (PostgreSQL on port 51214)                     |

**Server Endpoints Verified:**

| Method  | Path                         | Status                     |
| ------- | ---------------------------- | -------------------------- |
| `GET`   | `/api/health`                | ✅                         |
| `POST`  | `/api/auth/login`            | ✅                         |
| `GET`   | `/api/auth/me`               | ✅                         |
| `POST`  | `/api/assets`                | ✅                         |
| `POST`  | `/api/assets/:id/upload`     | ✅                         |
| `GET`   | `/api/assets/:id`            | ✅                         |
| `POST`  | `/api/assets/:id/form`       | ✅                         |
| `GET`   | `/api/messages`              | ✅                         |
| `GET`   | `/api/admin/stats`           | ✅                         |
| `GET`   | `/api/admin/users`           | ✅                         |
| `GET`   | `/api/admin/assets`          | ✅                         |
| `GET`   | `/api/admin/status`          | ✅ Triad health            |
| `WS`    | `/socket.io/`                | ✅                         |
| `POST`  | `/api/admin/cleanup-assets`  | ✅ Stale asset cleanup     |
| `GET`   | `/api/assets/mine`           | ✅ User's assets list      |
| `POST`  | `/api/errors`                | ✅ Client error log        |
| `GET`   | `/api/admin/errors`          | ✅ Retrieve errors         |
| `PATCH` | `/api/assets/:id/transcript` | ✅ Save transcript         |
| `POST`  | `/api/admin/users`           | ✅ Create user (admin)     |
| `POST`  | `/api/admin/nuclear-reset`   | ✅ Wipe all data + Mux     |
| `POST`  | `/api/assets/:id/mux-upload` | ✅ Mux direct upload       |
| `POST`  | `/api/webhooks/mux`          | ✅ Mux webhook handler     |
| `GET`   | `/api/mux/status/:clipId`    | ✅ Mux polling fallback    |
| `GET`   | `/api/mux/env-key`           | ✅ Mux env key (public)    |
| `POST`  | `/api/admin/sync-mux-status` | ✅ Force-sync stuck assets |
| `GET`   | `/`                          | ✅ Dashboard               |
| `GET`   | `/clips/:slug`               | ✅ Web clip viewer         |
| `GET`   | `/clips/:mediasourceId/status` | ✅ Clip readiness (JSON) |

---

### � Milestone 4 — iOS Demo App (Phase 2)

**In Progress: Mar 2–25, 2026**

| Deliverable                        | Status             | Notes                                                  |
| ---------------------------------- | ------------------ | ------------------------------------------------------ |
| Xcode project setup (SwiftUI)      | ✅ Done            | iOS 17+ target, XcodeGen `project.yml`                 |
| Login / Auth (Phone + PIN → JWT)   | ✅ Working         | Tested on Simulator + physical iPhone                  |
| Chat UI (messages, bubbles, input) | ✅ Working         | `ChatView`, `MessageBubble`, `InputBar`                |
| WebSocket client (native)          | ✅ Connected       | `URLSessionWebSocketTask` + Socket.IO protocol         |
| Text message send + auto-reply     | ✅ Working         | Server replies "send me your videos!"                  |
| Video picker (PhotosPicker)        | ✅ Working         | SwiftUI `PhotosPicker` with `.videos` filter           |
| Video upload (multipart)           | ✅ Built           | `VideoUploadService` with progress tracking            |
| Upload progress bar                | ✅ Built           | Inline progress bar in chat view                       |
| Metadata display (slide-up sheet)  | 🟡 Built, untested | `MetadataView` SwiftUI sheet                           |
| Context form (slide-up sheet)      | 🟡 Built, untested | `ContextFormView` SwiftUI sheet                        |
| Confirmation message               | ✅ Built           | `form:confirmed` → Mediasource link in chat            |
| Slack post trigger                 | ✅ Built           | Auto-triggers after form submit, 1.5s delay            |
| TestFlight build                   | 🔲 Not started     | For demo distribution                                  |
| Xcode automatic code signing       | ✅ Done            | Team `LW5P4PVL96`, auto signing in project.yml         |
| Centralized Theme + Formatting     | ✅ Done            | Theme.swift, DVUDateFormatting.swift, UserDefaultsKeys |
| Video trim (pre-upload)            | ✅ Done            | UIVideoEditorController via modal host VC, .typeHigh   |

**Features Added (Apr 9 — Session):**

- **Admin component refactoring** — `AssetList.tsx` refactored from monolithic 350-line component into modular sub-components: `AssetRow` (individual row rendering), `FormSection` (form response display), `ClipSection` (clip details). `UserList.tsx` similarly refactored into `UserRow`, `StatusPill`, `UserDetails` with data-driven detail rendering. `formatDuration()` and `formatLoginAge()` extracted as shared utility functions. Comprehensive JSDoc documentation added.
- **Server-side input sanitization** — `POST /api/assets/:id/form` hardened: `slug` limited to 50 characters, stripped of non-alphanumeric/dash/period characters via regex; `description` limited to 500 characters, stripped of non-printable control characters (`[\x00-\x1F\x7F]`). Protects against malicious API calls bypassing the iOS client. Confirmed consistent `escapeHtml()` usage in `clips.js` for XSS prevention.
- **Clip Viewer video placeholder + auto-polling** — Replaced static "Video not yet available" text with a styled 16:9 placeholder matching Mux player dimensions, featuring a shimmer CSS animation and pulsing film icon. Added `GET /clips/:mediasourceId/status` lightweight JSON endpoint (public, no auth). Client-side JavaScript polls every 5s (max 72 attempts = 6 min). When Mux signals ready, dynamically loads the Mux Player SDK, creates a `<mux-player>` element, and swaps it in-place — zero page reload. Status pill updates live during processing.
- **Transcribe toggle UX** — Updated `VideoBubble.swift` transcribe button styling: off state = solid white background + gray text + `mic.slash` icon; on state = solid green background + black text + `mic.fill` icon. Clear visual distinction against the dark video bubble gradient.
- **Domain migration** — All project references updated from `rodgriola.com` to `ms-fixer.com` (README, first-file.md, privacy-policy.md, TODO.md).
- **Admin dashboard themes** — Created three semantic CSS theme files: `theme-a-editorial.css` (Clean Editorial — neutral tones), `theme-b-lavender.css` (Lavender Mist — purple gradient, currently active), `theme-c-newsroom.css` (Warm Newsroom — amber/sunset tones). Base `index.css` expanded with CSS custom properties for all design tokens.
- **README rewrite** — Full rewrite of `README.md` reflecting current architecture, Mux integration, admin dashboard, and deployment setup.
- **ServerConfig tethering IP** — Updated physical device debug fallback from `192.168.0.100` to `172.20.10.2` (USB tethering interface).
**Features Added (Apr 12 — Session):**

- **ArchiveRowView: `RowStatus` enum** — Added `private enum RowStatus` (needsDetails / failed / reuploading / processing / ready) and `rowStatus` computed property as the single source of truth. Replaced two separate if-else chains (status badge and action buttons section) with `switch rowStatus`. Priority order is centralized and compiler-enforced over exhaustiveness.
- **`phAssetToTempFile` continuation guard** — Added `var resumed = false` guard to prevent double-resume crash on iCloud assets (same fix applied to `VideoLibraryView` last session). `deliveryMode` already set to `.highQualityFormat`.
- **`handleReupload` PHAsset fast path** — Replaced `loadTransferable(type: Data.self)` (loads full video into RAM — 1–2 GB for 4K) with `PHAsset.fetchAssets` + `exportVideoToTemp`. Uses the `phAssetToTempFile` function already in the file. PHAsset identifier now saved immediately from the picker item.
- **UUID subdirectory in `phAssetToTempFile`** — Temp file now written to `temporaryDirectory/UUID/filename` to prevent filename collisions across app launches.
- **`defer`-based `isReuploadingVideo` reset** — Replaced 5 scattered `isReuploadingVideo = false` resets in error branches with a single `defer { if reuploadError != nil { isReuploadingVideo = false } }` at the top of each calling function. UI can no longer get stuck in uploading state.
- **Slug as primary display name** — Collapsed archive row now shows `asset.formResponse?.slug` first, falling back to `originalFileName → mediasourceId → id`.
- **Format row** — Resolution and Codec metadata rows combined into a single "Format" row using `compactMap` join (e.g. `"1920×1080 • HEVC / H.265"`).
- **`FormField.defaultVideoFields()` extension** — Added static method to `FormField` in `ChatMessage.swift`. Both `ChatViewModel.buildFormFields()` and `ArchiveRowView.buildFormFields()` now delegate to this shared extension — single source of truth for form field definitions.
- **`auth.authenticatedRequest` in Archive views** — `ArchiveRowView.submitFormFromArchive` and `ArchiveListView.fetchAssets` both replaced raw manual `URLRequest` + `setValue("Bearer \(token)", ...)` with `auth.authenticatedRequest(for:method:)`. Consistent with all `ChatViewModel` network calls.
- **Dead `parseISO8601` wrapper removed** — `private func parseISO8601` in `ArchiveRowView` was a 1-line passthrough to `DVUDateFormatting.parseISO` with no added value. Deleted; call site updated to call `DVUDateFormatting.parseISO` directly.
- **Photos tab (placeholder)** — New `PhotosView.swift` added at `Views/Photos/`. Matches `ArchiveListView` and `ProfileView` visual style: `Theme.screenGradient` background, standard black header, feature overview with `instructionRow` helper. Wired into `ContentView` as tab 3 (Chat → Archive → Photos → Profile) with `photo.fill` icon.

**Features Added (Apr 11 — Evening Session):**

- **ChatViewModel refactor** — Removed dead `formType`/`formDescription`/`formPriority` fields from `ArchiveState`, `MessageContent`, and 3 WS event handlers (fields were parsed from server but never displayed after ConversationSummaryBubble cleanup). Introduced `private static let isoFormatter = ISO8601DateFormatter()` replacing 12 separate allocations per session. Fixed `slackThumbnails` memory leak: dictionary now cleared in `startNewConversation()`. Removed redundant `await MainActor.run` in `downloadSlackThumbnail` (class is already `@MainActor`). Added `form.submitError = nil` on successful form submission (belt-and-suspenders with ChatView's existing clear-on-open).
- **VideoTrimView positioning fix** — Standardized all overlay positioning in `TrimScrubberView` to use `.position()` instead of mixing `.position()` and `.offset()`. Dim regions and trim border now use the same coordinate system as handles and playhead. Fixed playhead overlay: thin 2pt white line now rendered inside the hit target's `.overlay` *before* `.position()` is applied, preventing double-offset on certain screen sizes. Hit target widened from 14pt to 24pt (clear fill) for easier thumb targeting.
- **VideoTrimView @Observable migration** — Migrated `TrimViewModel` from `ObservableObject`/`@Published`/`@StateObject` to `@Observable`/`@State`, matching the rest of the codebase. `TrimScrubberView` changed from `@ObservedObject var vm` to plain `var vm`.
- **Audio session cleanup** — `TrimViewModel.cleanup()` now deactivates `AVAudioSession` with `.notifyOthersOnDeactivation`, allowing other audio apps (Spotify, podcasts) to resume after leaving the trim screen.
- **Export progress polling** — Replaced `Timer.scheduledTimer` + `nonisolated(unsafe)` with `Task`-based async polling (100ms interval). Cleaner Swift concurrency pattern, same behavior.
- **Transcription toggle default** — Changed from `@AppStorage("transcribeEnabled")` (persisted across videos) to `@State` (resets to off per video). Most videos don't require transcription; users opt-in per video with mic tap.

**Features Added (Apr 11 — Session):**


- **Instructions UI overhaul** — Expanded from 4 to 5 pages. New page 4 "What's Happening Inside Fixer" broken out from the Steps page, with emoji-led rows (GPS, transcript, metadata, confirmation, Slack). Step indicators on page 3 replaced with inline SF Symbol icons (`plus.circle.fill`, `checkmark.circle.fill`, `scissors`, etc.) matching actual app UI elements. Numbered steps removed. New `stepRow(icon:text:)` and `instructionRow(icon:text:)` overloads render icons in the app's standard purple/white palette.
- **First-name greeting** — Server now parses `socket.userName` ("Rod Griola") to extract first name only ("Rod") before passing to greeting templates. `split(' ')[0]` with null-safe fallback.
- **Per-device greeting** — Removed `iosCountForUser <= 1` gate on greeting. Every iOS device connection now receives its own greeting + feature tip, even if the same account is already connected on another device. Multi-phone uploading is a feature.
- **Device tracking** — iOS `WebSocketService.swift` now sends `deviceId` (UIDevice.identifierForVendor UUID), `deviceName` (e.g. "Rod's iPhone 15 Pro"), and `deviceModel` (e.g. "iPhone") in the Socket.IO CONNECT auth payload via `JSONSerialization`. Server auth middleware reads and stores on the socket object. Connection log now shows device name: `✅ iOS connected: Rod on Rod's iPhone 15 Pro (iPhone)`.
- **formSlug end-to-end** — Added `formSlug` to the `mux:ready` event payload in both `mux-sync.js` and `mux-webhooks.js`. iOS `ArchiveState` struct extended with `formSlug` field. `ChatViewModel.onMuxReady` parses and stores it. `ChatView` passes it to `ConversationSummaryBubble`. Slug now displays with `tag.fill` icon in the Video Ready summary card.
- **ConversationSummaryBubble cleanup** — Removed unused `formType` property (was declared but never displayed). Surfaced `formDescription` (with `text.alignleft` icon) and `formPriority` (with `flag.fill` icon) which were previously declared but hidden. Removed unnecessary `@ViewBuilder` from `metaRow`. Simplified `buildDetailsString` from imperative loop to `compactMap` + `joined`. Fixed indentation.

**Features Added (Apr 10 — Session):**

- **iOS Permissions Profile** — `PermissionManager.swift` added as an `@MainActor @Observable` singleton (injected via `.environment()` in `DirectVideoUploaderApp`). Reads `PHPhotoLibrary.authorizationStatus(for: .readWrite)` and `SFSpeechRecognizer.authorizationStatus()`. Provides `requestPhotoLibrary()` / `requestSpeechRecognition()` async methods that trigger the one-time iOS system dialog or redirect to `Settings.app` if already denied. Refreshes on foreground return via `UIApplication.willEnterForegroundNotification`.
- **ProfileView rebuild** — Replaced minimal logout-only screen with full profile UI. User info card (avatar initial, name, phone). Permissions section: two tappable rows, each with icon, title, description, color-coded status dot (🟢 authorized, 🟡 limited, 🔴 denied, ⚪ not determined), and Settings redirect arrow when denied. App info section (server URL, version). Logout button with "Positive?" confirmation.
- **Info.plist hardening** — Added `ITSAppUsesNonExemptEncryption: false` to both `Info.plist` and `project.yml` (`info: properties:`). Skips Apple's export compliance questionnaire on all future builds/submissions. Added `UILaunchScreen` dict directly in plist as canonical source alongside build settings.
- **VideoLibraryView await fix** — Removed unnecessary `await` from `UIDevice.current.model` and `UIDevice.current.systemVersion` (Swift compiler warning: "No async operations occur within await expression").
- **Agent instructions updated** — `copilot-instructions.md` reviewed and updated: fixed stale `VideoPreviewBubble` and `selectedPhotoItem` references, updated Info.plist/launch screen rules, added rules 23–26 covering `VideoBubble` phases, PHAsset fast-path, `PermissionManager`, and server-side sanitization. Updated Key References section.

**Features Added (Apr 8 — Session):**

- **VideoBubble merge** — Consolidated `VideoPreviewBubble.swift` and `SentUploadBubble.swift` into a single `VideoBubble.swift` with a `VideoBubblePhase` enum (`.staged`, `.uploading`, `.sent`). Staged phase shows "Tap to Upload" with send/cancel buttons. Uploading phase shows progress bar. Sent phase shows "Upload ▸" badge. Reduces code duplication and simplifies ChatView message rendering.
- **Video library load optimization (PHAsset fast path)** — Replaced `PhotosPickerItem.loadTransferable(type:)` (copies entire file to temp directory — minutes for large videos) with `PHImageManager.requestAVAsset(forVideo:)` which returns a direct `AVURLAsset` referencing the file in-place. Zero copy, instant playback readiness. Metadata now extracted from `PHAsset` properties (duration, pixelWidth, pixelHeight, location, creationDate) instead of re-reading the video file via AVAsset. Only codec requires a lightweight file header read. Cleanup logic updated to only delete temp copies (Transferable fallback), not Photos library references.
- **iPhone format conversion tip** — Discovered that iOS Settings → Privacy & Security → Photos → [App] → Options → Format set to "Most Compatible" triggers HEVC → H.264 transcoding on every video share, adding minutes of delay. Setting to "Current" eliminates this. Documented in knowledge base for user onboarding.
- **WebSocket routing fix (mux:ready cross-talk)** — Critical bug: simultaneous uploads by different users caused `mux:ready` events to broadcast to all connected clients via `io.emit()`. User A would receive "Video Confirmed" for User B's video. Fixed in `mux-sync.js`: now accepts the `fastify` instance, looks up the asset owner's sockets via `fastify.userSockets.get(asset.userId)`, and emits only to those sockets. Payload enriched with duration, resolution, and form details to match webhook handler output.
- **ContextFormView auto-focus** — Added `@FocusState` for the slug field with a 0.5s `DispatchQueue.main.asyncAfter` delay in `.onAppear` to auto-focus only after sheet animation settles. Eliminates the perceived "typing delay" when the form appears.
- **Dashboard login sanitization** — `LoginForm.tsx` now strips non-digit characters, caps phone at 10 characters and PIN at 8 characters. Added `inputMode="numeric"` to trigger mobile numeric keypad. Submit button disabled until phone is exactly 10 digits.
- **Launch screen fix** — `UILaunchScreen_ImageName` was `Image` (nonexistent) instead of `launchscreen` (the actual imageset). `UILaunchStoryboardName` pointed to a nonexistent storyboard, conflicting with the auto-generated approach. Removed storyboard ref, corrected image name. Updated `LaunchBg` color to match the purple in the splash image.
- **Slack confirmation card redesign** — `MessageBubble.swift` Slack confirmation bubble restructured: thumbnail (72×72) anchored left, all details (owner, MS#, date, channel/mention, posted status) stacked in a VStack to the right. Channel/mention styled in `Theme.purple`. Secondary text at 12pt for visual hierarchy. Outgoing Slack message text moved above the "Sending to Slack" indicator.
- **ConversationSummaryBubble cleanup** — Removed unused properties (`originalFileName`, `thumbnailUrl`). Standardized bubble width using `HStack { ...; Spacer(minLength: 60) }` pattern.
- **Slug debug logging** — Added `console.log` in `handler.js` Slack post flow to trace slug value from `formResponse` through to `buildAssetMessage`.

**Features Added (Mar 25 — Session):**

- **Admin Panel** — New admin tools UI on the dashboard. Rod Griola added as ADMIN user (phone: 9176717330, PIN: 3218). `POST /api/admin/users` creates new accounts (default PIN 0000, USER role). `POST /api/admin/nuclear-reset` wipes all assets, clips, form responses, chat messages, error logs, and Mux assets — preserves users, resets mediasource ID sequence to 100000001. `AdminTools.tsx` component with confirmation dialogs.
- **Apple Speech Transcription** — On-device video transcription using `SFSpeechRecognizer`. New `TranscriptionService.swift` with `@MainActor @Observable` pattern. Dual-attempt strategy: server-based recognition first (more accurate), on-device fallback (works offline). `addsPunctuation = true` for proper sentence formatting. `contextualStrings` for newsroom vocabulary (mediasource, b-roll, slug, standup, Fixer, breaking). Opt-in via Transcribe toggle on VideoPreviewBubble. Saves to `clips.transcript` + `clips.transcript_segments` (per-word timestamps). `PATCH /api/assets/:id/transcript` server endpoint. Transcript displayed in Archive, MetadataView, and web clip viewer.
- **Render buildCommand fix** — `render.yaml` was missing `prisma db push` in the `buildCommand`. Prisma Client expected `transcript`/`transcript_segments` columns but they didn't exist in production PostgreSQL — P2022 error on every `clip.findFirst()`. Fixed by adding `npx prisma db push --accept-data-loss && node src/seed.js` to the Render buildCommand.
- **Greeting fix** — Greeting was not showing when admin dashboard was open. `userSockets` tracked both admin and iOS sockets for the same user. Fixed to count only iOS sockets per user.
- **Mediasource ID sequence fix** — Nuclear reset `ALTER SEQUENCE` used `RESTART WITH 1` instead of `RESTART WITH 100000001`. Fixed in `admin.js` + reset local dev DB sequence.
- **Dashboard logout button** — Added LogOut icon button to admin dashboard header.
- **Nuclear reset 400 fix** — `api()` function always set `Content-Type: application/json` even for empty-body POSTs. Fastify rejects with `FST_ERR_CTP_EMPTY_JSON_BODY`. Fixed to only set Content-Type when body exists.
- **Admin dashboard rebuilt** — Fresh Vite build deployed to `server/public/`.

**Features Added (Mar 19 — Session):**

- **Archive row status dots** — Collapsed row shows colored status dot: green (Ready), amber (Needs Details — no form response), red (Upload Failed — ERROR or stuck PROCESSING >5min), spinner (Processing/Uploading). Status text matches dot color.
- **Archive thumbnails** — AsyncImage loads Mux thumbnail (`image.mux.com/{playbackId}/thumbnail.png?width=640`) in archive rows.
- **Archive 7-day filter** — `recentAssets` computed property filters to last 7 days. Stuck uploads banner shows count with red background.
- **Archive equal-width action buttons** — View, Slack, Details buttons use `frame(maxWidth: .infinity)` for uniform width.
- **Re-upload feature (PHAsset auto-connect)** — 3-tier auto-reconnect: (1) stored PHAsset identifier from original upload, (2) auto-discovery by `capturedAt` date ±2s match in Photos library, (3) fallback to PhotosPicker. `PHAssetIdentifierStore` persists `[assetId: phAssetIdentifier]` to `Documents/phasset-identifiers.json`.
- **Swift 6 concurrency crash fix** — `PHImageManager.requestAVAsset` callback runs on background queue. Moved export to standalone `phAssetToTempFile()` function outside the View struct to avoid MainActor isolation conflict.
- **ERROR status handling in iOS** — Added `.error` case to status dot and action button cascades. Previously fell through to green "Ready".
- **Processing spinner fix** — Changed from `reuploadComplete || asset.status == .processing` to just `asset.status == .processing` so spinner clears when server data refreshes.
- **Form submission from archive** — `showFormSheet` + `ContextFormView` sheet with `submitFormFromArchive()`. Local `formSubmitted` @State tracks submission before server refresh.
- **Bubble tail removal** — `ChatBubbleShape` simplified to `RoundedRectangle(cornerRadius: 18)`. Clean rounded rectangles for all message bubbles.
- **Launch screen** — `project.yml` `info:` section with `LaunchBg` color, `Image` asset, no safe area insets.
- **Info.plist ATS fix** — `INFOPLIST_KEY_NSAppTransportSecurity_AllowsArbitraryLoads` build setting never worked for nested plist dictionaries. Fixed with proper `info:` section in `project.yml` containing `NSAppTransportSecurity: { NSAllowsArbitraryLoads: true, NSAllowsLocalNetworking: true }`.
- **Physical device URL fix** — Switched from Bonjour hostname (`Richards-MacBook-Air.local`) to LAN IP (`192.168.0.100:3000`) for reliable tethered device connections.
- **Server Mux upload idempotency** — Only reuse existing Mux upload if `status === 'waiting'`. Stale uploads (any other status) are deleted and recreated.
- **Clip ordering fix** — All clip queries (`/api/assets/mine`, form-submit, clip viewer) now use `orderBy: { createdAt: 'desc' }` to return newest clip first. Previously returned oldest (ERROR) clip, hiding the new READY one.
- **Mux-sync timeout reduced** — No-asset ERROR timeout changed from 30min to 15min in `mux-sync.js`.
- **ConversationSummaryBubble** — Mediasource ID row redesigned with 🔗 emoji, mono font ID, inline View button. `metaRow` helper restored after merge conflict damage.
- **Greeting text updated** — "Hey {name}! You are busy today. Upload away."

**Features Added (Mar 10 — Session):**

- **Clip viewer CSP fix (3 rounds)** — Helmet's default Content-Security-Policy in production was blocking the mux-player CDN script (`script-src 'self'` rejects `cdn.jsdelivr.net`). Fixed with explicit CSP directives allowing jsdelivr (scripts), stream.mux.com (media), image.mux.com (thumbnails), \*.litix.io (Mux Data analytics). Second round: CORP set to `cross-origin`, COEP disabled. Third round: added `*.edgemv.mux.com` for multi-level subdomain HLS segments. Commits: `57fcb9e`, `0beba37`, `18f0ef4`.
- **Removed dead `<video>` fallback** — Clip viewer simplified to mux-player or "not yet available" (removed dead `<video>` path).
- **Slack confirmation card redesign** — `MessageBubble.swift` Slack confirmation bubble redesigned with structured card layout: green accent bar, thumbnail with green stroke, channel/mention badges, clip link, and action buttons. Outgoing Slack messages simplified to plain "Sending to Slack…" indicator.
- **WebSocket handler** — `userName` and `slug` now included in Slack confirmation message content for richer iOS display.
- **Video trim (UIVideoEditorController)** — `VideoTrimView.swift` rewritten with `VideoEditorHostController` that presents `UIVideoEditorController` modally via `present(_:animated:)`. Previous approach embedding UIVideoEditorController as direct `UIViewControllerRepresentable` crashed (it's a UINavigationController subclass that must be presented modally). Uses `.typeHigh` quality setting.
- **WebSocket auth logging** — Server `handler.js` now logs auth rejections (no token, invalid token) and Engine.IO `connection_error` events. Previously auth failures were completely silent in Render logs.
- **iOS WebSocket reconnect fix** — `connect(token:)` guard was blocking fresh tokens while `isReconnecting == true`. Fixed: `connectWebSocket()` now calls `disconnect()` first (which cancels the reconnect `Task`, resets `isReconnecting`), then connects with the fresh token. Commit: `6e92dc2`.

**Features Added (Mar 9 — Session):**

- **Upload pipeline simplification** — Collapsed 4 upload paths (server direct, Mux direct, server-side ingest, tus resume) into single Mux direct path. iOS → `POST /api/assets/:id/mux-upload` → PATCH to Mux CDN via tus protocol. Background URLSession with `waitsForConnectivity` handles network interruptions natively.
- **Removed PendingUpload** — Deleted `PendingUpload` struct, `checkPendingUpload()`, `resumePendingUpload()`, `discardPendingUpload()`, `restoreFormForAsset(_:pending:)`, `buildMultipartFile()`, `checkTusOffset()`, `resumeMuxUpload()`, `createOffsetFile()`. ~350 lines removed across VideoUploadService.swift and ChatViewModel.swift.
- **Removed upload recovery alert** — Deleted `.alert("Interrupted Upload")` with Resume/Discard buttons from ChatView. If upload is interrupted, user simply re-uploads.
- **Removed server direct upload from iOS** — `ServerConfig.uploadURL(_:)` removed. Server endpoint still exists but iOS no longer calls it.
- **Chat header simplified** — Removed team/job subtitle. Status text: 🟢 Ready / 🟡 Working... / 🔴 Trying to connect... Dot enlarged 6pt→7pt.

**Features Added (Mar 8 — Session):**

- **Stability Plan Phases A–C** — Full implementation of `STABILITY_PLAN.md`. See dedicated section below.
- **Idempotent Mux upload** — `POST /api/assets/:id/mux-upload` now checks for existing PROCESSING clip with valid Mux upload URL before creating a new one. Prevents duplicate clips from retry/reconnect scenarios. (Commit `3fbb632`)
- **Upload recovery prompt** — ~~On relaunch, `checkPendingUpload()` now handles both UPLOADING and PROCESSING asset statuses.~~ **Removed Mar 9** — replaced by simplified single-path upload; background URLSession handles interruptions automatically.
- **Form state persistence** — New `PendingForm` Codable struct (modeled after `PendingUpload`) saved to `Documents/pending-form.json`. Stores `assetId`, `originalFileName`, `capturedAt`, `clipCount`, `duration`, `thumbnailJPEG`. Saved when `form:request` WebSocket event fires, cleared on successful form submit.
- **Form restoration on relaunch** — `checkPendingForm()` loads persisted form, verifies with server that form hasn't already been submitted, then restores form sheet UI. If upload completed in background but form was never shown, `restoreFormForAsset()` auto-opens the form.
- **Dashboard auth fixes** — 401 fix (query gating on `loggedIn` state), 403 fix (admin role seeding for Admin User).
- **Stuck PROCESSING auto-error** — `mux-sync.js` now auto-marks clips as ERROR after 30 minutes if they have no `muxAssetId`.

**Features Added (Mar 7 — Session):**

- **MessageBubble rewrite** — Complete rewrite of `MessageBubble.swift` with dedicated content views for each message type: `textContent`, `videoContent`, `confirmationContent`, `formRequestContent`, `slackContent`. Custom `ChatBubbleShape` with tail on outgoing (right) and incoming (left) bubbles.
- **Slack confirmation bubble** — Incoming slack bubbles show ✅ checkmark icon, message text, `#channel` and `@mention` badges with colored pill backgrounds.
- **Confirmation bubble enhancements** — Shows slug, mediasource ID with 🔗 link, copy-to-clipboard button, "Metadata" and "View" action buttons.
- **Form request bubble** — Shows slug, mediasource ID link, copy button, divider, and "Metadata" action button.
- **ContextFormView dismiss prevention** — Added `interactiveDismissDisabled(!canSubmit)` to prevent swipe-to-dismiss when slug/description fields are empty. X button shows alert dialog instead of closing when fields incomplete: "Please fill out Slug and Description before closing the form."
- **Server-side slug/description fallback** — Relaxed schema validation on `POST /api/assets/:id/form`. If slug or description arrive empty (edge case: app crash, battery death), server falls back to authenticated user's name.
- **Dashboard "missing form" alerts** — `AssetList.tsx` highlights READY assets without form data: red left border, tinted background, "⚠️ No Form" badge, expanded detail alert banner.
- **Clip viewer "missing form" alerts** — Server-rendered `/clips/:slug` page shows red 🚨 alert banner when READY asset has no form submission.
- **InputBar styling** — Darker background (`#DAD9D9`), 2px red top border accent.
- **VideoPreviewBubble styling** — Updated gradient with `Theme.videoBubbleHi` / `Theme.videoBubbleLo`.
- **Theme.swift additions** — Added `videoBubbleHi`, `videoBubbleLo`, and other new color constants.
- **Admin dashboard rebuilt** — Fresh Vite build deployed to `server/public/assets/`.

**Features Added (Mar 6 — Session):**

- **Mux webhook signature fix (ROOT CAUSE)** — `@mux/mux-node` v12 changed `Webhooks.verifySignature` from static method to instance method. Code called `Mux.Webhooks.verifySignature()` which threw "is not a function", rejecting ALL Mux webhooks with 401. Fixed to `new Mux().webhooks.verifySignature()`. This was why all clips stayed stuck in PROCESSING.
- **Asset status propagation** — `video.asset.ready` webhook handler only updated `clip.status` to READY but never updated the parent `asset.status`. Dashboard and clip viewer show asset status. Fixed in webhook handler, polling endpoint, and error handler.
- **Polling endpoint crash fix** — `GET /api/mux/status/:clipId` was missing `assetId` in its SELECT clause, causing `where: { id: undefined }` crashes. Fixed and restructured to handle `muxAssetId` exists but `muxPlaybackId` missing.
- **Admin sync endpoint** — `POST /api/admin/sync-mux-status` finds assets stuck in PROCESSING/UPLOADING that have READY clips and force-updates them.
- **Slug removal** — Removed `asset.slug` from entire codebase, replaced with `mediasourceId` for clip URLs.
- **Real Slack integration** — `server/src/lib/slack.js` with bot token for "fixer-video" bot. `postToChannel()`, `postDM()`, `buildAssetMessage()`. iOS `#channel @user` chat commands post to real Slack channels.
- **iOS createAsset retry** — Up to 3 attempts with exponential backoff in `ChatViewModel.createAsset()` for Render cold-start resilience.
- **Keyboard dismiss** — `.scrollDismissesKeyboard(.interactively)` on ChatView.
- **Background Mux sync job** — `server/src/jobs/mux-sync.js` runs every 2min, checks all PROCESSING clips against Mux API, auto-heals stuck clips, alerts via Slack on errors. Wired into server startup/shutdown lifecycle.
- **Render paid tier** — Upgraded to paid account. No cold starts. Dashboard response times 150–480ms.

**Features Added (Mar 5 — Session):**

- **Xcode automatic code signing** — Configured `DEVELOPMENT_TEAM: LW5P4PVL96`, `CODE_SIGN_STYLE: Automatic`, `CODE_SIGN_IDENTITY: "Apple Development"` in `project.yml`. Enables direct device install from Xcode without TestFlight.
- **Clip URL bug fix** — Server `form:confirmed` event was sending `formResponse.slug` (user-typed text like "Spill ") instead of `asset.slug` (URL-safe auto-generated like `img-6278-eec88a`). Fixed in `server/src/routes/assets.js`. Added `ServerConfig.clipURL(_:)` centralized helper for consistent URL construction.
- **iOS codebase pattern unification** — Comprehensive refactoring across 15+ Swift files:
  - **Theme.swift** (NEW) — 20 named color constants (`Theme.blue`, `Theme.cardBg`, etc.) + `Color(hex:)` extension. Eliminated 100+ duplicated hex color strings across 13 files.
  - **DVUDateFormatting.swift** (NEW) — Cached date/time formatters (`longDate`, `shortDate`, `timeOnly`, `duration`, `fileSize`, `parseISO`). Replaced 40+ inline formatter creations and 5 duplicate formatting functions. Uses `nonisolated(unsafe)` for Swift 6 concurrency.
  - **UserDefaultsKeys enum** (in ServerConfig.swift) — Centralized `"serverURL"` and `"authToken"` key constants. Replaces scattered hardcoded strings.

**Features Added (Mar 4 — Session):**

- **Client error logging** — `POST /api/errors` endpoint persists iOS errors to `client_errors` DB table (source, category, message, severity, metadata, userId, deviceInfo). `reportError()` utility in `ChatViewModel` calls the endpoint on failures.
- **View & Metadata buttons on High Five** — Confirmation bubble now has green "View" button (opens `/clips/:slug` in browser) and blue "Metadata" button (opens MetadataView sheet).
- **View button URL fix** — Was using `appendingPathComponent("/clips/...")` which percent-encoded slashes. Switched to string interpolation matching MetadataView's working approach.
- **Follow-up message with random phrases** — 1 second after High Five, a `.greeting` bubble appears with one of 10 random phrases (e.g., "smoother than a dolly shot", "fastest upload this side of the Mississippi", "cloud butler just filed your clip").
- **Archive tab (bottom tab bar)** — New `TabView` in `ContentView` with Chat and Archive tabs. Archive fetches from `GET /api/assets/mine` and shows expandable rows with metadata, form response fields, status pills, and a View button.
- **`GET /api/assets/mine` endpoint** — Returns authenticated user's assets ordered by `createdAt` desc, includes first clip and form response. BigInt `fileSize` converted to string.
- **`FormResponse` model** — New Codable struct in `Asset.swift` (id, assetId, slug, type, description, priority, submittedAt). `Asset` now includes optional `formResponse` field.

**Bugs Fixed (Mar 3 — Evening Session):**

- **Xcode build: async UIDevice properties** — In Swift 6, `UIDevice.current.model` and `.systemVersion` are `@MainActor`-isolated. Added `await` in `VideoMetadataExtractor.swift`.
- **Xcode build: FormField param order** — `FormField` init requires `value` before `options`. Fixed swapped arguments in `ChatViewModel.swift`.
- **Clip viewer empty response** — `@fastify/static` with `prefix: '/'` was intercepting `/clips/:slug`. Fixed with `wildcard: false` on the static plugin.
- **Prisma `include` timeout** — `findFirst` with `include: { clips, formResponse, user }` timed out (Prisma 7 + pg adapter issue). Split into separate sequential queries.

**Features Added (Mar 3 — Evening Session):**

- **Web clip viewer** — Server-rendered HTML at `GET /clips/:slug` with dark theme, video player, metadata grid, form response, priority badges. Route: `server/src/routes/clips.js`.
- **Server response intelligence** — Time-of-day greeting on connect, debounce (suppresses auto-reply if upload starts within 3s), personalization (uses first name), greeting fires once per session.
- **Real metadata extraction** — iOS `VideoMetadataExtractor` uses AVAsset to extract duration, resolution, codec, orientation, device model, OS version, GPS coordinates, capture date. Sent as multipart fields alongside video.
- **iOS form restructuring** — `ContextFormView` now shows read-only metadata fields (device, resolution, duration, codec, GPS, captured date) above editable fields (slug, type, description, priority). `MetadataView` wired to display extracted metadata.
- **Slack gating** — Removed auto-Slack post. Confirmation messages now include a "Post to Slack" button that the user explicitly taps.
- **Admin asset → clip viewer links** — Asset list rows link to `/clips/:slug` (opens in new tab with ▸ indicator).
- **Git repo initialized** — `.gitignore`, initial commit (68 files, 14,786 insertions).

**Bugs Fixed (Mar 3 — Afternoon Session):**

- **iOS WebSocket 25s disconnect loop** — Root cause: client was sending its own pings (Engine.IO 4 has server-initiated pings) and treating all `"3"` responses as probe responses instead of just `"3probe"`. Fix: removed client-side ping timer, added `isUpgraded` flag, `case "3"` now checks `raw == "3probe"`. Connection stable 10+ minutes.
- **WS connection storm (259 → accurate count)** — `engine.clientsCount` inflated by transport-level connections. Switched to `io.of('/').sockets.size` for actual Socket.IO socket count. Added `pingTimeout`/`pingInterval` config.
- **fileSize:0 in upload WS event** — `ChatViewModel` was passing hardcoded `fileSize: 0`. Now gets actual file size from disk via `FileManager.attributesOfItem` before sending the WS event. Confirmed: `fileSize: 10651178` in logs.
- **5 stale UPLOADING assets** — Created `POST /api/admin/cleanup-assets` endpoint + "Cleanup Assets" Quick Action button. Uses Prisma ORM to delete stuck assets (status=UPLOADING, 0 clips).
- **onlineUsers inflation** — Admin WS connections were counted as online users. Fixed with admin socket exclusion filter in `/api/admin/stats`.
- **Dashboard simulation buttons removed** — Removed "Login (David)" and "WS Connect" buttons from QuickActions. Only 3 actions remain: Health Check, My Profile, Chat History.
- **Chat History panel** — Was showing toast with count only. Created full `ChatHistory.tsx` component showing actual messages with direction (📤/📥), type badges, timestamps, file names.
- **Admin login credentials** — Dashboard now auto-logins as Admin User (`8001234567`/`0000`) instead of David Burgess.
- **Form response visibility** — Asset list now shows form response status indicator per asset.

**Bugs Fixed (Mar 2 — Evening Session):**

- `Asset.clipCount` made optional (`Int?`) — server create-asset response didn't include it, causing silent `JSONDecoder` failure that broke the entire video upload flow
- Server `POST /api/assets` response now includes `clipCount` and `totalDuration`
- DB connection pool increased from 5 → 20 — concurrent dashboard + WS queries caused timeout on `/api/admin/users`
- Text message auto-reply added — server now responds "I can't text just yet" to plain text (was silently storing without reply)
- Video picker `selectedPhotoItem` now resets to `nil` after processing (was preventing re-picks)
- Upload errors now surface inline in chat (was silently failing)
- `VideoTransferable` error handling improved — uses explicit `do/catch` instead of `try?`

**Bugs Fixed (Mar 2 — Afternoon Session):**

- `User.status` field made optional — server login response doesn't include it
- `ServerConfig.baseURL` changed from `localhost` to `127.0.0.1` — Simulator resolves `localhost` to IPv6 `::1`, but Node server binds IPv4 only
- Physical device uses Mac LAN IP via `#if targetEnvironment(simulator)`
- Fixed 3 Swift compiler warnings (unused `[weak self]`, `nonisolated(unsafe)`, `@MainActor` Timer closure)
- Fixed `UploadDelegate` Sendable warnings (`@unchecked Sendable`, `@Sendable` closures)

---

### ✅ Milestone 5 — Web Clip Viewer (Phase 2)

**Completed: Mar 3, 2026**

| Deliverable                    | Status      | Notes                                              |
| ------------------------------ | ----------- | -------------------------------------------------- |
| Clip viewer page               | ✅ Done     | Server-rendered HTML, `server/src/routes/clips.js` |
| Responsive layout (dark theme) | ✅ Done     | Dark theme with metadata grid, priority badges     |
| Public shareable links         | ✅ Done     | `GET /clips/:slug` — works without auth            |
| Video playback                 | ✅ Done     | `<mux-player>` web component (Mux CDN streaming)   |
| Admin links to clip viewer     | ✅ Done     | Asset list rows link to `/clips/:slug`             |
| Host on Vercel                 | 🔲 Deferred | Server-rendered (not static); deploy with Render   |

---

### ⚡ Milestone 6 — Live Demo Stack (Phase 3) ← **IN PROGRESS**

**Started: Mar 4, 2026**

Render is the preview environment (stand-in for eventual company production system). TestFlight couples with live Render + Cloud + Mux.

| Deliverable              | Status           | Notes                                                                                                                                       |
| ------------------------ | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Render deployment prep   | ✅ Done          | `render.yaml`, `render-build.sh`, SSL-aware pg pool, `trustProxy`, conditional pino-pretty, `NODE_ENV` detection                            |
| Deploy server to Render  | ✅ Live          | Auto-deploys from `main`. Custom domain `ms-fixer.com`. Managed PostgreSQL.                                                                |
| Mux SDK + service        | ✅ Done          | `@mux/mux-node`, `server/src/lib/mux.js` — createDirectUpload, ingestVideo, status helpers                                                  |
| Mux direct upload (iOS)  | ✅ Done          | iOS uploads directly to Mux CDN (bypasses server). `uploadViaMux()` in `VideoUploadService`, fallback to multipart                          |
| Mux webhooks             | ✅ Done          | `server/src/routes/mux-webhooks.js` — handles upload.asset_created, asset.ready, asset.errored. v12 instance method signature verification. |
| Mux Player (clip viewer) | ✅ Done          | `<mux-player>` web component in clip viewer. CSP configured for jsdelivr + stream.mux.com. Dead `<video>` fallback removed.                 |
| Mux background sync      | ✅ Done          | `server/src/jobs/mux-sync.js` — polls every 2min for stuck PROCESSING clips, auto-heals, Slack alerts                                       |
| Slack integration (real) | ✅ Done          | `server/src/lib/slack.js` — bot "fixer-video", `postToChannel()`, `postDM()`. iOS chat triggers real Slack posts.                           |
| Render paid tier         | ✅ Done          | No cold starts. Custom domain `ms-fixer.com`. Auto-deploy from `main`.                                                                     |
| Cloud storage (R2 or B2) | 🔲 Not started   | Replace local `uploads/` with Cloudflare R2 or Backblaze B2. Presigned URLs for upload + playback.                                          |
| Slack webhook (real)     | ✅ Done          | Real Slack bot integration via `server/src/lib/slack.js`. Bot "fixer-video" in Sea Lion Media workspace.                                    |
| TestFlight build         | ⚠️ Needs rebuild | Production URL changed to `ms-fixer.com`. New archive + upload to App Store Connect needed.                                                |
| Admin UI (expanded)      | ⚠️ Partial       | React dashboard running; needs asset detail, log persistence                                                                                |
| Stability (Phases A–C)   | ✅ Done          | WS reliability, upload resilience, security hardening. See `STABILITY_PLAN.md`.                                                             |
| WS auth logging          | ✅ Done          | Server logs auth rejections + Engine.IO connection errors. Commit `6e92dc2`.                                                                |
| iOS WS reconnect fix     | ✅ Done          | `disconnect()` cancels reconnect Task; `connectWebSocket()` disconnects before fresh connect. Commit `6e92dc2`.                             |
| Idempotent Mux upload    | ✅ Done          | Duplicate clip prevention on retry/reconnect. Commit `3fbb632`.                                                                             |
| Upload recovery prompt   | ✅ Done          | iOS prompts user to resume or discard interrupted uploads on relaunch.                                                                      |
| Re-upload (stuck/error)  | ✅ Done          | PHAsset auto-reconnect (3-tier), archive re-upload button, Swift 6 safe export                                                              |
| Archive status dots      | ✅ Done          | Green Ready, amber Needs Details, red Upload Failed, spinner Processing                                                                     |
| Archive thumbnails       | ✅ Done          | Mux thumbnails via AsyncImage in archive rows                                                                                               |
| Bubble tail removal      | ✅ Done          | Clean rounded rectangles, no tail triangles                                                                                                 |
| Launch screen            | ✅ Done          | LaunchBg color + Image asset via project.yml info section. Fixed Apr 8: image name mismatch + storyboard conflict.                          |
| ATS / Info.plist fix     | ✅ Done          | Proper NSAppTransportSecurity dict in Info.plist via xcodegen                                                                               |
| Form state persistence   | ✅ Done          | `PendingForm` persisted to disk; restored on relaunch if form not yet submitted.                                                            |
| VideoBubble merge        | ✅ Done          | Consolidated VideoPreviewBubble + SentUploadBubble into single phase-driven VideoBubble component.                                          |
| Video load optimization  | ✅ Done          | PHAsset zero-copy URL + PHAsset metadata. Minutes → instant for large videos.                                                               |
| WS mux:ready scoping    | ✅ Done          | Events scoped to asset owner's sockets only (was broadcasting to all clients).                                                              |
| Login input sanitization | ✅ Done          | Phone (10 digits) and PIN (8 digits) validation + numeric keypad.                                                                           |
| Form auto-focus          | ✅ Done          | @FocusState on slug field with 0.5s delay after sheet animation.                                                                            |
| Admin tools (nuclear)    | ✅ Done          | Nuclear reset wipes all data + Mux assets, preserves users, resets mediasource sequence. Admin create user.                                 |
| Transcription (Speech)   | ✅ Done          | On-device Apple Speech transcription. Opt-in toggle, dual-attempt (server + on-device), punctuation, domain vocabulary.                     |
| Render schema sync       | ✅ Done          | `render.yaml` buildCommand now includes `prisma db push --accept-data-loss` + `seed.js`. Previously only ran `prisma generate`.             |
| Real metadata extraction | ✅ Done          | iOS AVAsset extracts real metadata (not ffprobe — native iOS)                                                                               |
| Parallel form + upload   | 🔲 Not started   | Show form at upload start (not after); wait for both to finalize asset. Needed when real transcoding adds latency.                          |
| Ephemeral chat cleanup   | ✅ Done          | Option B: greeting, auto-reply, form-request, confirmation no longer persisted to DB — sent via WS only.                                    |
| Admin component refactor | ✅ Done          | AssetList + UserList extracted into modular sub-components (AssetRow, UserRow, StatusPill, UserDetails).                                     |
| Server input sanitization| ✅ Done          | Slug maxLength 50 + char strip; description maxLength 500 + control char strip. Server-side defense against bypassed client validation.      |
| Clip Viewer placeholder  | ✅ Done          | 16:9 shimmer placeholder + auto-polling status endpoint. Dynamically swaps to Mux player when ready — no reload.                            |
| Admin dashboard themes   | ✅ Done          | Three semantic CSS themes (Editorial, Lavender, Newsroom) with CSS custom property design tokens.                                           |
| Domain migration         | ✅ Done          | All references updated from rodgriola.com to ms-fixer.com across docs and server config.                                                    |
| Instructions UI overhaul | ✅ Done          | 5-page swipeable guide with SF Symbol icons, emoji rows, and "What's Happening" page                                                        |
| Device tracking          | ✅ Done          | iOS sends deviceId/deviceName/deviceModel in WS handshake auth; server logs per-device connections                                            |
| Per-device greeting      | ✅ Done          | Every iOS device gets its own greeting (multi-phone support)                                                                                   |
| formSlug in summary      | ✅ Done          | Slug name displayed in ConversationSummaryBubble via mux:ready payload                                                                         |

---

### 🔲 Milestone 7 — Production Hardening (Future)

**Target: TBD**

| Deliverable                      | Status         | Notes                           |
| -------------------------------- | -------------- | ------------------------------- |
| Device registration / MDM        | 🔲 Not started | Enterprise device control       |
| SMS/MMS fallback (Twilio)        | 🔲 Not started | Alternative upload path         |
| Rate limiting + abuse protection | ✅ Done        | `@fastify/rate-limit` (Phase C) |
| Multi-clip asset support         | 🔲 Not started | Multiple videos per asset       |
| Push notifications               | 🔲 Not started | Upload status, form reminders   |
| Audit logging                    | 🔲 Not started | Who did what, when              |

---

### 🔲 Milestone 8 — Onboarding & User Profile (Future)

**Target: TBD — UX planning phase**

#### Onboarding Flow

First-launch experience for new field crew members. The app should guide the user from "I just installed this" to "I'm uploading my first video" with minimal friction.

| Deliverable                         | Status         | Notes                                                                 |
| ----------------------------------- | -------------- | --------------------------------------------------------------------- |
| Welcome / splash screens            | 🔲 Not started | Brand intro, value prop ("Get your video to the newsroom in seconds") |
| Phone + PIN registration            | 🔲 Not started | Self-serve or admin-provisioned credentials                           |
| Permission grants (Photo Library, Speech) | ✅ Done       | `PermissionManager.swift` + ProfileView permission toggles with status dots and Settings redirect |
| Quick tutorial / first upload guide | 🔲 Not started | 3-4 swipeable cards showing the chat-based upload flow                |
| Server handshake verification       | 🔲 Not started | Confirm device can reach server, show green/red status                |
| Slack workspace connect prompt      | 🔲 Not started | Optional: "Connect Slack now?" during onboarding (skip for later)     |

#### User Profile & Credentials

A profile screen accessible from the chat header. Houses personal info, credentials, and third-party auth connections.

| Deliverable                       | Status         | Notes                                                               |
| --------------------------------- | -------------- | ------------------------------------------------------------------- |
| Profile screen (view/edit)        | ✅ Done        | User info card, permission toggles, app info, logout (ProfileView.swift) |
| Change PIN                        | 🔲 Not started | Requires current PIN to change                                      |
| Slack OAuth integration           | 🔲 Not started | "Connect Slack" button → OAuth flow → store workspace + user tokens |
| Slack connection status indicator | 🔲 Not started | Green/red dot on profile and chat header (is Slack connected?)      |
| Slack workspace/channel picker    | 🔲 Not started | After auth, pick default #channel for posts                         |
| Session management                | 🔲 Not started | View active sessions, logout from other devices                     |
| Notification preferences          | 🔲 Not started | Toggle push notifications, email alerts                             |

---

## Tech Stack (Current)

| Layer                | Technology                                   | Status           |
| -------------------- | -------------------------------------------- | ---------------- |
| **Server**           | Node.js + Fastify                            | ✅ Running       |
| **WebSocket**        | Socket.IO                                    | ✅ Running       |
| **Database**         | PostgreSQL (Prisma 7)                        | ✅ Running       |
| **ORM**              | Prisma (pg adapter)                          | ✅ Running       |
| **Auth**             | JWT (@fastify/jwt)                           | ✅ Running       |
| **Dashboard**        | React 19 + Vite 6 + TypeScript + Tailwind v4 | ✅ Running       |
| **Chat Demo**        | Vanilla HTML/CSS/JS                          | ✅ Complete      |
| **iOS App**          | SwiftUI + `URLSessionWebSocketTask`          | ✅ Core complete |
| **Web Viewer**       | Server-rendered HTML at `/clips/:slug`       | ✅ Working       |
| **Video Service**    | Mux (direct upload + HLS playback)           | ✅ Integrated    |
| **Storage**          | Cloudflare R2 or Backblaze B2 (planned)      | 🔲 Not started   |
| **Hosting (Server)** | Render (ms-fixer.com)                       | ✅ Live          |
| **Hosting (Web)**    | Vercel (planned)                             | 🔲 Not started   |
| **Slack**            | Bot API (`fixer-video` in Sea Lion Media)    | ✅ Integrated    |
| **Stability**        | STABILITY_PLAN.md Phases A–C                 | ✅ Complete      |

---

## Project Structure

```

Direct-Video-Uploader/
├── PROJECT_SPEC.md # Full project specification (v4)
├── PROJECT_STATUS.md # ← This file
├── package.json # Root scripts (npm run dev, build:admin, etc.)
├── chat-demo.html # Interactive chat UI demo
├── first-file.md # Initial project brief
├── .github/
│ └── copilot-instructions.md # Auto-loaded Copilot agent guide
├── scripts/
│ └── dev.js # Triad launcher (DB + Server + Admin)
├── admin/ # React admin dashboard (Vite + TypeScript)
│ ├── index.html # Vite entry point
│ ├── vite.config.ts # Vite config (proxy, Tailwind)
│ ├── tsconfig.json # TypeScript config
│ └── src/
│ ├── main.tsx # React entry point
│ ├── App.tsx # Dashboard layout + state
│ ├── lib/ # API client, types
│ ├── hooks/ # TanStack Query hooks, Socket.IO hook
│ └── components/ # Header, StatsGrid, UserList, AssetList, etc.
├── ios/
│ ├── project.yml # XcodeGen project definition
│ └── DirectVideoUploader/
│ ├── App/ # SwiftUI app entry, Theme.swift, DVUDateFormatting.swift
│ ├── Models/ # User, Asset, ChatMessage, ServerConfig
│ ├── Services/ # AuthService, ChatViewModel, WebSocketService, VideoUploadService, VideoMetadataExtractor
│ └── Views/ # Auth, Chat, Form, Metadata, Archive views
├── docs/
│ ├── PROJECT_SPEC_v1.md # Spec v1 (MMS approach)
│ └── PROJECT_SPEC_v2.md # Spec v2 (Direct Upload pivot)
└── server/
├── package.json # Node.js dependencies & scripts
├── prisma/
│ └── schema.prisma # Database schema (6 models, 5 enums)
├── prisma.config.ts # Prisma 7 config
├── .env # Environment variables (local)
├── public/ # Built admin dashboard (vite build output)
│ └── index.html # Served at / by Fastify
├── uploads/ # Local video storage (demo)
└── src/
├── index.js # Server entry point
├── seed.js # Demo user seeder
├── lib/
│ ├── prisma.js # Prisma client (pg adapter)
│ └── utils.js # PIN hashing, slug gen, ID gen
├── routes/
│ ├── auth.js # Login + profile + lastLoginAt tracking
│ ├── assets.js # Asset CRUD + upload + form + /mine
│ ├── admin.js # Triad status, stats, user/asset lists
│ ├── clips.js # Web clip viewer (GET /clips/:slug)
│ └── errors.js # Client error logging (POST + GET)
└── ws/
└── handler.js # WebSocket + client type tracking

```

---

## Demo Credentials

| User          | Phone        | PIN    | Role  |
| ------------- | ------------ | ------ | ----- |
| David Burgess | `5055034455` | `1234` | USER  |
| Carrie Smith  | `5055551234` | `1234` | USER  |
| Admin User    | `8001234567` | `0000` | ADMIN |
| Rod Griola    | `9176717330` | `3218` | ADMIN |

---

## Decision Log

| Date   | Decision                             | Rationale                                                                                                                                                                   |
| ------ | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Feb 28 | Pivot from MMS to Direct Upload      | MMS caps at 3.5 MB; direct upload gives full resolution + richer UX                                                                                                         |
| Mar 1  | "App IS a text conversation"         | Simplest mental model for field crew; reduces training friction                                                                                                             |
| Mar 1  | Mediasource Fixer branding           | Familiar identity for newsroom users                                                                                                                                        |
| Mar 2  | WebSocket (Socket.IO)                | Real-time bidirectional messaging; no polling overhead                                                                                                                      |
| Mar 2  | Fastify over Express                 | Faster, better plugin system, async-first                                                                                                                                   |
| Mar 2  | Prisma 7 with pg adapter             | Type-safe ORM, great migrations, Prisma 7 requires driver adapters                                                                                                          |
| Mar 2  | Render for hosting                   | WebSocket support, managed PostgreSQL, persistent services (vs Vercel serverless)                                                                                           |
| Mar 2  | Simple auth (Phone# + PIN)           | Demo-appropriate; no SMS verification overhead                                                                                                                              |
| Mar 2  | Local file uploads (demo)            | Production will use R2/B2; no cloud setup needed for Phase 1                                                                                                                |
| Mar 2  | Mock metadata (demo)                 | Production will use ffprobe; keeps Phase 1 simple                                                                                                                           |
| Mar 2  | Native WS over Socket.IO Swift       | `URLSessionWebSocketTask` with manual Socket.IO protocol framing; no third-party dependency                                                                                 |
| Mar 2  | `127.0.0.1` not `localhost`          | iOS Simulator resolves `localhost` to IPv6 `::1`; Node server binds IPv4 only                                                                                               |
| Mar 2  | Copilot instructions file            | Moved from `agent-guide.md` to `.github/copilot-instructions.md` (auto-loaded)                                                                                              |
| Mar 2  | DB pool size 5 → 20                  | Concurrent dashboard + WS queries exhausted small pool, causing 5s timeouts                                                                                                 |
| Mar 2  | `PhotosPicker` not `PHPicker`        | SwiftUI-native picker avoids UIKit bridging; `.videos` filter, `Transferable` protocol                                                                                      |
| Mar 2  | Stream multipart to temp file        | `VideoUploadService` writes multipart body to disk in 1MB chunks — avoids memory pressure                                                                                   |
| Mar 2  | Codable fields must be optional      | Server responses vary by endpoint; non-optional fields cause silent `JSONDecoder` failures                                                                                  |
| Mar 3  | React admin dashboard                | Replaced vanilla HTML with React 19 + Vite 6 + TypeScript + Tailwind v4 + TanStack Query                                                                                    |
| Mar 3  | Triad launcher (`scripts/dev.js`)    | Single `npm run dev` command orchestrates DB + Server + Admin with smart log filtering                                                                                      |
| Mar 3  | Live-only dashboard                  | Removed all simulated actions; dashboard shows only real data with neutral fallback states                                                                                  |
| Mar 3  | WS client type tracking              | Socket.IO connections tagged as `ios` or `admin`; enables accurate triad status reporting                                                                                   |
| Mar 3  | Remove client-side WS ping           | Engine.IO 4 uses server-initiated pings; client ping timer caused 25s disconnect loop                                                                                       |
| Mar 3  | `io.of('/').sockets.size` metric     | Replaced `engine.clientsCount` — gives accurate authenticated socket count, not transports                                                                                  |
| Mar 3  | Admin uses Admin User credentials    | Dashboard auto-logins as Admin User (`8001234567`) not David Burgess                                                                                                        |
| Mar 3  | Stale asset cleanup endpoint         | `POST /api/admin/cleanup-assets` — Prisma ORM delete of stuck UPLOADING assets                                                                                              |
| Mar 3  | Real file size in WS event           | iOS `FileManager.attributesOfItem` gets actual bytes before `sendVideoUpload`                                                                                               |
| Mar 3  | Server response intelligence         | Time-of-day greeting, debounce (3s window), personalization, fires once per session                                                                                         |
| Mar 3  | Remove auto-Slack post               | Replaced with explicit "Post to Slack" button — user controls when Slack is notified                                                                                        |
| Mar 3  | Real metadata via AVAsset            | iOS extracts duration, resolution, codec, GPS, device info natively — no ffprobe needed                                                                                     |
| Mar 3  | iOS form restructuring               | Read-only metadata fields above editable fields; MetadataView wired to show extracted data                                                                                  |
| Mar 3  | Web clip viewer (server-rendered)    | `GET /clips/:slug` — dark theme, metadata grid, video player, no auth required                                                                                              |
| Mar 3  | Separate Prisma queries              | `findFirst` with `include` times out in Prisma 7 + pg adapter — split into sequential calls                                                                                 |
| Mar 3  | `wildcard: false` on static          | `@fastify/static` was intercepting dynamic routes; fixed with wildcard option                                                                                               |
| Mar 3  | Admin links to clip viewer           | Asset list rows are `<a href="/clips/:slug">` opening in new tab                                                                                                            |
| Mar 3  | Git repo initialized                 | `.gitignore` (68 files committed), reference/design files excluded                                                                                                          |
| Mar 3  | Full 25-issue security/perf audit    | See `TODO.md` — 20 of 25 fixed. Covers auth, XSS, JWT, WS leaks, DB indexes, dead code                                                                                      |
| Mar 3  | Random JWT secret fallback           | `crypto.randomBytes(64)` when `JWT_SECRET` not set — warns in console                                                                                                       |
| Mar 3  | Admin route auth hardening           | All 7 admin routes now require JWT `preHandler`                                                                                                                             |
| Mar 3  | XSS escaping in clip viewer          | `escapeHtml()` on all user-controlled interpolations                                                                                                                        |
| Mar 3  | WS exponential backoff               | Max 10 retries, delay doubles each attempt (3s → 60s cap)                                                                                                                   |
| Mar 3  | URLSession leak fix                  | `invalidateAndCancel()` on reconnect + cleanup                                                                                                                              |
| Mar 3  | Upload handler DB optimization       | Merged 6 sequential queries → 3 (clip create with metadata, single asset update)                                                                                            |
| Mar 3  | DB indexes on FK columns             | `@@index` on `assets.userId`, `clips.assetId`, `chat_messages.userId`                                                                                                       |
| Mar 3  | Dead code removal                    | Removed `slack:post` handler, `greeting` handler, `sendFormSubmit`, `sendSlackPost`                                                                                         |
| Mar 3  | Selective dashboard invalidation     | `refreshDashboard(eventType)` invalidates only relevant query keys per socket event                                                                                         |
| Mar 4  | Client error logging to DB           | `POST /api/errors` persists iOS errors to `client_errors` table; `reportError()` utility                                                                                    |
| Mar 4  | View + Metadata buttons on High Five | Confirmation bubble has green View (opens clip) and blue Metadata (opens sheet) buttons                                                                                     |
| Mar 4  | View button URL string interpolation | `appendingPathComponent` percent-encodes slashes; switched to `URL(string:)` interpolation                                                                                  |
| Mar 4  | Random follow-up phrases (10)        | 1s after High Five, random `.greeting` bubble from 10 funny phrases using `randomElement()`                                                                                 |
| Mar 4  | Bottom tab bar (Chat \| Archive)     | `TabView` in `ContentView`; Archive fetches `GET /api/assets/mine` with expandable rows                                                                                     |
| Mar 4  | `FormResponse` model on Asset        | Codable struct for form response data; `Asset.formResponse` optional field for archive rows                                                                                 |
| Mar 4  | Render = preview environment         | Render deployment is a stand-in for company production; TestFlight couples with live stack                                                                                  |
| Mar 4  | `render.yaml` Blueprint              | Defines web service + PostgreSQL DB; auto-deploys from GitHub `main` branch                                                                                                 |
| Mar 4  | `render-build.sh` script             | Build: install deps, build admin, generate Prisma, push schema, seed DB — all in one                                                                                        |
| Mar 4  | SSL-aware pg Pool                    | `ssl: { rejectUnauthorized: false }` when `NODE_ENV=production` (Render managed PG)                                                                                         |
| Mar 4  | Conditional pino-pretty              | Pretty logs in dev, raw JSON in production (Render captures structured logs)                                                                                                |
| Mar 4  | `trustProxy` in production           | Fastify trusts Render's reverse proxy for correct client IP headers                                                                                                         |
| Mar 4  | `url(for:)` string interpolation     | ServerConfig.url(for:) switched from `appendingPathComponent` to `URL(string:)` for safety                                                                                  |
| Mar 4  | `.env.example` for documentation     | Template with all env vars (DB, auth, Slack, Mux, R2) — gitignored `.env` stays local                                                                                       |
| Mar 10 | UIVideoEditorController modal host   | Embedding UIVideoEditorController as UIViewControllerRepresentable crashes (UINavigationController subclass must be presented modally). VideoEditorHostController wraps it. |
| Mar 10 | CSP: `*.edgemv.mux.com` wildcard     | Helmet's `*.mux.com` wildcard doesn't match multi-level subdomains. HLS segments served from `chunk-gcp-us-east4-vop1.edgemv.mux.com` require explicit allowlist.           |
| Mar 10 | COEP disabled, CORP cross-origin     | Clip viewer loads cross-origin media/scripts from Mux CDN + jsdelivr. Helmet defaults (`same-origin`) block those fetches.                                                  |
| Mar 10 | WS `connect()` guard fix             | `isReconnecting` flag blocked fresh token from `connect(token:)`. Fix: `disconnect()` cancels `connectTask`, resets `isReconnecting`, then connects.                        |
| Mar 10 | Server WS auth logging               | Auth middleware had zero logging — auth failures invisible in Render logs. Added `console.warn` on rejection + Engine.IO `connection_error` handler.                        |
| Apr 8  | PHAsset zero-copy video loading      | `loadTransferable` copies entire video file (minutes for 1GB+). `PHImageManager.requestAVAsset` returns direct AVURLAsset reference — instant, same as native iOS Photos. |
| Apr 8  | PHAsset metadata over file I/O       | Duration, resolution, GPS, creation date read from PHAsset cached properties instead of AVAsset file reads. Only codec needs lightweight header read.                       |
| Apr 8  | iPhone format conversion setting     | iOS "Most Compatible" setting transcodes HEVC → H.264 on every share. "Current" skips transcoding. Must be communicated to end users.                                    |
| Apr 8  | User-scoped WebSocket events         | `mux-sync.js` now accepts `fastify` instance and emits `mux:ready` only to the asset owner's sockets, not all connected clients.                                          |
| Apr 8  | VideoBubble phase enum               | Single component with `.staged`/`.uploading`/`.sent` phases replaces two separate bubble views. Reduces code duplication.                                                  |
| Apr 8  | Launch screen config cleanup         | `UILaunchStoryboardName` + `UILaunchScreen_*` keys conflict — removed storyboard ref, corrected image name to match asset catalog.                                        |
| Apr 9  | Server-side slug sanitization        | Client-side validation insufficient — API calls can bypass iOS app entirely. Server now enforces maxLength + character whitelist on slug and description.                   |
| Apr 9  | Clip viewer auto-polling             | Static "not yet available" text replaced with 16:9 placeholder + `/status` JSON endpoint. Client polls every 5s, dynamically loads Mux SDK and swaps player in-place.     |
| Apr 9  | Admin modular architecture           | Monolithic list components (350+ lines each) extracted into focused sub-components. Data-driven rendering with shared utility functions.                                   |
| Apr 9  | CSS design token themes              | Dashboard styling moved from hardcoded values to CSS custom properties. Three theme files enable visual switching without code changes.                                    |
| Apr 9  | Transcribe toggle solid backgrounds  | Semi-transparent pill backgrounds (opacity 0.15) replaced with solid white/green for clearer on/off distinction against dark video bubble gradient.                        |
| Apr 10 | iOS PermissionManager                | Pre-authorizing Photo Library + Speech Recognition in Profile tab eliminates mid-upload permission dialogs. iOS only prompts once — users set it and forget it.            |
| Apr 10 | ProfileView rebuild                  | Minimal logout-only view replaced with user info + permission toggles + app info. Status dots reflect live OS state; refresh on foreground return catches Settings changes. |
| Apr 10 | ITSAppUsesNonExemptEncryption        | Must be `false` in both `Info.plist` and `project.yml info.properties`. Skips Apple export compliance questionnaire — app uses no non-exempt encryption.                  |
| Apr 10 | UIDevice await removal               | `UIDevice.current.model/.systemVersion` no longer require `await` in current Swift 6 SDK. Compiler warnings removed.                                                      |
| Apr 10 | ChatViewModel state consolidation    | 30+ loose properties → `ArchiveState`, `FormContext` structs. `startNewConversation()` reset reduced from 15 nils to 2 struct resets.                                       |
| Apr 10 | SentUploadInfo struct                | 4 parallel dictionaries (`sentUploadThumbnails`, `sentUploadFileNames`, etc.) merged into single `[String: SentUploadInfo]`. Impossible to get out of sync.                  |
| Apr 10 | RetryHelper.swift                    | Generic `withRetry(attempts:delay:)` extracted from inline 77-line retry loop in `createAsset()`. `@MainActor` for Swift 6 Sendable compliance.                              |
| Apr 10 | .systemNote message type             | New `SYSTEM_NOTE` type for informational bubbles (form-skip, tips). Fixes `.greeting` overload that was used for 3 unrelated purposes.                                       |
| Apr 10 | Upload cancellation                  | `cancelUpload()` added with `Task` handle + `Task.isCancelled` check between upload and transcription steps.                                                                  |
| Apr 10 | Server greeting system               | 10 greeting templates × 4 time-of-day variants (40 combos) with no-consecutive-repeat logic. Feature-tip second bubble sent 500ms after greeting.                             |
| Apr 10 | Admin build optimization             | `npm run build` now runs Vite only (5s). `npm run build:check` does tsc+Vite (95s). `tsc` was bottlenecked by 92% full disk.                                                  |
| Apr 11 | Instructions 4→5 pages              | "What's Happening Inside Fixer" content moved to its own page. Steps page cleaned to icon-only rows. Better content separation.                                              |
| Apr 11 | SF Symbol instruction icons          | Replaced numbered steps and emoji placeholders with actual SF Symbol icons matching the app UI (`plus.circle.fill`, `checkmark.circle.fill`, etc.).                           |
| Apr 11 | First-name only greeting             | `socket.userName.split(' ')[0]` extracts first name. Greetings say "Rod" not "Rod Griola".                                                                                    |
| Apr 11 | Per-device greeting                  | Removed `iosCountForUser <= 1` gate. Every iOS device gets greeted independently. Multi-phone uploading is a feature, not an edge case.                                      |
| Apr 11 | Device tracking in WS handshake      | iOS sends `deviceId` (identifierForVendor), `deviceName`, `deviceModel` in Socket.IO auth. Server stores on socket, logs device name on connect. DB persistence deferred.    |
| Apr 11 | formSlug wired end-to-end            | `mux:ready` payload now includes `formSlug`. Flows through ArchiveState → ChatView → ConversationSummaryBubble with `tag.fill` icon.                                        |
| Apr 11 | ConversationSummaryBubble cleanup    | Removed dead `formType` prop, surfaced `formDescription`/`formPriority`, simplified `buildDetailsString` with `compactMap`, removed unnecessary `@ViewBuilder`.              |
| Apr 11 | Shared ISO8601DateFormatter          | 12 separate `ISO8601DateFormatter()` allocations replaced with single `private static let`. Thread-safe, zero runtime cost. Same pattern as `DVUDateFormatting.isoBasic`.     |
| Apr 11 | Dead field removal (form fields)     | `formType`/`formDescription`/`formPriority` removed from `ArchiveState`, `MessageContent`, and 3 WS handlers. Were parsed but never displayed after summary bubble cleanup. |
| Apr 11 | @State over @AppStorage for transcribe | `@AppStorage` remembers across videos — wrong UX since most videos don't need transcription. `@State` resets to off per video, user opts in explicitly.                    |
| Apr 11 | Standardized .position() in TrimView | Mixed `.position()` and `.offset()` in same ZStack caused alignment inconsistencies. All overlays now use `.position(x:y:)` for uniform coordinate system.                  |
| Apr 11 | AVAudioSession deactivation          | Trim screen activates `.playback` session but never deactivated it. `.notifyOthersOnDeactivation` lets other audio apps resume correctly.                                   |
| Apr 12 | RowStatus enum in ArchiveRowView     | Replaces two parallel if-else chains (badge + action buttons) that each re-evaluated identical conditions. Enum is exhaustive — compiler forces new states to be handled.    |
| Apr 12 | Continuation guard in phAssetToTempFile | `PHImageManager.requestAVAsset` can fire callback twice for iCloud assets. Second `continuation.resume()` is a guaranteed crash. `var resumed = false` guard prevents it. |
| Apr 12 | loadTransferable → PHAsset fast path | `handleReupload` was loading entire video into RAM as `Data`. PHAsset path uses `requestAVAsset` for a direct file reference (zero copy). Same fix applied to `VideoLibraryView` Apr 8. |
| Apr 12 | FormField.defaultVideoFields()       | Both `ChatViewModel` and `ArchiveRowView` had identical `buildFormFields()` implementations. Static extension on `FormField` is the shared source — adding a field in one place covers both. |
| Apr 12 | auth.authenticatedRequest everywhere | Raw `URLRequest` + manual Bearer header in `ArchiveRowView` and `ArchiveListView` bypassed the centralized auth helper. If auth scheme changes, these would have been missed. |
| Apr 12 | Photos tab placeholder               | TBD feature needs a registered tab view before implementation. Placeholder matches visual style of Archive/Profile and documents planned feature rows for team reference.    |

---

## Security & Performance Audit (Mar 3, 2026)

**25 issues identified, 20 fixed, 5 deferred.** See `TODO.md` for full tracker.

**Critical fixes (6):** fileSize type mismatch, WS reconnect backoff, URLSession leak, admin route auth, XSS in clip viewer, JWT secret randomization.

**Performance fixes (5):** Selective query invalidation, 15s triad polling (was 5s), upload handler 6→3 DB calls, FK indexes added, mediasource ID sequence simplified.

**Consistency fixes (5):** Removed all dead WS handlers (greeting, form:submit, slack:post), safe JSON serialization in WS sends, ping timeout/interval swap.

**Lower priority fixes (4):** Temp file cleanup, pool error logging, asset detail auth, mediasource sequence.

**Deferred (5):** VideoUploadService session leak (#19), upload progress polling (#20), rate limiting (#22), CORS config (#24), admin chat history (#25).

**Files modified (16):** Asset.swift, MetadataView.swift, WebSocketService.swift, ChatViewModel.swift, ChatView.swift, admin.js, clips.js, index.js, use-dashboard.ts, App.tsx, use-socket.ts, assets.js, schema.prisma, utils.js, prisma.js, handler.js.

---

## Next Actions

### Now — Phase 3: Live Demo Stack

1. ~~**Deploy server to Render**~~ — ✅ Done.
2. **Cloud storage (Cloudflare R2 or Backblaze B2)** — Replace local `uploads/` directory. Implement presigned upload URLs so iOS uploads directly to cloud. Presigned read URLs for clip viewer playback.
3. ~~**Mux video streaming**~~ — ✅ Done. Direct upload + HLS playback + webhook pipeline.
4. ~~**Update iOS `ServerConfig` for Render**~~ — ✅ Done.
5. **TestFlight build** — With live Render backend, Mux streaming, and stability fixes.
6. ~~**Stability Plan Phases A–C**~~ — ✅ Done. See `STABILITY_PLAN.md`.
7. ~~**Idempotent Mux upload + recovery**~~ — ✅ Done. Duplicate clip prevention, form persistence. Upload recovery prompt removed Mar 9 (replaced by simplified single-path upload with background URLSession).
8. **Stability Phase D** — WebSocket-only transport, temp file cleanup, replace admin raw SQL.

### Soon — Polish & Integrations

9. **End-to-end production testing** — Full flow on live stack (login → upload → background → resume → form → clip viewer → Slack)
10. **Deferred security items** — JWT expiry shortening (C6), CORS tightening

### Later — Production Hardening

9. **Parallel form + upload** — Show form at upload start, finalize when both complete (needed with real transcoding latency)
10. **Push notifications** — Upload status, form reminders
11. **Onboarding flow** — First-launch experience (Milestone 8)
