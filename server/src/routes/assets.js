// Last updated: May 10, 2026 - 10:15am - GitHub Copilot (GPT-5.3-Codex)
/**
 * Asset routes — Create, upload, retrieve, submit form.
 */
import { randomUUID } from 'crypto';
import prisma from '../lib/prisma.js';
import { generateMediasourceId, dbRetry, parseClientMetadata, serializeClip, notifyUserSockets } from '../lib/utils.js';
import { isMuxEnabled, createDirectUpload } from '../lib/mux.js';
import { queueAssetMediaSync } from '../lib/media-reconciliation.js';
import { withAssetMediaLock } from '../lib/media-lock.js';
import { canExposePlayback } from '../lib/media-visibility.js';
import { teamScope } from '../lib/authorization.js';
import { isSuperAdmin } from '../lib/roles.js';
import { notifyDashboardAssetChange } from '../ws/dashboard-notifications.js';
import { userRoom } from '../ws/rooms.js';

// Allowed video MIME types — kept for reference if local upload is re-enabled
const ALLOWED_VIDEO_MIMES = new Set([
    'video/mp4',
    'video/quicktime',
    'video/x-msvideo',     // AVI
    'video/x-matroska',    // MKV
    'video/webm',
    'video/3gpp',
    'video/3gpp2',
]);

function serializeAsset(asset) {
    const clips = asset.clips.map(clip => {
        const serialized = serializeClip(clip);
        if (!canExposePlayback(asset)) {
            return { ...serialized, storageUrl: null, muxPlaybackId: null, streamUrl: null, thumbnailUrl: null };
        }
        return serialized;
    });
    const {
        mediaCreateOperationId: _operationId,
        mediaCreateMuxAssetId: _muxAssetId,
        mediaCreateStartedAt: _startedAt,
        mediaSyncRevision: _revision,
        mediaSyncNextAt: _nextAt,
        mediaSyncError: _error,
        ...visible
    } = asset;
    return { ...visible, clips };
}

