import { createServer } from 'node:http';
import { Server } from 'socket.io';
import { io as createClient } from 'socket.io-client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
    users: new Map(),
    assets: new Map(),
}));

vi.mock('../lib/prisma.js', () => ({
    default: {
        user: {
            findUnique: vi.fn(async ({ where }) => {
                const user = state.users.get(where.id);
                return user ? { ...user } : null;
            }),
            findMany: vi.fn(async ({ where }) => [...state.users.values()]
                .filter(user => where.id.in.includes(user.id)
                    && user.status === where.status
                    && where.OR.some(rule => Object.entries(rule).every(([key, value]) => user[key] === value)))
                .map(user => ({ id: user.id }))),
        },
        asset: {
            findUnique: vi.fn(async ({ where }) => {
                const asset = state.assets.get(where.id);
                if (!asset) return null;
                const user = state.users.get(asset.userId);
                return { ...asset, user: user ? { companyCode: user.companyCode } : null };
            }),
            findFirst: vi.fn(async ({ where }) => {
                const asset = state.assets.get(where.id);
                return asset && asset.userId === where.userId && asset.moderation === where.moderation
                    ? { id: asset.id }
                    : null;
            }),
        },
        chatMessage: { create: vi.fn(async ({ data }) => data) },
    },
}));

vi.mock('../lib/slack.js', () => ({
    isConfigured: vi.fn(() => false),
    buildAssetMessage: vi.fn(),
    postToChannel: vi.fn(),
    postDM: vi.fn(),
}));
vi.mock('../lib/config.js', () => ({ PUBLIC_URL: 'https://example.test' }));

import prisma from '../lib/prisma.js';
import * as slack from '../lib/slack.js';
import { notifyUserSockets } from '../lib/utils.js';
import { notifyDashboardAssetChange } from '../ws/dashboard-notifications.js';
import { setupWebSocket } from '../ws/handler.js';
import { invalidateUserSockets } from '../ws/rooms.js';

let server;
let io;
let fastify;
let url;
let clients;

function addUser(id, role, companyCode, status = 'ACTIVE') {
    state.users.set(id, { id, name: id, phoneNumber: '5550000000', role, companyCode, status });
}

function connectSocket(userId, clientType = 'admin', { headerOnly = false } = {}) {
    const socket = createClient(url, {
        autoConnect: false,
        forceNew: true,
        reconnection: false,
        timeout: 3000,
        transports: ['polling', 'websocket'],
        extraHeaders: { authorization: `Bearer ${userId}` },
        auth: headerOnly ? { clientType } : { token: userId, clientType },
    });
    clients.push(socket);
    const connected = new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            socket.off('connect_error', onError);
            reject(new Error(`Timed out connecting ${userId}`));
        }, 1500);
        const onError = error => {
            clearTimeout(timer);
            reject(error);
        };
        socket.once('connect', () => {
            clearTimeout(timer);
            socket.off('connect_error', onError);
            resolve(socket);
        });
        socket.once('connect_error', onError);
    });
    socket.connect();
    return connected;
}

function observe(socket, event) {
    const calls = [];
    socket.on(event, (...args) => calls.push(args));
    return calls;
}

async function flush(sockets) {
    const pending = sockets.map(socket => waitForEvent(socket, 'test:barrier'));
    io.emit('test:barrier');
    await Promise.all(pending);
}

function waitForEvent(socket, event) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            socket.off(event, onEvent);
            reject(new Error(`Timed out waiting for ${event}`));
        }, 1500);
        const onEvent = value => {
            clearTimeout(timer);
            resolve(value);
        };
        socket.once(event, onEvent);
    });
}

