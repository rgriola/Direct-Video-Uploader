# Agent Guide — Direct Video Uploader

> Auto-loaded by GitHub Copilot. Keep concise — every line here costs context on every prompt.

---

## Server Startup

- Check if port 3000 is in use before starting dev server.
- Test API endpoints with `curl`.
- Keep `PROJECT_SPEC.md`, `PROJECT_STATUS.md`, and this file up to date.
- run npm run dev from the root.

---

## Prisma 7 — Key Gotchas

1. **Database URL** must be in `prisma.config.ts`, NOT in the `schema.prisma` datasource block.
2. **Driver adapter** is required — we use `@prisma/adapter-pg` with the `pg` library.
3. **Constructor** uses `new PrismaClient({ adapter })` — no `datasourceUrl` in constructor.
4. **Local dev database**: run `npx prisma dev` (auto-manages a local PostgreSQL instance).

---

## Naming Conventions — Prisma ↔ PostgreSQL

**Critical rule**: In raw SQL, use **PostgreSQL snake_case** column/table names, NOT Prisma camelCase. See `server/prisma/schema.prisma` for all `@map()` / `@@map()` annotations.

```javascript
// ✅ Prisma ORM — camelCase
const users = await prisma.user.findMany({
  where: { phoneNumber: "5055034455" },
});

// ✅ Raw SQL — snake_case tables & columns
const result = await prisma.$queryRawUnsafe(
  `SELECT COUNT(*)::int FROM users WHERE status = 'ACTIVE'`,
);

// ❌ WRONG — Prisma model names in raw SQL (will fail)
// SELECT COUNT(*) FROM "User"
```

---

## Codebase Conventions

- **ES Modules only** — use `import`/`export`, never `require()`.
- **Fastify plugin pattern** — routes export `async function(fastify)`, registered via `fastify.register()`.
- **Auth guard** — protected routes use `preHandler: [fastify.authenticate]`.
- **BigInt serialization** — call `fileSize?.toString()` before including in JSON responses.
- **Socket.IO push** — look up `fastify.userSockets?.get(userId)` to push events to connected clients.
- **WS auth** — JWT token from `socket.handshake.auth?.token`, same secret as HTTP routes.
- **Chat persistence** — both `OUTGOING` and `INCOMING` messages stored via `prisma.chatMessage.createMany()`.
- **DB pool** — `pg.Pool` with `max: 20` connections. Pool was 5, caused timeouts on concurrent requests.
- **Server auto-reply** — `message:send` handler replies to plain text with "send me your videos!"; Slack commands (e.g., `#team-alerts @carrie`) trigger `slack:post`.

---

## iOS App — Key Gotchas

1. **Simulator networking** — use `127.0.0.1`, NOT `localhost`. Simulator resolves `localhost` to IPv6 `::1`, but Node server binds IPv4 only.
2. **Physical device** — uses Mac's LAN IP. `ServerConfig.swift` uses `#if targetEnvironment(simulator)` to auto-switch.
3. **WebSocket** — native `URLSessionWebSocketTask` with manual Socket.IO protocol framing (no third-party library).
4. **`@Observable` macro** — class must be `@MainActor @Observable final class`. Don't use `nonisolated(unsafe)` on stored properties — the macro conflicts with it.
5. **Codable models** — server may return fewer fields than the model defines. Use optionals (`String?`, `Int?`) for fields that aren't always present (e.g., `User.status`, `Asset.clipCount`). Non-optional fields cause silent `JSONDecoder` failures.
6. **XcodeGen** — run `xcodegen generate` after adding new `.swift` files. The `project.yml` sources the entire `DirectVideoUploader/` directory.
7. **Build with Xcode CLI** — `xcodebuild -project DirectVideoUploader.xcodeproj -scheme DirectVideoUploader -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
8. **PhotosPicker** — SwiftUI-native `PhotosPicker` with `.videos` filter and `Transferable` protocol. Reset `selectedPhotoItem` to `nil` after processing.
9. **Video uploads** — `VideoUploadService` streams multipart body to temp file (1MB chunks) to avoid memory pressure. Uses delegate-based `URLSession.uploadTask` for progress.

---

## API Naming

- Routes: `/api/kebab-case` (e.g., `/api/admin/simulate-upload`)
- JSON response keys: `camelCase` (e.g., `mediasourceId`, `clipCount`)

---

## Deployment

- **Vercel** → Web UI / Clip Viewer
- **Render** → Server + PostgreSQL + WebSocket

---

## Demo Credentials

| User          | Phone        | PIN    |
| ------------- | ------------ | ------ |
| David Burgess | `5055034455` | `1234` |
| Carrie Smith  | `5055551234` | `1234` |
| Admin User    | `8001234567` | `0000` |

---

## Key References

- `PROJECT_SPEC.md` — Full architecture, data model, endpoint catalog
- `PROJECT_STATUS.md` — Current progress, milestones, verified features
- `server/prisma/schema.prisma` — Source of truth for all Prisma ↔ PostgreSQL field mappings
