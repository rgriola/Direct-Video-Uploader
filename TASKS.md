# Fixer — Enterprise Readiness Tasks

> Companion to [ENTERPRISE_READINESS_PLAN.md](ENTERPRISE_READINESS_PLAN.md).
> Check items off as you complete them. Each task should be a single PR.

---

## 🚨 Quick Wins (Do This Week)

- [ ] Fix SQL injection — parameterize `companyCode` in [server/src/routes/admin.js](server/src/routes/admin.js)
- [ ] Enable Mux webhook signature verification unconditionally (remove dev bypass)
- [ ] Add startup secret validation (fail fast if env vars missing)
- [ ] Remove stack traces from production error responses
- [ ] Pin Node.js version in [render.yaml](render.yaml) (`nodeVersion: '22.x'`)
- [ ] Create `.env.example` with all required vars documented
- [ ] Add `User.status` check inside `fastify.authenticate` decorator
- [ ] Add `bodyLimit` to non-multipart routes
- [ ] Drop `--accept-data-loss` flag from `prisma db push` in [render.yaml](render.yaml)
- [ ] Add `SECURITY.md` + `/.well-known/security.txt`
- [ ] Enable Dependabot (one PR adds `.github/dependabot.yml`)

---

## Phase 0 — Foundation

### 0.1 Test Infrastructure

- [ ] Add Vitest to `server/package.json`
- [ ] Create `server/src/__tests__/` directory
- [ ] Write smoke tests for every existing route
- [ ] Create `.github/workflows/ci.yml`
- [ ] Add coverage reporting (c8)
- [ ] Set 60% coverage gate (raise to 80% by Phase 3)

### 0.2 Request Correlation IDs

- [ ] Install `@fastify/request-context` (or write UUID middleware)
- [ ] Generate `X-Request-ID` per request
- [ ] Attach to Pino child logger
- [ ] Return in response headers
- [ ] Thread through Slack alerts and error logs

### 0.3 OpenAPI / Swagger

- [ ] Install `@fastify/swagger` + `@fastify/swagger-ui`
- [ ] Register `/api/docs` (admin-auth in production)
- [ ] Add JSON Schema to all existing route schemas

### 0.4 Redis (PREREQUISITE for 1.1, 1.5, 6.4, 6.5)

- [ ] Add Render Redis (or Upstash) to [render.yaml](render.yaml)
- [ ] Add `REDIS_URL` env var (TLS in prod)
- [ ] Create `server/src/lib/redis.js` (`ioredis` singleton)
- [ ] Add Redis ping to `/api/health/ready`
- [ ] Document in-memory dev fallback

### 0.5 Versioned Migrations (CRITICAL)

- [ ] Switch local dev to `prisma migrate dev`
- [ ] Generate baseline migration from current production schema
- [ ] Replace `db push` with `migrate deploy` in [render.yaml](render.yaml)
- [ ] Commit `server/prisma/migrations/` directory
- [ ] Add migration review to PR checklist
- [ ] Document rollback procedure

### 0.6 Staging Environment

- [ ] Add `staging` service to [render.yaml](render.yaml)
- [ ] Separate staging DB + Redis + Mux env
- [ ] Auto-deploy from `staging` branch
- [ ] Add `Debug-Staging` iOS build configuration
- [ ] Document promotion flow

### 0.7 Supply Chain Security

- [ ] Enable Dependabot for `server/`, `admin/`, root
- [ ] Add `npm audit --audit-level=high` to CI
- [ ] Enforce `npm ci --frozen-lockfile`
- [ ] Add CodeQL workflow
- [ ] Document license policy (no GPL/AGPL in app code)

---

## Phase 1 — Security & Auth Hardening

### 1.1 Token Revocation

> Requires Phase 0.4

- [ ] Add `jti` claim to JWTs at login
- [ ] Store JTIs in Redis with TTL
- [ ] Verify JTI on every authenticated request
- [ ] `POST /api/auth/logout` (delete JTI)
- [ ] `POST /api/admin/users/:id/revoke-sessions`
- [ ] iOS: call logout endpoint, clear Keychain

### 1.2 Input Validation

- [ ] Add Fastify schemas to all unvalidated POST/PATCH routes
- [ ] Install `ajv-formats`
- [ ] Fix raw SQL `companyCode` injection in admin.js
- [ ] MIME type check before Mux upload creation
- [ ] Global validation error handler → consistent 422 format

### 1.3 PII Redaction

- [ ] Create `server/src/lib/redact.js`
- [ ] Add Pino `redact` config (`phoneNumber`, `companyCode`, `token`)
- [ ] Audit all `console.log` / `fastify.log` calls
- [ ] Redact PII in Slack alert messages

### 1.4 Security Headers & CSRF

