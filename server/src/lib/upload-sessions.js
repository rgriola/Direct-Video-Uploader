import { createHash } from "node:crypto";

const SESSION_TTL_MS = 24 * 60 * 60 * 1000;
const MAX_DATABASE_BIGINT = 9_223_372_036_854_775_807n;
const ACTIVE_SESSION_STATUSES = ["OPEN", "COMPLETING"];

export class UploadSessionError extends Error {
  constructor(code, message, options) {
    super(message, options);
    this.name = "UploadSessionError";
    this.code = code;
  }
}

function normalizeSize(value, label) {
  if (value == null) return null;
  let size;
  if (typeof value === "bigint") size = value;
  else if (typeof value === "number" && Number.isSafeInteger(value)) size = BigInt(value);
  else if (typeof value === "string" && /^\d+$/.test(value)) size = BigInt(value);
  else throw new UploadSessionError("INVALID_ARGUMENT", `${label} must be a non-negative integer`);
  if (size < 0n || size > MAX_DATABASE_BIGINT) {
    throw new UploadSessionError("INVALID_ARGUMENT", `${label} is outside the supported range`);
  }
  return size;
}

function normalizeSha256(value, label) {
  if (value == null) return null;
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/i.test(value)) {
    throw new UploadSessionError("INVALID_ARGUMENT", `${label} must contain 64 hexadecimal characters`);
  }
  return value.toLowerCase();
}

function assertPartNumber(partNumber) {
  if (!Number.isSafeInteger(partNumber) || partNumber < 1 || partNumber > 10_000) {
    throw new UploadSessionError("INVALID_ARGUMENT", "Part number must be between 1 and 10000");
  }
}

function assertOwnedSession(session, ownerId) {
  if (!session || session.ownerId !== ownerId) {
    throw new UploadSessionError("NOT_FOUND", "Upload session not found");
  }
}

function assertAcceptingUploads(session) {
  if (session.asset.userId !== session.ownerId) {
    throw new UploadSessionError("NOT_FOUND", "Upload session not found");
  }
  if (session.asset.moderation !== "ACTIVE"
    || !["UPLOADING", "PROCESSING"].includes(session.asset.status)) {
    throw new UploadSessionError("ASSET_NOT_ACTIVE", "Asset is not accepting uploads");
  }
}

function assertNotExpired(session, now) {
  if (session.status === "EXPIRED" || session.expiresAt <= now) {
    throw new UploadSessionError("EXPIRED", "Upload session has expired");
  }
}

function assertOpen(session, now) {
  assertNotExpired(session, now);
  if (session.status !== "OPEN") {
    throw new UploadSessionError("INVALID_STATE", `Upload session is ${session.status.toLowerCase()}`);
  }
}

async function hashStream(stream) {
  const hash = createHash("sha256");
  let sizeBytes = 0n;
  for await (const chunk of stream) {
    hash.update(chunk);
    sizeBytes += BigInt(chunk.length);
  }
  return { sha256: hash.digest("hex"), sizeBytes: sizeBytes.toString() };
}

