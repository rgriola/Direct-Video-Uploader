import Fastify from "fastify";
import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { fileURLToPath } from "node:url";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { createLocalStorageDriver } from "../lib/storage/local-driver.js";
import {
  createStorageCapacity, lockStorageCapacity, SESSION_OVERHEAD_BYTES, WRITE_OVERHEAD_BYTES,
} from "../lib/storage/capacity.js";
import { createUploadSessionService } from "../lib/upload-sessions.js";
import uploadSessionRoutes from "../routes/upload-sessions.js";
import { acquireIntegrationDatabaseLock, INTEGRATION_SETUP_TIMEOUT_MS } from "./helpers/database-lock.js";
import { unrestrictedTestCapacity } from "./helpers/storage-capacity.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
if (process.env.CI && !databaseUrl) {
  throw new Error("TEST_DATABASE_URL is required for storage capacity integration tests in CI");
}
if (databaseUrl) {
  const url = new URL(databaseUrl);
  if (!["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)
    || !url.pathname.slice(1).startsWith("dvu_scope_test_")
    || process.env.DATABASE_URL !== databaseUrl) {
    throw new Error("Storage capacity tests require a dedicated local dvu_scope_test_ database");
  }
}

const integration = databaseUrl ? describe : describe.skip;
const sha256 = content => createHash("sha256").update(content).digest("hex");
const reservationFor = size => BigInt(size) * 2n + SESSION_OVERHEAD_BYTES;

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 800; attempt += 1) {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  throw new Error("Timed out waiting for storage capacity state");
}

