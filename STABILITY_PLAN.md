# Stability Improvement Plan — Direct Video Uploader

> **Date:** March 8, 2026
> **Scope:** WebSocket reliability, video upload resilience, security hardening
> **Out of scope (deferred):** Auth/user profiles, Slack profile connection (company system dependency)

---

## Why This Matters

Every item below protects the same thing: **user confidence**.

- When a crew member uploads a clip, they need to know it arrived.
- If the app says "uploaded" — it must be uploaded.
- If the connection drops — the app recovers silently.
- If the phone locks — the upload continues.
- Fixer's reputation lives or dies on this promise.

---

## Part 1 — WebSocket Connection Stability

### Current State

The iOS WebSocket (`WebSocketService.swift`) implements Socket.IO manually over `URLSessionWebSocketTask`. The flow is: HTTP polling handshake → WebSocket upgrade → Engine.IO probe → Socket.IO auth → connected. Reconnect uses exponential backoff (3s → 60s cap, 10 max attempts).

### Findings & Fixes

#### 1.1 No App Lifecycle Awareness — `CRITICAL`

**Problem:**
No `@Environment(\.scenePhase)` observer anywhere in the app. When iOS suspends the app (background/lock screen), the WebSocket dies silently. When the user returns, the app shows a stale "connected" state. The next message they send vanishes into a dead socket.

**Fix:**
Add `scenePhase` observer to `ContentView.swift`:

- On `.active` → check `ws.state`, reconnect if disconnected, reset retry counter
- On `.background` → optionally send graceful close (saves server resources)
- On `.inactive` → no action (transient state during app switcher)

**Complexity:** Small — ~15 lines of SwiftUI code

---

#### 1.2 No Message Queue or Retry — `CRITICAL`

**Problem:**
`sendMessage()` and `sendVideoUpload()` are fire-and-forget. If the WebSocket is disconnected or mid-reconnect, the send fails silently — the message is lost permanently. The user sees nothing - the media manager on backend sees nothing.

**Fix:** Add a pending-message queue to `WebSocketService`:

- Buffer outgoing events when `state != .connected`
- Flush queue in FIFO order upon successful reconnect (after Socket.IO ACK)
- Cap queue size (e.g., 20 items) to prevent unbounded growth. XXXX SEE > CAP QUEUE
- Show a subtle "sending…" indicator in chat when messages are queued

**Complexity:** Medium — new queue property, modified `sendRaw()`, flush logic in connect ACK handler

---

#### 1.3 Dead-End After Max Retries — `HIGH`

**Problem:** After 10 failed reconnect attempts, `onConnectionLost` fires. The user sees "Please check your network and restart the app." There is no recovery path — the WebSocket is permanently dead until the app is killed and relaunched.

**Fix:** After max retries, switch to passive monitoring via `NWPathMonitor`:

- Watch for network path becoming `.satisfied`
- On restoration → reset retry counter, attempt fresh connect
- Show a "Tap to reconnect" button in the chat UI as immediate option
- Continue background monitoring even if user doesn't tap

**Complexity:** Small — `NWPathMonitor` is ~20 lines, plus a UI button

---

#### 1.4 `sendRaw` Errors Don't Trigger Reconnect — `HIGH`

**Problem:** The completion handler in `sendRaw()` only prints the error. A send failure doesn't mark the connection as broken. Subsequent sends continue hitting a dead socket until the receive loop eventually fails (which could take up to `pingTimeout` — 25 seconds).

**Fix:** On `sendRaw` error:

1. Call `cleanupConnection()`
2. Trigger reconnect flow
3. Queue the failed message for retry

**Complexity:** Small — modify `sendRaw` completion handler

---

#### 1.5 No Client-Side Health Check — `MEDIUM`

**Problem:** Engine.IO pings are server-initiated only. iOS has no way to proactively detect a zombie connection where TCP is broken but the receive loop hasn't errored yet.

**Fix:** Add a client-side watchdog timer:

- Reset a 45-second timer every time a server ping (`2`) is received
- If timer fires without a ping → connection is zombie → trigger cleanup + reconnect
- 45s chosen because server sends pings every 20s with 25s timeout

**Complexity:** Small — one `Timer` or `Task.sleep` loop

---

#### 1.6 Reconnect Race Condition — `MEDIUM`

**Problem:** `connect()` guards on `state == .disconnected`, but `cleanupConnection()` sets state to `.disconnected` while the async reconnect delay (`Task.sleep`) is still in flight. A second caller (e.g., a future scenePhase observer) could start a parallel connection attempt.

