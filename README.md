# Direct Video Uploader (DVU) — Mediasource Fixer

_Last updated: September 24, 2026_

**Direct Video Uploader** is a mobile-first video upload platform disguised as a text conversation. Field crew members "text" full-resolution videos to the **Mediasource Fixer** server, which processes them the way a news assignment desk operates — fast, structured, and integrated with Slack.

The UX is intentionally modeled after text messaging work-flow: Opening the app displays a text thread. **"Fixer"** sends a message acknowledging it is ready for video. User uploads video starting with Photo Library. sation with **"Fixer"**, selects a video, taps send, fills out a slug form, and the server replies back with metadata, a clip viewer link, and a one-tap Slack post. Under the hood, videos upload directly to **Mux** via tus protocol, bypassing the server entirely.

> **Status:** Phase 3 (~99%) — Mux pipeline operational, Slack integration live, Apple Speech transcription, admin tools, archive, video trim, stability hardening complete. See `PROJECT_STATUS.md` for full details.

**Native readiness roadmap (October 28, 2026):** See the [iOS 27 Readiness Plan](docs/IOS_27_READINESS_PLAN.md) for phased work, acceptance gates, and progress checklists. Historical progress above does not establish current iOS 27 readiness.

---

## Architecture

```
┌──────────────┐      WebSocket (Socket.IO)      ┌──────────────────┐
│   iOS App    │◄──────────────────────────────►│  Node.js Server  │
│  (SwiftUI)   │      JWT auth + real-time       │  (Fastify)       │
└──────┬───────┘                                  └───────┬──────────┘
       │                                                   │
       │  Video upload (tus)                              │  PostgreSQL (Prisma 7)
       ▼                                                   │  Slack Bot API
┌──────────────┐                                  ┌───────▼──────────┐
│   Mux CDN    │──── HLS streaming ────────────►│  Clip Viewer     │
│  (direct)    │                                  │  /clips/:slug    │
└──────────────┘                                  └──────────────────┘
```

1. **iOS app** authenticates via phone# + PIN → JWT, connects WebSocket.
2. User picks a video → app uploads directly to **Mux CDN** (zero server bottleneck).
3. Server creates asset record, pushes form request to iOS via WebSocket.
4. User fills slug/description form → server stores metadata, sends confirmation.
5. Mux processes video → webhook/sync marks clip READY → server notifies user.
6. User types `#channel` or `@name` → server posts to **Slack** with thumbnail + clip link.
7. **Clip viewer** at `/clips/:slug` is a server-rendered page for authorized viewers, with a Mux player.

---

## What's in This Repo

```
Direct-Video-Uploader/
├── ios/                    # iOS app (SwiftUI, iOS 18.6+)
│   ├── project.yml         # XcodeGen project definition
│   ├── DirectVideoUploaderTests/ # Swift Testing regression tests
│   └── DirectVideoUploader/
│       ├── App/            # Entry point, Theme.swift, DVUDateFormatting.swift
│       ├── Models/         # User, Asset, ChatMessage, ServerConfig
│       ├── Services/       # Auth, ChatViewModel, WebSocket, VideoUpload, Transcription, PermissionManager
│       ├── Utilities/      # RetryHelper
│       └── Views/          # Auth, Chat, Form, Metadata, Archive, Profile, Instructions
├── server/                 # Node.js backend (Fastify + Socket.IO + Prisma)
│   ├── prisma/schema.prisma
│   └── src/
│       ├── routes/         # auth, assets, admin, clips, errors
│       ├── ws/handler.js   # WebSocket event handling
│       ├── lib/            # prisma, mux, slack, config, utils
│       └── jobs/           # mux-sync (background), upload-cleanup
├── admin/                  # React dashboard (Vite + TypeScript + Tailwind v4)
│   └── src/
│       ├── components/     # LoginForm, StatsGrid, AssetList, UserList, AdminTools
│       └── hooks/          # TanStack Query, Socket.IO real-time
├── scripts/dev.js          # Triad launcher (DB + Server + Admin)
├── Dockerfile              # Multi-stage Docker build (Fastify + Vite)
├── cloudbuild.yaml         # Legacy Google Cloud Build pipeline (not in use)
├── PROJECT_SPEC.md         # Full product specification (v4)
├── PROJECT_STATUS.md       # Detailed progress log with every session
├── STABILITY_PLAN.md       # Security + reliability hardening (Phases A–C)
├── TESTING_PLAN.md         # Testing approach
└── TODO.md                 # Backlog tracker
```

