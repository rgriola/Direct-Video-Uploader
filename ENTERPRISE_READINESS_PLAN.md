Last updated: May 12, 2026 - 2:44pm - GitHub Copilot (GPT-5.3-Codex)

# Enterprise Readiness Plan — Fixer

> Last updated: May 12, 2026
> Status: Execution in progress. Core foundation and security quick wins are partially implemented.
> Progress sync: Items checked below were verified in code/config as implemented. Unchecked items are pending or partially complete.

This document is a phased roadmap to bring Fixer to enterprise-grade quality.
Each phase is designed to be independently shippable. Phases are ordered by risk/impact.

---

## Plan Review Notes (Self-Critique)

This plan was reviewed on April 27, 2026. Issues found and corrected below:

### Reasoning corrections applied

- **Redis moved earlier.** Token revocation (1.1) and Redis-backed rate limiting (1.5) both require Redis. Redis is now Phase 0.4 instead of buried in Phase 6.1.
- **Prisma middleware is deprecated.** Soft delete plan (3.2) updated to use Prisma Client Extensions (`$extends`), not the legacy `$use` middleware.
- **Sentry SDK corrected.** Admin dashboard is React + Vite, so use `@sentry/react`, not `@sentry/sveltekit`.
- **MFA scope clarified.** SSO users inherit MFA from their IdP (Okta/Azure already enforce it). MFA work in 2.3 is now explicitly scoped to non-SSO (PIN) users only — saves ~1 week.
- **CSRF scope narrowed.** All API endpoints use `Authorization: Bearer` (JWT), which is CSRF-immune. Only the cookie-authenticated clip viewer login form needs CSRF tokens.
- **`db push --accept-data-loss` in production is a critical risk.** Promoted from Phase 6.3 to Quick Win + Phase 0.5. Switching to versioned migrations (`prisma migrate deploy`) is a prerequisite before any other schema work.
- **Quick win #7 removed.** No token refresh endpoint exists today; the suspended-user check belongs inside the existing `authenticate` decorator instead.
- **Effort estimates clarified** to "1 full-time engineer." With 2 engineers and parallelizable phases, ~3–4 months is realistic.

### Items added (were missing entirely)

- Staging environment (Phase 0.6) — currently prod-only on Render
- Real job queue with BullMQ (Phase 6.5) — replaces fragile `setInterval` jobs
- Socket.IO Redis adapter (Phase 6.6) — required for horizontal scaling
- Dependency & supply-chain security (Phase 0.7) — Dependabot, npm audit in CI, lockfile policy
- Feature flags (Phase 4.5) — safe progressive rollouts
- iOS hardening (new Phase 9) — certificate pinning, App Attest, MDM/managed app config
- Operational readiness (new Phase 10) — status page, SLA, incident response runbook, security.txt, on-call
- Data residency & sub-processor disclosure (added to Phase 8.3) — EU enterprise clients will ask
- Transactional email infrastructure (Phase 2.5) — broader than just invites

### Items intentionally NOT added

- **WAF / Cloudflare in front of Render** — premature; Render's edge already handles basic DDoS. Revisit only if abuse becomes a real problem.
- **Bug bounty program** — wait until after Phase 8 pen test. Premature programs generate noise.
- **HashiCorp Vault** — overkill at current scale. Render env vars + rotation discipline is sufficient until headcount > 10.

---

## Phase 0 — Foundation (Do Before Anything Else)

These are prerequisites that every subsequent phase depends on.

### 0.1 Automated Testing Infrastructure

**Why first:** You can't refactor auth, RBAC, or validation safely without a test harness.

- [x] Add Vitest (or Jest) to `server/package.json`
- [x] Create `server/src/__tests__/` directory structure mirroring `routes/`, `lib/`, `jobs/`
- [x] Write smoke tests for every existing route (status codes only — no logic yet)
- [x] Add GitHub Actions workflow: `.github/workflows/ci.yml`
  - Runs on every push and PR to `main`
  - Steps: `npm ci` → `npx prisma generate` → `vitest run`
- [x] Add test coverage reporting (Istanbul/c8)
- [x] Set minimum coverage gate at 60% to start; raise to 80% by Phase 3

**Files to create:**

```
server/src/__tests__/
  routes/auth.test.js
  routes/assets.test.js
  routes/admin.test.js
  routes/clips.test.js
  lib/utils.test.js
.github/workflows/ci.yml
```

---

### 0.2 Request Correlation IDs

**Why first:** Every log, error, and audit entry needs a trace ID.

- [x] Add `@fastify/request-context` or a UUID middleware
- [x] Generate `X-Request-ID` on every incoming request (use header if provided, else generate)
- [x] Attach `requestId` to Pino logger child instance for each request
- [x] Return `X-Request-ID` in every response header
- [x] Thread `requestId` through to Slack alerts and error logs

**Files to modify:**

- `server/src/index.js` — add middleware
- `server/src/lib/` — create `requestContext.js`

---

### 0.3 OpenAPI/Swagger Documentation

**Why first:** All future endpoints should be documented as they're written.

