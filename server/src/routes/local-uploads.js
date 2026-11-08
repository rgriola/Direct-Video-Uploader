import fastifyStatic from '@fastify/static';
import { realpath } from 'node:fs/promises';
import path from 'node:path';
import prisma from '../lib/prisma.js';
import { canExposePlayback } from '../lib/media-visibility.js';

export default async function localUploadRoutes(fastify, { root }) {
    const canonicalRoot = await realpath(root);

    fastify.addHook('preHandler', async (request, reply) => {
        const relative = request.params['*'];
        if (typeof relative !== 'string' || !relative || relative.includes('\\')
            || path.posix.normalize(relative) !== relative || relative.startsWith('/')) {
            return reply.callNotFound();
        }

        const requestedPath = path.resolve(canonicalRoot, relative);
        if (!requestedPath.startsWith(`${canonicalRoot}${path.sep}`)) return reply.callNotFound();

        let actualPath;
        try {
            actualPath = await realpath(requestedPath);
        } catch (err) {
            if (err.code === 'ENOENT' || err.code === 'ENOTDIR') return reply.callNotFound();
            request.log.error({ err: { message: err.message } }, 'Could not verify local upload path');
            return reply.status(503).send({ error: 'Could not verify local media' });
        }
        if (actualPath !== requestedPath) return reply.callNotFound();

        const clips = await prisma.clip.findMany({
            where: { storageUrl: `/uploads/${relative}` },
            select: {
                asset: {
                    select: { moderation: true, mediaPlaybackReset: true, mediaCreateOperationId: true },
                },
            },
        });
        if (!clips.length || clips.some(({ asset }) => !canExposePlayback(asset))) {
            return reply.callNotFound();
        }
        reply.header('Cache-Control', 'no-store');
    });

    await fastify.register(fastifyStatic, {
        root,
        prefix: '/uploads/',
        decorateReply: false,
        cacheControl: false,
        index: false,
    });
}