---

## Quick Start (Local Dev)

### Prerequisites

- **Node.js** 20.19+ (20.x), 22.x, or 24+ and **npm**
- **PostgreSQL 18** (Homebrew recommended for local dev: `brew install postgresql@18`; Prisma manages schema)
- **Xcode** with an iOS SDK compatible with iOS 18.6, plus **XcodeGen** (verified with Xcode 27.2)
- Optional: Mux account, Slack bot token

### 1. Setup

```bash
npm run setup
```

Installs dependencies for `server/` and `admin/`, pushes Prisma schema, generates client, seeds demo users.

### 2. Run Everything

```bash run from root
npm run dev
```

This single command launches the **Triad** — database, API server (`:3000`), and admin dashboard (`:5173`) with smart log filtering and status display.

```
╔══════════════════════════════════════════════════╗
║              T R I A D   S T A T U S             ║
╠══════════════════════════════════════════════════╣
║  🟢 Database     Running   PostgreSQL             ║
║  🟢 Server       Running   http://localhost:3000   ║
║  🟢 Dashboard    Running   http://localhost:5173   ║
║  ⚪ iOS App      Waiting   No client connected     ║
╚══════════════════════════════════════════════════╝
```

### 3. Build iOS App

```bash
xcodegen generate --spec ios/project.yml
# Open ios/DirectVideoUploader.xcodeproj in Xcode, build to device
```

> **Tip:** For tethered device testing, update `ServerConfig.swift` with your Mac's LAN IP.

The unit tests host the app, which can restore a saved session and contact its configured server. Use a fresh, disposable simulator rather than one containing real credentials or data:

```bash
xcrun simctl list runtimes
xcrun simctl list devicetypes
test_simulator="$(xcrun simctl create 'Fixer Unit Tests' \
  'com.apple.CoreSimulator.SimDeviceType.iPhone-17e' \
  'com.apple.CoreSimulator.SimRuntime.iOS-27-0')"
xcodebuild -project ios/DirectVideoUploader.xcodeproj -scheme DirectVideoUploader \
  -destination "platform=iOS Simulator,id=$test_simulator" CODE_SIGNING_ALLOWED=NO test
xcrun simctl shutdown "$test_simulator"
xcrun simctl delete "$test_simulator"
```

Replace the device type and runtime with installed iPhone options if needed. If testing is interrupted, shut down and delete only the simulator identified by `test_simulator`. CI runs the same suite on its newest available iOS 18.6+ iPhone simulator. These tests do not replace the physical-device regression checklist in the [iOS modernization plan](iOS-Modernization.md).

---

## Scripts

| Command               | What it does                                                           |
| --------------------- | ---------------------------------------------------------------------- |
| `npm run dev`         | **Triad launcher** — DB + Server `:3000` + Admin `:5173` (recommended) |
| `npm run dev:admin`   | Starts Vite dev server only on `:5173`                                 |
| `npm run build:admin` | Production build of React admin → `server/public/` (Vite only, fast)   |
| `npm --prefix admin run typecheck` | Type-checks the web app and its tests                       |
| `npm --prefix admin test` | Runs the web app's routing and session tests                        |
| `npm run server`      | Starts Fastify server only                                             |
| `npm run setup`       | Fresh setup: install deps, push schema, generate client, seed          |

The admin build empties `server/public/`. To avoid replacing existing files while validating,
run `npm --prefix admin run build -- --outDir <disposable-directory>` instead. After a
production rebuild, restart Fastify so it registers the new hashed files; see the
[home-server runbook](HOME_SERVER_RUNBOOK.md).

---

## Tech Stack

