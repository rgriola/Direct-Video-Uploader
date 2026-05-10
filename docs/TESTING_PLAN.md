# Direct Video Uploader — Testing Plan

> **Date:** March 4, 2026
> **Focus:** Dashboard speed · Server I/O · Reliability at 1,000 concurrent users
> **Constraint:** No code changes unless they directly improve production performance
> **Context:** This is a proof-of-concept project. Testing targets production readiness for a company tool.

---

## Q&A — Scope Decisions

| #   | Question                                                                                   | Answer                                                                                                                                                                                                                                                                                                                            |
| --- | ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Start from Phase 1 (unit tests) and build up, or start from Phase 3 (scale) and work back? | **Start at scale (Phase 3 in original plan → now Phase 1). Work backward.** Rationale: this is a POC — we need to know what breaks at 1,000 users first, then write targeted tests for the weak points we discover. Building a full unit test suite for code that might need to be rewritten after load testing is wasted effort. |
| 2   | Is the 1,000 target WebSocket-only, or combined across all clients?                        | **Combined: Dashboard admin + Server API + iOS app.** Realistic distribution: ~800 iOS app connections, ~150 admin dashboard sessions, ~50 API-only callers. Even at half this capacity (500), the single-process architecture and 20-connection DB pool need validation.                                                         |
| 3   | Include iOS app in testing plans?                                                          | **Yes.** XCTest integration tests for login, WebSocket, upload, and reconnection flows. iOS is the primary user-facing surface.                                                                                                                                                                                                   |

---

## Current State

| Area                    | Status                                                                 |
| ----------------------- | ---------------------------------------------------------------------- |
| **Test infrastructure** | ❌ None — no test runner, no test files, no test scripts               |
| **DB pool**             | `max: 20` connections, 10s idle/connection timeouts                    |
| **Dashboard polling**   | 10–15s intervals (stats/users/assets/triad)                            |
| **WebSocket**           | Socket.IO with `websocket` + `polling` transports                      |
| **Upload pipeline**     | 3 sequential DB calls per upload (was 6)                               |
| **DB indexes**          | FK indexes on `assets.userId`, `clips.assetId`, `chat_messages.userId` |
| **Security audit**      | 20/25 items fixed; rate limiting + CORS deferred                       |

---

## Execution Philosophy: Scale First, Fix What Breaks

**Why this order:** We don't know what's going to break. Running the full load test first gives us a hit list of real problems. Then we benchmark and fix those specific bottlenecks (Phase 2), harden recovery (Phase 3), and write unit tests that lock in the fixes (Phase 4). This avoids writing tests for code that changes after load testing.

---

## Phase 1: Scale Testing — 1,000 Combined Users

### 1A. WebSocket Connection Load Test

**Tool:** Artillery with Socket.IO engine

```
Test Profile:
  - Ramp: 0 → 1,000 connections over 120 seconds
  - Distribution: 800 iOS (clientType: 'ios'), 150 admin, 50 API-only
  - Hold: maintain 1,000 connections for 5 minutes
  - 10% of iOS clients send a text message every 30s
  - All admin clients poll 4 endpoints every 15s (simulating dashboard)
```

| Metric                       | Target          | What Breaks                                                  |
| ---------------------------- | --------------- | ------------------------------------------------------------ |
| **Connection success rate**  | > 99%           | Socket.IO handshake timeout, JWT verification bottleneck     |
| **Server memory (RSS)**      | < 512MB         | `userSockets`, `iosSockets`, `adminSockets` Map/Set overhead |
| **Server CPU**               | < 70% sustained | JWT verify per connection, broadcast fan-out                 |
| **Message latency (p95)**    | < 200ms         | Event loop blocking under concurrent DB queries              |
| **Disconnect rate (steady)** | < 1%/min        | `pingTimeout: 25s` / `pingInterval: 20s` may be too tight    |

### 1B. Concurrent Upload Stress Test

**Tool:** Custom Node.js script with `form-data` + `fetch`

```
Test Profile:
  - 50 simultaneous uploads (10MB test video each)
  - While 1,000 WS clients are connected (combined load)
  - Measure: time to first byte, total time, DB write time
```

| Metric                | Target                      | What Breaks                                                  |
| --------------------- | --------------------------- | ------------------------------------------------------------ |
| **Upload success**    | 100%                        | DB pool exhaustion (20 pool vs 50 uploads + 150 admin polls) |
| **Upload throughput** | All complete < 30s          | Stream pipeline backpressure, disk I/O                       |
| **DB pool wait**      | < 1s                        | `connectionTimeoutMillis: 10000` masks slow drain            |
| **Asset integrity**   | All clips created correctly | Transaction isolation under concurrent writes                |

### 1C. Dashboard Under Combined Load

**Tool:** Agent browser automation

| Metric              | Target         | What Breaks                                                     |
| ------------------- | -------------- | --------------------------------------------------------------- |
| **Dashboard loads** | < 3s           | Server too busy serving API to respond to static file + polling |
| **Stats accuracy**  | Match DB truth | Race conditions in concurrent COUNT queries                     |
| **Poll stability**  | No gaps > 30s  | Admin WS dropped during load spike                              |