- [x] Install `@fastify/swagger` and `@fastify/swagger-ui`
- [x] Enable `/api/docs` endpoint (admin-authenticated in production)
- [ ] Add JSON Schema to every existing route's Fastify schema (body, params, querystring, response)
- [ ] Auto-generate from schemas — no hand-written YAML

> Note: Swagger output stays incomplete until Phase 1.2 lands schemas on every route. The plugin is registered in Phase 0 so schemas added later auto-publish.

**Files to modify:**

- `server/src/index.js` — register swagger plugin
- All files in `server/src/routes/` — add full schema objects

---

### 0.4 Redis (Prerequisite for Phases 1.1, 1.5, 6.5, 6.6)

**Why first:** Token revocation, distributed rate limiting, BullMQ job queue, and Socket.IO horizontal scaling all depend on Redis. Provisioning it once up-front avoids stop-and-restart later.

- [ ] Add Render Redis (or Upstash) to `render.yaml`
- [ ] Add `REDIS_URL` env var (with TLS in production)
- [ ] Create `server/src/lib/redis.js` — `ioredis` singleton with reconnect/backoff
- [ ] Add Redis ping to `/api/health/ready` (Phase 4.3)
- [ ] Document local-dev fallback: in-memory shim when `REDIS_URL` is unset

---

### 0.5 Versioned Migrations (Stop `db push` in Production)

**Why first / CRITICAL:** `render.yaml` currently runs `npx prisma db push --accept-data-loss` on every deploy. This silently drops columns and bypasses migration history. No serious enterprise client will accept this.

- [ ] Switch local dev to `npx prisma migrate dev`
- [ ] Generate baseline migration from current production schema (`prisma migrate diff` → SQL)
- [x] Replace `prisma db push --accept-data-loss` with `prisma migrate deploy` in `render.yaml`
- [ ] Commit `server/prisma/migrations/` directory
- [ ] Add migration review to PR checklist (any schema change requires a migration file in the diff)
- [ ] Document rollback procedure (Render rollback + `prisma migrate resolve --rolled-back`)

---

### 0.6 Staging Environment

**Why first:** All subsequent phases need a non-prod target to validate against before shipping.

- [x] Add a `staging` service to `render.yaml` (separate DB, separate Redis, separate Mux env)
- [x] Auto-deploy staging from a `staging` branch
- [x] Use a separate Mux environment key (`MUX_ENV_KEY` already supports this)
- [x] Use a separate Slack channel for staging alerts
- [x] iOS: add `Debug-Staging` build configuration in `project.yml` pointing at staging URL
- [x] Document promotion flow: `staging` → `main` PR after smoke tests pass

---

### 0.7 Supply Chain & Dependency Security

- [x] Enable Dependabot for `server/`, `admin/`, root `package.json` (weekly cadence)
- [x] Add `npm audit --audit-level=high` step to CI; fail build on high/critical
- [x] Add `npm-audit-resolver` for tracked exceptions (`server/audit-resolve.json` + `check-audit` in CI)
- [x] Pin lockfile (`package-lock.json`) — already present, but add `npm ci --frozen-lockfile` to CI
- [x] Add CodeQL workflow for static analysis (free for public repos; ~$X/mo for private)
- [x] Document policy: no new dependency without license check (no GPL/AGPL in app code) in `SECURITY.md`

---

## Phase 1 — Security & Auth Hardening

> Note: Full SSO/SAML is tracked separately in Phase 2. This phase hardens existing auth.

### 1.1 Token Revocation (Server-Side Sessions)

**Problem:** Lost device = no way to invalidate a JWT.

> Depends on Phase 0.4 (Redis).

- [ ] Use Redis from Phase 0.4 to store token JTI (JWT ID) with TTL matching token expiry
  - On logout: delete JTI from Redis
  - On every auth check: verify JTI exists in Redis (or use a deny-list pattern for lower latency)
- [ ] Add `jti` claim to JWT payload at login
- [ ] Add `POST /api/auth/logout` endpoint (deletes JTI)
- [ ] Add `POST /api/admin/users/:id/revoke-sessions` endpoint (admin forcibly logs out a user)
- [ ] iOS: call logout endpoint on explicit sign-out; clear Keychain token

**Files to modify:**

- `server/src/routes/auth.js`
- `server/src/index.js` — Redis connection
- `server/src/middleware/` — create `verifyJti.js`
- `ios/DirectVideoUploader/Services/AuthService.swift`

---

### 1.2 Input Validation — Global Enforcement

**Problem:** Several POST endpoints accept unvalidated input.

- [ ] Add Fastify JSON Schema to every route that currently lacks it:
  - `POST /api/assets/:id/form` — slug (maxLength 50, pattern), description (maxLength 500)
  - `POST /api/assets` — fileName, duration, fileSize, codec
  - `PATCH /api/assets/:id` — partial update schema
  - `POST /api/admin/users` — phoneNumber format, role enum, companyCode
  - `POST /api/admin/messages` — maxLength on content
- [x] Add `ajv-formats` for email and date-time format validation
- [x] Fix raw SQL in `server/src/routes/admin.js` — parameterize `companyCode` query
- [x] Add file MIME type check before creating Mux upload (reject non-video)
- [x] Global error handler for Fastify validation errors → consistent 422 response format

