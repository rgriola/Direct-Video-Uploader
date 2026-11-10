import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createLocalStorageDriver } from "../lib/storage/local-driver.js";
import { createUploadSessionService } from "../lib/upload-sessions.js";
import { unrestrictedTestCapacity } from "./helpers/storage-capacity.js";

const temporaryDirectories = new Set();

async function createTemporaryDirectory() {
  const root = await mkdtemp(path.join(os.tmpdir(), "dvu-upload-session-unit-"));
  temporaryDirectories.add(root);
  return root;
}

function createDatabase({ moderation = "ACTIVE" } = {}) {
  const assetId = randomUUID();
  const clipId = randomUUID();
  const ownerId = randomUUID();
  const state = {
    owner: { status: "ACTIVE" },
    asset: { id: assetId, userId: ownerId, moderation, status: "UPLOADING" },
    clip: {
      id: clipId,
      assetId,
      status: "UPLOADING",
      storageUrl: null,
      storageKey: null,
      storageDriver: null,
      sha256: null,
      fileSize: null,
      muxAssetId: null,
      muxUploadId: null,
    },
    sessions: new Map(),
    parts: new Map(),
  };
  const partKey = (uploadSessionId, partNumber) => `${uploadSessionId}:${partNumber}`;
  const matches = (record, where) => Object.entries(where).every(([key, value]) => {
    if (value && typeof value === "object" && "in" in value) return value.in.includes(record[key]);
    return record[key] === value;
  });
  const includeSession = session => session && ({
    ...session,
    owner: { ...state.owner },
    asset: { userId: state.asset.userId, moderation: state.asset.moderation, status: state.asset.status },
    clip: { ...state.clip },
    parts: [...state.parts.values()]
      .filter(part => part.uploadSessionId === session.id)
      .sort((left, right) => left.partNumber - right.partNumber),
  });

  const db = {
    $queryRaw: async () => [],
    $transaction: async callback => callback(db),
    storageWriteLease: {
      findMany: async () => [],
      deleteMany: async () => ({ count: 0 }),
    },
    asset: {
      findUnique: async ({ where }) => where.id === state.asset.id ? { ...state.asset } : null,
    },
    clip: {
      findUnique: async ({ where }) => where.id === state.clip.id ? { ...state.clip } : null,
      updateMany: async ({ where, data }) => {
        if (!matches(state.clip, where)) return { count: 0 };
        Object.assign(state.clip, data);
        return { count: 1 };
      },
    },
    uploadSession: {
      create: async ({ data }) => {
        const session = {
          ...data,
          status: "OPEN",
          completedAt: null,
          createdAt: new Date("2026-11-09T12:00:00.000Z"),
        };
        state.sessions.set(session.id, session);
        return includeSession(session);
      },
      findFirst: async ({ where }) => {
        const session = [...state.sessions.values()].find(record => matches(record, where));
        return includeSession(session);
      },
      findUnique: async ({ where }) => includeSession(state.sessions.get(where.id)),
      update: async ({ where, data }) => {
        const session = state.sessions.get(where.id);
        Object.assign(session, data);
        return includeSession(session);
      },
      updateMany: async ({ where, data }) => {
        const session = state.sessions.get(where.id);
        if (!session || !matches(session, where)) return { count: 0 };
        Object.assign(session, data);
        return { count: 1 };
      },
    },
    uploadPart: {
      findMany: async ({ where }) => [...state.parts.values()]
        .filter(part => part.uploadSessionId === where.uploadSessionId),
      upsert: async ({ where, create, update }) => {
        const key = partKey(
          where.uploadSessionId_partNumber.uploadSessionId,
          where.uploadSessionId_partNumber.partNumber,
        );
        const part = state.parts.get(key) || { ...create };
        Object.assign(part, update);
        state.parts.set(key, part);
        return part;
      },
      deleteMany: async ({ where }) => {
        let count = 0;
        for (const [key, part] of state.parts) {
          if (part.uploadSessionId !== where.uploadSessionId) continue;
          if (!where.partNumber || !where.partNumber.notIn.includes(part.partNumber)) {
            state.parts.delete(key);
            count += 1;
          }
        }
        return { count };
      },
    },
  };
  return { db, state, assetId, clipId, ownerId };
}

afterEach(async () => {
  await Promise.all([...temporaryDirectories].map(root => rm(root, { recursive: true, force: true })));
  temporaryDirectories.clear();
});

