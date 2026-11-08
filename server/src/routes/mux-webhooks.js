// Last updated: May 10, 2026 - 12:55pm - GitHub Copilot (GPT-5.3-Codex)
/**
 * Mux Webhook Routes
 *
 * Mux sends webhook events when video processing completes.
 * We use these to update clip records with playback IDs and thumbnails.
 *
 * Webhook URL to configure in Mux dashboard:
 *   https://your-domain.onrender.com/api/webhooks/mux
 */
import prisma from '../lib/prisma.js';
import Mux from '@mux/mux-node';
import { disableMuxPlayback, getMuxAsset, MUX_ENV_KEY } from '../lib/mux.js';
import { dbRetry } from '../lib/utils.js';
import { teamScope } from '../lib/authorization.js';
import { notifyDashboardAssetChange } from '../ws/dashboard-notifications.js';
import { userRoom } from '../ws/rooms.js';
import fs from 'fs/promises';
import path from 'path';

const MUX_WEBHOOK_SECRET = process.env.MUX_WEBHOOK_SECRET;

// Mux v12: verifySignature is an instance method, not static
const muxClient = new Mux();

export default async function muxWebhookRoutes(fastify) {
    /**
     * POST /api/webhooks/mux
     * Receives Mux webhook events (video.asset.ready, video.upload.asset_created, etc.)
     */
    fastify.post('/api/webhooks/mux', {
        config: {
            // Don't parse body as JSON — we need the raw body for signature verification
            rawBody: true,
        },
    }, async (request, reply) => {
        // ─── Signature Verification ───────────────────────────────
        if (!MUX_WEBHOOK_SECRET) {
            request.log.error('MUX_WEBHOOK_SECRET missing — rejecting webhook');
            return reply.status(500).send({ error: 'Webhook signature verification not configured' });
        }

        const signature = request.headers['mux-signature'];
        if (!signature) {
            request.log.warn('Mux webhook missing signature header');
            return reply.status(401).send({ error: 'Missing signature' });
        }

        try {
            const rawBody = request.rawBody
                ? (Buffer.isBuffer(request.rawBody) ? request.rawBody.toString('utf8') : String(request.rawBody))
                : (typeof request.body === 'string' ? request.body : JSON.stringify(request.body));
            muxClient.webhooks.verifySignature(rawBody, { 'mux-signature': signature }, MUX_WEBHOOK_SECRET);
        } catch (err) {
            request.log.warn({ err: { message: err.message } }, 'Mux webhook signature verification failed');
            return reply.status(401).send({ error: 'Invalid signature' });
        }

        let event = request.body;
        if (typeof event === 'string') {
            try {
                event = JSON.parse(event);
            } catch {
                return reply.status(400).send({ error: 'Invalid JSON payload' });
            }
        }
        const eventType = event?.type;
        const eventData = event?.data;

        request.log.info({ eventType }, 'Mux webhook received');

        switch (eventType) {
            // Upload completed → Mux created an asset. Store the asset ID on our clip.
            case 'video.upload.asset_created': {
                const muxUploadId = eventData?.id;
                const muxAssetId = eventData?.asset_id;

                if (!muxUploadId || !muxAssetId) break;

                // Find our clip by muxUploadId
                const clip = await dbRetry(() =>
                    prisma.clip.findFirst({ where: { muxUploadId } })
                );

                if (clip) {
                    await dbRetry(() => prisma.clip.update({
                        where: { id: clip.id },
                        data: { muxAssetId },
                    }));
                    request.log.info({ muxAssetId, clipId: clip.id }, 'Linked mux asset to clip');
                }
                break;
            }

            // Asset is ready — video processing complete, playback IDs available
            case 'video.asset.ready': {
                const muxAssetId = eventData?.id;
                const playbackIds = eventData?.playback_ids;
                const passthrough = eventData?.passthrough;

                if (!muxAssetId) break;

                // Get the public playback ID
                const publicPlayback = playbackIds?.find(p => p.policy === 'public');
                const muxPlaybackId = publicPlayback?.id;

                if (!muxPlaybackId) {
                    request.log.warn({ muxAssetId }, 'Mux asset ready without public playback ID');
                    break;
                }

                // Build stream and thumbnail URLs
                const streamUrl = `https://stream.mux.com/${muxPlaybackId}.m3u8`;
                const thumbnailUrl = `https://image.mux.com/${muxPlaybackId}/thumbnail.png?width=640`;

                // Try to find clip by muxAssetId first, then by passthrough
                let clip = await dbRetry(() =>
                    prisma.clip.findFirst({ where: { muxAssetId } })
                );

                if (!clip && passthrough) {
                    try {
                        const meta = JSON.parse(passthrough);
                        if (meta.clipId) {
                            clip = await dbRetry(() =>
                                prisma.clip.findUnique({ where: { id: meta.clipId } })
                            );
                        }
                    } catch { /* passthrough wasn't valid JSON */ }
                }

                if (clip) {
                    const canPlay = await dbRetry(() => prisma.$transaction(async tx => {
                        const rows = await tx.$queryRaw`
                            SELECT moderation FROM assets WHERE id = ${clip.assetId} FOR UPDATE
                        `;
                        if (!rows.length) return false;
                        const active = rows[0].moderation === 'ACTIVE';
                        await tx.clip.update({
                            where: { id: clip.id },
                            data: {
                                muxAssetId,
                                muxPlaybackId: active ? muxPlaybackId : null,
                                streamUrl: active ? streamUrl : null,
                                thumbnailUrl: active ? thumbnailUrl : null,
                                status: 'READY',
                            },
                        });
                        await tx.asset.update({
                            where: { id: clip.assetId },
                            data: { status: 'READY' },
                        });
                        return active;
                    }));

                    let asset = canPlay ? await dbRetry(() => prisma.asset.findUnique({
                        where: { id: clip.assetId },
                        include: { formResponse: true },
                    })) : null;
                    if (canPlay && asset?.moderation !== 'ACTIVE') {
                        const revoked = await disableMuxPlayback(muxAssetId);
                        if (!revoked.ok) {
                            request.log.error({ muxAssetId, clipId: clip.id }, 'Could not revoke playback for moderated asset');
                            return reply.status(502).send({ error: 'Could not revoke playback for moderated asset' });
                        }
                        await dbRetry(() => prisma.clip.update({
                            where: { id: clip.id },
                            data: { muxPlaybackId: null, streamUrl: null, thumbnailUrl: null },
                        }));
                        asset = null;
                    } else if (!canPlay) {
                        const revoked = await disableMuxPlayback(muxAssetId);
                        if (!revoked.ok) {
                            request.log.error({ muxAssetId, clipId: clip.id }, 'Could not revoke playback for moderated asset');
                            return reply.status(502).send({ error: 'Could not revoke playback for moderated asset' });
                        }
                    }

                    request.log.info(
                        { clipId: clip.id, muxPlaybackId: asset ? muxPlaybackId : null },
                        asset ? 'Mux asset ready' : 'Mux asset ready while moderated'
                    );

                    // ─── Temp file cleanup ────────────────────────────────
                    // Delete local file now that Mux has the video
                    if (clip.storageUrl?.startsWith('/uploads/')) {
                        const localPath = path.resolve(process.cwd(), clip.storageUrl.slice(1));
                        try {
                            await fs.unlink(localPath);
                            request.log.info({ storageUrl: clip.storageUrl }, 'Deleted local clip file after mux ready');
                        } catch (unlinkErr) {
                            // File may already be gone (Render ephemeral disk) — that's OK
                            if (unlinkErr.code !== 'ENOENT') {
                                request.log.warn(
                                    { storageUrl: clip.storageUrl, err: { message: unlinkErr.message } },
                                    'Failed to delete local clip file after mux ready'
                                );
                            }
                        }
                    }

                    // Notify only when the asset remains available for playback.
                    if (asset) {
                        fastify.io.to(userRoom(asset.userId)).emit('mux:ready', {
                            assetId: asset.id,
                            clipId: clip.id,
                            mediasourceId: asset.mediasourceId,
                            mediasourceUrl: asset.mediasourceUrl,
                            originalFileName: asset.originalFileName,
                            muxPlaybackId,
                            streamUrl,
                            thumbnailUrl,
                            formSlug: asset.formResponse?.slug || null,
                            formType: asset.formResponse?.type || null,
                            formDescription: asset.formResponse?.description || null,
                            formPriority: asset.formResponse?.priority || null,
                            duration: clip.duration,
                            resolution: clip.resolution,
                            fileSize: clip.fileSize?.toString() || null,
                        });
                        await notifyDashboardAssetChange(fastify, asset.id);
                    }
                } else {
                    request.log.warn({ muxAssetId }, 'Mux asset ready but no matching clip found');
                }
                break;
            }

            // Asset errored during processing
            case 'video.asset.errored': {
                const muxAssetId = eventData?.id;
                const errors = eventData?.errors;

                request.log.error({ muxAssetId, errors }, 'Mux asset errored');

                const clip = await dbRetry(() =>
                    prisma.clip.findFirst({ where: { muxAssetId } })
                );

                if (clip) {
                    await dbRetry(() => prisma.clip.update({
                        where: { id: clip.id },
                        data: { status: 'ERROR' },
                    }));
                    await dbRetry(() => prisma.asset.update({
                        where: { id: clip.assetId },
                        data: { status: 'ERROR' },
                    }));
                    await notifyDashboardAssetChange(fastify, clip.assetId);
                }
                break;
            }

            default:
                // Log unhandled event types for debugging
                request.log.info({ eventType }, 'Mux webhook event unhandled');
        }

        // Always return 200 so Mux doesn't retry
        return { received: true };
    });

    /**
     * GET /api/mux/status/:clipId
     * Check Mux processing status for a clip (polling fallback if webhooks are delayed).
     */
    fastify.get('/api/mux/status/:clipId', {
        preHandler: [fastify.authenticate],
    }, async (request, reply) => {
        const { clipId } = request.params;

        const clip = await prisma.clip.findFirst({
            where: { id: clipId, asset: { ...teamScope(request.user), moderation: 'ACTIVE' } },
            select: {
                id: true,
                assetId: true,
                muxAssetId: true,
                muxPlaybackId: true,
                muxUploadId: true,
                streamUrl: true,
                thumbnailUrl: true,
                status: true,
            },
        });

        if (!clip) {
            return reply.status(404).send({ error: 'Clip not found' });
        }

        // If we have a playback ID, it's ready
        if (clip.muxPlaybackId) {
            return {
                status: 'ready',
                muxPlaybackId: clip.muxPlaybackId,
                streamUrl: clip.streamUrl,
                thumbnailUrl: clip.thumbnailUrl,
            };
        }

        // If we have an upload ID but no asset ID yet, check with Mux
        if (clip.muxUploadId && !clip.muxAssetId) {
            const { getMuxUpload } = await import('../lib/mux.js');
            const upload = await getMuxUpload(clip.muxUploadId);
            if (upload?.asset_id) {
                // Upload completed, store the asset ID
                await dbRetry(() => prisma.clip.update({
                    where: { id: clipId },
                    data: { muxAssetId: upload.asset_id },
                }));
                clip.muxAssetId = upload.asset_id;
            }
        }

        // If we have a Mux asset ID but no playback ID, check if it's ready
        if (clip.muxAssetId && !clip.muxPlaybackId) {
            const muxAsset = await getMuxAsset(clip.muxAssetId);
            if (muxAsset?.status === 'ready') {
                const playbackId = muxAsset.playback_ids?.find(p => p.policy === 'public')?.id;
                if (playbackId) {
                    const streamUrl = `https://stream.mux.com/${playbackId}.m3u8`;
                    const thumbnailUrl = `https://image.mux.com/${playbackId}/thumbnail.png?width=640`;

                    const active = await dbRetry(() => prisma.$transaction(async tx => {
                        const rows = await tx.$queryRaw`
                            SELECT moderation FROM assets WHERE id = ${clip.assetId} FOR UPDATE
                        `;
                        if (!rows.length || rows[0].moderation !== 'ACTIVE') return false;
                        await tx.clip.update({
                            where: { id: clipId },
                            data: { muxPlaybackId: playbackId, streamUrl, thumbnailUrl, status: 'READY' },
                        });
                        await tx.asset.update({
                            where: { id: clip.assetId },
                            data: { status: 'READY' },
                        });
                        return true;
                    }));
                    if (!active) {
                        const revoked = await disableMuxPlayback(clip.muxAssetId);
                        if (!revoked.ok) {
                            return reply.status(502).send({ error: 'Could not revoke playback for moderated asset' });
                        }
                        return reply.status(404).send({ error: 'Clip not found' });
                    }

                    await notifyDashboardAssetChange(fastify, clip.assetId);
                    return { status: 'ready', muxPlaybackId: playbackId, streamUrl, thumbnailUrl };
                }
            }
        }

        return { status: clip.status === 'PROCESSING' ? 'processing' : clip.status.toLowerCase() };
    });

    /**
     * GET /api/mux/env-key
     * Return the Mux environment key for client-side Mux Player.
     */
    fastify.get('/api/mux/env-key', async () => ({
        envKey: MUX_ENV_KEY,
        enabled: !!MUX_ENV_KEY,
    }));
}
