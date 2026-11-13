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

```bash
git fetch origin
git branch -m main backup/main-before-sync
git switch -c main --track origin/main
git status
```

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
**To release a new server version:** `server/package.json` is the single source of truth for the
version reported by `/api/health` and the API docs. It is read once at startup, so restart Fastify
after deploying the bump.
```bash
cd ~/apps/direct-video-uploader/server
npm version patch --no-git-tag-version   # or minor / major; updates package.json + package-lock.json
launchctl unload ~/Library/LaunchAgents/com.msfixer.fastify.plist
launchctl load ~/Library/LaunchAgents/com.msfixer.fastify.plist
curl http://127.0.0.1:3000/api/health    # "version" should match package.json
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

`lsof -iTCP:5432 -sTCP:LISTEN` and `lsof -iTCP:3000 -sTCP:LISTEN` both should show `localhost` only, never `*`.

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

## Experimental original uploads and Mux handoff

Keep `UPLOAD_SESSIONS_ENABLED` and `MUX_ORIGINAL_INGEST_ENABLED` **off** on this
shared home backend; `dev.ms-fixer.com` is not isolated staging. The server now
has experimental capacity checks and an independently opt-in tracked-session
cleanup worker, but verified original backups, cleanup validation, proactive
storage alerts, tunnel and proxy log verification, isolated real-Mux testing,
and client integration remain open. Untracked directories are reported for
manual review, not automatically deleted. Recovery for failed linked Mux assets
and late webhooks after hard deletion also remains open. Back up the database
and apply all pending migrations **before** starting the new server code, even
if both upload and Mux flags remain off.

On an isolated test server only, upload sessions require explicit positive
`UPLOAD_STORAGE_MAX_BYTES` and `UPLOAD_STORAGE_MIN_FREE_BYTES` values; there are
no defaults. Choose them after measuring the intended storage root and volume.
The first is a conservative budget for the root's files and reservations; the
second is free space to retain on the entire filesystem. For example, replace
the path below with the verified root:

```bash
df -k /path/to/originals
du -sk /path/to/originals
```

`du` reports allocated blocks, whereas the guard counts apparent file lengths
and reservations; these numbers are not interchangeable. One GiB is
1,073,741,824 bytes. Provision an empty new root on the intended mount, or keep
the existing root and its `.dvu-storage-id`; do not reset the marker or delete
files/leases to bypass a safeguard. Use one host and the same root and limits
for all upload-writing processes. Stop old processes before changing settings.
A copied marker does not prove that the correct volume is mounted. See the
[upload-session API guide](docs/UPLOAD_SESSION_API.md#capacity-and-free-space-policy)
for accounting, recovery, and limitations; these checks do not replace backups
or independent disk monitoring.

Do not use `DEBUG=true`: the Mux SDK can log signed source URLs, and the server
refuses that setting when original ingest is enabled or prior attempts exist.
If the feature has ever been enabled, keep the original storage root and the
new reconciliation code available when disabling it. Unresolved creates and
crashed read leases can block removal; the Super Admin investigation and
audited recovery procedures are in [the upload-session API guide](docs/UPLOAD_SESSION_API.md#super-admin-recovery).
Do not confirm an absent Mux asset or closed read without independently
verifying it.

### Manual upload recovery with intake and Mux ingest off

Keep `UPLOAD_SESSIONS_ENABLED=false` and `MUX_ORIGINAL_INGEST_ENABLED=false`.
Inspection, cancellation, and read-only history are always registered; they
require the same active owner's JWT, are bounded and IP-rate-limited, and return
`Cache-Control: no-store`. No storage, upload-signing, capacity, or Mux
configuration is needed for these routes.

1. Back up the database, apply the existing migrations (including cancellation
   indexes), and update **every** server instance. This handler move adds no
   migration or flag; older instances may not expose or enforce recovery.
2. Use the same account and server and the saved client request UUID. Inspect
   `GET /api/original-upload-recovery/:clientRequestId` first; do not replay asset
   or session creation. Missing or bounded results do not prove freshness.
3. If cancellation is intended, manually send the bodyless
   `POST /api/assets/original-uploads/:clientRequestId/cancel` with that owner's
   JWT and no `Content-Type` header. A 200 contains `assetId` (possibly null)
   and at most 100 session IDs. It guarantees neither task termination nor
   deletion. An unknown UUID creates only a quota-controlled durable tombstone,
   not an asset, session, or media.
4. On 503 `INTENT_SESSION_LIMIT`, the fence has committed. Read
   `GET /api/assets/original-uploads/:clientRequestId/sessions` without a cursor,
   then pass each `nextCursor` unchanged as `after` until null (at most 100
   sessions per page). History is read-only, not cleanup proof.
5. On 429, honor `Retry-After`. A 404 is ambiguous, including hidden data or an
   old instance in a mixed deployment. Updated cancellation handlers commit
   the fence before hidden, inconsistent, or overflow responses, but errors
   do not prove successful cleanup. Preserve originals, staged data, and
   recovery records for reconciliation on hidden/inconsistent errors; do not
   blindly retry or delete data to clear them.

Never log signed URLs. Intake-off recovery does not enable individual session
abort, expiry, completion recovery, or cleanup. Independent worker configuration
and validation requirements below remain unchanged. This manual procedure does
not change durable client retries or authorize iOS integration: trusted
installation enrollment, a durable retry ledger, epoch policy, and event/task
reconciliation are still required before reopening the iOS gate.

## Opt-in upload-session cleanup

`UPLOAD_SESSION_CLEANUP_ENABLED` defaults to `false` and is independent of
upload intake and Mux handoff. Test it on an isolated server first; enabling it
on the home server is a separate operational decision, not a prerequisite for
deploying code with the flag off. It needs `STORAGE_DRIVER=local` and an
explicit, absolute `STORAGE_LOCAL_ROOT`, including when intake is off. No
upload signing secret or capacity limits are needed for cleanup alone.

Before enabling it, verify the actual mounted source volume, the existing
`.dvu-storage-id`, database backups, and recoverable original-file backups.
The marker does not prove that a copied volume is the intended physical
device. Do not create a replacement marker or empty directory to bypass a
missing mount. Configure the flag and existing root in the Fastify LaunchAgent,
then restart Fastify using the commands above. Keep upload intake and Mux
handoff off on the shared home backend.

The worker starts immediately and then every five minutes, processing at most
50 tracked candidates and inspecting at most 100 upload-directory entries per
pass. It can expire abandoned sessions and recover interrupted completion,
including while intake is disabled. It preserves published originals and
backups; untracked directories and unattributed assembly partials are not
automatically deleted. Removed assets remain the moderation reconciler's
responsibility. A recovered completion queues Mux only when handoff is enabled
at recovery time; enabling handoff later requires the owner's explicit
eligible retry in the [API guide](docs/UPLOAD_SESSION_API.md#4-inspect-or-explicitly-retry-a-mux-handoff).

Review the Fastify logs for `Original upload recovery completed`, `Original
upload cleanup deferred`, `Original upload cleanup failed`, `Upload session
cleanup cycle failed`, and `requires manual review`. The worker also logs its
start and stop. A busy warning may be transient; investigate if it persists.
This is log-based visibility, not independent alerting, and a stopped server
cannot report missed cleanup. The LaunchAgent's `StandardOutPath` and
`StandardErrorPath`, if configured, identify the Fastify log files.

For an unexpected directory, lock, lease, or failed cleanup:

1. If further automatic work is unsafe, set the cleanup flag to `false` and
   restart Fastify; its shutdown waits for the current cleanup cycle. Verify
   whether any other server process or upload writer is still running.
2. Privately verify the actual mount and marker, then correlate the logged
   session ID with its `upload_sessions` row, asset, status, reservation, and
   any `storage_write_leases`. Inspect the relevant `.uploads` entries and
   lock ownership without changing them. For an unrecognized entry without a
   session ID, inspect the inventory locally.
3. Confirm that writers and lock owners have stopped, understand whether the
   staged data belongs to a recoverable upload, and verify independent backups
   before deciding on any manual action. Do not delete data, leases, or locks
   merely to clear a warning or reclaim space. A failed operation may already
   have removed staged files before a later database error; inspect both the
   filesystem and database rather than assuming either outcome.

The worker only reclaims locks and write leases it can verify as stale on the
same host. Ambiguous recovery locks or other-host/live-looking leases remain
for manual investigation. This procedure does not automate deletion of
untracked upload directories.

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

The two direct commands below are for installations **without** the optional
monitoring wrappers. After installing those wrappers, use the monitored manual
commands in the monitoring section instead; direct execution bypasses the
shared database lock and does not update receipts.

**Manual database backup (unmonitored):**
```bash
~/apps/direct-video-uploader/scripts/pg-backup.sh
```
Output: `~/backups/directvideo_<timestamp>.sql.gz.gpg` (gzip + gpg symmetric AES256, passphrase at `~/.backup-passphrase`, 7-day local retention).

**Manual offsite sync (unmonitored):**
```bash
~/apps/direct-video-uploader/scripts/pg-backup-offsite-sync.sh
```
Syncs `~/backups/*.sql.gz.gpg` to Backblaze B2 (`b2backup:ms-fixer-backups`, rclone remote configured at `~/.config/rclone/rclone.conf`).

**Database restore procedure (tested and verified working):**
```bash
createdb directvideo_scratch   # or a real recovery target
gpg --batch --yes --passphrase-file ~/.backup-passphrase \
  --decrypt ~/backups/directvideo_<timestamp>.sql.gz.gpg 2>/dev/null \
  | gunzip \
  | psql -d directvideo_scratch -q
```
Verify row counts against the live DB before treating the restore as authoritative, then `dropdb directvideo_scratch` if it was just a test.

### Original-file backups

The database backups above **do not contain video files**. The optional
`scripts/backup_originals.py` workflow copies physically published originals
and their `.dvu-storage-id` marker hourly to **both** a separate external drive
and a Backblaze B2 prefix. Each destination is an rclone `crypt` remote with
encrypted file contents, filenames, and directories. Upload parts and assembly
`.partial-*` files are excluded. Publication can precede the database commit, so
the copy can include an orphan that was never finalized in PostgreSQL.

Nothing installs or starts this job automatically. Until both actual
destinations and a restore drill are verified, original backups remain a
rollout prerequisite; keep both experimental flags off.

The job never syncs source deletions or replaces a different existing backup
object. An operator must explicitly remove retained copies when appropriate.
This intentionally retains content deleted through the app: account for
privacy obligations, access controls, disk space, and B2 costs. If a backup is
removed while its original still exists, the next run will copy it again.
Backblaze may retain hidden historical object versions after a manual removal;
permanent removal requires checking those versions separately.

Each run verifies the configured source identity, actual mount points, a
separate destination filesystem and destination-volume marker, crypt settings,
and applicable B2 lifecycle rules. It refuses a nonempty destination without
the expected source marker, overlapping runs, unknown entries or symlinks under
`originals/`, symlinks or special files in the local backup tree, nested
filesystems, and changed source files. A bad local drive does not prevent an
independent B2 attempt, or vice versa; the overall run fails if either
destination fails. `cryptcheck` must verify every current original against the
encrypted object's underlying checksum. Deleted originals retained only in
backup are **not** included in that recurring check.

These are safeguards, not proof of two physical devices: separate APFS volumes
can share one disk, and a copied marker does not prove a volume's physical
identity. Verify the source and backup devices with `diskutil list` and
`diskutil info` before setup; for APFS, use `diskutil apfs list` to trace each
volume to its physical store. The backup drive must be external and physically
separate. Do not disconnect, force-unmount, move, or modify the source or
backup trees during a run. One host and one macOS user must own all runs and
the dedicated backup namespaces; other processes must not write to them.

#### One-time setup (manual; do not paste credentials into chat)

1. Use rclone **1.75.1 or later** and Python 3 on the home server. Identify the
   server's actual `STORAGE_LOCAL_ROOT`, its mounted volume, and a physically
   separate external backup volume. Keep rclone current with security updates.
   Set `RCLONE` to its actual executable:
   ```bash
   RCLONE="/opt/homebrew/bin/rclone"
   "$RCLONE" version
   ```
   If the root is set directly in the Fastify plist, this prints only that path:
   ```bash
   /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:STORAGE_LOCAL_ROOT' \
     "$HOME/Library/LaunchAgents/com.msfixer.fastify.plist"
   ```
   Otherwise inspect the server's configuration privately. The root must
   already have a valid `.dvu-storage-id`; do not invent or replace a marker
   on a nonempty root.

2. Set the following paths locally, replacing the example values with the
   verified mounts and server root. Mounts and directories must already exist;
   the local crypt directory must be a dedicated, existing directory below the
   external backup volume.
   ```bash
   SOURCE_VOLUME="/Volumes/<source-volume>"
   SOURCE_ROOT="/Volumes/<source-volume>/<server-storage-root>"
   BACKUP_VOLUME="/Volumes/<separate-backup-volume>"
   mkdir "$BACKUP_VOLUME/dvu-originals-encrypted"
   ```
   Only when deliberately preparing a verified **new, empty** source root
   with all writers stopped and no existing marker, initialize its marker:
   ```bash
   (umask 077; set -o noclobber; uuidgen > "$SOURCE_ROOT/.dvu-storage-id")
   ```
   After confirming the external volume is the intended device, create its
   marker **only if it has no existing marker**. The no-clobber setting makes
   an existing marker an error; do not replace one to bypass a mismatch.
   ```bash
   (umask 077; set -o noclobber; uuidgen > "$BACKUP_VOLUME/.dvu-original-backup-volume-id")
   SOURCE_ID="$(tr -d '[:space:]' < "$SOURCE_ROOT/.dvu-storage-id")"
   BACKUP_ID="$(tr -d '[:space:]' < "$BACKUP_VOLUME/.dvu-original-backup-volume-id")"
   ```

3. Use a **separate** private rclone configuration so encrypting it does not
   disrupt the existing database offsite job:
   ```bash
   mkdir -p "$HOME/.config/rclone"
   CONF="$HOME/.config/rclone/original-backups.conf"
   (umask 077; "$RCLONE" --config "$CONF" config)
   ```
   Create these remotes interactively:
   - a native B2 remote with an application key restricted to the intended
     bucket and the capabilities needed to list the bucket and lifecycle,
     list/read files, and upload files;
   - a local `crypt` remote named `dvu-original-local`, wrapping the absolute
     path `$BACKUP_VOLUME/dvu-originals-encrypted`, without `.` or `..` path
     components;
   - a B2 `crypt` remote named `dvu-original-b2`, wrapping a dedicated prefix
     such as `your-b2-remote:your-bucket/dvu-originals-encrypted`.

   Bucket and prefix components must start with an ASCII letter or digit and
   contain only ASCII letters, digits, hyphens, and underscores. This keeps
   the configured prefix identical to its B2 object-name prefix for lifecycle
   checks.
   Select standard filename encryption, encrypted directory names, encrypted
   file data, and strong crypt passwords and salts. Do not use a custom B2
   endpoint, disable B2 checksums, or allow B2 lifecycle rules to hide objects
   under this prefix automatically. The job checks the bucket's lifecycle
   before each B2 run and fails if it cannot inspect it. Other B2 policies or
   external processes can still change or remove objects; review them too.
   Encrypt this dedicated rclone configuration using rclone's configuration
   password menu, and make it private:
   ```bash
   chmod 600 "$CONF"
   ```
   Keep a protected, recoverable copy of the encrypted configuration, its
   configuration password, and both crypt passwords and salts **away from the
   server and backup drive**. Losing them makes the backups unrecoverable.
   Never print `rclone config show` or `rclone config dump`: they can expose
   credentials. Do not put passwords in command arguments, plists, or this repo.

4. Save the rclone configuration password in the login Keychain. The `-w` at
   the end prompts without placing the password in the command line:
   ```bash
   /usr/bin/security add-generic-password -a "$(id -un)" \
     -s com.msfixer.original-backup-rclone -w
   ```
   Use the same configuration password chosen in rclone, not a crypt password.
   Create a private helper that retrieves it without printing it to a terminal.
   Stop if the helper already exists rather than overwriting it:
   ```bash
   mkdir -p "$HOME/.config/dvu"
   HELPER="$HOME/.config/dvu/original-backup-password"
   (umask 077; set -o noclobber; cat > "$HELPER" <<'EOF'
   #!/bin/sh
   exec /usr/bin/security find-generic-password -a "$(/usr/bin/id -un)" \
     -s com.msfixer.original-backup-rclone -w
   EOF
   )
   chmod 700 "$HELPER"
   ```
   The job strips inherited `RCLONE_*` overrides, copies the encrypted config
   into a private temporary directory, and gets the password from this helper.
   The Keychain must be unlocked and accessible to the logged-in LaunchAgent.

5. From the deployed checkout, run one foreground backup and inspect its
   result. The command contains identities and paths, not passwords:
   ```bash
   SCRIPT="$HOME/apps/direct-video-uploader/scripts/backup_originals.py"
   ARGS=(
     --source-volume "$SOURCE_VOLUME" --source-root "$SOURCE_ROOT" --source-id "$SOURCE_ID"
     --backup-volume "$BACKUP_VOLUME" --backup-volume-id "$BACKUP_ID"
     --local-remote dvu-original-local --b2-remote dvu-original-b2
     --rclone-config "$CONF" --password-helper "$HELPER" --rclone "$RCLONE"
   )
   python3 "$SCRIPT" "${ARGS[@]}"
   ```
   Success requires `local backup verified`, `B2 backup verified`, and
   `originals backup complete` for the same run. A nonzero exit is a failure;
   don't enable the schedule until fixed. Error messages deliberately omit raw
   rclone output because it can contain sensitive paths or credentials.

6. Only after a successful manual run, create and load the hourly user
   LaunchAgent. The generated plist has paths and UUIDs, not secrets. The log
   files must be private:
   ```bash
   PLIST="$HOME/Library/LaunchAgents/com.msfixer.original-backup.plist"
   mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
   (umask 077; touch "$HOME/Library/Logs/com.msfixer.original-backup.out.log" \
     "$HOME/Library/Logs/com.msfixer.original-backup.err.log")
   chmod 600 "$HOME/Library/Logs/com.msfixer.original-backup.out.log" \
     "$HOME/Library/Logs/com.msfixer.original-backup.err.log"
   (umask 077; set -o noclobber; python3 "$SCRIPT" "${ARGS[@]}" --print-launchd > "$PLIST")
   plutil -lint "$PLIST"
   launchctl bootstrap "gui/$(id -u)" "$PLIST"
   launchctl kickstart "gui/$(id -u)/com.msfixer.original-backup"
   ```
   To change settings, stop the agent with `launchctl bootout
   "gui/$(id -u)/com.msfixer.original-backup"`, then regenerate the plist after
   preserving or explicitly removing the old one.

#### Monitoring, limitations, and recovery

```bash
launchctl print "gui/$(id -u)/com.msfixer.original-backup"
tail -n 40 "$HOME/Library/Logs/com.msfixer.original-backup.out.log"
tail -n 40 "$HOME/Library/Logs/com.msfixer.original-backup.err.log"
```

Check the timestamp and complete success messages for **each** run and both
destinations; a start or a single verified destination is not success. There is
an optional Super Admin monitoring dashboard and opt-in Slack alerts described
below; neither can report while the server is down. Investigate missing/stale runs,
locked Keychain, missing drives, B2 permissions/lifecycle, full destinations,
and nonzero exits. For deeper diagnosis, run narrowly scoped rclone commands
locally without debug logging or printing the config; protect any diagnostic
output. Never clear a marker or overwrite backup files to make a run pass.

Full verification scans the local backup tree, rereads each current original
once per destination, and makes B2 metadata/range requests. A large library
can exceed an hour, consume bandwidth or incur charges; an overlapping
invocation fails rather than overlap. Sleep, disconnection, slow transfers, and failures increase the
recovery-point gap, so hourly scheduling is not an hourly recovery guarantee.
New files appearing after inventory wait for the next run. Database dumps and
file copies are independent, not a transactionally consistent point-in-time
snapshot; retain and reconcile both during recovery. The private temporary
directory contains an encrypted config snapshot and a plaintext list of
storage keys, not video bytes; an abrupt termination can leave it behind in
the system temporary directory. Protect and clean up those remnants deliberately.

Periodically restore from **each** destination into a new, empty private
scratch directory on a verified volume. The following example restores from
the local crypt remote; use `dvu-original-b2:` to drill the offsite copy. Run
from the same shell after setting `CONF`, `HELPER`, and `RCLONE` as above:
```bash
RESTORE_DIR="$HOME/recovery/originals-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$HOME/recovery"
mkdir -m 700 "$RESTORE_DIR"
env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/bin:/bin" \
  "$RCLONE" --config "$CONF" --ask-password=false \
  --password-command "\"$HELPER\"" --crypt-strict-names \
  --crypt-filename-encryption standard --crypt-directory-name-encryption=true \
  --crypt-no-data-encryption=false --crypt-pass-bad-blocks=false \
  copy "dvu-original-local:" "$RESTORE_DIR" --immutable
```
Check the exit status, marker, file counts, and representative restored bytes
against an independently recorded source SHA-256 where available. Restoring
also authenticates encrypted data blocks; periodically test retained files
whose live originals were deleted. A successful current-source `cryptcheck`
does not verify those retained-only files. Keep the scratch copy private and
remove it deliberately after verification.

To remove a retained original deliberately, first confirm that the live
original is gone, identify its **exact** storage key, and stop the LaunchAgent
after any running backup finishes. Never remove the storage marker, use a
wildcard, or run `sync`/`purge` on either backup namespace. This helper uses
the same isolated environment as the restore command:
```bash
rclone_originals() {
  env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/bin:/bin" \
    "$RCLONE" --config "$CONF" --ask-password=false \
    --password-command "\"$HELPER\"" --crypt-strict-names \
    --crypt-filename-encryption standard --crypt-directory-name-encryption=true \
    --crypt-no-data-encryption=false --crypt-pass-bad-blocks=false "$@"
}
KEY="originals/<exact-owner>/<exact-asset>/<exact-clip>/<exact-object>"
rclone_originals deletefile "dvu-original-local:$KEY" --dry-run
rclone_originals deletefile "dvu-original-b2:$KEY" --dry-run
```
Only after reviewing both dry runs and explicitly authorizing deletion, repeat
those two exact `deletefile` commands **without** `--dry-run`. Confirm the
results independently. The native B2 backend can hide a file rather than
permanently delete its versions; inspect and remove any retained historical
versions in Backblaze if permanent erasure is required. If the scheduled B2
key lacks delete permission, use a separate authorized operator configuration
with the same crypt settings and B2 prefix. `rclone_originals
cryptdecode --reverse "dvu-original-b2:" "$KEY"` maps the plaintext key to its
encrypted name relative to the configured B2 prefix for that investigation.
Resume the LaunchAgent afterward.

For actual recovery, restore the database separately to an isolated target,
restore files into an empty verified storage root, and preserve the recovered
`.dvu-storage-id`. Compare database storage keys, sizes and checksums with the
restored originals; investigate missing, retained-deleted, orphaned, and
legacy-unverified entries before switching the server. Do not merge an entire
backup into an active root or assume deleted content should be resurrected.
Reconcile Mux and upload state before enabling either experimental flag.

## Monitoring

- Uptime: UptimeRobot free tier, monitoring `https://ms-fixer.com/api/health` every 5 minutes (also safe to point at `https://dev.ms-fixer.com/api/health`, same backend).
- Cloudflare Access protects the dashboard (site root) on both `ms-fixer.com` and `dev.ms-fixer.com` — bypassed for `/api/*`, `/socket.io/*`, `/uploads/*`, `/clips/*` on each.

### Storage and backup dashboard monitoring (opt-in)

This feature is **disabled by default** and does not install or start any backup
job. It reports to the Super Admin dashboard and, only if separately configured
(step 6), posts Slack alerts while Fastify is running. It cannot notify anyone
while the server or host is down. UptimeRobot's existing health check is
separate and does not check storage or backups. Verified alert delivery and an
independent server-down alert remain production rollout prerequisites; keep
both experimental original-upload and Mux flags off.

When enabled, Fastify checks every five minutes and the dashboard refreshes
every 30 seconds. The panel reports:

- Free space on the original source volume, original backup drive, and database
  backup volume. Warning and critical thresholds are explicit byte counts; free
  space **at or below** a threshold triggers that level. The source and external
  original-backup identities and mount points must match the configured values.
- Original-root bytes on disk and, if `UPLOAD_STORAGE_MAX_BYTES` is set, the
  configured budget and a separately configured used-byte warning. These numbers
  **exclude outstanding upload reservations and write leases** and are not an
  admission-capacity calculation. The check walks original-storage filesystem
  metadata each cycle; investigate timeouts or significant I/O on large trees.
- Separate last-result/freshness checks for local and B2 originals, the nightly
  local database dump, and the weekly database offsite sync. Originals are
  reported successful only after the existing crypt checks finish. Database
  status describes a completed job and recorded local archive, **not** a
  verified SQL restore or an independent check of B2 contents. Retained-only
  originals are not included in recurring crypt checks.
- If tracked upload-session cleanup is enabled, its cycle health. A failure is
  critical until a later complete scan finds no failures; a cycle that has not
  finished for 15 minutes is also critical. Deferred sessions and untracked
  storage still require log review. Cleanup status is in memory and resets
  when the server restarts.

Missing receipts show a warning; failed, stale, or overlong runs show critical.
An unreadable receipt, missing/wrong mount, failed check, or timed-out check
shows unknown rather than healthy. A previously completed backup can become
stale while a long run is still in progress. The default freshness limits are
three hours for each original destination, 36 hours for the local database,
and nine days for the offsite database sync. Adjust these for real run times.
The panel also warns if the monitoring cycle itself becomes stale. A job that
cannot start or record a receipt may show missing, stale, or unknown rather
than an immediate failure; continue checking LaunchAgent logs.

#### Configuration and installation

Perform this only after deploying the code **and** completing the separate
original-backup setup above. No credentials should be pasted into chat. The
Fastify process and all monitored jobs must run as the same macOS user.

1. Create a private state directory on the home server's system disk, outside
   the source and backup volumes. If it already exists, inspect its ownership
   and permissions rather than replacing it:
   ```bash
   MONITOR_STATE="$HOME/.dvu-monitor"
   mkdir -m 700 "$MONITOR_STATE"
   ls -ld "$MONITOR_STATE"
   ```
   The directory must be owned by this user, mode `700`, and not a symlink.
   The private receipts record timestamps and, for database backups, the
   archive basename and file metadata; they contain neither passwords nor
   backup contents. Losing or replacing them makes status unconfirmed until
   monitored jobs run again.

2. Privately edit the server's environment, using actual **absolute** paths
   and the identities from the existing original-backup setup. Do not copy
   placeholders, shell variables, or `~` literally into `.env`. Select free
   space thresholds appropriate to each real volume; warning must be greater
   than critical. Confirm the database volume with `df` and the mount/device
   with `diskutil`; `/` is appropriate only if the database directory is on
   the system volume. Directories below the chosen volumes must not contain
   symlinks or nested mounts.
   ```dotenv
   STORAGE_LOCAL_ROOT="/Volumes/REPLACE_SOURCE/REPLACE_STORAGE_ROOT"
   DVU_MONITORING_ENABLED="true"
   DVU_MONITOR_STATE_DIR="/Users/REPLACE_USER/.dvu-monitor"
   DVU_MONITOR_SOURCE_VOLUME="/Volumes/REPLACE_SOURCE"
   DVU_MONITOR_SOURCE_ID="REPLACE_WITH_SOURCE_UUID"
   DVU_MONITOR_SOURCE_WARNING_FREE_BYTES="REPLACE_WITH_BYTES"
   DVU_MONITOR_SOURCE_CRITICAL_FREE_BYTES="REPLACE_WITH_BYTES"
   DVU_MONITOR_BACKUP_VOLUME="/Volumes/REPLACE_BACKUP"
   DVU_MONITOR_BACKUP_ID="REPLACE_WITH_BACKUP_VOLUME_UUID"
   DVU_MONITOR_BACKUP_WARNING_FREE_BYTES="REPLACE_WITH_BYTES"
   DVU_MONITOR_BACKUP_CRITICAL_FREE_BYTES="REPLACE_WITH_BYTES"
   DVU_MONITOR_DATABASE_VOLUME="/"
   DVU_MONITOR_DATABASE_DIR="/Users/REPLACE_USER/backups"
   DVU_MONITOR_DATABASE_WARNING_FREE_BYTES="REPLACE_WITH_BYTES"
   DVU_MONITOR_DATABASE_CRITICAL_FREE_BYTES="REPLACE_WITH_BYTES"
   DVU_MONITOR_ORIGINAL_STALE_HOURS="3"
   DVU_MONITOR_DATABASE_LOCAL_STALE_HOURS="36"
   DVU_MONITOR_DATABASE_OFFSITE_STALE_HOURS="216"
   ```
   If `UPLOAD_STORAGE_MAX_BYTES` is set, also set
   `DVU_MONITOR_SOURCE_WARNING_USED_BYTES` to a positive byte count below that
   maximum. If `UPLOAD_STORAGE_MIN_FREE_BYTES` is set, the source critical
   free-space threshold must be at least that minimum. Invalid monitoring
   configuration appears as a critical dashboard check and is logged; it does
   not enable upload sessions or prevent Fastify from starting. If the Fastify
   plist already sets an environment variable, update it there too: inherited
   environment values take precedence over the server's `.env`.

3. Add `--monitor-state-dir "$MONITOR_STATE"` to the existing original-backup
   `ARGS` array from the setup above. Run a foreground backup and confirm both
   destinations complete successfully. To update an existing hourly LaunchAgent,
   wait for any active run to finish, preserve its original plist for rollback,
   generate a candidate outside `~/Library/LaunchAgents`, and inspect it:
   ```bash
   ARGS+=(--monitor-state-dir "$MONITOR_STATE")
   python3 "$SCRIPT" "${ARGS[@]}"
   CANDIDATE="$MONITOR_STATE/original-backup.candidate.plist"
   (umask 077; set -o noclobber; python3 "$SCRIPT" "${ARGS[@]}" --print-launchd > "$CANDIDATE")
   plutil -lint "$CANDIDATE"
   ```
   After reviewing the candidate, replace the original LaunchAgent plist and
   reload it using the same controlled procedure as the original setup. Keep
   its schedule and private logs. Manual original runs without the monitoring
   argument do not update receipts.

4. Update the existing nightly database and weekly offsite LaunchAgent plists
   **after their current jobs finish**. Save private copies for rollback.
   Preserve each plist's label, `StartCalendarInterval`, environment, log paths,
   and other settings; replace only `ProgramArguments`. Use the absolute
   Python 3 executable from `command -v python3` and replace all `REPLACE_USER`
   and `REPLACE_PYTHON3` placeholders. Do not add a second `ProgramArguments`
   key. If a plist also has a `Program` key, remove it or set it to the same
   Python executable; leaving the old program there can bypass the wrapper.
   For the nightly dump:
   ```xml
   <key>ProgramArguments</key>
   <array>
     <string>REPLACE_PYTHON3</string>
     <string>/Users/REPLACE_USER/apps/direct-video-uploader/scripts/monitor_job.py</string>
     <string>--state-dir</string><string>/Users/REPLACE_USER/.dvu-monitor</string>
     <string>--check</string><string>database-local</string>
     <string>--created-archive-dir</string><string>/Users/REPLACE_USER/backups</string>
     <string>--archive-max-age-hours</string><string>36</string>
     <string>--</string><string>/bin/bash</string>
     <string>/Users/REPLACE_USER/apps/direct-video-uploader/scripts/pg-backup.sh</string>
   </array>
   ```
   For the weekly offsite sync:
   ```xml
   <key>ProgramArguments</key>
   <array>
     <string>REPLACE_PYTHON3</string>
     <string>/Users/REPLACE_USER/apps/direct-video-uploader/scripts/monitor_job.py</string>
     <string>--state-dir</string><string>/Users/REPLACE_USER/.dvu-monitor</string>
     <string>--check</string><string>database-offsite</string>
     <string>--require-archive-dir</string><string>/Users/REPLACE_USER/backups</string>
     <string>--archive-max-age-hours</string><string>36</string>
     <string>--</string><string>/bin/bash</string>
     <string>/Users/REPLACE_USER/apps/direct-video-uploader/scripts/pg-backup-offsite-sync.sh</string>
   </array>
   ```
   The archive directory must match the one actually used by **both** scripts
   and the dashboard; the wrapper refuses a symlink there. Keep
   `--archive-max-age-hours` aligned with
   `DVU_MONITOR_DATABASE_LOCAL_STALE_HOURS`. Validate both plists with
   `plutil -lint`, then reload the existing LaunchAgents and inspect their
   status and private logs. Do not create duplicate jobs.

   **Intentional safety change:** monitored database jobs take a shared lock.
   The offsite wrapper waits for another monitored database job and then
   refuses to run `rclone sync` unless a recent successful local receipt
   identifies an unchanged nonempty archive. Missing, stale, failed,
   interrupted, or changed local backups block the sync. If the monitoring
   directory or lock is unavailable, the local dump is still attempted but
   its wrapper exits nonzero; the offsite sync is blocked. The offsite sync is
   also blocked if its start receipt cannot be recorded. Run manual database
   jobs through these same wrapper arguments. Direct runs bypass the lock and
   receipts; do not modify the backup directory during an offsite sync.
   The underlying `rclone sync` still mirrors local deletions when it runs;
   this guard is not an immutable or independently verified remote backup.

   For a manual run after installation, use the same private state and archive
   paths and the same age limit as the plists. These commands create a real
   dump and, in the second case, perform a real B2 sync:
   ```bash
   MONITOR_STATE="$HOME/.dvu-monitor"
   MONITOR_SCRIPT="$HOME/apps/direct-video-uploader/scripts/monitor_job.py"
   python3 "$MONITOR_SCRIPT" --state-dir "$MONITOR_STATE" --check database-local \
     --created-archive-dir "$HOME/backups" --archive-max-age-hours 36 -- \
     /bin/bash "$HOME/apps/direct-video-uploader/scripts/pg-backup.sh"
   python3 "$MONITOR_SCRIPT" --state-dir "$MONITOR_STATE" --check database-offsite \
     --require-archive-dir "$HOME/backups" --archive-max-age-hours 36 -- \
     /bin/bash "$HOME/apps/direct-video-uploader/scripts/pg-backup-offsite-sync.sh"
   ```
   Adjust these example paths and `36` if the deployed configuration differs.

5. Rebuild the dashboard and restart Fastify as described in **Rebuilding the
   admin dashboard**, then sign in as Super Admin and inspect each check. Allow
   one monitoring cycle and the next scheduled jobs, or deliberately run the
   monitored jobs after reviewing their effects. Verify failure and recovery
   with a safe isolated test setup; never simulate failure by deleting a real
   backup or disconnecting an in-use volume. Check LaunchAgent exit status and
   logs as well. A successful receipt does not replace periodic restore drills.

6. Optional Slack alerts: invite the existing Fixer Slack bot (the one using
   `SLACK_BOT_TOKEN`) to a private operations channel, then set:
   ```dotenv
   DVU_MONITOR_ALERT_SLACK_CHANNEL="REPLACE_CHANNEL_NAME"
   DVU_MONITOR_ALERT_REPEAT_HOURS="6"
   ```
   Use the lowercase channel name without `#`. Fastify posts once when a check
   becomes `warning`, `critical`, or `unknown`, again when its status changes or
   after the repeat interval (1–168 hours, default 6), and once on recovery.
   Alert state is in memory, so a restart re-sends unresolved problems. A failed
   post is retried on the next cycle and shows **Monitoring alerts** as critical
   on the dashboard; an invalid channel or missing token does the same. Messages
   contain only check labels, statuses, and generic messages. Restart Fastify,
   then verify delivery with a safe isolated test setup, not by filling or
   unmounting a real volume.

For future integrations, server code can register additional checks using
`fastify.monitoring.registerCheck({ id, label, category, collect })` and
subscribe to periodic snapshots with `fastify.monitoring.subscribe(listener)`.
Checks return a status (`ok`, `warning`, `critical`, or `unknown`) and a safe
message; `category` is `storage`, `backup`, or `service`. Subscriber failures
and check timeouts are logged. The optional Slack alerts in step 6 use this
subscriber hook; no external service monitors the server itself.

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