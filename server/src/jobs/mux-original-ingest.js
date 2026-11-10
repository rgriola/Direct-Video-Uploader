import { randomUUID } from 'node:crypto';
import prisma from '../lib/prisma.js';
import * as mux from '../lib/mux.js';
import { withAssetMediaLock } from '../lib/media-lock.js';
import { createStorageDriver } from '../lib/storage/driver.js';
import { queueAssetMediaSync, reconcileAssetMedia } from '../lib/media-reconciliation.js';
import { lockMuxOriginalRows, originalIngestEligibility, retainMuxOriginalAsset } from '../lib/mux-original-records.js';
import { signMuxOriginalRead } from '../lib/mux-original-signing.js';

const MAX_FAILURES = 3;
const RETRY_DELAY_MS = 10_000;
const DEFER_DELAY_MS = 30_000;
const CYCLE_INTERVAL_MS = 10_000;
const BATCH_SIZE = 20;

const sessionInclude = {
    owner: { select: { status: true } },
    asset: { select: { userId: true, moderation: true, status: true } },
    clip: true,
    muxIngestJob: true,
};

function nextRetry(now, failures) {
    return new Date(now.getTime() + RETRY_DELAY_MS * (2 ** (failures - 1)));
}

export function createMuxOriginalWorker({
    db = prisma,
    muxApi = mux,
    withLock = withAssetMediaLock,
    storageFactory = createStorageDriver,
    reconcile = reconcileAssetMedia,
    clock = () => new Date(),
    config = { enabled: false },
} = {}) {
    async function lockedSession(tx, snapshot) {
        await lockMuxOriginalRows(tx, snapshot);
        return tx.uploadSession.findUnique({ where: { id: snapshot.id }, include: sessionInclude });
    }

    async function recordLocalFailure(snapshot) {
        return db.$transaction(async tx => {
            const session = await lockedSession(tx, snapshot);
            const job = session?.muxIngestJob;
            if (!job || job.status !== 'QUEUED' || job.nextAttemptAt > clock()) return false;
            const failures = job.retryCount + 1;
            await tx.muxIngestJob.update({
                where: { uploadSessionId: session.id },
                data: {
                    retryCount: failures,
                    status: failures >= MAX_FAILURES ? 'FAILED' : 'QUEUED',
                    nextAttemptAt: failures >= MAX_FAILURES ? null : nextRetry(clock(), failures),
                    lastError: 'Original storage is unavailable or has changed',
                },
            });
            return true;
        });
    }

    async function recoverInterrupted(snapshot) {
        return db.$transaction(async tx => {
            const session = await lockedSession(tx, snapshot);
            const job = session?.muxIngestJob;
            if (!job || job.status !== 'CREATING') return false;
            const attempt = job.currentAttemptId && await tx.muxIngestAttempt.findUnique({
                where: { id: job.currentAttemptId },
            });
            if (!attempt || attempt.uploadSessionId !== session.id || attempt.status !== 'CREATING') {
                await tx.muxIngestJob.update({
                    where: { uploadSessionId: session.id },
                    data: {
                        status: 'CONFLICT',
                        nextAttemptAt: null,
                        lastError: 'Mux ingest references require manual reconciliation',
                    },
                });
                await queueAssetMediaSync(tx, session.assetId, { resetPlayback: true });
                return true;
            }
            await tx.muxIngestAttempt.update({
                where: { id: attempt.id },
                data: { status: 'UNKNOWN' },
            });
            await tx.muxIngestJob.update({
                where: { uploadSessionId: session.id },
                data: {
                    status: 'UNKNOWN',
                    nextAttemptAt: null,
                    lastError: 'Mux asset creation outcome is unknown',
                },
            });
            await queueAssetMediaSync(tx, session.assetId);
            return true;
        });
    }

    async function prepareAttempt(snapshot) {
        return db.$transaction(async tx => {
            const session = await lockedSession(tx, snapshot);
            const job = session?.muxIngestJob;
            if (!job || job.status !== 'QUEUED' || !job.nextAttemptAt || job.nextAttemptAt > clock()) {
                return null;
            }
            const state = originalIngestEligibility(session);
            if (state === 'DEFERRED') {
                await tx.muxIngestJob.update({
                    where: { uploadSessionId: session.id },
                    data: { nextAttemptAt: new Date(clock().getTime() + DEFER_DELAY_MS) },
                });
                return null;
            }
            const previousReference = await tx.muxAssetReference.findFirst({
                where: { assetId: session.assetId },
                select: { muxAssetId: true },
            });
            if (state !== 'READY' || previousReference) {
                await tx.muxIngestJob.update({
                    where: { uploadSessionId: session.id },
                    data: {
                        status: previousReference ? 'CONFLICT' : 'FAILED',
                        nextAttemptAt: null,
                        lastError: previousReference
                            ? 'Mux ingest references require manual reconciliation'
                            : 'Original is not eligible for Mux ingest',
                    },
                });
                if (previousReference) await queueAssetMediaSync(tx, session.assetId, { resetPlayback: true });
                return null;
            }
            const operationId = randomUUID();
            const expires = Math.floor((clock().getTime() + config.readTtlMs) / 1000);
            await tx.muxIngestAttempt.create({
                data: {
                    id: operationId,
                    uploadSessionId: session.id,
                    readExpiresAt: new Date(expires * 1000),
                },
            });
            await tx.muxIngestJob.update({
                where: { uploadSessionId: session.id },
                data: {
                    status: 'CREATING',
                    attemptCount: { increment: 1 },
                    currentAttemptId: operationId,
                    nextAttemptAt: null,
                    lastError: null,
                },
            });
            return { operationId, expires, assetId: session.assetId, clipId: session.clipId };
        });
    }

    async function recordOutcome(snapshot, operation, result) {
        return db.$transaction(async tx => {
            if (result.ok) {
                return retainMuxOriginalAsset(tx, {
                    operationId: operation.operationId,
                    muxAssetId: result.muxAssetId,
                    expectedAssetId: operation.assetId,
                    expectedClipId: operation.clipId,
                    now: clock(),
                });
            }
            const session = await lockedSession(tx, snapshot);
            if (!session?.muxIngestJob) return { matched: false };
            const attempt = await tx.muxIngestAttempt.findUnique({ where: { id: operation.operationId } });
            if (!attempt || attempt.uploadSessionId !== session.id) return { matched: false };
            if (attempt.status === 'LINKED') return { matched: true };
            if (!['CREATING', 'UNKNOWN'].includes(attempt.status)) return { matched: true };

            const indeterminate = result.indeterminate !== false;
            await tx.muxIngestAttempt.update({
                where: { id: attempt.id },
                data: {
                    status: indeterminate ? 'UNKNOWN' : 'REJECTED',
                    ...(indeterminate ? {} : { resolvedAt: clock() }),
                },
            });
            const job = session.muxIngestJob;
            if (job.currentAttemptId === attempt.id && job.status !== 'CONFLICT') {
                const failures = job.retryCount + (indeterminate ? 0 : 1);
                const retry = !indeterminate && result.retryable === true && failures < MAX_FAILURES;
                await tx.muxIngestJob.update({
                    where: { uploadSessionId: session.id },
                    data: {
                        status: indeterminate ? 'UNKNOWN' : retry ? 'QUEUED' : 'FAILED',
                        retryCount: failures,
                        nextAttemptAt: retry ? nextRetry(clock(), failures) : null,
                        lastError: indeterminate
                            ? 'Mux asset creation outcome is unknown'
                            : result.retryable === true
                                ? 'Mux rate limited asset creation'
                                : 'Mux rejected asset creation',
                    },
                });
            }
            if (indeterminate || job.status === 'CONFLICT') {
                await queueAssetMediaSync(tx, session.assetId, { resetPlayback: job.status === 'CONFLICT' });
            }
            return { matched: true };
        });
    }

    async function processJob(fastify, job) {
        const snapshot = job.uploadSession;
        const locked = await withLock(snapshot.assetId, async assertLocked => {
            await assertLocked();
            if (job.status === 'CREATING') return recoverInterrupted(snapshot);
            if (!config.enabled) return false;
            const current = await db.uploadSession.findUnique({
                where: { id: snapshot.id }, include: sessionInclude,
            });
            if (originalIngestEligibility(current) === 'READY') {
                try {
                    const storage = storageFactory({ provider: current.storageDriver });
                    await storage.assertStorageLocation(current.storageKey);
                    const file = await storage.stat(current.storageKey);
                    if (!file || file.sizeBytes !== current.expectedSizeBytes.toString()) {
                        throw new Error('Stored original is unavailable or has changed');
                    }
                } catch {
                    fastify.log.error({ uploadSessionId: snapshot.id }, 'Original storage preflight failed');
                    await recordLocalFailure(snapshot);
                    return false;
                }
            }
            await assertLocked();
            const operation = await prepareAttempt(snapshot);
            if (!operation) return false;
            await assertLocked();
            const signature = signMuxOriginalRead(config.signingSecret, operation.operationId, operation.expires);
            const sourceUrl = `${config.baseUrl}/api/mux-originals/${operation.operationId}`
                + `?expires=${operation.expires}&signature=${signature}`;
            let result;
            try {
                result = await muxApi.createMuxOriginalAsset({ sourceUrl, ...operation });
            } catch {
                result = {
                    ok: false,
                    indeterminate: true,
                    retryable: false,
                    error: 'Mux asset creation outcome is unknown',
                };
            }
            await recordOutcome(snapshot, operation, result);
            return true;
        });
        if (locked.acquired && locked.value) await reconcile(fastify, snapshot.assetId);
    }

    async function runOnce(fastify) {
        const due = await db.muxIngestJob.findMany({
            where: {
                OR: [
                    { status: 'CREATING' },
                    ...(config.enabled ? [{ status: 'QUEUED', nextAttemptAt: { lte: clock() } }] : []),
                ],
            },
            orderBy: [{ createdAt: 'asc' }, { uploadSessionId: 'asc' }],
            take: BATCH_SIZE,
            include: { uploadSession: true },
        });
        for (const job of due) {
            try {
                await processJob(fastify, job);
            } catch {
                fastify.log.error({ uploadSessionId: job.uploadSessionId }, 'Mux original ingest job failed');
            }
        }
    }

    return { runOnce };
}

export function startMuxOriginalIngest(fastify, config) {
    const worker = createMuxOriginalWorker({ config });
    let running = false;
    const run = async () => {
        if (running) return;
        running = true;
        try {
            await worker.runOnce(fastify);
        } catch {
            fastify.log.error('Mux original ingest worker failed');
        } finally {
            running = false;
        }
    };
    const startup = setTimeout(() => { void run(); }, 1000);
    const interval = setInterval(() => { void run(); }, CYCLE_INTERVAL_MS);
    fastify.log.info({ enabled: config.enabled }, 'Mux original ingest worker started');
    return () => {
        clearTimeout(startup);
        clearInterval(interval);
    };
}
