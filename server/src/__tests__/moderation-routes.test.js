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
        findUnique: vi.fn(),
        findMany: vi.fn(),
        update: vi.fn(),
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

const reconcileAssetMedia = vi.fn();
const recordMuxAssetReference = vi.fn();
const withAssetMediaLock = vi.fn();

vi.mock('../lib/prisma.js', () => ({ default: prismaMock }));
vi.mock('../lib/media-reconciliation.js', () => ({ reconcileAssetMedia, recordMuxAssetReference }));
vi.mock('../lib/media-lock.js', () => ({ withAssetMediaLock }));

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
    prismaMock.asset.findUnique.mockResolvedValue({ moderation: 'PAUSED', mediaSyncState: 'SYNCED' });
    prismaMock.asset.findMany.mockResolvedValue([]);
    prismaMock.asset.update.mockResolvedValue({});
    prismaMock.asset.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.clip.findMany.mockResolvedValue([]);
    prismaMock.clip.update.mockResolvedValue({});
    prismaMock.clip.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.auditLog.create.mockResolvedValue({});
    prismaMock.auditLog.findMany.mockResolvedValue([]);
    reconcileAssetMedia.mockResolvedValue({ state: 'SYNCED', message: 'Media reconciliation completed' });
    withAssetMediaLock.mockImplementation(async (_id, work) => ({
        acquired: true,
        value: await work(async () => {}),
    }));

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
    it('pauses an asset, clears playback, and queues reconciliation', async () => {
        prismaMock.asset.findFirst.mockResolvedValue({ id: 'asset-1', moderation: 'ACTIVE' });

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload: { moderation: 'PAUSED' },
        });

        expect(response.statusCode).toBe(200);
        expect(response.json().mediaSyncState).toBe('SYNCED');
        expect(reconcileAssetMedia).toHaveBeenCalledWith(expect.anything(), 'asset-1');
        expect(prismaMock.clip.updateMany).not.toHaveBeenCalled();
        expect(prismaMock.asset.updateMany).toHaveBeenCalledWith(expect.objectContaining({
            where: { id: 'asset-1', moderation: 'ACTIVE' },
            data: expect.objectContaining({
                moderation: 'PAUSED',
                moderatedById: 'admin-1',
                mediaSyncState: 'PENDING',
                mediaPlaybackReset: true,
                mediaSyncRevision: { increment: 1 },
            }),
        }));
    });

    it('reports pending failure and retries without duplicate audit entries', async () => {
        prismaMock.asset.findFirst
            .mockResolvedValueOnce({ id: 'asset-1', moderation: 'ACTIVE' })
            .mockResolvedValueOnce({ id: 'asset-1', moderation: 'PAUSED' });
        reconcileAssetMedia
            .mockResolvedValueOnce({ state: 'ERROR', message: 'Mux revocation failed' })
            .mockResolvedValueOnce({ state: 'SYNCED', message: 'Media reconciliation completed' });
        prismaMock.asset.findUnique
            .mockResolvedValueOnce({ moderation: 'PAUSED', mediaSyncState: 'ERROR' })
            .mockResolvedValueOnce({ moderation: 'PAUSED', mediaSyncState: 'SYNCED' });

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

        expect(failed.statusCode).toBe(202);
        expect(failed.json()).toMatchObject({
            mediaSyncState: 'ERROR',
            message: expect.stringContaining('Mux revocation failed'),
        });
        expect(retried.statusCode).toBe(200);
        expect(prismaMock.auditLog.create).toHaveBeenCalledTimes(1);
    });

    it('queues a flagged asset restore with playback reset required', async () => {
        actor = SUPER_ADMIN;
        prismaMock.asset.findFirst.mockResolvedValue({ id: 'asset-1', moderation: 'FLAGGED_FOR_REMOVAL' });
        prismaMock.asset.findUnique.mockResolvedValue({ moderation: 'ACTIVE', mediaSyncState: 'SYNCED' });

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload: { moderation: 'ACTIVE' },
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.asset.updateMany).toHaveBeenCalledWith(expect.objectContaining({
            data: expect.objectContaining({ moderation: 'ACTIVE', mediaPlaybackReset: true }),
        }));
        expect(prismaMock.auditLog.create).toHaveBeenCalledWith(expect.objectContaining({
            data: expect.objectContaining({ action: 'ASSET_RESTORED' }),
        }));
    });

    it('rejects a stale moderation transition without starting reconciliation', async () => {
        actor = SUPER_ADMIN;
        prismaMock.asset.findFirst.mockResolvedValue({ id: 'asset-1', moderation: 'FLAGGED_FOR_REMOVAL' });
        prismaMock.asset.updateMany.mockResolvedValueOnce({ count: 0 });

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload: { moderation: 'ACTIVE' },
        });

        expect(response.statusCode).toBe(409);
        expect(reconcileAssetMedia).not.toHaveBeenCalled();
        expect(prismaMock.auditLog.create).not.toHaveBeenCalled();
    });

    it('retries reconciliation for an active asset without a transition audit', async () => {
        prismaMock.asset.findFirst.mockResolvedValue({ id: 'asset-1', moderation: 'ACTIVE' });
        prismaMock.asset.findUnique.mockResolvedValue({ moderation: 'ACTIVE', mediaSyncState: 'SYNCED' });

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload: { moderation: 'ACTIVE' },
        });

        expect(response.statusCode).toBe(200);
        expect(reconcileAssetMedia).toHaveBeenCalledWith(expect.anything(), 'asset-1');
        expect(prismaMock.auditLog.create).not.toHaveBeenCalled();
    });

    it('queues removal for a Super Admin and preserves its tombstone', async () => {
        actor = SUPER_ADMIN;
        prismaMock.asset.findFirst.mockResolvedValue({ id: 'asset-1', moderation: 'FLAGGED_FOR_REMOVAL' });
        prismaMock.asset.findUnique.mockResolvedValue({ moderation: 'REMOVED', mediaSyncState: 'SYNCED' });

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload: { moderation: 'REMOVED', reason: 'Confirmed duplicate' },
        });

        expect(response.statusCode).toBe(200);
        expect(reconcileAssetMedia).toHaveBeenCalledWith(expect.anything(), 'asset-1');
        expect(prismaMock.asset.updateMany).toHaveBeenCalledWith(expect.objectContaining({
            data: expect.objectContaining({ moderation: 'REMOVED' }),
        }));
        expect(prismaMock.clip.updateMany).not.toHaveBeenCalled();
    });

    it('does not report success for a moderation state superseded during reconciliation', async () => {
        prismaMock.asset.findFirst.mockResolvedValue({ id: 'asset-1', moderation: 'ACTIVE' });
        prismaMock.asset.findUnique.mockResolvedValue({ moderation: 'ACTIVE', mediaSyncState: 'SYNCED' });

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/assets/asset-1/moderation',
            payload: { moderation: 'PAUSED' },
        });

        expect(response.statusCode).toBe(409);
        expect(response.json().error).toContain('moderation changed');
    });
});

