import { randomUUID } from "node:crypto";
import os from "node:os";
import { StorageError, storageIdentityForKey } from "./local-driver.js";

const CAPACITY_LOCK_KEY = "dvu:original-storage-capacity";
const MAX_DATABASE_BIGINT = 9_223_372_036_854_775_807n;
export const SESSION_OVERHEAD_BYTES = 1024n * 1024n;
export const WRITE_OVERHEAD_BYTES = 64n * 1024n;
const localLeases = new Map();

export async function lockStorageCapacity(tx) {
  await tx.$queryRaw`
    SELECT pg_advisory_xact_lock(hashtextextended(${CAPACITY_LOCK_KEY}, 0))::text AS locked
  `;
}

export async function releaseStorageReservation(tx, uploadSessionId) {
  await tx.$queryRaw`SELECT id FROM upload_sessions WHERE id = ${uploadSessionId} FOR UPDATE`;
  await lockStorageCapacity(tx);
  await tx.uploadSession.updateMany({
    where: { id: uploadSessionId },
    data: { storageReservationBytes: 0n },
  });
}

function isProcessAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    throw new StorageError("Storage write ownership could not be verified", {
      cause: error,
      code: "STORAGE_UNAVAILABLE",
    });
  }
}

function isStaleLease(lease, { hostname, pid, processAlive }) {
  return lease.host === hostname && (lease.pid === pid
    ? localLeases.get(lease.id) !== "active"
    : !processAlive(lease.pid));
}

export async function assertNoActiveUploadWrites(tx, session, {
  hostname = os.hostname(),
  pid = process.pid,
  processAlive = isProcessAlive,
} = {}) {
  await lockStorageCapacity(tx);
  const leases = await tx.storageWriteLease.findMany({ where: { uploadSessionId: session.id } });
  if (!leases.length) return;
  const identity = storageIdentityForKey(session.storageKey);
  for (const lease of leases) {
    if (!identity || lease.storageIdentity !== identity || lease.sizeBytes < 1n
      || typeof lease.host !== "string" || !lease.host
      || !Number.isSafeInteger(lease.pid) || lease.pid < 1) {
      throw new StorageError("Upload write reservation requires manual recovery", { code: "STORAGE_UNAVAILABLE" });
    }
    if (!isStaleLease(lease, { hostname, pid, processAlive })) {
      throw new StorageError("Upload writes are active or cannot be verified", { code: "SESSION_BUSY" });
    }
  }
  for (const lease of leases) {
    await tx.storageWriteLease.deleteMany({ where: { id: lease.id } });
    if (lease.host === hostname && lease.pid === pid) localLeases.delete(lease.id);
  }
}

function reservationFor(sizeBytes) {
  if (typeof sizeBytes !== "bigint" || sizeBytes < 1n
    || sizeBytes > (MAX_DATABASE_BIGINT - SESSION_OVERHEAD_BYTES) / 2n) {
    throw new StorageError("A valid upload size is required for storage capacity", {
      code: "STORAGE_UNAVAILABLE",
    });
  }
  return sizeBytes * 2n + SESSION_OVERHEAD_BYTES;
}

function requireLocation(identity, key, provider) {
  if (provider !== "local" || !identity) {
    throw new StorageError("Original storage references require recovery", { code: "STORAGE_UNAVAILABLE" });
  }
  let keyIdentity;
  try {
    keyIdentity = storageIdentityForKey(key);
  } catch (error) {
    if (!(error instanceof StorageError)) throw error;
    throw new StorageError("Original storage references require recovery", {
      cause: error,
      code: "STORAGE_UNAVAILABLE",
    });
  }
  if (keyIdentity !== identity) {
    throw new StorageError("Original storage location does not match existing uploads", {
      code: "STORAGE_UNAVAILABLE",
    });
  }
}

