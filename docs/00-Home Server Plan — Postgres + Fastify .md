# Home Server Plan — Postgres + Fastify on MacBook Air via Cloudflare Tunnel

_Drafted: September 25, 2026_
_Owner: Rod_
_Status: **Draft** — awaiting execution (target: later this week)_

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

Cloudflare edge → outbound TLS tunnel from MacBook Air (`cloudflared`, no open ports at home) → `http://127.0.0.1:3000` Fastify → `psql :5432` SCRAM loopback → Postgres 18 `directvideo` DB. Nothing at home is internet-reachable except what the tunnel forwards to `localhost:3000`.

---

## Phase 1 — MacBook Air host prep

- [ ] Install Xcode Command Line Tools: `xcode-select --install`
- [ ] Install Homebrew if missing
- [ ] `brew install postgresql@18 cloudflared node@20 jq`
- [ ] Set stable hostname: `sudo scutil --set HostName fixer-server`
- [ ] Disable auto-sleep (System Settings → Battery → Prevent sleeping when display is off)
- [ ] (Optional) DHCP-reserve the Air's LAN IP in the router

## Phase 2 — Postgres 18 "prod-like"

- [ ] `brew services start postgresql@18`
- [ ] `postgresql.conf`: `listen_addresses='localhost'`, `password_encryption='scram-sha-256'`, memory tuning (`shared_buffers=2GB`, `effective_cache_size=6GB`, `work_mem=16MB`), logging
- [ ] `pg_hba.conf`: **remove all `trust` lines**, require `scram-sha-256` on `127.0.0.1/32` and `::1/128`, keep `peer` for local `postgres` admin only
- [ ] Restart: `brew services restart postgresql@18`
- [ ] Create non-superuser role + DB:
  ```sql
  CREATE ROLE fixer_app LOGIN PASSWORD '<strong>' NOSUPERUSER NOCREATEDB NOCREATEROLE;
  CREATE DATABASE directvideo OWNER fixer_app;
  ```
- [ ] Verify SCRAM prompts for password on both `fixer_app` and `postgres` connections
- [ ] Enable macOS App Firewall; confirm `lsof -iTCP:5432 -sTCP:LISTEN` shows `127.0.0.1` only

## Phase 3 — Fastify at home

- [ ] Clone repo to `~/apps/direct-video-uploader`, `cd server && npm ci`
- [ ] Author `server/.env`:
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
- [ ] `prisma db push` + `npm run seed`
- [ ] Confirm `trustProxy` is enabled in server (Cloudflare forwards `CF-Connecting-IP`)
- [ ] Verify `lsof -iTCP:3000 -sTCP:LISTEN` shows `127.0.0.1:3000` only, NOT `*:3000`
- [ ] Install LaunchAgent `~/Library/LaunchAgents/com.msfixer.fastify.plist` with `KeepAlive=true`, `RunAtLoad=true`, logs to `~/Library/Logs/msfixer/`

## Phase 4 — Cloudflare Tunnel

- [ ] `cloudflared tunnel login` (browser auth to Cloudflare account, select `ms-fixer.com` zone)
- [ ] `cloudflared tunnel create fixer-dev` — save the UUID
- [ ] Author `~/.cloudflared/config.yml`:
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
- [ ] `cloudflared tunnel route dns fixer-dev dev.ms-fixer.com`
- [ ] Test foreground: `cloudflared tunnel run fixer-dev`, then `curl -I https://dev.ms-fixer.com/healthz` from work laptop → 200
- [ ] Install as system service: `sudo cloudflared service install`
- [ ] (Recommended) Add Cloudflare Access email-OTP policy on `/admin*` — leave `/api/*` and `/socket.io/*` open (JWT-gated already)

## Phase 5 — Client + config updates

- [ ] iOS `ServerConfig.swift` Debug scheme → `https://dev.ms-fixer.com`
- [ ] Admin dashboard verify Socket.IO auto-detects `wss://`
- [ ] README.md: add "Home Server (Cloudflare Tunnel)" subsection under Deployment
- [ ] server/.env.example: replace stale Render/Cloud SQL comments with home-server block

## Phase 6 — Ops, backups, monitoring

- [ ] Nightly `pg_dump` LaunchAgent → `~/backups/`, 7-day retention
- [ ] Weekly offsite copy → GCS Coldline or Backblaze B2
- [ ] Uptime monitor on `/healthz` (UptimeRobot free tier or Cloudflare Health Checks)
- [ ] Write `docs/HOME_SERVER_RUNBOOK.md` with restart commands + restore procedure
- [ ] Decide Cloud Run + Cloud SQL fate after 1–2 stable weeks

---

## Verification (run in order)

1. [ ] **DB isolation (critical)** — from an external host: `nc -vz <MBA-public-IP> 5432` MUST fail/timeout. If it succeeds, stop and diagnose.
2. [ ] DB auth — `psql -h 127.0.0.1 -U postgres -d directvideo` prompts for password
3. [ ] HTTPS through tunnel — `curl -I https://dev.ms-fixer.com/healthz` → 200 from work laptop
4. [ ] WSS through tunnel — admin dashboard Socket.IO green
5. [ ] iOS end-to-end — full upload → form → Mux → Slack flow
6. [ ] LaunchAgent resilience — `kill -9` Fastify PID, restarts in 5s
7. [ ] Reboot resilience — reboot MBA, all three services up in 60s
8. [ ] Backup restore — `pg_restore` a nightly dump into scratch DB, row counts match

---

## Decisions (locked)

- Both Fastify and Postgres at home (not split networks)
- Cloudflare Tunnel over port-forwarding (dynamic IP, no router config)
- Postgres loopback + SCRAM (Cloud-SQL-private-VPC equivalent)
- Nightly `pg_dump` to cheap object storage, not streaming replication
- Mux stays as-is

## Open decisions during execution

1. **Admin dashboard second auth**: Cloudflare Access on `/admin*` (Option A, recommended) vs split hostnames (Option B) vs JWT-only (Option C)
2. **Postgres SSL on loopback**: `sslmode=disable` recommended; `sslmode=require` for prod-parity is optional chore
3. **Cloud Run + Cloud SQL fate**: keep 1–2 weeks, then delete Cloud SQL (biggest cost); Cloud Run auto-scales to zero — near-free as warm standby

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
