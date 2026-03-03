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
        const mediasourceId = generateMediasourceId();

        const asset = await dbRetry(() => prisma.asset.create({
            data: {
                slug,
                userId: request.user.id,
                mediasourceId,
                mediasourceUrl: `https://mediasource.com/${mediasourceId}`,
                status: 'UPLOADING',
            },
        }));

        // Send a WebSocket message to the user about asset creation
        const io = fastify.io;
        const userSockets = fastify.userSockets?.get(request.user.id);
        if (userSockets) {
            for (const socketId of userSockets) {
                io.to(socketId).emit('message:new', {
                    id: randomUUID(),
                    userId: null,
                    assetId: asset.id,
                    direction: 'INCOMING',
                    messageType: 'TEXT',
                    content: {
                        text: `🎬 Got it! Processing your upload...`,
                    },
                    createdAt: new Date().toISOString(),
                });
            }
        }

        return {
            asset: {
                id: asset.id,
                slug: asset.slug,
                mediasourceId: asset.mediasourceId,
                mediasourceUrl: asset.mediasourceUrl,
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

        // Create clip record
        const clip = await dbRetry(() => prisma.clip.create({
            data: {
                id: clipId,
                assetId: id,
                clipIndex: 0,
                storageUrl: `/uploads/${fileName}`,
                fileSize: BigInt(stats.size),
                status: 'PROCESSING',
            },
        }));

        // Update asset status
        await dbRetry(() => prisma.asset.update({
            where: { id },
            data: {
                status: 'PROCESSING',
                clipCount: { increment: 1 },
            },
        }));

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

        // Update clip with extracted metadata
        await dbRetry(() => prisma.clip.update({
            where: { id: clipId },
            data: {
                ...metadata,
                status: 'READY',
            },
        }));

        // Update asset to ready
        const updatedAsset = await dbRetry(() => prisma.asset.update({
            where: { id },
            data: {
                status: 'READY',
                totalDuration: metadata.duration,
            },
            include: { clips: true },
        }));

        // Push metadata + form request via WebSocket
        const io = fastify.io;
        const userSockets = fastify.userSockets?.get(request.user.id);
        if (userSockets) {
            for (const socketId of userSockets) {
                // Send metadata message
                io.to(socketId).emit('upload:complete', {
                    assetId: id,
                    mediasourceId: asset.mediasourceId,
                    mediasourceUrl: asset.mediasourceUrl,
                    metadata: metadata,
                    clip: {
                        id: clipId,
                        storageUrl: clip.storageUrl,
                        thumbnailUrl: clip.thumbnailUrl,
                        fileSize: stats.size.toString(),
                    },
                });

                // Send form request
                io.to(socketId).emit('form:request', {
                    assetId: id,
                    prefilledData: {
                        sender: request.user.name,
                        phone: request.user.phoneNumber,
                        slug: asset.slug,
                        gps: metadata.gpsLat && metadata.gpsLon
                            ? `${metadata.gpsLat.toFixed(4)}, ${metadata.gpsLon.toFixed(4)}`
                            : 'Not available',
                        capturedAt: metadata.capturedAt,
                        device: metadata.deviceModel,
                        duration: `${metadata.duration}s`,
                        codec: metadata.codec,
                        resolution: metadata.resolution,
                        orientation: metadata.orientation,
                    },
                });
            }
        }

        // Store chat messages (best-effort — don't fail upload over this)
        try {
            await prisma.chatMessage.createMany({
                data: [
                    {
                        userId: request.user.id,
                        assetId: id,
                        direction: 'INCOMING',
                        messageType: 'FORM_REQUEST',
                        content: {
                            text: `🎬 ${asset.slug} is being processed, here are the Mediasource details.`,
                            mediasourceId: asset.mediasourceId,
                            mediasourceUrl: asset.mediasourceUrl,
                            metadata: metadata,
                        },
                    },
                ],
            });
        } catch (err) {
            console.error('Chat message store failed:', err.message);
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
                slug: updatedAsset.slug,
                mediasourceId: updatedAsset.mediasourceId,
                mediasourceUrl: updatedAsset.mediasourceUrl,
                status: updatedAsset.status,
            },
        };
    });

    /**
     * GET /api/assets/:id
     * Get asset details with clips and form response.
     */
    fastify.get('/api/assets/:id', async (request, reply) => {
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

        const asset = await prisma.asset.findUnique({ where: { id } });
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

        // Push confirmation via WebSocket
        const io = fastify.io;
        const userSockets = fastify.userSockets?.get(request.user.id);
        if (userSockets) {
            for (const socketId of userSockets) {
                io.to(socketId).emit('form:confirmed', {
                    assetId: id,
                    mediasourceId: asset.mediasourceId,
                    mediasourceUrl: asset.mediasourceUrl,
                    message: `🙌 High Five! I received your sheet, thank you. I'll text when the video is done.`,
                });
            }
        }

        // Store chat messages
        await prisma.chatMessage.createMany({
            data: [
                {
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
                {
                    userId: request.user.id,
                    assetId: id,
                    direction: 'INCOMING',
                    messageType: 'CONFIRMATION',
                    content: {
                        text: `🙌 High Five! I received your sheet, thank you. I'll text when the video is done.`,
                        mediasourceId: asset.mediasourceId,
                        mediasourceUrl: asset.mediasourceUrl,
                    },
                },
            ],
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