- [ ] Add `Permissions-Policy` header
- [ ] Add `Cache-Control: no-store` on auth endpoints
- [ ] Add `@fastify/csrf-protection` to clip viewer login form ONLY
- [ ] Strip stack traces from prod error responses
- [ ] Make Mux webhook signature verification unconditional

### 1.5 Rate Limiting (Redis-backed)

> Requires Phase 0.4

- [ ] Switch `@fastify/rate-limit` store to Redis
- [ ] Add per-user limits on authenticated routes
- [ ] Add `X-RateLimit-*` response headers
- [ ] WebSocket throttling (10 msgs / 10s)
- [ ] Mux upload creation: 5/hour per user

---

## Phase 2 — Identity & Access Management

### 2.1 Expanded RBAC

- [ ] Add roles: `SUPER_ADMIN`, `ORG_ADMIN`, `EDITOR`, `VIEWER`
- [ ] Migrate existing users (`ADMIN`→`SUPER_ADMIN`, `USER`→`EDITOR`)
- [ ] Create `fastify.authorize(roles)` decorator factory
- [ ] Replace all `authorizeAdmin` calls
- [ ] Add ORG_ADMIN guards on org-level endpoints
- [ ] Add role to JWT payload
- [ ] iOS: read/store role from JWT
- [ ] Admin dashboard: role badges + role change UI

### 2.2 SSO / OAuth2

- [ ] Add `passport-saml` or `openid-client`
- [ ] `POST /api/auth/sso/saml` callback
- [ ] `GET /api/auth/sso/metadata`
- [ ] Add SSO fields to `Organization` model
- [ ] Login flow: SSO redirect for SSO-enabled orgs
- [ ] Keep PIN login as fallback for non-SSO orgs
- [ ] iOS: `ASWebAuthenticationSession` for SAML
- [ ] Admin: SSO config UI per org

### 2.3 MFA (non-SSO users only)

- [ ] Install `otplib`
- [ ] Add `mfaEnabled`, `mfaSecret` (encrypted), `mfaBackupCodes` (hashed)
- [ ] `POST /api/auth/mfa/setup` (TOTP secret + QR + backup codes)
- [ ] `POST /api/auth/mfa/verify`
- [ ] `POST /api/auth/mfa/disable`
- [ ] `POST /api/auth/mfa/backup-code`
- [ ] Login flow: short-lived `mfa_pending` JWT → full JWT after TOTP
- [ ] iOS: `MFAVerifyView.swift`
- [ ] Admin: per-org MFA enforcement toggle

### 2.4 Org User Management

- [ ] Add `UserInvite` model (token hashed)
- [ ] `POST /api/admin/users/invite` (ORG_ADMIN+)
- [ ] `GET /api/auth/invite/:token` (validate)
- [ ] `POST /api/auth/invite/:token/accept` (set PIN)
- [ ] `POST /api/admin/users/:id/suspend` (revokes JTIs)
- [ ] `DELETE /api/admin/users/:id` (soft delete)
- [ ] Admin dashboard: invite/suspend/delete UI

### 2.5 Transactional Email

- [ ] Pick provider (Resend / SES / Postmark)
- [ ] Create `server/src/lib/email.js`
- [ ] Set up SPF, DKIM, DMARC for `ms-fixer.com`
- [ ] Build templates (invite, reset, security-alert, MFA-disabled)
- [ ] Bounce webhook handling
- [ ] Unsubscribe link on non-transactional emails
- [ ] Per-recipient send rate limit (5/hour)

---

## Phase 3 — Audit, Compliance & Data Governance

### 3.1 Audit Log System

- [ ] Add `AuditLog` Prisma model
- [ ] Create `server/src/lib/audit.js` (`logAction(req, action, resource, metadata)`)
- [ ] Wire into auth (login, logout, failed login, PIN change)
- [ ] Wire into assets (create, update, delete)
- [ ] Wire into clips (form submit, status change)
- [ ] Wire into users (create, suspend, delete, role change)
- [ ] Wire into admin (cleanup, reset)
- [ ] `GET /api/admin/audit-logs` (paginated, filterable)
- [ ] Admin dashboard: AuditLog component
- [ ] 2-year retention policy (configurable)

### 3.2 Soft Deletes

- [ ] Add `deletedAt` to `User`, `Asset`, `Clip`, `FormResponse`, `ChatMessage`
- [ ] Implement Prisma Client Extension (`$extends`) — NOT `$use`
- [ ] Add `includeSoftDeleted` escape hatch
- [ ] Convert all DELETE endpoints to soft delete
- [ ] `POST /api/admin/assets/:id/restore` (SUPER_ADMIN only)
- [ ] Purge job: hard delete past retention window
- [ ] Per-org `dataRetentionDays`
- [ ] Mux asset deletion at hard-purge time

### 3.3 GDPR / CCPA Endpoints

