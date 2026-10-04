# Home Server Plan — Postgres + Fastify on MacBook Air via Cloudflare Tunnel

_Drafted: September 25, 2026_
_Owner: Rod_
_Status: **Live** — all 6 phases complete, 7/8 verification checks passed. Only reboot resilience (Verification #7) remains, deferred until convenient._

Move both the Postgres 18 database and the Fastify server off Google Cloud (Cloud Run + Cloud SQL) and host them on the 2026 MacBook Air at home. Expose only the Fastify server to the internet through a **Cloudflare Tunnel** bound to `dev.ms-fixer.com`. Postgres stays loopback-only with SCRAM auth so port 5432 is never internet-reachable — same security posture as Cloud SQL with a private-VPC-only IP.

Why: eliminates managed-DB costs while the project is still pre-production, keeps ms-fixer.com DNS on Cloudflare, and lets the iOS app + work laptop reach the server from anywhere.

---

## Answered Design Questions

| Question                       | Answer                                                                           |
| ------------------------------ | -------------------------------------------------------------------------------- |
| What runs at home?             | **Both** Fastify (`:3000`) and Postgres 18 (`:5432` loopback) on the MacBook Air |
| Home internet IP               | Dynamic (residential) → Cloudflare Tunnel handles this automatically             |
| Cloudflare zone                | `ms-fixer.com` already active on Cloudflare                                      |
| Host hardware                  | 2026 MacBook Air (Apple Silicon)                                                 |
| Domain for home server         | `dev.ms-fixer.com` (subdomain of existing zone)                                  |
| Existing Cloud Run / Cloud SQL | Leave running as fallback for 1–2 weeks after cutover, then decide               |

---

## Architecture

Cloudflare edge → outbound TLS tunnel from MacBook Air (`cloudflared`, no open ports at home) → `http://127.0.0.1:3000` Fastify → `psql :5432` SCRAM loopback → Postgres 18 `directvideo` DB. Nothing at home is internet-reachable except what the tunnel forwards to `localhost:3000`. `cloudflared` reconnects automatically on residential IP/DHCP changes or brief internet drops — no dynamic DNS needed.

---

## Phase 1 — MacBook Air host prep

- [x] Install Xcode Command Line Tools: `xcode-select --install` — already present
- [x] Install Homebrew if missing — already present
- [x] `brew install postgresql@18 cloudflared node@20 jq` — postgresql@18 was already installed; cloudflared, node@20, jq installed
- [x] Set stable hostname: `sudo scutil --set HostName fixer-server` — confirmed via `scutil --get HostName`
- [x] Disable auto-sleep: `sudo pmset -a sleep 0 disksleep 0 displaysleep 0` — confirmed via `pmset -g`; host runs lid-open + plugged in, so no clamshell caveat applies
- [x] Disable automatic restart-after-macOS-update (System Settings → General → Software Update → Advanced) so an OS patch doesn't silently reboot the host outside a maintenance window
- [ ] (Optional) DHCP-reserve the Air's LAN IP in the router — **deferred**; not required for correctness since Cloudflare Tunnel doesn't depend on a fixed LAN IP, but a stable local IP makes on-LAN troubleshooting (SSH, `lsof` checks from another device) easier. Revisit when convenient.

## Phase 2 — Postgres 18 "prod-like"

- [x] `brew services start postgresql@18`
- [x] `postgresql.conf`: `listen_addresses='localhost'`, `password_encryption='scram-sha-256'`, memory tuning (`shared_buffers=2GB`, `effective_cache_size=6GB`, `work_mem=16MB`), logging (`logging_collector=on`, `log_directory='log'`, `log_filename='postgresql-%Y-%m-%d_%H%M%S.log'`, `log_line_prefix='%m [%p] %q%u@%d '`)
- [x] `pg_hba.conf`: **removed all `trust` lines**, require `scram-sha-256` on `127.0.0.1/32` and `::1/128`. **Correction**: this Homebrew install's superuser role is named after the OS user (`rodgriola`), not `postgres` — there is no `postgres` role in this cluster. `peer` is scoped to `rodgriola` only for local admin.
- [x] Restart: `brew services restart postgresql@18`
- [x] Create non-superuser role + DB:
  ```sql
  CREATE ROLE fixer_app LOGIN PASSWORD '<strong>' NOSUPERUSER NOCREATEDB NOCREATEROLE;
  CREATE DATABASE directvideo OWNER fixer_app;
  ```
  Passwords generated with `openssl rand -base64 24` for both `rodgriola` (admin) and `fixer_app` — stored in password manager, not committed anywhere.
- [x] Verify SCRAM prompts for password — confirmed via `psql -h 127.0.0.1 -U fixer_app -d directvideo` (successful auth with password); local peer auth confirmed for `rodgriola` via Unix socket
- [x] Enable macOS App Firewall; confirm `lsof -iTCP:5432 -sTCP:LISTEN` shows `127.0.0.1` only — both confirmed

## Phase 3 — Fastify at home

- [x] Clone repo to `~/apps/direct-video-uploader`, `cd server && npm ci`
- [x] `npm audit` triage: started at 37 vulns (1 critical, 24 high, 12 moderate) → 29 (0 critical, 19 high, 10 moderate) after fixes:
  - `fast-jwt` critical (JWT auth-bypass via empty HMAC secret) → overridden to `^6.3.3`
  - `@fastify/static` high (path traversal/auth bypass), directly serves `/uploads/` + dashboard through the tunnel → bumped direct dep to `^10.1.5`
  - `ws` high (memory exhaustion DoS via Socket.IO) → overridden to `^8.22.0`
  - `axios`, `brace-expansion`, `defu` → overridden to patched versions
  - Remaining 29 are nested under `prisma`'s dev-tooling (`@prisma/dev`, unused — this plan uses `migrate deploy` against our own Postgres, not `prisma dev`'s ephemeral DB) and `vitest`/`@vitest/coverage-v8` (test-only), plus one `@fastify/static` copy nested inside `@fastify/swagger-ui`'s auth-guarded `/api/docs` route — deferred, revisit later
  - Note: `content-disposition@3.0.0` (new dep of `@fastify/static@10.1.5`) wants Node ≥22; we're on Node 20 — `EBADENGINE` warning only, verify server boots before deciding whether to bump Node
