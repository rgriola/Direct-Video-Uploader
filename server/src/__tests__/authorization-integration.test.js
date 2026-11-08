import Fastify from 'fastify';
import cookie from '@fastify/cookie';
import fastifyJwt from '@fastify/jwt';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { requireRole } from '../lib/authorization.js';
import { acquireIntegrationDatabaseLock } from './helpers/database-lock.js';

const databaseUrl = process.env.TEST_DATABASE_URL;
if (process.env.CI && !databaseUrl) {
    throw new Error('TEST_DATABASE_URL is required for authorization tests in CI');
}
if (databaseUrl) {
    const url = new URL(databaseUrl);
    if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
        || !url.pathname.slice(1).startsWith('dvu_scope_test_')
        || process.env.DATABASE_URL !== databaseUrl) {
        throw new Error('Authorization integration tests require a dedicated local dvu_scope_test_ database');
    }
    process.env.MUX_TOKEN_ID = '';
    process.env.MUX_TOKEN_SECRET = '';
    process.env.MUX_ENV_KEY = '';
}

const integration = databaseUrl ? describe : describe.skip;

integration('organization authorization against PostgreSQL', () => {
    let app;
    let prisma;
    let releaseDatabaseLock;

    const users = [
        { id: 'scope-super', name: 'Super', phoneNumber: '5500000001', role: 'SUPER_ADMIN', companyCode: null },
        { id: 'scope-admin-news', name: 'News Admin', phoneNumber: '5500000002', role: 'ADMIN', companyCode: 'NEWS' },
        { id: 'scope-admin-sport', name: 'Sport Admin', phoneNumber: '5500000003', role: 'ADMIN', companyCode: 'SPRT' },
        { id: 'scope-admin-orphan', name: 'Unassigned Admin', phoneNumber: '5500000004', role: 'ADMIN', companyCode: null },
        { id: 'scope-user-news', name: 'News User', phoneNumber: '5500000005', role: 'USER', companyCode: 'NEWS' },
        { id: 'scope-user-sport', name: 'Sport User', phoneNumber: '5500000006', role: 'USER', companyCode: 'SPRT' },
        { id: 'scope-user-lower', name: 'Lowercase User', phoneNumber: '5500000007', role: 'USER', companyCode: 'news' },
        { id: 'scope-super-other', name: 'Other Super', phoneNumber: '5500000008', role: 'SUPER_ADMIN', companyCode: null },
    ];
    const assets = [
        { id: 'scope-asset-news', userId: 'scope-user-news', mediasourceId: '810000001' },
        { id: 'scope-asset-sport', userId: 'scope-user-sport', mediasourceId: '810000002' },
        { id: 'scope-asset-lower', userId: 'scope-user-lower', mediasourceId: '810000003' },
        { id: 'scope-asset-team', userId: 'scope-admin-news', mediasourceId: '810000004' },
        { id: 'scope-asset-orphan', userId: 'scope-admin-orphan', mediasourceId: '810000005' },
    ];
    const userIds = users.map(user => user.id);
    const companyCodes = ['NEWS', 'SPRT', 'news'];
    const createdPhone = '5500000099';

    function requestAs(userId, method, url, payload) {
        return app.inject({
            method,
            url,
            headers: userId ? { 'x-test-user': userId } : {},
            ...(payload === undefined ? {} : { payload }),
        });
    }

    function clipCookie(userId, claims = {}) {
        const token = app.jwt.sign({ id: userId, ...claims });
        return `fixer_clip_token=${token}`;
    }

    beforeAll(async () => {
        const database = await import('../lib/prisma.js');
        prisma = database.default;
        releaseDatabaseLock = await acquireIntegrationDatabaseLock(database.pool);
        const { default: adminRoutes } = await import('../routes/admin.js');
        const { default: assetRoutes } = await import('../routes/assets.js');
        const { default: clipRoutes } = await import('../routes/clips.js');
        const { default: errorRoutes } = await import('../routes/errors.js');

        await prisma.organization.createMany({
            data: [
                { companyCode: 'NEWS', companyName: 'News' },
                { companyCode: 'SPRT', companyName: 'Sport' },
                { companyCode: 'news', companyName: 'Other News' },
            ],
        });
        await prisma.user.createMany({
            data: users.map(user => ({ ...user, pinHash: 'integration-test' })),
        });
        await prisma.asset.createMany({
            data: assets.map(asset => ({
                ...asset,
                mediasourceUrl: `/clips/${asset.mediasourceId}`,
                status: 'READY',
            })),
        });
        await prisma.clip.createMany({
            data: assets.map((asset, index) => ({
                id: `scope-clip-${index}`,
                assetId: asset.id,
                clipIndex: 0,
                status: 'READY',
                muxPlaybackId: `scope-playback-${index}`,
            })),
        });
        await prisma.chatMessage.createMany({
            data: ['news', 'sport', 'lower'].map(name => ({
                id: `scope-message-${name}`,
                userId: `scope-user-${name}`,
                assetId: `scope-asset-${name}`,
                direction: 'OUTGOING',
                messageType: 'TEXT',
                content: { text: `${name} message` },
            })),
        });

        app = Fastify({ logger: false });
        await app.register(cookie);
        await app.register(fastifyJwt, { secret: 'integration-only-jwt-secret' });
        app.decorate('csrfProtection', async () => {});
        app.decorate('authenticate', async (request, reply) => {
            const id = request.headers['x-test-user'];
            const user = id && await prisma.user.findUnique({ where: { id } });
            if (!user || user.status !== 'ACTIVE') {
                return reply.status(401).send({ error: 'Unauthorized' });
            }
            request.user = { ...user, sub: user.id };
        });
        app.decorate('requireRole', requireRole);
        app.decorate('io', {
            of: () => ({ sockets: new Map() }),
            to: () => ({ emit: () => {} }),
        });
        app.decorate('userSockets', new Map([
            ['scope-user-news', new Set(['news-ios'])],
            ['scope-admin-news', new Set(['news-admin'])],
            ['scope-user-sport', new Set(['sport-ios'])],
        ]));
        app.decorate('iosSockets', new Set(['news-ios', 'sport-ios']));
        app.decorate('adminSockets', new Set(['news-admin']));
        await app.register(adminRoutes);
        await app.register(assetRoutes);
        await app.register(clipRoutes);
        await app.register(errorRoutes);
    });

    afterAll(async () => {
        if (app) await app.close();
        if (prisma) {
            try {
                await prisma.chatMessage.deleteMany({ where: { userId: { in: userIds } } });
                await prisma.asset.deleteMany({ where: { userId: { in: userIds } } });
                await prisma.user.deleteMany({ where: { OR: [{ id: { in: userIds } }, { phoneNumber: createdPhone }] } });
                await prisma.organization.deleteMany({ where: { companyCode: { in: companyCodes } } });
            } finally {
                await releaseDatabaseLock?.();
                await prisma.$disconnect();
            }
        }
    });

    it.each([
        ['scope-super', userIds, assets.map(asset => asset.id), 3, 2, 3],
        ['scope-admin-news', ['scope-admin-news', 'scope-user-news'], ['scope-asset-news', 'scope-asset-team'], 1, 1, 2],
        ['scope-admin-sport', ['scope-admin-sport', 'scope-user-sport'], ['scope-asset-sport'], 1, 1, 1],
        ['scope-user-news', ['scope-user-news'], ['scope-asset-news'], 1, 1, 1],
        ['scope-user-sport', ['scope-user-sport'], ['scope-asset-sport'], 1, 1, 1],
        ['scope-admin-orphan', ['scope-admin-orphan'], ['scope-asset-orphan'], 0, 0, 0],
    ])('scopes lists and statistics for %s', async (actor, expectedUsers, expectedAssets, messages, iosClients, wsConnections) => {
        const userResponse = await requestAs(actor, 'GET', '/api/admin/users');
        const assetResponse = await requestAs(actor, 'GET', '/api/admin/assets');
        const messageResponse = await requestAs(actor, 'GET', '/api/admin/messages');
        const statsResponse = await requestAs(actor, 'GET', '/api/admin/stats');

        expect(userResponse.statusCode).toBe(200);
        expect(assetResponse.statusCode).toBe(200);
        expect(messageResponse.statusCode).toBe(200);
        expect(statsResponse.statusCode).toBe(200);
        expect(userResponse.json().users.map(user => user.id).sort()).toEqual([...expectedUsers].sort());
        expect(assetResponse.json().assets.map(asset => asset.id).sort()).toEqual([...expectedAssets].sort());
        expect(messageResponse.json().messages).toHaveLength(messages);
        expect(statsResponse.json()).toMatchObject({
            users: expectedUsers.length,
            assets: expectedAssets.length,
            messages,
            iosClients,
            wsConnections,
            onlineUsers: iosClients,
        });
    });

    it('reports playback availability to every role without exposing operation details', async () => {
        const id = 'scope-asset-news';
        const actors = ['scope-super', 'scope-admin-news', 'scope-user-news'];
        const readAsset = async (actor, moderation) => {
            const query = moderation ? `?moderation=${moderation}` : '';
            const response = await requestAs(actor, 'GET', `/api/admin/assets${query}`);
            expect(response.statusCode).toBe(200);
            const asset = response.json().assets.find(item => item.id === id);
            expect(asset).toBeDefined();
            return asset;
        };

        try {
            for (const actor of actors) {
                expect((await readAsset(actor)).mediaPlaybackUnavailable).toBe(false);
            }

            await prisma.asset.update({ where: { id }, data: { mediaPlaybackReset: true } });
            for (const actor of actors) {
                expect((await readAsset(actor)).mediaPlaybackUnavailable).toBe(true);
            }

            await prisma.asset.update({
                where: { id },
                data: {
                    mediaPlaybackReset: false,
                    mediaCreateOperationId: 'scope-operation',
                    mediaCreateMuxAssetId: 'scope-mux-asset',
                    mediaCreateStartedAt: new Date(),
                },
            });
            for (const actor of actors) {
                const asset = await readAsset(actor);
                expect(asset.mediaPlaybackUnavailable).toBe(true);
                expect(asset.mediaCreateOperationId).toBe(actor === 'scope-super' ? 'scope-operation' : null);
                expect(asset.mediaCreateMuxAssetId).toBe(actor === 'scope-super' ? 'scope-mux-asset' : null);
            }

            await prisma.asset.update({
                where: { id },
                data: {
                    moderation: 'PAUSED',
                    mediaCreateOperationId: null,
                    mediaCreateMuxAssetId: null,
                    mediaCreateStartedAt: null,
                },
            });
            for (const actor of actors) {
                expect((await readAsset(actor, 'PAUSED')).mediaPlaybackUnavailable).toBe(true);
            }
        } finally {
            await prisma.asset.update({
                where: { id },
                data: {
                    moderation: 'ACTIVE',
                    mediaPlaybackReset: false,
                    mediaCreateOperationId: null,
                    mediaCreateMuxAssetId: null,
                    mediaCreateStartedAt: null,
                },
            });
        }
    });

    it('requires authentication and scopes asset details to the owner or their admin', async () => {
        expect((await requestAs(null, 'GET', '/api/admin/users')).statusCode).toBe(401);
        expect((await requestAs('scope-user-news', 'GET', '/api/assets/scope-asset-news')).statusCode).toBe(200);
        expect((await requestAs('scope-user-news', 'GET', '/api/assets/scope-asset-team')).statusCode).toBe(404);
        expect((await requestAs('scope-admin-news', 'GET', '/api/assets/scope-asset-team')).statusCode).toBe(200);
        expect((await requestAs('scope-admin-news', 'GET', '/api/assets/scope-asset-sport')).statusCode).toBe(404);
        expect((await requestAs('scope-admin-news', 'GET', '/api/assets/scope-asset-lower')).statusCode).toBe(404);
        expect((await requestAs('scope-super', 'GET', '/api/assets/scope-asset-sport')).statusCode).toBe(200);
        expect((await requestAs('scope-admin-orphan', 'GET', '/api/assets/scope-asset-orphan')).statusCode).toBe(200);
        expect((await requestAs('scope-admin-orphan', 'GET', '/api/assets/scope-asset-news')).statusCode).toBe(404);
    });

    it('preserves same-organization shared clip viewing without cross-organization access', async () => {
        const newsCookie = clipCookie('scope-user-news');
        const teamCookie = clipCookie('scope-admin-news');
        const superCookie = clipCookie('scope-super');
        const status = (id, value) => app.inject({
            method: 'GET', url: `/clips/${id}/status`, headers: { cookie: value },
        });

        expect((await status('810000004', newsCookie)).statusCode).toBe(200);
        expect((await status('810000002', newsCookie)).statusCode).toBe(404);
        expect((await status('810000003', teamCookie)).statusCode).toBe(404);
        expect((await status('810000002', teamCookie)).statusCode).toBe(404);
        expect((await status('810000002', superCookie)).statusCode).toBe(200);

        const sharedPage = await app.inject({
            method: 'GET', url: '/clips/810000004', headers: { cookie: newsCookie },
        });
        const foreignPage = await app.inject({
            method: 'GET', url: '/clips/810000002', headers: { cookie: teamCookie },
        });
        expect(sharedPage.statusCode).toBe(200);
        expect(sharedPage.body).toContain('scope-playback-3');
        expect(foreignPage.statusCode).toBe(404);
        expect(foreignPage.body).not.toContain('scope-playback-1');
    });

    it('uses the current account role and status instead of stale clip-cookie claims', async () => {
        const staleCookie = clipCookie('scope-admin-news', { role: 'SUPER_ADMIN', companyCode: 'SPRT' });
        const denied = await app.inject({
            method: 'GET', url: '/clips/810000002/status', headers: { cookie: staleCookie },
        });
        expect(denied.statusCode).toBe(404);

        await prisma.user.update({ where: { id: 'scope-admin-news' }, data: { status: 'SUSPENDED' } });
        try {
            const suspended = await app.inject({
                method: 'GET', url: '/clips/810000004/status', headers: { cookie: staleCookie },
            });
            expect(suspended.statusCode).toBe(401);
        } finally {
            await prisma.user.update({ where: { id: 'scope-admin-news' }, data: { status: 'ACTIVE' } });
        }
    });

    it('limits transcript writes to the asset owner', async () => {
        const body = { transcript: 'A transcript' };
        expect((await requestAs('scope-admin-news', 'PATCH', '/api/assets/scope-asset-news/transcript', body)).statusCode).toBe(404);
        expect((await requestAs('scope-user-sport', 'PATCH', '/api/assets/scope-asset-news/transcript', body)).statusCode).toBe(404);
        expect((await requestAs('scope-user-news', 'PATCH', '/api/assets/scope-asset-news/transcript', body)).statusCode).toBe(200);
        expect((await prisma.clip.findUnique({ where: { id: 'scope-clip-0' } })).transcript).toBe('A transcript');
    });

    it('updates only the specified owned clip and rejects replaced or foreign clips', async () => {
        const url = '/api/assets/scope-asset-news/clips/scope-clip-0/transcript';
        const body = { transcript: 'Original clip transcript', clipId: 'scope-clip-0', segments: [] };
        expect((await requestAs('scope-admin-news', 'PATCH', url, body)).statusCode).toBe(404);
        expect((await requestAs('scope-user-news', 'PATCH', url, body)).statusCode).toBe(200);
        expect((await prisma.clip.findUnique({ where: { id: 'scope-clip-0' } })).transcript)
            .toBe('Original clip transcript');

        const foreignClip = { ...body, clipId: 'scope-clip-1', transcript: 'must not be saved' };
        const replacedClip = { ...body, clipId: 'scope-clip-replaced', transcript: 'must not be saved' };
        expect((await requestAs('scope-user-news', 'PATCH', url, foreignClip)).statusCode).toBe(400);
        expect((await requestAs(
            'scope-user-news', 'PATCH',
            '/api/assets/scope-asset-news/clips/scope-clip-1/transcript', foreignClip,
        )).statusCode).toBe(404);
        expect((await requestAs(
            'scope-user-news', 'PATCH',
            '/api/assets/scope-asset-news/clips/scope-clip-replaced/transcript', replacedClip,
        )).statusCode).toBe(404);
        expect((await prisma.clip.findUnique({ where: { id: 'scope-clip-1' } })).transcript).toBeNull();
        expect((await prisma.clip.findUnique({ where: { id: 'scope-clip-0' } })).transcript)
            .toBe('Original clip transcript');
        const noBodyClip = await requestAs(
            'scope-user-news', 'PATCH', url, { transcript: 'Path clip transcript' },
        );
        expect(noBodyClip.statusCode).toBe(200);
        expect(noBodyClip.json().clipId).toBe('scope-clip-0');
        expect((await prisma.clip.findUnique({ where: { id: 'scope-clip-0' } })).transcript)
            .toBe('Path clip transcript');
    });

    it('never sends an old clip transcript to its replacement', async () => {
        const assetId = 'scope-replacement-asset';
        const oldClipId = 'scope-replacement-old';
        const replacementId = 'scope-replacement-new';
        await prisma.asset.create({
            data: {
                id: assetId,
                userId: 'scope-user-news',
                mediasourceId: '810000099',
                mediasourceUrl: '/clips/810000099',
                status: 'UPLOADING',
            },
        });
        try {
            await prisma.clip.create({
                data: { id: oldClipId, assetId, clipIndex: 0, status: 'UPLOADING' },
            });
            await prisma.clip.delete({ where: { id: oldClipId } });
            await prisma.clip.create({
                data: { id: replacementId, assetId, clipIndex: 0, status: 'UPLOADING' },
            });

            const response = await requestAs(
                'scope-user-news', 'PATCH',
                `/api/assets/${assetId}/clips/${oldClipId}/transcript`,
                { transcript: 'Old clip transcript', clipId: oldClipId },
            );
            expect(response.statusCode).toBe(404);
            expect((await prisma.clip.findUnique({ where: { id: replacementId } })).transcript)
                .toBeNull();

            const legacy = await requestAs(
                'scope-user-news', 'PATCH', `/api/assets/${assetId}/transcript`,
                { transcript: 'Legacy clip transcript' },
            );
            expect(legacy.statusCode).toBe(200);
            expect(legacy.json().clipId).toBe(replacementId);
            expect((await prisma.clip.findUnique({ where: { id: replacementId } })).transcript)
                .toBe('Legacy clip transcript');
        } finally {
            await prisma.asset.delete({ where: { id: assetId } });
        }
    });

    it('restricts global and destructive operations to the Super Admin', async () => {
        for (const actor of ['scope-user-news', 'scope-admin-news', 'scope-admin-orphan']) {
            for (const [method, url] of [
                ['GET', '/api/admin/status'],
                ['GET', '/api/admin/errors'],
                ['POST', '/api/admin/cleanup-assets'],
                ['POST', '/api/admin/nuclear-reset'],
                ['DELETE', '/api/admin/users/scope-user-sport'],
                ['POST', '/api/admin/organizations'],
                ['PUT', '/api/admin/organizations/SPRT'],
                ['DELETE', '/api/admin/organizations/SPRT'],
            ]) {
                expect((await requestAs(actor, method, url, method === 'POST' || method === 'PUT' ? {} : undefined)).statusCode).toBe(403);
            }
        }
        expect((await requestAs('scope-super', 'GET', '/api/admin/status')).statusCode).toBe(200);
        expect((await requestAs('scope-super', 'GET', '/api/admin/errors')).statusCode).toBe(200);
        expect((await requestAs('scope-admin-orphan', 'GET', '/api/admin/organizations')).statusCode).toBe(403);
        const orgs = await requestAs('scope-admin-news', 'GET', '/api/admin/organizations');
        expect(orgs.json().organizations.map(org => org.companyCode)).toEqual(['NEWS']);
        expect((await requestAs('scope-super', 'POST', '/api/admin/cleanup-assets', {})).statusCode).toBe(200);
        expect((await requestAs('scope-super', 'DELETE', '/api/admin/users/scope-super')).statusCode).toBe(400);
        expect((await requestAs('scope-super', 'DELETE', '/api/admin/users/scope-super-other')).statusCode).toBe(403);
        expect(await prisma.user.findUnique({ where: { id: 'scope-user-sport' } })).not.toBeNull();
    });

    it('allows a Super Admin to move an ordinary user while preserving team scope', async () => {
        const removeOrg = await requestAs('scope-super', 'PATCH', '/api/admin/users/scope-user-news', { companyCode: null });
        expect(removeOrg.statusCode).toBe(200);
        try {
            expect((await requestAs('scope-admin-news', 'PATCH', '/api/admin/users/scope-user-news', { name: 'Changed' })).statusCode).toBe(404);
        } finally {
            const restoreOrg = await requestAs('scope-super', 'PATCH', '/api/admin/users/scope-user-news', { companyCode: 'NEWS' });
            expect(restoreOrg.statusCode).toBe(200);
        }
    });

    it('prevents cross-organization user changes and assigns new members to the admin organization', async () => {
        expect((await requestAs('scope-admin-orphan', 'POST', '/api/admin/users', { name: 'New', phoneNumber: createdPhone })).statusCode).toBe(403);
        expect((await requestAs('scope-admin-news', 'PATCH', '/api/admin/users/scope-user-sport', { name: 'Changed' })).statusCode).toBe(404);
        expect((await requestAs('scope-admin-news', 'PATCH', '/api/admin/users/scope-user-news', { companyCode: 'SPRT' })).statusCode).toBe(403);
        expect((await requestAs('scope-admin-news', 'PATCH', '/api/admin/users/scope-user-lower/role', { role: 'ADMIN' })).statusCode).toBe(404);
        expect((await requestAs('scope-admin-news', 'POST', '/api/admin/users', {
            name: 'New', phoneNumber: createdPhone, companyCode: 'SPRT',
        })).statusCode).toBe(403);

        const created = await requestAs('scope-admin-news', 'POST', '/api/admin/users', {
            name: 'New', phoneNumber: createdPhone,
        });
        expect(created.statusCode).toBe(200);
        expect(created.json().user.companyCode).toBe('NEWS');
        expect((await prisma.user.findUnique({ where: { phoneNumber: createdPhone } })).companyCode).toBe('NEWS');

        expect((await requestAs('scope-admin-news', 'PATCH', '/api/admin/users/scope-user-news/role', { role: 'ADMIN' })).statusCode).toBe(200);
        expect((await requestAs('scope-admin-news', 'PATCH', '/api/admin/users/scope-user-news/role', { role: 'USER' })).statusCode).toBe(200);
        expect((await requestAs('scope-super', 'PATCH', '/api/admin/users/scope-user-news/role', { role: 'SUPER_ADMIN' })).statusCode).toBe(400);
        expect((await prisma.user.findUnique({ where: { id: 'scope-user-news' } })).role).toBe('USER');
    });
});