- [ ] `GET /api/users/me/export`
- [ ] `POST /api/users/me/delete-request`
- [ ] `GET /api/admin/users/:id/export`
- [ ] Add `User.privacyAcceptedAt`
- [ ] Add `User.tosVersion`

### 3.4 Data Retention Job

- [ ] Add `videoRetentionDays`, `auditRetentionDays` to `Organization`
- [ ] Create `server/src/jobs/data-retention.js` (nightly)
- [ ] Soft-delete past retention window
- [ ] Hard-delete past purge window (incl. Mux assets)
- [ ] Weekly retention summary to SUPER_ADMIN via Slack

---

## Phase 4 — Observability

### 4.1 Sentry

- [ ] Install `@sentry/node` (server) + `@sentry/react` + `@sentry/vite-plugin` (admin)
- [ ] Init Sentry with `SENTRY_DSN`, release tag, PII scrubbing
- [ ] Wire into Fastify error handler
- [ ] Wire into unhandled rejection/exception handlers
- [ ] Wire into background jobs
- [ ] Create Sentry projects (server + admin)
- [ ] Set up alert → Slack `#errors` channel

### 4.2 Structured Logging

- [ ] Configure Pino: env-driven level, redact, JSON serializers
- [ ] Add HTTP access log middleware
- [ ] Replace emoji `console.log` calls with structured logs
- [ ] Enable Prisma query logging in dev
- [ ] Add timing logs (Mux calls, slow queries >500ms, WS messages)
- [ ] Add `pino-loki` or `pino-datadog-transport`

### 4.3 Health & Readiness

- [ ] `GET /api/health/live`
- [ ] `GET /api/health/ready` (DB + Redis + Mux checks)
- [ ] Point Render health check at `/ready`
- [ ] `GET /api/metrics` (admin-only)

### 4.4 iOS Error Tracking

- [ ] Add Sentry iOS SDK 
- [ ] Init in `DirectVideoUploaderApp.swift`
- [ ] Crash reporting + breadcrumbs
- [ ] PII scrubbing config

### 4.5 Feature Flags

- [ ] Pick provider (Unleash / LaunchDarkly / PostHog)
- [ ] Create `server/src/lib/flags.js`
- [ ] Wrap risky changes (SSO, MFA, retention purge, transcription)
- [ ] iOS: launch-time flag fetch + foreground refresh
- [ ] Admin dashboard: SUPER_ADMIN flag toggle UI

---

## Phase 5 — Org Administration & Quotas

### 5.1 Org Settings & Quotas

- [ ] Add quota fields to `Organization` (max users / storage / uploads)
- [ ] Enforce quotas at upload-creation time
- [ ] `GET /api/admin/orgs/:code/usage`
- [ ] `OrgUsageSnapshot` table + monthly tracking job

### 5.2 Org Admin Scoped Dashboard

- [ ] ORG_ADMIN login on admin dashboard
- [ ] Scope all queries by org for ORG_ADMIN
- [ ] Org user CRUD for ORG_ADMIN
- [ ] Org usage stats view
- [ ] Org settings (branding, retention) for ORG_ADMIN
- [ ] SUPER_ADMIN org management panel

### 5.3 API Keys

- [ ] Add `ApiKey` model
- [ ] `POST /api/admin/api-keys` (returns plaintext once)
- [ ] `GET /api/admin/api-keys` (list, no plaintext)
- [ ] `DELETE /api/admin/api-keys/:id`
- [ ] Bearer token auth path for API keys
- [ ] Scope enforcement (`assets:read`, etc.)
- [ ] Separate rate limits

---

## Phase 6 — Infrastructure & Scalability

### 6.1 Secrets Management

- [ ] Audit all secrets in Render
- [ ] Rotate all secrets
- [ ] Startup validation (fail fast on missing vars)
- [ ] Pin Node.js version
- [ ] Document rotation runbook (cadence + procedure)

### 6.2 Database Hardening

- [ ] Add CHECK constraints (`duration > 0`, `fileSize > 0`)
- [ ] Add missing indexes (AuditLog, Clip status, ChatMessage)
- [ ] Implement PostgreSQL RLS for org isolation
- [ ] Backup/restore drill on Render PostgreSQL
- [ ] Document RTO/RPO
- [ ] Get encryption-at-rest attestation for SOC 2
- [ ] Nightly logical backup to S3

### 6.3 Zero-Downtime Deployments

- [ ] Render health check tied to `/api/health/ready`
- [ ] 30s `startPeriod` grace
- [ ] Verify SIGTERM handling on background jobs
- [ ] Graceful WebSocket drain

### 6.4 Job Queue (BullMQ)

> Requires Phase 0.4

- [ ] Install `bullmq`
- [ ] Convert `mux-sync` to BullMQ
- [ ] Convert `upload-cleanup` to BullMQ
- [ ] Retry policy + dead-letter queue
- [ ] Convert async work (transcription, Slack, email)
- [ ] Bull Board UI at `/admin/queues`
- [ ] Idempotent handlers