beforeEach(async () => {
    state.users.clear();
    state.assets.clear();
    vi.clearAllMocks();
    clients = [];

    addUser('owner-news', 'USER', 'NEWS');
    addUser('owner-sport', 'USER', 'SPRT');
    addUser('owner-unassigned', 'USER', null);
    addUser('admin-news', 'ADMIN', 'NEWS');
    addUser('admin-sport', 'ADMIN', 'SPRT');
    addUser('admin-lower', 'ADMIN', 'news');
    addUser('admin-unassigned', 'ADMIN', null);
    addUser('super', 'SUPER_ADMIN', null);
    addUser('super-news', 'SUPER_ADMIN', 'NEWS');
    addUser('super-sport', 'SUPER_ADMIN', 'SPRT');
    state.assets.set('asset-news', { id: 'asset-news', userId: 'owner-news', moderation: 'ACTIVE' });
    state.assets.set('asset-sport', { id: 'asset-sport', userId: 'owner-sport', moderation: 'ACTIVE' });
    state.assets.set('asset-unassigned', { id: 'asset-unassigned', userId: 'owner-unassigned', moderation: 'ACTIVE' });

    server = createServer();
    io = new Server(server);
    fastify = {
        io,
        log: { info: vi.fn(), warn: vi.fn(), error: vi.fn(), debug: vi.fn() },
        jwt: {
            verify: vi.fn(token => {
                if (token === 'invalid') throw new Error('invalid token');
                return { id: token, role: 'SUPER_ADMIN', companyCode: 'SPRT' };
            }),
        },
        decorate(name, value) { this[name] = value; },
    };
    setupWebSocket(io, fastify);
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    url = `http://127.0.0.1:${server.address().port}`;
});

afterEach(async () => {
    for (const socket of clients) socket.disconnect();
    await new Promise(resolve => io.close(resolve));
});

