import { createHash, randomUUID } from "node:crypto";
import { constants, createReadStream } from "node:fs";
import {
  link,
  lstat,
  mkdir,
  open,
  readdir,
  realpath,
  rm,
  unlink,
} from "node:fs/promises";
import path from "node:path";
import { Readable, Transform, Writable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";

const KEY_PREFIX = "originals";
const SESSION_DIRECTORY = ".uploads";
const SESSION_LOCK = ".busy";
const PARTIAL_PART_PREFIX = ".partial-";
const MAX_PART_NUMBER = 10_000;
const MAX_PART_SIZE_BYTES = 50 * 1024 * 1024;
const DEFAULT_LOCAL_STORAGE_ROOT = path.resolve(fileURLToPath(new URL("../../../.local-storage", import.meta.url)));
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const IDENTIFIER_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const NOFOLLOW = constants.O_NOFOLLOW;

export class StorageError extends Error {
  constructor(message, options) {
    super(message, options);
    this.name = "StorageError";
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
  if (!UUID_PATTERN.test(segments[4])) throw new StorageError("Storage key is invalid");
  return segments;
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

function createPartSizeLimiter() {
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
        callback(new StorageError(`Upload parts cannot exceed ${MAX_PART_SIZE_BYTES} bytes`));
        return;
      }
      callback(null, buffer);
    },
  });
}

async function acquireSessionLock(sessionPath) {
  const lockPath = path.join(sessionPath, SESSION_LOCK);
  let handle;
  try {
    handle = await open(
      lockPath,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW,
      0o600,
    );
  } catch (error) {
    if (error.code === "EEXIST") throw new StorageError("Upload session is busy", { cause: error });
    throw error;
  }
  await handle.close();
  return async () => {
    try {
      await unlink(lockPath);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  };
}

async function assertSessionUnlocked(sessionPath) {
  try {
    await lstat(path.join(sessionPath, SESSION_LOCK));
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  throw new StorageError("Upload session is busy");
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

  async function getRoot() {
    if (canonicalRoot) return canonicalRoot;
    await mkdir(configuredRoot, { recursive: true, mode: 0o700 });
    canonicalRoot = await realpath(configuredRoot);
    return canonicalRoot;
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

  async function getSession(uploadId) {
    const sessionPath = await getSessionDirectory(uploadId);
    if (!sessionPath) throw new StorageError("Upload session not found");
    const manifest = await readManifest(uploadId, sessionPath);
    return { sessionPath, manifest };
  }

  async function openRegularFile(key) {
    const rootPath = await getRoot();
    const segments = parseStorageKey(key);
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
    async createUpload({ ownerId, assetId, clipId }) {
      assertIdentifier(ownerId, "Owner ID");
      assertIdentifier(assetId, "Asset ID");
      assertIdentifier(clipId, "Clip ID");

      const rootPath = await getRoot();
      const uploadsPath = await ensureDirectory(rootPath, [SESSION_DIRECTORY], { create: true });
      const uploadId = randomUUID();
      const sessionPath = path.join(uploadsPath, uploadId);
      await mkdir(sessionPath, { mode: 0o700 });

      const key = `${KEY_PREFIX}/${ownerId}/${assetId}/${clipId}/${randomUUID()}`;
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

    async uploadPart(uploadId, partNumber, body) {
      const part = validatePartNumber(partNumber);
      const source = asReadable(body);
      const { sessionPath } = await getSession(uploadId);
      const partsPath = await ensureDirectory(await getRoot(), [SESSION_DIRECTORY, uploadId, "parts"], {
        create: true,
      });
      const partPath = path.join(partsPath, part);
      const temporaryPath = path.join(partsPath, `${PARTIAL_PART_PREFIX}${part}-${randomUUID()}`);
      const handle = await open(
        temporaryPath,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW,
        0o600,
      );
      try {
        // Completion either sees this temporary part or blocks the writer with the session lock.
        await assertSessionUnlocked(sessionPath);
        await pipeline(source, createPartSizeLimiter(), handle.createWriteStream({ autoClose: true }));
        await link(temporaryPath, partPath);
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
      return { partNumber, uploadId };
    },

    async completeUpload(uploadId, { expectedSha256, expectedSizeBytes } = {}) {
      if (expectedSha256 != null
        && (typeof expectedSha256 !== "string" || !/^[a-f0-9]{64}$/i.test(expectedSha256))) {
        throw new StorageError("Expected SHA-256 must contain 64 hexadecimal characters");
      }
      const expectedSize = parseExpectedSize(expectedSizeBytes);
      const rootPath = await getRoot();
      const { sessionPath, manifest } = await getSession(uploadId);
      const release = await acquireSessionLock(sessionPath);
      try {
        const partsPath = await ensureDirectory(rootPath, [SESSION_DIRECTORY, uploadId, "parts"]);
        const entries = await readdir(partsPath);
        if (entries.some(name => name.startsWith(PARTIAL_PART_PREFIX))) {
          throw new StorageError("Upload parts are still being written");
        }
        const partNames = entries
          .filter(name => /^\d{5}$/.test(name))
          .sort((left, right) => Number(left) - Number(right));
        if (partNames.length === 0 || partNames.some((name, index) => Number(name) !== index + 1)) {
          throw new StorageError("Upload parts must be numbered consecutively starting at 1");
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
        const temporaryPath = path.join(destinationDirectory, `.partial-${randomUUID()}`);
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
            throw new StorageError("Completed upload size does not match the expected size");
          }
          if (expectedSha256 != null && sha256 !== expectedSha256.toLowerCase()) {
            throw new StorageError("Completed upload SHA-256 does not match the expected checksum");
          }

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

    async abortUpload(uploadId) {
      const sessionPath = await getSessionDirectory(uploadId);
      if (!sessionPath) return false;
      const release = await acquireSessionLock(sessionPath);
      try {
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