**Files to modify:**

- `server/src/routes/admin.js` — fix SQL injection risk
- All route files — add schemas
- `server/src/index.js` — add global validation error handler

---

### 1.3 PII Redaction in Logs

**Problem:** Phone numbers and company codes logged in plaintext.

- [x] Create `server/src/lib/redact.js` — utility to mask PII (`555****4455`)
- [x] Add Pino `redact` config to mask `phoneNumber`, `companyCode`, `token` fields
- [ ] Audit all `console.log` / `fastify.log` calls — replace direct phone/PIN logging
- [x] Add redaction to Slack alert messages (partial masking for context)

**Files to modify:**

- `server/src/index.js` — Pino redact config
- `server/src/lib/` — create `redact.js`
- `server/src/routes/clips.js` — line ~236 (clip viewer login log)
- `server/src/routes/auth.js`

---

### 1.4 Security Headers & CSRF

- [x] Audit current Helmet config — add missing headers:
  - `Permissions-Policy: camera=(), microphone=(), geolocation=()`
  - `Cache-Control: no-store` on auth endpoints
- [x] Add CSRF protection ONLY to cookie-authenticated endpoints (the clip viewer login form / `/clips/login`). All `/api/*` routes use `Authorization: Bearer` JWT and are CSRF-immune by design — do NOT add CSRF tokens there.
  - Use `@fastify/csrf-protection` with synchronizer token pattern on the clip viewer form
- [x] Remove stack traces from production error responses
  - Fastify error handler should return only `{ error, code, requestId }` in production
- [x] Enable Mux webhook signature verification unconditionally
  - Remove `if (process.env.NODE_ENV !== 'production')` bypass in `mux-webhooks.js`

**Files to modify:**

- `server/src/index.js`
- `server/src/routes/mux-webhooks.js`
- `server/src/routes/clips.js`

---

### 1.5 Rate Limiting — Per-User + Redis-Backed

**Problem:** In-memory rate limiting breaks on multi-instance; no per-user limits.

> Depends on Phase 0.4 (Redis).

- [ ] Switch `@fastify/rate-limit` store to Redis
- [ ] Add per-user rate limiting on authenticated routes (by userId from JWT)
- [ ] Add `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` headers
- [ ] Add WebSocket message throttling in `server/src/ws/handler.js`
  - Max 10 messages/10s per connection; disconnect on sustained abuse
- [ ] Add dedicated limit for Mux upload creation: 5/hour per user

**Files to modify:**

- `server/src/index.js`
- `server/src/ws/handler.js`
- `server/src/routes/assets.js`

---

## Phase 2 — Identity & Access Management

### 2.1 Expanded RBAC

**Problem:** Only ADMIN and USER roles; no org-level control.

New role model:

```
SUPER_ADMIN  → can manage all orgs, all users, system config
ORG_ADMIN    → can manage users within their org, view all org clips
EDITOR       → can upload, submit forms, view all org clips
VIEWER       → read-only clip access within their org
```

- [ ] Add `role` enum values to Prisma schema: `SUPER_ADMIN`, `ORG_ADMIN`, `EDITOR`, `VIEWER`
- [ ] Write migration to map existing `ADMIN` → `SUPER_ADMIN`, `USER` → `EDITOR`
- [ ] Create `server/src/middleware/authorize.js` — decorator factory:
  ```js
  fastify.decorate('authorize', (roles) => async (req, reply) => { ... })
  ```
- [ ] Replace all `fastify.authorizeAdmin` calls with `fastify.authorize(['SUPER_ADMIN'])`
- [ ] Add `ORG_ADMIN` guards to org-level management endpoints
- [x] Update JWT payload to include role
- [ ] Update iOS `AuthService.swift` to read and store role from JWT
- [ ] Update admin dashboard — show role badge per user; allow role changes by SUPER_ADMIN

**Files to modify:**

- `server/prisma/schema.prisma`
- `server/src/index.js`
- `server/src/middleware/` — create `authorize.js`
- `server/src/routes/admin.js`
- `server/src/routes/assets.js`
- `ios/DirectVideoUploader/Models/User.swift`
- `ios/DirectVideoUploader/Services/AuthService.swift`

---

### 2.2 SSO / OAuth2 (Enterprise Identity)

**Problem:** Phone + PIN won't pass enterprise IT review.

- [ ] Add `passport-saml` or `openid-client` to server
- [ ] Add `POST /api/auth/sso/saml` callback endpoint
- [ ] Add `GET /api/auth/sso/metadata` — expose SP metadata XML for Okta/Azure AD setup
- [ ] Org-level SSO config: `Organization` model gets `ssoEnabled`, `samlMetadataUrl`, `samlEntityId`
- [ ] Login flow: if org has SSO enabled, redirect to IdP instead of PIN screen
- [ ] Fallback: PIN login remains for orgs without SSO
- [ ] iOS: detect SSO orgs — open `ASWebAuthenticationSession` for SAML flow
- [ ] Admin: UI to configure SSO per org (entity ID, metadata URL, attribute mapping)

**Files to modify/create:**