### 1D. iOS App Under Server Load

**Tool:** Xcode + physical device or Simulator against loaded local server

| Metric                    | Target                    | What Breaks                           |
| ------------------------- | ------------------------- | ------------------------------------- |
| **Login success**         | 100%                      | JWT sign latency under load           |
| **Upload completes**      | 100%                      | Multipart stream to server under load |
| **WS messages delivered** | All within 2s             | Server event broadcast fan-out delay  |
| **Reconnection**          | Auto-reconnect within 10s | Backoff timer + server capacity       |

---

## Phase 2: Performance Benchmarking

Run after Phase 1 to quantify the bottlenecks discovered.

### 2A. API Response Time Benchmarks

**Tool:** autocannon (Fastify-recommended)

| Endpoint                 | Method | Concurrency | Target p95 |
| ------------------------ | ------ | ----------- | ---------- |
| `/api/health`            | GET    | 100         | < 5ms      |
| `/api/admin/status`      | GET    | 50          | < 50ms     |
| `/api/admin/stats`       | GET    | 50          | < 100ms    |
| `/api/admin/users`       | GET    | 50          | < 100ms    |
| `/api/admin/assets`      | GET    | 50          | < 200ms    |
| `/api/assets/:id/upload` | POST   | 10          | < 2s       |
| `/api/auth/login`        | POST   | 50          | < 50ms     |

### 2B. Database Query Analysis

**Tool:** Prisma query logging + `EXPLAIN ANALYZE`

| Analysis             | What to Look For                                                    |
| -------------------- | ------------------------------------------------------------------- |
| **Slow queries**     | Any > 100ms? Missing indexes, full table scans                      |
| **N+1 detection**    | `admin/assets` is the main risk (4-table joins)                     |
| **Index usage**      | Verify index scans, not seq scans on FK columns                     |
| **Pool utilization** | `pool.totalCount`, `pool.idleCount`, `pool.waitingCount` under load |

### 2C. Dashboard Render Profiling

**Tool:** Lighthouse + React DevTools Profiler

| Test                                     | Target                                   |
| ---------------------------------------- | ---------------------------------------- |
| **LCP**                                  | < 2s                                     |
| **TBT**                                  | < 200ms                                  |
| **Bundle size**                          | JS < 400KB, CSS < 25KB                   |
| **Re-render scope on `upload:complete`** | Only `StatsGrid` + `AssetList` re-render |

---

## Phase 3: Reliability & Recovery

### 3A. Server Reconnection

| Test               | Action                   | Expected                                           |
| ------------------ | ------------------------ | -------------------------------------------------- |
| **Server restart** | Kill + restart server    | All WS clients reconnect; dashboard recovers < 30s |
| **DB restart**     | Stop/start Prisma dev DB | Pool errors absorbed; server resumes               |
| **Network blip**   | Throttle connection      | Reconnect with backoff                             |

### 3B. iOS App Reconnection

| Test                   | Action                      | Expected                               |
| ---------------------- | --------------------------- | -------------------------------------- |
| **App background**     | Minimize 2 min              | Reconnects on foreground + greeting    |
| **Server unreachable** | Stop server while connected | Backoff (3s → 60s cap, max 10 retries) |
| **Token expiry**       | Expired JWT                 | 401 → redirect to login                |

### 3C. Failure Injection

| Test                   | Injection                        | Expected                       |
| ---------------------- | -------------------------------- | ------------------------------ |
| **DB pool exhaustion** | `max: 2`, 10 concurrent requests | Queue/timeout gracefully (503) |
| **Disk full**          | Fill `/uploads`                  | Clear error, no crash          |
| **Malformed upload**   | Non-video multipart              | Rejected, no file persisted    |
| **Huge payload**       | 600MB (exceeds 500MB limit)      | Rejected by multipart, no OOM  |
| **Invalid JWT**        | Tampered token                   | 401 everywhere                 |

### 3D. Memory & Leak Detection

**Tool:** `node --inspect` + Chrome DevTools, or `clinic.js`

| Test            | Duration                        | Watch For                        |
| --------------- | ------------------------------- | -------------------------------- |
| **Idle leak**   | 1 hour                          | RSS growth < 10MB                |
| **WS churn**    | 1,000 connect/disconnect cycles | All maps empty after             |
| **Upload leak** | 100 sequential uploads          | Temp files cleaned; RSS baseline |

---

## Phase 4: Foundation Tests (Informed by Phases 1–3)

### 4A. Server Unit Tests (Vitest)

| Test File         | Covers                                                          |
| ----------------- | --------------------------------------------------------------- |
| `utils.test.js`   | `generateSlug`, `generateMediasourceId`, `dbRetry`, PIN hashing |
| `prisma.test.js`  | Pool config, warmup query, error handlers                       |
| `handler.test.js` | `getGreeting()` by time-of-day                                  |

### 4B. API Integration Tests

| Suite      | Key Assertions                                   |
| ---------- | ------------------------------------------------ |
| **Auth**   | Valid PIN → JWT; invalid → 401; expired → 401    |
| **Assets** | Create → upload → clip → form → confirmation     |
| **Admin**  | Stats accurate; cleanup stale only; JWT required |
| **Clips**  | HTML returned; XSS-escaped; 404 for missing      |

