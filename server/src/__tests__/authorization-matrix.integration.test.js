import Fastify from 'fastify';
import cookie from '@fastify/cookie';
import csrfProtection from '@fastify/csrf-protection';
import formbody from '@fastify/formbody';
import fastifyJwt from '@fastify/jwt';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { requireRole } from '../lib/authorization.js';
import { hashPin } from '../lib/utils.js';
import { acquireIntegrationDatabaseLock, waitForBlockedQuery } from './helpers/database-lock.js';

const mux = vi.hoisted(() => ({
    createDirectUpload: vi.fn(async ({ clipId }) => ({
        uploadUrl: `https://upload.invalid/${clipId}`,
        muxUploadId: `matrix-upload-${clipId}`,
    })),
    getMuxUpload: vi.fn(),
}));

vi.mock('../lib/mux.js', () => ({
    ...mux,
    isMuxEnabled: true,
    MUX_ENV_KEY: '',
}));
vi.mock('@mux/mux-node', () => ({
    default: class {
        webhooks = {
            verifySignature() {
                throw new Error('No signed Mux events are sent by this suite');
            },
        };
    },
}));

const databaseUrl = process.env.TEST_DATABASE_URL;
if (process.env.CI && !databaseUrl) {
    throw new Error('TEST_DATABASE_URL is required for authorization matrix tests in CI');
}
if (databaseUrl) {
    const url = new URL(databaseUrl);
    if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
        || !url.pathname.slice(1).startsWith('dvu_scope_test_')
        || process.env.DATABASE_URL !== databaseUrl) {
        throw new Error('Authorization matrix tests require a dedicated local dvu_scope_test_ database');
    }
}

const integration = databaseUrl ? describe : describe.skip;

const actors = [
    { key: 'guest' },
    { key: 'user-news', role: 'USER', companyCode: 'NEWS', phoneNumber: '5581000001' },
    { key: 'user-sport', role: 'USER', companyCode: 'SPRT', phoneNumber: '5581000002' },
    { key: 'admin-news', role: 'ADMIN', companyCode: 'NEWS', phoneNumber: '5581000003' },
    { key: 'admin-sport', role: 'ADMIN', companyCode: 'SPRT', phoneNumber: '5581000004' },
    { key: 'super-news', role: 'SUPER_ADMIN', companyCode: 'NEWS', phoneNumber: '5581000005' },
    { key: 'super-sport', role: 'SUPER_ADMIN', companyCode: 'SPRT', phoneNumber: '5581000006' },
    { key: 'admin-unassigned', role: 'ADMIN', companyCode: null, phoneNumber: '5581000007' },
].map((actor, index) => ({ ...actor, index, id: actor.role ? `matrix-${actor.key}` : null }));

const signedInActors = actors.filter(actor => actor.id);
const primaryAssets = signedInActors.map((actor, index) => ({
    id: `matrix-asset-${actor.key}`,
    userId: actor.id,
    clipId: `matrix-clip-${actor.key}`,
    mediasourceId: String(920000001 + index),
    fileName: `matrix-${actor.key}.mp4`,
    playbackId: `matrix-playback-${actor.key}`,
}));
const emptyAssets = [
    { id: 'matrix-moderation-news', userId: 'matrix-user-news' },
    { id: 'matrix-moderation-sport', userId: 'matrix-user-sport' },
];
const allAssets = [...primaryAssets, ...emptyAssets];
const teams = [
    {
        key: 'news',
        userId: 'matrix-user-news',
        asset: primaryAssets.find(asset => asset.userId === 'matrix-user-news'),
        sharedAsset: primaryAssets.find(asset => asset.userId === 'matrix-admin-news'),
        moderationAssetId: 'matrix-moderation-news',
    },
    {
        key: 'sport',
        userId: 'matrix-user-sport',
        asset: primaryAssets.find(asset => asset.userId === 'matrix-user-sport'),
        sharedAsset: primaryAssets.find(asset => asset.userId === 'matrix-admin-sport'),
        moderationAssetId: 'matrix-moderation-sport',
    },
];
const messages = [
    { id: 'matrix-message-news', userId: 'matrix-user-news', assetId: teams[0].asset.id },
    { id: 'matrix-message-sport', userId: 'matrix-user-sport', assetId: teams[1].asset.id },
];

const ALL = [401, 200, 200, 200, 200, 200, 200, 200];
const ADMINS = [401, 403, 403, 200, 200, 200, 200, 403];
const SUPER = [401, 403, 403, 403, 403, 200, 200, 403];
const SUPER_CONFLICT = [401, 403, 403, 403, 403, 409, 409, 403];
const SCOPED = [
    [401, 200, 404, 200, 404, 200, 200, 404],
    [401, 404, 200, 404, 200, 200, 200, 404],
];
const OWNER_ONLY = [
    [401, 200, 404, 404, 404, 404, 404, 404],
    [401, 404, 200, 404, 404, 404, 404, 404],
];
const TEAM_ADMINS = [
    [401, 403, 403, 200, 404, 200, 200, 403],
    [401, 403, 403, 404, 200, 200, 200, 403],
];