| Layer             | Technology                                   |
| ----------------- | -------------------------------------------- |
| **iOS App**       | SwiftUI + `URLSessionWebSocketTask`          |
| **Server**        | Node.js + Fastify + Socket.IO                |
| **Database**      | PostgreSQL 18 + Prisma 7 (pg adapter)        |
| **Auth**          | Phone# + PIN → JWT (`@fastify/jwt`)          |
| **Video**         | Mux (direct upload via tus + HLS playback)   |
| **Dashboard**     | React 19 + Vite 6 + TypeScript + Tailwind v4 |
| **Clip Viewer**   | Server-rendered HTML at `/clips/:slug`       |
| **Slack**         | Bot API (`fixer-video` bot)                  |
| **Transcription** | Apple Speech (opt-in; may use Apple's servers) |
| **Hosting**       | Home server + Cloudflare Tunnel              |

---

## Key Features

- **Chat-based UX** — Upload flow feels like texting, not a file manager
- **Mux direct upload** — iOS uploads to Mux CDN via tus protocol (no server bottleneck)
- **Real-time WebSocket** — Greeting, upload progress, form requests, Mux ready notifications, Slack confirmations
- **Scoped dashboard refreshes** — Step 2.4 sends payload-free asset-change signals to the
  relevant team admins and super admins; rich upload and form events remain owner-only.
  Step 2.4 and the Step 2.2 reconciliation fix are merged to `main`; the owner reports the web
  app deployed. The matching server version, migration status, legacy-upload draining, and
  real-Mux checks remain unconfirmed. See the [roadmap](iOS-Modernization.md).
- **Context form** — Slug, type, description, priority with auto-focus and swipe-dismiss prevention
- **Video trim** — Pre-upload trimming via native `UIVideoEditorController`
- **PHAsset fast path** — Zero-copy video loading from Photos library (instant, no file copy)
- **Slack integration** — Post to `#channels` or DM `@users` with thumbnail, clip link, and metadata
- **Clip viewer** — Sign-in required for owners, same-organization members, or Super Admins. The underlying Mux playback URLs are still public.
- **Apple Speech** — Optional transcription with newsroom vocabulary and per-word timestamps; recognition may use Apple's servers.
- **Archive** — uploads or details submitted in the last 7 days, plus older uploads needing details or upload recovery, with status dots, thumbnails, re-upload, and form submission. Slug shown as primary display name; format row combines resolution + codec
- **Photos tab** — Placeholder for upcoming photo upload pipeline (TBD feature)
- **Profile** — User info, Photo Library + Speech Recognition permission toggles with live status, app info
- **In-app instructions** — 5-page swipeable guide: First Things, iPhone Media, Steps to Use Fixer, What's Happening Inside Fixer, Archive. SF Symbol icons inline
- **Server greetings** — 40+ randomized greeting combos using first name only, feature tips, no consecutive repeats. Greets every device independently
- **Device tracking** — iOS sends `deviceId`, `deviceName`, `deviceModel` in WebSocket handshake auth. Server logs per-device connections
- **Role-separated web dashboard (in progress)** — Super Admin and Team Admin retain the
  existing management tools; users see their own active and paused videos and can open
  available clips. Hash routes provide role-specific homes and 403/404 pages. The current
  login remains phone and PIN without a company code; server authorization still enforces
  access. Deploy the dashboard with the matching server and verify Cloudflare Access permits
  intended web users. The Step 3.2 work adds lazy thumbnails and status fallbacks to scoped
  lists, with indeterminate upload progress. Mux thumbnail URLs remain public while playback
  is active. Profile/PIN changes and richer video details remain planned.

---

## Demo Credentials

| User          | Phone        | PIN    | Role        |
| ------------- | ------------ | ------ | ------------|
| Rod Griola    | `9176717330` | `3xxx` | SUPER ADMIN |
| David Burgess | `5055034455` | `xxxx` | USER        |
| Carrie Smith  | `5055551234` | `xxxx` | USER        |

---

## Environment Variables

The server expects these in `server/.env` (see `.env.example`):

| Variable             | Required | Description                                                                                                      |
| -------------------- | -------- | ---------------------------------------------------------------------------------------------------------------- |
| `DATABASE_URL`       | Yes      | PostgreSQL connection string (local: `postgresql://<user>@localhost:5432/directvideo`, no password — trust auth) |
| `JWT_SECRET`         | Yes\*    | JWT signing secret (\*auto-generates)                                                                            |
| `MUX_TOKEN_ID`       | Yes      | Mux API token ID                                                                                                 |
| `MUX_TOKEN_SECRET`   | Yes      | Mux API token secret                                                                                             |
| `MUX_WEBHOOK_SECRET` | No       | Mux webhook signing secret (optional — for verifying webhook signatures)                                         |
| `SLACK_BOT_TOKEN`    | No       | Slack bot OAuth token (`xoxb-...`)                                                                               |
| `PUBLIC_URL`         | No       | Public URL for clip links                                                                                        |
| `NODE_ENV`           | No       | `production` enables SSL, trust proxy                                                                            |

---

## Legacy Cloud Deployment

Cloud Build and Render are no longer used for deployment (confirmed by the project owner on Nov 7, 2026). The legacy configuration remains in the repository; it must be reviewed before reuse because it runs `prisma db push --accept-data-loss`. The Render build script also seeds demo accounts.

The former Cloud Build pipeline performed these steps:

```bash
# Historical Cloud Build steps (not in use)
# 1. Builds multi-stage Dockerfile (bundles React admin into Fastify static public/)
# 2. Pushes container image to Google Artifact Registry
# 3. Runs npx prisma db push --accept-data-loss via ephemeral Cloud SQL Auth Proxy
# 4. Deploys service to Cloud Run with Secret Manager environment variables
```

### Former Architecture on GCP

- **Cloud Run**: Hosts the unified Node.js Fastify server + Vite React admin static bundle. Auto-scales down to zero when idle.
- **Cloud SQL**: Managed PostgreSQL instance, connected securely via Unix Sockets (`/cloudsql/...`).
- **Secret Manager**: Holds sensitive environment variables (`DATABASE_URL`, `JWT_SECRET`, `MUX_*`).
- **Artifact Registry**: Stores versioned Docker container builds tagged by Git commit SHA.
- **Cloudflare**: Managed DNS CNAME (`ghs.googlehosted.com.`) with automatic SSL certificate provisioning.

---

## Home Server (Cloudflare Tunnel)

The Fastify server and Postgres 18 run on a home MacBook Air instead of Cloud Run/Cloud SQL, exposed via a **Cloudflare Tunnel**. Both the production domain `ms-fixer.com` and the secondary/testing domain `dev.ms-fixer.com` route to this home server (Cloud Run no longer receives traffic for either). Postgres stays loopback-only (SCRAM auth, no open ports); only the Fastify server is tunneled out.

- **Services**: `brew services` manages Postgres 18; a `launchd` `LaunchAgent` (`~/Library/LaunchAgents/com.msfixer.fastify.plist`) keeps Fastify running (`KeepAlive`, auto-restart).
- **Tunnel**: `cloudflared` runs as a system `LaunchDaemon`, config at `/etc/cloudflared/config.yml`, routing both `ms-fixer.com` and `dev.ms-fixer.com` → `http://localhost:3000`.
- **Access control**: Cloudflare Zero Trust protects the admin dashboard (site root) with email one-time-PIN login, on both domains. `/api/*`, `/socket.io/*`, `/uploads/*`, and `/clips/*` bypass Access. App authentication protects the applicable API and clip routes, but active `/uploads/*` URLs remain unauthenticated and Mux playback URLs are public. The merged Step 2.2 code gates moderated legacy files, and Step 2.4 scopes payload-free dashboard refreshes; confirm the running server version before relying on either.
- **Real-time deployment**: Socket rooms and authorization invalidation are process-local, matching the current single-server deployment. Multiple server processes require a shared Socket.IO adapter and coordinated revocation. Refreshes are best-effort; dashboard polling remains enabled.
- **CORS/WebSocket origins**: `PUBLIC_URL` (defaults to `https://ms-fixer.com`) plus its `www.` variant are always allowed; additional origins (e.g. `https://dev.ms-fixer.com`) can be added via the comma-separated `EXTRA_CORS_ORIGINS` env var.
- **Migrations**: schema changes go through `prisma migrate dev` locally, then `prisma migrate deploy` on the home server (not `db push`, to avoid destructive drift on real data).
- **Backups**: nightly `pg_dump` with 7-day local retention, encrypted offsite copy.

Full runbook: [Home Server Runbook](HOME_SERVER_RUNBOOK.md).

---

## Documentation

| File                           | Contents                                         |
| ------------------------------ | ------------------------------------------------ |
| `PROJECT_SPEC.md`              | Full product specification (v4)                  |
| `PROJECT_STATUS.md`            | Detailed progress log — every session documented |
| `STABILITY_PLAN.md`            | Security + reliability hardening (Phases A–C)    |
| `STYLE_CENTRALIZATION_PLAN.md` | iOS Theme.swift centralization guide             |
| `ios/STYLING_GUIDE.md`         | Portable iOS styling reference for agents        |
| `TESTING_PLAN.md`              | Testing approach + 1000-user target              |
| `TODO.md`                      | 25-issue security/perf audit tracker             |
| `SERVER_URL_PATTERN.md`        | iOS ServerConfig URL construction patterns       |

---

## License

Private — internal use only. No open-source license. Contact the author for usage terms.