describe('POST /api/admin/assets/:id/media-sync/confirm-create', () => {
    const url = '/api/admin/assets/asset-1/media-sync/confirm-create';
    const payload = { operationId: 'operation-1', confirmed: true, reason: 'Mux confirmed the request cannot complete later' };

    it('requires a Super Admin and explicit confirmation', async () => {
        expect((await app.inject({ method: 'POST', url, payload })).statusCode).toBe(403);
        actor = SUPER_ADMIN;
        expect((await app.inject({ method: 'POST', url, payload: { ...payload, confirmed: false } })).statusCode).toBe(400);
        expect(withAssetMediaLock).not.toHaveBeenCalled();
    });

    describe('GET /api/admin/media-issues', () => {
        it('restricts recovery details to Super Admins', async () => {
            const response = await app.inject({ method: 'GET', url: '/api/admin/media-issues' });
            expect(response.statusCode).toBe(403);
            expect(prismaMock.asset.findMany).not.toHaveBeenCalled();
        });

        it('includes unresolved removed assets and reports truncation', async () => {
            actor = SUPER_ADMIN;
            prismaMock.asset.findMany.mockResolvedValue(Array.from({ length: 101 }, (_, index) => ({
                id: `asset-${index}`, moderation: 'REMOVED', mediaSyncState: 'ERROR',
            })));
            const response = await app.inject({ method: 'GET', url: '/api/admin/media-issues' });
            expect(response.statusCode).toBe(200);
            expect(response.json().issues).toHaveLength(100);
            expect(response.json().hasMore).toBe(true);
            expect(prismaMock.asset.findMany).toHaveBeenCalledWith(expect.objectContaining({
                where: expect.objectContaining({ OR: expect.arrayContaining([
                    { moderation: { not: 'ACTIVE' }, mediaSyncState: 'PENDING' },
                ]) }),
            }));
        });
    });

    it('records a matching confirmation before retrying reconciliation', async () => {
        actor = SUPER_ADMIN;
        prismaMock.$queryRaw.mockResolvedValueOnce([{
            media_create_operation_id: 'operation-1',
            media_create_mux_asset_id: 'mux-operation-1',
        }]);

        const response = await app.inject({ method: 'POST', url, payload });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.asset.update).toHaveBeenCalledWith(expect.objectContaining({
            data: expect.objectContaining({
                mediaCreateOperationId: null,
                mediaPlaybackReset: true,
                mediaSyncState: 'PENDING',
            }),
        }));
        expect(prismaMock.auditLog.create).toHaveBeenCalledWith(expect.objectContaining({
            data: expect.objectContaining({
                action: 'MEDIA_CREATE_CONFIRMED',
                reason: `Operation ${payload.operationId}: ${payload.reason}`,
            }),
        }));
        expect(recordMuxAssetReference).toHaveBeenCalledWith(prismaMock, {
            assetId: 'asset-1', muxAssetId: 'mux-operation-1',
        });
        expect(reconcileAssetMedia).toHaveBeenCalledWith(expect.anything(), 'asset-1');
    });

    it('does not confirm a stale or currently running operation', async () => {
        actor = SUPER_ADMIN;
        prismaMock.$queryRaw.mockResolvedValueOnce([{ media_create_operation_id: 'other-operation' }]);
        expect((await app.inject({ method: 'POST', url, payload })).statusCode).toBe(409);
        withAssetMediaLock.mockResolvedValueOnce({ acquired: false });
        expect((await app.inject({ method: 'POST', url, payload })).statusCode).toBe(409);
        expect(prismaMock.auditLog.create).not.toHaveBeenCalled();
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
