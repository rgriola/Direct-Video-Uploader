# Home Server Runbook — ms-fixer.com / dev.ms-fixer.com

Operational reference for the MacBook Air home server hosting Postgres 18 + Fastify, exposed via Cloudflare Tunnel. See `00-Home Server Plan — Postgres + Fastify .md` for the full setup history and rationale.

**Domains:** As of Oct 11, 2026 the apex `ms-fixer.com` (production, used by the iOS Release build and the public site) and `dev.ms-fixer.com` (kept as a secondary/testing hostname) both route through the same Cloudflare Tunnel to this home server. Cloud Run no longer receives any traffic for either hostname.

We do not use Google Cloud or Render.

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

Cloud Build and Render are retired, not deployment targets. `cloudbuild.yaml` has been removed.
The legacy Render script still uses `prisma db push --accept-data-loss` and must not be reused
without a separate migration review.

This DB uses Prisma migrations (not `db push`). Workflow:
1. Edit `server/prisma/schema.prisma`
2. Locally: `npx prisma migrate dev --name <description>` (creates + applies migration, needs a role with `CREATEDB` for the shadow DB — `fixer_app` intentionally lacks this; use the admin role via a one-off `DATABASE_URL` override if needed)

3. Back up first (`scripts/pg-backup.sh`) whenever a migration changes data or types
4. On the home server, from `server/` (the schema and the pinned Prisma version live there; running
   from the repo root fails with "Could not find Prisma Schema" and makes `npx` download a different Prisma):
   ```bash
   cd ~/apps/direct-video-uploader/server
   npx prisma migrate status    # lists pending migrations
   npx prisma migrate deploy    # uses fixer_app, no shadow DB needed
   ```
5. If a migration was bootstrapped as the admin role, fix ownership — tables **and enum types**
   (otherwise `ALTER TYPE` migrations fail with `must be owner of type`):
   ```sql
   ALTER SCHEMA public OWNER TO fixer_app;
   -- then for any tables/sequences/types still owned by the admin role:
   ALTER TABLE public.<table> OWNER TO fixer_app;
   ALTER TYPE public."<EnumName>" OWNER TO fixer_app;
   ```
   Check with `\dT+` and `\dt` in `psql -d directvideo`.
6. If `migrate deploy` fails, Prisma records the migration as failed and blocks later deploys.
   Once the cause is fixed (and the failed SQL didn't partially apply):
   `npx prisma migrate resolve --rolled-back <migration_name>`, then `migrate deploy` again.

## Super Admin bootstrap

`SUPER_ADMIN` can't be granted through the API. Set `SUPER_ADMIN_PHONE` (the account's
phone number, digits as stored) in `server/.env`, then after `migrate deploy`:
```bash
cd ~/apps/direct-video-uploader/server
npm run bootstrap:super-admin   # idempotent; exits 1 if unset or the account doesn't exist
```
To hand the role to someone else, change it directly in the database; the API refuses to
modify a Super Admin.

## Step 2.3 rollout prerequisites

- Assign the existing unassigned Team Admin to an organization and notify affected admins
  before their global access becomes team-scoped.
- Deploy the server update before distributing the iOS update. The updated client uses a
  clip-specific transcript route that older servers do not provide; transcript delivery
  will fail until the server is updated. Their legacy route can ignore a clip ID in the
  request body.
- HTTP scoping alone does not provide team-scoped dashboard refreshes or isolate public
  Mux playback URLs and `/uploads/`. Do not treat this phase as end-to-end media isolation.
- Do not re-upload while the original transfer may still be active: the existing Mux
  idempotency flow can return the same waiting upload URL to both attempts. A failed
  Mux status lookup now leaves the existing clip untouched; an upload already handed
  to Mux processing is not replaced. If processing remains stuck, investigate the Mux
  webhook and scheduled sync before attempting any manual repair. A reused waiting upload
  can also retain earlier clip metadata, including location, when a different video is
  selected. The workspace client stops a retry when it observes a changed asset, including
  immediately before the PUT, but it cannot detect unfetched or cross-device changes.
  Attempt and metadata binding remain release blockers.
