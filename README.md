# Direct Video Uploader (DVU)

**Direct Video Uploader** is a demo-first system for sending full‑resolution videos from an iOS app to a backend **as if you were texting a contact**.

The UX is intentionally modeled after Apple Messages: the user opens a conversation with the server contact **“Mediasource Fixer”** (`800-123-4567`), selects a video, taps send, and the server replies back in the same thread with metadata, next steps, and confirmation. Under the hood, the upload is handled via a persistent **WebSocket** connection with a Node.js backend.

## What’s in this repo

This repository is a monorepo with:

- **`server/`** — Node.js backend (Fastify + Socket.IO + Prisma)
- **`admin/`** — Admin UI (Vite + React + Tailwind)
- **`ios/`** — iOS client (Swift / SwiftUI)
- **`scripts/`** — local/dev + deploy helper scripts
- **`render.yaml`** — Render deployment configuration
- Project docs/specs:
  - `PROJECT_SPEC.md`
  - `PROJECT_STATUS.md`
  - `TESTING_PLAN.md`
  - `STABILITY_PLAN.md`
  - `STYLE_CENTRALIZATION_PLAN.md`
  - `TODO.md`

## High-level architecture

1. iOS app opens a chat-style conversation with the server contact (**Mediasource Fixer**).
2. App authenticates and connects to the backend over WebSockets.
3. User sends a video; the app uploads at full resolution.
4. Server stores the video, extracts metadata, and responds in-chat (and can optionally post to Slack).
5. Admin UI is intended for Phase 2 (managing users/devices, backend operations, etc).

## Prerequisites

- Node.js (modern version recommended)
- npm
- (For backend) a Postgres database (Prisma is used)
- (Optional) Render account for deployment
- (Optional) Accounts/keys depending on integrations:
  - Mux (video pipeline/storage)
  - Slack (posting messages)

## Getting started (local dev)

### 1) Install dependencies

From the repo root:

```bash
npm run setup
```

This runs installs in `server/` and `admin/`.

### 2) Start the backend

```bash
npm run dev:server
```

> The server dev script uses Prisma and runs the API with `nodemon`.

### 3) Start the admin UI

In a second terminal:

```bash
npm run dev:admin
```

### 4) (Optional) Start everything via root dev script

```bash
npm run dev
```

> `npm run dev` runs `node scripts/dev.js` (see `scripts/` for what it orchestrates).

## Build

### Build the admin UI

```bash
npm run build:admin
```

## Deployment (Render)

This repo includes `render.yaml` and a root build hook:

```bash
npm run render:build
```

Render should ultimately run the root `start` script:

```bash
npm start
```

Which starts the backend via:

```bash
cd server && node src/index.js
```

## Configuration

The server uses `dotenv` and expects environment variables for things like:

- Database connection (Postgres)
- Auth/token settings
- Mux credentials (if enabled)
- Slack credentials (if enabled)

Check the `server/` code and any example env files (if present) to see the full list of required variables.

## Scripts (root)

Common root scripts (from `package.json`):

- `npm run setup` — install deps for `server/` and `admin/`
- `npm run dev:server` — run backend dev server
- `npm run dev:admin` — run admin dev server
- `npm run build:admin` — build the admin UI
- `npm run start` — start backend (production-style)
- `npm run render:build` — Render build hook

## Documentation

Start here:

- `PROJECT_SPEC.md` — the “why” and the end-to-end product/architecture plan
- `PROJECT_STATUS.md` — progress notes / current state
- `TESTING_PLAN.md` — testing approach
- `TODO.md` — backlog

## Roadmap (very high level)

- Phase 1: demo iOS app + WebSocket upload + server replies
- Phase 2: admin UI for user/device management and backend operations
- Integrations: Slack posting, external video/storage pipeline (e.g. Mux)

## License

No license file is included yet. If you want this to be open source, add a `LICENSE` file (MIT/Apache-2.0/etc). If this is internal-only, keep it private and document intended usage here.