### 6.5 Horizontal Scaling

> Requires Phase 0.4

- [ ] Install `@socket.io/redis-adapter`
- [ ] Configure Redis pub/sub adapter
- [ ] Enable sticky sessions on Render
- [ ] Move `userSockets` map to Redis
- [ ] Test at 2+ instances

---

## Phase 7 — Testing Completion

### 7.1 Server Unit Tests

- [ ] `lib/utils.js`
- [ ] `lib/mux.js` (mocked SDK)
- [ ] `lib/slack.js` (mocked HTTP)
- [ ] `lib/audit.js`
- [ ] `jobs/mux-sync.js`
- [ ] `jobs/upload-cleanup.js`

### 7.2 Server Integration Tests

- [ ] Auth: login success/failure, MFA, SSO
- [ ] Assets: full lifecycle
- [ ] Admin: user CRUD, role checks, pagination
- [ ] Clips: form submit, status, viewer auth
- [ ] Webhooks: Mux signature, ready, error
- [ ] Rate limiting (verify 429)
- [ ] RBAC matrix (each role × each endpoint)

### 7.3 iOS Tests

- [ ] `AuthService` unit tests
- [ ] `VideoUploadService` unit tests
- [ ] `TranscriptionService` unit tests
- [ ] Snapshot tests (ChatView, ArchiveView, VideoBubble)
- [ ] `URLProtocol` mock server

### 7.4 Load Testing

- [ ] k6 script: 50 concurrent uploads
- [ ] WebSocket throughput test (100 connections)
- [ ] Identify DB pool bottlenecks
- [ ] Establish performance baselines

---

## Phase 8 — Compliance & Certification

### 8.1 SOC 2 Type I

- [ ] Document all data flows
- [ ] Engage compliance consultant
- [ ] Document incident response procedure
- [ ] Document vendor risk management

### 8.2 Penetration Testing

- [ ] Engage external pen tester (post Phase 1–2)
- [ ] Scope: API, WebSocket, admin, iOS
- [ ] Fix critical/high findings
- [ ] Retest

### 8.3 DPA & Data Residency

- [ ] Draft DPA template
- [ ] GDPR Article 28 sub-processor list
- [ ] Document US-only residency (or plan EU option)
- [ ] SCCs for any EU customer
- [ ] Legal review

---

## Phase 9 — iOS Hardening

### 9.1 Network Security

- [ ] Remove `NSAllowsArbitraryLoads` from production builds
- [ ] Add certificate pinning (current + backup pin)
- [ ] Document cert rotation procedure

### 9.2 Device Integrity

- [ ] Apple App Attest (server verifies before issuing JWT)
- [ ] Jailbreak detection (refuse on jailbroken for enterprise builds)

### 9.3 Local Data Protection

- [ ] Set `NSFileProtectionComplete` on Documents files
- [ ] Enable Data Protection entitlement
- [ ] Verify Keychain access group restriction
- [ ] Wipe Documents on logout

### 9.4 Enterprise Distribution

- [ ] Apple Managed App Configuration support
- [ ] Apple Business Manager / VPP
- [ ] MDM deployment guide for IT admins

---

## Phase 10 — Operational Readiness

### 10.1 Status Page

- [ ] Set up status.ms-fixer.com
- [ ] Subscribe components (API, WS, Mux, DB, iOS)
- [ ] Auto-update from health checks

### 10.2 SLA

- [ ] Publish 99.5% uptime target
- [ ] Define maintenance windows policy
- [ ] Define support response times by severity

### 10.3 Incident Response

- [ ] Write `docs/INCIDENT_RESPONSE.md`
- [ ] Set up on-call rotation (PagerDuty / Opsgenie / Better Stack)
- [ ] Wire Sentry critical alerts → on-call

### 10.4 Responsible Disclosure

- [ ] Add `/.well-known/security.txt`
- [ ] Create `SECURITY.md`
- [ ] Set up `security@ms-fixer.com`

### 10.5 Cost Monitoring

- [ ] Render budget alert (150% forecast)
- [ ] Mux budget alert (storage + delivery + encoding)
- [ ] Per-org infra cost projection
- [ ] Document cost-per-active-user metric

---

## Progress Snapshot

Update these counts as you go:

- Quick Wins: 0 / 11
- Phase 0: 0 / 28
- Phase 1: 0 / 25
- Phase 2: 0 / 35
- Phase 3: 0 / 26
- Phase 4: 0 / 25
- Phase 5: 0 / 14
- Phase 6: 0 / 25
- Phase 7: 0 / 19
- Phase 8: 0 / 11
- Phase 9: 0 / 11
- Phase 10: 0 / 17

**Overall: 0 / 247 tasks**
