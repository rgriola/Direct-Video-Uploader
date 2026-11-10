# Experimental Upload Session API

This server-only API stores a native original and can optionally hand it to Mux
for playback. Upload sessions and the Mux handoff are **separately disabled by
default**. Existing clients continue using direct-to-Mux uploads. Do not enable
either feature on the home server or in production yet: backups, proactive
storage alerts, an automatic expiry/orphan sweep, proxy-log verification,
isolated real-Mux validation, and client integration remain open. The dev and
production hostnames currently share the home backend; the dev hostname is not
an isolated test environment.

## Isolated development configuration

Set `UPLOAD_SESSIONS_ENABLED=true` only on an isolated test server. Provide
`UPLOAD_SESSION_SIGNING_SECRET` with at least 32 bytes and a different value
from `JWT_SECRET`. Generate a random secret locally, for example:

```sh
node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
```

Configure `STORAGE_DRIVER=local` and an absolute `STORAGE_LOCAL_ROOT` outside
the repository. Provision an empty new root on the intended mounted volume, or
preserve the verified `.dvu-storage-id` marker when using an existing root. An
unmarked nonempty root requires investigation; the server will not initialize
a new identity over it.

Set both `UPLOAD_STORAGE_MAX_BYTES` and `UPLOAD_STORAGE_MIN_FREE_BYTES` to
positive decimal byte counts appropriate for that root and volume. There are
no defaults. The server refuses to enable upload sessions without both limits,
with an unsupported storage driver, an invalid flag, a missing or short signing
secret, or the JWT secret reused as the upload signing secret. Production also
requires an explicit absolute storage root. One GiB is 1,073,741,824 bytes.

### Capacity and free-space policy

The storage budget covers all regular files under the original storage root,
including retained originals, staged and orphaned files, and the marker. It
uses apparent file lengths; hard-linked paths are counted separately, so it is
conservative and is not the same measurement as physical disk blocks. Symlinks,
special files, nested mounted filesystems, unverified roots, and measurement
failures stop new writes rather than being ignored.

Each unfinished session reserves twice its declared size plus 1 MiB for
metadata. This covers staged parts, duplicate-part retries, and assembly.
Each active part or assembly write also holds a durable reservation for its
declared write size plus 64 KiB. Admission is serialized across server
processes and requires both:

- measured root bytes plus all unreleased session reservations, active write
  reservations, and the new session reservation to be at most
  `UPLOAD_STORAGE_MAX_BYTES`; and
- filesystem space available to the server to be at least
  `UPLOAD_STORAGE_MIN_FREE_BYTES` plus those outstanding and new reservations.

Before each part or assembly write, the server rechecks the root budget and
free space against all active write reservations and the proposed write.
Already-written bytes may also be covered by reservations, so admission can
stop conservatively before the folder is actually full. Retained originals and
untracked files still count after a session reservation is released. Limits
apply globally, not per user.

An equivalent create retry does not allocate another session or require free
space. Low capacity returns **507** for a new session or additional write;
status checks and abort/cleanup remain available. Once space is restored,
clients can retry and request new signed URLs if needed. A missing or
unverifiable root, an unknown legacy reservation, or unavailable capacity
measurement returns **503**. The server logs these failures, but it does not
yet proactively alert while the system is idle.

Reservations are released only after session files have been removed or
completion and cleanup have been verified. A failed abort, expiry cleanup, or
moderation cleanup keeps the reservation. Existing sessions are conservatively
backfilled by the migration; a session without a known size blocks capacity
admission until its data has been investigated and cleaned. An owner can retry
abort or access a completed session to retry its cleanup; removed assets use
moderation reconciliation. No automatic expiry/orphan sweep is provided.

The free-space check is a snapshot, not an operating-system disk quota. Other
processes, filesystem metadata, snapshots, quotas, or a changing mount can
consume space after the check; in-flight writes are not stopped merely because
another process consumes the reserve. Actual `ENOSPC`/`EDQUOT` write failures
are logged and reported as 507. Monitor the volume independently, keep the root
private, and do not modify it while uploads are running.

