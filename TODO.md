# TODO — Direct Video Uploader

> Full project audit — March 3, 2026
> **20 of 25 issues fixed. 5 deferred to deployment prep.**

---

## Critical — ALL FIXED

| #     | Issue                                                                   | Status |
| ----- | ----------------------------------------------------------------------- | ------ |
| **1** | fileSize type mismatch — Changed Clip.fileSize from Int64? to String?   | DONE   |
| **2** | Infinite WS reconnect loop — Added exponential backoff (max 10 retries) | DONE   |
| **3** | URLSession leak on reconnect — Added invalidateAndCancel()              | DONE   |
| **4** | No auth on admin routes — Added preHandler to all 7 routes              | DONE   |
| **5** | XSS in clip viewer — Added escapeHtml() helper                          | DONE   |
| **6** | Hardcoded JWT secret — Now generates crypto.randomBytes(64)             | DONE   |

---

## Dashboard & Performance

| #      | Issue                                                                        | Status   |
| ------ | ---------------------------------------------------------------------------- | -------- |
| **7**  | Dashboard over-invalidation — Selective query invalidation by event type     | DONE     |
| **8**  | 5s triad polling — Changed to 15s                                            | DONE     |
| **9**  | 6 sequential DB calls in upload — Merged to 3 calls                          | DONE     |
| **10** | N+1 queries in clip viewer — Mitigated by new indexes                        | DEFERRED |
| **11** | Missing DB indexes — Added 3 indexes on FK columns                           | DONE     |
| **12** | Broken mediasource ID sequence — Simplified to CREATE SEQUENCE IF NOT EXISTS | DONE     |

---

## Server ↔ iOS Inconsistencies — ALL FIXED

| #      | Issue                                                                | Status |
| ------ | -------------------------------------------------------------------- | ------ |
| **13** | greeting dead code — Removed onGreeting callback and handler         | DONE   |
| **14** | form:submit dead code — Removed sendFormSubmit() method and call     | DONE   |
| **15** | slack:post event loop — Removed all Slack handlers (Phase 3)         | DONE   |
| **16** | Unsafe JSON in WS sends — sendVideoUpload now uses JSONSerialization | DONE   |
| **17** | pingTimeout less than pingInterval — Swapped to 25000/20000          | DONE   |

---

## Lower Priority

| #      | Issue                                       | Status   |
| ------ | ------------------------------------------- | -------- |
| **18** | Temp video files never deleted after upload | DONE     |
| **19** | VideoUploadService URLSession leak          | DEFERRED |
| **20** | Upload progress 100ms polling               | DEFERRED |
| **21** | pool.on error silently swallows errors      | DONE     |
| **22** | No rate limiting on login                   | DEFERRED |
| **23** | GET /api/assets/:id no auth                 | DONE     |
| **24** | CORS origin: true in production             | DEFERRED |
| **25** | Admin ChatHistory shows only own messages   | DEFERRED |
