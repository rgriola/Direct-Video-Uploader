import { createHash } from "node:crypto";
import {
  assertNoActiveUploadWrites, lockStorageCapacity, releaseStorageReservation,
} from "./storage/capacity.js";
import { StorageError, storageIdentityForKey } from "./storage/local-driver.js";

export const SESSION_TTL_MS = 24 * 60 * 60 * 1000;
const MAX_DATABASE_BIGINT = 9_223_372_036_854_775_807n;
const ACTIVE_SESSION_STATUSES = ["OPEN", "COMPLETING"];

export class UploadSessionError extends Error {
  constructor(code, message, options) {
    super(message, options);
    this.name = "UploadSessionError";
    this.code = code;
  }
}

export async function assertOriginalIntentNotCancelled(db, ownerId, assetId) {
  const intent = await db.originalUploadIntent.findUnique({
    where: { assetId },
    select: { userId: true, cancelledAt: true },
  });
  if (intent && intent.userId !== ownerId) {
    throw new UploadSessionError("INTENT_INCONSISTENT", "Original upload intent cannot be verified");
  }
  if (intent?.cancelledAt) {
    throw new UploadSessionError("INTENT_CANCELLED", "Original upload was cancelled");
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

function validateCompletion(session, completion) {
  const sizeBytes = normalizeSize(completion.sizeBytes, "Completed upload size");
  const sha256 = normalizeSha256(completion.sha256, "Completed upload SHA-256");
  if (session.expectedSizeBytes != null && sizeBytes !== session.expectedSizeBytes) {
    throw new UploadSessionError("INTEGRITY_MISMATCH", "Completed upload size does not match the session");
  }
  if (session.expectedSha256 != null && sha256 !== session.expectedSha256) {
    throw new UploadSessionError("INTEGRITY_MISMATCH", "Completed upload SHA-256 does not match the session");
  }
  if (session.clip?.storageKey === session.storageKey
    && ((session.clip.sha256 != null && sha256 !== session.clip.sha256)
      || (session.clip.fileSize != null && sizeBytes !== session.clip.fileSize))) {
    throw new UploadSessionError("INTEGRITY_MISMATCH", "Completed upload does not match the stored clip");
  }
  return { sizeBytes, sha256 };
}

function canVerifyCompletion(session) {
  return Boolean(session.expectedSha256
    || (session.clip?.storageKey === session.storageKey && session.clip.sha256));
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

function assertVisibleSession(session) {
  if (session.asset.userId !== session.ownerId
    || !["ACTIVE", "PAUSED"].includes(session.asset.moderation)) {
    throw new UploadSessionError("NOT_FOUND", "Upload session not found");
  }
  if (session.owner.status !== "ACTIVE") {
    throw new UploadSessionError("ACCOUNT_SUSPENDED", "Account is suspended");
  }
}

export function assertAcceptingUploads(session) {
  if (session.asset.userId !== session.ownerId) {
    throw new UploadSessionError("NOT_FOUND", "Upload session not found");
  }
  if (session.owner.status !== "ACTIVE") {
    throw new UploadSessionError("ACCOUNT_SUSPENDED", "Account is suspended");
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

function createUploadSessionOperations({
  db,
  storage,
  storageDriver = "local",
  capacity,
  now = () => new Date(),
  sessionTtlMs = SESSION_TTL_MS,
  onCompleted,
} = {}, { recoveryOnly = false } = {}) {
  if (!db || !storage || (!recoveryOnly && (typeof capacity?.reserve !== "function"
    || typeof capacity?.withWritePermit !== "function"))) {
    throw new TypeError("Upload session service requires database, storage, and capacity safeguards");
  }
  if (recoveryOnly && typeof storage.assertUploadReferences !== "function") {
    throw new TypeError("Upload session recovery requires storage reference validation");
  }
  if (!Number.isSafeInteger(sessionTtlMs) || sessionTtlMs < 1) {
    throw new TypeError("Upload session TTL must be a positive safe integer");
  }
  if (onCompleted !== undefined && typeof onCompleted !== "function") {
    throw new TypeError("Upload completion callback must be a function");
  }

  async function loadSession(uploadSessionId, ownerId) {
    const session = await db.uploadSession.findFirst({
      where: { id: uploadSessionId, ownerId },
      include: {
        owner: { select: { status: true } },
        asset: { select: { userId: true, moderation: true, status: true } },
        clip: {
          select: {
            id: true,
            assetId: true,
            storageUrl: true,
            storageKey: true,
            storageDriver: true,
            sha256: true,
            fileSize: true,
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
        owner: { select: { status: true } },
        asset: { select: { userId: true, moderation: true, status: true } },
        clip: {
          select: {
            id: true,
            assetId: true,
            storageUrl: true,
            storageKey: true,
            storageDriver: true,
            sha256: true,
            fileSize: true,
            muxAssetId: true,
            muxUploadId: true,
          },
        },
      },
    });
  }

  async function syncParts(snapshot, parts, expectedStatus = snapshot.status) {
    const uploadSessionId = snapshot.id;
    const previousParts = new Map(snapshot.parts.map(part => [part.partNumber, part]));
    await db.$transaction(async tx => {
      const session = await lockSession(tx, uploadSessionId);
      if (!session || session.status !== expectedStatus) return;
      // Publication holds this row lock, so this inexpensive listing cannot miss a committed part.
      const partNumbers = await storage.listPartNumbers(uploadSessionId);
      const present = new Set(partNumbers);
      const recorded = new Map((await tx.uploadPart.findMany({ where: { uploadSessionId } }))
        .map(part => [part.partNumber, part]));
      for (const part of parts) {
        if (!present.has(part.partNumber)) continue;
        const previous = previousParts.get(part.partNumber);
        const current = recorded.get(part.partNumber);
        if (current && (!previous || current.sizeBytes !== previous.sizeBytes || current.sha256 !== previous.sha256)) {
          continue;
        }
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
      await tx.uploadPart.deleteMany(partNumbers.length === 0
        ? { where: { uploadSessionId } }
        : {
          where: {
            uploadSessionId,
            partNumber: { notIn: partNumbers },
          },
        });
    });
  }

  async function finalizeCompletion(session, completion) {
    const { sizeBytes, sha256 } = validateCompletion(session, completion);

    return db.$transaction(async tx => {
      await tx.$queryRaw`SELECT id FROM users WHERE id = ${session.ownerId} FOR UPDATE`;
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
          await lockStorageCapacity(tx);
          const completed = await tx.uploadSession.update({
            where: { id: current.id },
            data: { status: "COMPLETED", completedAt: current.completedAt || now(), storageReservationBytes: 0n },
            include: { parts: { orderBy: { partNumber: "asc" } } },
          });
          if (onCompleted) await onCompleted(tx, current);
          return completed;
        }
        throw new UploadSessionError("CLIP_CHANGED", "Clip is no longer available for original storage");
      }

      await lockStorageCapacity(tx);
      const completed = await tx.uploadSession.update({
        where: { id: current.id },
        data: {
          status: "COMPLETED",
          completedAt: now(),
          storageReservationBytes: 0n,
        },
        include: { parts: { orderBy: { partNumber: "asc" } } },
      });
      if (onCompleted) await onCompleted(tx, current);
      return completed;
    }, { timeout: 60000 });
  }

  async function assertRecoveryWritesStopped(session, expectedStatus) {
    await db.$transaction(async tx => {
      const current = await lockSession(tx, session.id);
      assertOwnedSession(current, session.ownerId);
      if (current.status !== expectedStatus) {
        throw new UploadSessionError("SESSION_BUSY", "Upload session changed during recovery");
      }
      await assertNoActiveUploadWrites(tx, current);
    }, { timeout: 60000 });
  }

  async function recoverCompletingSessionLocked(session, assertLocked, storageOptions) {
    const current = await loadSession(session.id, session.ownerId);
    if (current.status !== "COMPLETING") return;
    await assertRecoveryWritesStopped(current, "COMPLETING");

    await storage.assertStorageLocation(current.storageKey);
    const stored = await storage.stat(current.storageKey);
    if (stored) {
      const result = await hashStream(await storage.getReadStream(current.storageKey));
      if (result.sizeBytes !== stored.sizeBytes) {
        throw new UploadSessionError("STORAGE_CHANGED", "Stored object changed while recovering completion");
      }
      validateCompletion(current, result);
      if (await storage.hasUpload(current.id) && !canVerifyCompletion(current)) {
        throw new UploadSessionError("STORAGE_UNAVAILABLE", "Staged upload data cannot be verified");
      }
      await assertLocked?.();
      await storage.abortUpload(current.id, storageOptions);
      await assertLocked?.();
      await finalizeCompletion(current, { ...result, key: current.storageKey });
      return;
    }

    await assertLocked?.();
    await storage.recoverUpload(current.id, storageOptions);
    await assertLocked?.();
    await db.uploadSession.updateMany({
      where: { id: current.id, ownerId: current.ownerId, status: "COMPLETING" },
      data: { status: "OPEN" },
    });
  }

  async function recoverCompletingSession(session) {
    const locked = await storage.withCompletionLock(
      session.id,
      () => recoverCompletingSessionLocked(session),
    );
    return locked.acquired;
  }

  async function expireSession(session, { assertLocked, ...storageOptions } = {}) {
    await storage.assertStorageLocation(session.storageKey);
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
    if (expired) await removeSessionFilesAndRelease(session, { assertLocked, ...storageOptions });
    return expired;
  }

  async function removeSessionFilesAndRelease(session, { assertLocked, ...storageOptions } = {}) {
    await assertRecoveryWritesStopped(session, session.status === "OPEN" ? "EXPIRED" : session.status);
    await assertLocked?.();
    await storage.abortUpload(session.id, storageOptions);
    await assertLocked?.();
    await db.$transaction(tx => releaseStorageReservation(tx, session.id), { timeout: 60000 });
  }

  async function cleanupCompletedSession(session, assertLocked, storageOptions) {
    await storage.assertStorageLocation(session.storageKey);
    const stored = await storage.stat(session.storageKey);
    if (!stored || (session.expectedSizeBytes != null
      && BigInt(stored.sizeBytes) !== session.expectedSizeBytes)) {
      throw new UploadSessionError("STORAGE_UNAVAILABLE", "Completed original is unavailable");
    }
    if (session.storageReservationBytes === 0n) return false;
    if (await storage.hasUpload(session.id)) {
      if (!canVerifyCompletion(session)) {
        throw new UploadSessionError("STORAGE_UNAVAILABLE", "Staged upload data cannot be verified");
      }
      const result = await hashStream(await storage.getReadStream(session.storageKey));
      if (result.sizeBytes !== stored.sizeBytes) {
        throw new UploadSessionError("STORAGE_CHANGED", "Stored object changed while recovering completion");
      }
      validateCompletion(session, result);
    }
    await assertLocked?.();
    await removeSessionFilesAndRelease(session, { assertLocked, ...storageOptions });
    return true;
  }

  function needsRecovery(session) {
    if (session.status === "OPEN") return session.expiresAt <= now();
    if (session.status === "COMPLETING") return true;
    return ["ABORTED", "EXPIRED", "COMPLETED"].includes(session.status)
      && session.storageReservationBytes !== 0n;
  }

  function assertRecoveryReferences(session, assetId) {
    const prefix = `originals/${session.ownerId}/${session.assetId}/${session.clipId}/`;
    if (session.assetId !== assetId || session.asset.userId !== session.ownerId
      || session.clip.id !== session.clipId || session.clip.assetId !== session.assetId
      || session.storageDriver !== "local" || !session.storageKey.startsWith(prefix)) {
      throw new UploadSessionError("STORAGE_UNAVAILABLE", "Upload session references require manual review");
    }
  }

  async function recoverForSweep({ uploadSessionId, ownerId, assetId, assertLocked }) {
    if (typeof assertLocked !== "function") {
      throw new TypeError("Upload session recovery requires an asset lock");
    }
    const initial = await loadSession(uploadSessionId, ownerId);
    if (!needsRecovery(initial)) return { status: "unchanged" };
    assertRecoveryReferences(initial, assetId);
    await assertLocked();
    await storage.assertStorageLocation(initial.storageKey);

    const storageOptions = { preserveUnattributedAssemblies: true };
    const locked = await storage.withCompletionLock(uploadSessionId, async () => {
      await assertLocked();
      const current = await loadSession(uploadSessionId, ownerId);
      if (!needsRecovery(current)) return { status: "unchanged" };
      assertRecoveryReferences(current, assetId);
      await storage.assertStorageLocation(current.storageKey);
      await storage.assertUploadReferences(current.id, {
        ownerId: current.ownerId,
        assetId: current.assetId,
        clipId: current.clipId,
        storageKey: current.storageKey,
      });
      await assertLocked();

      if (current.asset.moderation === "REMOVED") {
        return { status: "deferred", reason: "Removed assets require moderation reconciliation" };
      }
      if (current.status === "COMPLETING") {
        if (current.owner.status !== "ACTIVE" || current.asset.moderation !== "ACTIVE"
          || !["UPLOADING", "PROCESSING"].includes(current.asset.status)) {
          return { status: "deferred", reason: "Upload completion is not currently eligible for recovery" };
        }
        if ((current.clip.storageKey && (current.clip.storageKey !== current.storageKey
          || current.clip.storageDriver !== current.storageDriver))
          || current.clip.storageUrl || current.clip.muxAssetId || current.clip.muxUploadId) {
          throw new UploadSessionError("STORAGE_UNAVAILABLE", "Upload completion references require manual review");
        }
        if (await storage.stat(current.storageKey) && !canVerifyCompletion(current)) {
          throw new UploadSessionError("STORAGE_UNAVAILABLE", "Published original cannot be verified");
        }
        await recoverCompletingSessionLocked(current, assertLocked, storageOptions);
        const recovered = await loadSession(uploadSessionId, ownerId);
        if (recovered.status === "OPEN" && recovered.expiresAt <= now()) {
          await assertLocked();
          await expireSession(recovered, { assertLocked, ...storageOptions });
          return { status: "expired" };
        }
        return { status: recovered.status === "COMPLETED" ? "completed" : "reopened" };
      }
      if (current.status === "COMPLETED") {
        if (current.clip.storageKey !== current.storageKey
          || current.clip.storageDriver !== current.storageDriver) {
          throw new UploadSessionError("STORAGE_UNAVAILABLE", "Completed original references require manual review");
        }
        await cleanupCompletedSession(current, assertLocked, storageOptions);
        return { status: "cleaned" };
      }
      if (current.clip.storageKey === current.storageKey || await storage.stat(current.storageKey)) {
        throw new UploadSessionError("STORAGE_UNAVAILABLE", "Unexpected original requires manual review");
      }
      await assertLocked();
      if (current.status === "OPEN") {
        return { status: await expireSession(current, { assertLocked, ...storageOptions }) ? "expired" : "unchanged" };
      }
      await removeSessionFilesAndRelease(current, { assertLocked, ...storageOptions });
      return { status: "cleaned" };
    });
    return locked.acquired ? locked.value : { status: "busy" };
  }

  async function create({
    ownerId, assetId, clipId, expectedSizeBytes, expectedSha256, initializeClip = false, metadata = null,
  }) {
    const sizeBytes = normalizeSize(expectedSizeBytes, "Expected upload size");
    const sha256 = normalizeSha256(expectedSha256, "Expected SHA-256");
    const createdAt = now();
    const expiresAt = new Date(createdAt.getTime() + sessionTtlMs);
    let driverSession;
    let session;

    try {
      session = await db.$transaction(async tx => {
        // Share-lock the owner first so creates coexist while cancellation can fence them.
        await tx.$queryRaw`SELECT id FROM users WHERE id = ${ownerId} FOR SHARE`;
        await tx.$queryRaw`SELECT id FROM assets WHERE id = ${assetId} FOR UPDATE`;
        const asset = await tx.asset.findUnique({ where: { id: assetId } });
        let clip = await tx.clip.findUnique({ where: { id: clipId } });
        if (!asset || asset.userId !== ownerId) {
          throw new UploadSessionError("NOT_FOUND", "Asset not found");
        }
        await assertOriginalIntentNotCancelled(tx, ownerId, assetId);
        if (asset.moderation !== "ACTIVE"
          || !["UPLOADING", "PROCESSING"].includes(asset.status)) {
          throw new UploadSessionError("ASSET_NOT_ACTIVE", "Asset is not accepting uploads");
        }
        if (initializeClip) {
          const owner = await tx.user.findUnique({ where: { id: ownerId }, select: { status: true } });
          if (!owner || owner.status !== "ACTIVE") {
            throw new UploadSessionError("ACCOUNT_SUSPENDED", "Account is suspended");
          }
          if (asset.uploadMode === "MUX") {
            throw new UploadSessionError("CLIP_CHANGED", "Asset is reserved for a direct Mux upload");
          }
          if (asset.status !== "UPLOADING") {
            throw new UploadSessionError("CLIP_CHANGED", "Asset is already being processed");
          }
          const otherClip = await tx.clip.findFirst({
            where: { assetId, id: { not: clipId } },
            select: { id: true },
          });
          if (otherClip) {
            throw new UploadSessionError("CLIP_CHANGED", "Asset already has a different upload");
          }
          if (!clip) {
            clip = await tx.clip.create({
              data: {
                id: clipId,
                assetId,
                originalFileName: asset.originalFileName,
                status: "UPLOADING",
                ...(metadata ? {
                  gpsLat: metadata.gpsLat,
                  gpsLon: metadata.gpsLon,
                  gpsAltitude: metadata.gpsAltitude,
                  capturedAt: metadata.capturedAt,
                  deviceModel: metadata.deviceModel,
                  osVersion: metadata.osVersion,
                  codec: metadata.codec,
                  resolution: metadata.resolution,
                  orientation: metadata.orientation,
                  duration: metadata.duration,
                } : {}),
              },
            });
            await tx.asset.update({
              where: { id: assetId },
              data: {
                clipCount: { increment: 1 },
                uploadMode: "ORIGINAL",
                ...(metadata ? { totalDuration: metadata.duration } : {}),
              },
            });
          } else if (asset.uploadMode == null) {
            await tx.asset.update({ where: { id: assetId }, data: { uploadMode: "ORIGINAL" } });
          }
        }
        if (!clip || clip.assetId !== assetId) {
          throw new UploadSessionError("NOT_FOUND", "Clip not found");
        }
        if (!["UPLOADING", "PROCESSING"].includes(clip.status)
          || clip.storageUrl || clip.storageKey || clip.muxAssetId || clip.muxUploadId) {
          throw new UploadSessionError("CLIP_CHANGED", "Clip is no longer available for original storage");
        }

        const active = await tx.uploadSession.findFirst({
          where: {
            clipId,
            status: { in: ACTIVE_SESSION_STATUSES },
          },
        });
        const previous = active || await tx.uploadSession.findFirst({
          where: {
            clipId,
            status: { in: ["ABORTED", "EXPIRED"] },
          },
          orderBy: [{ createdAt: "desc" }, { id: "desc" }],
        });
        const existing = previous && await lockSession(tx, previous.id);
        if (existing
          && ACTIVE_SESSION_STATUSES.includes(existing.status)
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
          if (!["OPEN", "ABORTED", "EXPIRED"].includes(existing.status)) {
            throw new UploadSessionError("INVALID_STATE", "Upload session cannot be replaced");
          }
          await storage.assertStorageLocation(existing.storageKey);
          await storage.abortUpload(existing.id);
          if (existing.status === "OPEN") {
            await tx.uploadSession.update({
              where: { id: existing.id },
              data: { status: "EXPIRED" },
            });
          }
          await releaseStorageReservation(tx, existing.id);
        }

        const reservation = await capacity.reserve(tx, sizeBytes);
        driverSession = await storage.createUpload({ ownerId, assetId, clipId });
        if (reservation.identity && storageIdentityForKey(driverSession.key) !== reservation.identity) {
          throw new StorageError("Local storage location changed during upload creation", {
            code: "STORAGE_UNAVAILABLE",
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
            storageReservationBytes: reservation.reservationBytes,
            expiresAt,
          },
          include: { parts: true },
        });
      }, { timeout: 60000, isolationLevel: "ReadCommitted" });
    } catch (error) {
      if (driverSession) {
        try {
          await db.$transaction(async tx => {
            await lockStorageCapacity(tx);
            const persisted = await tx.uploadSession.findUnique({
              where: { id: driverSession.uploadId },
              select: { storageKey: true },
            });
            if (persisted && persisted.storageKey !== driverSession.key) {
              throw new StorageError("Upload session references changed during creation", {
                code: "STORAGE_UNAVAILABLE",
              });
            }
            if (!persisted) await storage.abortUpload(driverSession.uploadId);
          }, { timeout: 60000 });
        } catch (cleanupError) {
          throw new AggregateError(
            [error, cleanupError],
            "Could not create or clean up the upload session",
            { cause: error },
          );
        }
      }
      throw error;
    }

    return session;
  }

  async function get({ ownerId, uploadSessionId }) {
    let session = await loadSession(uploadSessionId, ownerId);
    assertVisibleSession(session);
    if (session.status === "OPEN" && session.expiresAt <= now()) {
      await expireSession(session);
      session = await loadSession(uploadSessionId, ownerId);
    } else if (session.status === "COMPLETING" && session.asset.moderation === "ACTIVE") {
      await recoverCompletingSession(session);
      session = await loadSession(uploadSessionId, ownerId);
    } else if (session.status === "EXPIRED" || session.status === "ABORTED") {
      await storage.assertStorageLocation(session.storageKey);
      await removeSessionFilesAndRelease(session);
    }

    assertVisibleSession(session);
    if (session.status === "OPEN") {
      await storage.assertStorageLocation(session.storageKey);
      await storage.recoverUpload(session.id);
      const parts = await storage.listParts(session.id);
      await syncParts(session, parts);
      session = await loadSession(uploadSessionId, ownerId);
      assertVisibleSession(session);
    }
    if (session.status === "COMPLETED") {
      if (await cleanupCompletedSession(session)) {
        session = await loadSession(uploadSessionId, ownerId);
        assertVisibleSession(session);
      }
    }
    return session;
  }

  async function uploadPart({ ownerId, uploadSessionId, partNumber, body, expectedSizeBytes }) {
    assertPartNumber(partNumber);
    const session = await loadSession(uploadSessionId, ownerId);
    assertOpen(session, now());
    assertAcceptingUploads(session);
    await storage.assertStorageLocation(session.storageKey);
    let committed = false;
    const writeSize = normalizeSize(expectedSizeBytes, "Expected part size");
    const part = await capacity.withWritePermit(session, writeSize, () =>
      storage.uploadPart(session.id, partNumber, body, {
        expectedSizeBytes,
        commitPart: async (result, publish) => {
          await db.$transaction(async tx => {
            await tx.$queryRaw`SELECT id FROM users WHERE id = ${ownerId} FOR UPDATE`;
            await tx.$queryRaw`SELECT id FROM assets WHERE id = ${session.assetId} FOR UPDATE`;
            const current = await lockSession(tx, session.id);
            assertOwnedSession(current, ownerId);
            assertOpen(current, now());
            assertAcceptingUploads(current);
            await publish();
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
                sizeBytes: BigInt(result.sizeBytes),
                sha256: result.sha256,
              },
              update: {
                sizeBytes: BigInt(result.sizeBytes),
                sha256: result.sha256,
              },
            });
          });
          committed = true;
        },
      }));
    if (!committed) {
      throw new Error("Storage driver did not commit the upload part");
    }
    return part;
  }

  async function complete({ ownerId, uploadSessionId }) {
    const initial = await loadSession(uploadSessionId, ownerId);
    assertVisibleSession(initial);
    if (initial.status === "COMPLETED") return get({ ownerId, uploadSessionId });
    await storage.assertStorageLocation(initial.storageKey);
    if (initial.status === "COMPLETING" && !await recoverCompletingSession(initial)) {
      throw new UploadSessionError("SESSION_BUSY", "Upload session is completing");
    }
    const locked = await storage.withCompletionLock(uploadSessionId, async () => {
      const session = await loadSession(uploadSessionId, ownerId);
      if (session.status === "COMPLETED") return session;
      assertOpen(session, now());
      assertAcceptingUploads(session);

      return capacity.withWritePermit(session, session.expectedSizeBytes, async () => {
        await db.$transaction(async tx => {
          await tx.$queryRaw`SELECT id FROM users WHERE id = ${ownerId} FOR UPDATE`;
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
          if (parts.length === 0) {
            throw new UploadSessionError("INCOMPLETE_UPLOAD", "Upload has no completed parts");
          }
          await syncParts(session, parts, "COMPLETING");
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
    });
    if (!locked.acquired) {
      throw new UploadSessionError("SESSION_BUSY", "Upload session is completing");
    }
    return locked.value;
  }

  async function abort({ ownerId, uploadSessionId }) {
    const session = await loadSession(uploadSessionId, ownerId);
    assertVisibleSession(session);
    if (session.status === "COMPLETED") {
      throw new UploadSessionError("INVALID_STATE", "Completed originals cannot be aborted");
    }
    await storage.assertStorageLocation(session.storageKey);
    if (session.status === "COMPLETING") {
      if (!await recoverCompletingSession(session)) {
        throw new UploadSessionError("SESSION_BUSY", "Upload session is completing");
      }
      const latest = await loadSession(uploadSessionId, ownerId);
      if (latest.status === "COMPLETED") {
        throw new UploadSessionError("INVALID_STATE", "Completed originals cannot be aborted");
      }
    }

    const status = await db.$transaction(async tx => {
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
        return "ABORTED";
      }
      return current.status;
    });
    await storage.assertStorageLocation(session.storageKey);
    await removeSessionFilesAndRelease({ ...session, status });
    return { id: session.id, status };
  }

  return {
    create,
    get,
    uploadPart,
    complete,
    abort,
    recoverForSweep,
  };
}

export function createUploadSessionService(options) {
  const { create, get, uploadPart, complete, abort } = createUploadSessionOperations(options);
  return { create, get, uploadPart, complete, abort };
}

export function createUploadSessionRecovery(options) {
  const { recoverForSweep } = createUploadSessionOperations(options, { recoveryOnly: true });
  return { recoverForSweep };
}
