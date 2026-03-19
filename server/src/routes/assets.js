/**
 * Asset routes — Create, upload, retrieve, submit form.
 */
import { randomUUID } from 'crypto';
import path from 'path';
import fs from 'fs/promises';
import { pipeline } from 'stream/promises';
import { fileTypeFromFile } from 'file-type';
import prisma from '../lib/prisma.js';
import { generateMediasourceId, dbRetry, parseClientMetadata, serializeClip, notifyUserSockets } from '../lib/utils.js';
import { ingestVideo, isMuxEnabled, createDirectUpload } from '../lib/mux.js';

// Allowed video MIME types (B5: file upload validation)
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
     * POST /api/assets/:id/upload
     * Upload a video file (multipart).
     */
    fastify.post('/api/assets/:id/upload', {
        preHandler: [fastify.authenticate],
        config: {
            rateLimit: { max: 10, timeWindow: '1 minute' },
        },
    }, async (request, reply) => {
        const { id } = request.params;

        // Verify asset exists and belongs to user
        const asset = await dbRetry(() => prisma.asset.findUnique({ where: { id } }));
        if (!asset || asset.userId !== request.user.id) {
            return reply.status(404).send({ error: 'Asset not found' });
        }

        const data = await request.file();
        if (!data) {
            return reply.status(400).send({ error: 'No file uploaded' });
        }

        // Collect metadata fields sent alongside the file
        const clientMeta = {};
        for (const [key, field] of Object.entries(data.fields || {})) {
            if (field?.value) clientMeta[key] = field.value;
        }

        // Save file to local uploads directory (demo — production would use R2/S3)
        // B5: Sanitize filename — strip path components, limit length, remove null bytes
        const safeOriginal = (data.filename || 'upload.mp4')
            .replace(/\0/g, '')
            .replace(/[/\\]/g, '_')
            .slice(0, 255);
        const ext = path.extname(safeOriginal) || '.mp4';
        const clipId = randomUUID();
        const fileName = `${clipId}${ext}`;
        const uploadDir = path.resolve(process.cwd(), 'uploads');
        const filePath = path.join(uploadDir, fileName);

        await fs.mkdir(uploadDir, { recursive: true });

        // Stream file to disk
        const writeStream = (await import('fs')).createWriteStream(filePath);
        await pipeline(data.file, writeStream);

        // B5: Validate file is actually a video (magic byte check)
        const fileType = await fileTypeFromFile(filePath);
        if (!fileType || !ALLOWED_VIDEO_MIMES.has(fileType.mime)) {
            await fs.unlink(filePath).catch(() => {});
            return reply.status(415).send({
                error: 'Invalid file type — only video files are accepted',
                detected: fileType?.mime || 'unknown',
            });
        }

        // Get file stats
        const stats = await fs.stat(filePath);

        const metadata = parseClientMetadata(clientMeta);
        console.log(`📊 Metadata for ${asset.mediasourceId}:`, metadata);

        // Create clip with metadata in one call (merged from 2 separate calls — #9)
        const clip = await dbRetry(() => prisma.clip.create({
            data: {
                id: clipId,
                assetId: id,
                clipIndex: 0,
                originalFileName: safeOriginal || asset.originalFileName || null,
                storageUrl: `/uploads/${fileName}`,
                fileSize: BigInt(stats.size),
                ...metadata,
                status: 'READY',
            },
        }));

        // Single asset update (merged from 2 separate calls — #9)
        const updatedAsset = await dbRetry(() => prisma.asset.update({
            where: { id },
            data: {
                status: 'READY',
                clipCount: { increment: 1 },
                totalDuration: metadata.duration,
            },
            include: { clips: true },
        }));

        // Push metadata + form request via WebSocket
        const originalName = clip.originalFileName || asset.originalFileName || asset.mediasourceId;

        notifyUserSockets(fastify.io, fastify.userSockets?.get(request.user.id), {
            assetId: id,
            asset: { mediasourceId: asset.mediasourceId, mediasourceUrl: asset.mediasourceUrl, originalFileName: originalName },
            userName: request.user.name,
            metadata,
            clip: { id: clipId, storageUrl: clip.storageUrl, fileSize: stats.size.toString() },
            messageText: `🎬 #${asset.mediasourceId} is being processed, here are the Mediasource details.`,
        });

        // FORM_REQUEST is ephemeral — sent via WebSocket only, not persisted (Option B)

        // ─── Mux Video Ingestion (fire-and-forget) ──────────────────
        // Don't await — let Mux process in the background. Webhook updates the clip when ready.
        if (isMuxEnabled) {
            ingestVideo(filePath, { clipId, assetId: id }).then(async (result) => {
                if (result?.muxUploadId) {
                    await dbRetry(() => prisma.clip.update({
                        where: { id: clipId },
                        data: {
                            muxUploadId: result.muxUploadId,
                            // Don't change status — local file is already READY and playable.
                            // Mux webhook will add muxPlaybackId when processing completes.
                        },
                    }));
                    console.log(`🎬 Mux ingestion queued for clip ${clipId}`);
                }
            }).catch(err => {
                console.error(`🎬 Mux ingestion failed for clip ${clipId}:`, err.message);
            });
        }

        return {
            clip: {
                id: clipId,
                storageUrl: `/uploads/${fileName}`,
                fileSize: stats.size.toString(),
                metadata: metadata,
            },
            asset: {
                id: updatedAsset.id,
                mediasourceId: updatedAsset.mediasourceId,
                mediasourceUrl: updatedAsset.mediasourceUrl,
                status: updatedAsset.status,
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
            // Look up the Mux upload to get the URL (still valid if < 1h old)
            const { getMuxUpload } = await import('../lib/mux.js');
            const upload = await getMuxUpload(existingClip.muxUploadId);
            if (upload?.url && upload.status !== 'asset_created' && upload.status !== 'errored') {
                console.log(`🎬 Reusing existing PROCESSING clip ${existingClip.id} for asset #${asset.mediasourceId}`);
                return {
                    uploadUrl: upload.url,
                    clipId: existingClip.id,
                    muxUploadId: existingClip.muxUploadId,
                };
            }
            // Upload expired or already used — fall through to create a new one
        }

        const clientMeta = request.body?.metadata || {};
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

        console.log(`🎬 Mux direct upload created for clip ${clipId}, asset #${asset.mediasourceId}`);

        // Push form request via WebSocket
        const originalName = clientMeta.fileName || asset.originalFileName || asset.mediasourceId;

        notifyUserSockets(fastify.io, fastify.userSockets?.get(request.user.id), {
            assetId: id,
            asset: { mediasourceId: asset.mediasourceId, mediasourceUrl: asset.mediasourceUrl, originalFileName: originalName },
            userName: request.user.name,
            metadata,
            clip: { id: clipId, fileSize: clientMeta.fileSize || '0' },
            messageText: `🎬 #${asset.mediasourceId} is uploading to Mux, here are the Mediasource details.`,
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
                clips: { take: 1 },
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
        if (asset.userId !== request.user.id && request.user.role !== 'ADMIN') {
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
                    slug: { type: 'string' },
                    type: { type: 'string', default: 'Raw' },
                    description: { type: 'string' },
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
            include: { clips: { take: 1 } },
        });
        if (!asset || asset.userId !== request.user.id) {
            return reply.status(404).send({ error: 'Asset not found' });
        }

        // Fallback: if slug or description are missing (app crash, battery death, etc.)
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
                    message: `🙌 High Five! I received slug form. Keep the app open to finish the upload. I'll text when the video is ready. Here is your metadata.`,
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
                    text: '✅ Form submitted',
                    slug: formResponse.slug,
                    type: formResponse.type,
                    priority: formResponse.priority,
                },
            },
        });

        return { formResponse };
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
