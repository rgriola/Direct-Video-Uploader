import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, rm, symlink, unlink, writeFile } from "node:fs/promises";
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
      "createUpload",
      "uploadPart",
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

  it("stores consecutive parts, verifies integrity, supports ranges, and deletes the object", async () => {
    const driver = createLocalStorageDriver({ root: await createTemporaryDirectory() });
    const { uploadId, key } = await driver.createUpload({
      ownerId: "owner-1",
      assetId: "asset-1",
      clipId: "clip-1",
    });

    await driver.uploadPart(uploadId, 1, Buffer.from("native "));
    await driver.uploadPart(uploadId, 2, Buffer.from("original"));
    const expectedSha256 = createHash("sha256").update("native original").digest("hex");
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
    await expect(driver.uploadPart(uploadId, 1, Buffer.from("replacement"))).rejects.toMatchObject({
      code: "EEXIST",
    });

    const result = await driver.completeUpload(uploadId, { expectedSizeBytes: 5 });
    expect(result.key).toBe(key);
    expect(await readAll(await driver.getReadStream(key))).toEqual(Buffer.from("first"));
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
    await writeFile(lockPath, "", { flag: "wx" });

    await expect(driver.uploadPart(uploadId, 1, Buffer.from("part"))).rejects.toThrow("session is busy");
    await expect(driver.completeUpload(uploadId)).rejects.toThrow("session is busy");
    await expect(driver.abortUpload(uploadId)).rejects.toThrow("session is busy");
    await unlink(lockPath);

    await driver.uploadPart(uploadId, 1, Buffer.from("part"));
    await driver.completeUpload(uploadId);
    expect(await readAll(await driver.getReadStream(key))).toEqual(Buffer.from("part"));
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