**Fix:** Add a `reconnecting` state to `ConnectionState` enum, or use a simple `isReconnecting` boolean guard checked before any `connect()` call.

**Complexity:** Small — one new guard flag

---

#### 1.7 Two-Step Handshake — `LOW`

**Problem:** The HTTP polling request (to get SID) is a separate network round-trip that can fail independently. Socket.IO supports `transports: ['websocket']` to skip polling entirely.

**Fix:** Set `transports: ['websocket']` on server Socket.IO config. Modify iOS `performHandshake()` to send SID request as WebSocket frame instead of HTTP. Reduces one failure point and one network round-trip.

**Complexity:** Medium — requires handshake rewrite for websocket-only mode. Consider deferring. XXX defer

---

### Part 1 Implementation Order

| Priority | Item                         | Risk Removed                                       |
| -------- | ---------------------------- | -------------------------------------------------- |
| P0       | 1.1 scenePhase observer      | Silent zombie connections on foreground return     |
| P0       | 1.2 Message queue            | Lost messages during disconnection                 |
| P1       | 1.3 NWPathMonitor recovery   | Dead-end after max retries                         |
| P1       | 1.4 sendRaw reconnect        | 25s delay before detecting dead connection on send |
| P2       | 1.5 Client health check      | Zombie connection detection                        |
| P2       | 1.6 Reconnect guard          | Parallel connection race                           |
| P3       | 1.7 WebSocket-only transport | Extra failure point in handshake                   |

---

## Part 2 — Video Upload Resilience

### Current State

Videos upload through `VideoUploadService.swift` using a delegate-based `URLSession.uploadTask`. The session uses `.default` configuration — **not background**. Upload progress is tracked in memory only. If the app is backgrounded, killed, or the network drops — the upload fails and the user must start over. XXX serious issue

Upload flow: `stageVideo()` → `confirmStagedUpload()` → `createAsset()` (3 retries with backoff) → `uploadVideo()` (try primary method, fallback to alternate) → `uploadWithProgress()` (single attempt, no retry).

### Findings & Fixes

#### 2.1 No Background Upload Support — `CRITICAL`

**Problem:** `URLSession(configuration: .default)` terminates upload tasks ~30 seconds after the app enters background. Users who lock their phone or switch apps during a large video upload will lose the entire upload. This is the single biggest reliability gap in the app.

**Fix:** Switch to `URLSessionConfiguration.background(withIdentifier:)`:

- Background sessions let iOS manage the upload in a separate daemon process
- Upload continues even if the app is suspended or terminated by the OS
- Requires:
  1. `URLSessionConfiguration.background(withIdentifier: "com.directvideo.upload")`
  2. `config.isDiscretionary = false` (upload immediately, not at iOS's discretion)
  3. `config.sessionSendsLaunchEvents = true`
  4. Handle `application(_:handleEventsForBackgroundURLSession:completionHandler:)` in app delegate
  5. Store upload metadata (assetId, fileName) to UserDefaults so the app can reconcile on relaunch
- **Note:** Background sessions require file-based uploads (not data streams) — already the case with `uploadTask(with:fromFile:)`. XXX Does this mean videos stored on the phone may need to download to the phone first then upload? Right now these uploads orginate from the photolibrary on iOS. I'm just curious since I know iCloud works silently moving videos/photos off the device to the cloud unless explictly set not to do so. This may need User Education so video stay on a device.

**Complexity:** Medium-Large — requires app delegate changes, state persistence, and completion reconciliation

---

#### 2.2 No Upload Resume / Resumable Uploads — `HIGH`

**Problem:** If a 200MB upload fails at 80%, the entire file must be re-uploaded from byte 0. Neither the server upload route nor the Mux direct upload supports resumable transfers.

**Fix (Server Upload):** Implement chunked/resumable upload:

- Option A: `tus` protocol (open standard for resumable uploads) — libraries exist for both Swift and Node.js
- Option B: Byte-range uploads — iOS sends `Content-Range` header, server appends to partial file
- Either approach requires tracking upload progress server-side (bytes received per clipId)

**Fix (Mux Direct Upload):** Mux's direct upload API already supports resumable uploads via `tus` protocol. The current implementation uses a single PUT — switch to the Mux `tus` endpoint for automatic resume capability.

**Complexity:** Large — requires protocol changes on both sides. Can be phased: start with Mux tus (smaller change), then server-side tus.

---

#### 2.3 Upload State Not Persisted — `HIGH`

**Problem:** Upload progress, staged video reference, and asset ID are all in-memory `@Observable` properties. If the app crashes or is killed:

- `stagedVideo` is lost — user must re-pick the video
- `uploadProgress` resets to 0
- `currentAssetId` is lost — orphaned asset in UPLOADING state on server
- No way to resume or reconcile

**Fix:** Persist upload state to disk:

- On `createAsset()` success → write `{ assetId, fileName, fileURL, status }` to a JSON file in the app's documents directory (or UserDefaults for simplicity)
- On app launch → check for pending uploads, offer to resume or clean up
- On upload complete → delete persisted state
- Server already tracks asset status (UPLOADING/PROCESSING/READY) — iOS just needs to ask "do I have an incomplete upload?"

**Complexity:** Medium — file I/O + launch-time reconciliation logic

---

#### 2.4 Network Interruption During Upload — `HIGH`

**Problem:** `uploadWithProgress()` has zero retry logic. A momentary network blip (cellular handoff, WiFi flicker) fails the entire upload immediately. The delegate's `didCompleteWithError` fires and the error propagates up.

**Fix (Short-Term):** Add `waitsForConnectivity = true` to URLSession config:

- iOS automatically pauses and resumes the task when connectivity is restored
- No code changes to the upload logic itself
- Works with both `.default` and `.background` configurations

**Fix (Long-Term):** Combine with 2.2 (resumable uploads) for full network resilience.

**Complexity:** Trivial for `waitsForConnectivity` — one line. Combine with 2.1 for background sessions.

---

#### 2.5 Orphaned Server-Side State — `MEDIUM`

**Problem:** If iOS crashes after `createAsset()` but before upload completes:

- Asset remains in `UPLOADING` status in the database indefinitely
- If upload partially completes: partial file on disk in `uploads/`, never cleaned up
- No server-side job handles stuck `UPLOADING` assets

**Fix:**

- Add a server background job (similar to `mux-sync.js`) that checks for assets in UPLOADING state older than 1 hour
- Mark them as `ERROR` status with a note
- Clean up partial files from the `uploads/` directory
- Alert via Slack if configured
- On iOS reconnect: check for assets in UPLOADING/ERROR state and offer retry

**Complexity:** Small — follows existing `mux-sync.js` pattern

---

#### 2.6 Temp File Cleanup — `LOW`

**Problem:** `confirmStagedUpload()` only deletes the temp video file if `uploadVideo()` completes (success or failure). If the app is killed mid-upload, the temp file (~50-500MB) remains in `NSTemporaryDirectory()` permanently.

**Fix:**

- On app launch, scan temp directory for orphaned `.mov` / `.mp4` files older than 1 hour
- Delete them
- iOS also periodically purges temp files, but only when storage is low

**Complexity:** Trivial — 5-10 lines in app startup

---

### Part 2 Implementation Order

| Priority | Item                                  | Risk Removed                              |
| -------- | ------------------------------------- | ----------------------------------------- |
| P0       | 2.1 Background upload sessions        | Upload lost when app backgrounded         |
| P0       | 2.4 `waitsForConnectivity`            | Upload fails on momentary network blip    |
| P1       | 2.3 Persist upload state              | Can't recover from app crash/kill         |
| P1       | 2.5 Server orphan cleanup             | Stuck UPLOADING assets, leaked disk space |
| P2       | 2.2 Resumable uploads (Mux tus first) | Re-upload entire file on failure          |
| P3       | 2.6 Temp file cleanup                 | Disk space leak in temp directory         |

---

## Part 3 — Security Hardening

### Current State

The app uses JWT auth with phone/PIN login, Fastify server with CORS, file uploads via multipart, Mux webhooks, Slack integration, admin dashboard, and WebSocket communication. Several areas need hardening before this goes to production users.

### Findings & Fixes

#### 3.1 No Admin Role Enforcement — `CRITICAL`

**Problem:** All admin routes (`/api/admin/*`) only check `fastify.authenticate` — any logged-in user can access admin endpoints including user management, asset listing, cleanup operations, and Mux sync. The User model has no `role` field.

**Fix:**

1. Add `role` field to Prisma User model (enum: `USER`, `ADMIN`)
2. Create `fastify.authorizeAdmin` preHandler middleware that checks `request.user.role === 'ADMIN'`
3. Apply to all `/api/admin/*` routes

**Complexity:** Small — schema migration + middleware

---

#### 3.2 Missing Asset Ownership Check — `CRITICAL`

**Problem:** `GET /api/assets/:id` returns full asset details (clips, user info, metadata) to any authenticated user — no check that the requesting user owns the asset.

**Fix:** Add ownership verification: `if (asset.userId !== request.user.id && request.user.role !== 'ADMIN') return 403`

**Complexity:** Trivial — one condition

---

#### 3.3 Weak PIN Hashing — `CRITICAL` (for production)

**Problem:** PINs are hashed with plain SHA-256 — fast, no salt, rainbow-table vulnerable. Current code comments acknowledge this is demo-grade.

**Fix:** Replace with `bcrypt` (already common in Node.js). `bcrypt.hash(pin, 10)` provides salting + cost factor. Requires migration script for existing hashed PINs.

**Note:** User stated auth will be replaced with company system. If PIN auth is temporary, this can be deferred — but document the risk.

**Complexity:** Small — swap `hashPin()`, run PIN re-hash migration

---

#### 3.4 File Upload Validation — `HIGH`

**Problem:**

- **iOS side:** MIME type is hardcoded to `video/quicktime` — no actual verification that the file is a video
- **Server side:** No MIME type check, no magic-byte validation. Extension comes from client-provided filename. Any file type can be uploaded and stored.
- **Size limit:** 500MB per file — no per-user quota

**Fix:**

- **iOS:** Validate UTType of selected file via PhotosPicker's `supportedContentTypes: [.movie]` (already filtered, but verify after `Transferable` conversion)
- **Server:** Check magic bytes of uploaded file (first 12 bytes identify MP4/MOV/AVI/MKV). Reject non-video files. Use a library like `file-type` for Node.js.
- **Server:** Sanitize and limit `originalFileName` length (max 255 chars, strip path components, remove null bytes)
- **Server:** Consider per-user daily upload quota (e.g., 10 uploads or 2GB) XXX << in a real world system can't limit uploads, this can be up to 50 uploads a day or and many Gigs of Video in a real worlds workflow.

Question: how can this also be adopted for multiclip uploads, same phone with all clips combined as one long clip on the server >>

**Complexity:** Small-Medium

---

#### 3.5 Mux Webhook Signature Required in Production — `HIGH`

**Problem:** If `MUX_WEBHOOK_SECRET` is not set, webhook events are accepted without signature verification — even in production (just logs a warning). An attacker could forge webhook events to mark clips as READY or inject data.

**Fix:** In production, if `MUX_WEBHOOK_SECRET` is not set, reject all webhook requests with 500. Make it a hard requirement.

**Complexity:** Trivial — one condition

---

#### 3.6 Missing Rate Limiting — `HIGH`

**Problem:** Only the auth/login endpoint has rate limiting. All other POST endpoints are unprotected:

- `/api/assets` — unlimited asset creation
- `/api/assets/:id/upload` — unlimited uploads
- `/api/errors` — unlimited error log writes (potential log flooding)
- `/api/admin/*` — unlimited admin operations

**Fix:** Add `@fastify/rate-limit` globally with sensible defaults:

- General: 100 requests/minute per IP
- Upload creation: 10/minute per user
- Error logging: 20/minute per user
- Admin endpoints: 30/minute per user

**Complexity:** Small — plugin config + per-route overrides

---

#### 3.7 HTTP Security Headers — `HIGH`

**Problem:** No security headers set. Missing HSTS, X-Frame-Options, X-Content-Type-Options, CSP.

**Fix:** Add `@fastify/helmet` with sensible defaults. One line: `await fastify.register(helmet)`.

**Complexity:** Trivial

---

#### 3.8 JWT Secret Must Be Required in Production — `HIGH`

**Problem:** If `JWT_SECRET` is missing, server generates a random one — all tokens invalidated on restart. In production this causes silent mass logout on every deploy.

**Fix:** `if (!process.env.JWT_SECRET && isProduction) throw new Error('JWT_SECRET required')`

**Complexity:** Trivial — one line

---

#### 3.9 Chat Message Sanitization — `MEDIUM`

**Problem:** User text messages are stored and relayed as-is. No length limit, no sanitization. Could contain XSS payloads (rendered in admin dashboard web UI), control characters, or extremely long strings.

**Fix:**

- Enforce max message length server-side (e.g., 5000 chars) — truncate or reject << where is this issue? text to slack or user random texts the server does not actually respond to? >>
- HTML-escape messages before rendering in admin web UI
- Strip control characters (except newlines)

**Complexity:** Small

---

#### 3.10 Unsanitized Slack Input — `MEDIUM`

**Problem:** User-controlled text (`userName`, `mediasourceId`, `clipUrl`, `mention`) is injected into Slack Block Kit payloads without escaping. Slack's `mrkdwn` format could be abused. << yes should limit and structure. >>

**Fix:** Escape Slack special characters (`&`, `<`, `>`) in user-provided strings before building blocks.

**Complexity:** Trivial — utility function

---

#### 3.11 JWT Expiry Window — `MEDIUM`

**Problem:** Tokens are valid for 7 days. A stolen token gives extended access.

**Fix:** Reduce to 24 hours. Implement silent refresh — iOS checks token expiry on `scenePhase` `.active` and calls a `/api/auth/refresh` endpoint. This pairs naturally with the scenePhase work in 1.1.

**Note:** Since auth is being replaced with company system, consider deferring refresh tokens — but shorten expiry now. defer for now.

**Complexity:** Small for shorter expiry; Medium for refresh token flow

---

#### 3.12 Admin Raw SQL Queries — `MEDIUM`

**Problem:** Admin routes use `$queryRawUnsafe()`. Current queries are hardcoded (no user input), but the pattern is fragile — a future edit could introduce SQL injection.

**Fix:** Migrate to Prisma ORM queries (`.aggregate()`, `.findMany()` with `include`). For complex queries, use `$queryRaw` with tagged template literals (parameterized).

**Complexity:** Medium — rewrite ~5 queries

---

### Part 3 Implementation Order

| Priority | Item                            | Risk Removed                                     |
| -------- | ------------------------------- | ------------------------------------------------ |
| P0       | 3.1 Admin role enforcement      | Any user can access admin functions              |
| P0       | 3.2 Asset ownership check       | Cross-user data access                           |
| P0       | 3.8 Required JWT_SECRET in prod | Mass logout on every deploy                      |
| P1       | 3.4 File upload validation      | Arbitrary file upload                            |
| P1       | 3.5 Required webhook signature  | Forged Mux events                                |
| P1       | 3.6 Rate limiting               | DoS / resource exhaustion                        |
| P1       | 3.7 Security headers            | Clickjacking, MIME sniffing                      |
| P2       | 3.9 Chat message sanitization   | XSS in admin dashboard                           |
| P2       | 3.10 Slack input escaping       | Slack injection                                  |
| P2       | 3.11 Shorter JWT expiry         | Extended token theft window                      |
| P2       | 3.3 Stronger PIN hashing        | Rainbow table attack (deferred if auth replaced) |
| P3       | 3.12 Replace raw SQL            | Future SQL injection risk                        |

---

## Implementation Phases

### Phase A — Foundation (P0 items)

Core reliability and security — do these first. Each can be an independent PR.

| #   | Item                                          | Area            | Effort       |
| --- | --------------------------------------------- | --------------- | ------------ |
| A1  | scenePhase observer + reconnect on foreground | iOS WS          | Small        |
| A2  | Message send queue + flush on reconnect       | iOS WS          | Medium       |
| A3  | Background URLSession for uploads             | iOS Upload      | Medium-Large |
| A4  | `waitsForConnectivity = true`                 | iOS Upload      | Trivial      |
| A5  | Admin role field + middleware                 | Server Security | Small        |
| A6  | Asset ownership check on GET                  | Server Security | Trivial      |
| A7  | Required JWT_SECRET in production             | Server Security | Trivial      |

**Outcome:** App survives foreground/background transitions, uploads continue when app is suspended, messages aren't lost during brief disconnections, admin endpoints are protected.

### Phase B — Resilience (P1 items)

Handling edge cases and building robustness.

| #   | Item                                     | Area            | Effort  |
| --- | ---------------------------------------- | --------------- | ------- |
| B1  | NWPathMonitor recovery after max retries | iOS WS          | Small   |
| B2  | sendRaw error triggers reconnect         | iOS WS          | Small   |
| B3  | Persist upload state to disk             | iOS Upload      | Medium  |
| B4  | Server orphan cleanup job                | Server Upload   | Small   |
| B5  | File upload validation (magic bytes)     | Server Security | Small   |
| B6  | Mux webhook signature required in prod   | Server Security | Trivial |
| B7  | Global rate limiting                     | Server Security | Small   |
| B8  | HTTP security headers (Helmet)           | Server Security | Trivial |

**Outcome:** App recovers from any network state, uploads are resumable after crash, server rejects bad files, APIs are rate-limited.

### Phase C — Hardening (P2 items)

Polish and defense-in-depth.

| #   | Item                                       | Area            | Effort  |
| --- | ------------------------------------------ | --------------- | ------- |
| C1  | Client-side ping watchdog                  | iOS WS          | Small   |
| C2  | Reconnect race guard                       | iOS WS          | Small   |
| C3  | Resumable uploads (Mux tus)                | iOS Upload      | Large   |
| C4  | Chat message sanitization + length limit   | Server Security | Small   |
| C5  | Slack input escaping                       | Server Security | Trivial |
| C6  | Shorter JWT expiry (24h)                   | Server Security | Small   |
| C7  | Stronger PIN hashing (if still using PINs) | Server Security | Small   |

### Phase D — Nice-to-Have (P3 items)

| #   | Item                                         | Area            | Effort  |
| --- | -------------------------------------------- | --------------- | ------- |
| D1  | WebSocket-only transport (skip HTTP polling) | iOS WS          | Medium  |
| D2  | Temp file cleanup on launch                  | iOS Upload      | Trivial |
| D3  | Replace admin raw SQL with Prisma ORM        | Server Security | Medium  |

---

## Testing Verification

Each phase should include targeted tests:

| Phase | Test                                                                   |
| ----- | ---------------------------------------------------------------------- |
| A     | Upload video → background app → return → verify upload completed       |
| A     | Send message → kill WiFi → restore → verify message delivered          |
| A     | Non-admin user → try GET /api/admin/users → verify 403                 |
| B     | Upload video → kill app → relaunch → verify resume or clean recovery   |
| B     | Upload non-video file via curl → verify server rejection               |
| B     | Rapid-fire 200 requests to /api/assets → verify rate limiting kicks in |
| C     | Start upload on WiFi → switch to cellular → verify upload continues    |
| C     | Send 10KB text message → verify server truncates/rejects               |

---

## Risk Summary

| Scenario                                | Current Outcome                   | After Plan                        |
| --------------------------------------- | --------------------------------- | --------------------------------- |
| User locks phone during upload          | Upload fails silently             | Upload continues in background    |
| Network drops for 5 seconds             | Upload lost, must restart         | Pauses and resumes automatically  |
| User sends message during reconnect     | Message vanishes                  | Queued and delivered on reconnect |
| User returns to app after 10 min        | Shows stale "connected" state     | Detects stale state, reconnects   |
| 10 retries exhausted, then WiFi returns | App stuck, must kill and relaunch | NWPathMonitor auto-reconnects     |
| Non-admin calls admin API               | Gets full access                  | Gets 403 Forbidden                |
| Attacker uploads malware as "video"     | Server stores it                  | Server rejects non-video files    |
| App crash mid-upload                    | Orphaned asset, lost progress     | Recovers on next launch           |

---

_This plan is review-only. No code changes have been made. Ready to begin implementation on your go._

... NOTES

CAP QUEUE
The cap prevents a pathological case: if the WebSocket is down for a long time and the user keeps tapping "send," every outgoing event (text messages, upload notifications) accumulates in an in-memory array. Without a limit, that array grows forever — consuming RAM on a mobile device that may already be under memory pressure from video processing.

In practice, 20 is generous for this app. A realistic disconnection scenario might produce 1-3 queued items (a text message, maybe a video:upload event). But if something goes haywire — say the connection is stuck in a reconnect loop for 10 minutes and the user is frantically typing — you don't want 500 unsent messages piling up and then all flushing at once when the socket reconnects (which could also overwhelm the server).

When the cap is hit, you have a design choice:

Drop oldest — discard the front of the queue (least recent). Keeps the user's latest intent.
Drop newest — reject the new send and show the user "message not sent, connection lost." More honest.
Block sends — disable the input bar entirely when the queue is full. Clearest signal.
For this app, I'd lean toward dropping oldest + notifying — since the most recent message is what the user cares about, and the older queued texts were probably "hello?" / "are you there?" type messages anyway.

The number 20 itself isn't sacred — it's just a reasonable default that's high enough to never annoy a normal user but low enough to prevent memory issues. You could set it to 5 or 50 and it wouldn't meaningfully change behavior for real-world usage.
