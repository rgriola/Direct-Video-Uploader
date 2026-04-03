# Agent Guide — Fixer (formerly Direct Video Uploader)

> **App Name:** Fixer — use this name in all user-facing UI (titles, headers, alerts, about screens).
> Auto-loaded by GitHub Copilot. Keep concise — every line here costs context on every prompt.

---

## Dev Server Startup

- Check if port 3000 is in use before starting dev server.
- Test API endpoints with `curl`.
- Keep `PROJECT_SPEC.md`, `PROJECT_STATUS.md`, and this file up to date.
- run npm run dev from the root.

## Live Host

- RENDER PAID ACCOUNT (no cold starts)
- Custom domain: `ms-fixer.com`
- Auto-deploys from `main` branch

---

## Github

- https://github.com/rgriola/Direct-Video-Uploader.git

## Prisma 7 — Key Gotchas

1. **Database URL** must be in `prisma.config.ts`, NOT in the `schema.prisma` datasource block.
2. **Driver adapter** is required — we use `@prisma/adapter-pg` with the `pg` library.
3. **Constructor** uses `new PrismaClient({ adapter })` — no `datasourceUrl` in constructor.
4. **Local dev database**: Homebrew PostgreSQL (`postgresql://rodczaro@localhost:5432/directvideo`). Do NOT use PGlite (`npx prisma dev`) — it breaks Prisma Studio introspection.

---

## Naming Conventions — Prisma ↔ PostgreSQL

**Critical rule**: In raw SQL, use **PostgreSQL snake_case** column/table names, NOT Prisma camelCase. See `server/prisma/schema.prisma` for all `@map()` / `@@map()` annotations.

```javascript
// ✅ Prisma ORM — camelCase
const users = await prisma.user.findMany({
  where: { phoneNumber: "5055034455" },
});

// ✅ Raw SQL — snake_case tables & columns
const result = await prisma.$queryRawUnsafe(
  `SELECT COUNT(*)::int FROM users WHERE status = 'ACTIVE'`,
);

// ❌ WRONG — Prisma model names in raw SQL (will fail)
// SELECT COUNT(*) FROM "User"
```

---

## Codebase Conventions

- **ES Modules only** — use `import`/`export`, never `require()`.
- **Fastify plugin pattern** — routes export `async function(fastify)`, registered via `fastify.register()`.
- **Auth guard** — protected routes use `preHandler: [fastify.authenticate]`.
- **BigInt serialization** — call `fileSize?.toString()` before including in JSON responses.
- **Socket.IO push** — look up `fastify.userSockets?.get(userId)` to push events to connected clients.
- **WS auth** — JWT token from `socket.handshake.auth?.token`, same secret as HTTP routes.
- **Chat persistence (Option B)** — only persist meaningful events: user `TEXT` (outgoing), `FORM_SUBMITTED`. Ephemeral messages (greeting, auto-reply, form-request, confirmation) are sent via WebSocket only — never written to `chat_messages`.
- **DB pool** — `pg.Pool` with `max: 20` connections. Pool was 5, caused timeouts on concurrent requests.
- **Server auto-reply** — `message:send` handler replies to plain text with "send me your videos!"; Slack commands (e.g., `#team-alerts @carrie`) trigger `slack:post`.
- **Background jobs** — `server/src/jobs/mux-sync.js` runs on an interval after `fastify.listen()`. Start in `start()`, stop in `shutdown()`. Pattern: export `startXxx(io)` / `stopXxx()`.

---

## iOS App — Key Gotchas

