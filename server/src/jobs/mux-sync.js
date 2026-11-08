/**
 * Periodically reconcile durable media work and report stale uploads.
 */
import prisma from '../lib/prisma.js';
import { isMuxEnabled } from '../lib/mux.js';
import { queueAssetMediaSync, reconcileAssetMedia } from '../lib/media-reconciliation.js';
import * as slack from '../lib/slack.js';
import { notifyDashboardAssetChange } from '../ws/dashboard-notifications.js';

const SYNC_INTERVAL_MS = 2 * 60 * 1000;
const STALE_THRESHOLD_MS = 5 * 60 * 1000;
const MISSING_ASSET_TIMEOUT_MS = 15 * 60 * 1000;
const RECONCILE_BATCH_SIZE = 20;
const RECONCILE_CONCURRENCY = 4;
let intervalId = null;
let startupTimer = null;
let running = false;
let syncLog = null;

async function reconcileDueAssets(fastify) {
    const assets = await prisma.asset.findMany({
        where: { mediaSyncNextAt: { lte: new Date() } },
        orderBy: [{ mediaSyncNextAt: 'asc' }, { id: 'asc' }],
        take: RECONCILE_BATCH_SIZE,
        select: { id: true },
    });

    for (let index = 0; index < assets.length; index += RECONCILE_CONCURRENCY) {
        await Promise.all(assets.slice(index, index + RECONCILE_CONCURRENCY)
            .map(asset => reconcileAssetMedia(fastify, asset.id)));
    }
}

async function queueMissingPlayback(fastify) {
    if (!isMuxEnabled) return;
    const clips = await prisma.clip.findMany({
        where: {
            status: 'READY',
            muxPlaybackId: null,
            OR: [{ muxAssetId: { not: null } }, { muxUploadId: { not: null } }],
            asset: { moderation: 'ACTIVE', mediaSyncState: 'SYNCED' },
        },
        select: { assetId: true },
        distinct: ['assetId'],
        take: RECONCILE_BATCH_SIZE,
    });
    for (const assetId of new Set(clips.map(clip => clip.assetId))) {
        await queueAssetMediaSync(prisma, assetId);
        await reconcileAssetMedia(fastify, assetId);
    }
}

async function checkProcessingClips(fastify) {
    if (!isMuxEnabled) return;
    const clips = await prisma.clip.findMany({
        where: { status: 'PROCESSING' },
        include: { asset: { select: { id: true, mediasourceId: true, mediaSyncState: true } } },
    });

    for (const clip of clips) {
        if (clip.asset.mediaSyncState === 'SYNCED') {
            await queueAssetMediaSync(prisma, clip.asset.id);
            await reconcileAssetMedia(fastify, clip.asset.id);
        }

        const current = await prisma.clip.findUnique({
            where: { id: clip.id },
            select: { status: true, muxAssetId: true },
        });
        if (!current || current.status !== 'PROCESSING') continue;

        const age = Date.now() - new Date(clip.createdAt).getTime();
        const ageMin = Math.round(age / 60000);
        if (!current.muxAssetId && age > MISSING_ASSET_TIMEOUT_MS) {
            const failed = await prisma.$transaction(async tx => {
                const updated = await tx.clip.updateMany({
                    where: { id: clip.id, status: 'PROCESSING', muxAssetId: null },
                    data: { status: 'ERROR' },
                });
                if (updated.count) {
                    await tx.asset.updateMany({ where: { id: clip.asset.id }, data: { status: 'ERROR' } });
                }
                return updated.count;
            });
            if (!failed) continue;

            fastify.log.error(
                { clipId: clip.id, mediasourceId: clip.asset.mediasourceId, ageMinutes: ageMin },
                'Mux sync clip missing mux asset past timeout; marking error',
            );
            await notifyDashboardAssetChange(fastify, clip.asset.id);
            if (slack.isConfigured()) {
                const alert = await slack.postToChannel(
                    'general',
                    `⚠️ Upload failed — clip #${clip.asset.mediasourceId} had no Mux asset after ${ageMin}min (auto-marked ERROR)`,
                    undefined,
                    { requestId: 'job:mux-sync' },
                );
                if (!alert.ok) fastify.log.error({ clipId: clip.id }, 'Could not send Mux upload alert');
            }
        } else if (age > STALE_THRESHOLD_MS) {
            fastify.log.warn(
                { clipId: clip.id, mediasourceId: clip.asset.mediasourceId, ageMinutes: ageMin },
                current.muxAssetId ? 'Mux sync clip still processing past stale threshold' : 'Mux sync clip still waiting for mux asset id',
            );
        }
    }
}

async function runSyncCycle(fastify) {
    if (running) return;
    running = true;
    try {
        await reconcileDueAssets(fastify);
        await queueMissingPlayback(fastify);
        await checkProcessingClips(fastify);
    } catch (err) {
        fastify.log.error({ err: { message: err.message } }, 'Mux sync job failed');
    } finally {
        running = false;
    }
}

export function startMuxSync(fastify) {
    if (intervalId) return;
    syncLog = fastify.log;
    if (!isMuxEnabled) syncLog.info('Mux is not configured; media reconciliation will check local media only');
    startupTimer = setTimeout(() => {
        startupTimer = null;
        void runSyncCycle(fastify);
    }, 10_000);
    intervalId = setInterval(() => { void runSyncCycle(fastify); }, SYNC_INTERVAL_MS);
    syncLog.info({ intervalSeconds: SYNC_INTERVAL_MS / 1000 }, 'Mux sync worker started');
}

export function stopMuxSync() {
    if (startupTimer) {
        clearTimeout(startupTimer);
        startupTimer = null;
    }
    if (intervalId) {
        clearInterval(intervalId);
        intervalId = null;
        syncLog?.info('Mux sync stopped');
    }
}