- `server/src/routes/` — create `auth-sso.js`
- `server/prisma/schema.prisma` — add SSO fields to Organization
- `ios/DirectVideoUploader/Services/AuthService.swift`
- `ios/DirectVideoUploader/Views/Auth/` — SSO login view

---

### 2.3 MFA (Multi-Factor Authentication) — for non-SSO users only

> SSO users (Phase 2.2) inherit MFA from their IdP. This phase only applies to PIN-authenticated users (orgs without SSO configured). This scoping cuts MFA work roughly in half.

- [ ] Implement TOTP-based MFA (Google Authenticator compatible) using `otplib`
- [ ] Add `mfaEnabled`, `mfaSecret` (encrypted at rest using `JWT_SECRET`-derived key or KMS), `mfaBackupCodes` (hashed) to User model
- [ ] Add endpoints:
  - `POST /api/auth/mfa/setup` — generate TOTP secret + QR code + 10 backup codes
  - `POST /api/auth/mfa/verify` — verify TOTP and complete login
  - `POST /api/auth/mfa/disable` — admin or self (with re-auth)
  - `POST /api/auth/mfa/backup-code` — single-use recovery codes
- [ ] Login flow: if MFA enabled, issue short-lived (5 min) `mfa_pending` JWT; full JWT after TOTP
- [ ] iOS: `MFAVerifyView.swift` — 6-digit code entry screen
- [ ] Admin: toggle MFA enforcement per org (opt-in vs. required for non-SSO users)

---

### 2.4 Org User Management

**Problem:** No invite/remove flows; users created only by global admin.

- [ ] Add `UserInvite` model: `id`, `email`, `orgCode`, `role`, `token` (hashed), `expiresAt`, `usedAt`, `invitedBy`
- [ ] Add endpoints:
  - `POST /api/admin/users/invite` — ORG_ADMIN can invite by email
  - `GET /api/auth/invite/:token` — validate invite token
  - `POST /api/auth/invite/:token/accept` — set PIN, create user account
- [ ] Add `POST /api/admin/users/:id/suspend` — sets `status: SUSPENDED`, revokes JTIs
- [ ] Add `DELETE /api/admin/users/:id` — soft delete with `deletedAt` timestamp
- [ ] Admin dashboard: invite button, suspend/delete user actions

---

### 2.5 Transactional Email Infrastructure

**Why:** Invites, password resets, security alerts, and audit notifications all need reliable delivery. Building this once is cheaper than retrofitting.

- [ ] Pick a provider: Resend (simplest), AWS SES (cheapest at scale), or Postmark (best deliverability)
- [ ] Create `server/src/lib/email.js` — `sendEmail({ to, template, data })`
- [ ] Set up SPF, DKIM, DMARC for `ms-fixer.com` sending domain
- [ ] Build templates: invite, password-reset, security-alert (new device login), MFA-disabled
- [ ] Handle bounces: webhook from provider → mark email invalid, alert admin
- [ ] Add unsubscribe link to non-transactional emails (CAN-SPAM compliance)
- [ ] Add rate limit: max 5 emails/hour per recipient (anti-abuse)

---

## Phase 3 — Audit, Compliance & Data Governance

### 3.1 Audit Log System

**Problem:** No persistent record of who did what.

- [ ] Add `AuditLog` Prisma model:
  ```
  id          String   @id @default(uuid())
  userId      String?
  orgCode     String?
  action      String   // CREATE_ASSET, SUBMIT_FORM, DELETE_USER, etc.
  resourceType String  // asset, user, clip, org
  resourceId  String?
  ipAddress   String?
  userAgent   String?
  requestId   String?
  metadata    Json?    // before/after for updates
  createdAt   DateTime @default(now())
  ```
- [ ] Create `server/src/lib/audit.js` — `logAction(req, action, resource, metadata)`
- [ ] Add audit calls to every state-changing endpoint:
  - Auth: login, logout, failed login, PIN change
  - Assets: create, update, delete
  - Clips: form submit, status change
  - Users: create, suspend, delete, role change
  - Admin: cleanup, reset actions
- [ ] Add `GET /api/admin/audit-logs` — paginated, filterable by user/action/date
- [ ] Admin dashboard: AuditLog component (searchable table)
- [ ] Retention policy: auto-delete audit logs older than 2 years (configurable)

---

### 3.2 Soft Deletes

**Problem:** Hard deletes make GDPR compliance and accidental-delete recovery impossible.

- [ ] Add `deletedAt DateTime?` to: `User`, `Asset`, `Clip`, `FormResponse`, `ChatMessage`
- [ ] Use Prisma Client Extensions (`$extends`) to filter out soft-deleted records globally — NOT the legacy `$use` middleware (deprecated in Prisma 5+, removed in Prisma 7)
- [ ] Add per-query escape hatch (`includeSoftDeleted: true`) for admin/audit queries
- [ ] Update all `DELETE` endpoints to set `deletedAt` instead of hard delete
- [ ] Add `POST /api/admin/assets/:id/restore` (SUPER_ADMIN only)
- [ ] Add purge job: hard delete records where `deletedAt < NOW() - retention_days`
- [ ] Configurable retention per org: `Organization.dataRetentionDays`
- [ ] Cascade consideration: deleting a User soft-deletes their assets, but Mux assets must also be deleted at hard-purge time (irreversible billing)

