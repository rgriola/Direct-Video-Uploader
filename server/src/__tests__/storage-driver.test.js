import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { link, mkdtemp, mkdir, rm, symlink, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { createStorageDriver, registerStorageDriver } from "../lib/storage/driver.js";
import {
  createLocalStorageDriver,
  resolveLocalStorageRoot,
  StorageError,
} from "../lib/storage/local-driver.js";

const temporaryDirectories = new Set();

async function createTemporaryDirectory() {
  const directory = await mkdtemp(path.join(os.tmpdir(), "dvu-storage-"));
  temporaryDirectories.add(directory);
  return directory;
}

async function readAll(stream) {
  const chunks = [];
  for await (const chunk of stream) chunks.push(chunk);
  return Buffer.concat(chunks);
}

afterEach(async () => {
  await Promise.all([...temporaryDirectories].map(directory => rm(directory, { recursive: true, force: true })));
  temporaryDirectories.clear();
});

describe("StorageDriver registry", () => {
  it("creates registered drivers and rejects unknown providers", () => {
    const name = `test-${randomUUID()}`;
    const methods = Object.fromEntries([
      "getCapacitySnapshot",
      "createUpload",
      "assertStorageLocation",
      "hasUpload",
      "uploadPart",
      "listParts",
      "listPartNumbers",
      "recoverUpload",
      "withCompletionLock",
      "completeUpload",
      "abortUpload",
      "getReadStream",
      "delete",
      "stat",
    ].map(method => [method, () => {}]));
    registerStorageDriver(name, options => ({ ...methods, options }));

    expect(createStorageDriver({ provider: name, root: "/tmp/storage" }).options)
      .toEqual({ root: "/tmp/storage" });
    expect(() => createStorageDriver({ provider: "unregistered" }))
      .toThrow('Storage driver "unregistered" is not registered');
  });

  it("rejects incomplete driver implementations", () => {
    const name = `test-${randomUUID()}`;
    registerStorageDriver(name, () => ({}));
    expect(() => createStorageDriver({ provider: name })).toThrow(/missing methods/);
    expect(() => registerStorageDriver(undefined, () => ({}))).toThrow(TypeError);
  });
});

describe("local storage driver", () => {
  it("can inspect capacity without creating a missing root", async () => {
    const root = path.join(await createTemporaryDirectory(), "missing");
    const driver = createLocalStorageDriver({ root });
    await expect(driver.getCapacitySnapshot({ create: false })).rejects.toMatchObject({ code: "STORAGE_UNAVAILABLE" });
    await expect(driver.getCapacitySnapshot()).resolves.toMatchObject({ hasEntries: false });
  });

  it("measures every file under the root conservatively and rejects symbolic links", async () => {
    const root = await createTemporaryDirectory();
    const driver = createLocalStorageDriver({ root });
    await mkdir(path.join(root, "nested"));
    await writeFile(path.join(root, "first"), "abc");
    await writeFile(path.join(root, "nested", "second"), "12345");
    await link(path.join(root, "first"), path.join(root, "nested", "hardlink"));

    const snapshot = await driver.getCapacitySnapshot();
    expect(snapshot.identity).toBeNull();
    expect(snapshot.hasEntries).toBe(true);
    expect(snapshot.usedBytes).toBe(11n);
    expect(snapshot.availableBytes).toBeGreaterThan(0n);

    await symlink(path.join(root, "first"), path.join(root, "link"));
    await expect(driver.getCapacitySnapshot()).rejects.toMatchObject({ code: "STORAGE_UNAVAILABLE" });
  });

  it("uses a development fallback but requires an explicit production root", () => {
    const expectedRoot = path.resolve(fileURLToPath(new URL("../../.local-storage", import.meta.url)));
    expect(resolveLocalStorageRoot({ root: "", production: false })).toBe(expectedRoot);
    const moduleUrl = new URL("../lib/storage/local-driver.js", import.meta.url).href;
    const script = `import { resolveLocalStorageRoot } from ${JSON.stringify(moduleUrl)};
      process.stdout.write(resolveLocalStorageRoot({ root: "", production: false }));`;
    const child = spawnSync(process.execPath, ["--input-type=module", "-e", script], {
      cwd: os.tmpdir(),
      encoding: "utf8",
    });
    expect(child.status, child.stderr).toBe(0);
    expect(child.stdout).toBe(expectedRoot);
    expect(() => resolveLocalStorageRoot({ root: "", production: true }))
      .toThrow("STORAGE_LOCAL_ROOT is required in production");
    expect(() => resolveLocalStorageRoot({ root: "relative/path", production: false }))
      .toThrow("STORAGE_LOCAL_ROOT must be an absolute path");
  });

  it("binds new originals to one storage root and refuses missing or different roots", async () => {
    const root = await createTemporaryDirectory();
    const otherRoot = await createTemporaryDirectory();
    const driver = createLocalStorageDriver({ root });
    const other = createLocalStorageDriver({ root: otherRoot });
    const { uploadId, key } = await driver.createUpload({ ownerId: "owner", assetId: "asset", clipId: "clip" });
    const otherSession = await other.createUpload({ ownerId: "owner", assetId: "asset", clipId: "clip" });

    await expect(driver.assertStorageLocation(key)).resolves.toBeUndefined();
    await expect(other.assertStorageLocation(key)).rejects.toThrow("does not match");
    await expect(other.stat(key)).rejects.toThrow("does not match");
    const missingRoot = path.join(await createTemporaryDirectory(), "not-mounted");
    const missing = createLocalStorageDriver({ root: missingRoot });
    await expect(missing.assertStorageLocation(key)).rejects.toThrow("root is unavailable");
    const legacyKey = `originals/owner/asset/clip/${randomUUID()}`;
    await expect(driver.assertStorageLocation(legacyKey)).rejects.toThrow("no verified storage location");
    await expect(driver.stat(legacyKey)).resolves.toBeNull();
    await driver.abortUpload(uploadId);
    await other.abortUpload(otherSession.uploadId);
  });

  it("initializes the same storage identity when processes start uploads concurrently", async () => {
    const root = await createTemporaryDirectory();
    const drivers = Array.from({ length: 5 }, () => createLocalStorageDriver({ root }));
    const sessions = await Promise.all(drivers.map(driver =>
      driver.createUpload({ ownerId: "owner", assetId: "asset", clipId: "clip" })));
    const identities = sessions.map(session => session.key.split("/").at(-1).split(".")[0]);
    expect(new Set(identities).size).toBe(1);
    await Promise.all(sessions.map((session, index) => drivers[index].abortUpload(session.uploadId)));
  });

  it("stores consecutive parts, verifies integrity, supports ranges, and deletes the object", async () => {
    const driver = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    const { uploadId, key } = await driver.createUpload({
      ownerId: "owner-1",
      assetId: "asset-1",
      clipId: "clip-1",
    });

    expect(await driver.listPartNumbers(uploadId)).toEqual([]);
    await driver.uploadPart(uploadId, 1, Buffer.from("native "));
    await driver.uploadPart(uploadId, 2, Buffer.from("original"));
    expect(await driver.listPartNumbers(uploadId)).toEqual([1, 2]);
    const expectedSha256 = createHash("sha256").update("native original").digest("hex");
    expect(await driver.listParts(uploadId)).toEqual([
      {
        partNumber: 1,
        sizeBytes: "7",
        sha256: createHash("sha256").update("native ").digest("hex"),
      },
      {
        partNumber: 2,
        sizeBytes: "8",
        sha256: createHash("sha256").update("original").digest("hex"),
      },
    ]);
    const result = await driver.completeUpload(uploadId, {
      expectedSha256,
      expectedSizeBytes: 15,
    });

    expect(result).toMatchObject({ key, sizeBytes: "15" });
    expect(result.sha256).toMatch(/^[a-f0-9]{64}$/);
    expect(await driver.stat(key)).toMatchObject({ sizeBytes: "15" });
    expect(await readAll(await driver.getReadStream(key, { start: 7, end: 14 })))
      .toEqual(Buffer.from("original"));
    expect(await readAll(await driver.getReadStream(key))).toEqual(Buffer.from("native original"));
    await expect(driver.getReadStream(key, { start: 15, end: 16 })).rejects.toThrow(StorageError);
    await expect(driver.completeUpload(uploadId)).rejects.toThrow("Upload session not found");

    expect(await driver.delete(key)).toBe(true);
    expect(await driver.stat(key)).toBeNull();
    expect(await driver.delete(key)).toBe(false);
  });

  it("does not overwrite or remove an existing part when a duplicate is uploaded", async () => {
    const driver = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    const { uploadId, key } = await driver.createUpload({
      ownerId: "owner",
      assetId: "asset",
      clipId: "clip",
    });
    await driver.uploadPart(uploadId, 1, Buffer.from("first"));
    await expect(driver.uploadPart(uploadId, 1, Buffer.from("replacement")))
      .rejects.toThrow("already exists with different content");

    const result = await driver.completeUpload(uploadId, { expectedSizeBytes: 5 });
    expect(result.key).toBe(key);
    expect(await readAll(await driver.getReadStream(key))).toEqual(Buffer.from("first"));
  });

  it("accepts identical part retries and rejects different content for a stored part", async () => {
    const driver = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    const { uploadId } = await driver.createUpload({
      ownerId: "owner",
      assetId: "asset",
      clipId: "clip",
    });
    const first = await driver.uploadPart(uploadId, 1, Buffer.from("same"));
    await expect(driver.uploadPart(uploadId, 1, Buffer.from("same"))).resolves.toEqual(first);
    await expect(driver.uploadPart(uploadId, 1, Buffer.from("different")))
      .rejects.toThrow("already exists with different content");
    await driver.abortUpload(uploadId);
  });

  it("enforces the signed part size without retaining a short or oversized part", async () => {
    const driver = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    const { uploadId } = await driver.createUpload({ ownerId: "owner", assetId: "asset", clipId: "clip" });

    await expect(driver.uploadPart(uploadId, 1, Buffer.from("ab"), { expectedSizeBytes: 3 }))
      .rejects.toMatchObject({ code: "PART_SIZE_MISMATCH" });
    await expect(driver.uploadPart(uploadId, 1, Buffer.from("abcd"), { expectedSizeBytes: 3 }))
      .rejects.toMatchObject({ code: "PART_SIZE_MISMATCH" });
    expect(await driver.listParts(uploadId)).toEqual([]);
    await expect(driver.uploadPart(uploadId, 1, Buffer.from("abc"), { expectedSizeBytes: 3 }))
      .resolves.toMatchObject({ sizeBytes: "3" });
    await driver.abortUpload(uploadId);
  });

  it("serializes concurrent writes to the same part", async () => {
    const driver = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    const { uploadId } = await driver.createUpload({ ownerId: "owner", assetId: "asset", clipId: "clip" });
    let started;
    const reading = new Promise(resolve => { started = resolve; });
    const source = new Readable({
      read() {
        this._read = () => {};
        this.push(Buffer.from("part"));
        started();
      },
    });
    const first = driver.uploadPart(uploadId, 1, source);
    await reading;
    await expect(driver.uploadPart(uploadId, 1, Buffer.from("part")))
      .rejects.toMatchObject({ code: "SESSION_BUSY" });
    source.push(null);
    await expect(first).resolves.toMatchObject({ sizeBytes: "4" });
    await driver.abortUpload(uploadId);
  });

  it("rejects missing parts and checksum or size mismatches without publishing a partial object", async () => {
    const driver = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    const { uploadId } = await driver.createUpload({
      ownerId: "owner",
      assetId: "asset",
      clipId: "clip",
    });
    await driver.uploadPart(uploadId, 2, Buffer.from("part"));
    await expect(driver.completeUpload(uploadId)).rejects.toThrow("numbered consecutively");
    await driver.abortUpload(uploadId);

    const next = await driver.createUpload({ ownerId: "owner", assetId: "asset", clipId: "clip" });
    await driver.uploadPart(next.uploadId, 1, Buffer.from("part"));
    await expect(driver.completeUpload(next.uploadId, { expectedSizeBytes: 2 }))
      .rejects.toMatchObject({ code: "INTEGRITY_MISMATCH" });
    await expect(driver.stat(next.key)).resolves.toBeNull();
    await expect(driver.completeUpload(next.uploadId, { expectedSizeBytes: 99 }))
      .rejects.toThrow("size does not match");
    await expect(driver.stat(next.key)).resolves.toBeNull();
    await expect(driver.completeUpload(next.uploadId, { expectedSha256: "0".repeat(64) }))
      .rejects.toThrow("SHA-256 does not match");
    await expect(driver.stat(next.key)).resolves.toBeNull();
    await driver.abortUpload(next.uploadId);
  });

  it("reports missing objects when their parent directories have not been created", async () => {
    const driver = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    const { uploadId, key } = await driver.createUpload({
      ownerId: "owner",
      assetId: "asset",
      clipId: "clip",
    });

    await expect(driver.stat(key)).resolves.toBeNull();
    await expect(driver.delete(key)).resolves.toBe(false);
    await expect(driver.getReadStream(key)).rejects.toThrow("Storage object not found");
    await driver.abortUpload(uploadId);
  });

  it("does not publish an upload while another part is still streaming", async () => {
    const driver = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    const { uploadId, key } = await driver.createUpload({
      ownerId: "owner",
      assetId: "asset",
      clipId: "clip",
    });
    await driver.uploadPart(uploadId, 1, Buffer.from("first-"));

    let markStarted;
    let finishPart;
    const started = new Promise(resolve => { markStarted = resolve; });
    const finish = new Promise(resolve => { finishPart = resolve; });
    const source = Readable.from((async function* () {
      yield Buffer.from("second-");
      markStarted();
      await finish;
      yield Buffer.from("part");
    })());
    const pendingPart = driver.uploadPart(uploadId, 2, source);
    await started;
    try {
      await expect(driver.completeUpload(uploadId)).rejects.toThrow("still being written");
      await expect(driver.stat(key)).resolves.toBeNull();
    } finally {
      finishPart();
      await pendingPart;
    }

    await driver.completeUpload(uploadId);
    expect(await readAll(await driver.getReadStream(key))).toEqual(Buffer.from("first-second-part"));
  });

  it("rejects mutations while another process holds the session lock", async () => {
    const root = await createTemporaryDirectory();
    const driver = createLocalStorageDriver({ root });
    const { uploadId, key } = await driver.createUpload({
      ownerId: "owner",
      assetId: "asset",
      clipId: "clip",
    });
    const lockPath = path.join(root, ".uploads", uploadId, ".busy");
    await writeFile(lockPath, JSON.stringify({ host: os.hostname(), pid: process.pid }), { flag: "wx" });

    await expect(driver.uploadPart(uploadId, 1, Buffer.from("part"))).rejects.toThrow("session is busy");
    await expect(driver.completeUpload(uploadId)).rejects.toThrow("session is busy");
    await expect(driver.abortUpload(uploadId)).rejects.toThrow("session is busy");
    await unlink(lockPath);

    await driver.uploadPart(uploadId, 1, Buffer.from("part"));
    await driver.completeUpload(uploadId);
    expect(await readAll(await driver.getReadStream(key))).toEqual(Buffer.from("part"));
  });

  it("recovers stale locks and partial files after the owning process exits", async () => {
    const root = await createTemporaryDirectory();
    const driver = createLocalStorageDriver({ root });
    const { uploadId } = await driver.createUpload({
      ownerId: "owner",
      assetId: "asset",
      clipId: "clip",
    });
    const sessionPath = path.join(root, ".uploads", uploadId);
    const partsPath = path.join(sessionPath, "parts");
    await mkdir(partsPath);
    const stalePid = 999_999_999;
    await writeFile(path.join(sessionPath, ".busy"), JSON.stringify({ host: os.hostname(), pid: stalePid }));
    await writeFile(path.join(partsPath, `.partial-${stalePid}-00001-stale`), "partial");

    await expect(driver.recoverUpload(uploadId)).resolves.toEqual([]);
    await driver.uploadPart(uploadId, 1, Buffer.from("recovered"));
    await driver.abortUpload(uploadId);
  });

  it("holds the completion lock across driver instances after session cleanup", async () => {
    const root = await createTemporaryDirectory();
    const driver = createLocalStorageDriver({ root });
    const otherDriver = createLocalStorageDriver({ root });
    const { uploadId } = await driver.createUpload({ ownerId: "owner", assetId: "asset", clipId: "clip" });
    await driver.uploadPart(uploadId, 1, Buffer.from("part"));

    let releaseCompletion;
    let markStarted;
    const started = new Promise(resolve => { markStarted = resolve; });
    const gate = new Promise(resolve => { releaseCompletion = resolve; });
    const completion = driver.withCompletionLock(uploadId, async () => {
      await driver.completeUpload(uploadId);
      markStarted();
      await gate;
      return "done";
    });

    await started;
    try {
      await expect(otherDriver.withCompletionLock(uploadId, async () => "unexpected"))
        .resolves.toEqual({ acquired: false });
    } finally {
      releaseCompletion();
      await completion;
    }
    await expect(completion).resolves.toEqual({ acquired: true, value: "done" });
    await expect(otherDriver.withCompletionLock(uploadId, async () => "retry"))
      .resolves.toEqual({ acquired: true, value: "retry" });
  });

  it("recovers stale completion locks and releases them after callback errors", async () => {
    const root = await createTemporaryDirectory();
    const driver = createLocalStorageDriver({ root });
    const { uploadId } = await driver.createUpload({ ownerId: "owner", assetId: "asset", clipId: "clip" });
    const lockPath = path.join(root, ".uploads", `.completion-${uploadId}`);
    await writeFile(lockPath, JSON.stringify({ host: os.hostname(), pid: 999_999_999 }));

    await expect(driver.withCompletionLock(uploadId, async () => {
      throw new Error("completion failed");
    })).rejects.toThrow("completion failed");
    await expect(driver.withCompletionLock(uploadId, async () => "recovered"))
      .resolves.toEqual({ acquired: true, value: "recovered" });
    await driver.abortUpload(uploadId);
  });

  it("does not reclaim a lock while another recovery is in progress", async () => {
    const root = await createTemporaryDirectory();
    const driver = createLocalStorageDriver({ root });
    const { uploadId } = await driver.createUpload({ ownerId: "owner", assetId: "asset", clipId: "clip" });
    const lockPath = path.join(root, ".uploads", `.completion-${uploadId}`);
    const recoveryPath = `${lockPath}.recovery`;
    await writeFile(lockPath, JSON.stringify({ host: os.hostname(), pid: 999_999_999 }));
    await writeFile(recoveryPath, "");

    await expect(driver.withCompletionLock(uploadId, async () => "unexpected"))
      .resolves.toEqual({ acquired: false });
    await unlink(recoveryPath);
    await expect(driver.withCompletionLock(uploadId, async () => "recovered"))
      .resolves.toEqual({ acquired: true, value: "recovered" });
    await driver.abortUpload(uploadId);
  });

  it("reports a changed lock owner without deleting the replacement lock", async () => {
    const root = await createTemporaryDirectory();
    const driver = createLocalStorageDriver({ root });
    const { uploadId } = await driver.createUpload({ ownerId: "owner", assetId: "asset", clipId: "clip" });
    const lockPath = path.join(root, ".uploads", `.completion-${uploadId}`);

    await expect(driver.withCompletionLock(uploadId, async () => {
      await writeFile(lockPath, JSON.stringify({ host: os.hostname(), pid: 999_999_999 }));
    })).rejects.toThrow("lock ownership changed");
    await expect(driver.withCompletionLock(uploadId, async () => "recovered"))
      .resolves.toEqual({ acquired: true, value: "recovered" });
    await driver.abortUpload(uploadId);
  });

  it("allows 50 MB parts and rejects larger parts without leaving a published part", async () => {
    const driver = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    const { uploadId } = await driver.createUpload({
      ownerId: "owner",
      assetId: "asset",
      clipId: "clip",
    });
    const chunk = Buffer.alloc(1024 * 1024);
    await driver.uploadPart(uploadId, 1, Readable.from(Array(50).fill(chunk)));
    await expect(driver.uploadPart(uploadId, 2, Buffer.alloc(50 * 1024 * 1024 + 1)))
      .rejects.toThrow("Upload parts cannot exceed 52428800 bytes");
    await driver.uploadPart(uploadId, 2, Buffer.from("retry"));
    await driver.abortUpload(uploadId);
  }, 15_000);

  it("rejects traversal keys and symbolic-link storage paths", async () => {
    const root = await createTemporaryDirectory();
    const outside = path.join(await createTemporaryDirectory(), "outside");
    await mkdir(outside);
    const driver = createLocalStorageDriver({ root });
    const { uploadId, key } = await driver.createUpload({
      ownerId: "owner",
      assetId: "asset",
      clipId: "clip",
    });
    await driver.uploadPart(uploadId, 1, Buffer.from("content"));
    await driver.completeUpload(uploadId);

    await expect(driver.stat("originals/../outside/asset/clip/id")).rejects.toThrow(StorageError);
    await rm(path.join(root, "originals", "owner"), { recursive: true });
    await symlink(outside, path.join(root, "originals", "owner"), "dir");
    await expect(driver.stat(key)).rejects.toThrow("symbolic link");
  });

  it("aborts incomplete uploads and reports absent sessions", async () => {
    const driver = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    expect(await driver.abortUpload(randomUUID())).toBe(false);
    const { uploadId } = await driver.createUpload({
      ownerId: "owner",
      assetId: "asset",
      clipId: "clip",
    });
    expect(await driver.abortUpload(uploadId)).toBe(true);
    expect(await driver.abortUpload(uploadId)).toBe(false);
  });
});
