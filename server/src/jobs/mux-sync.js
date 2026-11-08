// Last updated: May 10, 2026 - 12:55pm - GitHub Copilot (GPT-5.3-Codex)
/**
 * Mux Status Sync — Background Job
 *
 * Periodically checks for clips stuck in PROCESSING and syncs their
 * actual status from the Mux API. Alerts via Slack when clips are
 * stuck for too long or encounter errors.
 *
 * Runs every 2 minutes. A clip is considered "stale" if it's been
 * PROCESSING for more than 5 minutes.
 */
import prisma from '../lib/prisma.js';
import { getMuxAsset, getMuxUpload, isMuxEnabled } from '../lib/mux.js';
import { dbRetry } from '../lib/utils.js';
import * as slack from '../lib/slack.js';
import { notifyDashboardAssetChange } from '../ws/dashboard-notifications.js';
import { userRoom } from '../ws/rooms.js';

const SYNC_INTERVAL_MS = 2 * 60 * 1000;  // 2 minutes
const STALE_THRESHOLD_MS = 5 * 60 * 1000; // 5 minutes before alerting
let intervalId = null;
let syncLog = null;

/**
 * Check all PROCESSING clips and sync status from Mux.
 */
async function syncProcessingClips(fastify) {
    if (!isMuxEnabled) return;
    const log = fastify.log;
    const io = fastify.io;

    try {
        const stuckClips = await prisma.clip.findMany({
            where: { status: 'PROCESSING' },
            include: {
                asset: {
                    select: { id: true, mediasourceId: true, mediasourceUrl: true, userId: true },
                },
            },
        });

        if (stuckClips.length === 0) return;

        log.info({ clipCount: stuckClips.length }, 'Mux sync checking processing clips');

        for (const clip of stuckClips) {
            const age = Date.now() - new Date(clip.createdAt).getTime();
            const ageMin = Math.round(age / 60000);

            // Step 1: If no muxAssetId, try to get it from the upload
            if (!clip.muxAssetId && clip.muxUploadId) {
                const upload = await getMuxUpload(clip.muxUploadId);
                if (upload?.asset_id) {
                    await dbRetry(() => prisma.clip.update({
                        where: { id: clip.id },
                        data: { muxAssetId: upload.asset_id },
                    }));
                    clip.muxAssetId = upload.asset_id;
                    log.info({ clipId: clip.id, muxAssetId: upload.asset_id }, 'Mux sync linked asset to clip');
                }
            }

            // Step 2: If we have a muxAssetId, check its status
            if (clip.muxAssetId) {
                const muxAsset = await getMuxAsset(clip.muxAssetId);

                if (muxAsset?.status === 'ready') {
                    const playbackId = muxAsset.playback_ids?.find(playback => playback.policy === 'public')?.id;
                    const result = await dbRetry(() => prisma.$transaction(async tx => {
                        const rows = await tx.$queryRaw`
                            SELECT moderation FROM assets WHERE id = ${clip.asset.id} FOR UPDATE
                        `;
                        if (!rows.length) return { state: 'missing' };
                        if (rows[0].moderation !== 'ACTIVE') return { state: 'moderated' };
                        if (!playbackId) return { state: 'missingPlayback' };

                        const streamUrl = `https://stream.mux.com/${playbackId}.m3u8`;
                        const thumbnailUrl = `https://image.mux.com/${playbackId}/thumbnail.png?width=640`;
                        await tx.clip.update({
                            where: { id: clip.id },
                            data: { muxPlaybackId: playbackId, streamUrl, thumbnailUrl, status: 'READY' },
                        });
                        await tx.asset.update({
                            where: { id: clip.asset.id },
                            data: { status: 'READY' },
                        });
                        return { state: 'ready', playbackId, streamUrl, thumbnailUrl };
                    }));

                    if (result.state === 'moderated') {
                        if (playbackId) {
                            log.error(
                                { clipId: clip.id, muxAssetId: clip.muxAssetId },
                                'Mux sync skipped moderated clip; check public playback revocation'
                            );
                        }
                        continue;
                    }
                    if (result.state === 'missingPlayback') {
                        log.warn({ clipId: clip.id, muxAssetId: clip.muxAssetId }, 'Mux sync ready asset has no public playback ID');
                        continue;
                    }
                    if (result.state !== 'ready') continue;

                    const fullAsset = await prisma.asset.findUnique({
                        where: { id: clip.asset.id },
                        include: { formResponse: true },
                    });
                    if (!fullAsset || fullAsset.moderation !== 'ACTIVE') {
                        log.warn({ clipId: clip.id }, 'Mux sync skipped ready notification for unavailable asset');
                        continue;
                    }

                    log.info(
                        { clipId: clip.id, mediasourceId: clip.asset.mediasourceId, ageMinutes: ageMin },
                        'Mux sync moved clip to ready'
                    );

                    io.to(userRoom(clip.asset.userId)).emit('mux:ready', {
                        assetId: clip.asset.id,
                        clipId: clip.id,
                        mediasourceId: clip.asset.mediasourceId,
                        mediasourceUrl: clip.asset.mediasourceUrl,
                        originalFileName: fullAsset.originalFileName || null,
                        muxPlaybackId: result.playbackId,
                        streamUrl: result.streamUrl,
                        thumbnailUrl: result.thumbnailUrl,
                        formSlug: fullAsset.formResponse?.slug || null,
                        formType: fullAsset.formResponse?.type || null,
                        formDescription: fullAsset.formResponse?.description || null,
                        formPriority: fullAsset.formResponse?.priority || null,
                        duration: clip.duration,
                        resolution: clip.resolution,
                        fileSize: clip.fileSize?.toString() || null,
                    });
                    await notifyDashboardAssetChange(fastify, clip.asset.id);
                } else if (muxAsset?.status === 'errored') {
                    await dbRetry(() => prisma.clip.update({
                        where: { id: clip.id },
                        data: { status: 'ERROR' },
                    }));
                    await dbRetry(() => prisma.asset.update({
                        where: { id: clip.asset.id },
                        data: { status: 'ERROR' },
                    }));
                    await notifyDashboardAssetChange(fastify, clip.asset.id);

                    log.error({ clipId: clip.id, mediasourceId: clip.asset.mediasourceId }, 'Mux sync moved clip to error');

                    // Alert via Slack
                    if (slack.isConfigured()) {
                        await slack.postToChannel('general',
                            `⚠️ Mux processing error — clip #${clip.asset.mediasourceId} failed after ${ageMin}min`,
                            undefined,
                            { requestId: 'job:mux-sync' }
                        );
                    }
                } else if (age > STALE_THRESHOLD_MS) {
                    // Still processing after threshold — log warning (only once per cycle)
                    log.warn(
                        {
                            clipId: clip.id,
                            mediasourceId: clip.asset.mediasourceId,
                            ageMinutes: ageMin,
                            muxStatus: muxAsset?.status || 'unknown',
                        },
                        'Mux sync clip still processing past stale threshold'
                    );
                }
            } else if (age > 15 * 60 * 1000) {
                // No muxAssetId after 15 min — upload never completed, mark as ERROR
                log.error(
                    { clipId: clip.id, mediasourceId: clip.asset.mediasourceId, ageMinutes: ageMin },
                    'Mux sync clip missing mux asset past timeout; marking error'
                );
                await dbRetry(() => prisma.clip.update({
                    where: { id: clip.id },
                    data: { status: 'ERROR' },
                }));
                await dbRetry(() => prisma.asset.update({
                    where: { id: clip.asset.id },
                    data: { status: 'ERROR' },
                }));
                await notifyDashboardAssetChange(fastify, clip.asset.id);
                if (slack.isConfigured()) {
                    await slack.postToChannel('general',
                        `⚠️ Upload failed — clip #${clip.asset.mediasourceId} had no Mux asset after ${ageMin}min (auto-marked ERROR)`,
                        undefined,
                        { requestId: 'job:mux-sync' }
                    );
                }
            } else if (age > STALE_THRESHOLD_MS) {
                // No muxAssetId but under 30min — still waiting
                log.warn(
                    { clipId: clip.id, mediasourceId: clip.asset.mediasourceId, ageMinutes: ageMin },
                    'Mux sync clip still waiting for mux asset id'
                );
            }
        }
    } catch (err) {
        log.error({ err: { message: err.message } }, 'Mux sync job failed');
    }
}

