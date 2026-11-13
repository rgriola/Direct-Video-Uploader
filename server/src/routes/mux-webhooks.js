/**
 * Mux webhook and polling routes.
 *
 * Signed events only record remote references and queue reconciliation. The
 * coordinator is the sole writer of Mux playback IDs and media status.
 */
import Mux from '@mux/mux-node';
import prisma from '../lib/prisma.js';
import { MUX_ENV_KEY } from '../lib/mux.js';
import { queueAssetMediaSync, recordMuxAssetReference, reconcileAssetMedia } from '../lib/media-reconciliation.js';
import { retainMuxOriginalAsset, retainRetiredMuxOriginalAsset } from '../lib/mux-original-records.js';
import { dbRetry } from '../lib/utils.js';
import { teamScope } from '../lib/authorization.js';

const MUX_WEBHOOK_SECRET = process.env.MUX_WEBHOOK_SECRET;
const muxClient = new Mux();

function parsePassthrough(value, log) {
    if (!value) return null;
    try {
        const parsed = JSON.parse(value);
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed;
    } catch {
        log.warn('Invalid Mux passthrough');
        return null;
    }
    log.warn('Invalid Mux passthrough');
    return null;
}

async function findMuxAssetOwner(muxAssetId, passthrough, log) {
    const meta = parsePassthrough(passthrough, log);
    const metaClipId = typeof meta?.clipId === 'string' && meta.clipId ? meta.clipId : null;
    const metaAssetId = typeof meta?.assetId === 'string' && meta.assetId ? meta.assetId : null;
    const reference = await prisma.muxAssetReference.findUnique({ where: { muxAssetId } });
    let clip = await prisma.clip.findFirst({ where: { muxAssetId } });
    if (!clip && metaClipId) {
        clip = await prisma.clip.findUnique({ where: { id: metaClipId } });
    }
    if (!clip && reference?.clipId) {
        clip = await prisma.clip.findUnique({ where: { id: reference.clipId } });
    }

    const assetId = reference?.assetId || clip?.assetId || metaAssetId;
    if (!assetId) return null;
    if ((reference && reference.assetId !== assetId)
        || (clip && clip.assetId !== assetId)
        || (metaAssetId && metaAssetId !== assetId)) {
        throw new Error('Mux event references conflicting assets');
    }
    return { assetId, clipId: clip?.id || reference?.clipId || metaClipId, clip };
}

async function queueMuxAsset({ assetId, clipId, clip, muxAssetId }) {
    return prisma.$transaction(async tx => {
        const queued = await queueAssetMediaSync(tx, assetId);
        if (queued.count !== 1) return false;
        await recordMuxAssetReference(tx, { assetId, clipId, muxAssetId });
        if (clip) {
            await tx.clip.updateMany({
                where: { id: clip.id, assetId, OR: [{ muxAssetId: null }, { muxAssetId }] },
                data: { muxAssetId },
            });
        }
        return true;
    });
}