1. **Simulator networking** — use `127.0.0.1`, NOT `localhost`. Simulator resolves `localhost` to IPv6 `::1`, but Node server binds IPv4 only.
2. **Physical device** — uses Mac's LAN IP. `ServerConfig.swift` uses `#if targetEnvironment(simulator)` to auto-switch.
3. **WebSocket** — native `URLSessionWebSocketTask` with manual Socket.IO protocol framing (no third-party library).
4. **`@Observable` macro** — class must be `@MainActor @Observable final class`. Don't use `nonisolated(unsafe)` on stored properties — the macro conflicts with it.
5. **Codable models** — server may return fewer fields than the model defines. Use optionals (`String?`, `Int?`) for fields that aren't always present (e.g., `User.status`, `Asset.clipCount`). Non-optional fields cause silent `JSONDecoder` failures.
6. **XcodeGen** — run `xcodegen generate` after adding new `.swift` files. The `project.yml` sources the entire `DirectVideoUploader/` directory.
7. **Build with Xcode CLI** — `xcodebuild -project DirectVideoUploader.xcodeproj -scheme DirectVideoUploader -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
8. **PhotosPicker** — SwiftUI-native `PhotosPicker` with `.videos` filter and `Transferable` protocol. Reset `selectedPhotoItem` to `nil` after processing.
9. **Video uploads (simplified Mar 9)** — Single upload path: iOS → `POST /api/assets/:id/mux-upload` for URL → PATCH bytes directly to Mux CDN via tus protocol. Uses `URLSessionConfiguration.background` with `sessionSendsLaunchEvents = true` and `waitsForConnectivity = true`. iOS handles network interruptions natively — no custom resume/offset logic needed.
10. **PendingForm** — Codable struct saved to `Documents/pending-form.json`. Stores `assetId`, `originalFileName`, `capturedAt`, `clipCount`, `duration`, `thumbnailJPEG`, `savedAt`. Saved on `form:request`, cleared on submit. Restored on relaunch if form not yet submitted.
11. **No PendingUpload** — Removed Mar 9. Upload recovery via tus resume was over-engineered for demo phase. If upload is interrupted, user simply re-uploads. Background URLSession + `waitsForConnectivity` handles 95% of real-world interruptions automatically.
12. **Theme.swift** — All colors centralized in `Theme` enum (`Theme.blue`, `Theme.cardBg`, etc.). Never use `Color(hex: "...")` directly in views — add a constant to Theme.swift instead.
13. **DVUDateFormatting.swift** — Cached date/time formatters. Use `DVUDateFormatting.longDate(_:)`, `.duration(_:)`, `.fileSize(_:)`, etc. Never create inline `DateFormatter` or `ISO8601DateFormatter` instances.
14. **UserDefaultsKeys** — Enum in `ServerConfig.swift`. Use `UserDefaultsKeys.authToken` / `.serverURL` instead of hardcoded strings.
15. **Clip URLs** — Use `ServerConfig.clipURL(_:slug)` to build clip viewer URLs. Never hand-build `/clips/` URLs inline.
16. **Re-upload (PHAsset auto-connect)** — `PHAssetIdentifierStore` in `VideoUploadService.swift` persists `[assetId: phAssetIdentifier]` to `Documents/phasset-identifiers.json`. `ArchiveRowView.handleAutoReupload()` uses 3-tier lookup: stored PHAsset ID → auto-discovery by `capturedAt` ±2s → PhotosPicker fallback.
17. **Swift 6 + PHImageManager** — `PHImageManager.requestAVAsset` callback runs on a background queue. Never call it from inside a `@MainActor` View struct's method — move export logic to a standalone file-scope `async` function to avoid actor isolation conflicts.
18. **Info.plist / ATS** — `INFOPLIST_KEY_NSAppTransportSecurity_AllowsArbitraryLoads` build setting does NOT work for nested plist dictionaries. Use `info:` section in `project.yml` with `NSAppTransportSecurity: { NSAllowsArbitraryLoads: true, NSAllowsLocalNetworking: true }` instead.
19. **Archive status cascade** — ArchiveRowView status dot/button logic follows strict if/else order: needsDetails → amber | error/stuckProcessing → red | isReuploading → spinner | processing → spinner | else → green Ready. Always check `.error` status explicitly — it won't match `.processing`.
20. **Transcription** — `TranscriptionService.swift` uses `SFSpeechRecognizer` with dual-attempt strategy: server-based first, on-device fallback. `addsPunctuation = true` for sentence formatting. `contextualStrings` for newsroom terms. Opt-in via Transcribe toggle on `VideoPreviewBubble`. Saves via `PATCH /api/assets/:id/transcript` to `clips.transcript` + `clips.transcript_segments`.
21. **WS greeting** — Server greeting uses `iosSockets` count per user (not total `userSockets`) to decide if it's a fresh connection. Admin dashboard sockets must not block the iOS greeting.

---

## Mux Integration — Key Gotchas

1. **SDK version** — `@mux/mux-node` v12+. Instance methods, NOT static. `new Mux()` then `muxClient.video.assets.retrieve()` etc.
2. **Webhook signature** — `muxClient.webhooks.verifySignature()` (instance method). NOT `Mux.Webhooks.verifySignature()` (old static API, does not exist in v12).
3. **Direct upload** — iOS uploads directly to Mux CDN via `createDirectUpload()`. Server creates clip in PROCESSING state.
4. **Webhook events** — `video.upload.asset_created` links muxAssetId, `video.asset.ready` sets clip+asset to READY, `video.asset.errored` sets ERROR.
5. **Background sync** — `server/src/jobs/mux-sync.js` polls Mux every 2min for stuck PROCESSING clips (fallback if webhooks fail). No-asset clips auto-error after 15min. Alerts via Slack.
6. **Mux helpers** — `server/src/lib/mux.js` exports `getMuxAsset()`, `getMuxUpload()`, `createDirectUpload()`, `deleteMuxAsset()`, `listMuxAssets()`, `ingestVideo()`, `isMuxEnabled`, `MUX_ENV_KEY`.
7. **Upload idempotency** — `POST /api/assets/:id/mux-upload` only reuses existing Mux upload if `status === 'waiting'`. Stale uploads (any other status) are deleted and recreated.
8. **Clip ordering** — All clip queries must use `orderBy: { createdAt: 'desc' }` to return newest clip first. Without this, re-uploaded assets show the old ERROR clip instead of the new READY one.

---

## Slack Integration

- **Module:** `server/src/lib/slack.js` — exports `isConfigured()`, `postToChannel()`, `postDM()`, `buildAssetMessage()`.
- **Bot name:** "fixer-video" (Sea Lion Media workspace).
- **Chat trigger:** User types `#channel-name @user` in iOS chat → server posts to Slack via bot token.
- **Alerting:** Background jobs use `postToChannel('general', ...)` for error alerts.

