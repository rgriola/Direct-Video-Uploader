import { createUploadSessionRecovery, UploadSessionError } from '../lib/upload-sessions.js';
import { createStorageDriver } from '../lib/storage/driver.js';
import { lockStorageCapacity } from '../lib/storage/capacity.js';
import { StorageError } from '../lib/storage/local-driver.js';

const CYCLE_INTERVAL_MS = 5 * 60 * 1000;
const SESSION_BATCH_SIZE = 50;
const INVENTORY_BATCH_SIZE = 100;
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const SESSION_DIRECTORY = new RegExp(`^${UUID}$`, 'i');
const COMPLETION_LOCK = new RegExp(`^\\.completion-(${UUID})(\\.recovery)?$`, 'i');

function errorDetails(error) {
    const name = error instanceof Error ? error.name : 'Error';
    const message = error instanceof Error ? error.message : String(error);
    const code = typeof error?.code === 'string' ? ` [${error.code}]` : '';
    if (error instanceof AggregateError) {
        const causes = error.errors.map(cause => errorDetails(cause).message).join('; ');
        return { name, message: `${message}${code}: ${causes}` };
    }
    return { name, message: `${message}${code}` };
}

export function createUploadSessionCleanupWorker({
    db,
    storage,
    log,
    onCompleted,
    withLock,
    clock = () => new Date(),
    sessionBatchSize = SESSION_BATCH_SIZE,
    inventoryBatchSize = INVENTORY_BATCH_SIZE,
}) {
    if (!db || !storage || typeof storage.getCapacitySnapshot !== 'function'
        || typeof storage.openUploadInventory !== 'function'
        || typeof storage.assertUploadInventory !== 'function' || !log
        || typeof log.info !== 'function' || typeof log.warn !== 'function'
        || typeof log.error !== 'function' || typeof withLock !== 'function'
        || typeof clock !== 'function' || !Number.isSafeInteger(sessionBatchSize)
        || sessionBatchSize < 1 || !Number.isSafeInteger(inventoryBatchSize)
        || inventoryBatchSize < 1) {
        throw new TypeError('Upload session cleanup requires storage, database, logging, and bounded batches');
    }
    const recovery = createUploadSessionRecovery({ db, storage, now: clock, onCompleted });
    let cursor = null;
    let inventory = null;
    let running = false;

    async function closeInventory() {
        const current = inventory;
        inventory = null;
        if (current) await current.directory.close();
    }

    async function sweepSessions() {
        const candidates = await db.uploadSession.findMany({
            where: {
                ...(cursor ? { id: { gt: cursor } } : {}),
                OR: [
                    { status: 'OPEN', expiresAt: { lte: clock() } },
                    { status: 'COMPLETING' },
                    {
                        status: { in: ['ABORTED', 'EXPIRED', 'COMPLETED'] },
                        OR: [
                            { storageReservationBytes: null },
                            { storageReservationBytes: { gt: 0n } },
                        ],
                    },
                ],
            },
            select: { id: true, ownerId: true, assetId: true },
            orderBy: { id: 'asc' },
            take: sessionBatchSize,
        });
        const counts = { processed: 0, failed: 0, deferred: 0 };
        for (const candidate of candidates) {
            cursor = candidate.id;
            try {
                const locked = await withLock(candidate.assetId, async assertLocked => {
                    await assertLocked();
                    return recovery.recoverForSweep({
                        uploadSessionId: candidate.id,
                        ownerId: candidate.ownerId,
                        assetId: candidate.assetId,
                        assertLocked,
                    });
                });
                if (!locked.acquired || locked.value.status === 'busy') {
                    counts.deferred += 1;
                    log.warn({ uploadSessionId: candidate.id }, 'Original upload cleanup deferred because it is busy');
                } else if (locked.value.status === 'deferred') {
                    counts.deferred += 1;
                    log.warn(
                        { uploadSessionId: candidate.id, reason: locked.value.reason },
                        'Original upload cleanup requires reconciliation',
                    );
                } else if (locked.value.status !== 'unchanged') {
                    counts.processed += 1;
                    log.info(
                        { uploadSessionId: candidate.id, result: locked.value.status },
                        'Original upload recovery completed',
                    );
                }
            } catch (error) {
                if (error instanceof UploadSessionError && error.code === 'NOT_FOUND') {
                    log.info({ uploadSessionId: candidate.id }, 'Original upload changed before cleanup');
                } else if (error?.code === 'SESSION_BUSY') {
                    counts.deferred += 1;
                    log.warn({ uploadSessionId: candidate.id }, 'Original upload cleanup deferred because it is busy');
                } else {
                    counts.failed += 1;
                    log.error(
                        { uploadSessionId: candidate.id, err: errorDetails(error) },
                        'Original upload cleanup failed; recovery is required',
                    );
                }
            }
        }
        const scanComplete = candidates.length < sessionBatchSize;
        if (scanComplete) cursor = null;
        return { ...counts, scanComplete };
    }

    async function reportInventory() {
        if (!inventory) inventory = await storage.openUploadInventory();
        if (inventory?.unmarkedRoot) {
            inventory = null;
            // An empty unmarked root may be a missing volume, not a new installation.
            await db.$transaction(async tx => {
                await lockStorageCapacity(tx);
                const root = await storage.getCapacitySnapshot({ create: false });
                if (root.identity) return;
                const activeSession = await tx.uploadSession.findFirst({
                    where: {
                        OR: [
                            { storageReservationBytes: null },
                            { storageReservationBytes: { gt: 0n } },
                            { status: { in: ['OPEN', 'COMPLETING'] } },
                        ],
                    },
                    select: { id: true },
                });
                const original = await tx.clip.findFirst({
                    where: { storageKey: { not: null } },
                    select: { id: true },
                });
                const lease = await tx.storageWriteLease.findFirst({ select: { id: true } });
                if (root.hasEntries || activeSession || original || lease) {
                    throw new StorageError('Original upload inventory requires a verified storage root', {
                        code: 'STORAGE_UNAVAILABLE',
                    });
                }
            }, { timeout: 60000, isolationLevel: 'ReadCommitted' });
            return { inspected: 0, reported: 0 };
        }
        if (!inventory) return { inspected: 0, reported: 0 };

        const entries = [];
        let finished = false;
        try {
            await storage.assertUploadInventory(inventory);
            for (let count = 0; count < inventoryBatchSize; count += 1) {
                const entry = await inventory.directory.read();
                if (!entry) {
                    finished = true;
                    break;
                }
                const lock = COMPLETION_LOCK.exec(entry.name);
                if (SESSION_DIRECTORY.test(entry.name)) {
                    entries.push({ id: entry.name, kind: entry.isDirectory() ? 'directory' : 'invalid-directory' });
                } else if (lock) {
                    entries.push({
                        id: lock[1],
                        kind: !entry.isFile() ? 'invalid-lock' : lock[2] ? 'recovery-lock' : 'completion-lock',
                    });
                } else {
                    entries.push({ kind: 'unexpected' });
                }
            }
            if (finished) await closeInventory();
        } catch (error) {
            try {
                await closeInventory();
            } catch (closeError) {
                throw new AggregateError([error, closeError], 'Upload inventory and directory cleanup failed');
            }
            throw error;
        }

        const ids = [...new Set(entries.map(entry => entry.id).filter(Boolean))];
        const sessions = ids.length ? await db.$transaction(async tx => {
            await lockStorageCapacity(tx);
            return tx.uploadSession.findMany({
                where: { id: { in: ids } },
                select: { id: true, status: true, storageReservationBytes: true },
            });
        }, { timeout: 60000 }) : [];
        const tracked = new Map(sessions.map(session => [session.id, session]));
        let reported = 0;
        for (const entry of entries) {
            const session = tracked.get(entry.id);
            if (entry.kind === 'unexpected') {
                reported += 1;
                log.warn('Unrecognized original upload storage entry requires manual review');
            } else if (entry.kind === 'invalid-directory') {
                reported += 1;
                log.warn({ uploadSessionId: entry.id }, 'Invalid original upload directory requires manual review');
            } else if (entry.kind === 'invalid-lock') {
                reported += 1;
                log.warn({ uploadSessionId: entry.id }, 'Invalid original upload lock requires manual review');
            } else if (!session) {
                reported += 1;
                log.warn(
                    { uploadSessionId: entry.id, kind: entry.kind },
                    'Possible untracked original upload data requires manual review',
                );
            } else if (entry.kind === 'recovery-lock') {
                reported += 1;
                log.warn(
                    { uploadSessionId: entry.id },
                    'Original upload recovery lock may require manual review',
                );
            } else if (entry.kind === 'completion-lock'
                && ['ABORTED', 'EXPIRED', 'COMPLETED'].includes(session.status)
                && session.storageReservationBytes === 0n) {
                reported += 1;
                log.warn(
                    { uploadSessionId: entry.id, status: session.status },
                    'Finished upload completion lock may require manual review if it persists',
                );
            } else if (entry.kind === 'directory'
                && ['ABORTED', 'EXPIRED', 'COMPLETED'].includes(session.status)
                && session.storageReservationBytes != null && session.storageReservationBytes <= 0n) {
                reported += 1;
                log.warn(
                    { uploadSessionId: entry.id, status: session.status },
                    'Unexpected staged upload data requires manual review',
                );
            }
        }
        return { inspected: entries.length, reported };
    }

    async function runOnce() {
        if (running) throw new Error('Upload session cleanup is already running');
        running = true;
        try {
            const errors = [];
            let sessions;
            let inventoryResult;
            try {
                sessions = await sweepSessions();
            } catch (error) {
                errors.push(error);
            }
            try {
                inventoryResult = await reportInventory();
            } catch (error) {
                errors.push(error);
            }
            if (errors.length) throw new AggregateError(errors, 'Upload session cleanup cycle failed');
            return { sessions, inventory: inventoryResult };
        } finally {
            running = false;
        }
    }

    return { runOnce, close: closeInventory };
}