- Transcript receipts identify the requested clip, but do not yet prove it remains the
  current attempt after a concurrent re-upload. Cross-device form edits are still
  last-write-wins. Resolve upload-attempt coordination and versioned form conflicts
  before relying on these workflows concurrently.
- The workspace client saves trims to Photos before creating the server asset. Manual
  recovery requires selecting and confirming a Photos representation. Verified v3 links
  and older links are retained locally but are not automatically selected, because they
  cannot establish the latest server upload attempt.
  Temporary videos request protection until first unlock to support background uploads;
  physical-device and locked-device validation are still required. Repeated live form
  requests can reopen completed details, and resubmitting them can overwrite existing
  details. See the iOS roadmap before distributing the client.
- Do not use the legacy Render workflow; it uses `prisma db push --accept-data-loss` and seeds
  demo accounts. The Cloud Build pipeline has been removed.
- Finish the physical-device checks described in `iOS-Modernization.md` before rollout.

## Step 2.2 moderation reconciliation rollout

The Step 2.2 reconciliation fix and Step 2.4 are merged to `main`; the owner reports the web
app deployed. The matching server version, production migration status, legacy-upload draining,
and real-Mux checks have not been confirmed. Verify what is already deployed and which checks
have passed before taking further action. Do not rely on pause or permanent removal in
production until the following checks pass against the actual Mux account.

1. Back up the home database and establish a rollback/restore plan. Stop issuing uploads and
   stop **all** old Fastify processes before deploying; old code can create or publish public
   playback IDs outside the new coordinator. Do not run mixed old and new server versions.
2. Inventory previously issued Mux direct-upload URLs, including any not represented in the
   database. Old URLs may request an automatic public playback ID even when their asset is
   paused. Cancel or drain them, wait for in-flight asset creation/processing to settle, and
   verify their terminal state and public playback IDs in Mux. Waiting an arbitrary interval
   or relying only on webhooks is not sufficient. Reconcile any untracked Mux assets manually.
3. Before migration, review conflicting and incomplete media references. For example, on the
   home database run these **read-only** queries and investigate any results:

   ```sql
   SELECT mux_asset_id, COUNT(DISTINCT asset_id)
   FROM clips WHERE mux_asset_id IS NOT NULL
   GROUP BY mux_asset_id HAVING COUNT(DISTINCT asset_id) > 1;

   SELECT mux_upload_id, COUNT(DISTINCT asset_id)
   FROM clips WHERE mux_upload_id IS NOT NULL
   GROUP BY mux_upload_id HAVING COUNT(DISTINCT asset_id) > 1;

   SELECT id, asset_id, mux_upload_id
   FROM clips WHERE mux_asset_id IS NULL
     AND (mux_playback_id IS NOT NULL OR stream_url IS NOT NULL OR thumbnail_url IS NOT NULL);

   SELECT storage_url, COUNT(*) FROM clips WHERE storage_url IS NOT NULL
   GROUP BY storage_url HAVING COUNT(*) > 1;

   SELECT id, asset_id FROM clips
   WHERE storage_url IS NOT NULL AND storage_url NOT LIKE '/uploads/%';
   ```

   The Mux-reference migration refuses an asset ID shared across different assets. An upload
   ID may allow a missing asset ID to be recovered; otherwise a playback URL without its Mux
   asset ID cannot be verified or revoked automatically. Shared, invalid, or symlinked local
   media also requires manual investigation. Keep such assets and references; do not clear
   their fields or hard-delete their owners to bypass an error.
4. With the old server stopped, check migration status and apply any pending migrations using
   the schema workflow above, build the matching dashboard, and start only the updated server.
   Confirm Mux credentials, webhook signature verification, and the media worker are configured.
   New direct uploads do not request an automatic playback ID; the coordinator creates one only
   for active media.
