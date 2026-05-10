// Last updated: May 9, 2026 - 6:14pm
import Fastify from 'fastify';
import cookie from '@fastify/cookie';
import formbody from '@fastify/formbody';
import csrfProtection from '@fastify/csrf-protection';
import fastifyJwt from '@fastify/jwt';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = {
    user: {
        findUnique: vi.fn(async () => null),
        update: vi.fn(async () => null),
    },
    asset: {
        findUnique: vi.fn(async () => null),
        findFirst: vi.fn(async () => null),
        findMany: vi.fn(async () => []),
        update: vi.fn(async () => null),
    },
    clip: {
        findFirst: vi.fn(async () => null),
        findUnique: vi.fn(async () => null),
        findMany: vi.fn(async () => []),
        update: vi.fn(async () => null),
    },
    formResponse: {
        findUnique: vi.fn(async () => null),
    },
    chatMessage: {
        findMany: vi.fn(async () => []),
    },
    errorLog: {
        findMany: vi.fn(async () => []),
    },
    $queryRaw: vi.fn(async () => [{ ok: 1 }]),
};

vi.mock('../lib/prisma.js', () => ({
    default: prismaMock,
}));

let authRoutes;
let assetRoutes;
let adminRoutes;
let clipRoutes;
let errorRoutes;
let muxWebhookRoutes;

/** @type {import('fastify').FastifyInstance} */
let app;

beforeAll(async () => {
    process.env.MUX_TOKEN_ID = process.env.MUX_TOKEN_ID || 'test-token-id';
    process.env.MUX_TOKEN_SECRET = process.env.MUX_TOKEN_SECRET || 'test-token-secret';
    process.env.MUX_ENV_KEY = process.env.MUX_ENV_KEY || 'test-env-key';
    process.env.MUX_WEBHOOK_SECRET = process.env.MUX_WEBHOOK_SECRET || 'test-webhook-secret';

    ({ default: authRoutes } = await import('../routes/auth.js'));
    ({ default: assetRoutes } = await import('../routes/assets.js'));
    ({ default: adminRoutes } = await import('../routes/admin.js'));
    ({ default: clipRoutes } = await import('../routes/clips.js'));
    ({ default: errorRoutes } = await import('../routes/errors.js'));
    ({ default: muxWebhookRoutes } = await import('../routes/mux-webhooks.js'));
});

beforeEach(async () => {
    app = Fastify({ logger: false });

    await app.register(cookie);
    await app.register(formbody);
    await app.register(csrfProtection);
    await app.register(fastifyJwt, { secret: 'test-jwt-secret' });

    app.decorate('authenticate', async (request, reply) => {
        return reply.status(401).send({ error: 'Unauthorized' });
    });

    app.decorate('authorizeAdmin', async (request, reply) => {
        return reply.status(403).send({ error: 'Admin access required' });
    });

    app.decorate('clipAuthenticate', async () => null);

    app.decorate('io', {
        of: () => ({ sockets: new Map() }),
        to: () => ({ emit: () => {} }),
    });
    app.decorate('userSockets', new Map());
    app.decorate('iosSockets', new Set());
    app.decorate('adminSockets', new Set());

    await app.register(authRoutes);
    await app.register(assetRoutes);
    await app.register(adminRoutes);
    await app.register(clipRoutes);
    await app.register(errorRoutes);
    await app.register(muxWebhookRoutes);
});

afterEach(async () => {
    await app.close();
});

describe('Route smoke coverage', () => {
    it('auth routes are registered', async () => {
        const response = await app.inject({
            method: 'POST',
            url: '/api/auth/login',
            payload: {},
        });

        expect(response.statusCode).toBe(400);
    });

    it('asset routes are registered', async () => {
        const response = await app.inject({
            method: 'POST',
            url: '/api/assets',
            payload: {},
        });

        expect(response.statusCode).toBe(401);
    });

    it('admin routes are registered', async () => {
        const response = await app.inject({
            method: 'GET',
            url: '/api/admin/status',
        });

        expect(response.statusCode).toBe(401);
    });

    it('clip routes are registered and render login form with CSRF token', async () => {
        const response = await app.inject({
            method: 'GET',
            url: '/clips/login',
        });

        expect(response.statusCode).toBe(200);
        expect(response.body).toContain('name="_csrf"');
    });

    it('error routes are registered', async () => {
        const response = await app.inject({
            method: 'POST',
            url: '/api/errors',
            payload: { source: 'ios', category: 'upload', message: 'test' },
        });

        expect(response.statusCode).toBe(401);
    });

    it('mux webhook routes are registered and require signature', async () => {
        const response = await app.inject({
            method: 'POST',
            url: '/api/webhooks/mux',
            payload: { type: 'video.asset.ready', data: {} },
        });

        expect(response.statusCode).toBe(401);
    });
});
