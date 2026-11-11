import Fastify from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import uploadCapabilityRoutes from '../routes/upload-capabilities.js';

let app;

async function build(originalUploads) {
    app = Fastify({ logger: false });
    app.decorate('authenticate', async (request, reply) => {
        if (request.headers.authorization !== 'Bearer valid') {
            return reply.status(401).send({ error: 'Unauthorized' });
        }
    });
    await app.register(uploadCapabilityRoutes, { originalUploads });
    return app;
}

afterEach(async () => {
    await app?.close();
    app = undefined;
});

describe('upload capabilities', () => {
    it.each([true, false])('reports original uploads as %s to signed-in users', async enabled => {
        await build(enabled);
        const response = await app.inject({
            method: 'GET', url: '/api/upload-capabilities', headers: { authorization: 'Bearer valid' },
        });
        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual({ originalUploads: enabled });
        expect(response.headers['cache-control']).toBe('no-store');
    });

    it('requires authentication and an explicit setting', async () => {
        await build(true);
        expect((await app.inject({ method: 'GET', url: '/api/upload-capabilities' })).statusCode).toBe(401);
        await app.close();
        app = Fastify({ logger: false });
        app.decorate('authenticate', async () => {});
        await expect(app.register(uploadCapabilityRoutes, {}).ready()).rejects.toThrow('original-upload setting');
    });
});