export default async function muxWebhookRoutes(fastify) {
    fastify.post('/api/webhooks/mux', {
        config: { rawBody: true },
    }, async (request, reply) => {
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
        } catch {
            request.log.warn('Mux webhook signature verification failed');
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

        if (['video.asset.created', 'video.asset.ready', 'video.asset.errored'].includes(eventType)) {
            const meta = parsePassthrough(eventData?.passthrough, request.log);
            if (meta?.ingestOperationId !== undefined) {
                if (typeof eventData?.id !== 'string' || !eventData.id
                    || typeof meta.ingestOperationId !== 'string' || !meta.ingestOperationId
                    || (meta.assetId !== undefined && typeof meta.assetId !== 'string')
                    || (meta.clipId !== undefined && typeof meta.clipId !== 'string')) {
                    return reply.status(400).send({ error: 'Invalid Mux original ingest event' });
                }
                const retained = await dbRetry(() => prisma.$transaction(async tx => {
                    const result = await retainMuxOriginalAsset(tx, {
                        operationId: meta.ingestOperationId,
                        muxAssetId: eventData.id,
                        expectedAssetId: meta.assetId,
                        expectedClipId: meta.clipId,
                    });
                    if (result.matched) return result;
                    const retired = await retainRetiredMuxOriginalAsset(tx, {
                        operationId: meta.ingestOperationId,
                        muxAssetId: eventData.id,
                    });
                    return { matched: false, retired };
                }));
                if (!retained.matched) {
                    request.log.error(
                        { operationId: meta.ingestOperationId, muxAssetId: eventData.id },
                        retained.retired
                            ? 'Mux original event after account deletion requires manual reconciliation'
                            : 'Mux original event has no matching ingest attempt',
                    );
                    return reply.status(503).send({
                        error: retained.retired
                            ? 'Mux reference retained; manual reconciliation required'
                            : 'Could not retain Mux ingest reference',
                    });
                }
                if (retained.conflict) {
                    request.log.error(
                        { operationId: meta.ingestOperationId, muxAssetId: eventData.id },
                        'Mux original event requires manual reconciliation',
                    );
                }
                if (eventType === 'video.asset.errored') {
                    request.log.error({ muxAssetId: eventData.id }, 'Mux asset errored');
                }
                await reconcileAssetMedia(fastify, retained.assetId);
                return { received: true };
            }
        }

        let owner = null;
        let muxAssetId = null;
        if (eventType === 'video.upload.asset_created') {
            if (typeof eventData?.id !== 'string' || !eventData.id
                || typeof eventData?.asset_id !== 'string' || !eventData.asset_id) {
                return reply.status(400).send({ error: 'Invalid Mux upload event' });
            }
            muxAssetId = eventData.asset_id;
            const clip = await dbRetry(() => prisma.clip.findFirst({ where: { muxUploadId: eventData.id } }));
            if (clip) owner = { assetId: clip.assetId, clipId: clip.id, clip };
            else {
                owner = await dbRetry(() => findMuxAssetOwner(
                    muxAssetId, eventData.new_asset_settings?.passthrough, request.log,
                ));
            }
        } else if (['video.asset.ready', 'video.asset.errored'].includes(eventType)) {
            if (typeof eventData?.id !== 'string' || !eventData.id) {
                return reply.status(400).send({ error: 'Invalid Mux asset event' });
            }
            muxAssetId = eventData.id;
            owner = await dbRetry(() => findMuxAssetOwner(muxAssetId, eventData.passthrough, request.log));
            if (eventType === 'video.asset.errored') {
                request.log.error({ muxAssetId }, 'Mux asset errored');
            }
        } else {
            request.log.info({ eventType }, 'Mux webhook event unhandled');
            return { received: true };
        }

        if (!owner) {
            request.log.warn({ muxAssetId, eventType }, 'Mux event has no matching local asset');
            return { received: true };
        }

        const queued = await dbRetry(() => queueMuxAsset({ ...owner, muxAssetId }));
        if (!queued) {
            request.log.error({ muxAssetId, assetId: owner.assetId }, 'Mux event references a missing local asset');
            return reply.status(503).send({ error: 'Could not retain Mux asset reference' });
        }

        await reconcileAssetMedia(fastify, owner.assetId);
        return { received: true };
    });

    fastify.get('/api/mux/status/:clipId', {
        preHandler: [fastify.authenticate],
    }, async (request, reply) => {
        const where = {
            id: request.params.clipId,
            asset: { ...teamScope(request.user), moderation: 'ACTIVE' },
        };
        const select = {
            id: true,
            assetId: true,
            muxAssetId: true,
            muxPlaybackId: true,
            muxUploadId: true,
            streamUrl: true,
            thumbnailUrl: true,
            status: true,
            asset: {
                select: { mediaPlaybackReset: true, mediaCreateOperationId: true, mediaSyncState: true },
            },
        };
        let clip = await prisma.clip.findFirst({ where, select });
        if (!clip) return reply.status(404).send({ error: 'Clip not found' });

        if ((clip.muxAssetId || clip.muxUploadId)
            && (!clip.muxPlaybackId || clip.asset.mediaPlaybackReset || clip.asset.mediaCreateOperationId)) {
            if (clip.asset.mediaSyncState === 'SYNCED') await queueAssetMediaSync(prisma, clip.assetId);
            await reconcileAssetMedia(fastify, clip.assetId);
            clip = await prisma.clip.findFirst({ where, select });
            if (!clip) return reply.status(404).send({ error: 'Clip not found' });
        }

        if (clip.muxPlaybackId && !clip.asset.mediaPlaybackReset && !clip.asset.mediaCreateOperationId) {
            return {
                status: 'ready',
                muxPlaybackId: clip.muxPlaybackId,
                streamUrl: clip.streamUrl,
                thumbnailUrl: clip.thumbnailUrl,
            };
        }
        return {
            status: clip.status === 'READY' ? 'processing' : clip.status.toLowerCase(),
            mediaSyncState: clip.asset.mediaSyncState,
        };
    });

    fastify.get('/api/mux/env-key', async () => ({
        envKey: MUX_ENV_KEY,
        enabled: !!MUX_ENV_KEY,
    }));
}
