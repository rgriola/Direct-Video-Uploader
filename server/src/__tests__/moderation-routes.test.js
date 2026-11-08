import Fastify from 'fastify';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { requireRole } from '../lib/authorization.js';

const prismaMock = {
    $transaction: vi.fn(),
    $queryRaw: vi.fn(),
    user: {
        findFirst: vi.fn(),
        count: vi.fn(),
        updateMany: vi.fn(),
    },
    asset: {
        findFirst: vi.fn(),
        updateMany: vi.fn(),
    },
    clip: {
        findMany: vi.fn(),
        update: vi.fn(),
        updateMany: vi.fn(),
    },
    auditLog: {
        create: vi.fn(),
        findMany: vi.fn(),
    },
};

const muxMock = {
    deleteMuxAsset: vi.fn(),
    disableMuxPlayback: vi.fn(),
    enableMuxPlayback: vi.fn(),
};

vi.mock('../lib/prisma.js', () => ({ default: prismaMock }));
vi.mock('../lib/mux.js', () => ({
    deleteMuxAsset: muxMock.deleteMuxAsset,
    disableMuxPlayback: muxMock.disableMuxPlayback,
    enableMuxPlayback: muxMock.enableMuxPlayback,
}));

let moderationRoutes;
let app;
let actor;
let disconnect;

const TEAM_ADMIN = { id: 'admin-1', role: 'ADMIN', companyCode: 'NEWS' };
const SUPER_ADMIN = { id: 'super-1', role: 'SUPER_ADMIN', companyCode: null };

beforeAll(async () => {
    ({ default: moderationRoutes } = await import('../routes/moderation.js'));
});

beforeEach(async () => {
    vi.clearAllMocks();
    actor = TEAM_ADMIN;
    disconnect = vi.fn();

    prismaMock.$transaction.mockImplementation(async callback => callback(prismaMock));
    prismaMock.$queryRaw.mockResolvedValue([{ id: 'super-1' }, { id: 'super-2' }]);
    prismaMock.user.findFirst.mockResolvedValue(null);
    prismaMock.user.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.asset.findFirst.mockResolvedValue(null);
    prismaMock.asset.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.clip.findMany.mockResolvedValue([]);
    prismaMock.clip.update.mockResolvedValue({});
    prismaMock.clip.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.auditLog.create.mockResolvedValue({});
    prismaMock.auditLog.findMany.mockResolvedValue([]);
    muxMock.deleteMuxAsset.mockResolvedValue(true);
    muxMock.disableMuxPlayback.mockResolvedValue({ ok: true });
    muxMock.enableMuxPlayback.mockResolvedValue({ ok: true, playbackId: 'playback-restored' });

    app = Fastify({ logger: false });
    app.decorate('authenticate', async request => { request.user = { ...actor }; });
    app.decorate('requireRole', requireRole);
    app.decorate('socketAuthState', { revision: 0 });
    app.decorate('userSockets', new Map([['user-1', new Set(['socket-1'])]]));
    app.decorate('io', { sockets: { sockets: new Map([['socket-1', { disconnect }]]) } });
    await app.register(moderationRoutes);
});

afterEach(async () => {
    await app.close();
});

describe('PATCH /api/admin/users/:id/status', () => {
    it('pauses a team member, records the action, and disconnects their sockets', async () => {
        prismaMock.user.findFirst.mockResolvedValue({
            id: 'user-1',
            role: 'USER',
            status: 'ACTIVE',
        });

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/users/user-1/status',
            payload: { status: 'SUSPENDED', reason: 'Account review' },
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.user.updateMany).toHaveBeenCalledWith(expect.objectContaining({
            where: { id: 'user-1', status: 'ACTIVE', companyCode: 'NEWS' },
            data: {
                status: 'SUSPENDED',
                pausedAt: expect.any(Date),
                pausedById: 'admin-1',
            },
        }));
        expect(prismaMock.auditLog.create).toHaveBeenCalledWith({
            data: {
                actorUserId: 'admin-1',
                targetType: 'USER',
                targetId: 'user-1',
                action: 'USER_PAUSED',
                reason: 'Account review',
            },
        });
        expect(disconnect).toHaveBeenCalledWith(true);
        expect(app.socketAuthState.revision).toBe(1);
    });

    it('prevents pausing the last active Super Admin', async () => {
        actor = SUPER_ADMIN;
        prismaMock.user.findFirst.mockResolvedValue({
            id: 'super-2',
            role: 'SUPER_ADMIN',
            status: 'ACTIVE',
        });
        prismaMock.$queryRaw.mockResolvedValueOnce([{ id: 'super-2' }]);

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/users/super-2/status',
            payload: { status: 'SUSPENDED' },
        });

        expect(response.statusCode).toBe(409);
        expect(prismaMock.user.updateMany).not.toHaveBeenCalled();
    });

    it('hides users outside a Team Admin organization', async () => {
        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/users/outside/status',
            payload: { status: 'SUSPENDED' },
        });

        expect(response.statusCode).toBe(404);
        expect(prismaMock.user.updateMany).not.toHaveBeenCalled();
    });
});

