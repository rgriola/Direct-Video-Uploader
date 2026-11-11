import { createHash, randomUUID } from "node:crypto";
import { constants, createReadStream } from "node:fs";
import {
  link,
  lstat,
  mkdir,
  open,
  opendir,
  readFile,
  readdir,
  realpath,
  rm,
  statfs,
  unlink,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Readable, Transform, Writable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";

const KEY_PREFIX = "originals";
const SESSION_DIRECTORY = ".uploads";
const SESSION_LOCK = ".busy";
const PARTIAL_PART_PREFIX = ".partial-";
const STORAGE_IDENTITY_FILE = ".dvu-storage-id";
const MAX_PART_NUMBER = 10_000;
export const MAX_PART_SIZE_BYTES = 50 * 1024 * 1024;
const DEFAULT_LOCAL_STORAGE_ROOT = path.resolve(fileURLToPath(new URL("../../../.local-storage", import.meta.url)));
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const IDENTIFIER_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const NOFOLLOW = constants.O_NOFOLLOW;

export class StorageError extends Error {
  constructor(message, options) {
    super(message, options);
    this.name = "StorageError";
    if (options?.code) this.code = options.code;
  }
}

class StorageBusyError extends StorageError {
  constructor(options) {
    super("Upload session is busy", { ...options, code: "SESSION_BUSY" });
    this.name = "StorageBusyError";
  }
}

export function resolveLocalStorageRoot({
  root = process.env.STORAGE_LOCAL_ROOT,
  production = process.env.NODE_ENV === "production",
} = {}) {
  if (root == null || root === "") {
    if (production) throw new StorageError("STORAGE_LOCAL_ROOT is required in production");
    return DEFAULT_LOCAL_STORAGE_ROOT;
  }
  if (typeof root !== "string" || !path.isAbsolute(root)) {
    throw new StorageError("STORAGE_LOCAL_ROOT must be an absolute path");
  }
  return path.normalize(root);
}

function assertIdentifier(value, label) {
  if (typeof value !== "string" || !IDENTIFIER_PATTERN.test(value) || value === "." || value === "..") {
    throw new StorageError(`${label} is not a valid storage identifier`);
  }
  return value;
}

function parseStorageKey(key) {
  if (typeof key !== "string" || key.includes("\\") || key.startsWith("/")) {
    throw new StorageError("Storage key is invalid");
  }

  const segments = key.split("/");
  if (segments.length !== 5 || segments[0] !== KEY_PREFIX) {
    throw new StorageError("Storage key is invalid");
  }
  assertIdentifier(segments[1], "Owner ID");
  assertIdentifier(segments[2], "Asset ID");
  assertIdentifier(segments[3], "Clip ID");
  const objectIds = segments[4].split(".");
  if (![1, 2].includes(objectIds.length) || objectIds.some(id => !UUID_PATTERN.test(id))) {
    throw new StorageError("Storage key is invalid");
  }
  return segments;
}

export function storageIdentityForKey(key) {
  const objectIds = parseStorageKey(key).at(-1).split(".");
  return objectIds.length === 2 ? objectIds[0].toLowerCase() : null;
}

function assertWithinRoot(root, candidate) {
  const relative = path.relative(root, candidate);
  if (relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new StorageError("Storage path escapes the configured root");
  }
}

async function ensureDirectory(root, segments, { create = false } = {}) {
  let current = root;
  for (const segment of segments) {
    current = path.join(current, segment);
    if (create) {
      try {
        await mkdir(current, { mode: 0o700 });
      } catch (error) {
        if (error.code !== "EEXIST") throw error;
      }
    }

    const info = await lstat(current);
    if (!info.isDirectory() || info.isSymbolicLink()) {
      throw new StorageError("Storage path contains a non-directory or symbolic link");
    }
    const canonical = await realpath(current);
    assertWithinRoot(root, canonical);
    current = canonical;
  }
  return current;
}

async function existingFile(root, segments) {
  let parent;
  try {
    parent = await ensureDirectory(root, segments.slice(0, -1));
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
  const candidate = path.join(parent, segments.at(-1));
  assertWithinRoot(root, candidate);

  let info;
  try {
    info = await lstat(candidate);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
  if (!info.isFile() || info.isSymbolicLink()) {
    throw new StorageError("Storage object is not a regular file");
  }

  const canonical = await realpath(candidate);
  assertWithinRoot(root, canonical);
  return canonical;
}

async function readStorageIdentity(root) {
  const filePath = await existingFile(root, [STORAGE_IDENTITY_FILE]);
  if (!filePath) return null;
  const handle = await open(filePath, constants.O_RDONLY | NOFOLLOW);
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.size > 64) {
      throw new StorageError("Local storage identity is invalid", { code: "STORAGE_UNAVAILABLE" });
    }
    const identity = (await handle.readFile("utf8")).trim();
    if (!UUID_PATTERN.test(identity)) {
      throw new StorageError("Local storage identity is invalid", { code: "STORAGE_UNAVAILABLE" });
    }
    return identity.toLowerCase();
  } finally {
    await handle.close();
  }
}

async function initializeStorageIdentity(root) {
  const current = await readStorageIdentity(root);
  if (current) return current;

  const identity = randomUUID();
  const temporaryPath = path.join(root, `.dvu-storage-id-${identity}`);
  let handle;
  try {
    handle = await open(temporaryPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW, 0o600);
    await handle.writeFile(`${identity}\n`);
    await handle.sync();
    await handle.close();
    handle = null;
    try {
      await link(temporaryPath, path.join(root, STORAGE_IDENTITY_FILE));
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
    }
  } finally {
    try {
      await handle?.close();
    } finally {
      try {
        await unlink(temporaryPath);
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
    }
  }
  const registered = await readStorageIdentity(root);
  if (!registered) throw new StorageError("Local storage identity could not be initialized");
  return registered;
}

function validatePartNumber(partNumber) {
  if (!Number.isSafeInteger(partNumber) || partNumber < 1 || partNumber > MAX_PART_NUMBER) {
    throw new StorageError(`Part number must be between 1 and ${MAX_PART_NUMBER}`);
  }
  return String(partNumber).padStart(5, "0");
}

function validateUploadId(uploadId) {
  if (typeof uploadId !== "string" || !UUID_PATTERN.test(uploadId)) {
    throw new StorageError("Upload ID is invalid");
  }
  return uploadId;
}

function asReadable(source) {
  if (Buffer.isBuffer(source) || source instanceof Uint8Array) {
    return Readable.from([source]);
  }
  if (source && typeof source.pipe === "function") return source;
  throw new StorageError("Upload part must be a byte buffer or readable stream");
}

function parseExpectedSize(size) {
  if (size == null) return null;
  if (typeof size === "bigint" && size >= 0n) return size;
  if (typeof size === "number" && Number.isSafeInteger(size) && size >= 0) return BigInt(size);
  if (typeof size === "string" && /^\d+$/.test(size)) return BigInt(size);
  throw new StorageError("Expected size must be a non-negative integer");
}

function createPartSizeLimiter(expectedSizeBytes) {
  let bytes = 0;
  return new Transform({
    transform(chunk, _encoding, callback) {
      let buffer;
      try {
        buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      } catch (error) {
        callback(new StorageError("Upload parts must contain byte data", { cause: error }));
        return;
      }
      bytes += buffer.length;
      if (bytes > MAX_PART_SIZE_BYTES) {
        callback(new StorageError(`Upload parts cannot exceed ${MAX_PART_SIZE_BYTES} bytes`, { code: "PART_TOO_LARGE" }));
        return;
      }
      if (expectedSizeBytes != null && bytes > expectedSizeBytes) {
        callback(new StorageError("Upload part size does not match the signed size", { code: "PART_SIZE_MISMATCH" }));
        return;
      }
      callback(null, buffer);
    },
    flush(callback) {
      if (expectedSizeBytes != null && bytes !== expectedSizeBytes) {
        callback(new StorageError("Upload part size does not match the signed size", { code: "PART_SIZE_MISMATCH" }));
        return;
      }
      callback();
    },
  });
}

async function acquireSessionLock(sessionPath, lockName = SESSION_LOCK) {
  const lockPath = path.join(sessionPath, lockName);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    let handle;
    try {
      handle = await open(
        lockPath,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW,
        0o600,
      );
      await handle.writeFile(JSON.stringify({ host: os.hostname(), pid: process.pid }));
      await handle.close();
      return async () => {
        let lock;
        try {
          lock = JSON.parse(await readFile(lockPath, "utf8"));
        } catch (error) {
          if (error.code === "ENOENT") return;
          throw error;
        }
        if (lock.host !== os.hostname() || lock.pid !== process.pid) {
          throw new StorageError("Upload session lock ownership changed");
        }
        await unlink(lockPath);
      };
    } catch (error) {
      const cleanupErrors = [];
      if (handle) {
        try {
          await handle.close();
        } catch (closeError) {
          cleanupErrors.push(closeError);
        }
        try {
          await unlink(lockPath);
        } catch (unlinkError) {
          if (unlinkError.code !== "ENOENT") cleanupErrors.push(unlinkError);
        }
      }
      if (cleanupErrors.length) {
        throw new AggregateError(
          [error, ...cleanupErrors],
          "Could not acquire or clean up the upload lock",
          { cause: error },
        );
      }
      if (error.code !== "EEXIST" || handle) throw error;
      await clearStaleSessionLock(lockPath);
    }
  }
  throw new StorageBusyError();
}

async function clearStaleSessionLock(lockPath) {
  const recoveryPath = `${lockPath}.recovery`;
  let recoveryHandle;
  try {
    recoveryHandle = await open(
      recoveryPath,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW,
      0o600,
    );
  } catch (error) {
    if (error.code === "EEXIST") throw new StorageBusyError();
    throw error;
  }

  let recoveryError;
  try {
    await recoveryHandle.close();
    let lock;
    try {
      lock = JSON.parse(await readFile(lockPath, "utf8"));
    } catch (error) {
      if (error.code === "ENOENT") return;
      throw new StorageError("Upload session lock is invalid", { cause: error });
    }
    if (lock.host !== os.hostname() || !Number.isSafeInteger(lock.pid) || lock.pid < 1) {
      throw new StorageBusyError();
    }
    try {
      process.kill(lock.pid, 0);
    } catch (error) {
      if (error.code !== "ESRCH") throw new StorageBusyError({ cause: error });
      await unlink(lockPath);
      return;
    }
    throw new StorageBusyError();
  } catch (error) {
    recoveryError = error;
    throw error;
  } finally {
    try {
      await unlink(recoveryPath);
    } catch (releaseError) {
      if (releaseError.code !== "ENOENT") {
        if (recoveryError) {
          throw new AggregateError(
            [recoveryError, releaseError],
            "Upload lock recovery and cleanup both failed",
            { cause: recoveryError },
          );
        }
        throw releaseError;
      }
    }
  }
}

async function assertSessionUnlocked(sessionPath) {
  const lockPath = path.join(sessionPath, SESSION_LOCK);
  try {
    await lstat(lockPath);
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  await clearStaleSessionLock(lockPath);
  try {
    await lstat(lockPath);
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  throw new StorageBusyError();
}

function isProcessAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    throw error;
  }
}

async function readPart(filePath, partNumber) {
  const hash = createHash("sha256");
  let sizeBytes = 0n;
  for await (const chunk of createReadStream(filePath, { flags: constants.O_RDONLY | NOFOLLOW })) {
    hash.update(chunk);
    sizeBytes += BigInt(chunk.length);
  }
  return { partNumber, sizeBytes: sizeBytes.toString(), sha256: hash.digest("hex") };
}

async function removeStalePartials(directory) {
  let entries;
  try {
    entries = await readdir(directory);
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  for (const name of entries) {
    const match = /^\.partial-(\d+)-/.exec(name);
    if (!match || isProcessAlive(Number(match[1]))) continue;
    const filePath = path.join(directory, name);
    const info = await lstat(filePath);
    if (!info.isFile() || info.isSymbolicLink()) {
      throw new StorageError("Partial storage path is not a regular file");
    }
    await unlink(filePath);
  }
}

function hasActivePartials(entries) {
  return entries.some(name => {
    const match = /^\.partial-(\d+)-/.exec(name);
    return match && isProcessAlive(Number(match[1]));
  });
}

export function createLocalStorageDriver({ root = resolveLocalStorageRoot() } = {}) {
  if (typeof root !== "string" || !path.isAbsolute(root)) {
    throw new StorageError("Local storage root must be an absolute path");
  }
  if (typeof NOFOLLOW !== "number") {
    throw new StorageError("This platform does not support no-follow file opens");
  }

  const configuredRoot = path.resolve(root);
  let canonicalRoot;

  async function getRoot({ create = true } = {}) {
    if (canonicalRoot) return canonicalRoot;
    if (create) await mkdir(configuredRoot, { recursive: true, mode: 0o700 });
    try {
      canonicalRoot = await realpath(configuredRoot);
    } catch (error) {
      if (error.code === "ENOENT") {
        throw new StorageError("Local storage root is unavailable", { cause: error, code: "STORAGE_UNAVAILABLE" });
      }
      throw error;
    }
    return canonicalRoot;
  }

  async function assertStorageLocation(key, { required = true } = {}) {
    const expectedIdentity = storageIdentityForKey(key);
    if (!expectedIdentity) {
      if (required) throw new StorageError("Original has no verified storage location", { code: "STORAGE_UNAVAILABLE" });
      return;
    }
    const rootPath = await getRoot({ create: false });
    const identity = await readStorageIdentity(rootPath);
    if (!identity || identity !== expectedIdentity) {
      throw new StorageError("Local storage location is unavailable or does not match the original", {
        code: "STORAGE_UNAVAILABLE",
      });
    }
  }

  async function measureFiles(rootPath, directory, device) {
    let names;
    try {
      names = await readdir(directory);
    } catch (error) {
      if (directory !== rootPath && error.code === "ENOENT") return 0n;
      throw error;
    }
    let sizeBytes = 0n;
    for (const name of names) {
      const candidate = path.join(directory, name);
      let info;
      try {
        info = await lstat(candidate, { bigint: true });
      } catch (error) {
        if (error.code === "ENOENT") continue;
        throw error;
      }
      if (info.dev !== device) {
        throw new StorageError("Original storage contains another mounted filesystem", {
          code: "STORAGE_UNAVAILABLE",
        });
      }
      if (info.isSymbolicLink()) {
        throw new StorageError("Storage capacity cannot be measured through symbolic links", {
          code: "STORAGE_UNAVAILABLE",
        });
      }
      if (info.isFile()) {
        sizeBytes += info.size;
      } else if (info.isDirectory()) {
        let canonical;
        try {
          canonical = await realpath(candidate);
        } catch (error) {
          if (error.code === "ENOENT") continue;
          throw error;
        }
        assertWithinRoot(rootPath, canonical);
        sizeBytes += await measureFiles(rootPath, canonical, device);
      } else {
        throw new StorageError("Storage capacity contains an unsupported file type", {
          code: "STORAGE_UNAVAILABLE",
        });
      }
    }
    return sizeBytes;
  }

  async function getSessionDirectory(uploadId, { create = false } = {}) {
    validateUploadId(uploadId);
    const rootPath = await getRoot();
    let base;
    try {
      base = await ensureDirectory(rootPath, [SESSION_DIRECTORY], { create });
    } catch (error) {
      if (!create && error.code === "ENOENT") return null;
      throw error;
    }
    const sessionPath = path.join(base, uploadId);
    if (create) {
      await mkdir(sessionPath, { mode: 0o700 });
      return sessionPath;
    }
    try {
      const info = await lstat(sessionPath);
      if (!info.isDirectory() || info.isSymbolicLink()) {
        throw new StorageError("Upload session is not a regular directory");
      }
      const canonical = await realpath(sessionPath);
      assertWithinRoot(rootPath, canonical);
      return canonical;
    } catch (error) {
      if (error.code === "ENOENT") return null;
      throw error;
    }
  }

  async function readManifest(uploadId, sessionPath) {
    const manifestPath = path.join(sessionPath, "manifest.json");
    let handle;
    try {
      handle = await open(manifestPath, constants.O_RDONLY | NOFOLLOW);
      const raw = await handle.readFile("utf8");
      const manifest = JSON.parse(raw);
      if (manifest == null || typeof manifest !== "object" || Array.isArray(manifest)) {
        throw new StorageError("Upload manifest is invalid");
      }
      if (manifest.uploadId !== uploadId) throw new StorageError("Upload manifest does not match its session");
      const keySegments = parseStorageKey(manifest.key);
      await assertStorageLocation(manifest.key, { required: false });
      if (manifest.ownerId !== keySegments[1]
        || manifest.assetId !== keySegments[2]
        || manifest.clipId !== keySegments[3]) {
        throw new StorageError("Upload manifest identifiers do not match its storage key");
      }
      return manifest;
    } catch (error) {
      if (error.code === "ENOENT") throw new StorageError("Upload session not found", { cause: error });
      if (error instanceof SyntaxError) throw new StorageError("Upload manifest is invalid", { cause: error });
      throw error;
    } finally {
      await handle?.close();
    }
  }

  async function assertTrackedUploadContents(uploadId, sessionPath) {
    let hasParts = false;
    let hasSessionLock = false;
    for await (const entry of await opendir(sessionPath)) {
      if (entry.name === "parts" && entry.isDirectory()) {
        hasParts = true;
      } else if (entry.name === ".busy.recovery") {
        throw new StorageBusyError();
      } else if (entry.name === SESSION_LOCK && entry.isFile()) {
        hasSessionLock = true;
      } else if (!["manifest.json", SESSION_LOCK].includes(entry.name) || !entry.isFile()) {
        throw new StorageError("Unexpected upload session contents require manual review", {
          code: "STORAGE_UNAVAILABLE",
        });
      }
    }
    if (hasSessionLock) await assertSessionUnlocked(sessionPath);
    if (!hasParts) return;

    const rootPath = await getRoot({ create: false });
    const partsPath = await ensureDirectory(rootPath, [SESSION_DIRECTORY, uploadId, "parts"]);
    const locks = [];
    let count = 0;
    for await (const entry of await opendir(partsPath)) {
      count += 1;
      if (count > MAX_PART_NUMBER * 3 || !entry.isFile()) {
        throw new StorageError("Unexpected upload part contents require manual review", {
          code: "STORAGE_UNAVAILABLE",
        });
      }
      const part = /^(\d{5})$/.exec(entry.name);
      const lock = /^\.part-(\d{5})(\.recovery)?$/.exec(entry.name);
      const partial = /^\.partial-(\d+)-(\d{5})-(.+)$/.exec(entry.name);
      const number = Number(part?.[1] || lock?.[1] || partial?.[2]);
      if (!Number.isSafeInteger(number) || number < 1 || number > MAX_PART_NUMBER
        || (partial && (!Number.isSafeInteger(Number(partial[1])) || Number(partial[1]) < 1
          || !UUID_PATTERN.test(partial[3])))) {
        throw new StorageError("Unexpected upload part contents require manual review", {
          code: "STORAGE_UNAVAILABLE",
        });
      }
      if (lock?.[2]) throw new StorageBusyError();
      if (lock) locks.push(path.join(partsPath, entry.name));
    }
    for (const lockPath of locks) await clearStaleSessionLock(lockPath);
  }

  async function getSession(uploadId) {
    const sessionPath = await getSessionDirectory(uploadId);
    if (!sessionPath) throw new StorageError("Upload session not found");
    const manifest = await readManifest(uploadId, sessionPath);
    return { sessionPath, manifest };
  }

  async function listPartFiles(uploadId) {
    await getSession(uploadId);
    const rootPath = await getRoot();
    const partsPath = await ensureDirectory(rootPath, [SESSION_DIRECTORY, uploadId, "parts"])
      .catch(error => {
        if (error.code === "ENOENT") return null;
        throw error;
      });
    if (!partsPath) return [];
    const names = (await readdir(partsPath))
      .filter(name => /^\d{5}$/.test(name))
      .sort((left, right) => Number(left) - Number(right));
    const files = [];
    for (const name of names) {
      const filePath = await existingFile(rootPath, [SESSION_DIRECTORY, uploadId, "parts", name]);
      if (filePath) files.push({ partNumber: Number(name), filePath });
    }
    return files;
  }

  async function openRegularFile(key) {
    const segments = parseStorageKey(key);
    await assertStorageLocation(key, { required: false });
    const rootPath = await getRoot();
    const filePath = await existingFile(rootPath, segments);
    if (!filePath) return null;

    const handle = await open(filePath, constants.O_RDONLY | NOFOLLOW);
    try {
      const info = await handle.stat({ bigint: true });
      if (!info.isFile()) throw new StorageError("Storage object is not a regular file");
      return { handle, info };
    } catch (error) {
      await handle.close();
      throw error;
    }
  }

  return {
    async getCapacitySnapshot({ create = true } = {}) {
      try {
        const rootPath = await getRoot({ create });
        const rootInfo = await lstat(rootPath, { bigint: true });
        if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) {
          throw new StorageError("Local storage root is unavailable", { code: "STORAGE_UNAVAILABLE" });
        }
        const identity = await readStorageIdentity(rootPath);
        const usedBytes = await measureFiles(rootPath, rootPath, rootInfo.dev);
        const filesystem = await statfs(rootPath, { bigint: true });
        const hasEntries = (await readdir(rootPath)).length > 0;
        const currentRoot = await lstat(rootPath, { bigint: true });
        if (!currentRoot.isDirectory() || currentRoot.isSymbolicLink()
          || currentRoot.dev !== rootInfo.dev || currentRoot.ino !== rootInfo.ino
          || await readStorageIdentity(rootPath) !== identity) {
          throw new StorageError("Local storage location changed during capacity measurement", {
            code: "STORAGE_UNAVAILABLE",
          });
        }
        if (filesystem.bsize <= 0n || filesystem.bavail < 0n) {
          throw new StorageError("Storage free space is invalid", { code: "STORAGE_UNAVAILABLE" });
        }
        return { identity, hasEntries, usedBytes, availableBytes: filesystem.bavail * filesystem.bsize };
      } catch (error) {
        if (error instanceof StorageError && error.code === "STORAGE_UNAVAILABLE") throw error;
        throw new StorageError("Original storage capacity could not be verified", {
          cause: error,
          code: "STORAGE_UNAVAILABLE",
        });
      }
    },

    async createUpload({ ownerId, assetId, clipId }) {
      assertIdentifier(ownerId, "Owner ID");
      assertIdentifier(assetId, "Asset ID");
      assertIdentifier(clipId, "Clip ID");

      const rootPath = await getRoot();
      const storageIdentity = await initializeStorageIdentity(rootPath);
      const uploadsPath = await ensureDirectory(rootPath, [SESSION_DIRECTORY], { create: true });
      const uploadId = randomUUID();
      const sessionPath = path.join(uploadsPath, uploadId);
      await mkdir(sessionPath, { mode: 0o700 });

      const key = `${KEY_PREFIX}/${ownerId}/${assetId}/${clipId}/${storageIdentity}.${randomUUID()}`;
      const manifest = JSON.stringify({ uploadId, ownerId, assetId, clipId, key });
      try {
        const handle = await open(
          path.join(sessionPath, "manifest.json"),
          constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW,
          0o600,
        );
        try {
          await handle.writeFile(manifest);
        } finally {
          await handle.close();
        }
      } catch (error) {
        await rm(sessionPath, { recursive: true, force: true });
        throw error;
      }
      return { uploadId, key };
    },

    async assertStorageLocation(key) {
      await assertStorageLocation(key);
    },

    async hasUpload(uploadId) {
      return Boolean(await getSessionDirectory(uploadId));
    },

    async assertUploadReferences(uploadId, { ownerId, assetId, clipId, storageKey }) {
      const sessionPath = await getSessionDirectory(uploadId);
      if (!sessionPath) return false;
      const manifest = await readManifest(uploadId, sessionPath);
      if (manifest.ownerId !== ownerId || manifest.assetId !== assetId
        || manifest.clipId !== clipId || manifest.key !== storageKey) {
        throw new StorageError("Upload manifest does not match its database record", {
          code: "STORAGE_UNAVAILABLE",
        });
      }
      await assertTrackedUploadContents(uploadId, sessionPath);
      return true;
    },

    async openUploadInventory() {
      const rootPath = await getRoot({ create: false });
      const rootInfo = await lstat(rootPath, { bigint: true });
      const identity = await readStorageIdentity(rootPath);
      // A fresh root is only marked by its first upload, so it has nothing to inventory yet.
      if (!identity && rootInfo.isDirectory() && !rootInfo.isSymbolicLink()
        && (await readdir(rootPath)).length === 0) {
        return null;
      }
      if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink() || !identity) {
        throw new StorageError("Original upload inventory requires a verified storage root", {
          code: "STORAGE_UNAVAILABLE",
        });
      }
      let uploadsPath;
      try {
        uploadsPath = await ensureDirectory(rootPath, [SESSION_DIRECTORY]);
      } catch (error) {
        if (error.code === "ENOENT") return null;
        throw error;
      }
      const uploadsInfo = await lstat(uploadsPath, { bigint: true });
      return {
        directory: await opendir(uploadsPath),
        identity,
        device: rootInfo.dev,
        inode: rootInfo.ino,
        uploadsDevice: uploadsInfo.dev,
        uploadsInode: uploadsInfo.ino,
      };
    },

    async assertUploadInventory(inventory) {
      const rootPath = await getRoot({ create: false });
      const rootInfo = await lstat(rootPath, { bigint: true });
      const uploadsPath = await ensureDirectory(rootPath, [SESSION_DIRECTORY]);
      const uploadsInfo = await lstat(uploadsPath, { bigint: true });
      if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()
        || rootInfo.dev !== inventory.device || rootInfo.ino !== inventory.inode
        || uploadsInfo.dev !== inventory.uploadsDevice || uploadsInfo.ino !== inventory.uploadsInode
        || await readStorageIdentity(rootPath) !== inventory.identity) {
        throw new StorageError("Original upload inventory storage root changed", {
          code: "STORAGE_UNAVAILABLE",
        });
      }
    },

    async uploadPart(uploadId, partNumber, body, { expectedSizeBytes, commitPart } = {}) {
      const part = validatePartNumber(partNumber);
      const source = asReadable(body);
      if (commitPart != null && typeof commitPart !== "function") {
        throw new TypeError("Part publication requires a callback");
      }
      const expectedSize = parseExpectedSize(expectedSizeBytes);
      if (expectedSize != null && expectedSize > BigInt(MAX_PART_SIZE_BYTES)) {
        throw new StorageError(`Upload parts cannot exceed ${MAX_PART_SIZE_BYTES} bytes`, { code: "PART_TOO_LARGE" });
      }
      const { sessionPath, manifest } = await getSession(uploadId);
      const rootPath = await getRoot();
      const currentSession = await getSessionDirectory(uploadId);
      if (!currentSession || currentSession !== sessionPath) {
        throw new StorageError("Upload session not found");
      }
      const candidatePartsPath = path.join(currentSession, "parts");
      try {
        await mkdir(candidatePartsPath, { mode: 0o700 });
      } catch (error) {
        if (error.code !== "EEXIST") throw error;
      }
      const partsPath = await ensureDirectory(rootPath, [SESSION_DIRECTORY, uploadId, "parts"]);
      const releasePart = await acquireSessionLock(partsPath, `.part-${part}`);
      let workError;
      try {
        const partPath = path.join(partsPath, part);
        const temporaryPath = path.join(partsPath, `${PARTIAL_PART_PREFIX}${process.pid}-${part}-${randomUUID()}`);
        const handle = await open(
          temporaryPath,
          constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW,
          0o600,
        );
        const hash = createHash("sha256");
        let sizeBytes = 0n;
        const meter = new Transform({
          transform(chunk, _encoding, callback) {
            hash.update(chunk);
            sizeBytes += BigInt(chunk.length);
            callback(null, chunk);
          },
        });
        try {
          // Completion either sees this temporary part or blocks the writer with the session lock.
          await assertSessionUnlocked(sessionPath);
          await pipeline(
            source,
            createPartSizeLimiter(expectedSize == null ? null : Number(expectedSize)),
            meter,
            handle.createWriteStream({ autoClose: true }),
          );
          const result = { partNumber, sizeBytes: sizeBytes.toString(), sha256: hash.digest("hex") };
          const assertMatchingPart = async filePath => {
            const existing = await readPart(filePath, partNumber);
            if (existing.sizeBytes !== result.sizeBytes || existing.sha256 !== result.sha256) {
              throw new StorageError(`Upload part ${partNumber} already exists with different content`, {
                code: "PART_CONFLICT",
              });
            }
          };
          const existingPath = await existingFile(rootPath, [SESSION_DIRECTORY, uploadId, "parts", part]);
          if (existingPath) await assertMatchingPart(existingPath);
          let published = false;
          const publish = async () => {
            if (published) throw new Error("Upload part was already published");
            await assertStorageLocation(manifest.key, { required: false });
            try {
              await link(temporaryPath, partPath);
            } catch (error) {
              if (error.code !== "EEXIST") throw error;
              await assertMatchingPart(partPath);
            }
            published = true;
          };
          if (commitPart) {
            await commitPart(result, publish);
          } else {
            await publish();
          }
          if (!published) throw new Error("Upload part was not published");
          return result;
        } finally {
          try {
            await handle.close();
          } finally {
            try {
              await unlink(temporaryPath);
            } catch (error) {
              if (error.code !== "ENOENT") throw error;
            }
          }
        }
      } catch (error) {
        workError = error;
        throw error;
      } finally {
        try {
          await releasePart();
        } catch (releaseError) {
          if (workError) {
            throw new AggregateError(
              [workError, releaseError],
              "Upload part and lock release both failed",
              { cause: workError },
            );
          }
          throw releaseError;
        }
      }
    },

    async listParts(uploadId) {
      const parts = [];
      for (const { partNumber, filePath } of await listPartFiles(uploadId)) {
        parts.push(await readPart(filePath, partNumber));
      }
      return parts;
    },

    async listPartNumbers(uploadId) {
      return (await listPartFiles(uploadId)).map(part => part.partNumber);
    },

    async recoverUpload(uploadId, { preserveUnattributedAssemblies = false } = {}) {
      const { sessionPath, manifest } = await getSession(uploadId);
      const release = await acquireSessionLock(sessionPath);
      try {
        const rootPath = await getRoot();
        await removeStalePartials(path.join(sessionPath, "parts"));
        const segments = parseStorageKey(manifest.key);
        let destinationDirectory;
        try {
          destinationDirectory = await ensureDirectory(rootPath, segments.slice(0, -1));
        } catch (error) {
          if (error.code !== "ENOENT") throw error;
        }
        if (destinationDirectory && !preserveUnattributedAssemblies) {
          await removeStalePartials(destinationDirectory);
        }
      } finally {
        await release();
      }
      return this.listParts(uploadId);
    },

    async withCompletionLock(uploadId, work) {
      validateUploadId(uploadId);
      if (typeof work !== "function") throw new TypeError("Completion lock requires a callback");
      const uploadsPath = await ensureDirectory(await getRoot(), [SESSION_DIRECTORY], { create: true });
      let release;
      try {
        release = await acquireSessionLock(uploadsPath, `.completion-${uploadId}`);
      } catch (error) {
        if (error instanceof StorageBusyError) return { acquired: false };
        throw error;
      }

      let workError;
      try {
        return { acquired: true, value: await work() };
      } catch (error) {
        workError = error;
        throw error;
      } finally {
        try {
          await release();
        } catch (releaseError) {
          if (workError) {
            throw new AggregateError(
              [workError, releaseError],
              "Upload completion and lock release both failed",
              { cause: workError },
            );
          }
          throw releaseError;
        }
      }
    },

    async completeUpload(uploadId, { expectedSha256, expectedSizeBytes } = {}) {
      if (expectedSha256 != null
        && (typeof expectedSha256 !== "string" || !/^[a-f0-9]{64}$/i.test(expectedSha256))) {
        throw new StorageError("Expected SHA-256 must contain 64 hexadecimal characters");
      }
      await this.recoverUpload(uploadId);
      const expectedSize = parseExpectedSize(expectedSizeBytes);
      const rootPath = await getRoot();
      const { sessionPath, manifest } = await getSession(uploadId);
      const release = await acquireSessionLock(sessionPath);
      try {
        const partsPath = await ensureDirectory(rootPath, [SESSION_DIRECTORY, uploadId, "parts"]);
        const entries = await readdir(partsPath);
        if (hasActivePartials(entries)) {
          throw new StorageError("Upload parts are still being written", { code: "SESSION_BUSY" });
        }
        if (entries.some(name => name.startsWith(PARTIAL_PART_PREFIX))) {
          throw new StorageError("Stale upload parts require recovery");
        }
        const partNames = entries
          .filter(name => /^\d{5}$/.test(name))
          .sort((left, right) => Number(left) - Number(right));
        if (partNames.length === 0 || partNames.some((name, index) => Number(name) !== index + 1)) {
          throw new StorageError("Upload parts must be numbered consecutively starting at 1", { code: "INCOMPLETE_UPLOAD" });
        }

        const partPaths = [];
        for (const name of partNames) {
          const filePath = await existingFile(rootPath, [
            SESSION_DIRECTORY, uploadId, "parts", name,
          ]);
          if (!filePath) throw new StorageError(`Upload part ${Number(name)} is missing`);
          partPaths.push(filePath);
        }

        const keySegments = parseStorageKey(manifest.key);
        const destinationDirectory = await ensureDirectory(rootPath, keySegments.slice(0, -1), { create: true });
        const destinationPath = path.join(destinationDirectory, keySegments.at(-1));
        const temporaryPath = path.join(destinationDirectory, `${PARTIAL_PART_PREFIX}${process.pid}-${randomUUID()}`);
        const outputHandle = await open(
          temporaryPath,
          constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW,
          0o600,
        );
        const hash = createHash("sha256");
        let sizeBytes = 0n;
        let outputClosed = false;
        const meter = new Transform({
          transform(chunk, _encoding, callback) {
            if (expectedSize != null && sizeBytes + BigInt(chunk.length) > expectedSize) {
              callback(new StorageError("Completed upload size does not match the expected size", {
                code: "INTEGRITY_MISMATCH",
              }));
              return;
            }
            hash.update(chunk);
            sizeBytes += BigInt(chunk.length);
            callback(null, chunk);
          },
        });
        const source = Readable.from((async function* readParts() {
          for (const partPath of partPaths) {
            for await (const chunk of createReadStream(partPath, { flags: constants.O_RDONLY | NOFOLLOW })) {
              yield chunk;
            }
          }
        })());

        try {
          const output = new Writable({
            write(chunk, _encoding, callback) {
              (async () => {
                let offset = 0;
                while (offset < chunk.length) {
                  const { bytesWritten } = await outputHandle.write(
                    chunk,
                    offset,
                    chunk.length - offset,
                  );
                  if (bytesWritten === 0) throw new StorageError("Unable to write completed upload");
                  offset += bytesWritten;
                }
              })().then(() => callback(), callback);
            },
          });
          await pipeline(source, meter, output);
          await outputHandle.sync();
          await outputHandle.close();
          outputClosed = true;

          const sha256 = hash.digest("hex");
          if (expectedSize != null && sizeBytes !== expectedSize) {
            throw new StorageError("Completed upload size does not match the expected size", { code: "INTEGRITY_MISMATCH" });
          }
          if (expectedSha256 != null && sha256 !== expectedSha256.toLowerCase()) {
            throw new StorageError("Completed upload SHA-256 does not match the expected checksum", { code: "INTEGRITY_MISMATCH" });
          }

          await assertStorageLocation(manifest.key, { required: false });
          await link(temporaryPath, destinationPath);
          await unlink(temporaryPath);
          await rm(sessionPath, { recursive: true, force: true });
          return { key: manifest.key, sha256, sizeBytes: sizeBytes.toString() };
        } catch (error) {
          try {
            if (!outputClosed) await outputHandle.close();
          } finally {
            try {
              await unlink(temporaryPath);
            } catch (unlinkError) {
              if (unlinkError.code !== "ENOENT") throw unlinkError;
            }
          }
          throw error;
        }
      } finally {
        await release();
      }
    },

    async abortUpload(uploadId, options) {
      const sessionPath = await getSessionDirectory(uploadId);
      if (!sessionPath) return false;
      await this.recoverUpload(uploadId, options);
      const release = await acquireSessionLock(sessionPath);
      try {
        const partsPath = path.join(sessionPath, "parts");
        const entries = await readdir(partsPath).catch(error => {
          if (error.code === "ENOENT") return [];
          throw error;
        });
        if (hasActivePartials(entries)) {
          throw new StorageError("Upload parts are still being written", { code: "SESSION_BUSY" });
        }
        await rm(sessionPath, { recursive: true, force: false });
      } finally {
        await release();
      }
      return true;
    },

    async getReadStream(key, range) {
      const opened = await openRegularFile(key);
      if (!opened) throw new StorageError("Storage object not found");
      const { handle, info } = opened;

      if (range != null) {
        const { start, end } = range;
        if (!Number.isSafeInteger(start) || start < 0
          || !Number.isSafeInteger(end) || end < start || BigInt(end) >= info.size) {
          await handle.close();
          throw new StorageError("Read range is outside the storage object");
        }
        return handle.createReadStream({ start, end, autoClose: true });
      }
      return handle.createReadStream({ autoClose: true });
    },

    async delete(key) {
      const opened = await openRegularFile(key);
      if (!opened) return false;
      await opened.handle.close();
      const segments = parseStorageKey(key);
      await assertStorageLocation(key, { required: false });
      const filePath = await existingFile(await getRoot(), segments);
      if (!filePath) return false;
      await unlink(filePath);
      return true;
    },

    async stat(key) {
      const opened = await openRegularFile(key);
      if (!opened) return null;
      try {
        return {
          sizeBytes: opened.info.size.toString(),
          modifiedAt: opened.info.mtime.toISOString(),
        };
      } finally {
        await opened.handle.close();
      }
    },
  };
}