describe('Socket.IO scoped delivery', () => {
    it('sends private events to every owner device and payload-free refreshes to the authorized team and super admin', async () => {
        const [
            ownerPhone, ownerDashboard, otherOwner, teamAdmin, otherAdmin,
            lowerAdmin, orphanAdmin, superAdmin, teamAdminPhone, superNews, superSport,
        ] = await Promise.all([
            connectSocket('owner-news', 'ios', { headerOnly: true }),
            connectSocket('owner-news', 'admin'),
            connectSocket('owner-sport', 'ios'),
            connectSocket('admin-news'),
            connectSocket('admin-sport'),
            connectSocket('admin-lower'),
            connectSocket('admin-unassigned'),
            connectSocket('super'),
            connectSocket('admin-news', 'ios'),
            connectSocket('super-news'),
            connectSocket('super-sport'),
        ]);
        const sockets = [
            ownerPhone, ownerDashboard, otherOwner, teamAdmin, otherAdmin,
            lowerAdmin, orphanAdmin, superAdmin, teamAdminPhone, superNews, superSport,
        ];
        const uploads = sockets.map(socket => observe(socket, 'upload:complete'));
        const forms = sockets.map(socket => observe(socket, 'form:request'));
        const refreshes = sockets.map(socket => observe(socket, 'dashboard:asset-changed'));

        notifyUserSockets(io, 'owner-news', {
            assetId: 'asset-news',
            asset: { mediasourceId: '123', mediasourceUrl: '/clips/123', originalFileName: 'video.mov' },
            userName: 'Reporter',
            metadata: { gpsLat: 35, codec: 'H264', deviceModel: 'Phone', duration: 10 },
            clip: { id: 'clip-1', fileSize: '100' },
        });
        await notifyDashboardAssetChange(fastify, 'asset-news');
        await flush(sockets);

        expect(uploads.map(events => events.length)).toEqual([1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        expect(forms.map(events => events.length)).toEqual([1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        expect(refreshes.map(events => events.length)).toEqual([0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1]);
        expect(refreshes[3][0]).toEqual([]);
        expect(refreshes[7][0]).toEqual([]);
        expect(refreshes[9][0]).toEqual([]);
        expect(refreshes[10][0]).toEqual([]);
        expect(uploads[0][0][0].metadata.gpsLat).toBe(35);
        expect(io.sockets.sockets.get(ownerDashboard.id).rooms.has('super')).toBe(false);
        expect(io.sockets.sockets.get(teamAdmin.id).rooms.has('team:NEWS')).toBe(true);
        expect(io.sockets.sockets.get(teamAdminPhone.id).rooms.has('team:NEWS')).toBe(false);
        expect(io.sockets.sockets.get(superAdmin.id).rooms.has('super')).toBe(true);
    });

    it('rechecks stale roles and teams, then rejoins the new scope without disconnecting the iOS device', async () => {
        const [dashboard, phone, superAdmin] = await Promise.all([
            connectSocket('admin-news'),
            connectSocket('admin-news', 'ios'),
            connectSocket('super'),
        ]);
        const dashboardEvents = observe(dashboard, 'dashboard:asset-changed');
        const superEvents = observe(superAdmin, 'dashboard:asset-changed');

        state.users.get('admin-news').role = 'USER';
        await notifyDashboardAssetChange(fastify, 'asset-news');
        await flush([dashboard, phone, superAdmin]);
        expect(dashboardEvents).toHaveLength(0);
        expect(superEvents).toHaveLength(1);

        state.users.get('admin-news').role = 'ADMIN';
        state.users.get('admin-news').companyCode = 'SPRT';
        await notifyDashboardAssetChange(fastify, 'asset-news');
        await flush([dashboard, phone, superAdmin]);
        expect(dashboardEvents).toHaveLength(0);

        const disconnected = waitForEvent(dashboard, 'disconnect');
        invalidateUserSockets(fastify, ['admin-news'], { dashboardOnly: true });
        expect(await disconnected).toBe('io server disconnect');
        expect(phone.connected).toBe(true);
        const reconnected = waitForEvent(dashboard, 'connect');
        dashboard.connect();
        await reconnected;
        expect(io.sockets.sockets.get(dashboard.id).rooms.has('team:SPRT')).toBe(true);
        expect(io.sockets.sockets.get(dashboard.id).rooms.has('team:NEWS')).toBe(false);

        await notifyDashboardAssetChange(fastify, 'asset-sport');
        await flush([dashboard, phone, superAdmin]);
        expect(dashboardEvents).toHaveLength(1);

        state.users.get('admin-news').status = 'SUSPENDED';
        const dashboardClosed = waitForEvent(dashboard, 'disconnect');
        const phoneClosed = waitForEvent(phone, 'disconnect');
        invalidateUserSockets(fastify, ['admin-news']);
        await Promise.all([dashboardClosed, phoneClosed]);
        await expect(connectSocket('admin-news')).rejects.toThrow('Account unavailable');
    });

    it.each([
        ['news', 'asset-news', 'admin-news', 'admin-sport'],
        ['sport', 'asset-sport', 'admin-sport', 'admin-news'],
    ].flatMap(([team, assetId, ownAdmin, otherAdmin]) =>
        ['PAUSED', 'FLAGGED_FOR_REMOVAL', 'REMOVED'].map(moderation =>
            ({ team, assetId, ownAdmin, otherAdmin, moderation }))))(
        'skips $team assets in $moderation while limiting unassigned refreshes to super admins',
        async ({ assetId, ownAdmin, otherAdmin, moderation }) => {
            const sockets = await Promise.all([
                connectSocket(ownAdmin),
                connectSocket(otherAdmin),
                connectSocket('admin-unassigned'),
                connectSocket('super-news'),
                connectSocket('super-sport'),
            ]);
            const refreshes = sockets.map(socket => observe(socket, 'dashboard:asset-changed'));

            await notifyDashboardAssetChange(fastify, 'asset-unassigned');
            state.assets.get(assetId).moderation = moderation;
            await notifyDashboardAssetChange(fastify, assetId);
            await flush(sockets);

            expect(refreshes.map(events => events.length)).toEqual([0, 0, 0, 1, 1]);
            expect(refreshes[3][0]).toEqual([]);
            expect(refreshes[4][0]).toEqual([]);
        },
    );

    it('fails closed and logs when current dashboard authorization cannot be checked', async () => {
        const [teamAdmin, superAdmin] = await Promise.all([connectSocket('admin-news'), connectSocket('super')]);
        const teamEvents = observe(teamAdmin, 'dashboard:asset-changed');
        const superEvents = observe(superAdmin, 'dashboard:asset-changed');
        prisma.user.findMany.mockRejectedValueOnce(new Error('database offline'));

        await notifyDashboardAssetChange(fastify, 'asset-news');
        await flush([teamAdmin, superAdmin]);

        expect(teamEvents).toHaveLength(0);
        expect(superEvents).toHaveLength(0);
        expect(fastify.log.error).toHaveBeenCalledWith(
            expect.objectContaining({ err: { message: 'database offline' }, assetId: 'asset-news' }),
            'Could not notify dashboards of asset change'
        );
    });

    it.each([
        'owner-news', 'owner-sport', 'admin-news', 'admin-sport',
        'admin-unassigned', 'super-news', 'super-sport',
    ])('keeps %s upload progress on the initiating socket', async actor => {
        const otherActor = actor === 'owner-news' ? 'owner-sport' : 'owner-news';
        const [sender, sameUser, otherUser] = await Promise.all([
            connectSocket(actor), connectSocket(actor), connectSocket(otherActor),
        ]);
        const sameUserEvents = observe(sameUser, 'upload:progress');
        const otherUserEvents = observe(otherUser, 'upload:progress');

        for (const assetId of ['asset-news', 'asset-sport']) {
            const progress = waitForEvent(sender, 'upload:progress');
            sender.emit('video:upload', { assetId });
            expect(await progress).toEqual({ assetId, percent: 0, status: 'uploading' });
        }
        await flush([sender, sameUser, otherUser]);
        expect(sameUserEvents).toHaveLength(0);
        expect(otherUserEvents).toHaveLength(0);
    });

    it.each([
        ['owner-news', 'asset-sport'],
        ['owner-sport', 'asset-news'],
        ['owner-unassigned', 'asset-news'],
        ['admin-news', 'asset-news'],
        ['admin-sport', 'asset-sport'],
        ['admin-unassigned', 'asset-news'],
        ['super', 'asset-news'],
        ['super-news', 'asset-news'],
        ['super-sport', 'asset-sport'],
    ])('allows %s to send messages only for owned active assets', async (actor, foreignAssetId) => {
        const socket = await connectSocket(actor);
        const ownAssetId = 'matrix-owned-asset';
        state.assets.set(ownAssetId, { id: ownAssetId, userId: actor, moderation: 'ACTIVE' });

        const accepted = waitForEvent(socket, 'message:new');
        socket.emit('message:send', { text: '#news share this', assetId: ownAssetId });
        expect((await accepted).content.code).toBe('WS_SLACK_NOT_CONFIGURED');
        expect(prisma.chatMessage.create).toHaveBeenCalledWith({
            data: expect.objectContaining({ userId: actor, assetId: ownAssetId, messageType: 'SLACK_POST' }),
        });

        for (const moderation of ['PAUSED', 'FLAGGED_FOR_REMOVAL', 'REMOVED']) {
            state.assets.get(ownAssetId).moderation = moderation;
            const writesBefore = prisma.chatMessage.create.mock.calls.length;
            const rejected = waitForEvent(socket, 'message:new');
            socket.emit('message:send', { text: '#news share this', assetId: ownAssetId });
            expect((await rejected).content.code).toBe('WS_ASSET_UNAVAILABLE');
            expect(prisma.chatMessage.create.mock.calls.length).toBe(writesBefore);
        }

        const writesBefore = prisma.chatMessage.create.mock.calls.length;
        const rejected = waitForEvent(socket, 'message:new');
        socket.emit('message:send', { text: '#news share this', assetId: foreignAssetId });
        expect((await rejected).content.code).toBe('WS_ASSET_UNAVAILABLE');
        expect(prisma.chatMessage.create.mock.calls.length).toBe(writesBefore);
        expect(slack.postToChannel).not.toHaveBeenCalled();
        expect(slack.postDM).not.toHaveBeenCalled();
    });
});
