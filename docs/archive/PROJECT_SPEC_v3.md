# Fixer — Project Specification v3

> **Last Updated:** April 15, 2026
> **Status:** Active development — TestFlight / Enterprise distribution
> **Platform:** iOS (SwiftUI) + Node.js server + React admin dashboard

---

## 1. What Fixer Is

Fixer is a **professional video upload platform** for field journalists and media crews. Users select a video from their iPhone, upload it to cloud storage (Mux.com), fill in a slug/description, and get a shareable clip link — all from a native iOS app that feels like a chat interface.

This is **not** an MMS-based system. The current platform uses a direct iOS → server → Mux pipeline.

---

## 2. System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        FIXER TRIAD                              │
│                                                                 │
│  iOS App (SwiftUI)          Admin Dashboard (React/Vite)        │
│  ├─ LoginView               ├─ LoginForm                        │
│  ├─ ChatView (upload)       ├─ UserList                         │
│  ├─ ArchiveListView         ├─ OrgPanel                         │
│  ├─ ProfileView             ├─ AdminTools                       │
│  └─ InstructionsView        └─ ErrorLog                         │
│          │                          │                           │
│          └──────────────┬───────────┘                           │
│                         ▼                                       │
│              Fastify Server (:3000)                             │
│              ├─ /api/auth/*     (login, me)                     │
│              ├─ /api/assets/*   (upload, list)                  │
│              ├─ /api/admin/*    (CRUD, stats, orgs)             │
│              ├─ /clips/*        (viewer, auth)                  │
│              ├─ WebSocket       (Socket.IO real-time)           │
│              └─ Mux webhooks    (processing callbacks)          │
│                         │                                       │
│              PostgreSQL (Prisma ORM)                            │
│              Mux.com (video processing + streaming CDN)         │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Authentication System

### 3.1 iOS App Login

- **Credentials:** Phone number + PIN (bcrypt) + Company Code
- **Token:** JWT (7-day expiry), stored in iOS Keychain
- **Session validation:** On every app launch, `/api/auth/me` is called to validate the token before the main UI appears. Invalid tokens force a return to LoginView.
- **Rate limiting:** 5 login attempts per minute per IP

### 3.2 Admin Dashboard Login

- **Credentials:** Phone number + PIN (same user table)
- **Token:** JWT stored in `localStorage` as `fixer_admin_token`
- **Role check:** Server enforces `role === 'ADMIN'` on all `/api/admin/*` routes
- **Non-admin users:** See only their organization's clips (org-scoped filtering)

### 3.3 Clip Viewer Login

- **Who:** Anyone with a shareable clip URL (journalists, recipients)
- **Credentials:** Phone number + PIN + Company Code (same user table)
- **Token:** JWT stored as an **HttpOnly cookie** (`fixer_clip_token`, 7-day expiry, scoped to `/clips`)
- **Org-scoped:** Users see only clips from their own organization
- **Admin bypass:** ADMIN role sees all clips regardless of org
- **Routes:**
  - `GET /clips/login` — login form (dark-themed, no app required)
  - `POST /clips/login` — validates, sets cookie, redirects to clip
  - `POST /clips/logout` — clears cookie

### 3.4 Public Routes (No Auth Required)

| Route | Reason |
|-------|--------|
| `/privacy-policy.html` | Required for App Store / TestFlight compliance |
| `/api/health` | Infrastructure monitoring |
| `/clips/login` | Must be reachable unauthenticated |
| Dashboard static assets | Required for admin login page |

---

## 4. Organizational Accounts

Fixer supports multi-tenant organizational accounts. Each organization has:
- **Company Name** — up to 50 letters (no numbers or special characters)
- **Company Code** — 3–4 letters, mixed case (e.g. `CNN`, `ABCn`)
- **Created At** — server timestamp when admin added the org

### 4.1 User ↔ Organization Relationship

- Each user may belong to **one organization** (via `companyCode` foreign key)
- A phone number is always unique; one user, one org
- Company code is required for iOS login; admin dashboard login does not require it
- Admins can assign/change a user's company via the admin dashboard

### 4.2 Data Visibility

| Role | Sees |
|------|------|
| ADMIN (dashboard) | All users, all assets, all clips |
| Non-admin (dashboard) | Only their organization's clips |
| iOS user | Their own uploads + org's archive |
| Clip viewer (web) | Their org's clips only |

### 4.3 Organization CRUD

- **Create / Edit / Delete** organizations via Admin Dashboard → Org Panel
- **FK-safe code rename:** When renaming a company code, a database transaction (1) notes affected user IDs, (2) nulls the FK, (3) updates the org, (4) re-assigns by ID — prevents foreign key constraint errors
- **Nuclear reset** explicitly skips the Organization table (enterprise config is preserved)

---

## 5. Video Upload Pipeline

### 5.1 User Flow (iOS)

1. User opens Fixer → taps `+` to open photo library (videos only)
2. Selects video → (optional) trims clip
3. (Optional) enables audio transcription via Apple Speech Recognition
4. Taps upload → video streams to Fixer server
5. Server forwards to **Mux.com** for transcoding + CDN delivery
6. Chat interface shows upload progress
7. After upload: AI-assisted form fields appear (Slug, Description)
8. User fills in required fields → submits
9. Mux processes video; webhook updates status to READY
10. Fixer sends a confirmation message with the clip link
11. User can Slack their team from the metadata chat

### 5.2 Server-Side Processing

| Stage | Detail |
|-------|--------|
| **Receive** | Multipart upload via iOS URLSession |
| **Validate** | JWT authentication + file type check |
| **Forward** | Direct upload to Mux via Mux Upload API |
| **Metadata** | GPS, timestamp, device, codec, duration extracted from video |
| **Webhooks** | Mux fires `video.asset.ready` → server marks clip READY |
| **Notification** | WebSocket pushes confirmation to iOS client |

### 5.3 Archive

- Uploads appear in **Archive** tab upon completion
- Held for 7 days (configurable)
- Archive shows: clip metadata, Slack share button, web clip link
- Incomplete forms can be finished from Archive

---

## 6. Tech Stack (Current)

| Layer | Technology |
|-------|-----------|
| **iOS App** | Swift 5.9+, SwiftUI, `@Observable`, URLSession background upload |
| **Server** | Node.js 20, Fastify 5, Socket.IO |
| **Database** | PostgreSQL 16 via Prisma ORM |
| **Video CDN** | Mux.com (upload, transcoding, HLS streaming) |
| **Admin Dashboard** | React 19, Vite 6, TanStack Query, Socket.IO client |
| **Auth** | JWT (`@fastify/jwt`), bcrypt PIN hashing, HttpOnly cookies for clip viewer |
| **Security** | Helmet, CORS, `@fastify/rate-limit`, CSP in production |
| **Dev runtime** | Single `npm run dev` launches DB check, server, and dashboard (Triad Launcher) |

---

## 7. Database Schema (Key Models)

```prisma
model User {
  id          String   @id @default(uuid())
  name        String
  phoneNumber String   @unique
  email       String?
  team        String?
  role        String   @default("USER")  // USER | ADMIN
  status      String   @default("ACTIVE") // ACTIVE | SUSPENDED
  pinHash     String
  companyCode String?  // FK → Organization.companyCode
  organization Organization? @relation(fields: [companyCode], references: [companyCode])
  lastLoginAt DateTime?
  createdAt   DateTime @default(now())
}

model Organization {
  companyName String    @db.VarChar(50)
  companyCode String    @id  // 3–4 mixed-case letters
  createdAt   DateTime  @default(now())
  users       User[]
}

model Asset {
  id              String   @id @default(uuid())
  userId          String
  mediasourceId   String?  @unique
  mediasourceUrl  String?
  originalFileName String?
  status          String   @default("PROCESSING")
  // ... GPS, timestamps, file metadata
}

model Clip {
  id           String  @id @default(uuid())
  assetId      String
  muxPlaybackId String?
  muxAssetId   String?
  status       String  @default("PROCESSING") // PROCESSING | READY | ERROR
}
```

---

## 8. API Reference

### Auth
| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `POST` | `/api/auth/login` | — | Phone + PIN + companyCode → JWT |
| `GET` | `/api/auth/me` | Bearer | Current user profile |

### Assets (iOS)
| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `POST` | `/api/assets/upload` | Bearer | Upload video |
| `GET` | `/api/assets` | Bearer | List user's assets (org-filtered for non-admin) |
| `PATCH` | `/api/assets/:id/form` | Bearer | Submit slug/description form |

### Admin
| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/admin/stats` | Admin | Upload stats |
| `GET` | `/api/admin/users` | Admin | All users |
| `POST` | `/api/admin/users` | Admin | Create user |
| `PATCH` | `/api/admin/users/:id` | Admin | Update user (name, company, etc.) |
| `DELETE` | `/api/admin/users/:id` | Admin | Hard delete user + all data |
| `GET` | `/api/admin/organizations` | Admin | List all orgs |
| `POST` | `/api/admin/organizations` | Admin | Create org |
| `PUT` | `/api/admin/organizations/:code` | Admin | Update org (FK-safe) |
| `DELETE` | `/api/admin/organizations/:code` | Admin | Delete org |
| `POST` | `/api/admin/nuclear-reset` | Admin | Wipe all assets/clips (preserves users + orgs) |

### Clip Viewer (Web)
| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/clips/login` | — | Login form page |
| `POST` | `/clips/login` | — | Authenticate → set cookie |
| `POST` | `/clips/logout` | Cookie | Clear session |
| `GET` | `/clips/:mediasourceId` | Cookie | Clip viewer page |
| `GET` | `/clips/:mediasourceId/status` | Cookie | Playback readiness check |

---

## 9. Security Summary

| Control | Implementation |
|---------|---------------|
| **PIN hashing** | bcrypt (auto-migration from SHA-256) |
| **JWT** | 7-day expiry, signed with `JWT_SECRET` env var |
| **Clip viewer session** | HttpOnly cookie, `SameSite=Lax`, scoped to `/clips` |
| **Rate limiting** | 5/min on login; 100/min global |
| **Admin authorization** | Two-layer: `authenticate` + `authorizeAdmin` decorators |
| **Org-scoped data** | Non-admin users see only their organization's content |
| **Account suspension** | `status !== 'ACTIVE'` check on every login |
| **XSS prevention** | `escapeHtml()` on all server-rendered clip viewer output |
| **Security headers** | Helmet: HSTS, X-Frame-Options, CSP (production) |
| **CORS** | Origin-restricted (configured per environment) |
| **Nuclear reset** | Skips Organization table — enterprise config preserved |

---

## 10. Distribution

### Current Path: TestFlight (Recommended for Demo)

- **Public link** — create in App Store Connect → TestFlight → External Testing → Enable Public Link
- Share the link over Zoom / Slack — recipients tap it, no email collection required
- Supports up to 10,000 testers
- Beta review only (~24 hours, lighter than full App Store review)

### Enterprise Path: Apple Business Manager

- Custom Apps distributed privately to specific organizations
- No App Store listing required
- Appropriate for newsrooms with MDM
- Matches the current company-code architecture

### App Store (Future)

- Requires self-service user sign-up, Apple In-App Purchase for paid tiers
- Significant architecture changes needed (BYOS, email/password auth)
- Not the immediate priority

---

## 11. Known Issues & Roadmap

See [`known-issues.md`](../known-issues.md) for the full tracked list.

**Top priorities:**

1. **Chat UI reset** — After a new video is selected, the chat should reset with a "Conversation moved to Archive" panel + fresh greeting
2. **Upload/message ordering** — iOS and server both emit chat messages; need a single source of truth for ordering
3. **Trim view improvements** — Playhead timecode display, time markers, "preserve original" option
4. **Video library reset** — "Video queued" / GPS labels should clear when user fully deselects
5. **WebSocket reconnect noise** — Suppress handshake messages during active Mux uploads

---

*Spec v3 written April 15, 2026 — reflects the actual built system*
*Previous specs: PROJECT_SPEC_v1.md (original concept), PROJECT_SPEC_v2.md (MMS-first architecture)*