/**
 * Backfill READY clips that are missing muxPlaybackId.
 * These clips were marked READY before playback data was saved.
 */
async function backfillMissingPlaybackIds(fastify) {
    if (!isMuxEnabled) return;
    const log = fastify.log;

    try {
        const clips = await prisma.clip.findMany({
            where: { status: 'READY', muxPlaybackId: null, muxUploadId: { not: null }, asset: { moderation: 'ACTIVE' } },
            select: { id: true, assetId: true, muxUploadId: true, muxAssetId: true },
        });

        if (clips.length === 0) return;

        log.info({ clipCount: clips.length }, 'Mux backfill checking ready clips missing playback id');

        for (const clip of clips) {
            let assetId = clip.muxAssetId;
            if (!assetId && clip.muxUploadId) {
                const upload = await getMuxUpload(clip.muxUploadId);
                assetId = upload?.asset_id;
                if (assetId) {
                    await dbRetry(() => prisma.clip.update({
                        where: { id: clip.id },
                        data: { muxAssetId: assetId },
                    }));
                }
            }

            if (assetId) {
                const muxAsset = await getMuxAsset(assetId);
                const playbackId = muxAsset?.playback_ids?.find(p => p.policy === 'public')?.id;
                if (playbackId) {
                    const streamUrl = `https://stream.mux.com/${playbackId}.m3u8`;
                    const thumbnailUrl = `https://image.mux.com/${playbackId}/thumbnail.png?width=640`;
                    const updated = await dbRetry(() => prisma.$transaction(async tx => {
                        const rows = await tx.$queryRaw`
                            SELECT moderation FROM assets WHERE id = ${clip.assetId} FOR UPDATE
                        `;
                        if (!rows.length || rows[0].moderation !== 'ACTIVE') return false;
                        await tx.clip.update({
                            where: { id: clip.id },
                            data: { muxPlaybackId: playbackId, streamUrl, thumbnailUrl },
                        });
                        return true;
                    }));
                    if (updated) {
                        log.info({ clipId: clip.id, muxPlaybackId: playbackId }, 'Mux backfill wrote playback id');
                        await notifyDashboardAssetChange(fastify, clip.assetId);
                    }
                }
            }
        }
    } catch (err) {
        log.error({ err: { message: err.message } }, 'Mux backfill job failed');
    }
}

/**
 * Start the background sync loop.
 * @param {import('socket.io').Server} io — Socket.IO server for push notifications
 */
export function startMuxSync(fastify) {
    const log = fastify.log;
    syncLog = log;

    if (!isMuxEnabled) {
        log.info('Mux sync skipped because mux is not configured');
        return;
    }

    // Run once immediately (catches anything stuck from before a deploy)
    setTimeout(() => syncProcessingClips(fastify), 10_000);

    // Backfill READY clips missing playback data (one-time on boot)
    setTimeout(() => backfillMissingPlaybackIds(fastify), 15_000);

    // Then run on interval
    intervalId = setInterval(() => syncProcessingClips(fastify), SYNC_INTERVAL_MS);
    log.info({ intervalSeconds: SYNC_INTERVAL_MS / 1000 }, 'Mux sync worker started');
}

/** Stop the sync loop (called during graceful shutdown). */
export function stopMuxSync() {
    if (intervalId) {
        clearInterval(intervalId);
        intervalId = null;
        syncLog?.info('Mux sync stopped');
    }
}