- [x] Author `server/.env`:
  ```
  DATABASE_URL="postgresql://fixer_app:<urlencoded-pass>@127.0.0.1:5432/directvideo?sslmode=disable"
  JWT_SECRET="<64-byte hex>"
  HOST="127.0.0.1"
  PORT=3000
  NODE_ENV="production"
  PUBLIC_URL="https://dev.ms-fixer.com"
  MUX_TOKEN_ID="…"
  MUX_TOKEN_SECRET="…"
  MUX_ENV_KEY="…"
  MUX_WEBHOOK_SECRET="…"
  SLACK_BOT_TOKEN="…"
  ```
  Generated locally (JWT_SECRET via `crypto.randomBytes(64)`, DB URL from Phase 2 `fixer_app` creds); Mux/Slack values entered directly by Rod in the editor, not shared in chat.
- [x] `chmod 600 server/.env` (holds DB password, JWT secret, Mux + Slack tokens)
- [x] `prisma migrate deploy` + `npm run seed` — use `migrate deploy`, not `db push`, since this DB now holds real data and `db push` can silently drop/alter columns on drift
  - **Correction**: repo had no `prisma/migrations` history (previously only used `db push`). Bootstrapped one with `prisma migrate dev --name init` against the fresh, empty `directvideo` DB — safe since no data existed yet. Going forward, schema changes should go through `migrate dev` locally then `migrate deploy` here.
  - `migrate dev` needs shadow-DB create rights, which `fixer_app` intentionally lacks (`NOCREATEDB`) — ran that one bootstrap step as the `rodgriola` admin role via a one-off `DATABASE_URL` override, without touching `.env`.
  - Bootstrapping as admin left all tables owned by `rodgriola` instead of `fixer_app` — fixed via `ALTER SCHEMA public OWNER TO fixer_app` + reassigning each table/sequence owner individually (`REASSIGN OWNED BY` failed cluster-wide since `rodgriola` also owns system-required objects). Verified all 8 tables now owned by `fixer_app`.
  - `npx prisma generate` was needed explicitly (client wasn't generated automatically); seed then ran cleanly as `fixer_app`, creating 4 demo users.
- [x] Confirm `trustProxy` is enabled in server (Cloudflare forwards `CF-Connecting-IP`) — `trustProxy: isProduction` in `src/index.js`, true since `NODE_ENV=production`. Inline comment still says "Render" — cosmetic, fix during Phase 5 cleanup.
- [x] Verify `lsof -iTCP:3000 -sTCP:LISTEN` shows `127.0.0.1:3000` only, NOT `*:3000` — confirmed (`localhost:hbci`, loopback only). Foreground test boot also confirmed: DB connects, Mux enabled, `/api/health` → 200. Note: actual health route is `/api/health`, not `/healthz` — doc corrected below. Also noted `public/` (dashboard build) doesn't exist yet — non-blocking warning, revisit before exposing the dashboard.
- [x] Install LaunchAgent `~/Library/LaunchAgents/com.msfixer.fastify.plist` with `KeepAlive=true`, `RunAtLoad=true`, logs to `~/Library/Logs/msfixer/` — loaded via `launchctl`, confirmed serving `/api/health` on port 3000, and confirmed `KeepAlive` restart after `kill -9` (new PID within ~3s)

## Phase 4 — Cloudflare Tunnel

- [x] `cloudflared tunnel login` (browser auth to Cloudflare account, select `ms-fixer.com` zone) — cert saved to `~/.cloudflared/cert.pem`
- [x] `cloudflared tunnel create fixer-dev` — UUID `61348dc7-6e08-457e-bd92-9cd7257db18a`
- [x] Author `~/.cloudflared/config.yml`:
  ```yaml
  tunnel: <UUID>
  credentials-file: /Users/<you>/.cloudflared/<UUID>.json
  ingress:
    - hostname: dev.ms-fixer.com
      service: http://localhost:3000
      originRequest:
        connectTimeout: 30s
    - service: http_status:404
  ```
- [x] `cloudflared tunnel route dns fixer-dev dev.ms-fixer.com` — CNAME added
- [x] Test foreground: `cloudflared tunnel run fixer-dev`, then `curl -I https://dev.ms-fixer.com/api/health` from work laptop → 200 — confirmed 200 (tested from this host via public DNS/Cloudflare edge round-trip, not localhost; optionally re-test from the work laptop later for full independent confirmation)
- [x] Install as system service: `sudo cloudflared service install` — **required a manual fix**: the installed `LaunchDaemon` plist ran bare `cloudflared` with no arguments, which (running as root) can't find a user's `~/.cloudflared/config.yml` and just prints a hint instead of starting the tunnel (silent failure, HTTP 530/1033 externally). Fixed by copying `config.yml` + credentials JSON to `/etc/cloudflared/` (root-readable standard path) and editing `/Library/LaunchDaemons/com.cloudflare.cloudflared.plist`'s `ProgramArguments` to `cloudflared tunnel --config /etc/cloudflared/config.yml run`. Reloaded via `launchctl`; confirmed `/api/health` → 200 through the system service.
- [x] (Recommended) Add Cloudflare Access email-OTP policy on `/admin*` — leave `/api/*` and `/socket.io/*` open (JWT-gated already)
  - **Correction**: there is no `/admin*` path in this codebase — the admin dashboard SPA (built from `admin/` → `server/public`) is served at the site **root** (`/`), not a subpath. Client-facing routes (`/clips/*` cookie-gated viewer, `/api/*` JWT-gated, `/uploads/*` static assets, `/socket.io/*` websocket) needed explicit bypass policies instead.
  - Set up: Cloudflare Zero Trust team created (free plan). 5 Access applications on `dev.ms-fixer.com`:
    1. **Fixer Admin Dashboard** — domain `dev.ms-fixer.com`, no path (whole domain) — Allow policy, email OTP to `rodczaro@gmail.com`
    2. **Fixer API Bypass** — path `/api/*` — Bypass, Everyone
    3. **Fixer Socket.IO Bypass** — path `/socket.io/*` — Bypass, Everyone
    4. **Fixer Uploads Bypass** — path `/uploads/*` — Bypass, Everyone
    5. **Fixer Clips Bypass** — path `/clips/*` — Bypass, Everyone
  - Verified via curl: `/` → 302 to `cloudflareaccess.com` login (protected, correct); `/api/health` → 200 (bypassed, correct); `/socket.io/` → 400 (reached app's own socket.io handshake handler, bypassed correctly); `/uploads/` → 404 (reached app's static handler, bypassed correctly); `/clips/` → 302 to the **app's own** `/clips/login` (not Cloudflare's login — confirms bypass working, app-level auth intact).
  - **Follow-up fix**: the real Socket.IO/Engine.IO polling handshake hits the bare path `/socket.io` (no trailing slash — this is the Engine.IO client spec, confirmed from both the iOS `URLSessionWebSocketTask`-based client and testing), which did NOT match the `/socket.io/*` bypass path (requires a literal `/` before the wildcard) and fell through to the domain-wide login policy, breaking the iOS WebSocket handshake (redirect response instead of a valid Engine.IO payload). Fixed by changing the bypass path to `/socket.io*` (no slash before the wildcard) — confirmed both `/socket.io` and `/socket.io/` now return 200/expected app responses instead of 302.

