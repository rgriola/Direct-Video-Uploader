import authRoutes from './auth.js';
import assetRoutes from './assets.js';
import adminRoutes from './admin.js';
import moderationRoutes from './moderation.js';
import clipRoutes from './clips.js';
import errorRoutes from './errors.js';
import muxWebhookRoutes from './mux-webhooks.js';
import uploadSessionRoutes from './upload-sessions.js';
import { getUploadSessionConfig } from '../lib/upload-session-config.js';
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
    if (uploadConfig.enabled) {
        await fastify.register(uploadSessionRoutes, {
            storage: createStorageDriver({ provider: uploadConfig.storageDriver }),
            storageDriver: uploadConfig.storageDriver,
            signingSecret: uploadConfig.signingSecret,
        });
    }
}
