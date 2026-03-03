# Direct Video Uploader — Project Status

> **Last Updated:** March 3, 2026 · 3:10 PM MST
> **Current Phase:** Phase 2 — iOS Demo App (in progress)
> **Overall Progress:** ██████████████████░░ 85%

---

## Quick Summary

The **Direct Video Uploader** is a mobile-first video upload platform disguised as a text conversation. Field crew members "text" videos to the **Mediasource Fixer** server, which processes them the way a news assignment desk operates — fast, structured, and integrated with Slack.

We've completed the **interactive chat demo** (HTML prototype), **project specification** (v4), the **Phase 1 server foundation** (Node.js API, WebSocket, PostgreSQL, auth, admin dashboard), and the **Phase 2 — iOS Demo App** core flow is fully verified end-to-end on physical device: login → chat → video upload (with real file size) → form popup → Slack notification → confirmation. Dashboard shows only live data with accurate WebSocket metrics.

---

## Running the Project

```bash
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

| Deliverable                      | Status       | File                                              |
| -------------------------------- | ------------ | ------------------------------------------------- |
| Node.js + Fastify server         | ✅ Running   | `server/src/index.js`                             |
| PostgreSQL database (Prisma 7)   | ✅ Running   | `server/prisma/schema.prisma`                     |
| Database schema (6 models)       | ✅ Synced    | Users, Assets, Clips, FormResponses, ChatMessages |
| Auth: Phone# + PIN → JWT         | ✅ Working   | `server/src/routes/auth.js`                       |
| Asset CRUD + Upload              | ✅ Working   | `server/src/routes/assets.js`                     |
| Form submission                  | ✅ Working   | `POST /api/assets/:id/form`                       |
| Chat message history             | ✅ Working   | `GET /api/messages`                               |
| WebSocket (Socket.IO)            | ✅ Connected | `server/src/ws/handler.js`                        |
| Real-time greeting message       | ✅ Working   | Sent on WS connect                                |
| Slack post simulation            | ✅ Working   | `slack:post` → `slack:confirmed` events           |
| Admin API (stats, users, assets) | ✅ Working   | `server/src/routes/admin.js`                      |
| Admin triad status endpoint      | ✅ Working   | `GET /api/admin/status` — DB, Server, iOS, Admin  |
| Admin dashboard (React)          | ✅ Working   | React 19 + Vite 6 + TypeScript + Tailwind v4      |
| Demo users seeded (3)            | ✅ Seeded    | David Burgess, Carrie Smith, Admin User           |
| Local dev database               | ✅ Running   | `prisma dev` (PostgreSQL on port 51214)           |

**Server Endpoints Verified:**

| Method | Path                        | Status                 |
| ------ | --------------------------- | ---------------------- |
| `GET`  | `/api/health`               | ✅                     |
| `POST` | `/api/auth/login`           | ✅                     |
| `GET`  | `/api/auth/me`              | ✅                     |
| `POST` | `/api/assets`               | ✅                     |
| `POST` | `/api/assets/:id/upload`    | ✅                     |
| `GET`  | `/api/assets/:id`           | ✅                     |
| `POST` | `/api/assets/:id/form`      | ✅                     |
| `GET`  | `/api/messages`             | ✅                     |
| `GET`  | `/api/admin/stats`          | ✅                     |
| `GET`  | `/api/admin/users`          | ✅                     |
| `GET`  | `/api/admin/assets`         | ✅                     |
| `GET`  | `/api/admin/status`         | ✅ Triad health        |
| `WS`   | `/socket.io/`               | ✅                     |
| `POST` | `/api/admin/cleanup-assets` | ✅ Stale asset cleanup |
| `GET`  | `/`                         | ✅ Dashboard           |

---

### � Milestone 4 — iOS Demo App (Phase 2)

**In Progress: Mar 2–14, 2026**

| Deliverable                        | Status             | Notes                                          |
| ---------------------------------- | ------------------ | ---------------------------------------------- |
| Xcode project setup (SwiftUI)      | ✅ Done            | iOS 17+ target, XcodeGen `project.yml`         |
| Login / Auth (Phone + PIN → JWT)   | ✅ Working         | Tested on Simulator + physical iPhone          |
| Chat UI (messages, bubbles, input) | ✅ Working         | `ChatView`, `MessageBubble`, `InputBar`        |
| WebSocket client (native)          | ✅ Connected       | `URLSessionWebSocketTask` + Socket.IO protocol |
| Text message send + auto-reply     | ✅ Working         | Server replies "send me your videos!"          |
| Video picker (PhotosPicker)        | ✅ Working         | SwiftUI `PhotosPicker` with `.videos` filter   |
| Video upload (multipart)           | ✅ Built           | `VideoUploadService` with progress tracking    |
| Upload progress bar                | ✅ Built           | Inline progress bar in chat view               |
| Metadata display (slide-up sheet)  | 🟡 Built, untested | `MetadataView` SwiftUI sheet                   |
| Context form (slide-up sheet)      | 🟡 Built, untested | `ContextFormView` SwiftUI sheet                |
| Confirmation message               | ✅ Built           | `form:confirmed` → Mediasource link in chat    |
| Slack post trigger                 | ✅ Built           | Auto-triggers after form submit, 1.5s delay    |
| TestFlight build                   | 🔲 Not started     | For demo distribution                          |

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

### 🔲 Milestone 5 — Web Clip Viewer (Phase 2)

**Target: Week of Mar 10, 2026**

| Deliverable                    | Status         | Notes                       |
| ------------------------------ | -------------- | --------------------------- |
| Clip viewer page               | 🔲 Not started | Video player + metadata     |
| Responsive layout (dark theme) | 🔲 Not started | Match dashboard aesthetic   |
| Public shareable links         | 🔲 Not started | `GET /clips/:slug`          |
| Video playback                 | 🔲 Not started | Mux Player or `<video>` tag |
| Host on Vercel                 | 🔲 Not started | Static site                 |

---

### 🔲 Milestone 6 — Integrations & Polish (Phase 3)

**Target: Week of Mar 17, 2026**

| Deliverable                        | Status         | Notes                                                        |
| ---------------------------------- | -------------- | ------------------------------------------------------------ |
| Video streaming (Mux or CF Stream) | 🔲 Not started | Replace local file storage                                   |
| Slack webhook (real)               | 🔲 Not started | Replace simulated posts                                      |
| Cloud storage (R2 or B2)           | 🔲 Not started | Video file storage                                           |
| Deploy server to Render            | 🔲 Not started | Production deployment                                        |
| Admin UI (expanded)                | � Partial      | React dashboard running; needs asset detail, log persistence |
| Real metadata extraction (ffprobe) | 🔲 Not started | Replace mock data                                            |

---

### 🔲 Milestone 7 — Production Hardening (Future)

**Target: TBD**

| Deliverable                      | Status         | Notes                         |
| -------------------------------- | -------------- | ----------------------------- |
| Device registration / MDM        | 🔲 Not started | Enterprise device control     |
| SMS/MMS fallback (Twilio)        | 🔲 Not started | Alternative upload path       |
| Rate limiting + abuse protection | 🔲 Not started | Production security           |
| Multi-clip asset support         | 🔲 Not started | Multiple videos per asset     |
| Push notifications               | 🔲 Not started | Upload status, form reminders |
| Audit logging                    | 🔲 Not started | Who did what, when            |

---

## Tech Stack (Current)

| Layer                | Technology                                   | Status            |
| -------------------- | -------------------------------------------- | ----------------- |
| **Server**           | Node.js + Fastify                            | ✅ Running        |
| **WebSocket**        | Socket.IO                                    | ✅ Running        |
| **Database**         | PostgreSQL (Prisma 7)                        | ✅ Running        |
| **ORM**              | Prisma (pg adapter)                          | ✅ Running        |
| **Auth**             | JWT (@fastify/jwt)                           | ✅ Running        |
| **Dashboard**        | React 19 + Vite 6 + TypeScript + Tailwind v4 | ✅ Running        |
| **Chat Demo**        | Vanilla HTML/CSS/JS                          | ✅ Complete       |
| **iOS App**          | SwiftUI + `URLSessionWebSocketTask`          | 🟡 In progress    |
| **Web Viewer**       | Vite or Next.js (planned)                    | 🔲 Not started    |
| **Video Service**    | Mux or CF Stream (planned)                   | 🔲 Not started    |
| **Storage**          | Cloudflare R2 or Backblaze B2 (planned)      | 🔲 Not started    |
| **Hosting (Server)** | Render (planned)                             | 🔲 Local only     |
| **Hosting (Web)**    | Vercel (planned)                             | 🔲 Not started    |
| **Slack**            | Incoming Webhooks (planned)                  | 🔲 Simulated only |

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
│ ├── App/ # SwiftUI app entry point
│ ├── Models/ # User, Asset, ChatMessage, ServerConfig
│ ├── Services/ # AuthService, ChatViewModel, WebSocketService, VideoUploadService
│ └── Views/ # Auth, Chat, Form, Metadata views
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
│ ├── assets.js # Asset CRUD + upload + form
│ └── admin.js # Triad status, stats, user/asset lists
└── ws/
└── handler.js # WebSocket + client type tracking

```