---

## API Naming

- Routes: `/api/kebab-case` (e.g., `/api/admin/simulate-upload`)
- JSON response keys: `camelCase` (e.g., `mediasourceId`, `clipCount`)

---

## Deployment

- **Vercel** → Web UI / Clip Viewer
- **Render** → Server + PostgreSQL + WebSocket
- **Render buildCommand** must include `npx prisma db push --accept-data-loss` to sync schema changes to production DB. Without it, new columns exist in Prisma Client but not PostgreSQL → P2022 errors.
- **Render `render.yaml`** buildCommand: `npm ci --include=dev && cd ../admin && npm ci --include=dev && npm run build && cd ../server && npx prisma generate && npx prisma db push --accept-data-loss && node src/seed.js`

---

## Demo Credentials

| User          | Phone        | PIN    | Role  |
| ------------- | ------------ | ------ | ----- |
| David Burgess | `5055034455` | `1234` | USER  |
| Carrie Smith  | `5055551234` | `1234` | USER  |
| Admin User    | `8001234567` | `0000` | ADMIN |
| Rod Griola    | `9176717330` | `3218` | ADMIN |

---

## Key References

- `PROJECT_SPEC.md` — Full architecture, data model, endpoint catalog
- `PROJECT_STATUS.md` — Current progress, milestones, verified features
- `server/prisma/schema.prisma` — Source of truth for all Prisma ↔ PostgreSQL field mappings
- `server/src/lib/mux.js` — Mux SDK wrapper (direct upload, asset/upload retrieval)
- `server/src/lib/slack.js` — Slack bot integration (channel posts, DMs, alerts)
- `server/src/jobs/mux-sync.js` — Background worker for stuck PROCESSING clips
- `server/src/routes/mux-webhooks.js` — Mux webhook handler + polling fallback
- `server/src/routes/admin.js` — Admin endpoints: stats, users, assets, nuclear reset, create user
- `ios/DirectVideoUploader/Services/TranscriptionService.swift` — Apple Speech transcription (dual-attempt, punctuation, domain vocabulary)
- `docs/APPLE_SPEECH_IMPLEMENTATION.md` — Transcription implementation plan + agent prompts