describe("upload session service", () => {
  async function setup(options) {
    const database = createDatabase(options);
    const storage = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    const currentTime = { value: new Date("2026-11-09T12:00:00.000Z") };
    const service = createUploadSessionService({
      db: database.db,
      storage,
      capacity: unrestrictedTestCapacity,
      now: () => new Date(currentTime.value),
    });
    return { ...database, storage, service, currentTime };
  }

  it("creates resumable sessions and persists completed part metadata", async () => {
    const { ownerId, assetId, clipId, state, service } = await setup();
    const expectedSha256 = createHash("sha256").update("part one").digest("hex");
    const session = await service.create({
      ownerId,
      assetId,
      clipId,
      expectedSizeBytes: "8",
      expectedSha256,
    });
    await service.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body: Buffer.from("part one"),
    });

    const resumed = await service.get({ ownerId, uploadSessionId: session.id });
    expect(resumed.parts).toMatchObject([
      { partNumber: 1, sizeBytes: 8n, sha256: expectedSha256 },
    ]);
    expect(state.parts.size).toBe(1);
  });

  it("reuses equivalent create retries and removes their unused storage sessions", async () => {
    const { ownerId, assetId, clipId, state, service, storage } = await setup();
    const input = { ownerId, assetId, clipId, expectedSizeBytes: 4 };
    const first = await service.create(input);
    const retry = await service.create(input);

    expect(retry.id).toBe(first.id);
    expect(state.sessions.size).toBe(1);
    await expect(storage.listParts(first.id)).resolves.toEqual([]);
  });

  it("removes part metadata that is no longer present in storage on resume", async () => {
    const { ownerId, assetId, clipId, state, service } = await setup();
    const session = await service.create({ ownerId, assetId, clipId });
    state.parts.set(`${session.id}:1`, {
      uploadSessionId: session.id,
      partNumber: 1,
      sizeBytes: 4n,
      sha256: createHash("sha256").update("part").digest("hex"),
    });

    const resumed = await service.get({ ownerId, uploadSessionId: session.id });
    expect(resumed.parts).toEqual([]);
    expect(state.parts.size).toBe(0);
  });

  it("does not reuse a session when a create retry changes its expected upload", async () => {
    const { ownerId, assetId, clipId, state, service } = await setup();
    await service.create({ ownerId, assetId, clipId, expectedSizeBytes: 4 });

    await expect(service.create({ ownerId, assetId, clipId, expectedSizeBytes: 5 }))
      .rejects.toMatchObject({ code: "SESSION_EXISTS" });
    expect(state.sessions.size).toBe(1);
  });

  it("completes only after verification and writes nullable original metadata", async () => {
    const { ownerId, assetId, clipId, state, service, storage } = await setup();
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

    expect(completed.status).toBe("COMPLETED");
    expect(state.clip).toMatchObject({
      storageKey: session.storageKey,
      storageDriver: "local",
      sha256: expectedSha256,
      fileSize: BigInt(content.length),
    });
    await expect(storage.stat(session.storageKey)).resolves.toMatchObject({
      sizeBytes: String(content.length),
    });
  });

  it("rejects foreign owners and moderated assets and cleans up unpersisted storage sessions", async () => {
    const { ownerId, assetId, clipId, state, service } = await setup({ moderation: "PAUSED" });
    await expect(service.create({ ownerId: "another-owner", assetId, clipId }))
      .rejects.toMatchObject({ code: "NOT_FOUND" });
    await expect(service.create({ ownerId, assetId, clipId }))
      .rejects.toMatchObject({ code: "ASSET_NOT_ACTIVE" });
    expect(state.sessions.size).toBe(0);
  });

  it("expires idle sessions and rejects writes after expiry", async () => {
    const { ownerId, assetId, clipId, service, currentTime } = await setup();
    const session = await service.create({ ownerId, assetId, clipId });
    currentTime.value = new Date(currentTime.value.getTime() + 24 * 60 * 60 * 1000 + 1);

    expect((await service.get({ ownerId, uploadSessionId: session.id })).status).toBe("EXPIRED");
    await expect(service.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body: Buffer.from("late"),
    })).rejects.toMatchObject({ code: "EXPIRED" });
  });

  it("rejects completion after the asset is no longer active", async () => {
    const { ownerId, assetId, clipId, state, service } = await setup();
    const session = await service.create({ ownerId, assetId, clipId });
    state.asset.status = "ERROR";

    await expect(service.complete({ ownerId, uploadSessionId: session.id }))
      .rejects.toMatchObject({ code: "ASSET_NOT_ACTIVE" });
  });

  it("recovers a completed object left before its database status was committed", async () => {
    const { ownerId, assetId, clipId, state, service, storage } = await setup();
    const content = Buffer.from("recovered original");
    const session = await service.create({ ownerId, assetId, clipId });
    await service.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body: content,
    });
    await storage.completeUpload(session.id);
    state.sessions.get(session.id).status = "COMPLETING";

    const recovered = await service.get({ ownerId, uploadSessionId: session.id });
    expect(recovered.status).toBe("COMPLETED");
    expect(state.clip.sha256).toBe(createHash("sha256").update(content).digest("hex"));
    expect(state.clip.fileSize).toBe(BigInt(content.length));
  });

  it("keeps a published object recoverable when storage cleanup fails", async () => {
    const { ownerId, assetId, clipId, state, service, storage } = await setup();
    const content = Buffer.from("published before cleanup");
    const session = await service.create({ ownerId, assetId, clipId });
    await service.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body: content,
    });
    const completeUpload = storage.completeUpload.bind(storage);
    storage.completeUpload = async (...args) => {
      await completeUpload(...args);
      throw new Error("session cleanup failed after publish");
    };

    await expect(service.complete({ ownerId, uploadSessionId: session.id }))
      .rejects.toThrow("session cleanup failed after publish");
    expect(state.sessions.get(session.id).status).toBe("COMPLETING");

    const recovered = await service.get({ ownerId, uploadSessionId: session.id });
    expect(recovered.status).toBe("COMPLETED");
    expect(state.clip.fileSize).toBe(BigInt(content.length));
  });

  it("does not reopen a completion that is still in progress", async () => {
    const { ownerId, assetId, clipId, service, storage } = await setup();
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

    await expect(completion).resolves.toMatchObject({ status: "COMPLETED" });
    expect(resumed.status).toBe("COMPLETING");
  });

  it("reopens a completion interrupted before the object was published", async () => {
    const { ownerId, assetId, clipId, state, service } = await setup();
    const session = await service.create({ ownerId, assetId, clipId });
    await service.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body: Buffer.from("retryable"),
    });
    state.sessions.get(session.id).status = "COMPLETING";

    const recovered = await service.get({ ownerId, uploadSessionId: session.id });
    expect(recovered.status).toBe("OPEN");
    expect(recovered.parts.map(part => part.partNumber)).toEqual([1]);
  });
});