---

## Demo Credentials

| User          | Phone        | PIN    | Team        |
| ------------- | ------------ | ------ | ----------- |
| David Burgess | `5055034455` | `1234` | Field       |
| Carrie Smith  | `5055551234` | `1234` | Editorial   |
| Admin User    | `8001234567` | `0000` | Engineering |

---

## Decision Log

| Date   | Decision                          | Rationale                                                                                   |
| ------ | --------------------------------- | ------------------------------------------------------------------------------------------- |
| Feb 28 | Pivot from MMS to Direct Upload   | MMS caps at 3.5 MB; direct upload gives full resolution + richer UX                         |
| Mar 1  | "App IS a text conversation"      | Simplest mental model for field crew; reduces training friction                             |
| Mar 1  | Mediasource Fixer branding        | Familiar identity for newsroom users                                                        |
| Mar 2  | WebSocket (Socket.IO)             | Real-time bidirectional messaging; no polling overhead                                      |
| Mar 2  | Fastify over Express              | Faster, better plugin system, async-first                                                   |
| Mar 2  | Prisma 7 with pg adapter          | Type-safe ORM, great migrations, Prisma 7 requires driver adapters                          |
| Mar 2  | Render for hosting                | WebSocket support, managed PostgreSQL, persistent services (vs Vercel serverless)           |
| Mar 2  | Simple auth (Phone# + PIN)        | Demo-appropriate; no SMS verification overhead                                              |
| Mar 2  | Local file uploads (demo)         | Production will use R2/B2; no cloud setup needed for Phase 1                                |
| Mar 2  | Mock metadata (demo)              | Production will use ffprobe; keeps Phase 1 simple                                           |
| Mar 2  | Native WS over Socket.IO Swift    | `URLSessionWebSocketTask` with manual Socket.IO protocol framing; no third-party dependency |
| Mar 2  | `127.0.0.1` not `localhost`       | iOS Simulator resolves `localhost` to IPv6 `::1`; Node server binds IPv4 only               |
| Mar 2  | Copilot instructions file         | Moved from `agent-guide.md` to `.github/copilot-instructions.md` (auto-loaded)              |
| Mar 2  | DB pool size 5 → 20               | Concurrent dashboard + WS queries exhausted small pool, causing 5s timeouts                 |
| Mar 2  | `PhotosPicker` not `PHPicker`     | SwiftUI-native picker avoids UIKit bridging; `.videos` filter, `Transferable` protocol      |
| Mar 2  | Stream multipart to temp file     | `VideoUploadService` writes multipart body to disk in 1MB chunks — avoids memory pressure   |
| Mar 2  | Codable fields must be optional   | Server responses vary by endpoint; non-optional fields cause silent `JSONDecoder` failures  |
| Mar 3  | React admin dashboard             | Replaced vanilla HTML with React 19 + Vite 6 + TypeScript + Tailwind v4 + TanStack Query    |
| Mar 3  | Triad launcher (`scripts/dev.js`) | Single `npm run dev` command orchestrates DB + Server + Admin with smart log filtering      |
| Mar 3  | Live-only dashboard               | Removed all simulated actions; dashboard shows only real data with neutral fallback states  |
| Mar 3  | WS client type tracking           | Socket.IO connections tagged as `ios` or `admin`; enables accurate triad status reporting   |
| Mar 3  | Remove client-side WS ping        | Engine.IO 4 uses server-initiated pings; client ping timer caused 25s disconnect loop       |
| Mar 3  | `io.of('/').sockets.size` metric  | Replaced `engine.clientsCount` — gives accurate authenticated socket count, not transports  |
| Mar 3  | Admin uses Admin User credentials | Dashboard auto-logins as Admin User (`8001234567`) not David Burgess                        |
| Mar 3  | Stale asset cleanup endpoint      | `POST /api/admin/cleanup-assets` — Prisma ORM delete of stuck UPLOADING assets              |
| Mar 3  | Real file size in WS event        | iOS `FileManager.attributesOfItem` gets actual bytes before `sendVideoUpload`               |

---

## Next Actions

1. **Server response refinement** — Tolerance for odd texts (wait before auto-reply in case video follows), suppress "I can't text" if upload starts within N seconds. See `first-file.md` notes on response flow.
2. **Metadata sheet verification** — `MetadataView` built but untested on physical device
3. **Polish chat UI** — Video thumbnail preview, upload status indicators, error states
4. **TestFlight build** — For demo distribution
5. **Set up Render deployment** — Push server to Render with managed PostgreSQL
6. **Build web clip viewer** — Vite + React, dark theme, video player
7. **Admin dashboard polish** — Real-time upload progress, asset detail view, log persistence