---

### 3.3 GDPR / CCPA Compliance Endpoints

- [ ] `GET /api/users/me/export` — returns all user data as JSON (assets, clips, chat messages, form responses)
- [ ] `POST /api/users/me/delete-request` — triggers soft delete + queues purge within 30 days
- [ ] `GET /api/admin/users/:id/export` — SUPER_ADMIN data export for any user
- [ ] Privacy policy acceptance tracking: `User.privacyAcceptedAt`
- [ ] Terms of service versioning: `User.tosVersion`

---

### 3.4 Data Retention Policies

- [ ] Add `Organization` fields: `videoRetentionDays` (default: 365), `auditRetentionDays` (default: 730)
- [ ] Update `server/src/jobs/` — create `data-retention.js` job:
  - Runs nightly
  - Soft-deletes assets older than org's retention window
  - Hard-deletes records past purge window
  - Deletes Mux assets for purged clips
  - Sends weekly retention summary to SUPER_ADMIN via Slack

---

## Phase 4 — Observability & Error Tracking

### 4.1 Sentry Integration

- [ ] Install `@sentry/node` on server, `@sentry/react` + `@sentry/vite-plugin` on admin (admin is React + Vite, NOT SvelteKit)
- [ ] Initialize Sentry in `server/src/index.js` with:
  - DSN from env var `SENTRY_DSN`
  - `tracesSampleRate: 0.1` (10% performance traces)
  - `release` tag from `package.json` version
  - PII scrubbing: scrub `phoneNumber`, `pin`, `token` from breadcrumbs
- [ ] Add Sentry to Fastify error handler
- [ ] Add Sentry to unhandled rejection/exception handlers
- [ ] Add Sentry to background jobs (`mux-sync.js`, `upload-cleanup.js`, `data-retention.js`)
- [ ] Create Sentry project "fixer-server" and "fixer-admin"
- [ ] Set up Sentry alerts: new issues → Slack `#errors` channel

---

### 4.2 Structured Logging — Production Grade

- [x] Configure Pino with:
  - `level: process.env.LOG_LEVEL || 'info'` (env-configurable)
  - `redact` array for PII fields
  - JSON serializers for `req` and `res`
- [ ] Add HTTP access log middleware: every request logs `method`, `url`, `statusCode`, `responseTime`, `requestId`, `userId`
- [ ] Replace all emoji `console.log` calls with `fastify.log.info()` calls using structured objects
- [ ] Add Prisma query logging in development (`log: ['query', 'warn', 'error']`)
- [ ] Add performance timing logs for:
  - Mux API calls
  - Database queries > 500ms
  - WebSocket message processing
- [ ] Log aggregation: add `pino-loki` or `pino-datadog-transport` for external shipping

---

### 4.3 Health & Readiness Endpoints

Current `/api/health` only checks if server is up. Expand to:

- [x] `GET /api/health/live` — is the process alive? (always 200 if running)
- [ ] `GET /api/health/ready` — are dependencies ready?
  - Checks: DB query (SELECT 1), Redis ping, Mux API reachable
  - Returns: `{ status, db, redis, mux, uptime, version }`
- [x] Add Render health check pointing to `/api/health/ready`
- [x] Add `GET /api/metrics` (admin-authenticated) — basic runtime stats:
  - Memory usage, uptime, active WS connections, job status, DB pool stats

---

### 4.4 Error Tracking in iOS

- [ ] Add Sentry iOS SDK to `ios/DirectVideoUploader/`
- [ ] Initialize in `DirectVideoUploaderApp.swift` with `SENTRY_DSN` build setting
- [ ] Add crash reporting
- [ ] Add breadcrumbs for navigation events, upload state transitions
- [ ] PII scrubbing: don't send phone numbers in breadcrumbs

---

### 4.5 Feature Flags

**Why:** Safe progressive rollouts of risky changes (new auth flow, RBAC migration, transcription provider swap).

- [ ] Pick a provider: Unleash (open-source, self-host), LaunchDarkly (paid, mature), or PostHog (analytics + flags)
- [ ] Create `server/src/lib/flags.js` — `isEnabled(flag, { userId, orgCode })`
- [ ] Wrap risky changes: SSO login path, MFA enforcement, retention purge job, transcription provider
- [ ] iOS: fetch flags at app launch, cache, refresh on foreground
- [ ] Admin dashboard: flag toggle UI for SUPER_ADMIN

---

## Phase 5 — Org Administration & Quotas

### 5.1 Org-Level Settings & Quotas

- [ ] Add to `Organization` model:
  ```
  maxUsersCount       Int?    // null = unlimited
  maxStorageGB        Int?    // null = unlimited
  maxUploadsPerMonth  Int?    // null = unlimited
  videoRetentionDays  Int     @default(365)
  allowedFileTypes    String? // comma-sep MIME types, null = all video
  customBranding      Json?   // logo URL, primary color
  ```
