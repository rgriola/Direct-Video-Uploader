// Last updated: May 11, 2026 - 5:21pm - GitHub Copilot (GPT-5.3-Codex)
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
import { getMuxAsset, MUX_ENV_KEY } from '../lib/mux.js';
import { dbRetry } from '../lib/utils.js';
import fs from 'fs/promises';
import path from 'path';

const MUX_WEBHOOK_SECRET = process.env.MUX_WEBHOOK_SECRET;
const uploadAssetCreatedTimestamps = new Map();

// Mux v12: verifySignature is an instance method, not static
const muxClient = new Mux();

function parsePassthrough(rawPassthrough) {
    if (!rawPassthrough || typeof rawPassthrough !== 'string') return null;

    try {
        const parsed = JSON.parse(rawPassthrough);
        return parsed && typeof parsed === 'object' ? parsed : null;
    } catch {
        return null;
    }
}

function parseTimestampMs(rawValue) {
    if (rawValue === undefined || rawValue === null) return null;

    const parsed = Number.parseInt(String(rawValue), 10);
    if (!Number.isFinite(parsed) || parsed <= 0) {
        return null;
    }

    return parsed;
}

function diffMs(startIso, endIso) {
    if (!startIso || !endIso) return null;

    const start = Date.parse(startIso);
    const end = Date.parse(endIso);
    if (!Number.isFinite(start) || !Number.isFinite(end)) {
        return null;
    }

    return Math.max(0, end - start);
}

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
                const webhookAssetCreatedAt = new Date().toISOString();
                const passthrough = parsePassthrough(
                    eventData?.passthrough || eventData?.new_asset_settings?.passthrough
                );

                if (!muxUploadId || !muxAssetId) break;

                uploadAssetCreatedTimestamps.set(muxUploadId, webhookAssetCreatedAt);

                // Find our clip by muxUploadId
                const clip = await dbRetry(() =>
                    prisma.clip.findFirst({ where: { muxUploadId } })
                );

                if (clip) {
                    await dbRetry(() => prisma.clip.update({
                        where: { id: clip.id },
                        data: { muxAssetId },
                    }));
                    request.log.info(
                        {
                            muxAssetId,
                            muxUploadId,
                            clipId: clip.id,
                            telemetryCorrelationId: passthrough?.telemetryCorrelationId || null,
                            webhookAssetCreatedAt,
                        },
                        'Linked mux asset to clip'
                    );
                }
                break;
            }

            // Asset is ready — video processing complete, playback IDs available
            case 'video.asset.ready': {
                const muxAssetId = eventData?.id;
                const playbackIds = eventData?.playback_ids;
                const passthrough = eventData?.passthrough;
                const webhookReadyAt = new Date().toISOString();

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

                const meta = parsePassthrough(passthrough);
                if (!clip && meta?.clipId) {
                    clip = await dbRetry(() =>
                        prisma.clip.findUnique({ where: { id: meta.clipId } })
                    );
                }

                const telemetryCorrelationId =
                    typeof meta?.telemetryCorrelationId === 'string'
                        ? meta.telemetryCorrelationId
                        : null;
                const clientUploadStartedAtMs = parseTimestampMs(meta?.clientUploadStartedAtMs);
                const serverUploadCreatedAt =
                    typeof meta?.serverUploadCreatedAt === 'string'
                        ? meta.serverUploadCreatedAt
                        : null;
                const serverUploadCreatedAtMs = parseTimestampMs(meta?.serverUploadCreatedAtMs);

                const muxUploadId = clip?.muxUploadId || null;
                const webhookAssetCreatedAt =
                    muxUploadId ? uploadAssetCreatedTimestamps.get(muxUploadId) || null : null;
                const serverToAssetCreatedMs = diffMs(serverUploadCreatedAt, webhookAssetCreatedAt);
                const serverToReadyMs = diffMs(serverUploadCreatedAt, webhookReadyAt);

                const uploadTelemetry = {
                    correlationId: telemetryCorrelationId,
                    muxUploadId,
                    clientUploadStartedAtMs,
                    serverUploadCreatedAt,
                    serverUploadCreatedAtMs,
                    webhookAssetCreatedAt,
                    webhookReadyAt,
                    serverToAssetCreatedMs,
                    serverToReadyMs,
                };

                if (clip) {
                    await dbRetry(() => prisma.clip.update({
                        where: { id: clip.id },
                        data: {
                            muxAssetId,
                            muxPlaybackId,
                            streamUrl,
                            thumbnailUrl,
                            status: 'READY',
                        },
                    }));

                    request.log.info(
                        {
                            clipId: clip.id,
                            muxPlaybackId,
                            telemetryCorrelationId,
                            muxUploadId,
                            serverUploadCreatedAt,
                            webhookAssetCreatedAt,
                            webhookReadyAt,
                            serverToAssetCreatedMs,
                            serverToReadyMs,
                        },
                        'Mux asset ready'
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

                    // Update the parent asset status to READY
                    await dbRetry(() => prisma.asset.update({
                        where: { id: clip.assetId },
                        data: { status: 'READY' },
                    }));

                    // Notify the asset owner via WebSocket (not all clients)
                    const asset = await prisma.asset.findUnique({
                        where: { id: clip.assetId },
                        include: { formResponse: true },
                    });
                    if (asset) {
                        const ownerSockets = fastify.userSockets?.get(asset.userId);
                        if (ownerSockets) {
                            for (const sid of ownerSockets) {
                                fastify.io.to(sid).emit('mux:ready', {
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
                                    uploadTelemetry,
                                });
                            }
                        }
                    }

                    if (muxUploadId) {
                        uploadAssetCreatedTimestamps.delete(muxUploadId);
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

                    if (clip.muxUploadId) {
                        uploadAssetCreatedTimestamps.delete(clip.muxUploadId);
                    }
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
    fastify.get('/api/mux/status/:clipId', async (request, reply) => {
        const { clipId } = request.params;

        const clip = await prisma.clip.findUnique({
            where: { id: clipId },
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

                    await dbRetry(() => prisma.clip.update({
                        where: { id: clipId },
                        data: { muxPlaybackId: playbackId, streamUrl, thumbnailUrl, status: 'READY' },
                    }));

                    // Also update the parent asset status
                    await dbRetry(() => prisma.asset.update({
                        where: { id: clip.assetId },
                        data: { status: 'READY' },
                    }));

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