### 4C. WebSocket Integration Tests

| Test                   | Assertions                           |
| ---------------------- | ------------------------------------ |
| **Auth handshake**     | Valid JWT accepted; invalid rejected |
| **Client tracking**    | `iosSockets`/`adminSockets` correct  |
| **Greeting**           | iOS receives once; no duplicate      |
| **Disconnect cleanup** | Maps/Sets cleared on last socket     |

### 4D. iOS Tests (XCTest)

| Suite                           | Covers                                 | Priority |
| ------------------------------- | -------------------------------------- | -------- |
| **AuthServiceTests**            | Login, JWT storage, token refresh      | High     |
| **WebSocketServiceTests**       | Connect/disconnect, backoff, ping/pong | High     |
| **VideoUploadServiceTests**     | Multipart, progress, temp cleanup      | High     |
| **VideoMetadataExtractorTests** | AVAsset extraction                     | Medium   |
| **ChatViewModelTests**          | Message flow, greeting, upload states  | Medium   |
| **ServerConfigTests**           | Simulator vs device URL switching      | Low      |

---

## Suggested Improvements

### Quick Wins

| #   | Suggestion                                      | Impact                             |
| --- | ----------------------------------------------- | ---------------------------------- |
| 1   | **DB pool `max: 20` → `max: 50`**               | Prevents pool exhaustion           |
| 2   | **Cache `/api/admin/stats` for 5s**             | Eliminates redundant COUNT queries |
| 3   | **Server: `transports: ['websocket']` only**    | Eliminates polling overhead        |
| 4   | **Rate limit `/api/auth/login`** (deferred #22) | Prevents brute-force               |
| 5   | **CORS origin whitelist** (deferred #24)        | Blocks unauthorized frontends      |

### Scaling Concerns at 1,000 Users

| Concern                              | Recommendation                           |
| ------------------------------------ | ---------------------------------------- |
| **Single-process Node.js**           | `cluster` module or PM2                  |
| **In-memory socket maps**            | `@socket.io/redis-adapter` if clustering |
| **No upload queue**                  | BullMQ for upload processing             |
| **Prisma 7 + pg adapter overhead**   | Raw queries for hot paths                |
| **15s admin polling × 150 sessions** | Push via WS events instead               |

---

## Tooling Requirements

| Tool                 | Purpose                   | Install                             |
| -------------------- | ------------------------- | ----------------------------------- |
| **Vitest**           | Unit + integration tests  | `npm i -D vitest` in `server/`      |
| **autocannon**       | HTTP benchmarks           | `npm i -D autocannon` in `server/`  |
| **Artillery**        | WS load testing           | `npm i -g artillery`                |
| **socket.io-client** | WS integration tests      | Add to `server/` devDeps            |
| **Playwright**       | Dashboard browser testing | `npm i -D @playwright/test` at root |
| **clinic.js**        | Node.js diagnostics       | `npm i -g clinic`                   |
| **XCTest**           | iOS tests                 | Built into Xcode                    |

---

## Execution Order & Estimates

| Order | Phase                          | Est. Time | What It Tells Us                    |
| ----- | ------------------------------ | --------- | ----------------------------------- |
| 1     | **1A** — 1,000 WS load test    | 3h        | Do we crash? Where's the ceiling?   |
| 2     | **1B** — Concurrent uploads    | 2h        | DB pool + file I/O under load       |
| 3     | **1C** — Dashboard under load  | 1h        | Can admins work while users upload? |
| 4     | **1D** — iOS under server load | 2h        | Real-device behavior under stress   |
| 5     | **2A** — API benchmarks        | 2h        | Which endpoints are slow?           |
| 6     | **2B** — DB query analysis     | 2h        | Missing indexes? N+1?               |
| 7     | **2C** — Dashboard profiling   | 1h        | Frontend bottlenecks                |
| 8     | **3A/3B** — Reconnection       | 2h        | Recovery behavior                   |
| 9     | **3C** — Failure injection     | 2h        | Edge case handling                  |
| 10    | **3D** — Memory/leaks          | 2h        | Long-running stability              |
| 11    | **4A–C** — Server tests        | 5h        | Lock in fixes                       |
| 12    | **4D** — iOS XCTest            | 4h        | iOS regression protection           |

**Total estimated:** ~28 hours

---

## Success Criteria

| Criteria                                | Threshold                  |
| --------------------------------------- | -------------------------- |
| 1,000 concurrent WS connections (5 min) | > 99% success              |
| 50 concurrent uploads under full load   | 100% success               |
| Dashboard operational under load        | Loads < 3s, stats accurate |
| iOS upload under server load            | 100% success               |
| API p95 response times                  | Meet Phase 2 targets       |
| No memory leaks (1 hour)                | RSS growth < 10MB          |
| Server recovery from DB restart         | < 30 seconds               |
| Zero data corruption                    | 100% asset integrity       |
| All Phase 4 tests pass                  | 100%                       |
