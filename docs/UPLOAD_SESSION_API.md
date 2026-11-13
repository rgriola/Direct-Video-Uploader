# Experimental Upload Session API

This experimental API stores a native original and can optionally hand it to Mux
for playback. Upload sessions, the Mux handoff, and tracked-session cleanup are
**separately disabled by default**. Existing clients continue using
direct-to-Mux uploads unless they explicitly opt into a supported experimental
client. Do not enable upload intake or Mux handoff on the home server or in
production yet: verified backups, proactive storage alerts,
cleanup validation, proxy-log verification, isolated real-Mux validation, and
client integration remain open. The dev and production hostnames currently
share the home backend; the dev hostname is not an isolated test environment.

Apply the `20261110200000_original_upload_intents` migration before deploying
this server version, even when upload sessions remain disabled: existing asset
routes also read the new upload-mode fields. Do not enable store-first clients
until all server instances run the new code; older instances do not enforce the
new pre-session reservation. Also apply `20261111150000_asset_upload_source`,
which adds the nullable asset `uploadSource` column read by asset routes.

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
clients can retry and request new signed URLs if needed. Cleanup may return
**409** while a write is active or cannot be verified; retry after it stops.
A missing or unverifiable root, an unknown legacy reservation, or unavailable
capacity measurement returns **503**. The server logs these failures, but it
does not yet proactively alert while the system is idle.

Reservations are released only after session files have been removed or
completion and cleanup have been verified. A failed abort, expiry cleanup, or
moderation cleanup keeps the reservation. Existing sessions are conservatively
backfilled by the migration; a session without a known size blocks capacity
admission until its data has been investigated and cleaned. An owner can retry
abort or access a completed session to retry its cleanup; removed assets use
moderation reconciliation. The optional worker below can also recover eligible
tracked sessions; untracked directories are reported, not automatically deleted.

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

### Optional tracked-session cleanup

The worker is an independent opt-in; enabling upload sessions does not enable
cleanup, and cleanup can run with upload intake and the Mux handoff disabled.
On an isolated test server, after verifying the existing mount and storage
identity, configure:

```text
UPLOAD_SESSION_CLEANUP_ENABLED=true
STORAGE_DRIVER=local
STORAGE_LOCAL_ROOT=/absolute/path/to/existing/originals-root
```