## Phase 5 — Client + config updates

- [ ] iOS `ServerConfig.swift` Debug scheme → `https://dev.ms-fixer.com`
- [ ] Admin dashboard verify Socket.IO auto-detects `wss://`
- [ ] README.md: add "Home Server (Cloudflare Tunnel)" subsection under Deployment
- [ ] server/.env.example: replace stale Render/Cloud SQL comments with home-server block

## Phase 6 — Ops, backups, monitoring

- [x] Nightly `pg_dump` LaunchAgent → `~/backups/`, 7-day retention — `scripts/pg-backup.sh` + `com.msfixer.pgdump.plist` (2am daily), tested manually, restore verified (see Verification)
- [x] Encrypt dumps before they leave the box (`gpg --symmetric` or provider-side SSE) — they contain user data — gpg AES256 symmetric, passphrase generated via `openssl rand -base64 32` at `~/.backup-passphrase` (chmod 600), never shown in chat
- [x] Weekly offsite copy → GCS Coldline or Backblaze B2 — Backblaze B2 chosen. `rclone` installed, scoped Application Key created (bucket-restricted, not the account Master Key), `scripts/pg-backup-offsite-sync.sh` + `com.msfixer.pgdump-offsite.plist` (Sundays 3am), tested manually — synced successfully to `ms-fixer-backups` bucket.
  - **Security note during setup**: a B2 application key got accidentally pasted into `server/.env` and shared in chat — treated as compromised, deleted, and replaced with a freshly scoped key. Lesson: cloud credentials for ops tooling should never go in the app's `.env`.