export default async function assetRoutes(fastify) {
    /**
     * POST /api/assets
     * Create a new asset record.
     * Body: { fileName?: string }
     */
    fastify.post('/api/assets', {
        preHandler: [fastify.authenticate],
        config: {
            rateLimit: { max: 10, timeWindow: '1 minute' },
        },
    }, async (request) => {
        const { fileName } = request.body || {};
        const mediasourceId = await generateMediasourceId(prisma);

        const asset = await dbRetry(() => prisma.asset.create({
            data: {
                userId: request.user.id,
                mediasourceId,
                mediasourceUrl: `/clips/${mediasourceId}`,
                originalFileName: fileName || null,
                status: 'UPLOADING',
            },
        }));

        await notifyDashboardAssetChange(fastify, asset.id);

        return {
            asset: {
                id: asset.id,
                mediasourceId: asset.mediasourceId,
                mediasourceUrl: asset.mediasourceUrl,
                originalFileName: asset.originalFileName,
                status: asset.status,
                clipCount: asset.clipCount,
                totalDuration: asset.totalDuration,
            },
        };
    });

    /**
     * POST /api/assets/:id/mux-upload
     * Create a Mux direct upload URL. iOS uploads directly to Mux's CDN,
     * bypassing the server for large file transfers.
     *
     * Body: { metadata?: { duration, resolution, codec, ... } }
     * Returns: { uploadUrl, clipId, muxUploadId }
     */
    fastify.post('/api/assets/:id/mux-upload', {
        preHandler: [fastify.authenticate],
    }, async (request, reply) => {
        const { id } = request.params;

        if (!isMuxEnabled) {
            return reply.status(503).send({ error: 'Mux not configured' });
        }

        const clientMeta = request.body?.metadata || {};
        const mimeType = String(clientMeta.mimeType || clientMeta.contentType || clientMeta.type || '')
            .trim()
            .toLowerCase();

        if (mimeType && !ALLOWED_VIDEO_MIMES.has(mimeType)) {
            return reply.status(415).send({ error: `Unsupported media type: ${mimeType}` });
        }
        const metadata = parseClientMetadata(clientMeta);
        let fileSize;
        try {
            fileSize = clientMeta.fileSize ? BigInt(clientMeta.fileSize) : null;
        } catch {
            return reply.status(400).send({ error: 'Invalid file size' });
        }

        let locked;
        try {
            locked = await withAssetMediaLock(id, async assertLocked => {
                const asset = await dbRetry(() => prisma.asset.findUnique({ where: { id } }));
                if (!asset || asset.userId !== request.user.id) {
                    return { status: 404, body: { error: 'Asset not found' } };
                }
                if (asset.moderation !== 'ACTIVE') {
                    return { status: 409, body: { error: 'This asset is not accepting uploads while it is moderated' } };
                }

                const existingClip = await dbRetry(() => prisma.clip.findFirst({
                    where: {
                        assetId: id,
                        status: 'PROCESSING',
                        OR: [
                            { muxUploadId: { not: null } },
                            { muxUploadId: null, muxAssetId: null, storageUrl: null },
                        ],
                    },
                    orderBy: { createdAt: 'desc' },
                }));
                let staleClip = null;
                if (existingClip?.muxUploadId) {
                    const { getMuxUpload } = await import('../lib/mux.js');
                    let upload;
                    try {
                        upload = await getMuxUpload(existingClip.muxUploadId);
                    } catch (err) {
                        request.log.warn({ err: { message: err.message } }, 'Could not fetch Mux upload status');
                    }
                    if (!upload || typeof upload.status !== 'string'
                        || (upload.status === 'waiting' && !upload.url)
                        || !['waiting', 'asset_created', 'cancelled', 'timed_out', 'errored'].includes(upload.status)) {
                        request.log.warn({ muxUploadId: existingClip.muxUploadId }, 'Cannot verify existing Mux upload status');
                        return { status: 503, body: { error: 'Could not verify the existing upload. Please try again.' } };
                    }
                    if (upload.status === 'asset_created') {
                        return { status: 409, body: { error: 'The existing upload is already processing.' } };
                    }
                    if (upload.status === 'waiting') {
                        await assertLocked();
                        const current = await prisma.asset.findUnique({ where: { id } });
                        if (!current || current.userId !== request.user.id || current.moderation !== 'ACTIVE') {
                            return { status: 409, body: { error: 'This asset is not accepting uploads while it is moderated' } };
                        }
                        return {
                            status: 200,
                            body: { uploadUrl: upload.url, clipId: existingClip.id, muxUploadId: existingClip.muxUploadId },
                        };
                    }
                    staleClip = existingClip;
                } else if (existingClip) {
                    staleClip = existingClip;
                }

                if (staleClip && (staleClip.muxAssetId || staleClip.muxPlaybackId
                    || staleClip.storageUrl || staleClip.streamUrl || staleClip.thumbnailUrl
                    || await prisma.muxAssetReference.findFirst({
                    where: { assetId: id, clipId: staleClip.id },
                    select: { muxAssetId: true },
                }))) {
                    await queueAssetMediaSync(prisma, id);
                    return { status: 409, body: { error: 'The previous upload has media requiring reconciliation.' } };
                }

                const clipId = randomUUID();
                const claimed = await dbRetry(() => prisma.$transaction(async tx => {
                    const updated = await tx.asset.updateMany({
                        where: { id, userId: request.user.id, moderation: 'ACTIVE' },
                        data: {
                            status: 'PROCESSING',
                            ...(!staleClip ? { clipCount: { increment: 1 } } : {}),
                            totalDuration: metadata.duration,
                        },
                    });
                    if (updated.count !== 1) return false;
                    if (staleClip) {
                        const deleted = await tx.clip.deleteMany({
                            where: { id: staleClip.id, assetId: id, status: 'PROCESSING', muxAssetId: null },
                        });
                        if (deleted.count !== 1) throw new Error('Previous upload changed while being replaced');
                    }
                    await tx.clip.create({
                        data: {
                            id: clipId,
                            assetId: id,
                            clipIndex: 0,
                            originalFileName: clientMeta.fileName || asset.originalFileName || null,
                            fileSize,
                            ...metadata,
                            status: 'PROCESSING',
                        },
                    });
                    await queueAssetMediaSync(tx, id);
                    return true;
                }));
                if (!claimed) {
                    return { status: 409, body: { error: 'This asset is not accepting uploads while it is moderated' } };
                }

                let muxResult;
                try {
                    await assertLocked();
                    muxResult = await createDirectUpload({ clipId, assetId: id });
                    if (!muxResult) throw new Error('Mux upload creation is not configured');
                } catch (err) {
                    request.log.error({ assetId: id, err: { message: err.message } }, 'Mux upload creation failed');
                    await dbRetry(() => prisma.$transaction(async tx => {
                        await tx.asset.updateMany({
                            where: { id, clips: { none: { id: { not: clipId }, status: 'PROCESSING' } } },
                            data: { status: 'ERROR' },
                        });
                        await tx.clip.updateMany({
                            where: { id: clipId, assetId: id, muxUploadId: null },
                            data: { status: 'ERROR' },
                        });
                        await queueAssetMediaSync(tx, id);
                    }));
                    return { status: 502, body: { error: 'Failed to create Mux upload. Please try again.' } };
                }

                await dbRetry(() => prisma.$transaction(async tx => {
                    await queueAssetMediaSync(tx, id);
                    const linked = await tx.clip.updateMany({
                        where: { id: clipId, assetId: id, muxUploadId: null },
                        data: { muxUploadId: muxResult.muxUploadId },
                    });
                    if (linked.count !== 1) throw new Error('Mux upload could not be linked to its clip');
                }));
                await assertLocked();

                const current = await prisma.asset.findUnique({ where: { id } });
                if (!current || current.userId !== request.user.id || current.moderation !== 'ACTIVE') {
                    return { status: 409, body: { error: 'This asset is not accepting uploads while it is moderated' } };
                }
                return {
                    status: 200,
                    body: { uploadUrl: muxResult.uploadUrl, clipId, muxUploadId: muxResult.muxUploadId },
                    asset,
                };
            });
        } catch (err) {
            request.log.error({ assetId: id, err: { message: err.message } }, 'Could not safely create Mux upload');
            return reply.status(503).send({ error: 'Could not safely create the upload. Please try again.' });
        }

        if (!locked.acquired) {
            return reply.status(409).send({ error: 'Media reconciliation is in progress. Please try again.' });
        }
        const { status, body, asset } = locked.value;
        if (status !== 200 || !asset) return reply.status(status).send(body);

        request.log.info({ clipId: body.clipId, mediasourceId: asset.mediasourceId, muxUploadId: body.muxUploadId }, 'Created mux direct upload URL');
        const originalName = clientMeta.fileName || asset.originalFileName || asset.mediasourceId;
        notifyUserSockets(fastify.io, request.user.id, {
            assetId: id,
            asset: { mediasourceId: asset.mediasourceId, mediasourceUrl: asset.mediasourceUrl, originalFileName: originalName },
            userName: request.user.name,
            metadata,
            clip: { id: body.clipId, fileSize: clientMeta.fileSize || '0' },
            messageText: `🎬 #${asset.mediasourceId} uploading to Mediasoure.`,
        });
        await notifyDashboardAssetChange(fastify, id);
        return body;
    });

    /**
     * GET /api/assets/mine
     * Get all assets for the authenticated user (for archive list).
     */
    fastify.get('/api/assets/mine', {
        preHandler: [fastify.authenticate],
    }, async (request) => {
        const assets = await prisma.asset.findMany({
            where: { userId: request.user.id, moderation: { in: ['ACTIVE', 'PAUSED'] } },
            orderBy: { createdAt: 'desc' },
            include: {
                clips: { take: 1, orderBy: { createdAt: 'desc' } },
                formResponse: true,
            },
        });

        // Convert BigInt to string for JSON serialization
        const serialized = assets.map(serializeAsset);

        return { assets: serialized };
    });

    /**
     * GET /api/assets/:id
     * Get asset details with clips and form response.
     */
    fastify.get('/api/assets/:id', {
        preHandler: [fastify.authenticate],
    }, async (request, reply) => {
        const { id } = request.params;

        const asset = await prisma.asset.findFirst({
            where: {
                id,
                ...teamScope(request.user),
                moderation: {
                    in: isSuperAdmin(request.user.role)
                        ? ['ACTIVE', 'PAUSED', 'FLAGGED_FOR_REMOVAL']
                        : ['ACTIVE', 'PAUSED'],
                },
            },
            include: {
                clips: true,
                formResponse: true,
                user: {
                    select: { id: true, name: true, phoneNumber: true, team: true },
                },
            },
        });

        if (!asset) {
            return reply.status(404).send({ error: 'Asset not found' });
        }

        // Convert BigInt to string for JSON serialization
        return { asset: serializeAsset(asset) };
    });

    /**
     * POST /api/assets/:id/form
     * Submit the context form for an asset.
     */
    fastify.post('/api/assets/:id/form', {
        schema: {
            body: {
                type: 'object',
                properties: {
                    // maxLength enforced here rejects oversized payloads before the handler runs
                    slug: { type: 'string', maxLength: 50 },
                    type: { type: 'string', default: 'Raw' },
                    description: { type: 'string', maxLength: 500 },
                    priority: { type: 'string', default: 'Low', enum: ['Low', 'Medium', 'High', 'Critical', 'low', 'medium', 'high', 'critical', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'] },
                },
            },
        },
        preHandler: [fastify.authenticate],
    }, async (request, reply) => {
        const { id } = request.params;
        let { slug, type, description, priority } = request.body || {};

        const asset = await prisma.asset.findUnique({
            where: { id },
            include: { clips: { take: 1, orderBy: { createdAt: 'desc' } } },
        });
        if (!asset || asset.userId !== request.user.id) {
            return reply.status(404).send({ error: 'Asset not found' });
        }
        if (asset.moderation !== 'ACTIVE') {
            return reply.status(409).send({ error: 'This asset is not accepting form updates while it is moderated' });
        }

        // ── Server-side sanitization ─────────────────────────────────────────────
        //
        // These run independent of any client-side filtering so that direct API
        // calls (bypassing the iOS app) are also covered.
        //
        // Slug: allow letters, numbers, dashes, periods, spaces — strip everything else.
        // Mirrors the iOS allowedCharacters set in ContextFormView.swift.
        if (slug) {
            slug = slug
                .replace(/[^a-zA-Z0-9\-. ]/g, '')  // strip disallowed characters
                .trim()
                .slice(0, 50);                       // hard cap (belt-and-suspenders after schema)
        }

        // Description: strip null bytes and non-printable control characters.
        // Preserves printable Unicode, punctuation, newlines, tabs.
        if (description) {
            description = description
                .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '')  // strip control chars (keep \t \n \r)
                .trim()
                .slice(0, 500);                      // hard cap
        }

        // Fallback: if slug or description are still missing (app crash, battery death, etc.)
        // use the authenticated user's name so the record isn't left blank. 
        if (!slug?.trim() || !description?.trim()) {
            const user = await prisma.user.findUnique({ where: { id: request.user.id } });
            if (!slug?.trim()) slug = user?.name || 'Untitled';
            if (!description?.trim()) description = user?.name || 'No description';
        }

        // Upsert form response
        const formResponse = await prisma.formResponse.upsert({
            where: { assetId: id },
            create: {
                assetId: id,
                slug: slug || null,
                type: type || 'Raw',
                description,
                priority: priority?.toUpperCase() || 'MEDIUM',
            },
            update: {
                slug: slug || undefined,
                type: type || undefined,
                description,
                priority: priority?.toUpperCase() || undefined,
            },
        });

        // Push confirmation via WebSocket — include metadata for rich confirmation card
        const clip = asset.clips?.[0];
        const messageFallbackText = "High five. I'll text when the video is done. Metadata is ready, and you can Slack your team below.";
        fastify.io.to(userRoom(request.user.id)).emit('form:confirmed', {
            assetId: id,
            mediasourceId: asset.mediasourceId,
            mediasourceUrl: asset.mediasourceUrl,
            originalFileName: asset.originalFileName ?? clip?.originalFileName,
            capturedAt: clip?.capturedAt?.toISOString(),
            formType: formResponse.type,
            formDescription: formResponse.description,
            formPriority: formResponse.priority,
            messageCode: 'WS_FORM_CONFIRMED',
            messageParams: {},
            messageFallbackText,
            messageSchemaVersion: 1,
            message: messageFallbackText,
        });

        // Persist user's form submission (meaningful event); confirmation is ephemeral (Option B)
        await prisma.chatMessage.create({
            data: {
                userId: request.user.id,
                assetId: id,
                direction: 'OUTGOING',
                messageType: 'FORM_SUBMITTED',
                content: {
                    text: 'Form submitted',
                    code: 'WS_FORM_SUBMITTED',
                    fallbackText: 'Form submitted',
                    schemaVersion: 1,
                    slug: formResponse.slug,
                    type: formResponse.type,
                    priority: formResponse.priority,
                },
            },
        });

        await notifyDashboardAssetChange(fastify, id);

        return { formResponse };
    });

    /**
     * PATCH /api/assets/:id/clips/:clipId/transcript
     * Save transcript text + timestamped segments to a specific owned clip.
     * The legacy /api/assets/:id/transcript route remains available for older clients.
     */
    const saveTranscript = async (request, reply) => {
        const { id, clipId: pathClipId } = request.params;
        const { transcript, segments, clipId: bodyClipId } = request.body || {};
        let clipId = pathClipId ?? bodyClipId;

        if (!transcript || typeof transcript !== 'string') {
            return reply.code(400).send({ error: 'transcript is required' });
        }
        if (clipId !== undefined && (typeof clipId !== 'string' || !clipId.trim())) {
            return reply.code(400).send({ error: 'clipId must be a non-empty string' });
        }
        if (pathClipId !== undefined && bodyClipId !== undefined && pathClipId !== bodyClipId) {
            return reply.code(400).send({ error: 'clipId does not match the requested clip' });
        }

        const data = {
            transcript: transcript.slice(0, 10000),
            transcriptSegments: Array.isArray(segments) ? segments : undefined,
        };
        const transcriptAssetScope = {
            userId: request.user.id,
            moderation: { in: ['ACTIVE', 'PAUSED'] },
        };

        const saved = await prisma.$transaction(async tx => {
            // Serialize transcript writes with moderation changes to the parent asset.
            const assets = await tx.$queryRaw`
                SELECT id FROM assets
                WHERE id = ${id} AND user_id = ${request.user.id}
                  AND moderation IN ('ACTIVE', 'PAUSED')
                FOR UPDATE
            `;
            if (!assets.length) return false;

            if (clipId === undefined) {
                const clip = await tx.clip.findFirst({
                    where: { assetId: id, asset: transcriptAssetScope },
                    orderBy: { clipIndex: 'asc' },
                });
                if (!clip) return false;
                clipId = clip.id;
            }

            const updated = await tx.clip.updateMany({
                where: { id: clipId, assetId: id, asset: transcriptAssetScope },
                data,
            });
            return updated.count === 1;
        });
        if (!saved) {
            return reply.code(404).send({ error: 'No clip found for this asset' });
        }

        request.log.info(
            { clipId, segmentCount: segments?.length ?? 0 },
            'Transcript saved for clip'
        );

        return { ok: true, clipId, segmentCount: segments?.length ?? 0 };
    };

    fastify.patch('/api/assets/:id/transcript', {
        preHandler: [fastify.authenticate],
    }, saveTranscript);
    fastify.patch('/api/assets/:id/clips/:clipId/transcript', {
        preHandler: [fastify.authenticate],
    }, saveTranscript);

    /**
     * GET /api/messages
     * Get chat message history for the authenticated user.
     */
    fastify.get('/api/messages', {
        preHandler: [fastify.authenticate],
    }, async (request) => {
        const messages = await prisma.chatMessage.findMany({
            where: { userId: request.user.id },
            orderBy: { createdAt: 'asc' },
            take: 100,
        });

        return { messages };
    });
}
