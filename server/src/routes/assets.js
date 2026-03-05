/**
 * Asset routes — Create, upload, retrieve, submit form.
 */
import { randomUUID } from 'crypto';
import path from 'path';
import fs from 'fs/promises';
import { pipeline } from 'stream/promises';
import prisma from '../lib/prisma.js';
import { generateSlug, generateMediasourceId, dbRetry } from '../lib/utils.js';

export default async function assetRoutes(fastify) {
    /**
     * POST /api/assets
     * Create a new asset record.
     * Body: { fileName?: string }
     */
    fastify.post('/api/assets', {
        preHandler: [fastify.authenticate],
    }, async (request) => {
        const { fileName } = request.body || {};
        const slugBase = fileName
            ? fileName.replace(/\.[^/.]+$/, '')  // strip extension
            : 'upload';

        const slug = generateSlug(slugBase);
        const mediasourceId = await generateMediasourceId(prisma);

        const asset = await dbRetry(() => prisma.asset.create({
            data: {
                slug,
                userId: request.user.id,
                mediasourceId,
                mediasourceUrl: `/clips/${slug}`,
                originalFileName: fileName || null,
                status: 'UPLOADING',
            },
        }));

        return {
            asset: {
                id: asset.id,
                slug: asset.slug,
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
        const ext = path.extname(data.filename) || '.mp4';
        const clipId = randomUUID();
        const fileName = `${clipId}${ext}`;
        const uploadDir = path.resolve(process.cwd(), 'uploads');
        const filePath = path.join(uploadDir, fileName);

        await fs.mkdir(uploadDir, { recursive: true });

        // Stream file to disk
        const writeStream = (await import('fs')).createWriteStream(filePath);
        await pipeline(data.file, writeStream);

        // Get file stats
        const stats = await fs.stat(filePath);

        // io + userSockets used later for form:request and upload:complete events
        const io = fastify.io;
        const userSockets = fastify.userSockets?.get(request.user.id);

        // Create clip record with original filename
        // Use client-provided metadata from iOS (fallback to defaults for missing fields)
        const metadata = {
            gpsLat: clientMeta.gpsLat ? parseFloat(clientMeta.gpsLat) : null,
            gpsLon: clientMeta.gpsLon ? parseFloat(clientMeta.gpsLon) : null,
            capturedAt: clientMeta.capturedAt ? new Date(clientMeta.capturedAt) : new Date(),
            deviceModel: clientMeta.deviceModel || 'Unknown Device',
            osVersion: clientMeta.osVersion || 'Unknown OS',
            codec: clientMeta.codec || 'Unknown',
            resolution: clientMeta.resolution || 'Unknown',
            orientation: clientMeta.orientation || 'landscape',
            duration: clientMeta.duration ? parseInt(clientMeta.duration, 10) : 0,
        };
        console.log(`📊 Metadata for ${asset.slug}:`, metadata);

        // Create clip with metadata in one call (merged from 2 separate calls — #9)
        const clip = await dbRetry(() => prisma.clip.create({
            data: {
                id: clipId,
                assetId: id,
                clipIndex: 0,
                originalFileName: data.filename || asset.originalFileName || null,
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
        const originalName = clip.originalFileName || asset.originalFileName || asset.slug;

        // Determine if we have meaningful metadata beyond just timestamps
        const hasRichMeta = metadata.gpsLat || metadata.codec !== 'Unknown' || metadata.deviceModel !== 'Unknown Device';

        if (userSockets) {
            for (const socketId of userSockets) {
                // Send upload complete with full metadata for "Show Details" sheet
                io.to(socketId).emit('upload:complete', {
                    assetId: id,
                    mediasourceId: asset.mediasourceId,
                    mediasourceUrl: asset.mediasourceUrl,
                    originalFileName: originalName,
                    userName: request.user.name,
                    hasRichMeta,
                    metadata: metadata,
                    clip: {
                        id: clipId,
                        storageUrl: clip.storageUrl,
                        thumbnailUrl: clip.thumbnailUrl,
                        fileSize: stats.size.toString(),
                        originalFileName: originalName,
                    },
                });

                // Send form:request chat message so it appears in live chat
                io.to(socketId).emit('message:new', {
                    id: randomUUID(),
                    userId: null,
                    assetId: id,
                    direction: 'INCOMING',
                    messageType: 'FORM_REQUEST',
                    content: {
                        text: `🎬 ${asset.slug} is being processed, here are the Mediasource details.`,
                        mediasourceId: asset.mediasourceId,
                        mediasourceUrl: asset.mediasourceUrl,
                        originalFileName: originalName,
                        userName: request.user.name,
                        clipCount: 1,
                        duration: metadata.duration || 0,
                        gpsLat: metadata.gpsLat,
                        gpsLon: metadata.gpsLon,
                        capturedAt: metadata.capturedAt?.toISOString() || null,
                        codec: metadata.codec !== 'Unknown' ? metadata.codec : null,
                        resolution: metadata.resolution !== 'Unknown' ? metadata.resolution : null,
                        hasRichMeta,
                    },
                    createdAt: new Date().toISOString(),
                });

                // Send form request event — opens the form sheet
                io.to(socketId).emit('form:request', {
                    assetId: id,
                    originalFileName: originalName,
                    capturedAt: metadata.capturedAt,
                    clipCount: 1,
                    duration: metadata.duration,
                    prefilledData: {
                        slug: asset.slug,
                    },
                });
            }
        }

        // FORM_REQUEST is ephemeral — sent via WebSocket only, not persisted (Option B)

        return {
            clip: {
                id: clipId,
                storageUrl: `/uploads/${fileName}`,
                fileSize: stats.size.toString(),
                metadata: metadata,
            },
            asset: {
                id: updatedAsset.id,
                slug: updatedAsset.slug,
                mediasourceId: updatedAsset.mediasourceId,
                mediasourceUrl: updatedAsset.mediasourceUrl,
                status: updatedAsset.status,
            },
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
            clips: a.clips.map((c) => ({
                ...c,
                fileSize: c.fileSize?.toString() || null,
            })),
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

        // Convert BigInt to string for JSON serialization
        const clips = asset.clips.map((c) => ({
            ...c,
            fileSize: c.fileSize?.toString() || null,
        }));

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
        preHandler: [fastify.authenticate],
    }, async (request, reply) => {
        const { id } = request.params;
        const { slug, type, description, priority } = request.body || {};

        const asset = await prisma.asset.findUnique({
            where: { id },
            include: { clips: { take: 1 } },
        });
        if (!asset || asset.userId !== request.user.id) {
            return reply.status(404).send({ error: 'Asset not found' });
        }

        // Upsert form response
        const formResponse = await prisma.formResponse.upsert({
            where: { assetId: id },
            create: {
                assetId: id,
                slug: slug || asset.slug,
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
                    slug: formResponse.slug || asset.slug,
                    mediasourceId: asset.mediasourceId,
                    mediasourceUrl: asset.mediasourceUrl,
                    originalFileName: asset.originalFileName ?? clip?.originalFileName,
                    capturedAt: clip?.capturedAt?.toISOString(),
                    formType: formResponse.type,
                    formDescription: formResponse.description,
                    formPriority: formResponse.priority,
                    message: `🙌 High Five! I received your sheet, thank you. I'll text when the video is done.`,
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