5. In the Super Admin **Moderation Audit** panel, inspect **Media requiring attention** and
   retry or resolve errors. `PENDING` and `ERROR` are not completed revocations: the app hides
   playback immediately and the dashboard hides its playback link while access is blocked.
   A previously issued public Mux URL may still work until Mux confirms revocation. Verify
   every paused/flagged asset has no public playback IDs and every removed Mux asset is gone.
   Check a new upload, pause, restore, removal, missed-webhook recovery, and a blocked legacy
   local URL in staging with real Mux before production use.
6. Monitor server logs and the issue list after restarting. The due queue takes at most 20
   assets per two-minute cycle, with up to four concurrent reconciliations; a backlog means
   individual assets may be checked less often. A healthy HTTP health check alone does not
   establish that media reconciliation is current.

**Unknown playback creation:** The Super Admin issue list shows the Mux asset, local operation
ID, and start time. A marker can represent an in-flight call or an unknown outcome after a
failure. Ask Mux to confirm that the relevant request cannot complete now **or later**; only
then use **Confirm Mux cannot complete request** and record how and when Mux confirmed it.
The operation ID and note are retained in the audit log. If Mux cannot confirm, leave the
operation unresolved and playback unavailable. Old playback references remain stored until
revocation is verified, then are cleared before replacement playback is attempted. Other
missing or conflicting references may require a controlled, backed-up database repair; there
is no dashboard action to invent a missing Mux association.

**Destructive operations:** A Super Admin can hard-delete a user only after every owned asset
is `REMOVED` and media cleanup is `SYNCED`, with no outstanding creation marker or held media
lock. Nuclear Reset returns 409 while any asset record remains. With no assets it clears
non-media data, preserves users, audit history, and the media-ID sequence, and does not
delete or verify Mux videos.

**Limitations:** Active Mux playback IDs remain public URLs. The merged `/uploads/` route
is still unauthenticated for known active files, although it denies moderated, unreferenced,
and symlinked paths and sends `Cache-Control: no-store`. Neither mechanism is team-scoped media
authorization. A viewer already streaming, a previously cached response, or a downloaded
file may remain playable after a pause or removal.

## Step 2.4 socket scoping rollout

Step 2.4 is merged to `main`, and the owner reports the web app deployed. Confirm the
matching server version and complete the Step 2.2 checks and required migrations above
before relying on the behavior. If an update is still needed, rebuild the dashboard and
restart Fastify using the commands above so the server and dashboard are updated together.

- Rich upload, form, and Mux notifications remain owner-only. Active asset changes also
  trigger a payload-free refresh for the owner's Team Admins and Super Admins; changes for
  an unassigned owner go only to Super Admins.
- Socket authentication reloads current account status, role, and organization. Changes
  through the API reconnect affected dashboards when roles or organizations change;
  suspension and deletion disconnect all of the affected user's sockets. Dashboard access
  and scoped data are rechecked. Direct database changes bypass this invalidation, so restart
  Fastify after making them.
- Notifications are best-effort and dashboard polling remains enabled. Verify cross-team
  isolation, reconnect after a team change, and suspension after deploying.
- Rooms, connection tracking, and authorization invalidation are process-local. The current
  single Fastify process is required; multiple instances need a shared Socket.IO adapter
  and coordinated revocation before relying on these guarantees.
- This does not make public Mux playback URLs or active legacy `/uploads/` URLs private.

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

- iOS: revert the app release or point the Debug scheme to an authorized environment; do not
  roll back to the retired Cloud Run deployment
- Home: `launchctl unload ~/Library/LaunchAgents/com.msfixer.fastify.plist` + `brew services stop postgresql@18`
- Cloudflare: delete the `ms-fixer.com` and/or `dev.ms-fixer.com` DNS routes (or `cloudflared tunnel delete fixer-dev`), and remove the corresponding public hostname from each of the 5 Zero Trust Access applications

## Viewing Database 
- cd ~/apps/direct-video-uploader/server
- npx prisma studio

## For quick queries
psql (CLI) — best for quick queries:

/opt/homebrew/opt/postgresql@18/bin/psql -d directvideo