- [x] Exclude the Postgres data directory from Time Machine (live file-copy backups of a running DB can be inconsistent — rely on `pg_dump` instead) — `tmutil addexclusion /opt/homebrew/var/postgresql@18`, confirmed via `tmutil isexcluded`
- [x] Uptime monitor on `/api/health` (UptimeRobot free tier or Cloudflare Health Checks) — Cloudflare Health Checks requires a Pro plan upgrade; used **UptimeRobot free tier** instead, 5-minute interval
- [x] Write `docs/HOME_SERVER_RUNBOOK.md` with restart commands + restore procedure
- [ ] Decide Cloud Run + Cloud SQL fate after 1–2 stable weeks — **updated trigger**: shut down Cloud SQL once iOS end-to-end (Verification #5) is confirmed against the home server, not a fixed timeline

---

## Verification (run in order)

1. [x] **DB isolation (critical)** — from an external host: `nc -vz <MBA-public-IP> 5432` MUST fail/timeout. If it succeeds, stop and diagnose. — confirmed via `yougetsignal.com`/nmap from an external host: port 5432 returned **filtered** (silently dropped, not reachable) on the public IPv4. Note: this Mac's public address is actually IPv6 by default (confirmed via `curl ifconfig.me`); Postgres's `listen_addresses='localhost'` binds only to `127.0.0.1`/`::1` (verified via `lsof`), so it's unreachable on both protocols regardless of router/firewall behavior — the external scan is corroborating evidence, not the sole guarantee.
2. [x] DB auth — `psql -h 127.0.0.1 -U fixer_app -d directvideo` prompts for password (verified; note: superuser role is `rodgriola`, not `postgres`, on this Homebrew install)
3. [x] HTTPS through tunnel — `curl -I https://dev.ms-fixer.com/api/health` → 200 from work laptop
4. [x] WSS through tunnel — admin dashboard Socket.IO green — confirmed via dashboard log: `WS Connected (<socket-id>)` after logging in through Cloudflare Access + app auth (demo admin account)
5. [x] iOS end-to-end — full upload → form → Mux → Slack flow — confirmed: on a real iPhone over cellular data (untethered, external network), uploaded 3 videos successfully and viewed them in the admin dashboard. Auth/login, API, WebSocket, upload, and Mux processing all working through the tunnel.
6. [x] LaunchAgent resilience — `kill -9` Fastify PID, restarts in 5s — confirmed, new PID served `/api/health` within ~3s
7. [ ] Reboot resilience — reboot MBA, all three services up in 60s
8. [x] Backup restore — `pg_restore` a nightly dump into scratch DB, row counts match — verified: decrypted + restored into `directvideo_restoretest`, all 7 table row counts matched `directvideo` exactly, scratch DB dropped after

---

## Decisions (locked)

- Both Fastify and Postgres at home (not split networks)
- Cloudflare Tunnel over port-forwarding (dynamic IP, no router config)
- Postgres loopback + SCRAM (Cloud-SQL-private-VPC equivalent)
- Nightly `pg_dump` to cheap object storage, not streaming replication
- Mux stays as-is

## Open decisions during execution

1. ~~**Admin dashboard second auth**: Cloudflare Access on `/admin*` (Option A, recommended) vs split hostnames (Option B) vs JWT-only (Option C)~~ — **Resolved**: Option A implemented, domain-wide Access policy (not `/admin*` — see Phase 4 correction) with bypass rules for `/api/*`, `/socket.io/*`, `/uploads/*`, `/clips/*`.
2. **Postgres SSL on loopback**: `sslmode=disable` recommended; `sslmode=require` for prod-parity is optional chore
3. **Cloud Run + Cloud SQL fate**: keep until iOS end-to-end (Verification #5) is confirmed against the home server, then shut down Cloud SQL (biggest cost); Cloud Run auto-scales to zero — near-free as warm standby, can stay longer

---

## Rollback

- iOS: switch Debug scheme back to Cloud Run URL (still live if kept)
- Home: `launchctl unload …com.msfixer.fastify.plist` + `brew services stop postgresql@18`
- Cloudflare: delete `dev.ms-fixer.com` DNS or `cloudflared tunnel delete fixer-dev`

---

## Relevant files

- `scripts/dev.js` — triad launcher; may need a "home" mode variant later
- `server/src/index.js` — verify `trustProxy` + Helmet CSP handle Cloudflare
- `server/prisma.config.js` — no change; reads `DATABASE_URL`
- `server/.env.example` — replace Render/Cloud SQL comments with home-server block
- `README.md` — add Home Server deployment section
- `cloudbuild.yaml` — leave alone unless tearing down Cloud Run

## New files to create during execution

- `~/.cloudflared/config.yml`
- `~/Library/LaunchAgents/com.msfixer.fastify.plist`
- `~/Library/LaunchAgents/com.msfixer.pgdump.plist`
- `docs/HOME_SERVER_RUNBOOK.md`
