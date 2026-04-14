# Fixer ↔ Mediasource Integration Requirements

What Fixer needs from the organization to integrate with Mediasource.

---

## Infrastructure Access

- **Sandbox/staging environment** — Need a dev environment to test with dummy data.
- **Service account credentials** — A dedicated API identity for Fixer (not tied to a human user).
  Determines auth flow: OAuth2 client credentials, API key, or JWT.

- **Internal hosting** — Need to know: what internal hosting is available (AWS internal account, on-prem Kubernetes, etc.), and what the deployment/CI pipeline looks like. For production, the entire backend (API server, PostgreSQL, WebSocket) must migrate to an internal WBD-managed environment.

---

## Video Ingest Protocol

- **How does video physically arrive?** — Presigned S3 (Amazon) URLs? 
Direct HTTP PUT to a CDN? 
Chunked upload? This is the most critical unknown — it determines whether the current Mux upload path can be swapped or needs a complete rewrite.
- **Size limits & transcoding** — Are there Max file size, accepted codecs/containers, and whether Mediasource transcodes or expects a specific format.
- **Upload status callbacks** — Webhooks, polling endpoint, or event stream? The current Mux webhook flow needs a Mediasource equivalent.

---

## Asset Lifecycle

- **ID generation** — When is the Mediasource ID created? On upload initiation, after processing, or after editorial approval? This changes the entire confirmation flow. (With Direct Web app ingest User Creates a Number (context form) > Upload can be processed) For NewsCloud - There is a Minor Form you fill out then ingest begins.
- **State machine** — What states does an asset pass through (ingesting → processing → ready → published)? Need to map these to Fixer's current PROCESSING/READY/ERROR states.
- **Metadata write window** — Can metadata be attached at upload time, or must it be PATCHed after the asset exists? Are there required fields that block ingest?

---

## Auth & Permissions

- **User identity mapping** — How do Fixer users map to Mediasource users? WBD SSO (Okta/Azure AD)? Current phone+PIN auth is a placeholder — need the real identity provider details and whether it supports mobile OAuth flows (PKCE).
- **Permission model** — Can any authenticated user upload, or do they need a specific Mediasource role? Can Fixer create assets on behalf of a user?

---

## Enterprise Requirements

- **Security review** — Enterprise apps typically require an AppSec review before touching internal APIs. Ask early — this can take weeks.
- **MDM distribution** — Will Fixer be distributed via Apple Business Manager / MDM instead of the App Store? This affects signing, provisioning, and update flow.
- **Slack bot approval** — If the WBD Slack workspace is managed, the "fixer-video" bot needs IT/admin approval to post to channels. -- How does this worK?
- **Data classification** — Is video content considered sensitive/restricted? Determines encryption-at-rest and transit requirements for the internal hosting environment.

---

## Ongoing Operations

- **Dev environment parity** — A way to keep testing when Mediasource updates their API (versioned API? changelog?).
- **Error budget / SLA** — What uptime is expected? Who gets paged if uploads break at 2am?
- **Logging & audit trail** — Enterprise systems often require audit logs of who uploaded what and when.

---

## Priority Summary

| Priority | What's Needed                                          | Why                    |
| -------- | ------------------------------------------------------ | ---------------------- |
| **P0**   | API docs + sandbox environment + video ingest protocol | Can't build without it |

               Dev environment

| **P1** | SSO/auth integration details + security review kickoff | Blockers with long lead times |
Replace Ph# + Pin - Managed Phone Security

| **P1.5** | Internal hosting environment + CI/CD pipeline | Render is demo-only; production must be internal |

               Builds and tests the Node.js server and iOS app.
               Deploys the server to the internal WBD environment (not Render).
               Runs database migrations (PostgreSQL).
               Optionally, distributes the iOS app via MDM or TestFlight.

| **P2** | MDM distribution + Slack bot approval | Needed before rollout, not before dev |

> **Single biggest risk:** The video ingest protocol — if Mediasource uses something proprietary or requires internal network access, the architecture changes significantly.