describe('PATCH /api/admin/assets/:id/moderation', () => {
    it('pauses an asset and revokes its Mux playback ID', async () => {
        prismaMock.asset.findFirst.mockResolvedValue({ id: 'asset-1', moderation: 'ACTIVE' });
        prismaMock.clip.findMany.mockResolvedValue([{
            id: 'clip-1',
            muxAssetId: 'mux-1',
            muxPlaybackId: 'playback-1',
            storageUrl: null,
        }]);

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload: { moderation: 'PAUSED' },
        });

        expect(response.statusCode).toBe(200);
        expect(muxMock.disableMuxPlayback).toHaveBeenCalledWith('mux-1');
        expect(prismaMock.clip.update).toHaveBeenCalledWith({
            where: { id: 'clip-1' },
            data: { muxPlaybackId: null, streamUrl: null, thumbnailUrl: null },
        });
        expect(prismaMock.asset.updateMany).toHaveBeenCalledWith(expect.objectContaining({
            where: { id: 'asset-1', moderation: 'ACTIVE' },
            data: expect.objectContaining({ moderation: 'PAUSED', moderatedById: 'admin-1' }),
        }));
    });

    it('allows retrying playback revocation after partial failure without duplicate audit entries', async () => {
        prismaMock.asset.findFirst
            .mockResolvedValueOnce({ id: 'asset-1', moderation: 'ACTIVE' })
            .mockResolvedValueOnce({ id: 'asset-1', moderation: 'PAUSED' });
        prismaMock.clip.findMany.mockResolvedValue([{
            id: 'clip-1',
            muxAssetId: 'mux-1',
            muxPlaybackId: 'playback-1',
        }]);
        muxMock.disableMuxPlayback
            .mockResolvedValueOnce({ ok: false, error: 'temporary outage' })
            .mockResolvedValueOnce({ ok: true });

        const payload = { moderation: 'PAUSED' };
        const failed = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload,
        });
        const retried = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload,
        });

        expect(failed.statusCode).toBe(502);
        expect(retried.statusCode).toBe(200);
        expect(prismaMock.auditLog.create).toHaveBeenCalledTimes(1);
    });

    it('restores a flagged asset with a new playback ID', async () => {
        actor = SUPER_ADMIN;
        prismaMock.asset.findFirst.mockResolvedValue({ id: 'asset-1', moderation: 'FLAGGED_FOR_REMOVAL' });
        prismaMock.clip.findMany.mockResolvedValue([{
            id: 'clip-1',
            muxAssetId: 'mux-1',
            muxPlaybackId: null,
        }]);

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload: { moderation: 'ACTIVE' },
        });

        expect(response.statusCode).toBe(200);
        expect(muxMock.enableMuxPlayback).toHaveBeenCalledWith('mux-1');
        expect(prismaMock.clip.update).toHaveBeenCalledWith({
            where: { id: 'clip-1' },
            data: {
                muxPlaybackId: 'playback-restored',
                streamUrl: 'https://stream.mux.com/playback-restored.m3u8',
                thumbnailUrl: 'https://image.mux.com/playback-restored/thumbnail.png?width=640',
            },
        });
        expect(prismaMock.auditLog.create).toHaveBeenCalledWith(expect.objectContaining({
            data: expect.objectContaining({ action: 'ASSET_RESTORED' }),
        }));
    });

    it('revokes playback if moderation changes before a restore can commit', async () => {
        actor = SUPER_ADMIN;
        prismaMock.asset.findFirst.mockResolvedValue({ id: 'asset-1', moderation: 'FLAGGED_FOR_REMOVAL' });
        prismaMock.asset.updateMany.mockResolvedValueOnce({ count: 0 });
        prismaMock.clip.findMany.mockResolvedValue([{
            id: 'clip-1',
            muxAssetId: 'mux-1',
            muxPlaybackId: null,
        }]);

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload: { moderation: 'ACTIVE' },
        });

        expect(response.statusCode).toBe(409);
        expect(muxMock.enableMuxPlayback).toHaveBeenCalledWith('mux-1');
        expect(muxMock.disableMuxPlayback).toHaveBeenCalledWith('mux-1');
        expect(prismaMock.clip.update).toHaveBeenCalledWith({
            where: { id: 'clip-1' },
            data: { muxPlaybackId: null, streamUrl: null, thumbnailUrl: null },
        });
        expect(prismaMock.auditLog.create).not.toHaveBeenCalled();
    });

    it('persists playback for an active asset under a state lock without a transition audit', async () => {
        prismaMock.asset.findFirst.mockResolvedValue({ id: 'asset-1', moderation: 'ACTIVE' });
        prismaMock.clip.findMany.mockResolvedValue([{
            id: 'clip-1',
            muxAssetId: 'mux-1',
            muxPlaybackId: null,
        }]);
        prismaMock.$queryRaw.mockResolvedValueOnce([{ moderation: 'ACTIVE' }]);

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload: { moderation: 'ACTIVE' },
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.clip.update).toHaveBeenCalledWith({
            where: { id: 'clip-1' },
            data: {
                muxPlaybackId: 'playback-restored',
                streamUrl: 'https://stream.mux.com/playback-restored.m3u8',
                thumbnailUrl: 'https://image.mux.com/playback-restored/thumbnail.png?width=640',
            },
        });
        expect(prismaMock.auditLog.create).not.toHaveBeenCalled();
    });

    it('removes a flagged asset only for Super Admin and preserves its tombstone', async () => {
        actor = SUPER_ADMIN;
        prismaMock.asset.findFirst.mockResolvedValue({ id: 'asset-1', moderation: 'FLAGGED_FOR_REMOVAL' });
        prismaMock.clip.findMany.mockResolvedValue([{
            id: 'clip-1',
            muxAssetId: 'mux-1',
            muxPlaybackId: 'playback-1',
            storageUrl: null,
        }]);

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload: { moderation: 'REMOVED', reason: 'Confirmed duplicate' },
        });

        expect(response.statusCode).toBe(200);
        expect(muxMock.deleteMuxAsset).toHaveBeenCalledWith('mux-1');
        expect(prismaMock.asset.updateMany).toHaveBeenCalledWith(expect.objectContaining({
            data: expect.objectContaining({ moderation: 'REMOVED' }),
        }));
        expect(prismaMock.clip.updateMany).toHaveBeenCalledWith({
            where: { assetId: 'asset-1' },
            data: {
                muxAssetId: null,
                muxPlaybackId: null,
                streamUrl: null,
                thumbnailUrl: null,
                storageUrl: null,
            },
        });
    });
});

describe('GET /api/admin/audit-logs', () => {
    it('restricts audit history to Super Admin', async () => {
        const response = await app.inject({ method: 'GET', url: '/api/admin/audit-logs' });
        expect(response.statusCode).toBe(403);
        expect(prismaMock.auditLog.findMany).not.toHaveBeenCalled();
    });

    it('returns a bounded audit log to Super Admin', async () => {
        actor = SUPER_ADMIN;
        prismaMock.auditLog.findMany.mockResolvedValue([{ id: 'audit-1' }]);

        const response = await app.inject({ method: 'GET', url: '/api/admin/audit-logs?limit=20' });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.auditLog.findMany).toHaveBeenCalledWith({
            orderBy: { createdAt: 'desc' },
            take: 20,
        });
        expect(response.json()).toEqual({ logs: [{ id: 'audit-1' }] });
    });
});
