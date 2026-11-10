import authRoutes from './auth.js';
import assetRoutes from './assets.js';
import adminRoutes from './admin.js';
import moderationRoutes from './moderation.js';
import clipRoutes from './clips.js';
import errorRoutes from './errors.js';
import muxWebhookRoutes from './mux-webhooks.js';
import uploadSessionRoutes from './upload-sessions.js';
import { getUploadSessionConfig } from '../lib/upload-session-config.js';
import { getMuxOriginalConfig } from '../lib/mux-original-config.js';
import { createStorageDriver } from '../lib/storage/driver.js';

export async function registerApplicationRoutes(fastify) {
    await fastify.register(authRoutes);
    await fastify.register(assetRoutes);
    await fastify.register(adminRoutes);
    await fastify.register(moderationRoutes);
    await fastify.register(clipRoutes);
    await fastify.register(errorRoutes);
    await fastify.register(muxWebhookRoutes);
    const uploadConfig = getUploadSessionConfig();
    const muxOriginalConfig = getMuxOriginalConfig();
    if (uploadConfig.enabled) {
        let handoff;
        if (muxOriginalConfig.enabled) {
            const [{ default: muxOriginalRoutes }, { enqueueMuxOriginal }, { requestMuxOriginalIngest }] = await Promise.all([
                import('./mux-originals.js'),
                import('../lib/mux-original-records.js'),
                import('../lib/mux-original-enqueue.js'),
            ]);
            handoff = { onCompleted: enqueueMuxOriginal, request: requestMuxOriginalIngest };
            await fastify.register(muxOriginalRoutes, { signingSecret: muxOriginalConfig.signingSecret });
        }
        await fastify.register(uploadSessionRoutes, {
            storage: createStorageDriver({ provider: uploadConfig.storageDriver }),
            storageDriver: uploadConfig.storageDriver,
            signingSecret: uploadConfig.signingSecret,
            capacityLimits: {
                maxStorageBytes: uploadConfig.maxStorageBytes,
                minFreeBytes: uploadConfig.minFreeBytes,
            },
            ...(handoff ? { handoff } : {}),
        });
    }
    return muxOriginalConfig;
}
