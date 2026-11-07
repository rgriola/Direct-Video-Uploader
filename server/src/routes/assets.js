// Last updated: May 10, 2026 - 10:15am - GitHub Copilot (GPT-5.3-Codex)
/**
 * Asset routes — Create, upload, retrieve, submit form.
 */
import { randomUUID } from 'crypto';
import prisma from '../lib/prisma.js';
import { generateMediasourceId, dbRetry, parseClientMetadata, serializeClip, notifyUserSockets } from '../lib/utils.js';
import { isMuxEnabled, createDirectUpload } from '../lib/mux.js';
import { isAdminRole } from '../lib/roles.js';

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
     * bypassing the server (avoids Render's 30s request timeout for large files).
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

        const asset = await dbRetry(() => prisma.asset.findUnique({ where: { id } }));
        if (!asset || asset.userId !== request.user.id) {
            return reply.status(404).send({ error: 'Asset not found' });
        }

        // Idempotent: if there's already a PROCESSING clip for this asset with a
        // Mux upload URL, return it instead of creating a duplicate.
        const existingClip = await dbRetry(() => prisma.clip.findFirst({
            where: { assetId: id, status: 'PROCESSING', muxUploadId: { not: null } },
            orderBy: { createdAt: 'desc' },
        }));

        if (existingClip) {
            // Look up the Mux upload to check if it's still usable
            const { getMuxUpload } = await import('../lib/mux.js');
            let upload;
            try {
                upload = await getMuxUpload(existingClip.muxUploadId);
            } catch (err) {
                request.log.warn(
                    {
                        muxUploadId: existingClip.muxUploadId,
                        err: { message: err.message },
                    },
                    'Could not fetch Mux upload status'
                );
            }

            // Only reuse if Mux upload is still in 'waiting' state (accepting bytes)
            if (upload?.url && upload.status === 'waiting') {
                request.log.info(
                    { clipId: existingClip.id, mediasourceId: asset.mediasourceId },
                    'Reusing existing processing clip upload'
                );
                return {
                    uploadUrl: upload.url,
                    clipId: existingClip.id,
                    muxUploadId: existingClip.muxUploadId,
                };
            }
            // Upload expired, cancelled, timed-out, errored, or already used —
            // delete the stale clip and create a fresh one below
            request.log.info(
                {
                    muxUploadId: existingClip.muxUploadId,
                    muxUploadStatus: upload?.status ?? 'unknown',
                    mediasourceId: asset.mediasourceId,
                },
                'Creating fresh direct upload after stale mux upload state'
            );
            await dbRetry(() => prisma.clip.delete({ where: { id: existingClip.id } }));
            await dbRetry(() => prisma.asset.update({
                where: { id },
                data: { clipCount: { decrement: 1 } },
            }));
        }

        const clientMeta = request.body?.metadata || {};
        const mimeType = String(clientMeta.mimeType || clientMeta.contentType || clientMeta.type || '')
            .trim()
            .toLowerCase();

        if (mimeType && !ALLOWED_VIDEO_MIMES.has(mimeType)) {
            return reply.status(415).send({ error: `Unsupported media type: ${mimeType}` });
        }

        const clipId = randomUUID();

        // Create the Mux direct upload URL
        const muxResult = await createDirectUpload({ clipId, assetId: id });
        if (!muxResult) {
            return reply.status(500).send({ error: 'Failed to create Mux upload' });
        }

        const metadata = parseClientMetadata(clientMeta);

        // Create clip record in PROCESSING state (Mux webhook will mark READY)
        await dbRetry(() => prisma.clip.create({
            data: {
                id: clipId,
                assetId: id,
                clipIndex: 0,
                originalFileName: clientMeta.fileName || asset.originalFileName || null,
                fileSize: clientMeta.fileSize ? BigInt(clientMeta.fileSize) : null,
                muxUploadId: muxResult.muxUploadId,
                ...metadata,
                status: 'PROCESSING',
            },
        }));

        // Update asset status
        await dbRetry(() => prisma.asset.update({
            where: { id },
            data: {
                status: 'PROCESSING',
                clipCount: { increment: 1 },
                totalDuration: metadata.duration,
            },
        }));

        request.log.info(
            { clipId, mediasourceId: asset.mediasourceId, muxUploadId: muxResult.muxUploadId },
            'Created mux direct upload URL'
        );

        // Push form request via WebSocket
        const originalName = clientMeta.fileName || asset.originalFileName || asset.mediasourceId;

        notifyUserSockets(fastify.io, fastify.userSockets?.get(request.user.id), {
            assetId: id,
            asset: { mediasourceId: asset.mediasourceId, mediasourceUrl: asset.mediasourceUrl, originalFileName: originalName },
            userName: request.user.name,
            metadata,
            clip: { id: clipId, fileSize: clientMeta.fileSize || '0' },
            messageText: `🎬 #${asset.mediasourceId} uploading to Mediasoure.`,
        });

        return {
            uploadUrl: muxResult.uploadUrl,
            clipId,
            muxUploadId: muxResult.muxUploadId,
        };
    });

    /**
     * GET /api/assets/mine
     * Get all assets for the authenticated user (for archive list).
     */
    fastify.get('/api/assets/mine', {
        preHandler: [fastify.authenticate],
    }, async (request) => {
        const assets = await prisma.asset.findMany({
            where: { userId: request.user.id },
            orderBy: { createdAt: 'desc' },
            include: {
                clips: { take: 1, orderBy: { createdAt: 'desc' } },
                formResponse: true,
            },
        });

        // Convert BigInt to string for JSON serialization
        const serialized = assets.map((a) => ({
            ...a,
            clips: a.clips.map(serializeClip),
        }));

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

        const asset = await prisma.asset.findUnique({
            where: { id },
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

        // Ownership check — only asset owner or admin can view details (A6)
        if (asset.userId !== request.user.id && !isAdminRole(request.user.role)) {
            return reply.status(403).send({ error: 'Access denied' });
        }

        // Convert BigInt to string for JSON serialization
        const clips = asset.clips.map(serializeClip);

        return {
            asset: {
                ...asset,
                clips,
            },
        };
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
        const io = fastify.io;
        const userSockets = fastify.userSockets?.get(request.user.id);
        const clip = asset.clips?.[0];
        const messageFallbackText = "High five. I'll text when the video is done. Metadata is ready, and you can Slack your team below.";
        if (userSockets) {
            for (const socketId of userSockets) {
                io.to(socketId).emit('form:confirmed', {
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
            }
        }

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

        return { formResponse };
    });

    /**
     * PATCH /api/assets/:id/transcript
     * Save transcript text + timestamped segments to the first clip.
     * Body: { transcript: string, segments: [{word, start, end, confidence}, ...] }
     */
    fastify.patch('/api/assets/:id/transcript', {
        preHandler: [fastify.authenticate],
    }, async (request, reply) => {
        const { id } = request.params;
        const { transcript, segments } = request.body || {};

        if (!transcript || typeof transcript !== 'string') {
            return reply.code(400).send({ error: 'transcript is required' });
        }

        // Find the first clip for this asset
        const clip = await prisma.clip.findFirst({
            where: { assetId: id },
            orderBy: { clipIndex: 'asc' },
        });

        if (!clip) {
            return reply.code(404).send({ error: 'No clip found for this asset' });
        }

        // Update transcript text + segments JSON
        await prisma.clip.update({
            where: { id: clip.id },
            data: {
                transcript: transcript.slice(0, 10000),
                transcriptSegments: Array.isArray(segments) ? segments : undefined,
            },
        });

        request.log.info(
            { clipId: clip.id, segmentCount: segments?.length ?? 0 },
            'Transcript saved for clip'
        );

        return { ok: true, clipId: clip.id, segmentCount: segments?.length ?? 0 };
    });

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