integration('role and organization endpoint matrix', () => {
    let app;
    let prisma;
    let pool;
    let releaseDatabaseLock;
    let uploadRoot;
    let pinHash;
    let organizationsCreated = false;
    let usersCreated = false;
    const registeredRoutes = new Set();
    const previousWebhookSecret = process.env.MUX_WEBHOOK_SECRET;

    // The privileged claims are deliberately stale; each request must reload the real account.
    function headersFor(actor) {
        if (!actor.id) return {};
        const token = app.jwt.sign({ id: actor.id, role: 'SUPER_ADMIN', companyCode: 'SPRT' });
        return { authorization: `Bearer ${token}` };
    }

    function clipHeadersFor(actor) {
        if (!actor.id) return {};
        const token = app.jwt.sign({ id: actor.id, role: 'SUPER_ADMIN', companyCode: 'SPRT' });
        return { cookie: `fixer_clip_token=${token}` };
    }

    function request(actor, method, url, payload, headers = headersFor(actor)) {
        return app.inject({
            method,
            url,
            headers,
            ...(payload === undefined ? {} : { payload }),
        });
    }

    function visibleUserIds(actor) {
        if (actor.role === 'SUPER_ADMIN') return signedInActors.map(user => user.id);
        if (actor.role === 'ADMIN' && actor.companyCode) {
            return signedInActors.filter(user => user.companyCode === actor.companyCode).map(user => user.id);
        }
        return [actor.id];
    }

    function visibleAssetIds(actor) {
        const userIds = visibleUserIds(actor);
        return allAssets.filter(asset => userIds.includes(asset.userId)).map(asset => asset.id);
    }

    async function createUploadTarget(id, userId) {
        await prisma.asset.create({ data: { id, userId, status: 'UPLOADING' } });
    }

    async function clearForm(assetId) {
        await prisma.chatMessage.deleteMany({ where: { assetId, messageType: 'FORM_SUBMITTED' } });
        await prisma.formResponse.deleteMany({ where: { assetId } });
    }

    beforeAll(async () => {
        process.env.MUX_WEBHOOK_SECRET = 'matrix-webhook-secret';
        const database = await import('../lib/prisma.js');
        prisma = database.default;
        pool = database.pool;
        releaseDatabaseLock = await acquireIntegrationDatabaseLock(pool);
        const { authenticate } = await import('../lib/authentication.js');
        const { registerApplicationRoutes } = await import('../routes/index.js');
        const { default: localUploadRoutes } = await import('../routes/local-uploads.js');

        pinHash = await hashPin('1234');
        await prisma.organization.createMany({
            data: [
                { companyCode: 'NEWS', companyName: 'News' },
                { companyCode: 'SPRT', companyName: 'Sport' },
            ],
        });
        organizationsCreated = true;
        await prisma.user.createMany({
            data: signedInActors.map(actor => ({
                id: actor.id,
                name: actor.key,
                phoneNumber: actor.phoneNumber,
                pinHash,
                role: actor.role,
                companyCode: actor.companyCode,
            })),
        });
        usersCreated = true;
        await prisma.asset.createMany({
            data: [
                ...primaryAssets.map(asset => ({
                    id: asset.id,
                    userId: asset.userId,
                    mediasourceId: asset.mediasourceId,
                    mediasourceUrl: `/clips/${asset.mediasourceId}`,
                    status: 'READY',
                    clipCount: 1,
                    mediaSyncState: 'SYNCED',
                })),
                ...emptyAssets.map(asset => ({ ...asset, status: 'READY', mediaSyncState: 'SYNCED' })),
            ],
        });
        await prisma.clip.createMany({
            data: primaryAssets.map(asset => ({
                id: asset.clipId,
                assetId: asset.id,
                status: 'READY',
                storageUrl: `/uploads/${asset.fileName}`,
                muxPlaybackId: asset.playbackId,
                streamUrl: `https://stream.mux.com/${asset.playbackId}.m3u8`,
                thumbnailUrl: `https://image.mux.com/${asset.playbackId}/thumbnail.png`,
            })),
        });
        await prisma.chatMessage.createMany({
            data: messages.map(message => ({
                ...message,
                direction: 'OUTGOING',
                messageType: 'TEXT',
                content: { text: message.id },
            })),
        });

        uploadRoot = await mkdtemp(path.join(os.tmpdir(), 'dvu-step25-'));
        await Promise.all(primaryAssets.map(asset => writeFile(path.join(uploadRoot, asset.fileName), asset.id)));

        app = Fastify({ logger: false });
        app.addHook('onRoute', options => {
            for (const method of [options.method].flat()) {
                if (method !== 'HEAD') registeredRoutes.add(`${method} ${options.url}`);
            }
        });
        await app.register(cookie);
        await app.register(formbody);
        await app.register(csrfProtection);
        await app.register(fastifyJwt, { secret: 'matrix-only-jwt-secret' });
        app.decorate('authenticate', authenticate);
        app.decorate('requireRole', requireRole);
        app.decorate('io', {
            of: () => ({ sockets: new Map() }),
            to: () => ({ emit: () => {} }),
            in: () => ({ fetchSockets: async () => [] }),
            sockets: { sockets: new Map() },
        });
        app.decorate('userSockets', new Map());
        app.decorate('iosSockets', new Set());
        app.decorate('adminSockets', new Set());
        app.decorate('socketAuthState', { revision: 0 });
        await registerApplicationRoutes(app);
        await app.register(localUploadRoutes, { root: uploadRoot });
        await app.ready();
    }, 30000);

    afterAll(async () => {
        try {
            if (app) await app.close();
        } finally {
            try {
                if (prisma) {
                    try {
                        if (releaseDatabaseLock) {
                            const userIds = signedInActors.map(actor => actor.id);
                            if (usersCreated) {
                                await prisma.auditLog.deleteMany({ where: { actorUserId: { in: userIds } } });
                                await prisma.errorLog.deleteMany({ where: { userId: { in: userIds } } });
                                await prisma.chatMessage.deleteMany({ where: { userId: { in: userIds } } });
                                await prisma.asset.deleteMany({ where: { userId: { in: userIds } } });
                                await prisma.user.deleteMany({ where: { id: { in: userIds } } });
                            }
                            if (organizationsCreated) {
                                await prisma.organization.deleteMany({ where: { companyCode: { in: ['NEWS', 'SPRT'] } } });
                            }
                        }
                    } finally {
                        try {
                            await releaseDatabaseLock?.();
                        } finally {
                            await prisma.$disconnect();
                        }
                    }
                }
            } finally {
                try {
                    if (uploadRoot) await rm(uploadRoot, { recursive: true, force: true });
                } finally {
                    if (previousWebhookSecret === undefined) delete process.env.MUX_WEBHOOK_SECRET;
                    else process.env.MUX_WEBHOOK_SECRET = previousWebhookSecret;
                }
            }
        }
    });

    const scalarCases = [
        {
            route: 'GET /api/auth/me', method: 'GET', url: '/api/auth/me', statuses: ALL,
            check: async (response, actor) => {
                if (response.statusCode === 200) expect(response.json().user.id).toBe(actor.id);
            },
        },
        {
            route: 'POST /api/assets', method: 'POST', url: '/api/assets', statuses: ALL,
            payload: () => ({ fileName: 'matrix.mov' }),
            check: async (response, actor) => {
                if (response.statusCode === 200) {
                    const created = await prisma.asset.findUnique({ where: { id: response.json().asset.id } });
                    expect(created.userId).toBe(actor.id);
                }
            },
            after: async (_actor, response) => {
                if (response?.statusCode === 200) {
                    await prisma.asset.deleteMany({ where: { id: response.json().asset.id } });
                }
            },
        },
        {
            route: 'GET /api/assets/mine', method: 'GET', url: '/api/assets/mine', statuses: ALL,
            check: async (response, actor) => {
                if (response.statusCode === 200) {
                    expect(response.json().assets.map(asset => asset.id).sort())
                        .toEqual(allAssets.filter(asset => asset.userId === actor.id).map(asset => asset.id).sort());
                }
            },
        },
        {
            route: 'GET /api/messages', method: 'GET', url: '/api/messages', statuses: ALL,
            check: async (response, actor) => {
                if (response.statusCode === 200) {
                    expect(response.json().messages.map(message => message.id).sort())
                        .toEqual(messages.filter(message => message.userId === actor.id).map(message => message.id).sort());
                }
            },
        },
        {
            route: 'POST /api/errors', method: 'POST', url: '/api/errors', statuses: ALL,
            payload: () => ({ source: 'matrix', category: 'test', message: 'synthetic error' }),
            check: async (response, actor) => {
                if (response.statusCode === 200) {
                    const logged = await prisma.errorLog.findUnique({ where: { id: response.json().errorLog.id } });
                    expect(logged.userId).toBe(actor.id);
                }
            },
            after: async (_actor, response) => {
                if (response?.statusCode === 200) {
                    await prisma.errorLog.deleteMany({ where: { id: response.json().errorLog.id } });
                }
            },
        },
        { route: 'GET /api/admin/status', method: 'GET', url: '/api/admin/status', statuses: SUPER },
        {
            route: 'GET /api/admin/stats', method: 'GET', url: '/api/admin/stats', statuses: ALL,
            check: async (response, actor) => {
                if (response.statusCode === 200) {
                    const userIds = visibleUserIds(actor);
                    expect(response.json()).toMatchObject({
                        users: userIds.length,
                        assets: visibleAssetIds(actor).length,
                        messages: messages.filter(message => userIds.includes(message.userId)).length,
                    });
                }
            },
        },
        {
            route: 'GET /api/admin/users', method: 'GET', url: '/api/admin/users', statuses: ALL,
            check: async (response, actor) => {
                if (response.statusCode === 200) {
                    expect(response.json().users.map(user => user.id).sort()).toEqual(visibleUserIds(actor).sort());
                }
            },
        },
        {
            route: 'GET /api/admin/assets', method: 'GET', url: '/api/admin/assets', statuses: ALL,
            check: async (response, actor) => {
                if (response.statusCode === 200) {
                    expect(response.json().assets.map(asset => asset.id).sort()).toEqual(visibleAssetIds(actor).sort());
                }
            },
        },
        {
            route: 'GET /api/admin/messages', method: 'GET', url: '/api/admin/messages', statuses: ALL,
            check: async (response, actor) => {
                if (response.statusCode === 200) {
                    const userIds = visibleUserIds(actor);
                    expect(response.json().messages.map(message => message.id).sort())
                        .toEqual(messages.filter(message => userIds.includes(message.userId)).map(message => message.id).sort());
                }
            },
        },
        {
            route: 'POST /api/admin/cleanup-assets', method: 'POST', url: '/api/admin/cleanup-assets',
            statuses: SUPER, payload: () => ({}),
            check: async response => {
                if (response.statusCode === 200) expect(response.json().cleaned).toBe(0);
            },
        },
        {
            route: 'POST /api/admin/nuclear-reset', method: 'POST', url: '/api/admin/nuclear-reset',
            statuses: SUPER_CONFLICT, payload: () => ({}),
            check: async () => {
                expect(await prisma.asset.count({ where: { id: { in: allAssets.map(asset => asset.id) } } }))
                    .toBe(allAssets.length);
            },
        },
        {
            route: 'POST /api/admin/users', method: 'POST', url: '/api/admin/users', statuses: ADMINS,
            payload: actor => ({ name: 'Matrix New', phoneNumber: `558190000${actor.index}` }),
            check: async (response, actor) => {
                const user = await prisma.user.findUnique({ where: { phoneNumber: `558190000${actor.index}` } });
                if (response.statusCode === 200) {
                    expect(user.companyCode).toBe(actor.role === 'ADMIN' ? actor.companyCode : null);
                    expect(user.role).toBe('USER');
                } else {
                    expect(user).toBeNull();
                }
            },
            after: async actor => {
                await prisma.user.deleteMany({ where: { phoneNumber: `558190000${actor.index}` } });
            },
        },
        {
            route: 'DELETE /api/admin/users/:id', method: 'DELETE', url: '/api/admin/users/matrix-delete-target',
            statuses: SUPER,
            before: async () => {
                await prisma.user.create({
                    data: {
                        id: 'matrix-delete-target', name: 'Delete Target', phoneNumber: '5581900099',
                        pinHash, role: 'USER', companyCode: 'NEWS',
                    },
                });
            },
            check: async response => {
                const user = await prisma.user.findUnique({ where: { id: 'matrix-delete-target' } });
                if (response.statusCode === 200) expect(user).toBeNull();
                else expect(user).not.toBeNull();
            },
            after: async () => { await prisma.user.deleteMany({ where: { id: 'matrix-delete-target' } }); },
        },
        {
            route: 'GET /api/admin/organizations', method: 'GET', url: '/api/admin/organizations',
            statuses: ADMINS,
            check: async (response, actor) => {
                if (response.statusCode === 200) {
                    const expected = actor.role === 'SUPER_ADMIN' ? ['NEWS', 'SPRT'] : [actor.companyCode];
                    expect(response.json().organizations.map(org => org.companyCode).sort()).toEqual(expected.sort());
                }
            },
        },
        {
            route: 'POST /api/admin/organizations', method: 'POST', url: '/api/admin/organizations',
            statuses: SUPER, payload: () => ({ companyName: 'Matrix Team', companyCode: 'MTX' }),
            check: async response => {
                const org = await prisma.organization.findUnique({ where: { companyCode: 'MTX' } });
                if (response.statusCode === 200) expect(org.companyName).toBe('Matrix Team');
                else expect(org).toBeNull();
            },
            after: async () => { await prisma.organization.deleteMany({ where: { companyCode: 'MTX' } }); },
        },
        {
            route: 'PUT /api/admin/organizations/:code', method: 'PUT', url: '/api/admin/organizations/NEWS',
            statuses: SUPER, payload: () => ({ companyName: 'News' }),
            check: async () => {
                const org = await prisma.organization.findUnique({ where: { companyCode: 'NEWS' } });
                expect(org.companyName).toBe('News');
            },
        },
        {
            route: 'DELETE /api/admin/organizations/:code', method: 'DELETE', url: '/api/admin/organizations/MTD',
            statuses: SUPER,
            before: async () => {
                await prisma.organization.create({ data: { companyCode: 'MTD', companyName: 'Matrix Delete' } });
            },
            check: async response => {
                const org = await prisma.organization.findUnique({ where: { companyCode: 'MTD' } });
                if (response.statusCode === 200) expect(org).toBeNull();
                else expect(org).not.toBeNull();
            },
            after: async () => { await prisma.organization.deleteMany({ where: { companyCode: 'MTD' } }); },
        },
        {
            route: 'POST /api/admin/assets/:id/media-sync/confirm-create', method: 'POST',
            url: `/api/admin/assets/${teams[0].asset.id}/media-sync/confirm-create`,
            statuses: SUPER_CONFLICT,
            payload: () => ({ operationId: 'not-current', confirmed: true, reason: 'Matrix test' }),
            check: async () => {
                const asset = await prisma.asset.findUnique({ where: { id: teams[0].asset.id } });
                expect(asset.mediaCreateOperationId).toBeNull();
            },
        },
        { route: 'GET /api/admin/media-issues', method: 'GET', url: '/api/admin/media-issues', statuses: SUPER },
        { route: 'GET /api/admin/audit-logs', method: 'GET', url: '/api/admin/audit-logs', statuses: SUPER },
        { route: 'GET /api/admin/errors', method: 'GET', url: '/api/admin/errors', statuses: SUPER },
    ];

    const teamCases = [
        {
            route: 'GET /api/assets/:id', method: 'GET', statuses: SCOPED,
            url: team => `/api/assets/${team.asset.id}`,
            check: async (response, _actor, team) => {
                if (response.statusCode === 200) expect(response.json().asset.id).toBe(team.asset.id);
                else expect(response.body).not.toContain(team.asset.playbackId);
            },
        },
        {
            route: 'POST /api/assets/:id/mux-upload', method: 'POST', statuses: OWNER_ONLY,
            url: team => `/api/assets/matrix-upload-target-${team.key}/mux-upload`,
            payload: () => ({ metadata: { mimeType: 'video/mp4' } }),
            before: async (_actor, team) => { await createUploadTarget(`matrix-upload-target-${team.key}`, team.userId); },
            check: async (response, _actor, _team, callsBefore) => {
                expect(mux.createDirectUpload.mock.calls.length - callsBefore).toBe(response.statusCode === 200 ? 1 : 0);
                if (response.statusCode === 200) expect(response.json().uploadUrl).toContain('https://upload.invalid/');
            },
            after: async (_actor, team) => {
                await prisma.asset.deleteMany({ where: { id: `matrix-upload-target-${team.key}` } });
            },
        },
        {
            route: 'POST /api/assets/:id/form', method: 'POST', statuses: OWNER_ONLY,
            url: team => `/api/assets/${team.asset.id}/form`,
            payload: () => ({ slug: 'matrix', description: 'Matrix form' }),
            check: async (response, _actor, team) => {
                const form = await prisma.formResponse.findUnique({ where: { assetId: team.asset.id } });
                if (response.statusCode === 200) expect(form.description).toBe('Matrix form');
                else expect(form).toBeNull();
            },
            after: async (_actor, team) => { await clearForm(team.asset.id); },
        },
        {
            route: 'PATCH /api/assets/:id/transcript', method: 'PATCH', statuses: OWNER_ONLY,
            url: team => `/api/assets/${team.asset.id}/transcript`,
            payload: () => ({ transcript: 'Matrix transcript' }),
            check: async (response, _actor, team) => {
                const clip = await prisma.clip.findUnique({ where: { id: team.asset.clipId } });
                expect(clip.transcript).toBe(response.statusCode === 200 ? 'Matrix transcript' : null);
            },
            after: async (_actor, team) => {
                await prisma.clip.update({ where: { id: team.asset.clipId }, data: { transcript: null } });
            },
        },
        {
            route: 'PATCH /api/assets/:id/clips/:clipId/transcript', method: 'PATCH', statuses: OWNER_ONLY,
            url: team => `/api/assets/${team.asset.id}/clips/${team.asset.clipId}/transcript`,
            payload: team => ({ clipId: team.asset.clipId, transcript: 'Matrix transcript' }),
            check: async (response, _actor, team) => {
                const clip = await prisma.clip.findUnique({ where: { id: team.asset.clipId } });
                expect(clip.transcript).toBe(response.statusCode === 200 ? 'Matrix transcript' : null);
            },
            after: async (_actor, team) => {
                await prisma.clip.update({ where: { id: team.asset.clipId }, data: { transcript: null } });
            },
        },
        {
            route: 'GET /api/mux/status/:clipId', method: 'GET', statuses: SCOPED,
            url: team => `/api/mux/status/${team.asset.clipId}`,
            check: async (response, _actor, team) => {
                if (response.statusCode === 200) expect(response.json().muxPlaybackId).toBe(team.asset.playbackId);
                else expect(response.body).not.toContain(team.asset.playbackId);
            },
        },
        {
            route: 'PATCH /api/admin/users/:id', method: 'PATCH', statuses: TEAM_ADMINS,
            url: team => `/api/admin/users/${team.userId}`,
            payload: () => ({ name: 'Matrix Changed' }),
            check: async (response, _actor, team) => {
                const user = await prisma.user.findUnique({ where: { id: team.userId } });
                expect(user.name).toBe(response.statusCode === 200 ? 'Matrix Changed' : `user-${team.key}`);
            },
            after: async (_actor, team) => {
                await prisma.user.update({ where: { id: team.userId }, data: { name: `user-${team.key}` } });
            },
        },
        {
            route: 'PATCH /api/admin/users/:id/role', method: 'PATCH', statuses: TEAM_ADMINS,
            url: team => `/api/admin/users/${team.userId}/role`,
            payload: () => ({ role: 'USER' }),
            check: async (_response, _actor, team) => {
                expect((await prisma.user.findUnique({ where: { id: team.userId } })).role).toBe('USER');
            },
        },
        {
            route: 'PATCH /api/admin/users/:id/status', method: 'PATCH', statuses: TEAM_ADMINS,
            url: team => `/api/admin/users/${team.userId}/status`,
            payload: () => ({ status: 'ACTIVE' }),
            check: async (_response, _actor, team) => {
                expect((await prisma.user.findUnique({ where: { id: team.userId } })).status).toBe('ACTIVE');
            },
        },
        {
            route: 'PATCH /api/admin/assets/:id/moderation', method: 'PATCH', statuses: TEAM_ADMINS,
            url: team => `/api/admin/assets/${team.moderationAssetId}/moderation`,
            payload: () => ({ moderation: 'ACTIVE' }),
            check: async (_response, _actor, team) => {
                expect((await prisma.asset.findUnique({ where: { id: team.moderationAssetId } })).moderation)
                    .toBe('ACTIVE');
            },
        },
        {
            route: 'GET /clips/:mediasourceId/status', method: 'GET', statuses: SCOPED,
            url: team => `/clips/${team.sharedAsset.mediasourceId}/status`, clipCookie: true,
            check: async (response, _actor, team) => {
                if (response.statusCode === 200) expect(response.json().muxPlaybackId).toBe(team.sharedAsset.playbackId);
                else expect(response.body).not.toContain(team.sharedAsset.playbackId);
            },
        },
        {
            route: 'GET /clips/:mediasourceId', method: 'GET',
            statuses: SCOPED.map(statuses => statuses.map(status => status === 401 ? 302 : status)),
            url: team => `/clips/${team.sharedAsset.mediasourceId}`, clipCookie: true,
            check: async (response, _actor, team) => {
                if (response.statusCode === 200) expect(response.body).toContain(team.sharedAsset.playbackId);
                else expect(response.body).not.toContain(team.sharedAsset.playbackId);
            },
        },
    ];

    for (const spec of scalarCases) {
        describe(spec.route, () => {
            it.each(actors)('$key', async actor => {
                let response;
                try {
                    await spec.before?.(actor);
                    response = await request(actor, spec.method, spec.url, spec.payload?.(actor));
                    expect(response.statusCode, response.body).toBe(spec.statuses[actor.index]);
                    await spec.check?.(response, actor);
                } finally {
                    await spec.after?.(actor, response);
                }
            });
        });
    }

    for (const spec of teamCases) {
        describe(spec.route, () => {
            for (const [teamIndex, team] of teams.entries()) {
                it.each(actors)(`${team.key} target / $key`, async actor => {
                    let response;
                    const callsBefore = mux.createDirectUpload.mock.calls.length;
                    try {
                        await spec.before?.(actor, team);
                        response = await request(
                            actor, spec.method, spec.url(team), spec.payload?.(team),
                            spec.clipCookie ? clipHeadersFor(actor) : headersFor(actor),
                        );
                        expect(response.statusCode, response.body).toBe(spec.statuses[teamIndex][actor.index]);
                        await spec.check?.(response, actor, team, callsBefore);
                    } finally {
                        await spec.after?.(actor, team, response);
                    }
                });
            }
        });
    }

    const publicRoutes = [
        'POST /api/auth/login',
        'GET /clips/login',
        'POST /clips/login',
        'POST /clips/logout',
        'POST /api/webhooks/mux',
        'GET /api/mux/env-key',
        'GET /uploads/*',
    ];

    it('requires every registered application route to appear in the matrix or public-route tests', () => {
        expect([...registeredRoutes].sort()).toEqual([
            ...scalarCases.map(spec => spec.route),
            ...teamCases.map(spec => spec.route),
            ...publicRoutes,
        ].sort());
    });

    it.each(signedInActors)('accepts $key credentials and returns the current role', async actor => {
        const response = await request(null, 'POST', '/api/auth/login', {
            phoneNumber: actor.phoneNumber, pin: '1234', clientType: 'admin',
        }, {});
        expect(response.statusCode, response.body).toBe(200);
        expect(response.json().user).toMatchObject({ id: actor.id, role: actor.role, companyCode: actor.companyCode });
        expect(app.jwt.verify(response.json().token).role).toBe(actor.role);
    });

    it.each(signedInActors)('checks $key credentials and CSRF on clip login', async actor => {
        const page = await app.inject({ method: 'GET', url: '/clips/login' });
        const csrfToken = page.body.match(/name="_csrf" value="([^"]+)"/)?.[1];
        expect(csrfToken).toBeTruthy();
        const cookieHeader = page.cookies.map(item => `${item.name}=${item.value}`).join('; ');
        const destination = `/clips/${teams[0].asset.mediasourceId}`;
        const payload = new URLSearchParams({
            _csrf: csrfToken,
            phoneNumber: actor.phoneNumber,
            pin: '1234',
            companyCode: actor.companyCode || 'NEWS',
            redirect: destination,
        }).toString();
        const response = await app.inject({
            method: 'POST',
            url: '/clips/login',
            headers: { cookie: cookieHeader, 'content-type': 'application/x-www-form-urlencoded' },
            payload,
        });
        expect(response.statusCode).toBe(302);
        const clipCookie = response.cookies.find(item => item.name === 'fixer_clip_token');
        if (actor.companyCode) {
            expect(response.headers.location).toBe(destination);
            expect(app.jwt.verify(clipCookie.value).id).toBe(actor.id);
        } else {
            expect(response.headers.location).toContain('error=Invalid%20credentials');
            expect(clipCookie).toBeUndefined();
        }
    });

    it('requires a CSRF token for clip login', async () => {
        const response = await app.inject({
            method: 'POST',
            url: '/clips/login',
            headers: { 'content-type': 'application/x-www-form-urlencoded' },
            payload: 'phoneNumber=5581000001&pin=1234&companyCode=NEWS',
        });
        expect(response.statusCode).toBe(403);
    });

    it.each(actors)('treats public routes independently of $key role claims', async actor => {
        const login = await request(actor, 'GET', '/clips/login', undefined, clipHeadersFor(actor));
        const logout = await request(actor, 'POST', '/clips/logout', undefined, clipHeadersFor(actor));
        const envKey = await request(actor, 'GET', '/api/mux/env-key');
        const webhook = await request(actor, 'POST', '/api/webhooks/mux', { type: 'video.asset.ready' });
        expect(login.statusCode).toBe(200);
        expect(logout.statusCode).toBe(302);
        expect(envKey.statusCode).toBe(200);
        expect(webhook.statusCode).toBe(401);
    });

    it.each(signedInActors)('allows $key to use owner-only write routes for their own assets', async actor => {
        const asset = primaryAssets.find(item => item.userId === actor.id);
        const uploadId = `matrix-owned-upload-${actor.key}`;
        try {
            const form = await request(actor, 'POST', `/api/assets/${asset.id}/form`, {
                slug: 'own', description: 'Owner form',
            });
            expect(form.statusCode, form.body).toBe(200);
            expect((await prisma.formResponse.findUnique({ where: { assetId: asset.id } })).description).toBe('Owner form');

            for (const url of [
                `/api/assets/${asset.id}/transcript`,
                `/api/assets/${asset.id}/clips/${asset.clipId}/transcript`,
            ]) {
                const transcript = await request(actor, 'PATCH', url, { transcript: 'Owner transcript' });
                expect(transcript.statusCode, transcript.body).toBe(200);
                expect(transcript.json().clipId).toBe(asset.clipId);
            }
            expect((await prisma.clip.findUnique({ where: { id: asset.clipId } })).transcript).toBe('Owner transcript');

            await createUploadTarget(uploadId, actor.id);
            const upload = await request(actor, 'POST', `/api/assets/${uploadId}/mux-upload`, {
                metadata: { mimeType: 'video/mp4' },
            });
            expect(upload.statusCode, upload.body).toBe(200);
            expect(upload.json().uploadUrl).toContain('https://upload.invalid/');
            expect((await prisma.clip.findUnique({ where: { id: upload.json().clipId } })).assetId).toBe(uploadId);
        } finally {
            await clearForm(asset.id);
            await prisma.clip.update({ where: { id: asset.clipId }, data: { transcript: null } });
            await prisma.asset.deleteMany({ where: { id: uploadId } });
        }
    });

    it.each(teams)('enforces organization boundaries during $key member changes', async team => {
        const admin = signedInActors.find(actor => actor.key === `admin-${team.key}`);
        const otherTeam = teams.find(item => item.key !== team.key);
        const otherCode = otherTeam.key === 'news' ? 'NEWS' : 'SPRT';
        const phoneNumber = '5581900199';
        try {
            const foreignPromotion = await request(admin, 'PATCH', `/api/admin/users/${otherTeam.userId}/role`, {
                role: 'ADMIN',
            });
            expect(foreignPromotion.statusCode).toBe(404);
            expect((await prisma.user.findUnique({ where: { id: otherTeam.userId } })).role).toBe('USER');

            const promotion = await request(admin, 'PATCH', `/api/admin/users/${team.userId}/role`, { role: 'ADMIN' });
            expect(promotion.statusCode, promotion.body).toBe(200);
            expect((await prisma.user.findUnique({ where: { id: team.userId } })).role).toBe('ADMIN');
            const demotion = await request(admin, 'PATCH', `/api/admin/users/${team.userId}/role`, { role: 'USER' });
            expect(demotion.statusCode, demotion.body).toBe(200);

            const foreignPause = await request(admin, 'PATCH', `/api/admin/users/${otherTeam.userId}/status`, {
                status: 'SUSPENDED',
            });
            expect(foreignPause.statusCode).toBe(404);
            const pause = await request(admin, 'PATCH', `/api/admin/users/${team.userId}/status`, {
                status: 'SUSPENDED', reason: 'Matrix pause',
            });
            expect(pause.statusCode, pause.body).toBe(200);
            const owner = signedInActors.find(actor => actor.id === team.userId);
            expect((await request(owner, 'GET', '/api/auth/me')).statusCode).toBe(403);
            const unpause = await request(admin, 'PATCH', `/api/admin/users/${team.userId}/status`, {
                status: 'ACTIVE',
            });
            expect(unpause.statusCode, unpause.body).toBe(200);
            expect((await request(owner, 'GET', '/api/auth/me')).statusCode).toBe(200);

            const move = await request(admin, 'PATCH', `/api/admin/users/${team.userId}`, { companyCode: otherCode });
            expect(move.statusCode).toBe(403);
            const createOutside = await request(admin, 'POST', '/api/admin/users', {
                name: 'Outside User', phoneNumber, companyCode: otherCode,
            });
            expect(createOutside.statusCode).toBe(403);
            expect(await prisma.user.findUnique({ where: { phoneNumber } })).toBeNull();
        } finally {
            await prisma.user.update({
                where: { id: team.userId },
                data: { role: 'USER', status: 'ACTIVE', pausedAt: null, pausedById: null },
            });
            await prisma.user.deleteMany({ where: { phoneNumber } });
            await prisma.auditLog.deleteMany({ where: { targetType: 'USER', targetId: team.userId } });
        }
    });

    it.each(teams)('enforces $key moderation transitions and Super Admin removal', async team => {
        const admin = signedInActors.find(actor => actor.key === `admin-${team.key}`);
        const otherAdmin = signedInActors.find(actor => actor.key === `admin-${team.key === 'news' ? 'sport' : 'news'}`);
        const superAdmin = signedInActors.find(actor => actor.key === 'super-sport');
        const url = `/api/admin/assets/${team.moderationAssetId}/moderation`;
        try {
            const foreign = await request(otherAdmin, 'PATCH', url, { moderation: 'PAUSED' });
            expect(foreign.statusCode).toBe(404);
            const unauthorizedRemoval = await request(admin, 'PATCH', url, {
                moderation: 'REMOVED', reason: 'Matrix removal',
            });
            expect(unauthorizedRemoval.statusCode).toBe(403);

            const paused = await request(admin, 'PATCH', url, { moderation: 'PAUSED' });
            expect(paused.statusCode, paused.body).toBe(200);
            expect((await prisma.asset.findUnique({ where: { id: team.moderationAssetId } })).moderation).toBe('PAUSED');

            const flagged = await request(admin, 'PATCH', url, {
                moderation: 'FLAGGED_FOR_REMOVAL', reason: 'Matrix flag',
            });
            expect(flagged.statusCode, flagged.body).toBe(200);
            expect((await request(admin, 'PATCH', url, { moderation: 'ACTIVE' })).statusCode).toBe(409);

            const restored = await request(superAdmin, 'PATCH', url, { moderation: 'ACTIVE' });
            expect(restored.statusCode, restored.body).toBe(200);
            const flaggedAgain = await request(admin, 'PATCH', url, {
                moderation: 'FLAGGED_FOR_REMOVAL', reason: 'Matrix flag',
            });
            expect(flaggedAgain.statusCode, flaggedAgain.body).toBe(200);
            const removed = await request(superAdmin, 'PATCH', url, {
                moderation: 'REMOVED', reason: 'Matrix removal',
            });
            expect(removed.statusCode, removed.body).toBe(200);
            expect((await prisma.asset.findUnique({ where: { id: team.moderationAssetId } })).moderation).toBe('REMOVED');
        } finally {
            await prisma.asset.update({
                where: { id: team.moderationAssetId },
                data: {
                    moderation: 'ACTIVE', moderatedAt: null, moderatedById: null, moderationReason: null,
                    mediaSyncState: 'SYNCED', mediaSyncError: null, mediaSyncNextAt: null, mediaPlaybackReset: false,
                },
            });
            await prisma.auditLog.deleteMany({ where: { targetType: 'ASSET', targetId: team.moderationAssetId } });
        }
    });

    describe('moderation visibility', () => {
        for (const [teamIndex, team] of teams.entries()) {
            it.each(['ACTIVE', 'PAUSED', 'FLAGGED_FOR_REMOVAL', 'REMOVED'])(
                `${team.key} asset in %s`,
                async moderation => {
                    await prisma.asset.update({
                        where: { id: team.asset.id },
                        data: { moderation, mediaPlaybackReset: false },
                    });
                    try {
                        const thumbnailUrl = moderation === 'ACTIVE'
                            ? `https://image.mux.com/${team.asset.playbackId}/thumbnail.png`
                            : null;
                        for (const actor of signedInActors) {
                            const scoped = SCOPED[teamIndex][actor.index] === 200;
                            const isSuper = actor.role === 'SUPER_ADMIN';
                            const isOwner = actor.id === team.userId;
                            const expectedDefault = (moderation === 'ACTIVE' && scoped)
                                || (moderation === 'PAUSED' && isOwner);

                            const mine = await request(actor, 'GET', '/api/assets/mine');
                            expect(mine.statusCode).toBe(200);
                            const owned = mine.json().assets.find(asset => asset.id === team.asset.id);
                            expect(Boolean(owned)).toBe(isOwner && ['ACTIVE', 'PAUSED'].includes(moderation));
                            if (owned) {
                                expect(owned.clips[0]).toMatchObject({ id: team.asset.clipId, thumbnailUrl });
                            } else {
                                expect(mine.body).not.toContain(team.asset.playbackId);
                            }

                            const list = await request(actor, 'GET', '/api/admin/assets');
                            expect(list.statusCode).toBe(200);
                            const defaultListed = list.json().assets.find(asset => asset.id === team.asset.id);
                            expect(Boolean(defaultListed)).toBe(expectedDefault);
                            if (defaultListed) {
                                expect(defaultListed.clips[0]).toMatchObject({ id: team.asset.clipId, thumbnailUrl });
                            } else {
                                expect(list.body).not.toContain(team.asset.playbackId);
                            }

                            const filtered = await request(actor, 'GET', `/api/admin/assets?moderation=${moderation}`);
                            if (moderation === 'REMOVED') {
                                expect(filtered.statusCode).toBe(400);
                            } else if (moderation === 'FLAGGED_FOR_REMOVAL' && !isSuper) {
                                expect(filtered.statusCode).toBe(403);
                            } else {
                                expect(filtered.statusCode).toBe(200);
                                const listed = filtered.json().assets.find(asset => asset.id === team.asset.id);
                                expect(Boolean(listed)).toBe(scoped);
                                if (listed) {
                                    expect(listed.mediaPlaybackUnavailable).toBe(moderation !== 'ACTIVE');
                                    expect(listed.clips[0]).toMatchObject({ id: team.asset.clipId, thumbnailUrl });
                                } else {
                                    expect(filtered.body).not.toContain(team.asset.playbackId);
                                }
                            }

                            const detail = await request(actor, 'GET', `/api/assets/${team.asset.id}`);
                            const canViewDetail = (['ACTIVE', 'PAUSED'].includes(moderation) && scoped)
                                || (moderation === 'FLAGGED_FOR_REMOVAL' && isSuper);
                            expect(detail.statusCode).toBe(canViewDetail ? 200 : 404);
                            if (canViewDetail) {
                                const clip = detail.json().asset.clips.find(item => item.id === team.asset.clipId);
                                if (moderation === 'ACTIVE') {
                                    expect(clip).toMatchObject({
                                        storageUrl: `/uploads/${team.asset.fileName}`,
                                        muxPlaybackId: team.asset.playbackId,
                                        streamUrl: `https://stream.mux.com/${team.asset.playbackId}.m3u8`,
                                    });
                                } else {
                                    expect(clip).toMatchObject({
                                        storageUrl: null, muxPlaybackId: null, streamUrl: null, thumbnailUrl: null,
                                    });
                                }
                            } else {
                                expect(detail.body).not.toContain(team.asset.playbackId);
                            }

                            const muxStatus = await request(actor, 'GET', `/api/mux/status/${team.asset.clipId}`);
                            expect(muxStatus.statusCode).toBe(moderation === 'ACTIVE' && scoped ? 200 : 404);
                            if (muxStatus.statusCode === 200) {
                                expect(muxStatus.json().muxPlaybackId).toBe(team.asset.playbackId);
                            } else {
                                expect(muxStatus.body).not.toContain(team.asset.playbackId);
                            }

                            const owner = signedInActors.find(item => item.id === team.userId);
                            const canViewShared = moderation === 'ACTIVE'
                                && (isSuper || actor.companyCode === owner.companyCode);
                            const sharedStatus = await request(
                                actor, 'GET', `/clips/${team.asset.mediasourceId}/status`,
                                undefined, clipHeadersFor(actor),
                            );
                            const sharedPage = await request(
                                actor, 'GET', `/clips/${team.asset.mediasourceId}`,
                                undefined, clipHeadersFor(actor),
                            );
                            expect(sharedStatus.statusCode).toBe(canViewShared ? 200 : 404);
                            expect(sharedPage.statusCode).toBe(canViewShared ? 200 : 404);
                            if (canViewShared) {
                                expect(sharedStatus.json().muxPlaybackId).toBe(team.asset.playbackId);
                                expect(sharedPage.body).toContain(team.asset.playbackId);
                            } else {
                                expect(sharedStatus.body).not.toContain(team.asset.playbackId);
                                expect(sharedPage.body).not.toContain(team.asset.playbackId);
                            }
                        }

                        const local = await app.inject({ method: 'GET', url: `/uploads/${team.asset.fileName}` });
                        expect(local.statusCode).toBe(moderation === 'ACTIVE' ? 200 : 404);
                        if (moderation === 'ACTIVE') {
                            expect(local.body).toBe(team.asset.id);
                            expect(local.headers['cache-control']).toBe('no-store');
                        }

                        if (moderation !== 'ACTIVE') {
                            const owner = signedInActors.find(actor => actor.id === team.userId);
                            const callsBefore = mux.createDirectUpload.mock.calls.length;
                            const form = await request(owner, 'POST', `/api/assets/${team.asset.id}/form`, {
                                slug: 'denied', description: 'Must not be saved',
                            });
                            const upload = await request(owner, 'POST', `/api/assets/${team.asset.id}/mux-upload`, {
                                metadata: { mimeType: 'video/mp4' },
                            });
                            expect(form.statusCode).toBe(409);
                            expect(upload.statusCode).toBe(409);
                            expect(await prisma.formResponse.findUnique({ where: { assetId: team.asset.id } })).toBeNull();
                            expect(mux.createDirectUpload.mock.calls.length).toBe(callsBefore);
                        }
                    } finally {
                        await prisma.asset.update({
                            where: { id: team.asset.id },
                            data: { moderation: 'ACTIVE', mediaPlaybackReset: false },
                        });
                    }
                },
            );
        }

        for (const [teamIndex, team] of teams.entries()) {
            it.each([
                ['playback reset', { mediaPlaybackReset: true }],
                ['uncertain create', {
                    mediaCreateOperationId: 'matrix-pending-operation',
                    mediaCreateMuxAssetId: 'matrix-pending-mux',
                    mediaCreateStartedAt: new Date('2026-01-01T00:00:00Z'),
                }],
            ])(`${team.key} asset with %s`, async (_label, pending) => {
                await prisma.asset.update({ where: { id: team.asset.id }, data: pending });
                try {
                    for (const actor of signedInActors) {
                        if (SCOPED[teamIndex][actor.index] !== 200) continue;

                        const list = await request(actor, 'GET', '/api/admin/assets');
                        const listed = list.json().assets.find(asset => asset.id === team.asset.id);
                        expect(listed.mediaPlaybackUnavailable).toBe(true);
                        expect(listed.clips[0]).toMatchObject({ id: team.asset.clipId, thumbnailUrl: null });
                        expect(list.body).not.toContain(team.asset.playbackId);
                        expect(listed.mediaCreateOperationId).toBe(
                            actor.role === 'SUPER_ADMIN' ? (pending.mediaCreateOperationId || null) : null,
                        );
                        expect(listed.mediaCreateMuxAssetId).toBe(
                            actor.role === 'SUPER_ADMIN' ? (pending.mediaCreateMuxAssetId || null) : null,
                        );

                        if (actor.id === team.userId) {
                            const mine = await request(actor, 'GET', '/api/assets/mine');
                            const owned = mine.json().assets.find(asset => asset.id === team.asset.id);
                            expect(owned.clips[0]).toMatchObject({ id: team.asset.clipId, thumbnailUrl: null });
                            expect(mine.body).not.toContain(team.asset.playbackId);
                        }

                        const detail = await request(actor, 'GET', `/api/assets/${team.asset.id}`);
                        expect(detail.statusCode).toBe(200);
                        expect(detail.json().asset.clips[0]).toMatchObject({
                            storageUrl: null, muxPlaybackId: null, streamUrl: null, thumbnailUrl: null,
                        });

                        const muxStatus = await request(actor, 'GET', `/api/mux/status/${team.asset.clipId}`);
                        expect(muxStatus.statusCode).toBe(200);
                        expect(muxStatus.body).not.toContain(team.asset.playbackId);
                        expect(muxStatus.json()).not.toHaveProperty('streamUrl');

                        const sharedStatus = await request(
                            actor, 'GET', `/clips/${team.asset.mediasourceId}/status`,
                            undefined, clipHeadersFor(actor),
                        );
                        const sharedPage = await request(
                            actor, 'GET', `/clips/${team.asset.mediasourceId}`,
                            undefined, clipHeadersFor(actor),
                        );
                        expect(sharedStatus.statusCode).toBe(200);
                        expect(sharedStatus.json()).toMatchObject({ ready: false, muxPlaybackId: null });
                        expect(sharedPage.statusCode).toBe(200);
                        expect(sharedPage.body).not.toContain(team.asset.playbackId);
                        expect(sharedPage.body).not.toContain(`/uploads/${team.asset.fileName}`);
                    }
                    const local = await app.inject({ method: 'GET', url: `/uploads/${team.asset.fileName}` });
                    expect(local.statusCode).toBe(404);
                } finally {
                    await prisma.asset.update({
                        where: { id: team.asset.id },
                        data: {
                            mediaPlaybackReset: false,
                            mediaCreateOperationId: null,
                            mediaCreateMuxAssetId: null,
                            mediaCreateStartedAt: null,
                        },
                    });
                }
            });
        }

        it('orders multiple clips newest first and redacts every thumbnail when playback is unavailable', async () => {
            const team = teams[0];
            const clipId = 'matrix-latest-clip-z';
            const tiedClipId = 'matrix-latest-clip-a';
            const thumbnailUrl = 'https://image.mux.com/matrix-latest-playback/thumbnail.png';
            const tiedThumbnailUrl = 'https://image.mux.com/matrix-tied-playback/thumbnail.png';
            const createdAt = new Date('2100-01-01T00:00:00Z');
            await prisma.clip.createMany({
                data: [
                    { id: tiedClipId, assetId: team.asset.id, status: 'READY', thumbnailUrl: tiedThumbnailUrl, createdAt },
                    { id: clipId, assetId: team.asset.id, status: 'READY', thumbnailUrl, createdAt },
                ],
            });
            try {
                const owner = signedInActors.find(actor => actor.id === team.userId);
                const superAdmin = signedInActors.find(actor => actor.role === 'SUPER_ADMIN');
                const mine = await request(owner, 'GET', '/api/assets/mine');
                const owned = mine.json().assets.find(asset => asset.id === team.asset.id);
                expect(owned.clips).toHaveLength(1);
                expect(owned.clips[0]).toMatchObject({ id: clipId, thumbnailUrl });

                const active = await request(superAdmin, 'GET', '/api/admin/assets');
                const activeClips = active.json().assets.find(asset => asset.id === team.asset.id).clips;
                expect(activeClips.map(clip => clip.id)).toEqual([clipId, tiedClipId, team.asset.clipId]);
                expect(activeClips[0].thumbnailUrl).toBe(thumbnailUrl);
                expect(activeClips[1].thumbnailUrl).toBe(tiedThumbnailUrl);
                expect(activeClips[2].thumbnailUrl)
                    .toBe(`https://image.mux.com/${team.asset.playbackId}/thumbnail.png`);

                await prisma.asset.update({
                    where: { id: team.asset.id }, data: { mediaPlaybackReset: true },
                });
                const unavailable = await request(superAdmin, 'GET', '/api/admin/assets');
                const redacted = unavailable.json().assets.find(asset => asset.id === team.asset.id).clips;
                expect(redacted.map(clip => clip.thumbnailUrl)).toEqual([null, null, null]);
                expect(unavailable.body).not.toContain('matrix-latest-playback');
                expect(unavailable.body).not.toContain('matrix-tied-playback');
                expect(unavailable.body).not.toContain(team.asset.playbackId);
            } finally {
                await prisma.asset.update({
                    where: { id: team.asset.id }, data: { mediaPlaybackReset: false },
                });
                await prisma.clip.deleteMany({ where: { id: { in: [clipId, tiedClipId] } } });
            }
        });

        it.each(signedInActors.flatMap(actor => [
            { actor, moderation: 'ACTIVE', expectedStatus: 200 },
            { actor, moderation: 'PAUSED', expectedStatus: 200 },
            { actor, moderation: 'FLAGGED_FOR_REMOVAL', expectedStatus: 404 },
            { actor, moderation: 'REMOVED', expectedStatus: 404 },
        ]))('$actor.key transcript updates with $moderation moderation', async ({ actor, moderation, expectedStatus }) => {
            const asset = primaryAssets.find(item => item.userId === actor.id);
            await prisma.asset.update({ where: { id: asset.id }, data: { moderation } });
            try {
                const variants = [
                    { url: `/api/assets/${asset.id}/transcript` },
                    { url: `/api/assets/${asset.id}/transcript`, clipId: asset.clipId },
                    { url: `/api/assets/${asset.id}/clips/${asset.clipId}/transcript`, clipId: asset.clipId },
                ];
                for (const [index, variant] of variants.entries()) {
                    await prisma.clip.update({ where: { id: asset.clipId }, data: { transcript: 'Original' } });
                    const transcript = `Transcript ${index}`;
                    const response = await request(actor, 'PATCH', variant.url, {
                        transcript, ...(variant.clipId ? { clipId: variant.clipId } : {}),
                    });
                    expect(response.statusCode, response.body).toBe(expectedStatus);
                    expect((await prisma.clip.findUnique({ where: { id: asset.clipId } })).transcript)
                        .toBe(expectedStatus === 200 ? transcript : 'Original');
                }
            } finally {
                await prisma.clip.update({ where: { id: asset.clipId }, data: { transcript: null } });
                await prisma.asset.update({ where: { id: asset.id }, data: { moderation: 'ACTIVE' } });
            }
        });

        for (const team of teams) {
            it.each(['ACTIVE', 'PAUSED', 'FLAGGED_FOR_REMOVAL', 'REMOVED'])(
                `${team.key} non-owner transcript updates with %s moderation`,
                async moderation => {
                    await prisma.asset.update({ where: { id: team.asset.id }, data: { moderation } });
                    await prisma.clip.update({ where: { id: team.asset.clipId }, data: { transcript: 'Original' } });
                    try {
                        for (const actor of signedInActors.filter(item => item.id !== team.userId)) {
                            for (const url of [
                                `/api/assets/${team.asset.id}/transcript`,
                                `/api/assets/${team.asset.id}/clips/${team.asset.clipId}/transcript`,
                            ]) {
                                const response = await request(actor, 'PATCH', url, { transcript: 'Not allowed' });
                                expect(response.statusCode).toBe(404);
                            }
                        }
                        expect((await prisma.clip.findUnique({ where: { id: team.asset.clipId } })).transcript)
                            .toBe('Original');
                    } finally {
                        await prisma.clip.update({ where: { id: team.asset.clipId }, data: { transcript: null } });
                        await prisma.asset.update({ where: { id: team.asset.id }, data: { moderation: 'ACTIVE' } });
                    }
                },
            );
        }

        it.each([
            ['legacy', asset => `/api/assets/${asset.id}/transcript`, false],
            ['legacy with clip ID', asset => `/api/assets/${asset.id}/transcript`, true],
            ['clip-specific', asset => `/api/assets/${asset.id}/clips/${asset.clipId}/transcript`, true],
        ])('waits for a concurrent flag before accepting a %s transcript', async (_label, route, useClipId) => {
            const asset = teams[0].asset;
            const owner = signedInActors.find(actor => actor.id === asset.userId);
            const blocker = await pool.connect();
            let transactionOpen = false;
            let saving;
            try {
                await blocker.query('BEGIN');
                transactionOpen = true;
                await blocker.query(
                    "UPDATE assets SET moderation = 'FLAGGED_FOR_REMOVAL' WHERE id = $1",
                    [asset.id],
                );
                saving = request(owner, 'PATCH', route(asset), {
                    transcript: 'Must not be saved',
                    ...(useClipId ? { clipId: asset.clipId } : {}),
                });
                await waitForBlockedQuery(pool, 'SELECT id FROM assets');
                await blocker.query('COMMIT');
                transactionOpen = false;

                expect((await saving).statusCode).toBe(404);
                expect((await prisma.clip.findUnique({ where: { id: asset.clipId } })).transcript).toBeNull();
            } finally {
                if (transactionOpen) await blocker.query('ROLLBACK');
                blocker.release();
                if (saving) await saving;
                await prisma.asset.update({ where: { id: asset.id }, data: { moderation: 'ACTIVE' } });
                await prisma.clip.update({ where: { id: asset.clipId }, data: { transcript: null } });
            }
        });

        it('holds moderation until an already-authorized transcript write commits', async () => {
            const asset = teams[0].asset;
            const owner = signedInActors.find(actor => actor.id === asset.userId);
            const clipBlocker = await pool.connect();
            const moderator = await pool.connect();
            let transactionOpen = false;
            let saving;
            let flagging;
            try {
                await clipBlocker.query('BEGIN');
                transactionOpen = true;
                await clipBlocker.query('SELECT id FROM clips WHERE id = $1 FOR UPDATE', [asset.clipId]);
                saving = request(owner, 'PATCH', `/api/assets/${asset.id}/clips/${asset.clipId}/transcript`, {
                    transcript: 'Saved before the flag',
                });
                await waitForBlockedQuery(pool, 'UPDATE "public"."clips"');

                const pid = (await moderator.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
                flagging = moderator.query(
                    "UPDATE assets SET moderation = 'FLAGGED_FOR_REMOVAL' WHERE id = $1",
                    [asset.id],
                );
                await waitForBlockedQuery(pool, 'UPDATE assets SET moderation', pid);
                await clipBlocker.query('COMMIT');
                transactionOpen = false;

                expect((await saving).statusCode).toBe(200);
                await flagging;
                expect((await prisma.asset.findUnique({ where: { id: asset.id } })).moderation)
                    .toBe('FLAGGED_FOR_REMOVAL');
                expect((await prisma.clip.findUnique({ where: { id: asset.clipId } })).transcript)
                    .toBe('Saved before the flag');
            } finally {
                if (transactionOpen) await clipBlocker.query('ROLLBACK');
                clipBlocker.release();
                if (saving) await saving;
                if (flagging) await flagging;
                moderator.release();
                await prisma.asset.update({ where: { id: asset.id }, data: { moderation: 'ACTIVE' } });
                await prisma.clip.update({ where: { id: asset.clipId }, data: { transcript: null } });
            }
        });
    });

    it('rejects invalid credentials and suspended or deleted accounts', async () => {
        const invalid = await app.inject({
            method: 'GET', url: '/api/auth/me', headers: { authorization: 'Bearer invalid' },
        });
        const expiredToken = app.jwt.sign({ id: 'matrix-user-news', exp: Math.floor(Date.now() / 1000) - 60 });
        const expired = await app.inject({
            method: 'GET', url: '/api/auth/me', headers: { authorization: `Bearer ${expiredToken}` },
        });
        const missing = await request({ id: 'matrix-missing' }, 'GET', '/api/auth/me');
        expect(invalid.statusCode).toBe(401);
        expect(expired.statusCode).toBe(401);
        expect(missing.statusCode).toBe(401);

        await prisma.user.update({ where: { id: 'matrix-user-news' }, data: { status: 'SUSPENDED' } });
        try {
            const actor = actors[1];
            expect((await request(actor, 'GET', '/api/auth/me')).statusCode).toBe(403);
            expect((await request(actor, 'GET', `/clips/${teams[0].asset.mediasourceId}/status`,
                undefined, clipHeadersFor(actor))).statusCode).toBe(401);
        } finally {
            await prisma.user.update({ where: { id: 'matrix-user-news' }, data: { status: 'ACTIVE' } });
        }
    });
});