- [ ] Enforce quotas at upload time: check current month count + storage before creating Mux upload
- [ ] Add `GET /api/admin/orgs/:code/usage` — storage, upload count, user count
- [ ] Add usage tracking job: calculate monthly storage per org, store in `OrgUsageSnapshot` table

---

### 5.2 Org Admin Dashboard (Scoped View)

Currently, the admin dashboard shows everything to all ADMINs.

- [ ] Add ORG_ADMIN role to admin dashboard login
- [ ] ORG_ADMIN sees only their org's users, assets, clips, audit logs
- [ ] ORG_ADMIN can:
  - Invite/suspend/delete users within their org
  - View org usage stats
  - Configure org settings (branding, retention)
- [ ] SUPER_ADMIN sees everything + org management panel

---

### 5.3 API Keys for Org Integrations

**Why:** Enterprise clients want server-to-server integrations (e.g., push notifications to their CMS).

- [ ] Add `ApiKey` model: `id`, `orgCode`, `keyHash`, `name`, `scopes`, `lastUsedAt`, `expiresAt`, `createdBy`
- [ ] Add endpoints:
  - `POST /api/admin/api-keys` — create key (returns plaintext once)
  - `GET /api/admin/api-keys` — list keys (never show plaintext)
  - `DELETE /api/admin/api-keys/:id` — revoke key
- [ ] Add API key authentication path: `Authorization: Bearer <api-key>` header
- [ ] Scope enforcement: keys have explicit scopes (`assets:read`, `clips:read`, `webhooks:receive`)
- [ ] Rate limit API keys separately from user JWTs

---

## Phase 6 — Infrastructure & Scalability

> Note: Redis (formerly 6.1) was promoted to Phase 0.4 because earlier phases depend on it.

### 6.1 Secrets Management

- [ ] Audit all secrets — current env vars in Render:
  - `JWT_SECRET`, `DATABASE_URL`, `MUX_TOKEN_ID`, `MUX_TOKEN_SECRET`, `MUX_WEBHOOK_SECRET`, `SLACK_BOT_TOKEN`
- [ ] Rotate all secrets as part of this phase
- [x] Add secret validation at startup: fail fast if required secrets are missing
  ```js
  const required = ['JWT_SECRET', 'DATABASE_URL', 'MUX_TOKEN_ID', ...];
  required.forEach(key => { if (!process.env[key]) throw new Error(`Missing: ${key}`); });
  ```
- [x] Pin Node.js version in `render.yaml`: `nodeVersion: '22.x'`
- [x] Add `.env.example` with all required vars documented (no values)
- [ ] Document secret rotation runbook (rotation cadence: JWT_SECRET annually, MUX/SLACK on personnel changes)

---

### 6.2 Database Hardening

> Note: switching from `db push` to `migrate deploy` was promoted to Phase 0.5 (critical).

- [ ] Add explicit `CHECK` constraints via migration:
  - `duration > 0` on clips
  - `fileSize > 0` on assets
- [ ] Add missing indexes:
  - `AuditLog(userId, createdAt)`
  - `AuditLog(orgCode, createdAt)`
  - `Clip(status, createdAt)` — for mux-sync job
  - `ChatMessage(assetId, createdAt)`
- [ ] Add DB-level row security (PostgreSQL RLS) for org isolation as defense-in-depth
- [ ] Run a real backup/restore drill on Render PostgreSQL — document RTO/RPO
- [ ] Verify and document encryption-at-rest (Render uses AES-256 — get attestation in writing for SOC 2)
- [ ] Add automated nightly logical backup to S3 (Render snapshots only retained 7 days on lower plans)

---

### 6.3 Zero-Downtime Deployments

- [x] Enable Render health check so new deploy only goes live after `/api/health/ready` passes
- [ ] Add `startPeriod` grace period to health check (30s for cold start)
- [x] Ensure all background jobs (`mux-sync`, `upload-cleanup`) handle SIGTERM cleanly (they mostly do — verify)
- [ ] Add graceful WebSocket drain: on SIGTERM, stop accepting new connections, finish in-flight uploads

---

### 6.4 Job Queue (BullMQ)

**Problem:** Background jobs (`mux-sync.js`, `upload-cleanup.js`) use `setInterval`. No retry, no dead-letter queue, no visibility, lost on crash. Not enterprise-grade.

> Depends on Phase 0.4 (Redis).

- [ ] Install `bullmq`
- [ ] Convert `mux-sync` and `upload-cleanup` to BullMQ scheduled jobs
- [ ] Add retry policy (exponential backoff, max 5 attempts)
- [ ] Add dead-letter queue + Slack alert on permanent failure
- [ ] Convert async work (transcription kickoff, Slack post, email send) to queued jobs
- [ ] Add Bull Board UI at `/admin/queues` (SUPER_ADMIN only) for queue introspection
- [ ] Idempotency: every job handler must be safe to re-run

---

### 6.5 Horizontal Scaling — Socket.IO Redis Adapter

