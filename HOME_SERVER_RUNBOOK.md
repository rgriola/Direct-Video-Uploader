# Home Server Runbook — ms-fixer.com / dev.ms-fixer.com

Operational reference for the MacBook Air home server hosting Postgres 18 + Fastify, exposed via Cloudflare Tunnel. See `00-Home Server Plan — Postgres + Fastify .md` for the full setup history and rationale.

**Domains:** As of Oct 11, 2026 the apex `ms-fixer.com` (production, used by the iOS Release build and the public site) and `dev.ms-fixer.com` (kept as a secondary/testing hostname) both route through the same Cloudflare Tunnel to this home server. Cloud Run no longer receives any traffic for either hostname.

## Services running on this Mac

| Service | Managed by | Plist/config |
|---|---|---|
| Postgres 18 | `brew services` | `/opt/homebrew/var/postgresql@18/` |
| Fastify server | `launchd` (user LaunchAgent) | `~/Library/LaunchAgents/com.msfixer.fastify.plist` |
| Cloudflare Tunnel | `launchd` (system LaunchDaemon) | `/Library/LaunchDaemons/com.cloudflare.cloudflared.plist`, config at `/etc/cloudflared/config.yml` |
| Nightly DB backup | `launchd` (user LaunchAgent, 2am daily) | `~/Library/LaunchAgents/com.msfixer.pgdump.plist` |
| Weekly offsite sync | `launchd` (user LaunchAgent, Sun 3am) | `~/Library/LaunchAgents/com.msfixer.pgdump-offsite.plist` |

## Restart commands

**Postgres:**
```bash
brew services restart postgresql@18
```

**Fastify server:**
```bash
launchctl unload ~/Library/LaunchAgents/com.msfixer.fastify.plist
launchctl load ~/Library/LaunchAgents/com.msfixer.fastify.plist
```

**Cloudflare Tunnel (system service, needs sudo):**
```bash
sudo launchctl unload /Library/LaunchDaemons/com.cloudflare.cloudflared.plist
sudo launchctl load /Library/LaunchDaemons/com.cloudflare.cloudflared.plist
```

**After any `npm ci` / `npm install` in `server/`:** the Prisma client stub gets reset. This is now handled automatically by the `postinstall` script (`prisma generate`), but if the server crash-loops with `SyntaxError: Named export 'PrismaClient' not found`, run manually:
```bash
cd ~/apps/direct-video-uploader/server && npx prisma generate
```

## Health checks

```bash
curl http://127.0.0.1:3000/api/health          # local
curl https://ms-fixer.com/api/health           # through tunnel, production domain (should bypass Cloudflare Access)
curl https://dev.ms-fixer.com/api/health       # through tunnel, secondary domain (should bypass Cloudflare Access)
```

`lsof -iTCP:5432 -sTCP:LISTEN` and `lsof -iTCP:3000 -sTCP:LISTEN` should both show `localhost` only, never `*`.

## Rebuilding the admin dashboard

The dashboard (`admin/`) builds into `server/public/` (gitignored — build artifact, not committed).
**The restart is required, not optional:** `server/src/index.js` serves `server/public/` via
`@fastify/static` with `wildcard: false`, which registers a route per file only at process
startup. A rebuild emits new content-hashed filenames, so a running server has no route for
them until it restarts — skipping the restart leaves the dashboard showing a blank page (its
JS bundle 404s).
```bash
cd ~/apps/direct-video-uploader/admin
npm ci && npm run build:check   # tsc type-check + vite build
launchctl unload ~/Library/LaunchAgents/com.msfixer.fastify.plist
launchctl load ~/Library/LaunchAgents/com.msfixer.fastify.plist
```

## Schema changes

This DB uses Prisma migrations (not `db push`). Workflow:
1. Edit `server/prisma/schema.prisma`
2. Locally: `npx prisma migrate dev --name <description>` (creates + applies migration, needs a role with `CREATEDB` for the shadow DB — `fixer_app` intentionally lacks this; use the admin role via a one-off `DATABASE_URL` override if needed)

3. On the home server, from `server/` (the schema and the pinned Prisma version live there; running
   from the repo root fails with "Could not find Prisma Schema" and makes `npx` download a different Prisma):
   ```bash
   cd ~/apps/direct-video-uploader/server
   npx prisma migrate status    # lists pending migrations
   npx prisma migrate deploy    # uses fixer_app, no shadow DB needed
   ```
4. Back up first (`scripts/pg-backup.sh`) whenever a migration changes data or types
5. If a migration was bootstrapped as the admin role, fix table ownership:
   ```sql
   ALTER SCHEMA public OWNER TO fixer_app;
   -- then for any tables/sequences still owned by the admin role:
   ALTER TABLE public.<table> OWNER TO fixer_app;
   ```

## Super Admin bootstrap

`SUPER_ADMIN` can't be granted through the API. Set `SUPER_ADMIN_PHONE` (the account's
phone number, digits as stored) in `server/.env`, then after `migrate deploy`:
```bash
cd ~/apps/direct-video-uploader/server
npm run bootstrap:super-admin   # idempotent; exits 1 if unset or the account doesn't exist
```
To hand the role to someone else, change it directly in the database; the API refuses to
modify a Super Admin.

## Backup & restore

**Manual backup:**
```bash
~/apps/direct-video-uploader/scripts/pg-backup.sh
```
Output: `~/backups/directvideo_<timestamp>.sql.gz.gpg` (gzip + gpg symmetric AES256, passphrase at `~/.backup-passphrase`, 7-day local retention).

**Manual offsite sync:**
```bash
~/apps/direct-video-uploader/scripts/pg-backup-offsite-sync.sh
```
Syncs `~/backups/*.sql.gz.gpg` to Backblaze B2 (`b2backup:ms-fixer-backups`, rclone remote configured at `~/.config/rclone/rclone.conf`).

**Restore procedure (tested and verified working):**
```bash
createdb directvideo_scratch   # or a real recovery target
gpg --batch --yes --passphrase-file ~/.backup-passphrase \
  --decrypt ~/backups/directvideo_<timestamp>.sql.gz.gpg 2>/dev/null \
  | gunzip \
  | psql -d directvideo_scratch -q
```
Verify row counts against the live DB before treating the restore as authoritative, then `dropdb directvideo_scratch` if it was just a test.

## Monitoring

- Uptime: UptimeRobot free tier, monitoring `https://ms-fixer.com/api/health` every 5 minutes (also safe to point at `https://dev.ms-fixer.com/api/health`, same backend).
- Cloudflare Access protects the dashboard (site root) on both `ms-fixer.com` and `dev.ms-fixer.com` — bypassed for `/api/*`, `/socket.io/*`, `/uploads/*`, `/clips/*` on each.

## Rollback (see main plan doc for full detail)

- iOS: switch Debug scheme back to Cloud Run URL; Release build uses `ms-fixer.com` directly, so a DNS-level rollback (below) is required to revert production traffic
- Home: `launchctl unload ~/Library/LaunchAgents/com.msfixer.fastify.plist` + `brew services stop postgresql@18`
- Cloudflare: delete the `ms-fixer.com` and/or `dev.ms-fixer.com` DNS routes (or `cloudflared tunnel delete fixer-dev`), and remove the corresponding public hostname from each of the 5 Zero Trust Access applications

## Viewing Database 
- cd ~/apps/direct-video-uploader/server
- npx prisma studio

## For quick queries
psql (CLI) — best for quick queries:

/opt/homebrew/opt/postgresql@18/bin/psql -d directvideo