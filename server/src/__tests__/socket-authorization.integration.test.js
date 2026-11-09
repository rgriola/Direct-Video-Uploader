import Fastify from 'fastify';
import fastifyJwt from '@fastify/jwt';
import { Server } from 'socket.io';
import { io as createClient } from 'socket.io-client';
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { requireRole } from '../lib/authorization.js';
import { acquireIntegrationDatabaseLock } from './helpers/database-lock.js';

vi.mock('../lib/mux.js', () => ({ isMuxEnabled: false, MUX_ENV_KEY: '' }));
vi.mock('../lib/slack.js', () => ({
    isConfigured: () => false,
    buildAssetMessage: vi.fn(),
    postToChannel: vi.fn(),
    postDM: vi.fn(),
}));

const databaseUrl = process.env.TEST_DATABASE_URL;
if (process.env.CI && !databaseUrl) {
    throw new Error('TEST_DATABASE_URL is required for socket authorization integration tests in CI');
}
if (databaseUrl) {
    const url = new URL(databaseUrl);
    if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
        || !url.pathname.slice(1).startsWith('dvu_scope_test_')
        || process.env.DATABASE_URL !== databaseUrl) {
        throw new Error('Socket authorization tests require a dedicated local dvu_scope_test_ database');
    }
}

const integration = databaseUrl ? describe : describe.skip;