integration("storage capacity against PostgreSQL and local storage", () => {
  const ownerId = `capacity-owner-${randomUUID()}`;
  const minFreeBytes = 10n * 1024n * 1024n;
  let prisma;
  let pool;
  let releaseDatabaseLock;
  let storageRoot;
  let storage;
  let realSnapshot;
  let measurements;
  let now;
  let app;

  beforeAll(async () => {
    const database = await import("../lib/prisma.js");
    prisma = database.default;
    pool = database.pool;
    releaseDatabaseLock = await acquireIntegrationDatabaseLock(database.pool);
    await prisma.user.create({
      data: {
        id: ownerId,
        name: "Capacity Test",
        phoneNumber: `capacity-${randomUUID()}`,
        pinHash: "integration-test",
      },
    });
  }, INTEGRATION_SETUP_TIMEOUT_MS);

  beforeEach(async () => {
    storageRoot = await mkdtemp(path.join(os.tmpdir(), "dvu-storage-capacity-"));
    storage = createLocalStorageDriver({ root: storageRoot });
    realSnapshot = storage.getCapacitySnapshot.bind(storage);
    measurements = { usedBytes: 0n, availableBytes: 1024n * 1024n * 1024n };
    storage.getCapacitySnapshot = async () => ({ ...await realSnapshot(), ...measurements });
    now = new Date("2026-11-09T12:00:00.000Z");
  });

  afterEach(async () => {
    if (app) await app.close();
    app = null;
    await prisma.storageWriteLease.deleteMany({});
    await prisma.asset.deleteMany({ where: { userId: ownerId } });
    if (storageRoot) await rm(storageRoot, { recursive: true, force: true });
  });

  afterAll(async () => {
    if (!prisma) return;
    try {
      await prisma.storageWriteLease.deleteMany({});
      await prisma.asset.deleteMany({ where: { userId: ownerId } });
      await prisma.user.deleteMany({ where: { id: ownerId } });
    } finally {
      await releaseDatabaseLock?.();
      await prisma.$disconnect();
    }
  });

  function capacity(maxStorageBytes = 1024n * 1024n * 1024n, options = {}) {
    return createStorageCapacity({ db: prisma, storage, maxStorageBytes, minFreeBytes, ...options });
  }

  function service(storageCapacity = capacity()) {
    return createUploadSessionService({
      db: prisma, storage, capacity: storageCapacity, now: () => new Date(now),
    });
  }

  function routeApp() {
    const server = Fastify({ logger: false });
    server.decorate("authenticate", async request => { request.user = { id: ownerId }; });
    server.decorate("io", {
      to: () => ({ emit: vi.fn() }),
      in: () => ({ fetchSockets: async () => [] }),
    });
    return server;
  }

  async function assetWithClip() {
    const assetId = randomUUID();
    const clipId = randomUUID();
    await prisma.asset.create({
      data: {
        id: assetId,
        userId: ownerId,
        status: "UPLOADING",
        clips: { create: { id: clipId, status: "UPLOADING" } },
      },
    });
    return { assetId, clipId };
  }

  async function createSession(uploadService, content, asset) {
    const target = asset ?? await assetWithClip();
    const input = {
      ownerId,
      ...target,
      expectedSizeBytes: content.length,
      expectedSha256: sha256(content),
    };
    return { session: await uploadService.create(input), input };
  }

  async function upload(uploadService, session, content, body = content) {
    return uploadService.uploadPart({
      ownerId,
      uploadSessionId: session.id,
      partNumber: 1,
      body,
      expectedSizeBytes: content.length,
    });
  }

  it("backfills existing sessions conservatively without overflowing bigint", async () => {
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      await client.query("CREATE TEMP TABLE upload_sessions (id text PRIMARY KEY, expected_size_bytes bigint)");
      await client.query(`
        INSERT INTO upload_sessions (id, expected_size_bytes) VALUES
          ('known', 524288000), ('unknown', NULL), ('zero', 0),
          ('largest', 4611686018426863615), ('too-large', 4611686018426863616)
      `);
      await client.query("SET LOCAL search_path = pg_temp");
      const migration = await readFile(new URL(
        "../../prisma/migrations/20261110010000_storage_capacity/migration.sql", import.meta.url,
      ), "utf8");
      await client.query(migration);
      const result = await client.query(
        "SELECT id, storage_reservation_bytes::text AS reserved FROM upload_sessions ORDER BY id",
      );
      expect(Object.fromEntries(result.rows.map(row => [row.id, row.reserved]))).toEqual({
        known: reservationFor(524288000).toString(),
        largest: "9223372036854775806",
        "too-large": null,
        unknown: null,
        zero: null,
      });
    } finally {
      await client.query("ROLLBACK");
      client.release();
    }
  });

  it("accepts the exact quota boundary and reuses an equivalent session without writing", async () => {
    const content = Buffer.from("1234567890");
    measurements.usedBytes = 123n;
    const uploadService = service(capacity(123n + reservationFor(content.length)));
    const createUpload = vi.spyOn(storage, "createUpload");
    const { session, input } = await createSession(uploadService, content);
    expect(session.storageReservationBytes).toBe(reservationFor(content.length));
    expect(createUpload).toHaveBeenCalledTimes(1);

    measurements.availableBytes = 0n;
    expect((await uploadService.create(input)).id).toBe(session.id);
    expect(createUpload).toHaveBeenCalledTimes(1);

    measurements.availableBytes = 1024n * 1024n * 1024n;
    const nextAsset = await assetWithClip();
    await expect(createSession(uploadService, Buffer.from("x"), nextAsset))
      .rejects.toMatchObject({ code: "STORAGE_CAPACITY_EXCEEDED" });
    expect(await prisma.uploadSession.count()).toBe(1);
  });

  it("requires the full free-space reserve at admission, including staging overhead", async () => {
    const content = Buffer.from("free space");
    const uploadService = service();
    const asset = await assetWithClip();
    measurements.availableBytes = minFreeBytes + reservationFor(content.length) - 1n;
    await expect(createSession(uploadService, content, asset))
      .rejects.toMatchObject({ code: "STORAGE_CAPACITY_EXCEEDED" });
    expect(await prisma.uploadSession.count()).toBe(0);

    measurements.availableBytes += 1n;
    expect((await createSession(uploadService, content, asset)).session.status).toBe("OPEN");
  });

  it("serializes simultaneous admissions against the same global budget", async () => {
    const content = Buffer.from("same size");
    const uploadService = service(capacity(reservationFor(content.length)));
    const assets = await Promise.all([assetWithClip(), assetWithClip()]);
    const results = await Promise.allSettled(assets.map(asset => createSession(uploadService, content, asset)));
    expect(results.filter(result => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter(result => result.status === "rejected")[0].reason)
      .toMatchObject({ code: "STORAGE_CAPACITY_EXCEEDED" });
    expect(await prisma.uploadSession.count()).toBe(1);
  });

  it("holds the owner before capacity and the session foreign-key insert", async () => {
    const content = Buffer.from("owner-capacity");
    const asset = await assetWithClip();
    const realCapacity = capacity();
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    let creatorPid;
    let createOutcome;
    const gatedCapacity = {
      ...realCapacity,
      reserve: async (tx, bytes) => {
        const reservation = await realCapacity.reserve(tx, bytes);
        const [{ pid }] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
        creatorPid = pid;
        await gate;
        return reservation;
      },
    };
    const creating = createSession(service(gatedCapacity), content, asset).then(
      value => (createOutcome = { value }),
      error => (createOutcome = { error }),
    );

    let contenderPid;
    let ownerAcquired = false;
    let contenderOutcome;
    let contender;
    try {
      await waitFor(() => {
        if (createOutcome) {
          throw createOutcome.error ?? new Error("Create finished before the gate");
        }
        return creatorPid != null;
      });
      contender = prisma.$transaction(async tx => {
        await tx.$queryRaw`SELECT set_config('statement_timeout', '12s', true)`;
        const [{ pid }] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
        contenderPid = pid;
        await tx.$queryRaw`
          SELECT id FROM users WHERE id = ${ownerId}
          FOR UPDATE /* owner-capacity-regression */
        `;
        ownerAcquired = true;
        await lockStorageCapacity(tx);
      }, { timeout: 15_000 }).then(
        () => (contenderOutcome = {}),
        error => (contenderOutcome = { error }),
      );
      await waitFor(async () => {
        if (contenderOutcome?.error) throw contenderOutcome.error;
        if (ownerAcquired) throw new Error("Owner lock was acquired too early");
        if (contenderPid == null) return false;
        const { rows } = await pool.query(`
          SELECT EXISTS (
            SELECT 1 FROM pg_stat_activity a
            WHERE a.pid = $1
              AND a.wait_event_type = 'Lock'
              AND a.query LIKE '%owner-capacity-regression%'
              AND $2::integer = ANY(pg_blocking_pids(a.pid))
          ) AS blocked
        `, [contenderPid, creatorPid]);
        return rows[0].blocked;
      });
      release();
      const [created, competing] = await Promise.all([creating, contender]);
      if (created.error) throw created.error;
      if (competing.error) throw competing.error;
      expect(created.value.session).toMatchObject({
        ownerId, assetId: asset.assetId, clipId: asset.clipId, status: "OPEN",
      });
      expect(await prisma.uploadSession.findUnique({ where: { id: created.value.session.id } }))
        .toMatchObject({ ownerId, assetId: asset.assetId, clipId: asset.clipId });
    } finally {
      release();
      if (contender) await contender;
      await creating;
    }
  }, 30_000);

  it("serializes admissions across separate server processes", async () => {
    const text = "processes";
    const assets = await Promise.all([assetWithClip(), assetWithClip()]);
    const client = await pool.connect();
    const worker = fileURLToPath(new URL("./helpers/storage-capacity-worker.js", import.meta.url));
    const runWorker = asset => new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [
        worker, ownerId, asset.assetId, asset.clipId, storageRoot, text, reservationFor(text.length).toString(),
      ], { env: process.env, stdio: ["ignore", "pipe", "pipe"] });
      let output = "";
      let errors = "";
      child.stdout.setEncoding("utf8").on("data", chunk => { output += chunk; });
      child.stderr.setEncoding("utf8").on("data", chunk => { errors += chunk; });
      child.on("error", reject);
      child.on("close", code => {
        const result = output.split("\n").find(line => line.startsWith("RESULT "));
        if (code !== 0 || !result) {
          reject(new Error(`Capacity worker failed (${code}): ${errors} ${output}`));
        } else {
          resolve(JSON.parse(result.slice(7)));
        }
      });
    });

    await client.query("SELECT pg_advisory_lock(hashtextextended($1, 0))", ["dvu:original-storage-capacity"]);
    const workers = assets.map(runWorker);
    let waitError;
    try {
      await waitFor(async () => {
        const result = await pool.query(`
          SELECT COUNT(*)::integer AS count FROM pg_stat_activity
          WHERE datname = current_database() AND wait_event_type = 'Lock'
            AND query LIKE '%pg_advisory_xact_lock%'
        `);
        return result.rows[0].count >= 2;
      });
    } catch (error) {
      waitError = error;
    } finally {
      await client.query("SELECT pg_advisory_unlock(hashtextextended($1, 0))", ["dvu:original-storage-capacity"]);
      client.release();
    }
    const settled = await Promise.allSettled(workers);
    if (waitError) throw waitError;
    const failures = settled.filter(result => result.status === "rejected");
    if (failures.length) throw failures[0].reason;
    const results = settled.map(result => result.value);
    expect(results.map(result => result.status).sort()).toEqual(["created", "full"]);
    expect(await prisma.uploadSession.count()).toBe(1);
  }, 15000);

  it("preserves a committed session when the create transaction outcome is ambiguous", async () => {
    const content = Buffer.from("ambiguous create");
    const uploadService = service();
    const asset = await assetWithClip();
    const transaction = prisma.$transaction.bind(prisma);
    const transactionSpy = vi.spyOn(prisma, "$transaction").mockImplementationOnce(async (...args) => {
      await transaction(...args);
      throw new Error("create result lost after commit");
    });
    try {
      await expect(createSession(uploadService, content, asset)).rejects.toThrow("create result lost");
    } finally {
      transactionSpy.mockRestore();
    }
    const persisted = await prisma.uploadSession.findFirst({ where: { assetId: asset.assetId } });
    expect(persisted).toMatchObject({
      status: "OPEN", storageReservationBytes: reservationFor(content.length),
    });
    expect(await storage.listParts(persisted.id)).toEqual([]);
    expect((await createSession(uploadService, content, asset)).session.id).toBe(persisted.id);
  });

  it("cleans an uncommitted storage session after its transaction has rolled back", async () => {
    const content = Buffer.from("rolled back create");
    const uploadService = service();
    const asset = await assetWithClip();
    const transaction = prisma.$transaction.bind(prisma);
    const transactionSpy = vi.spyOn(prisma, "$transaction").mockImplementationOnce(async callback => {
      return transaction(async tx => {
        await callback(tx);
        throw new Error("transaction rolled back");
      }, { timeout: 60000 });
    });
    try {
      await expect(createSession(uploadService, content, asset)).rejects.toThrow("transaction rolled back");
    } finally {
      transactionSpy.mockRestore();
    }
    expect(await prisma.uploadSession.count({ where: { assetId: asset.assetId } })).toBe(0);
    expect(await readdir(path.join(storageRoot, ".uploads"))).toEqual([]);
  });

  it("pauses part writes and completion at the exact free-space threshold", async () => {
    const content = Buffer.from("pause and resume");
    const uploadService = service();
    const { session } = await createSession(uploadService, content);
    const needed = minFreeBytes + WRITE_OVERHEAD_BYTES + BigInt(content.length);
    measurements.availableBytes = needed - 1n;
    await expect(upload(uploadService, session, content))
      .rejects.toMatchObject({ code: "STORAGE_CAPACITY_EXCEEDED" });
    expect((await uploadService.get({ ownerId, uploadSessionId: session.id })).parts).toEqual([]);
    expect(await prisma.storageWriteLease.count()).toBe(0);

    measurements.availableBytes = needed;
    await upload(uploadService, session, content);
    measurements.availableBytes = needed - 1n;
    await expect(uploadService.complete({ ownerId, uploadSessionId: session.id }))
      .rejects.toMatchObject({ code: "STORAGE_CAPACITY_EXCEEDED" });
    expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe("OPEN");

    measurements.availableBytes = needed;
    expect((await uploadService.complete({ ownerId, uploadSessionId: session.id })).status).toBe("COMPLETED");
    expect(await prisma.storageWriteLease.count()).toBe(0);
  });

  it("enforces the folder quota again before each write", async () => {
    const content = Buffer.from("quota");
    const maxBytes = 10n * 1024n * 1024n;
    const uploadService = service(capacity(maxBytes));
    const { session } = await createSession(uploadService, content);
    const writeReservation = WRITE_OVERHEAD_BYTES + BigInt(content.length);
    measurements.usedBytes = maxBytes - writeReservation;
    await upload(uploadService, session, content);
    measurements.usedBytes += 1n;
    await expect(upload(uploadService, session, content))
      .rejects.toMatchObject({ code: "STORAGE_CAPACITY_EXCEEDED" });
    expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(1);
  });

  it("reserves concurrent writes before accepting either stream", async () => {
    const content = Buffer.from("parallel");
    const uploadService = service();
    const [{ session: first }, { session: second }] = await Promise.all([
      createSession(uploadService, content), createSession(uploadService, content),
    ]);
    measurements.availableBytes = minFreeBytes + WRITE_OVERHEAD_BYTES + BigInt(content.length);
    const source = new PassThrough();
    const writing = upload(uploadService, first, content, source);
    try {
      await waitFor(async () => await prisma.storageWriteLease.count() === 1);
      await expect(upload(uploadService, second, content))
        .rejects.toMatchObject({ code: "STORAGE_CAPACITY_EXCEEDED" });
      source.end(content);
      await writing;
      await upload(uploadService, second, content);
    } finally {
      source.destroy();
      await Promise.allSettled([writing]);
    }
    expect(await prisma.storageWriteLease.count()).toBe(0);
  });

  it("counts a write that finishes while the storage snapshot is being measured", async () => {
    const content = Buffer.from("snapshot race");
    const uploadService = service();
    const [{ session: first }, { session: second }] = await Promise.all([
      createSession(uploadService, content), createSession(uploadService, content),
    ]);
    measurements.availableBytes = minFreeBytes + WRITE_OVERHEAD_BYTES + BigInt(content.length);
    const source = new PassThrough();
    const writing = upload(uploadService, first, content, source);
    let continueSnapshot;
    const snapshotGate = new Promise(resolve => { continueSnapshot = resolve; });
    let snapshotStarted;
    const snapshotPaused = new Promise(resolve => { snapshotStarted = resolve; });
    try {
      await waitFor(async () => await prisma.storageWriteLease.count() === 1);
      storage.getCapacitySnapshot = async () => {
        snapshotStarted();
        await snapshotGate;
        return { ...await realSnapshot(), ...measurements };
      };
      const competing = upload(uploadService, second, content);
      const rejected = expect(competing).rejects.toMatchObject({ code: "STORAGE_CAPACITY_EXCEEDED" });
      await snapshotPaused;
      source.end(content);
      await waitFor(async () => await prisma.uploadPart.count({ where: { uploadSessionId: first.id } }) === 1);
      await waitFor(async () => {
        const result = await pool.query(`
          SELECT EXISTS (
            SELECT 1 FROM pg_stat_activity
            WHERE datname = current_database() AND wait_event_type = 'Lock'
              AND query LIKE '%pg_advisory_xact_lock%'
          ) AS waiting
        `);
        return result.rows[0].waiting;
      });
      continueSnapshot();
      await rejected;
      await writing;
    } finally {
      continueSnapshot();
      source.destroy();
      await Promise.allSettled([writing]);
    }
    expect(await prisma.storageWriteLease.count()).toBe(0);
  });

  it("counts retained originals and other files under the storage root after completion", async () => {
    const content = Buffer.from("retained original");
    const uploadService = service();
    const { session } = await createSession(uploadService, content);
    await upload(uploadService, session, content);
    await uploadService.complete({ ownerId, uploadSessionId: session.id });
    expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes).toBe(0n);
    await writeFile(path.join(storageRoot, "orphan"), "leftover");
    const actual = await realSnapshot();
    measurements.usedBytes = actual.usedBytes;

    const next = Buffer.from("next");
    const asset = await assetWithClip();
    const exact = actual.usedBytes + reservationFor(next.length);
    await expect(createSession(service(capacity(exact - 1n)), next, asset))
      .rejects.toMatchObject({ code: "STORAGE_CAPACITY_EXCEEDED" });
    expect((await createSession(service(capacity(exact)), next, asset)).session.status).toBe("OPEN");
  });

  it("keeps reservations after failed abort cleanup and releases them only after a retry", async () => {
    const content = Buffer.from("abort");
    const uploadService = service(capacity(reservationFor(content.length)));
    const { session } = await createSession(uploadService, content);
    await upload(uploadService, session, content);
    const abort = vi.spyOn(storage, "abortUpload").mockRejectedValueOnce(new Error("cleanup failed"));
    await expect(uploadService.abort({ ownerId, uploadSessionId: session.id })).rejects.toThrow("cleanup failed");
    expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
      .toMatchObject({ status: "ABORTED", storageReservationBytes: reservationFor(content.length) });

    const asset = await assetWithClip();
    await expect(createSession(uploadService, content, asset))
      .rejects.toMatchObject({ code: "STORAGE_CAPACITY_EXCEEDED" });
    abort.mockRestore();
    await uploadService.abort({ ownerId, uploadSessionId: session.id });
    expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes).toBe(0n);
    expect((await createSession(uploadService, content, asset)).session.status).toBe("OPEN");
  });

  it("retains a reservation when recording successful cleanup fails", async () => {
    const content = Buffer.from("database cleanup failure");
    const uploadService = service();
    const { session } = await createSession(uploadService, content);
    await upload(uploadService, session, content);
    const transaction = prisma.$transaction.bind(prisma);
    const transactionSpy = vi.spyOn(prisma, "$transaction")
      .mockImplementationOnce((...args) => transaction(...args))
      .mockImplementationOnce((...args) => transaction(...args))
      .mockRejectedValueOnce(new Error("reservation release failed"));
    try {
      await expect(uploadService.abort({ ownerId, uploadSessionId: session.id }))
        .rejects.toThrow("reservation release failed");
    } finally {
      transactionSpy.mockRestore();
    }
    expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
      .toMatchObject({ status: "ABORTED", storageReservationBytes: reservationFor(content.length) });
    await expect(storage.listParts(session.id)).rejects.toThrow("Upload session not found");
    await uploadService.abort({ ownerId, uploadSessionId: session.id });
    expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes).toBe(0n);
  });

  it("recovers a finished write lease if its database release fails", async () => {
    const content = Buffer.from("retry a committed part");
    const uploadService = service();
    const { session } = await createSession(uploadService, content);
    const transaction = prisma.$transaction.bind(prisma);
    const transactionSpy = vi.spyOn(prisma, "$transaction")
      .mockImplementationOnce((...args) => transaction(...args))
      .mockImplementationOnce((...args) => transaction(...args))
      .mockRejectedValueOnce(new Error("write lease release failed"));
    try {
      await expect(upload(uploadService, session, content)).rejects.toThrow("write lease release failed");
    } finally {
      transactionSpy.mockRestore();
    }
    expect(await prisma.storageWriteLease.count()).toBe(1);
    expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(1);
    await upload(uploadService, session, content);
    expect(await prisma.storageWriteLease.count()).toBe(0);
    expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(1);
  });

  it("retains expired reservations if cleanup fails and retries cleanup on session access", async () => {
    const content = Buffer.from("expire");
    const uploadService = service();
    const { session } = await createSession(uploadService, content);
    vi.spyOn(storage, "abortUpload").mockRejectedValueOnce(new Error("expiry cleanup failed"));
    now = new Date(now.getTime() + 25 * 60 * 60 * 1000);
    await expect(uploadService.get({ ownerId, uploadSessionId: session.id })).rejects.toThrow("expiry cleanup failed");
    expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
      .toMatchObject({ status: "EXPIRED", storageReservationBytes: reservationFor(content.length) });
    expect((await uploadService.get({ ownerId, uploadSessionId: session.id })).status).toBe("EXPIRED");
    expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes).toBe(0n);
  });

  it("removes staged leftovers before releasing a recovered completion reservation", async () => {
    const content = Buffer.from("recover the original");
    const uploadService = service();
    const { session } = await createSession(uploadService, content);
    await upload(uploadService, session, content);
    const sessionPath = path.join(storageRoot, ".uploads", session.id);
    const manifest = await readFile(path.join(sessionPath, "manifest.json"));
    const completeUpload = storage.completeUpload.bind(storage);
    storage.completeUpload = async (...args) => {
      await completeUpload(...args);
      await mkdir(path.join(sessionPath, "parts"), { recursive: true });
      await writeFile(path.join(sessionPath, "manifest.json"), manifest);
      await writeFile(path.join(sessionPath, "parts", "00001"), content);
      throw new Error("cleanup interrupted after publication");
    };
    await expect(uploadService.complete({ ownerId, uploadSessionId: session.id }))
      .rejects.toThrow("cleanup interrupted");
    expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
      .toMatchObject({ status: "COMPLETING", storageReservationBytes: reservationFor(content.length) });

    const originalPath = path.join(storageRoot, ...session.storageKey.split("/"));
    await writeFile(originalPath, Buffer.alloc(content.length, "x"));
    await expect(uploadService.get({ ownerId, uploadSessionId: session.id }))
      .rejects.toMatchObject({ code: "INTEGRITY_MISMATCH" });
    expect(await readFile(path.join(sessionPath, "parts", "00001"))).toEqual(content);
    expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes)
      .toBe(reservationFor(content.length));
    await writeFile(originalPath, content);

    const recovered = await uploadService.get({ ownerId, uploadSessionId: session.id });
    expect(recovered).toMatchObject({ status: "COMPLETED", storageReservationBytes: 0n });
    await expect(readFile(path.join(sessionPath, "manifest.json"))).rejects.toMatchObject({ code: "ENOENT" });
    expect(await storage.stat(session.storageKey)).toMatchObject({ sizeBytes: String(content.length) });
  });

  it("preserves staged data when an interrupted legacy completion has no verifiable checksum", async () => {
    const content = Buffer.from("legacy without checksum");
    const uploadService = service(unrestrictedTestCapacity);
    const asset = await assetWithClip();
    const session = await uploadService.create({ ownerId, ...asset, expectedSizeBytes: content.length });
    await upload(uploadService, session, content);
    const sessionPath = path.join(storageRoot, ".uploads", session.id);
    const manifest = await readFile(path.join(sessionPath, "manifest.json"));
    await storage.completeUpload(session.id, { expectedSizeBytes: content.length });
    await mkdir(path.join(sessionPath, "parts"), { recursive: true });
    await writeFile(path.join(sessionPath, "manifest.json"), manifest);
    await writeFile(path.join(sessionPath, "parts", "00001"), content);
    await prisma.uploadSession.update({ where: { id: session.id }, data: { status: "COMPLETING" } });

    await expect(uploadService.get({ ownerId, uploadSessionId: session.id }))
      .rejects.toMatchObject({ code: "STORAGE_UNAVAILABLE" });
    expect(await readFile(path.join(sessionPath, "parts", "00001"))).toEqual(content);
    expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe("COMPLETING");
  });

  it("verifies retained clip integrity before removing completed-session leftovers", async () => {
    const content = Buffer.from("verified legacy original");
    const uploadService = service(unrestrictedTestCapacity);
    const asset = await assetWithClip();
    const session = await uploadService.create({ ownerId, ...asset });
    await upload(uploadService, session, content);
    const sessionPath = path.join(storageRoot, ".uploads", session.id);
    const manifest = await readFile(path.join(sessionPath, "manifest.json"));
    await uploadService.complete({ ownerId, uploadSessionId: session.id });
    await mkdir(path.join(sessionPath, "parts"), { recursive: true });
    await writeFile(path.join(sessionPath, "manifest.json"), manifest);
    await writeFile(path.join(sessionPath, "parts", "00001"), content);
    await prisma.uploadSession.update({
      where: { id: session.id }, data: { storageReservationBytes: null },
    });

    const originalPath = path.join(storageRoot, ...session.storageKey.split("/"));
    await writeFile(originalPath, Buffer.alloc(content.length, "x"));
    await expect(uploadService.get({ ownerId, uploadSessionId: session.id }))
      .rejects.toMatchObject({ code: "INTEGRITY_MISMATCH" });
    expect(await readFile(path.join(sessionPath, "parts", "00001"))).toEqual(content);
    await writeFile(originalPath, content);
    expect((await uploadService.get({ ownerId, uploadSessionId: session.id })).storageReservationBytes).toBe(0n);
    await expect(readFile(path.join(sessionPath, "manifest.json"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("rechecks visibility after completed-session cleanup", async () => {
    const content = Buffer.from("moderated during cleanup");
    const uploadService = service();
    const { session } = await createSession(uploadService, content);
    await upload(uploadService, session, content);
    await uploadService.complete({ ownerId, uploadSessionId: session.id });
    await prisma.uploadSession.update({
      where: { id: session.id }, data: { storageReservationBytes: reservationFor(content.length) },
    });
    const abort = storage.abortUpload.bind(storage);
    let cleanupStarted;
    const started = new Promise(resolve => { cleanupStarted = resolve; });
    let continueCleanup;
    const gate = new Promise(resolve => { continueCleanup = resolve; });
    storage.abortUpload = async (...args) => {
      const result = await abort(...args);
      cleanupStarted();
      await gate;
      return result;
    };
    const loading = uploadService.get({ ownerId, uploadSessionId: session.id });
    const rejected = expect(loading).rejects.toMatchObject({ code: "NOT_FOUND" });
    try {
      await started;
      await prisma.asset.update({
        where: { id: session.assetId }, data: { moderation: "FLAGGED_FOR_REMOVAL" },
      });
    } finally {
      continueCleanup();
    }
    await rejected;
  });

  it("fails closed for unknown legacy sizes until the session is cleaned", async () => {
    const old = service(unrestrictedTestCapacity);
    const asset = await assetWithClip();
    const legacy = await old.create({ ownerId, ...asset });
    const uploadService = service();
    const next = await assetWithClip();
    await expect(createSession(uploadService, Buffer.from("new"), next))
      .rejects.toMatchObject({ code: "STORAGE_UNAVAILABLE" });
    await old.abort({ ownerId, uploadSessionId: legacy.id });
    expect((await createSession(uploadService, Buffer.from("new"), next)).session.status).toBe("OPEN");
  });

  it("does not initialize an identity over an unverified nonempty root", async () => {
    await writeFile(path.join(storageRoot, "unverified-original"), "do not replace");
    const uploadService = service();
    await expect(createSession(uploadService, Buffer.from("new")))
      .rejects.toMatchObject({ code: "STORAGE_UNAVAILABLE" });
    expect(await readFile(path.join(storageRoot, "unverified-original"), "utf8")).toBe("do not replace");
    await expect(readFile(path.join(storageRoot, ".dvu-storage-id"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("reclaims a dead same-host write lease but retains an unverified remote lease", async () => {
    const content = Buffer.from("lease");
    const uploadService = service(capacity(undefined, { processAlive: () => false }));
    const { session } = await createSession(uploadService, content);
    const identity = (await realSnapshot()).identity;
    await prisma.storageWriteLease.create({
      data: {
        id: randomUUID(), uploadSessionId: session.id, storageIdentity: identity,
        sizeBytes: 100n * 1024n * 1024n, host: os.hostname(), pid: 12345,
      },
    });
    await createSession(uploadService, content);
    expect(await prisma.storageWriteLease.count()).toBe(0);

    await prisma.storageWriteLease.create({
      data: {
        id: randomUUID(), uploadSessionId: session.id, storageIdentity: identity,
        sizeBytes: 100n * 1024n * 1024n, host: "different-host", pid: 12345,
      },
    });
    measurements.availableBytes = minFreeBytes + reservationFor(content.length) * 3n;
    const next = await assetWithClip();
    await expect(createSession(uploadService, content, next))
      .rejects.toMatchObject({ code: "STORAGE_CAPACITY_EXCEEDED" });
    expect(await prisma.storageWriteLease.count()).toBe(1);
  });

  it("refuses admission when existing storage belongs to a different root", async () => {
    const content = Buffer.from("original root");
    await createSession(service(), content);
    const otherRoot = await mkdtemp(path.join(os.tmpdir(), "dvu-capacity-other-"));
    try {
      const other = createLocalStorageDriver({ root: otherRoot });
      await other.createUpload({ ownerId, assetId: randomUUID(), clipId: randomUUID() });
      const otherCapacity = createStorageCapacity({
        db: prisma, storage: other, maxStorageBytes: 1024n * 1024n * 1024n, minFreeBytes,
      });
      const otherService = createUploadSessionService({ db: prisma, storage: other, capacity: otherCapacity });
      await expect(createSession(otherService, Buffer.from("new")))
        .rejects.toMatchObject({ code: "STORAGE_UNAVAILABLE" });
    } finally {
      await rm(otherRoot, { recursive: true, force: true });
    }
  });

  it("reports retryable capacity failures over HTTP without blocking reads or aborts", async () => {
    app = routeApp();
    await app.register(uploadSessionRoutes, {
      db: prisma,
      storage,
      capacity: capacity(),
      signingSecret: "capacity-integration-signing-secret-32-bytes",
      now: () => new Date(now),
    });
    const assetId = randomUUID();
    await prisma.asset.create({ data: { id: assetId, userId: ownerId, status: "UPLOADING" } });
    const content = Buffer.from("HTTP retry");
    const url = `/api/assets/${assetId}/upload-sessions`;
    const payload = { expectedSizeBytes: content.length, expectedSha256: sha256(content) };
    measurements.availableBytes = minFreeBytes + reservationFor(content.length) - 1n;
    expect((await app.inject({ method: "POST", url, payload })).statusCode).toBe(507);
    expect(await prisma.uploadSession.count()).toBe(0);

    measurements.availableBytes += 1n;
    const created = await app.inject({ method: "POST", url, payload });
    expect(created.statusCode, created.body).toBe(201);
    const sessionId = created.json().uploadSession.id;
    measurements.availableBytes = 0n;
    const retry = await app.inject({ method: "POST", url, payload });
    expect(retry.statusCode, retry.body).toBe(200);
    expect(retry.json().uploadSession.id).toBe(sessionId);
    const signed = await app.inject({ method: "POST", url: `/api/upload-sessions/${sessionId}/parts/1/sign` });
    expect(signed.statusCode).toBe(200);
    const put = await app.inject({
      method: "PUT",
      url: signed.json().url,
      headers: { "content-type": "application/octet-stream" },
      payload: content,
    });
    expect(put.statusCode, put.body).toBe(507);
    expect(put.headers.connection).toBe("close");
    expect((await app.inject({ method: "GET", url: `/api/upload-sessions/${sessionId}` })).statusCode).toBe(200);
    expect((await app.inject({ method: "DELETE", url: `/api/upload-sessions/${sessionId}` })).statusCode).toBe(200);
  });

  it.each(["ENOSPC", "EDQUOT"])("returns 507 for %s while keeping status and abort available", async code => {
    app = routeApp();
    await app.register(uploadSessionRoutes, {
      db: prisma,
      storage,
      capacity: capacity(),
      signingSecret: "capacity-integration-signing-secret-32-bytes",
      now: () => new Date(now),
    });
    const assetId = randomUUID();
    await prisma.asset.create({ data: { id: assetId, userId: ownerId, status: "UPLOADING" } });
    const content = Buffer.from("disk full");
    const created = await app.inject({
      method: "POST",
      url: `/api/assets/${assetId}/upload-sessions`,
      payload: { expectedSizeBytes: content.length, expectedSha256: sha256(content) },
    });
    expect(created.statusCode, created.body).toBe(201);
    const sessionId = created.json().uploadSession.id;
    const signed = await app.inject({ method: "POST", url: `/api/upload-sessions/${sessionId}/parts/1/sign` });
    vi.spyOn(storage, "uploadPart").mockRejectedValueOnce(Object.assign(new Error("disk full"), { code }));
    const put = await app.inject({
      method: "PUT",
      url: signed.json().url,
      headers: { "content-type": "application/octet-stream" },
      payload: content,
    });
    expect(put.statusCode, put.body).toBe(507);
    expect(put.headers.connection).toBe("close");
    expect(await prisma.storageWriteLease.count()).toBe(0);

    measurements.availableBytes = 0n;
    expect((await app.inject({ method: "GET", url: `/api/upload-sessions/${sessionId}` })).statusCode).toBe(200);
    expect((await app.inject({ method: "DELETE", url: `/api/upload-sessions/${sessionId}` })).statusCode).toBe(200);
    expect((await prisma.uploadSession.findUnique({ where: { id: sessionId } })).storageReservationBytes).toBe(0n);
  });
});