**Problem:** Current Socket.IO is in-memory only. Adding a second instance breaks message delivery (a user connected to instance A won't get messages emitted on instance B).

> Depends on Phase 0.4 (Redis).

- [ ] Install `@socket.io/redis-adapter`
- [ ] Configure Socket.IO to use Redis pub/sub adapter
- [ ] Enable sticky sessions on Render (or migrate to a load balancer that supports them)
- [ ] Move `fastify.userSockets` map to Redis (so any instance can find which socket belongs to a user)
- [ ] Test: scale to 2+ instances and verify message delivery

---

## Phase 7 — Testing Completion

With the foundation from Phase 0, complete coverage:

### 7.1 Server Unit Tests

- [ ] `lib/utils.js` — all helper functions
- [ ] `lib/mux.js` — mock Mux SDK, test all branches
- [ ] `lib/slack.js` — mock HTTP calls, test message formatting
- [ ] `lib/audit.js` — verify audit log creation
- [ ] `jobs/mux-sync.js` — test stuck clip detection logic
- [ ] `jobs/upload-cleanup.js` — test orphan detection

### 7.2 Server Integration Tests

- [ ] Auth routes: login success, wrong PIN, wrong company code, MFA flow, SSO redirect
- [ ] Asset routes: create, upload URL generation, status updates
- [ ] Admin routes: user CRUD, stats, pagination, role checks
- [ ] Clip routes: form submit, status poll, viewer auth
- [ ] Webhook routes: Mux signature validation, asset ready, asset error
- [ ] Rate limiting: verify 429 after threshold
- [ ] RBAC: verify each role can only access permitted endpoints

### 7.3 iOS Tests

- [ ] Unit tests for `AuthService`, `VideoUploadService`, `TranscriptionService`
- [ ] Snapshot tests for key views (ChatView, ArchiveView, VideoBubble)
- [ ] Mock server using Swift `URLProtocol` for network calls

### 7.4 Load Testing

- [ ] Use `k6` to simulate 50 concurrent uploads
- [ ] Test WebSocket message throughput (100 concurrent connections)
- [ ] Identify DB connection pool bottlenecks
- [ ] Establish performance baselines to catch regressions

---

## Phase 8 — Compliance & Certification Prep

### 8.1 SOC 2 Type I Readiness

- [ ] Document all data flows (who touches what data, where it goes)
- [ ] Implement all controls from Phases 1–7
- [ ] Engage a compliance consultant for gap assessment
- [ ] Key controls needed:
  - Access control (Phase 2) ✓
  - Audit logging (Phase 3.1) ✓
  - Encryption in transit + at rest ✓ (Render/Mux handles)
  - Vulnerability management (Phase 0 CI + Sentry) ✓
  - Incident response procedure (document)
  - Vendor risk management (Mux, Render, Slack — document)

### 8.2 Penetration Testing

- [ ] Engage external pen tester after Phase 1–2 complete
- [ ] Scope: API endpoints, WebSocket auth, admin dashboard, iOS app
- [ ] Fix all critical/high findings before enterprise launch
- [ ] Retest after fixes

### 8.3 Data Processing Agreement (DPA) & Data Residency

- [ ] Draft DPA for enterprise clients (what data is stored, where, for how long)
- [ ] GDPR Article 28 sub-processor list (Render, Mux, Slack, Sentry, email provider, feature flags)
- [ ] Document data residency: today everything is US-only (Render Oregon, Mux US). EU clients will require an EU option — plan for this OR explicitly exclude EU clients in MSA.
- [ ] Standard Contractual Clauses (SCCs) for any EU customer until EU residency exists
- [ ] Review with legal counsel

---

## Phase 9 — iOS Hardening

### 9.1 Network Security

- [ ] Remove `NSAllowsArbitraryLoads` for production builds (dev-only via `Debug-Staging` config)
- [ ] Add certificate pinning for `ms-fixer.com` API endpoints — pin to current cert SHA + backup pin
- [ ] Document cert rotation procedure (must ship app update before old cert expires)

### 9.2 Device Integrity

- [ ] Add Apple App Attest — server verifies attestation before issuing JWT
  - Prevents jailbroken devices and emulator/script-based abuse
- [ ] Add basic jailbreak detection heuristics (refuse to run on jailbroken device for enterprise builds)

### 9.3 Local Data Protection

- [ ] Audit `Documents/` storage (`pending-form.json`, `phasset-identifiers.json`) — set NSFileProtectionComplete
- [ ] Enable Data Protection entitlement
- [ ] Confirm Keychain access group restricts token to this app only
- [ ] Wipe Documents on logout (currently only Keychain is cleared)

### 9.4 Enterprise Distribution

- [ ] Support Apple Managed App Configuration (`UserDefaults` keys readable from MDM)
  - Server URL, company code, SSO config can be pre-populated by Jamf/Intune
- [ ] Support Apple Business Manager / Volume Purchase Program for enterprise distribution
- [ ] Document MDM deployment guide for IT admins

---

## Phase 10 — Operational Readiness

### 10.1 Status Page

- [ ] Set up status.ms-fixer.com (Statuspage.io, Instatus, or self-hosted Cachet)
- [ ] Subscribe components: API, WebSocket, Mux, Database, iOS App
- [ ] Auto-update from health check failures

### 10.2 SLA Definition

- [ ] Define and publish: 99.5% monthly uptime target (realistic on Render Pro)
- [ ] Define maintenance windows policy
- [ ] Define support response times by severity (P1: 1hr, P2: 4hr, P3: 1bd, P4: 3bd)

### 10.3 Incident Response Runbook

- [ ] Write `docs/INCIDENT_RESPONSE.md` covering:
  - Severity definitions
  - Escalation paths
  - Common incident playbooks: DB down, Mux outage, mass auth failure, data leak suspected
  - Communication templates (status page update, customer email)
  - Post-mortem template
- [ ] Set up on-call rotation (PagerDuty, Opsgenie, or Better Stack)
- [ ] Wire Sentry critical alerts → PagerDuty

### 10.4 Responsible Disclosure

- [x] Add `https://ms-fixer.com/.well-known/security.txt` (RFC 9116)
- [x] Create `SECURITY.md` in repo: how to report vulnerabilities, response SLA, scope
- [ ] Set up `security@ms-fixer.com` mailbox + alias
- [ ] Defer formal bug bounty until after Phase 8 pen test

### 10.5 Cost Monitoring

- [ ] Set Render budget alert at 150% of forecast
- [ ] Set Mux budget alert (storage + delivery + encoding minutes)
- [ ] Project per-org infra cost so pricing tiers are profitable
- [ ] Document cost-per-active-user metric for sales conversations

---

## Dependency Map

```
Phase 0 (Tests + ReqIDs + OpenAPI + Redis + Migrations + Staging + Supply Chain)
    │
    ├─→ Phase 1 (Security Hardening) — uses Redis (0.4), migrations (0.5)
    │       └─→ Phase 2 (IAM)
    │               └─→ Phase 3 (Audit/Compliance)
    │                       └─→ Phase 5 (Org Admin/Quotas) — needs soft deletes (3.2)
    │
    ├─→ Phase 4 (Observability + Feature Flags) — can run parallel to Phase 1
    │
    ├─→ Phase 6 (Infra) — uses Redis (0.4); 6.4 BullMQ replaces Phase 0 setInterval jobs
    │
    ├─→ Phase 7 (Test Coverage) — extends Phase 0 harness, can run parallel to all
    │
    ├─→ Phase 9 (iOS Hardening) — independent; can run parallel to Phases 1–6
    │
    └─→ Phase 10 (Ops Readiness) — needs Phase 4 (observability) for alerts

Phase 8 (SOC 2 / Pen Test) ── requires Phases 1, 2, 3, 4, 10 complete
```

---

## Effort Estimates (Rough)

All estimates assume **1 full-time engineer** with existing project context.

| Phase     | Scope                                                                     | Estimated Effort           |
| --------- | ------------------------------------------------------------------------- | -------------------------- |
| Phase 0   | Tests + ReqIDs + OpenAPI + **Redis + Migrations + Staging + SupplyChain** | 4–5 weeks                  |
| Phase 1   | Security hardening                                                        | 3–4 weeks                  |
| Phase 2   | IAM (RBAC + SSO + MFA + Invites + Email)                                  | 5–7 weeks                  |
| Phase 3   | Audit + compliance + GDPR + retention                                     | 3–4 weeks                  |
| Phase 4   | Observability + Sentry + Feature Flags                                    | 2–3 weeks                  |
| Phase 5   | Org admin + quotas + API keys                                             | 3–4 weeks                  |
| Phase 6   | Infra + DB + BullMQ + Socket.IO scaling                                   | 3–4 weeks                  |
| Phase 7   | Full test coverage                                                        | 3–4 weeks                  |
| Phase 8   | Compliance certification                                                  | Ongoing / external (3–6mo) |
| Phase 9   | iOS hardening                                                             | 2–3 weeks                  |
| Phase 10  | Ops readiness (status page, runbooks, on-call)                            | 1–2 weeks                  |
| **Total** |                                                                           | **~7–10 months solo**      |
|           | With 2 engineers + parallel work                                          | **~4–5 months**            |

---

## Quick Wins (Can Do Now, <1 Day Each)

These don't require a full phase — do them immediately:

1. [x] **Fix SQL injection risk** — parameterize `companyCode` in `server/src/routes/admin.js`
2. [x] **Enable Mux webhook signature verification** — remove dev bypass in `mux-webhooks.js`
3. [x] **Add startup secret validation** — fail fast if required env vars missing
4. [x] **Remove stack traces from prod error responses** — one-line Fastify error handler fix
5. [x] **Pin Node.js version** — add `nodeVersion: '22.x'` to `render.yaml`
6. [x] **Add `.env.example`** — document all required vars with descriptions
7. [x] **Add `User.status` check inside `fastify.authenticate`** — suspended users still pass auth currently (no token-refresh endpoint exists, so check belongs in the existing decorator)
8. [x] **Add body size limit** — add `bodyLimit` to non-multipart routes (currently uncapped)
9. [x] **Stop running `prisma db push --accept-data-loss` in prod** — at minimum, drop `--accept-data-loss` immediately while versioned migrations (Phase 0.5) are being set up
10. [x] **Add `SECURITY.md` + `security.txt`** — boilerplate from Phase 10.4; takes 30 minutes
11. [x] **Enable Dependabot** — one PR; gets you weekly dependency PRs