export function createStorageCapacity({
  db,
  storage,
  maxStorageBytes,
  minFreeBytes,
  hostname = os.hostname(),
  pid = process.pid,
  processAlive = isProcessAlive,
}) {
  if (!db || typeof storage?.getCapacitySnapshot !== "function"
    || typeof maxStorageBytes !== "bigint" || maxStorageBytes < 1n
    || typeof minFreeBytes !== "bigint" || minFreeBytes < 1n
    || typeof hostname !== "string" || !hostname
    || !Number.isSafeInteger(pid) || pid < 1 || typeof processAlive !== "function") {
    throw new TypeError("Storage capacity requires a database, local storage, and positive byte limits");
  }

  async function inspect(tx) {
    const leases = await tx.storageWriteLease.findMany();
    const staleLeaseIds = new Set();
    // Decide which writers are gone before measuring files, so a finishing write cannot be missed by both.
    for (const lease of leases) {
      if (isStaleLease(lease, { hostname, pid, processAlive })) {
        staleLeaseIds.add(lease.id);
      }
    }

    const snapshot = await storage.getCapacitySnapshot();
    if (!snapshot || (snapshot.identity !== null && typeof snapshot.identity !== "string")
      || typeof snapshot.hasEntries !== "boolean"
      || typeof snapshot.usedBytes !== "bigint" || snapshot.usedBytes < 0n
      || typeof snapshot.availableBytes !== "bigint" || snapshot.availableBytes < 0n) {
      throw new StorageError("Original storage capacity could not be verified", { code: "STORAGE_UNAVAILABLE" });
    }
    if (!snapshot.identity && snapshot.hasEntries) {
      throw new StorageError("A nonempty original storage root has no verified identity", {
        code: "STORAGE_UNAVAILABLE",
      });
    }

    let writingBytes = 0n;
    for (const lease of leases) {
      if (staleLeaseIds.has(lease.id)) {
        await tx.storageWriteLease.deleteMany({ where: { id: lease.id } });
        if (lease.host === hostname && lease.pid === pid) localLeases.delete(lease.id);
        continue;
      }
      if (!snapshot.identity || lease.storageIdentity !== snapshot.identity || lease.sizeBytes < 1n) {
        throw new StorageError("Storage write reservations require recovery", { code: "STORAGE_UNAVAILABLE" });
      }
      writingBytes += lease.sizeBytes;
    }

    const sessions = await tx.uploadSession.findMany({
      where: {
        OR: [
          { storageReservationBytes: null },
          { storageReservationBytes: { gt: 0n } },
          { status: { in: ["OPEN", "COMPLETING"] } },
        ],
      },
      select: {
        storageDriver: true,
        storageKey: true,
        status: true,
        expectedSizeBytes: true,
        storageReservationBytes: true,
      },
    });
    let reservedBytes = 0n;
    for (const session of sessions) {
      if (session.storageReservationBytes == null || session.storageReservationBytes < 1n
        || session.expectedSizeBytes == null
        || session.storageReservationBytes < reservationFor(session.expectedSizeBytes)) {
        throw new StorageError("An existing upload has an unverified storage reservation", {
          code: "STORAGE_UNAVAILABLE",
        });
      }
      requireLocation(snapshot.identity, session.storageKey, session.storageDriver);
      reservedBytes += session.storageReservationBytes;
    }

    const clips = await tx.clip.findMany({
      where: { storageKey: { not: null } },
      select: { storageDriver: true, storageKey: true },
    });
    for (const clip of clips) requireLocation(snapshot.identity, clip.storageKey, clip.storageDriver);
    return { ...snapshot, reservedBytes, writingBytes };
  }

  function assertRoom(snapshot, additionalBytes, outstandingBytes) {
    if (snapshot.usedBytes + outstandingBytes + additionalBytes > maxStorageBytes) {
      throw new StorageError("Original storage capacity is full; retry after space is available", {
        code: "STORAGE_CAPACITY_EXCEEDED",
      });
    }
    if (snapshot.availableBytes < minFreeBytes + outstandingBytes + additionalBytes) {
      throw new StorageError("Original storage has insufficient free space; retry after space is available", {
        code: "STORAGE_CAPACITY_EXCEEDED",
      });
    }
  }

  async function reserve(tx, expectedSizeBytes) {
    const reservationBytes = reservationFor(expectedSizeBytes);
    await lockStorageCapacity(tx);
    const snapshot = await inspect(tx);
    assertRoom(snapshot, reservationBytes, snapshot.reservedBytes + snapshot.writingBytes);
    return { reservationBytes, identity: snapshot.identity };
  }

  async function withWritePermit(session, sizeBytes, work) {
    if (typeof sizeBytes !== "bigint" || sizeBytes < 1n || sizeBytes > MAX_DATABASE_BIGINT - WRITE_OVERHEAD_BYTES
      || typeof work !== "function") {
      throw new StorageError("A valid write size is required for storage capacity", {
        code: "STORAGE_UNAVAILABLE",
      });
    }
    const leaseId = randomUUID();
    localLeases.set(leaseId, "active");
    try {
      await db.$transaction(async tx => {
        await lockStorageCapacity(tx);
        const snapshot = await inspect(tx);
        const current = await tx.uploadSession.findUnique({
          where: { id: session.id },
          select: {
            status: true, expectedSizeBytes: true, storageReservationBytes: true, storageKey: true, storageDriver: true,
          },
        });
        if (current?.status === "COMPLETING") {
          throw new StorageError("Upload session is completing", { code: "SESSION_BUSY" });
        }
        if (!current || current.status !== "OPEN"
          || current.expectedSizeBytes == null || sizeBytes > current.expectedSizeBytes
          || current.storageReservationBytes == null
          || current.storageReservationBytes < reservationFor(current.expectedSizeBytes)) {
          throw new StorageError("Upload storage reservation is unavailable", { code: "STORAGE_UNAVAILABLE" });
        }
        requireLocation(snapshot.identity, current.storageKey, current.storageDriver);
        const leaseBytes = sizeBytes + WRITE_OVERHEAD_BYTES;
        assertRoom(snapshot, leaseBytes, snapshot.writingBytes);
        await tx.storageWriteLease.create({
          data: {
            id: leaseId,
            uploadSessionId: session.id,
            storageIdentity: snapshot.identity,
            sizeBytes: leaseBytes,
            host: hostname,
            pid,
          },
        });
      }, { timeout: 60000 });
    } catch (error) {
      localLeases.delete(leaseId);
      throw error;
    }

    let workError;
    try {
      return await work();
    } catch (error) {
      workError = error;
      throw error;
    } finally {
      localLeases.set(leaseId, "finished");
      try {
        await db.$transaction(async tx => {
          await lockStorageCapacity(tx);
          await tx.storageWriteLease.deleteMany({ where: { id: leaseId, host: hostname, pid } });
        }, { timeout: 60000 });
        localLeases.delete(leaseId);
      } catch (releaseError) {
        if (workError) {
          throw new AggregateError(
            [workError, releaseError],
            "Storage write and reservation release both failed",
            { cause: workError },
          );
        }
        throw releaseError;
      }
    }
  }

  return { reserve, withWritePermit };
}
