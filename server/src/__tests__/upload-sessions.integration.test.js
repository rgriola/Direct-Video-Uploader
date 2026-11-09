import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { acquireIntegrationDatabaseLock } from "./helpers/database-lock.js";
import { createLocalStorageDriver } from "../lib/storage/local-driver.js";
import { createUploadSessionService, UploadSessionError } from "../lib/upload-sessions.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
if (process.env.CI && !databaseUrl) {
  throw new Error("TEST_DATABASE_URL is required for upload session integration tests in CI");
}
if (databaseUrl) {
  const url = new URL(databaseUrl);
  if (!["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)
    || !url.pathname.slice(1).startsWith("dvu_scope_test_")
    || process.env.DATABASE_URL !== databaseUrl) {
    throw new Error("Upload session tests require a dedicated local dvu_scope_test_ database");
  }
}

const integration = databaseUrl ? describe : describe.skip;

integration("upload sessions against PostgreSQL and local storage", () => {
  let prisma;
  let releaseDatabaseLock;
  let ownerId;
  let assetId;
  let clipId;
  let storageRoot;
  let storage;
  let service;
  let currentTime;

  beforeAll(async () => {
    const database = await import("../lib/prisma.js");
    prisma = database.default;
    releaseDatabaseLock = await acquireIntegrationDatabaseLock(database.pool);
    ownerId = randomUUID();
    await prisma.user.create({
      data: {
        id: ownerId,
        name: "Upload Session Test",
        phoneNumber: `+1555${String(Math.floor(Math.random() * 10_000_000)).padStart(7, "0")}`,
        pinHash: "integration-test",
      },
    });
  });

  beforeEach(async () => {
    assetId = randomUUID();
    clipId = randomUUID();
    currentTime = new Date("2026-11-09T12:00:00.000Z");
    await prisma.asset.create({
      data: {
        id: assetId,
        userId: ownerId,
        status: "UPLOADING",
        moderation: "ACTIVE",
        clips: {
          create: {
            id: clipId,
            status: "UPLOADING",
          },
        },
      },
    });
    storageRoot = await mkdtemp(path.join(os.tmpdir(), "dvu-upload-session-"));
    storage = createLocalStorageDriver({ root: storageRoot });
    service = createUploadSessionService({
      db: prisma,
      storage,
      now: () => new Date(currentTime),
    });
  });

  afterEach(async () => {
    await prisma.asset.deleteMany({ where: { id: assetId } });
    if (storageRoot) await rm(storageRoot, { recursive: true, force: true });
  });

  afterAll(async () => {
    if (!prisma) return;
    try {
      await prisma.asset.deleteMany({ where: { userId: ownerId } });
      await prisma.user.deleteMany({ where: { id: ownerId } });
    } finally {
      await releaseDatabaseLock?.();
      await prisma.$disconnect();
    }
  });

  it("persists created sessions and synchronizes completed part metadata when resumed", async () => {
    const expectedSha256 = createHash("sha256").update("part one").digest("hex");
    const created = await service.create({
      ownerId,
      assetId,
      clipId,
      expectedSizeBytes: "8",
      expectedSha256,
    });
    const part = await service.uploadPart({
      ownerId,
      uploadSessionId: created.id,
      partNumber: 1,
      body: Buffer.from("part one"),
    });

    expect(part).toMatchObject({ partNumber: 1, sizeBytes: "8", sha256: expectedSha256 });
    const resumed = await service.get({ ownerId, uploadSessionId: created.id });
    expect(resumed).toMatchObject({
      id: created.id,
      status: "OPEN",
      expectedSizeBytes: 8n,
      expectedSha256,
      parts: [{ partNumber: 1, sizeBytes: 8n, sha256: expectedSha256 }],
    });
    expect(await prisma.uploadPart.count({ where: { uploadSessionId: created.id } })).toBe(1);
  });

  it("reuses an equivalent create retry without leaving a second storage session", async () => {
    const input = {
      ownerId,
      assetId,
      clipId,
      expectedSizeBytes: 8,
      expectedSha256: createHash("sha256").update("part one").digest("hex"),
    };
    const [first, retry] = await Promise.all([service.create(input), service.create(input)]);

    expect(retry.id).toBe(first.id);
    expect(await prisma.uploadSession.count({ where: { clipId, status: "OPEN" } })).toBe(1);
    await expect(storage.listParts(retry.id)).resolves.toEqual([]);
  });

  it("stores original metadata only after verified completion", async () => {
    const content = Buffer.from("native original");
    const expectedSha256 = createHash("sha256").update(content).digest("hex");
    const session = await service.create({
      ownerId,
      assetId,
      clipId,
      expectedSizeBytes: content.length,
      expectedSha256,
    });
    await service.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body: content,
    });
    const completed = await service.complete({ ownerId, uploadSessionId: session.id });
    const clip = await prisma.clip.findUnique({ where: { id: clipId } });

    expect(completed.status).toBe("COMPLETED");
    expect(clip).toMatchObject({
      storageKey: session.storageKey,
      storageDriver: "local",
      sha256: expectedSha256,
      fileSize: BigInt(content.length),
    });
    expect(await storage.stat(session.storageKey)).toMatchObject({ sizeBytes: String(content.length) });
  });

  it("keeps incomplete sessions open after validation failure and permits abort", async () => {
    const session = await service.create({
      ownerId,
      assetId,
      clipId,
      expectedSizeBytes: 100,
    });
    await service.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body: Buffer.from("short"),
    });

    await expect(service.complete({ ownerId, uploadSessionId: session.id }))
      .rejects.toThrow("Completed upload size does not match");
    expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe("OPEN");
    expect(await service.abort({ ownerId, uploadSessionId: session.id })).toMatchObject({ status: "ABORTED" });
    expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(1);
  });

  it("expires idle sessions and rejects writes after expiry", async () => {
    service = createUploadSessionService({
      db: prisma,
      storage,
      now: () => new Date(currentTime),
      sessionTtlMs: 1_000,
    });
    const session = await service.create({ ownerId, assetId, clipId });
    currentTime = new Date(currentTime.getTime() + 1_001);

    const expired = await service.get({ ownerId, uploadSessionId: session.id });
    expect(expired.status).toBe("EXPIRED");
    await expect(service.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body: Buffer.from("late"),
    })).rejects.toMatchObject({ code: "EXPIRED" });
  });

  it("rejects foreign owners and moderated assets without persisting sessions", async () => {
    await expect(service.create({ ownerId: "another-owner", assetId, clipId }))
      .rejects.toMatchObject({ code: "NOT_FOUND" });
    await prisma.asset.update({ where: { id: assetId }, data: { moderation: "PAUSED" } });
    await expect(service.create({ ownerId, assetId, clipId }))
      .rejects.toBeInstanceOf(UploadSessionError);
    expect(await prisma.uploadSession.count({ where: { assetId } })).toBe(0);
  });

  it("recovers a completed object left between storage completion and database commit", async () => {
    const content = Buffer.from("recovered original");
    const session = await service.create({ ownerId, assetId, clipId });
    await service.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body: content,
    });
    await storage.completeUpload(session.id);
    await prisma.uploadSession.update({
      where: { id: session.id },
      data: { status: "COMPLETING" },
    });

    const recovered = await service.get({ ownerId, uploadSessionId: session.id });
    const clip = await prisma.clip.findUnique({ where: { id: clipId } });
    expect(recovered.status).toBe("COMPLETED");
    expect(clip.sha256).toBe(createHash("sha256").update(content).digest("hex"));
    expect(clip.fileSize).toBe(BigInt(content.length));
  });

  it("reopens a completion interrupted before the original was published", async () => {
    const session = await service.create({ ownerId, assetId, clipId });
    await service.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body: Buffer.from("retryable"),
    });
    await prisma.uploadSession.update({
      where: { id: session.id },
      data: { status: "COMPLETING" },
    });

    const recovered = await service.get({ ownerId, uploadSessionId: session.id });
    expect(recovered.status).toBe("OPEN");
    expect(recovered.parts.map(part => part.partNumber)).toEqual([1]);
  });

  it("does not recover or abort a completion that is still running", async () => {
    const session = await service.create({ ownerId, assetId, clipId });
    await service.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body: Buffer.from("in progress"),
    });

    let unblockCompletion;
    let markStarted;
    const started = new Promise(resolve => { markStarted = resolve; });
    const gate = new Promise(resolve => { unblockCompletion = resolve; });
    const listParts = storage.listParts.bind(storage);
    let firstCall = true;
    storage.listParts = async (...args) => {
      if (firstCall) {
        firstCall = false;
        markStarted();
        await gate;
      }
      return listParts(...args);
    };

    const completion = service.complete({ ownerId, uploadSessionId: session.id });
    await started;
    let resumed;
    try {
      resumed = await service.get({ ownerId, uploadSessionId: session.id });
      await expect(service.abort({ ownerId, uploadSessionId: session.id }))
        .rejects.toMatchObject({ code: "SESSION_BUSY" });
    } finally {
      unblockCompletion();
      await completion;
    }
    expect(resumed.status).toBe("COMPLETING");
    await expect(completion).resolves.toMatchObject({ status: "COMPLETED" });
  });
});
