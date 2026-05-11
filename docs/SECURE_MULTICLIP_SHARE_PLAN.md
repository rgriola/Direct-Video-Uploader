May 11, 2026 - 3:46pm - GitHub Copilot (GPT-5.3-Codex)

# Secure Multi-Clip Share Links - Parked Plan

## Status

- Parked for later implementation.
- This plan is intentionally scoped to avoid overlap with active in-flight work.

## Objective

Deliver one secure shareable URL that grants controlled access to multiple clips, with optional download support, expiration, and revoke controls.

## V1 Scope

- Create one share link for multiple selected clips.
- Public entry URL with token-based access.
- Expiration policy (default 72 hours).
- Owner/admin revoke.
- Optional passcode gate.
- Optional download toggle (`allowDownload`).
- Access logging (open and download events).

## Out of Scope (V1)

- Full invite/recipient management.
- Granular per-recipient ACLs.
- Advanced watermarking or DRM.
- Long-term retention policies.

## User Flow

1. User selects multiple clips from archive.
2. Client calls server to create a share collection.
3. Server returns one secure URL (`/s/:token`).
4. User sends link through iMessage/SMS/email.
5. Recipient opens link and unlocks if passcode is required.
6. Recipient views list of clips and can play or download based on share settings.
7. Owner/admin can revoke the link at any time.

## Data Model (Proposed)

### `share_collections`

- `id` (uuid)
- `tokenHash` (string, indexed)
- `createdByUserId` (fk users)
- `organizationId` (fk organizations)
- `expiresAt` (datetime)
- `allowDownload` (boolean)
- `requirePasscode` (boolean)
- `passcodeHash` (nullable string)
- `maxViews` (nullable int)
- `viewCount` (int default 0)
- `revokedAt` (nullable datetime)
- `createdAt`, `updatedAt`

### `share_collection_items`

- `id` (uuid)
- `shareCollectionId` (fk)
- `clipId` (fk clips)
- `sortOrder` (int)
- `createdAt`

### `share_access_logs`

- `id` (uuid)
- `shareCollectionId` (fk)
- `clipId` (nullable fk)
- `action` (`OPEN`, `UNLOCK_SUCCESS`, `UNLOCK_FAIL`, `DOWNLOAD`)
- `ipHash` (string)
- `userAgent` (string)
- `createdAt`

## API Surface (Proposed)

### Authenticated API

- `POST /api/shares`
  - input: clipIds, expiresInHours, allowDownload, requirePasscode, passcode, maxViews
  - output: shareId, shareUrl, expiresAt
- `GET /api/shares/:id`
  - owner/admin metadata view
- `POST /api/shares/:id/revoke`
  - immediate revoke

### Public Share API

- `GET /s/:token`
  - renders share page shell
- `POST /s/:token/unlock`
  - passcode validation when required
- `GET /s/:token/manifest`
  - returns clip list + display metadata for active share
- `GET /s/:token/download/:clipId`
  - returns short-lived signed download URL or streamed attachment

## Security Requirements

- Store token hash only (raw token never persisted).
- Constant-time token comparison.
- Rate-limit unlock and download endpoints.
- Enforce expiry/revoke/maxViews on every request.
- Hash passcodes with bcrypt.
- Record audit logs for access attempts and downloads.

## Download Strategy

### V1

- Generate short-lived signed download URL per request (5-15 minute TTL).
- Deny direct file access without share validation.

### Later

- Integrate object storage signed URLs (R2/B2) consistently across all clip download paths.

## iOS Integration Points

- Archive multi-select action to create share.
- Native share sheet to distribute returned URL.
- Optional management view to show active/revoked/expired shares.

## Testing Plan

1. Create share with valid clip set.
2. Reject share creation for clips outside caller ownership/org policy.
3. Token open success path.
4. Expired token blocked.
5. Revoked token blocked.
6. Passcode required and unlock success/failure.
7. Download allowed only when `allowDownload=true` and clip is part of collection.
8. Max views enforced when configured.
9. Access logs persisted for open/unlock/download events.

## Rollout Plan

1. Internal admin-only creation.
2. Pilot with a single org.
3. Full rollout with monitoring on error rates and abuse signals.

## Effort Estimate

- Minimal V1: 3-4 dev days.
- Hardened V1 with stronger test coverage and polish: 5-6 dev days.

## Acceptance Criteria

- One URL can securely expose multiple clips.
- Link can expire and can be revoked immediately.
- Optional passcode works end-to-end.
- Download is gated and short-lived.
- Logs provide traceability of access behavior.
