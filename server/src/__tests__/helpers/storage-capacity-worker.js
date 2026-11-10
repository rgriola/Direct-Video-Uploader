import { createHash } from "node:crypto";
import { createLocalStorageDriver } from "../../lib/storage/local-driver.js";
import { createStorageCapacity } from "../../lib/storage/capacity.js";
import { createUploadSessionService } from "../../lib/upload-sessions.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const url = new URL(databaseUrl);
if (process.env.DATABASE_URL !== databaseUrl
  || !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)
  || !url.pathname.slice(1).startsWith("dvu_scope_test_")) {
  throw new Error("Storage worker requires a dedicated local dvu_scope_test_ database");
}
const { default: prisma, pool } = await import("../../lib/prisma.js");

const [ownerId, assetId, clipId, root, text, maxBytes] = process.argv.slice(2);
const storage = createLocalStorageDriver({ root });
const getSnapshot = storage.getCapacitySnapshot.bind(storage);
storage.getCapacitySnapshot = async () => ({
  ...await getSnapshot(),
  usedBytes: 0n,
  availableBytes: 1024n * 1024n * 1024n,
});
const capacity = createStorageCapacity({
  db: prisma, storage, maxStorageBytes: BigInt(maxBytes), minFreeBytes: 1024n * 1024n,
});
const service = createUploadSessionService({ db: prisma, storage, capacity });
const content = Buffer.from(text);

try {
  const session = await service.create({
    ownerId,
    assetId,
    clipId,
    expectedSizeBytes: content.length,
    expectedSha256: createHash("sha256").update(content).digest("hex"),
  });
  process.stdout.write(`RESULT ${JSON.stringify({ status: "created", id: session.id })}\n`);
} catch (error) {
  if (error.code !== "STORAGE_CAPACITY_EXCEEDED") throw error;
  process.stdout.write(`RESULT ${JSON.stringify({ status: "full", code: error.code })}\n`);
} finally {
  await prisma.$disconnect();
  await pool.end();
}