integration('HTTP and Socket.IO authorization against PostgreSQL', () => {
    const users = [
        { id: 'socket-db-owner-news', role: 'USER', companyCode: 'NEWS', phoneNumber: '5582000001' },
        { id: 'socket-db-owner-sport', role: 'USER', companyCode: 'SPRT', phoneNumber: '5582000002' },
        { id: 'socket-db-admin-news', role: 'ADMIN', companyCode: 'NEWS', phoneNumber: '5582000003' },
        { id: 'socket-db-admin-sport', role: 'ADMIN', companyCode: 'SPRT', phoneNumber: '5582000004' },
        { id: 'socket-db-super-news', role: 'SUPER_ADMIN', companyCode: 'NEWS', phoneNumber: '5582000005' },
        { id: 'socket-db-super-sport', role: 'SUPER_ADMIN', companyCode: 'SPRT', phoneNumber: '5582000006' },
    ];
    const assetId = 'socket-db-asset-news';
    const clients = [];
    let app;
    let io;
    let prisma;
    let releaseDatabaseLock;
    let organizationsCreated = false;
    let usersCreated = false;
    let url;

    // Signed claims remain privileged even when the database role or team changes.
    function tokenFor(id) {
        return app.jwt.sign({ id, role: 'SUPER_ADMIN', companyCode: 'SPRT' });
    }

    function waitForEvent(socket, event) {
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                socket.off(event, onEvent);
                reject(new Error(`Timed out waiting for ${event}`));
            }, 3000);
            const onEvent = value => {
                clearTimeout(timer);
                resolve(value);
            };
            socket.once(event, onEvent);
        });
    }

    function makeClient(id, clientType = 'admin') {
        const client = createClient(url, {
            autoConnect: false,
            forceNew: true,
            reconnection: false,
            transports: ['websocket'],
            auth: { token: tokenFor(id), clientType },
        });
        clients.push(client);
        return client;
    }

    async function connect(id, clientType) {
        const client = makeClient(id, clientType);
        const connected = new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                client.off('connect_error', onError);
                reject(new Error(`Timed out connecting ${id}`));
            }, 3000);
            const onError = error => {
                clearTimeout(timer);
                reject(error);
            };
            client.once('connect', () => {
                clearTimeout(timer);
                client.off('connect_error', onError);
                resolve(client);
            });
            client.once('connect_error', onError);
        });
        client.connect();
        return connected;
    }

    function observe(socket, event) {
        const events = [];
        socket.on(event, (...args) => events.push(args));
        return events;
    }

    async function synchronize(sockets) {
        const barriers = sockets.map(socket => waitForEvent(socket, 'matrix:barrier'));
        io.emit('matrix:barrier');
        await Promise.all(barriers);
    }

    function request(id, method, requestUrl, payload) {
        return app.inject({
            method,
            url: requestUrl,
            headers: { authorization: `Bearer ${tokenFor(id)}` },
            payload,
        });
    }

    beforeAll(async () => {
        const database = await import('../lib/prisma.js');
        prisma = database.default;
        releaseDatabaseLock = await acquireIntegrationDatabaseLock(database.pool);
        const { authenticate } = await import('../lib/authentication.js');
        const { default: assetRoutes } = await import('../routes/assets.js');
        const { default: adminRoutes } = await import('../routes/admin.js');
        const { default: moderationRoutes } = await import('../routes/moderation.js');
        const { setupWebSocket } = await import('../ws/handler.js');

        await prisma.organization.createMany({
            data: [
                { companyCode: 'NEWS', companyName: 'News' },
                { companyCode: 'SPRT', companyName: 'Sport' },
            ],
        });
        organizationsCreated = true;
        await prisma.user.createMany({
            data: users.map(user => ({ ...user, name: user.id, pinHash: 'socket-integration-test' })),
        });
        usersCreated = true;
        await prisma.asset.create({
            data: {
                id: assetId, userId: 'socket-db-owner-news', mediasourceId: '930000001',
                mediasourceUrl: '/clips/930000001', status: 'READY', mediaSyncState: 'SYNCED',
            },
        });

        app = Fastify({ logger: false });
        await app.register(fastifyJwt, { secret: 'socket-matrix-only-jwt-secret' });
        app.decorate('authenticate', authenticate);
        app.decorate('requireRole', requireRole);
        io = new Server(app.server);
        app.decorate('io', io);
        setupWebSocket(io, app);
        await app.register(assetRoutes);
        await app.register(adminRoutes);
        await app.register(moderationRoutes);
        await app.listen({ host: '127.0.0.1', port: 0 });
        url = `http://127.0.0.1:${app.server.address().port}`;
    }, 30000);

    afterEach(() => {
        for (const client of clients.splice(0)) client.disconnect();
    });

    afterAll(async () => {
        try {
            for (const client of clients) client.disconnect();
            if (io) await new Promise(resolve => io.close(resolve));
            if (app) await app.close();
        } finally {
            if (prisma) {
                try {
                    if (releaseDatabaseLock) {
                        const userIds = users.map(user => user.id);
                        if (usersCreated) {
                            await prisma.auditLog.deleteMany({ where: { actorUserId: { in: userIds } } });
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
        }
    });

    it('keeps form payloads private, scopes refreshes, and disconnects paused users', async () => {
        const sockets = await Promise.all([
            connect('socket-db-owner-news', 'ios'),
            connect('socket-db-owner-news'),
            connect('socket-db-owner-sport'),
            connect('socket-db-admin-news'),
            connect('socket-db-admin-sport'),
            connect('socket-db-super-news'),
            connect('socket-db-super-sport'),
        ]);
        const forms = sockets.map(socket => observe(socket, 'form:confirmed'));
        const refreshes = sockets.map(socket => observe(socket, 'dashboard:asset-changed'));

        const submitted = await request('socket-db-owner-news', 'POST', `/api/assets/${assetId}/form`, {
            slug: 'socket-test', description: 'Private form details',
        });
        expect(submitted.statusCode, submitted.body).toBe(200);
        await synchronize(sockets);
        expect(forms.map(events => events.length)).toEqual([1, 1, 0, 0, 0, 0, 0]);
        expect(forms[0][0][0]).toMatchObject({ assetId, formDescription: 'Private form details' });
        expect(refreshes.map(events => events.length)).toEqual([0, 0, 0, 1, 0, 1, 1]);
        for (const index of [3, 5, 6]) expect(refreshes[index][0]).toEqual([]);

        const pauseAsset = await request('socket-db-admin-news', 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
            moderation: 'PAUSED',
        });
        expect(pauseAsset.statusCode, pauseAsset.body).toBe(200);
        const denied = await request('socket-db-owner-news', 'POST', `/api/assets/${assetId}/form`, {
            slug: 'denied', description: 'Must not be sent',
        });
        expect(denied.statusCode).toBe(409);
        await synchronize(sockets);
        expect(forms.map(events => events.length)).toEqual([1, 1, 0, 0, 0, 0, 0]);
        expect(refreshes.map(events => events.length)).toEqual([0, 0, 0, 1, 0, 1, 1]);

        const disconnects = sockets.slice(0, 2).map(socket => waitForEvent(socket, 'disconnect'));
        const pauseUser = await request('socket-db-admin-news', 'PATCH', '/api/admin/users/socket-db-owner-news/status', {
            status: 'SUSPENDED', reason: 'Socket authorization test',
        });
        expect(pauseUser.statusCode, pauseUser.body).toBe(200);
        expect(await Promise.all(disconnects)).toEqual(['io server disconnect', 'io server disconnect']);

        const suspendedClient = makeClient('socket-db-owner-news');
        const rejected = waitForEvent(suspendedClient, 'connect_error');
        suspendedClient.connect();
        expect((await rejected).message).toBe('Account unavailable');
        expect((await request('socket-db-owner-news', 'GET', '/api/assets/mine')).statusCode).toBe(403);
    });

    it('reconnects dashboard clients into the new team after an HTTP organization change', async () => {
        await prisma.user.update({ where: { id: 'socket-db-owner-news' }, data: { status: 'ACTIVE' } });
        await prisma.user.update({ where: { id: 'socket-db-admin-news' }, data: { companyCode: 'NEWS' } });
        const [dashboard, phone, superAdmin] = await Promise.all([
            connect('socket-db-admin-news'),
            connect('socket-db-admin-news', 'ios'),
            connect('socket-db-super-news'),
        ]);
        const refreshes = observe(dashboard, 'dashboard:asset-changed');
        const superRefreshes = observe(superAdmin, 'dashboard:asset-changed');

        const newsAsset = await request('socket-db-owner-news', 'POST', '/api/assets', { fileName: 'news.mov' });
        expect(newsAsset.statusCode, newsAsset.body).toBe(200);
        await synchronize([dashboard, phone, superAdmin]);
        expect(refreshes).toEqual([[]]);
        expect(superRefreshes).toEqual([[]]);

        const disconnected = waitForEvent(dashboard, 'disconnect');
        const moved = await request('socket-db-super-news', 'PATCH', '/api/admin/users/socket-db-admin-news', {
            companyCode: 'SPRT',
        });
        expect(moved.statusCode, moved.body).toBe(200);
        expect(await disconnected).toBe('io server disconnect');
        expect(phone.connected).toBe(true);

        const reconnected = waitForEvent(dashboard, 'connect');
        dashboard.connect();
        await reconnected;
        const rooms = io.sockets.sockets.get(dashboard.id).rooms;
        expect(rooms.has('team:NEWS')).toBe(false);
        expect(rooms.has('team:SPRT')).toBe(true);
        expect(rooms.has('super')).toBe(false);
        expect((await request('socket-db-admin-news', 'GET', `/api/assets/${newsAsset.json().asset.id}`)).statusCode)
            .toBe(404);

        const anotherNewsAsset = await request(
            'socket-db-owner-news', 'POST', '/api/assets', { fileName: 'another-news.mov' },
        );
        const sportAsset = await request('socket-db-owner-sport', 'POST', '/api/assets', { fileName: 'sport.mov' });
        expect(anotherNewsAsset.statusCode, anotherNewsAsset.body).toBe(200);
        expect(sportAsset.statusCode, sportAsset.body).toBe(200);
        expect((await request('socket-db-admin-news', 'GET', `/api/assets/${sportAsset.json().asset.id}`)).statusCode)
            .toBe(200);
        await synchronize([dashboard, phone, superAdmin]);
        expect(refreshes).toEqual([[], []]);
        expect(superRefreshes).toEqual([[], [], []]);
    });
});
