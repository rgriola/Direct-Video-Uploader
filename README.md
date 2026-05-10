# Direct Video Uploader (DVU) — Mediasource Fixer

**Direct Video Uploader** is a mobile-first video upload platform disguised as a text conversation. Field crew members "text" full-resolution videos to the **Mediasource Fixer** server, which processes them the way a news assignment desk operates — fast, structured, and integrated with Slack.

The UX is intentionally modeled after Apple Messages: the user opens a conversation with **"Fixer"**, selects a video, taps send, fills out a slug form, and the server replies back with metadata, a clip viewer link, and a one-tap Slack post. Under the hood, videos upload directly to **Mux** via tus protocol, bypassing the server entirely.

> **Status:** Phase 3 (~99%) — Mux pipeline operational, Slack integration live, Apple Speech transcription, admin tools, archive, video trim, stability hardening complete. See `PROJECT_STATUS.md` for full details.

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
7. **Clip viewer** at `/clips/:slug` is a public, server-rendered page with Mux player.

---

## What's in This Repo

```
Direct-Video-Uploader/
├── ios/                    # iOS app (SwiftUI, iOS 17+)
│   ├── project.yml         # XcodeGen project definition
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
├── render.yaml             # Render deployment blueprint
├── PROJECT_SPEC.md         # Full product specification (v4)
├── PROJECT_STATUS.md       # Detailed progress log with every session
├── STABILITY_PLAN.md       # Security + reliability hardening (Phases A–C)
├── TESTING_PLAN.md         # Testing approach
└── TODO.md                 # Backlog tracker
```

---

## Quick Start (Local Dev)

### Prerequisites

- **Node.js** 20+ and **npm**
- **PostgreSQL** (Prisma manages schema)
- **Xcode 16+** with iOS 17 SDK (for the iOS app)
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
cd ios && xcodegen generate
# Open DirectVideoUploader.xcodeproj in Xcode, build to device
```

> **Tip:** For tethered device testing, update `ServerConfig.swift` with your Mac's LAN IP.

---

## Scripts

| Command               | What it does                                                           |
| --------------------- | ---------------------------------------------------------------------- |
| `npm run dev`         | **Triad launcher** — DB + Server `:3000` + Admin `:5173` (recommended) |
| `npm run dev:admin`   | Starts Vite dev server only on `:5173`                                 |
| `npm run build:admin` | Production build of React admin → `server/public/` (Vite only, fast)   |
| `npm run server`      | Starts Fastify server only                                             |
| `npm run setup`       | Fresh setup: install deps, push schema, generate client, seed          |

---

## Tech Stack

| Layer            | Technology                                    |
| ---------------- | --------------------------------------------- |
| **iOS App**      | SwiftUI + `URLSessionWebSocketTask`           |
| **Server**       | Node.js + Fastify + Socket.IO                 |
| **Database**     | PostgreSQL + Prisma 7 (pg adapter)            |
| **Auth**         | Phone# + PIN → JWT (`@fastify/jwt`)           |
| **Video**        | Mux (direct upload via tus + HLS playback)    |
| **Dashboard**    | React 19 + Vite 6 + TypeScript + Tailwind v4  |
| **Clip Viewer**  | Server-rendered HTML at `/clips/:slug`        |
| **Slack**        | Bot API (`fixer-video` bot)                   |
| **Transcription**| Apple Speech (on-device, opt-in)              |
| **Hosting**      | Render (server + DB) · `ms-fixer.com`        |

---

## Key Features

- **Chat-based UX** — Upload flow feels like texting, not a file manager
- **Mux direct upload** — iOS uploads to Mux CDN via tus protocol (no server bottleneck)
- **Real-time WebSocket** — Greeting, upload progress, form requests, Mux ready notifications, Slack confirmations
- **Context form** — Slug, type, description, priority with auto-focus and swipe-dismiss prevention
- **Video trim** — Pre-upload trimming via native `UIVideoEditorController`
- **PHAsset fast path** — Zero-copy video loading from Photos library (instant, no file copy)
- **Slack integration** — Post to `#channels` or DM `@users` with thumbnail, clip link, and metadata
- **Clip viewer** — Public shareable page with Mux player, metadata, transcript
- **Apple Speech** — On-device transcription with newsroom vocabulary, per-word timestamps
- **Archive** — 7-day history with status dots, thumbnails, re-upload, form submission. Slug shown as primary display name; format row combines resolution + codec
- **Photos tab** — Placeholder for upcoming photo upload pipeline (TBD feature)
- **Profile** — User info, Photo Library + Speech Recognition permission toggles with live status, app info
- **In-app instructions** — 5-page swipeable guide: First Things, iPhone Media, Steps to Use Fixer, What's Happening Inside Fixer, Archive. SF Symbol icons inline
- **Server greetings** — 40+ randomized greeting combos using first name only, feature tips, no consecutive repeats. Greets every device independently
- **Device tracking** — iOS sends `deviceId`, `deviceName`, `deviceModel` in WebSocket handshake auth. Server logs per-device connections
- **Admin dashboard** — Stats, user management, asset list, nuclear reset, error logs

---

## Demo Credentials

| User          | Phone        | PIN    | Role  |
| ------------- | ------------ | ------ | ----- |
| Rod Griola    | `9176717330` | `3218` | ADMIN |
| David Burgess | `5055034455` | `1234` | USER  |
| Carrie Smith  | `5055551234` | `1234` | USER  |

---

## Environment Variables

The server expects these in `server/.env` (see `.env.example`):

| Variable           | Required | Description                          |
| ------------------ | -------- | ------------------------------------ |
| `DATABASE_URL`     | Yes      | PostgreSQL connection string         |
| `JWT_SECRET`       | Yes*     | JWT signing secret (*auto-generates) |
| `MUX_TOKEN_ID`     | Yes      | Mux API token ID                     |
| `MUX_TOKEN_SECRET` | Yes      | Mux API token secret                 |
| `MUX_WEBHOOK_SECRET`| Yes     | Mux webhook signing secret           |
| `SLACK_BOT_TOKEN`  | No       | Slack bot OAuth token (`xoxb-...`)   |
| `PUBLIC_URL`       | No       | Public URL for clip links            |
| `NODE_ENV`         | No       | `production` enables SSL, trust proxy|

---

## Deployment (Render)

The repo includes `render.yaml` for Render Blueprint deploys:

```bash
# Render auto-deploys from main branch
# Build: npm ci → build admin → prisma generate → prisma db push → seed
# Start: cd server && node src/index.js
```

Custom domain: `ms-fixer.com` · Managed PostgreSQL · No cold starts (paid tier).

---

## Documentation

| File                          | Contents                                           |
| ----------------------------- | -------------------------------------------------- |
| `PROJECT_SPEC.md`            | Full product specification (v4)                    |
| `PROJECT_STATUS.md`          | Detailed progress log — every session documented   |
| `STABILITY_PLAN.md`          | Security + reliability hardening (Phases A–C)      |
| `STYLE_CENTRALIZATION_PLAN.md`| iOS Theme.swift centralization guide               |
| `ios/STYLING_GUIDE.md`       | Portable iOS styling reference for agents          |
| `TESTING_PLAN.md`            | Testing approach + 1000-user target                |
| `TODO.md`                    | 25-issue security/perf audit tracker               |
| `SERVER_URL_PATTERN.md`      | iOS ServerConfig URL construction patterns         |

---

## License

Private — internal use only. No open-source license. Contact the author for usage terms.
