# Experimental Upload Session API

This server-only API stores a native original without sending it to Mux. It is
**disabled by default**. Existing clients continue using direct-to-Mux uploads.
Do not enable it on the home server or in production yet: free-space checks,
capacity limits across sessions, backups, an automatic expiry/orphan sweep,
original reads, Mux ingest, and client integration are not ready. The dev and
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
the repository. The server refuses to start with an invalid flag, a missing or
short signing secret, or the JWT secret reused as the upload signing secret.
Production also requires an explicit absolute storage root.

Treat each signed URL as a bearer credential. Use HTTPS, do not share or log
it, and ensure the reverse proxy and tunnel also suppress query strings.
Fastify omits query strings from request and 404 logs; that does not configure
logging at proxies or other infrastructure. Signed-URL responses use
`Cache-Control: no-store`. Rotating the signing secret invalidates outstanding
URLs; an active owner can request new ones.

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
expires after 24 hours. Private storage keys are not returned.

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
open. A missing or mismatched storage location, or a missing completed file,
is reported as 503 instead of claiming the original is available.

Completion does **not** make a playable video: Mux ingest and ready
notifications are not implemented, and the asset and clip remain `UPLOADING`.
The existing one-hour orphan job deliberately skips assets with any original
session. There is no automatic sweep for abandoned sessions yet.

## Moderation and storage safety

An asset that has ever had an original session cannot use the legacy Mux-upload
route, even after abort. To fall back to Mux, create a new asset. Pausing or
flagging stops new part publication; an owner can still inspect a paused
session, but flagged or removed sessions return 404. Permanent removal deletes
the session parts and any completed original before reporting reconciliation as
`SYNCED`; a busy operation or cleanup failure leaves it pending or in error.
Keep the configured storage root available even if the feature flag is later
disabled, so removal and recovery can finish.

Each new local original key is bound to the `.dvu-storage-id` marker in its
storage root. A missing or different marker prevents cleanup from being
reported as successful. Legacy keys without that identity require manual
recovery before deletion can be confirmed. Preserve the marker with an
intentional restore, but verify the actual mounted volume and backups
operationally: the marker cannot distinguish a copied clone carrying the same
identity. Never remove the marker to reset a root containing originals.