All upload-writing processes must use this code, the same database, the same
local root and limits, and the same host. Stop old processes before deploying or
changing limits. A dead same-host writer's lease is reclaimed conservatively on
a later capacity check; an unverified other-host or live-looking PID lease is
retained for investigation. Do not delete leases or storage files merely to
make capacity available. Verify the actual mount and backups independently;
the marker alone cannot distinguish a copied volume. A stalled upload request
can keep its write reservation until the request or server process ends; do not
reclaim a lease while its writer may still be active.

Treat each signed URL as a bearer credential. Use HTTPS, do not share or log
it, and ensure the reverse proxy and tunnel also suppress query strings.
Fastify omits query strings from request and 404 logs; that does not configure
logging at proxies or other infrastructure. Signed-URL responses use
`Cache-Control: no-store`. Rotating the signing secret invalidates outstanding
URLs; an active owner can request new ones.

An opt-in encrypted original-file backup workflow is documented in the
[home-server runbook](../HOME_SERVER_RUNBOOK.md#original-file-backups). It is not
enabled or provisioned automatically. Until both actual destinations and a
restore drill are verified, the backup rollout prerequisite remains open.

### Optional Mux handoff

On an isolated test backend only, after applying the database migration, set:

```text
UPLOAD_SESSIONS_ENABLED=true
MUX_ORIGINAL_INGEST_ENABLED=true
MUX_ORIGINAL_READ_SIGNING_SECRET=<separate random secret of at least 32 bytes>
MUX_ORIGINAL_READ_BASE_URL=https://<isolated-server-origin>
MUX_ORIGINAL_READ_TTL_SECONDS=3600
```

The read secret must differ from both `JWT_SECRET` and
`UPLOAD_SESSION_SIGNING_SECRET`. The base URL must be an HTTPS origin without
credentials, a path, query, or fragment; loopback HTTP is allowed outside
production. The TTL defaults to one hour and must be between 300 and 86,400
seconds. Valid Mux API credentials and a webhook signing secret are required.
The appropriate TTL, tunnel behavior, Mux source fetches, and proxy logging
must be verified with real Mux before rollout.

Do not set `DEBUG=true`: the installed Mux SDK logs request and response bodies,
which can contain signed source URLs. The server rejects that setting when the
handoff is enabled, and also refuses to start with it after any original-ingest
attempt exists, even if the handoff is later disabled.

## Protocol

All requests except the signed PUT require an active user's bearer JWT. Create
an asset first with the existing `POST /api/assets` route. A new original
session requires an owned, active, `UPLOADING` asset with no other clip. The
server initializes its clip and reserves that asset for original uploads.

### 1. Create or retry

`POST /api/assets/:assetId/upload-sessions`

```json
{
  "expectedSizeBytes": "15",
  "expectedSha256": "77ececd9176974f1a4c22a09919d4c7c0f70d35042f2380f8eb4147bb5c5e2d2"
}
```

The example is the SHA-256 of the 15 bytes `native original`. Size may be a
safe integer or a decimal string from 1 through 524,288,000 bytes (500 MiB).
SHA-256 is required and is normalized to lowercase. A new session returns 201;
an equivalent retry of an open or completed session returns 200. Different
integrity metadata conflicts with an existing session (409). After abort or
expiry, creating a new session reuses the reserved clip once previous cleanup
has finished; a busy cleanup returns 409 and can be retried.

The response contains `uploadSession` with `id`, `assetId`, `clipId`, `status`,
`expectedSizeBytes` (decimal string), `expectedSha256`, `partSizeBytes`
(52,428,800), `partCount`, `expiresAt`, `completedAt`, and `parts`. The session
expires after 24 hours. Private storage keys are not returned. When the Mux
handoff is enabled, the response also contains `muxIngest`: `null` if no
handoff has been requested, or an object containing `status`, `attemptCount`,
`nextAttemptAt`, and a sanitized `lastError`.

### 2. Sign and upload parts

`POST /api/upload-sessions/:sessionId/parts/:partNumber/sign` returns:

```json
{
  "url": "/api/upload-sessions/<sessionId>/parts/1?expires=<unixSeconds>&signature=<signature>",
  "partNumber": 1,
  "sizeBytes": 15,
  "expiresAt": "<ISO-8601 timestamp>"
}
```

Resolve the relative URL against the same server origin. It is valid for at
most five minutes and never beyond the session expiry. The signature binds
the owner, session, part number, required part size, and expiry. The server
checks the URL when the request starts and rechecks the account, asset, session
state, and session expiry before publishing the part.

`PUT` the raw bytes to that URL with `Content-Type: application/octet-stream`
and an exact `Content-Length`. The signed URL is the authorization for the
PUT; a JWT is not required on that request. Chunked transfer encoding is
rejected (411). Other incorrect lengths are rejected (400 or 413), and an
incorrect content type is rejected (415).

Parts are numbered from 1 through `partCount`. Every part except the last is
exactly 50 MiB; the last contains the remaining bytes. Parts may arrive out of
order. A successful response contains `part` with `partNumber`, `sizeBytes`
(decimal string), and `sha256`. Retrying an identical completed part is
idempotent. Concurrent writes to the same part, or retrying it with different
bytes, return 409; abort and start a fresh session if a stored part is wrong.
Interrupted streams do not publish partial parts.

### 3. Resume, complete, or abort

- `GET /api/upload-sessions/:sessionId` returns the session and its recorded
  parts for the owner. Use the `OPEN` parts list to decide which parts to send.
- `POST /api/upload-sessions/:sessionId/complete` verifies consecutive parts,
  total byte count, and whole-file SHA-256 before attaching the private original
  to the clip. A successful retry returns the same completed session. Missing
  parts or an in-progress operation return 409; integrity mismatch returns 422.
- `DELETE /api/upload-sessions/:sessionId` aborts an unfinished session.
  Retrying is safe; an already expired session reports `EXPIRED`. If cleanup is
  busy, retry until it succeeds. A completed original cannot be aborted (409).

Invalid, expired, suspended-account, or moderated-asset signed PUTs return 403.
An expired session is reported as 410 when an operation requires it to be
open. A missing or mismatched storage location, an unknown reservation, or a
missing completed file is reported as 503 instead of claiming the original is
available. Insufficient capacity or free space is reported as 507.

With the Mux handoff disabled, completion stores the original but does not make
it playable, and the asset and clip remain `UPLOADING`. With the handoff
enabled, completion atomically queues one ingest job; the clip moves to
`PROCESSING` once the remote asset is linked. Mux readiness is asynchronous:
the existing media coordinator creates a public playback ID and sends the
existing ready notification only after it verifies that the asset is active and
ready. The native original is retained after Mux succeeds. The existing
one-hour orphan job deliberately skips assets with any original session. There
is no automatic sweep for abandoned sessions yet.

### 4. Inspect or explicitly retry a Mux handoff

`POST /api/upload-sessions/:sessionId/mux-ingest` requires the active owner's
JWT and is available only when the handoff is enabled. It queues an eligible
completed original that predates the feature, or explicitly retries a
confirmed failed job. It returns 202 with the session and `muxIngest` status;
repeating it for an already queued or linked job does not create another job.
An in-progress, unknown, or conflicting attempt returns 409 and must not be
blindly retried.

| Status | Meaning |
| --- | --- |
| `QUEUED` | Waiting for the worker or a bounded retry. |
| `CREATING` | An operation was persisted before the Mux create request. |
| `LINKED` | A Mux asset ID was retained; playback may still be processing or may have failed. |
| `FAILED` | A known pre-create failure or rejection needs an explicit owner retry. |
| `UNKNOWN` | Creation may have happened; Super Admin investigation is required. |
| `CONFLICT` | Late or contradictory remote references need manual reconciliation. |

The worker disables SDK retries for Mux asset creation. It permits at most
three local preflight failures or Mux HTTP 429 responses in one cycle: the
initial attempt and at most two retries, with 10- and 20-second backoff. Mux
documents that a request rejected because
its rate-limit bucket is empty is not processed:
[Mux API rate limits](https://www.mux.com/docs/core/make-api-requests#api-rate-limits).
Timeouts, connection failures, other HTTP errors, invalid responses, and a
server crash during creation remain `UNKNOWN`; passthrough is for correlation,
not an idempotency guarantee. Previously completed originals are not queued
automatically.

`LINKED` alone does not mean playback succeeded. If Mux processing fails,
including after the source URL expires, the clip and asset become `ERROR`;
the original and remote reference are retained. The owner retry endpoint
returns 409 rather than claiming success. Re-ingesting a linked failed asset is
not implemented: a Super Admin must investigate it in media issues, and this
recovery workflow must be designed and tested before rollout.

Mux reads through a separate signed `GET`/`HEAD` capability with single-range
support, not the public `/uploads/` route. Both methods share a limit of 120
requests per minute per IP; exceeding it returns 429 with `Retry-After`. Each
request checks the current operation, expiry, completed original metadata,
owner status, and active moderation. Original reads close when the operation
expires, authorization changes, coordination fails, or the server shuts down.
Do not log or share these URLs, including in tunnel, reverse-proxy, or Mux
debug logs.

## Moderation and storage safety

An asset that has ever had an original session cannot use the legacy Mux-upload
route, even after abort. To fall back to Mux, create a new asset. Pausing or
flagging stops new part publication; an owner can still inspect a paused
session, but flagged or removed sessions return 404. Permanent removal deletes
the session parts and any completed original before reporting reconciliation as
`SYNCED`; a busy operation or cleanup failure leaves it pending or in error.
An unresolved Mux create also prevents a removal from being reported as
`SYNCED`. Durable read leases prevent original deletion while a response is
still open, including after a lost database connection. A crash can leave a
lease requiring audited Super Admin recovery; it is not automatically assumed
closed.

Keep the storage root and the new database schema available even if either
feature flag is later disabled. Disabling the Mux handoff stops new jobs and
signed reads, but the worker still marks interrupted creates as unknown and
webhooks still retain late references. Do not roll back to code that lacks these
safeguards while attempts or read leases remain unresolved.

### Super Admin recovery

`GET /api/admin/media-issues` lists problematic ingest jobs and outstanding
original-read leases. A lease includes an `id`, `attemptId`, `serverInstanceId`,
and creation time; the read server logs its instance ID at startup.

- If an original read lease remains after a crash, first verify that the
  corresponding server process and its response connection have actually
  stopped. Only then call
  `POST /api/admin/assets/:assetId/original-reads/confirm-closed` with
  `{ "leaseId": "...", "confirmed": true, "reason": "..." }`. An active
  advisory read lock blocks this action, but absence of a lock alone is **not**
  proof that an old response has stopped. The confirmation is audited and
  reconciliation runs again.
- For an `UNKNOWN` create, independently verify with Mux that no asset was
  created **and that the request cannot still create one**. A missing webhook
  is not proof. Only after verifying this, call
  `POST /api/admin/assets/:assetId/mux-ingest/confirm-absent` with
  `{ "operationId": "...", "confirmed": true, "reason": "..." }`. Active or
  unrecovered read leases block confirmation. The action is audited, marks the
  attempt `CONFIRMED_ABSENT`, and leaves the job `FAILED` for an explicit owner
  retry; it does not retry automatically.

While the original's database records exist, late or duplicate Mux webhooks
retain their remote asset references. A contradictory reference places the job
in `CONFLICT`, hides/revokes playback, and requires investigation; do not clear
references to force a retry. Removed assets are reconciled against every retained
Mux reference.

Hard-deleting the owner also deletes the attempt records after cleanup. A
contradictory webhook arriving afterward is logged and rejected with 503, but
its reference cannot be retained locally. A mistaken absence confirmation can
therefore leave an orphaned Mux asset. Durable post-deletion correlation has not
been implemented and remains a rollout blocker; absence confirmation must not
be treated as a substitute for proving the remote request is finished.

Each new local original key is bound to the `.dvu-storage-id` marker in its
storage root. A missing or different marker prevents cleanup from being
reported as successful. Legacy keys without that identity require manual
recovery before deletion can be confirmed. Preserve the marker with an
intentional restore, but verify the actual mounted volume and backups
operationally: the marker cannot distinguish a copied clone carrying the same
identity. Never remove the marker to reset a root containing originals.