export function scheduleUploadSessionCleanup({
    worker, log, monitoring, intervalMs = CYCLE_INTERVAL_MS, clock = () => Date.now(),
}) {
    if (typeof worker?.runOnce !== 'function' || typeof worker?.close !== 'function'
        || typeof log?.info !== 'function' || typeof log?.error !== 'function'
        || (monitoring != null && typeof monitoring.registerCheck !== 'function')
        || !Number.isSafeInteger(intervalMs) || intervalMs < 1 || typeof clock !== 'function') {
        throw new TypeError('Upload session cleanup scheduler requires a worker, logger, and positive interval');
    }
    let running;
    let stopped = false;
    let stopping;
    const startedAt = clock();
    let lastCycleAt = null;
    let lastSuccessAt = null;
    let failurePending = false;
    let failedInScan = false;
    let firstFinished;
    const firstCycle = new Promise(resolve => { firstFinished = resolve; });
    const unregister = monitoring?.registerCheck({
        id: 'original-upload-cleanup',
        label: 'Original upload cleanup',
        category: 'service',
        async collect() {
            const initialAge = clock() - startedAt;
            if (lastCycleAt === null && Number.isFinite(initialAge)
                && initialAge >= -60_000 && initialAge < intervalMs * 3) {
                let timeout;
                try {
                    await Promise.race([
                        firstCycle,
                        new Promise(resolve => { timeout = setTimeout(resolve, intervalMs * 3 - initialAge); }),
                    ]);
                } finally {
                    clearTimeout(timeout);
                }
            }
            const age = clock() - (lastCycleAt ?? startedAt);
            if (!Number.isFinite(age) || age < -60_000) {
                return { status: 'unknown', message: 'Cleanup cycle time cannot be verified' };
            }
            if (age >= intervalMs * 3) {
                return { status: 'critical', message: 'No cleanup cycle has finished within the freshness limit' };
            }
            if (lastCycleAt === null) {
                return { status: 'unknown', message: 'No cleanup cycle has finished' };
            }
            if (failurePending) {
                return { status: 'critical', message: 'A cleanup failure requires recovery; inspect server logs' };
            }
            return {
                status: 'ok',
                message: 'Cleanup cycles are running',
                ...(lastSuccessAt === null ? {} : { lastSuccessAt: new Date(lastSuccessAt).toISOString() }),
            };
        },
    });
    const run = () => {
        if (stopped || running) return;
        running = Promise.resolve().then(() => worker.runOnce())
            .then(result => {
                if (!Number.isSafeInteger(result?.sessions?.failed) || result.sessions.failed < 0
                    || typeof result.sessions.scanComplete !== 'boolean') {
                    throw new Error('Upload session cleanup returned an invalid result');
                }
                if (result.sessions.failed > 0) {
                    failurePending = true;
                    failedInScan = true;
                }
                if (result.sessions.scanComplete) {
                    if (!failedInScan) {
                        failurePending = false;
                        lastSuccessAt = clock();
                    }
                    failedInScan = false;
                }
            })
            .catch(error => {
                failurePending = true;
                failedInScan = true;
                log.error({ err: errorDetails(error) }, 'Upload session cleanup cycle failed');
            })
            .finally(() => {
                lastCycleAt = clock();
                firstFinished();
                running = null;
            });
    };
    const startup = setTimeout(run, 0);
    const interval = setInterval(run, intervalMs);
    log.info({ intervalMs }, 'Upload session cleanup worker started');
    return () => {
        if (!stopping) {
            stopped = true;
            clearTimeout(startup);
            clearInterval(interval);
            stopping = (async () => {
                if (running) await running;
                await worker.close();
                firstFinished();
                unregister?.();
                log.info('Upload session cleanup worker stopped');
            })();
        }
        return stopping;
    };
}

export function startUploadSessionCleanup(fastify, {
    config,
    db,
    withLock,
    onCompleted,
} = {}) {
    if (typeof config?.enabled !== 'boolean') {
        throw new TypeError('Upload session cleanup requires explicit configuration');
    }
    if (!config.enabled) return async () => {};
    const storage = createStorageDriver({ provider: 'local', root: config.storageRoot });
    const worker = createUploadSessionCleanupWorker({ db, storage, log: fastify.log, withLock, onCompleted });
    return scheduleUploadSessionCleanup({ worker, log: fastify.log, monitoring: fastify.monitoring });
}
