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

const SYNC_INTERVAL_MS = 2 * 60 * 1000;  // 2 minutes
const STALE_THRESHOLD_MS = 5 * 60 * 1000; // 5 minutes before alerting
let intervalId = null;

/**
 * Check all PROCESSING clips and sync status from Mux.
 */
async function syncProcessingClips(fastify) {
    if (!isMuxEnabled) return;
    const io = fastify.io;
    const userSockets = fastify.userSockets;

    try {
        const stuckClips = await prisma.clip.findMany({
            where: { status: 'PROCESSING' },
            include: {
                asset: {
                    select: { id: true, mediasourceId: true, userId: true },
                },
            },
        });

        if (stuckClips.length === 0) return;

        console.log(`🔄 Mux sync: checking ${stuckClips.length} PROCESSING clip(s)`);

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
                    console.log(`🔄 Mux sync: linked asset ${upload.asset_id} to clip ${clip.id}`);
                }
            }

            // Step 2: If we have a muxAssetId, check its status
            if (clip.muxAssetId) {
                const muxAsset = await getMuxAsset(clip.muxAssetId);

                if (muxAsset?.status === 'ready') {
                    const playbackId = muxAsset.playback_ids?.find(p => p.policy === 'public')?.id;
                    if (playbackId) {
                        const streamUrl = `https://stream.mux.com/${playbackId}.m3u8`;
                        const thumbnailUrl = `https://image.mux.com/${playbackId}/thumbnail.png?width=640`;

                        await dbRetry(() => prisma.clip.update({
                            where: { id: clip.id },
                            data: { muxPlaybackId: playbackId, streamUrl, thumbnailUrl, status: 'READY' },
                        }));
                        await dbRetry(() => prisma.asset.update({
                            where: { id: clip.asset.id },
                            data: { status: 'READY' },
                        }));

                        console.log(`🔄 Mux sync: clip ${clip.id} (#${clip.asset.mediasourceId}) → READY (was stuck ${ageMin}min)`);

                        // Notify only the asset owner (not all clients)
                        const ownerSockets = userSockets?.get(clip.asset.userId);
                        if (ownerSockets) {
                            // Fetch form response for the payload
                            const fullAsset = await prisma.asset.findUnique({
                                where: { id: clip.asset.id },
                                include: { formResponse: true },
                            });
                            for (const sid of ownerSockets) {
                                io.to(sid).emit('mux:ready', {
                                    assetId: clip.asset.id,
                                    clipId: clip.id,
                                    mediasourceId: clip.asset.mediasourceId,
                                    originalFileName: fullAsset?.originalFileName || null,
                                    muxPlaybackId: playbackId,
                                    streamUrl,
                                    thumbnailUrl,
                                    formSlug: fullAsset?.formResponse?.slug || null,
                                    formType: fullAsset?.formResponse?.type || null,
                                    formDescription: fullAsset?.formResponse?.description || null,
                                    formPriority: fullAsset?.formResponse?.priority || null,
                                    duration: clip.duration,
                                    resolution: clip.resolution,
                                    fileSize: clip.fileSize?.toString() || null,
                                });
                            }
                        }
                    }
                } else if (muxAsset?.status === 'errored') {
                    await dbRetry(() => prisma.clip.update({
                        where: { id: clip.id },
                        data: { status: 'ERROR' },
                    }));
                    await dbRetry(() => prisma.asset.update({
                        where: { id: clip.asset.id },
                        data: { status: 'ERROR' },
                    }));

                    console.error(`🔄 Mux sync: clip ${clip.id} (#${clip.asset.mediasourceId}) → ERROR`);

                    // Alert via Slack
                    if (slack.isConfigured()) {
                        await slack.postToChannel('general',
                            `⚠️ Mux processing error — clip #${clip.asset.mediasourceId} failed after ${ageMin}min`
                        );
                    }
                } else if (age > STALE_THRESHOLD_MS) {
                    // Still processing after threshold — log warning (only once per cycle)
                    console.warn(`🔄 Mux sync: clip ${clip.id} (#${clip.asset.mediasourceId}) still processing after ${ageMin}min (Mux status: ${muxAsset?.status || 'unknown'})`);
                }
            } else if (age > 15 * 60 * 1000) {
                // No muxAssetId after 15 min — upload never completed, mark as ERROR
                console.error(`🔄 Mux sync: clip ${clip.id} (#${clip.asset.mediasourceId}) has no Mux asset after ${ageMin}min — marking ERROR`);
                await dbRetry(() => prisma.clip.update({
                    where: { id: clip.id },
                    data: { status: 'ERROR' },
                }));
                await dbRetry(() => prisma.asset.update({
                    where: { id: clip.asset.id },
                    data: { status: 'ERROR' },
                }));
                if (slack.isConfigured()) {
                    await slack.postToChannel('general',
                        `⚠️ Upload failed — clip #${clip.asset.mediasourceId} had no Mux asset after ${ageMin}min (auto-marked ERROR)`
                    );
                }
            } else if (age > STALE_THRESHOLD_MS) {
                // No muxAssetId but under 30min — still waiting
                console.warn(`🔄 Mux sync: clip ${clip.id} (#${clip.asset.mediasourceId}) has no Mux asset after ${ageMin}min`);
            }
        }
    } catch (err) {
        console.error('🔄 Mux sync error:', err.message);
    }
}

/**
 * Backfill READY clips that are missing muxPlaybackId.
 * These clips were marked READY before playback data was saved.
 */
async function backfillMissingPlaybackIds() {
    if (!isMuxEnabled) return;

    try {
        const clips = await prisma.clip.findMany({
            where: { status: 'READY', muxPlaybackId: null, muxUploadId: { not: null } },
            select: { id: true, muxUploadId: true, muxAssetId: true },
        });

        if (clips.length === 0) return;

        console.log(`🔄 Mux backfill: ${clips.length} READY clip(s) missing playbackId`);

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
                    await dbRetry(() => prisma.clip.update({
                        where: { id: clip.id },
                        data: { muxPlaybackId: playbackId, streamUrl, thumbnailUrl },
                    }));
                    console.log(`🔄 Mux backfill: clip ${clip.id} → playbackId: ${playbackId}`);
                }
            }
        }
    } catch (err) {
        console.error('🔄 Mux backfill error:', err.message);
    }
}

/**
 * Start the background sync loop.
 * @param {import('socket.io').Server} io — Socket.IO server for push notifications
 */
export function startMuxSync(fastify) {
    if (!isMuxEnabled) {
        console.log('⏭️  Mux sync skipped — Mux not configured');
        return;
    }

    // Run once immediately (catches anything stuck from before a deploy)
    setTimeout(() => syncProcessingClips(fastify), 10_000);

    // Backfill READY clips missing playback data (one-time on boot)
    setTimeout(() => backfillMissingPlaybackIds(), 15_000);

    // Then run on interval
    intervalId = setInterval(() => syncProcessingClips(fastify), SYNC_INTERVAL_MS);
    console.log(`[Background Worker] Working for the man... 🔄 checking PROCESSING clips every ${SYNC_INTERVAL_MS / 1000}s`);
}

/** Stop the sync loop (called during graceful shutdown). */
export function stopMuxSync() {
    if (intervalId) {
        clearInterval(intervalId);
        intervalId = null;
        console.log('🔄 Mux sync stopped');
    }
}