export function createUploadSessionService({
  db,
  storage,
  storageDriver = "local",
  now = () => new Date(),
  sessionTtlMs = SESSION_TTL_MS,
} = {}) {
  if (!db || !storage) throw new TypeError("Upload session service requires database and storage drivers");
  if (!Number.isSafeInteger(sessionTtlMs) || sessionTtlMs < 1) {
    throw new TypeError("Upload session TTL must be a positive safe integer");
  }

  async function loadSession(uploadSessionId, ownerId) {
    const session = await db.uploadSession.findFirst({
      where: { id: uploadSessionId, ownerId },
      include: {
        asset: { select: { userId: true, moderation: true, status: true } },
        clip: {
          select: {
            id: true,
            assetId: true,
            storageUrl: true,
            storageKey: true,
            muxAssetId: true,
            muxUploadId: true,
          },
        },
        parts: { orderBy: { partNumber: "asc" } },
      },
    });
    assertOwnedSession(session, ownerId);
    return session;
  }

  async function lockSession(tx, uploadSessionId) {
    await tx.$queryRaw`SELECT id FROM upload_sessions WHERE id = ${uploadSessionId} FOR UPDATE`;
    return tx.uploadSession.findUnique({
      where: { id: uploadSessionId },
      include: {
        asset: { select: { userId: true, moderation: true, status: true } },
        clip: {
          select: {
            id: true,
            assetId: true,
            storageUrl: true,
            storageKey: true,
            muxAssetId: true,
            muxUploadId: true,
          },
        },
      },
    });
  }

  async function syncParts(uploadSessionId, parts) {
    await db.$transaction(async tx => {
      const session = await lockSession(tx, uploadSessionId);
      if (!session || !["OPEN", "COMPLETING"].includes(session.status)) return;
      for (const part of parts) {
        await tx.uploadPart.upsert({
          where: {
            uploadSessionId_partNumber: {
              uploadSessionId,
              partNumber: part.partNumber,
            },
          },
          create: {
            uploadSessionId,
            partNumber: part.partNumber,
            sizeBytes: BigInt(part.sizeBytes),
            sha256: part.sha256,
          },
          update: {
            sizeBytes: BigInt(part.sizeBytes),
            sha256: part.sha256,
          },
        });
      }
      await tx.uploadPart.deleteMany(parts.length === 0
        ? { where: { uploadSessionId } }
        : {
          where: {
            uploadSessionId,
            partNumber: { notIn: parts.map(part => part.partNumber) },
          },
        });
    });
  }

  async function finalizeCompletion(session, completion) {
    const sizeBytes = normalizeSize(completion.sizeBytes, "Completed upload size");
    const sha256 = normalizeSha256(completion.sha256, "Completed upload SHA-256");
    if (session.expectedSizeBytes != null && sizeBytes !== session.expectedSizeBytes) {
      throw new UploadSessionError("INTEGRITY_MISMATCH", "Completed upload size does not match the session");
    }
    if (session.expectedSha256 != null && sha256 !== session.expectedSha256) {
      throw new UploadSessionError("INTEGRITY_MISMATCH", "Completed upload SHA-256 does not match the session");
    }

    return db.$transaction(async tx => {
      await tx.$queryRaw`SELECT id FROM assets WHERE id = ${session.assetId} FOR UPDATE`;
      const current = await lockSession(tx, session.id);
      assertOwnedSession(current, session.ownerId);
      if (current.status === "COMPLETED") return current;
      if (!["OPEN", "COMPLETING"].includes(current.status)) {
        throw new UploadSessionError("INVALID_STATE", `Upload session is ${current.status.toLowerCase()}`);
      }
      assertAcceptingUploads(current);
      if (current.clip.assetId !== current.assetId) {
        throw new UploadSessionError("INVALID_STATE", "Upload session clip does not belong to its asset");
      }

      const clipUpdate = await tx.clip.updateMany({
        where: {
          id: current.clipId,
          assetId: current.assetId,
          storageKey: null,
          storageUrl: null,
          muxAssetId: null,
          muxUploadId: null,
        },
        data: {
          storageKey: current.storageKey,
          storageDriver: current.storageDriver,
          sha256,
          fileSize: sizeBytes,
        },
      });
      if (clipUpdate.count !== 1) {
        const clip = await tx.clip.findUnique({ where: { id: current.clipId } });
        if (clip?.storageKey === current.storageKey && clip.sha256 === sha256) {
          return tx.uploadSession.update({
            where: { id: current.id },
            data: { status: "COMPLETED", completedAt: current.completedAt || now() },
            include: { parts: { orderBy: { partNumber: "asc" } } },
          });
        }
        throw new UploadSessionError("CLIP_CHANGED", "Clip is no longer available for original storage");
      }

      return tx.uploadSession.update({
        where: { id: current.id },
        data: {
          status: "COMPLETED",
          completedAt: now(),
        },
        include: { parts: { orderBy: { partNumber: "asc" } } },
      });
    });
  }

  async function recoverCompletingSession(session) {
    const locked = await storage.withCompletionLock(session.id, async () => {
      const current = await loadSession(session.id, session.ownerId);
      if (current.status !== "COMPLETING") return;

      const stored = await storage.stat(current.storageKey);
      if (stored) {
        const result = await hashStream(await storage.getReadStream(current.storageKey));
        if (result.sizeBytes !== stored.sizeBytes) {
          throw new UploadSessionError("STORAGE_CHANGED", "Stored object changed while recovering completion");
        }
        await finalizeCompletion(current, { ...result, key: current.storageKey });
        return;
      }

      await storage.recoverUpload(current.id);
      await db.uploadSession.updateMany({
        where: { id: current.id, ownerId: current.ownerId, status: "COMPLETING" },
        data: { status: "OPEN" },
      });
    });
    return locked.acquired;
  }

  async function expireSession(session) {
    const expired = await db.$transaction(async tx => {
      const current = await lockSession(tx, session.id);
      if (!current || current.ownerId !== session.ownerId) return false;
      if (current.status !== "OPEN" || current.expiresAt > now()) return false;
      await tx.uploadSession.update({
        where: { id: current.id },
        data: { status: "EXPIRED" },
      });
      return true;
    });
    if (expired) await storage.abortUpload(session.id);
    return expired;
  }

  async function create({ ownerId, assetId, clipId, expectedSizeBytes, expectedSha256 }) {
    const sizeBytes = normalizeSize(expectedSizeBytes, "Expected upload size");
    const sha256 = normalizeSha256(expectedSha256, "Expected SHA-256");
    const createdAt = now();
    const expiresAt = new Date(createdAt.getTime() + sessionTtlMs);
    const driverSession = await storage.createUpload({ ownerId, assetId, clipId });
    let session;

    try {
      session = await db.$transaction(async tx => {
        await tx.$queryRaw`SELECT id FROM assets WHERE id = ${assetId} FOR UPDATE`;
        const asset = await tx.asset.findUnique({ where: { id: assetId } });
        const clip = await tx.clip.findUnique({ where: { id: clipId } });
        if (!asset || asset.userId !== ownerId) {
          throw new UploadSessionError("NOT_FOUND", "Asset not found");
        }
        if (asset.moderation !== "ACTIVE"
          || !["UPLOADING", "PROCESSING"].includes(asset.status)) {
          throw new UploadSessionError("ASSET_NOT_ACTIVE", "Asset is not accepting uploads");
        }
        if (!clip || clip.assetId !== assetId) {
          throw new UploadSessionError("NOT_FOUND", "Clip not found");
        }
        if (!["UPLOADING", "PROCESSING"].includes(clip.status)
          || clip.storageUrl || clip.storageKey || clip.muxAssetId || clip.muxUploadId) {
          throw new UploadSessionError("CLIP_CHANGED", "Clip is no longer available for original storage");
        }

        const existing = await tx.uploadSession.findFirst({
          where: {
            clipId,
            status: { in: ACTIVE_SESSION_STATUSES },
          },
        });
        if (existing
          && (existing.status === "COMPLETING" || existing.expiresAt > createdAt)) {
          if (existing.expectedSizeBytes === sizeBytes && existing.expectedSha256 === sha256) {
            return existing;
          }
          if (existing.status === "COMPLETING") {
            throw new UploadSessionError("SESSION_BUSY", "A session for this clip is completing");
          }
          throw new UploadSessionError("SESSION_EXISTS", "An upload session already exists for this clip");
        }
        if (existing) {
          await storage.recoverUpload(existing.id);
          await storage.abortUpload(existing.id);
          await tx.uploadSession.update({
            where: { id: existing.id },
            data: { status: "EXPIRED" },
          });
        }

        return tx.uploadSession.create({
          data: {
            id: driverSession.uploadId,
            ownerId,
            assetId,
            clipId,
            storageDriver,
            storageKey: driverSession.key,
            expectedSizeBytes: sizeBytes,
            expectedSha256: sha256,
            expiresAt,
          },
          include: { parts: true },
        });
      });
    } catch (error) {
      try {
        await storage.abortUpload(driverSession.uploadId);
      } catch (cleanupError) {
        throw new AggregateError(
          [error, cleanupError],
          "Could not create or clean up the upload session",
          { cause: error },
        );
      }
      throw error;
    }

    if (session.id !== driverSession.uploadId) {
      try {
        await storage.abortUpload(driverSession.uploadId);
      } catch (cleanupError) {
        throw new AggregateError(
          [cleanupError],
          "Could not clean up the duplicate upload session",
          { cause: cleanupError },
        );
      }
    }
    return session;
  }

  async function get({ ownerId, uploadSessionId }) {
    let session = await loadSession(uploadSessionId, ownerId);
    if (session.status === "OPEN" && session.expiresAt <= now()) {
      await expireSession(session);
      session = await loadSession(uploadSessionId, ownerId);
    } else if (session.status === "COMPLETING") {
      await recoverCompletingSession(session);
      session = await loadSession(uploadSessionId, ownerId);
    } else if (session.status === "EXPIRED" || session.status === "ABORTED") {
      await storage.abortUpload(session.id);
    }

    if (session.status === "OPEN") {
      assertAcceptingUploads(session);
      await storage.recoverUpload(session.id);
      const parts = await storage.listParts(session.id);
      await syncParts(session.id, parts);
      return loadSession(uploadSessionId, ownerId);
    }
    return session;
  }

  async function uploadPart({ ownerId, uploadSessionId, partNumber, body }) {
    assertPartNumber(partNumber);
    const session = await loadSession(uploadSessionId, ownerId);
    assertOpen(session, now());
    assertAcceptingUploads(session);
    const part = await storage.uploadPart(session.id, partNumber, body);

    await db.$transaction(async tx => {
      const current = await lockSession(tx, session.id);
      assertOwnedSession(current, ownerId);
      if (!["OPEN", "COMPLETED"].includes(current.status)) {
        throw new UploadSessionError("INVALID_STATE", `Upload session is ${current.status.toLowerCase()}`);
      }
      assertAcceptingUploads(current);
      await tx.uploadPart.upsert({
        where: {
          uploadSessionId_partNumber: {
            uploadSessionId: session.id,
            partNumber,
          },
        },
        create: {
          uploadSessionId: session.id,
          partNumber,
          sizeBytes: BigInt(part.sizeBytes),
          sha256: part.sha256,
        },
        update: {
          sizeBytes: BigInt(part.sizeBytes),
          sha256: part.sha256,
        },
      });
    });
    return part;
  }

  async function complete({ ownerId, uploadSessionId }) {
    await loadSession(uploadSessionId, ownerId);
    const locked = await storage.withCompletionLock(uploadSessionId, async () => {
      const session = await loadSession(uploadSessionId, ownerId);
      assertOpen(session, now());
      assertAcceptingUploads(session);

      await db.$transaction(async tx => {
        const current = await lockSession(tx, session.id);
        assertOwnedSession(current, ownerId);
        assertOpen(current, now());
        assertAcceptingUploads(current);
        await tx.uploadSession.update({
          where: { id: session.id },
          data: { status: "COMPLETING" },
        });
      });

      let completion;
      try {
        const parts = await storage.listParts(session.id);
        await syncParts(session.id, parts);
        completion = await storage.completeUpload(session.id, {
          expectedSha256: session.expectedSha256 || undefined,
          expectedSizeBytes: session.expectedSizeBytes?.toString(),
        });
      } catch (error) {
        let stored;
        try {
          stored = await storage.stat(session.storageKey);
        } catch (recoveryError) {
          throw new AggregateError(
            [error, recoveryError],
            "Could not determine whether the upload was published",
            { cause: error },
          );
        }
        if (!stored) {
          await db.uploadSession.updateMany({
            where: { id: session.id, ownerId, status: "COMPLETING" },
            data: { status: "OPEN" },
          });
        }
        throw error;
      }
      return finalizeCompletion(session, completion);
    });
    if (!locked.acquired) {
      throw new UploadSessionError("SESSION_BUSY", "Upload session is completing");
    }
    return locked.value;
  }

  async function abort({ ownerId, uploadSessionId }) {
    const session = await loadSession(uploadSessionId, ownerId);
    if (session.status === "COMPLETED") {
      throw new UploadSessionError("INVALID_STATE", "Completed originals cannot be aborted");
    }
    if (session.status === "COMPLETING") {
      if (!await recoverCompletingSession(session)) {
        throw new UploadSessionError("SESSION_BUSY", "Upload session is completing");
      }
      const latest = await loadSession(uploadSessionId, ownerId);
      if (latest.status === "COMPLETED") {
        throw new UploadSessionError("INVALID_STATE", "Completed originals cannot be aborted");
      }
    }

    await db.$transaction(async tx => {
      const current = await lockSession(tx, session.id);
      assertOwnedSession(current, ownerId);
      if (current.status === "COMPLETED" || current.status === "COMPLETING") {
        throw new UploadSessionError("INVALID_STATE", "Upload session cannot be aborted");
      }
      if (current.status !== "ABORTED" && current.status !== "EXPIRED") {
        await tx.uploadSession.update({
          where: { id: session.id },
          data: { status: "ABORTED" },
        });
      }
    });
    await storage.abortUpload(session.id);
    return { id: session.id, status: "ABORTED" };
  }

  return {
    create,
    get,
    uploadPart,
    complete,
    abort,
  };
}