Cleanup requires an explicit absolute local root, even outside production, but
does not require upload-signing secrets or capacity limits. A missing root or
marker is reported as an error; the worker does not create one for inventory.
The marker alone does not prove that the correct physical volume is mounted.
See the [home-server runbook](../HOME_SERVER_RUNBOOK.md#opt-in-upload-session-cleanup)
before enabling the worker or investigating its logs.

The worker runs at startup and every five minutes without overlapping its own
cycles. Each pass considers at most 50 database-tracked candidates and scans at
most 100 entries in the upload inventory; a backlog can therefore take multiple
passes. It expires due `OPEN` sessions, recovers interrupted `COMPLETING`
sessions, and finishes cleanup of `ABORTED`, `EXPIRED`, or `COMPLETED` sessions
with outstanding or unknown reservations. Expiry leaves the asset retryable;
it does not mark the asset as failed.

Live or unverified write leases and locks defer cleanup. The worker verifies
database references, the storage identity and any staged manifest, checks
published-original integrity before recovering completion, and releases a
reservation only after staged cleanup succeeds. Removed assets use moderation
reconciliation. It does not delete published originals or backups. Unexpected
files in a tracked session, inconsistent metadata, or unverified originals are
retained for investigation; unattributed assembly partials are also left alone.
Untracked directories, unexpected inventory entries, and potentially abandoned
locks are logged for manual review, not deleted. A persistent busy warning may
indicate an ambiguous nested lock or lease and also requires investigation.

If recovery finalizes an original while the Mux handoff is disabled, no Mux job
is queued automatically later. Once handoff is enabled on an isolated server,
the owner can explicitly request an eligible handoff using the endpoint below.
The worker logs outcomes and errors but does not provide external alerts.

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
an asset first, preferably with the idempotent original-upload route below. The
existing `POST /api/assets` route remains available to legacy clients. A new
original session requires an owned, active, `UPLOADING` asset with no other
clip. The server initializes its clip and reserves that asset for original
uploads. Bodyless control requests must omit `Content-Type: application/json`;
an empty JSON body is invalid.

Clients should call `GET /api/upload-capabilities` (always registered, bearer
JWT, `Cache-Control: no-store`) and offer store-first uploads only when it
returns `{ "originalUploads": true }`. The flag reflects
`UPLOAD_SESSIONS_ENABLED`; it does not report free space or Mux handoff state.

### 0. Reserve an original-upload asset

`POST /api/assets/original-uploads` is registered only when upload sessions
are enabled. Persist a new client-generated UUID, the chosen upload mode, and
the staged original's size and SHA-256 before making this request, then reuse
the same values after a lost response:

```json
{
  "clientRequestId": "b9162fc4-5c45-4f6e-9de8-1c0b181a75fd",
  "fileName": "native.mov",
  "expectedSizeBytes": "15",
  "expectedSha256": "77ececd9176974f1a4c22a09919d4c7c0f70d35042f2380f8eb4147bb5c5e2d2",
  "uploadSource": "WEB"
}
```

The optional file name is a string or `null`. The optional `uploadSource` is
`IOS` or `WEB` and is stored on the asset for support and reporting; it is not
an authorization signal. A retry may omit it, but a retry that supplies a
different source than the stored one returns 409. A new reservation returns 201;
an equivalent retry returns 200 with the same `asset`, including its `id`,
`mediasourceId`, `mediasourceUrl`, `originalFileName`, `status`, `clipCount`,
`totalDuration`, and `uploadMode: "ORIGINAL"`. Request IDs are scoped to the
authenticated owner. Reusing an ID with a different file name, size, or digest
returns 409. Later sessions on the reservation must use the same size and
digest. These fields describe unverified expected content until completion.
After the asset is permanently deleted, the retained intent returns 410 rather
than recreating it; the size and digest are deleted with the asset, and its
nonsecret UUID tombstone is removed when the owner is deleted. This protection
survives the administrative non-media reset.

To cancel without replaying either creation request, call
`POST /api/assets/original-uploads/:clientRequestId/cancel` with the same
owner's JWT, without a body or `Content-Type` header. A 200 response contains
`assetId` (or `null`) and the complete `sessionIds` list (possibly empty, at
most 100). The operation records a durable owner-scoped cancellation even if
the reservation never arrived. Retrying it returns the existing asset and
sessions without creating either. A previously removed, uncancelled intent
still returns 410. If a linked asset is flagged or removed, the fence is
recorded but the response is 404 without asset or session IDs. The route is also
unavailable when upload intake is disabled, so a 404 never confirms that a
fence was recorded or that cleanup completed.

For an unknown request ID, at most 100 unreserved cancellation fences per
owner are admitted in a rolling 24-hour window. A 429
`INTENT_CANCELLATION_QUOTA` includes `Retry-After` in seconds and does not
record a fence; park and retry. Existing intents and fence retries bypass this
quota but remain subject to the IP rate limit. Cancelled intents whose assets
were later deleted also count in the window. Accepted fences do not expire;
the quota limits admission rate, not lifetime storage. If more than 100
sessions exist for an asset, the fence is recorded but the endpoint returns 503
`INTENT_SESSION_LIMIT` without a partial list. Do not remove the fence,
session records, or stored data merely to clear this error.

After recording the fence, enumerate longer histories with
`GET /api/assets/original-uploads/:clientRequestId/sessions`. Each response
contains `assetId`, up to 100 `sessionIds` ordered by ID, and `nextCursor`.
Start without a cursor and pass each non-null `nextCursor` unchanged as the
`after` query parameter until it is null. A failed page may be retried, but
do not skip pages or count a repeated page as progress. Asset and session IDs
are case-sensitive; only the client request UUID is normalized. The route
requires the same active owner, an existing cancelled intent, and a visible
asset, and is IP-rate-limited. Missing or uncancelled intents and hidden assets
return 404 without identifiers. Session ownership and identifier validation
cover the fetched page and lookahead entry; an inconsistency there returns an
ID-free 503. If the asset disappears after a cursor has been issued, the next
page also returns an ID-free 503. Each page is read-only and does not create,
abort, or delete anything.

Cancellation and every page also check for session/clip asset mismatches in
either direction across the whole history, not just the page. A mismatch
returns an ID-free 503; cancellation still records the fence. Preserve the
staged data and seek operator reconciliation before retrying. These checks
coordinate with the supported upload paths, not arbitrary database changes
or a transaction that fails or rolls back.

For a pre-existing session/clip asset mismatch, an authorized individual
session GET, completion, or abort returns an ID-free 409 with
`{"error":"Upload session clip does not belong to its asset"}`. Recovery
that detects the mismatch preserves staged data for reconciliation.

For a pre-existing non-null clip `storageKey` that conflicts with the expected
key or has a mismatched `storageDriver` (which is not checked when `storageKey`
is null), or a non-null `storageUrl`, `muxUploadId`, or `muxAssetId`,
an `OPEN` completion checks the locked clip before transitioning or publishing,
and `COMPLETING` recovery checks before removing staged data. A conflict returns
an ID-free 503; capacity validation can return an earlier 503. Repair the
reference before retrying. For an already matching key, a new transition also
requires a recorded clip size and SHA-256 matching both session expectations;
missing evidence fails closed. Recovery requires complete clip metadata and
compares any available session expectations; when a legacy expected SHA is
missing, a published object's digest is independently checked against the clip
before staged cleanup. A mismatch found by hashing returns 422. Finalization
rechecks the locked clip's key, driver, digest, size, URL, and Mux references
before accepting an existing same-key reference. A clip reassignment observed
between the completion snapshot and the locked transition returns 409; a
changed session storage key, driver, expected size, or hash returns 503.
These checks do not protect against arbitrary database rewrites after the
transition or guarantee staged data survives late reference changes or other
finalization failures.

An empty page or `assetId: null` does not prove that earlier sessions or
storage were cleaned up: an asset can have been deleted, taking its session
records with it. If the asset ID changes or disappears while paging, or a
previously known asset or session cannot be reconciled, keep cancellation
pending and request operator reconciliation. All returned and locally known
session IDs still require individual reconciliation.

Cancellation is serialized with reservation and session creation. After it
commits, further creation requests for that intent return 410; a session that
won the race is included in a successful `sessionIds` response. Signing checks
the fence before recovery and again before issuing a URL; a signing response
that passed its last check may nevertheless arrive after cancellation.
Previously signed PUTs that observe the fence at request start are rejected
with a generic 403. Publication rechecks the fence while holding the owner and
asset locks shared with cancellation, followed by the session lock: if
cancellation commits first, an in-flight part cannot be published, though
bytes may already have arrived.
If publication acquires the locks first, the part may be published before the
fence. A filesystem publication can survive a failed or uncertain database
transaction; preserve it for authenticated session recovery and reconciliation.
The fence is also serialized with the transition of an `OPEN` session to
`COMPLETING`: if the fence commits first, an otherwise eligible attempt
reaching that transition returns 410, leaving the session and staged parts for
later reconciliation and abort. Earlier validation or capacity errors can
still take precedence.
An inconsistent session/clip asset reference prevents a new transition with
409 and leaves staged content untouched for investigation.
Sessions without an intent are not blocked by the cancellation fence, but
still undergo the completion and reference checks above.
A transition that commits first can still publish its original and enqueue an
enabled Mux handoff after the fence.
Recovery can also finalize a previously `COMPLETING` session; if it instead
reopens the session, a new completion is fenced. Retrying an already completed
session remains idempotent. Deploy the migrations and cancellation-aware code
to every server instance before clients rely on these guarantees; older
instances ignore the fence. The fence does **not** abort sessions, stop
in-flight transfers, cryptographically revoke already issued part URLs, or
delete stored originals. Stop local tasks and inspect and abort each unfinished
session with the same owner's current credentials; retry cleanup if needed.
An earlier creation response or notification may still arrive after the fence,
so clients must reject stale results and reconcile the returned IDs. Inspecting
or aborting a session already `COMPLETING` can recover and finalize its
original, and may enqueue an enabled Mux handoff. Bytes already received cannot
be recalled.

Reservation prevents direct-to-Mux upload on that asset even before a session
exists. An original reservation without a session is protected from the
automatic orphan sweep and administrative empty-asset cleanup for 24 hours.
After that, the sweep can mark an uncancelled reservation `ERROR`, while
cancelled intents are excluded from both the sweep and administrative
empty-asset cleanup. That cleanup can still remove other eligible empty assets.
A client must report an error or removal and start a fresh job with a new
request ID instead of claiming the old reservation was resumed.

`GET /api/assets/:id` and `GET /api/assets/mine` expose `uploadMode` as
`ORIGINAL`, `MUX`, or `UNKNOWN`, including while upload-session routes are
disabled. The migration backfills mode from legacy original sessions, retained
originals, and Mux upload identifiers. Missing or contradictory evidence
produces `UNKNOWN`. Do not guess a mode or fall back to Mux for an unknown or
original asset. Session IDs and private storage identifiers are not included
in this mode-discovery data.

For a new direct-Mux job, `POST /api/assets` accepts `uploadMode: "MUX"` and
records it before a Mux upload is created. The response must confirm `MUX`
before the client starts that upload. The field is optional for older clients;
without it, a new asset has `UNKNOWN` mode until there is Mux evidence. An
explicit `ORIGINAL` mode is rejected on this endpoint: use the content-bound
reservation instead. Deploy this server change to all instances before
releasing clients that require confirmation.

If upload-session routes are disabled while a store-first job is pending, park
the job and surface the unavailable service; do not silently switch it to the
direct-Mux path. A changed client preference applies only to new jobs.

### 1. Create or retry

`POST /api/assets/:assetId/upload-sessions`

```json
{
  "expectedSizeBytes": "15",
  "expectedSha256": "77ececd9176974f1a4c22a09919d4c7c0f70d35042f2380f8eb4147bb5c5e2d2",
  "metadata": {
    "capturedAt": "2026-01-15T12:00:00.000Z",
    "duration": 12,
    "resolution": "1920x1080",
    "codec": "HEVC",
    "orientation": "landscape",
    "deviceModel": "iPhone",
    "osVersion": "iOS"
  }
}
```

The example is the SHA-256 of the 15 bytes `native original`. Size may be a
safe integer or a decimal string from 1 through 524,288,000 bytes (500 MiB).
SHA-256 is required and is normalized to lowercase. A new session returns 201;
an equivalent retry of an open or completed session returns 200. Different
integrity metadata conflicts with an existing session (409). After abort or
expiry, creating a new session reuses the reserved clip once previous cleanup
has finished; a busy cleanup returns 409 and can be retried. If an asset has
multiple recoverable original sessions, creation returns 409 instead of
guessing which session to resume.

An equivalent retry returns the verified completed session even if its asset
has since moved to `PROCESSING`, `READY`, or `ERROR`; that session status does
not imply Mux playback is ready. A moderated asset still rejects new or
retried session writes.

`metadata` is optional and uses the existing direct-Mux metadata fields. It may
also include `gpsLat`, `gpsLon`, and `gpsAltitude`; clients must disclose that
location can be included. Validated metadata and asset duration are saved
when the first clip is created, using the existing default values when omitted.
On a retry, nonempty supplied metadata fields
must match the saved values or the server returns 409; omitted fields do not
overwrite them. Creating the first clip emits the existing owner-scoped
`upload:complete` and `form:request` events once, at upload start, not after
the original has been verified. A disconnected client must recover a missing
form from the asset/form state rather than assume it received the event. The
clip's file size is not recorded as verified until successful completion.

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
checks the URL and cancellation fence when the request starts and rechecks the
account, asset, session state, session expiry, and cancellation fence under
locks before publishing the part. Signing after a committed cancellation
returns 410; a signed PUT rejected at request start returns a generic 403, and
an in-flight PUT fenced before publication returns 410.

`PUT` the raw bytes to that URL with `Content-Type: application/octet-stream`
and an exact `Content-Length`. The signed URL is the authorization for the
PUT; a JWT is not required on that request. Chunked transfer encoding is
rejected (411). Other incorrect lengths are rejected (400 or 413), and an
incorrect content type is rejected (415).

Parts are numbered from 1 through `partCount`. Every part except the last is
exactly 50 MiB; the last contains the remaining bytes. Parts may arrive out of
order. A successful response contains `part` with `partNumber`, `sizeBytes`
(decimal string), and `sha256`. Retrying an identical completed part is
idempotent while uploads remain permitted. Concurrent writes to the same part,
or retrying it with different bytes, return 409; abort and start a fresh session
if a stored part is wrong.
Interrupted streams do not publish partial parts.

For experimental iOS background uploads, use file-backed tasks and a trusted,
isolated HTTPS origin whose full proxy path has been verified not to redirect.
Background sessions follow redirects automatically and iOS may delay a queued
task until its five-minute URL expires. Reattach and reconcile both live tasks
and authenticated server state before signing another request; do not cancel
an already-started transfer solely because its URL has since expired. iOS may
make system-managed copies of upload files, and force-quitting the app cancels
outstanding background tasks until the user reopens it.

### 3. Resume, complete, or abort

- `GET /api/upload-sessions/:sessionId` returns the session and its recorded
  parts for the owner. Use the `OPEN` parts list to decide which parts to send.
- `POST /api/upload-sessions/:sessionId/complete` verifies consecutive parts,
  total byte count, and whole-file SHA-256 before attaching the private original
  to the clip. A successful retry returns the same completed session. Missing
  parts or an in-progress operation return 409; integrity mismatch returns 422.
  A cancelled intent prevents a new `OPEN` to `COMPLETING` transition (410),
  but does not stop or undo an earlier transition.
- `DELETE /api/upload-sessions/:sessionId` aborts an unfinished session.
  A successful HTTP 200 returns `{"uploadSession":{"id":"...","status":"ABORTED"}}`;
  an already expired session reports `EXPIRED`. Retrying is safe. If cleanup is
  busy, retry until it succeeds. A completed original cannot be aborted (409).

Invalid, expired, suspended-account, moderated-asset, or already-cancelled
signed PUTs return 403 at request start.
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
one-hour orphan job deliberately skips assets with any original session.
The separately opt-in tracked-session worker is described above.

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

An asset reserved for originals, or one that has ever had an original session,
cannot use the legacy Mux-upload route, even after abort. To fall back to Mux,
create a new asset. Pausing or
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

Hard-deleting the owner retains each ingest operation ID and its previously
linked Mux asset ID, but no account or local asset identifiers, in
`mux_retired_ingest_attempts`. A signed webhook for that operation records its
Mux asset ID in `mux_retired_ingest_events`, logs an error, and returns 503.
Repeated deliveries of the same reference are deduplicated. Super Admins can
inspect these references in the dashboard or through the paginated
`GET /api/admin/retired-mux-events` endpoint. Operators must investigate the
operation and Mux asset IDs with Mux; the records are not automatically cleared
and do not remove remote media. Unknown operations still return 503 without
creating records.

These minimal identifiers are retained without an automatic expiry until a
safe retention policy is established. They cannot recover correlations for
accounts deleted before every server handling deletion was upgraded.
Post-deletion cleanup and proactive alerting remain rollout blockers, and absence
confirmation must not be treated as proof that a remote request is finished.

Each new local original key is bound to the `.dvu-storage-id` marker in its
storage root. A missing or different marker prevents cleanup from being
reported as successful. Legacy keys without that identity require manual
recovery before deletion can be confirmed. Preserve the marker with an
intentional restore, but verify the actual mounted volume and backups
operationally: the marker cannot distinguish a copied clone carrying the same
identity. Never remove the marker to reset a root containing originals.
