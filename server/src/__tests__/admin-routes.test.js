// Last updated: May 9, 2026 - 8:14pm - GPT-5.3-Codex
import Fastify from 'fastify';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { requireRole } from '../lib/authorization.js';

const prismaMock = {
    $queryRaw: vi.fn(),
    $executeRaw: vi.fn(),
    $transaction: vi.fn(),
    asset: {
        findMany: vi.fn(),
        deleteMany: vi.fn(),
    },
    chatMessage: {
        deleteMany: vi.fn(),
        findMany: vi.fn(),
    },
    clip: {
        findMany: vi.fn(),
        deleteMany: vi.fn(),
    },
    errorLog: {
        deleteMany: vi.fn(),
    },
    formResponse: {
        deleteMany: vi.fn(),
    },
    user: {
        findUnique: vi.fn(),
        findFirst: vi.fn(),
        create: vi.fn(),
        findMany: vi.fn(),
        updateMany: vi.fn(),
        update: vi.fn(),
        delete: vi.fn(),
    },
    organization: {
        findUnique: vi.fn(),
        findMany: vi.fn(),
        create: vi.fn(),
        update: vi.fn(),
        delete: vi.fn(),
    },
};

const muxMock = {
    deleteMuxAsset: vi.fn(),
};

const muxState = {
    enabled: false,
};

const fsMock = {
    unlink: vi.fn(),
};

vi.mock('../lib/prisma.js', () => ({
    default: prismaMock,
}));

vi.mock('../lib/mux.js', () => ({
    get isMuxEnabled() {
        return muxState.enabled;
    },
    deleteMuxAsset: muxMock.deleteMuxAsset,
}));

vi.mock('fs/promises', () => ({
    unlink: fsMock.unlink,
    default: fsMock,
}));

let adminRoutes;
let app;

beforeAll(async () => {
    ({ default: adminRoutes } = await import('../routes/admin.js'));
});

beforeEach(async () => {
    vi.clearAllMocks();
    muxState.enabled = false;

    prismaMock.$queryRaw.mockResolvedValue([{ ok: 1 }]);
    prismaMock.$executeRaw.mockResolvedValue(undefined);
    prismaMock.$transaction.mockImplementation(async (fn) => fn(prismaMock));

    prismaMock.asset.findMany.mockResolvedValue([]);
    prismaMock.asset.deleteMany.mockResolvedValue({ count: 0 });

    prismaMock.chatMessage.deleteMany.mockResolvedValue({ count: 0 });
    prismaMock.chatMessage.findMany.mockResolvedValue([]);

    prismaMock.clip.findMany.mockResolvedValue([]);
    prismaMock.clip.deleteMany.mockResolvedValue({ count: 0 });

    prismaMock.errorLog.deleteMany.mockResolvedValue({ count: 0 });
    prismaMock.formResponse.deleteMany.mockResolvedValue({ count: 0 });

    prismaMock.user.findUnique.mockResolvedValue(null);
    prismaMock.user.findFirst.mockResolvedValue(null);
    prismaMock.user.create.mockResolvedValue({
        id: 'user-new',
        name: 'New Reporter',
        phoneNumber: '5055551234',
        email: null,
        team: null,
        role: 'USER',
        companyCode: null,
    });
    prismaMock.user.findMany.mockResolvedValue([]);
    prismaMock.user.updateMany.mockResolvedValue({ count: 0 });
    prismaMock.user.update.mockResolvedValue({
        id: 'user-1',
        name: 'Updated Name',
        phoneNumber: '5055551000',
        email: null,
        team: null,
        companyCode: null,
        organization: null,
    });
    prismaMock.user.delete.mockResolvedValue({});

    prismaMock.organization.findUnique.mockResolvedValue(null);
    prismaMock.organization.findMany.mockResolvedValue([]);
    prismaMock.organization.create.mockResolvedValue({
        id: 'org-1',
        companyName: 'Sea Lion',
        companyCode: 'SLM',
        createdAt: new Date('2026-05-09T00:00:00.000Z'),
    });
    prismaMock.organization.update.mockResolvedValue({
        id: 'org-1',
        companyName: 'Sea Lion',
        companyCode: 'SLM',
        createdAt: new Date('2026-05-09T00:00:00.000Z'),
    });
    prismaMock.organization.delete.mockResolvedValue({});

    muxMock.deleteMuxAsset.mockResolvedValue(true);
    fsMock.unlink.mockResolvedValue(undefined);

    app = Fastify({ logger: false });

    app.decorate('authenticate', async (request) => {
        request.user = {
            id: 'admin-1',
            sub: 'admin-1',
            role: 'SUPER_ADMIN',
            companyCode: 'NEWS',
        };
    });

    app.decorate('requireRole', requireRole);

    app.decorate('io', {
        of: () => ({ sockets: new Map([['s1', {}], ['s2', {}]]) }),
    });
    app.decorate('userSockets', new Map([['user-1', new Set(['s1'])]]));
    app.decorate('iosSockets', new Set(['s1']));
    app.decorate('adminSockets', new Set(['s2']));

    await app.register(adminRoutes);
});

afterEach(async () => {
    await app.close();
});

describe('admin routes deeper coverage', () => {
    it('returns triad status with websocket counts', async () => {
        prismaMock.$queryRaw.mockResolvedValueOnce([{ ok: 1 }]);

        const response = await app.inject({
            method: 'GET',
            url: '/api/admin/status',
        });

        expect(response.statusCode).toBe(200);
        const body = response.json();
        expect(body.triad.database.status).toBe('ok');
        expect(body.triad.ios.clients).toBe(1);
        expect(body.connectedUsers).toBe(1);
        expect(body.totalWsConnections).toBe(2);
    });

    it('returns no-op cleanup result when there are no stale assets', async () => {
        prismaMock.asset.findMany.mockResolvedValue([]);

        const response = await app.inject({
            method: 'POST',
            url: '/api/admin/cleanup-assets',
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual({ cleaned: 0, message: 'No stale assets found' });
        expect(prismaMock.chatMessage.deleteMany).not.toHaveBeenCalled();
    });

    it('cleans stale uploading assets and dependent messages', async () => {
        prismaMock.asset.findMany.mockResolvedValue([{ id: 'asset-1' }, { id: 'asset-2' }]);
        prismaMock.chatMessage.deleteMany.mockResolvedValue({ count: 2 });
        prismaMock.asset.deleteMany.mockResolvedValue({ count: 2 });

        const response = await app.inject({
            method: 'POST',
            url: '/api/admin/cleanup-assets',
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.chatMessage.deleteMany).toHaveBeenCalledWith({
            where: { assetId: { in: ['asset-1', 'asset-2'] } },
        });
        expect(prismaMock.asset.deleteMany).toHaveBeenCalledWith({
            where: { id: { in: ['asset-1', 'asset-2'] } },
        });
        expect(response.json().cleaned).toBe(2);
    });

    it('validates admin user creation inputs and uniqueness', async () => {
        const missing = await app.inject({
            method: 'POST',
            url: '/api/admin/users',
            payload: { name: 'Test Only' },
        });
        expect(missing.statusCode).toBe(400);

        prismaMock.organization.findUnique.mockResolvedValueOnce(null);
        const badOrg = await app.inject({
            method: 'POST',
            url: '/api/admin/users',
            payload: {
                name: 'Test',
                phoneNumber: '5055559999',
                companyCode: 'NONE',
            },
        });
        expect(badOrg.statusCode).toBe(400);

        prismaMock.organization.findUnique.mockResolvedValueOnce({ id: 'org-1', companyCode: 'NEWS' });
        prismaMock.user.findUnique.mockResolvedValueOnce({ id: 'existing-user' });
        const duplicate = await app.inject({
            method: 'POST',
            url: '/api/admin/users',
            payload: {
                name: 'Test',
                phoneNumber: '5055559999',
                companyCode: 'NEWS',
            },
        });

        expect(duplicate.statusCode).toBe(409);
    });

    it('creates a user with default role and pin', async () => {
        prismaMock.organization.findUnique.mockResolvedValueOnce({ id: 'org-1', companyCode: 'NEWS' });
        prismaMock.user.findUnique.mockResolvedValueOnce(null);

        const response = await app.inject({
            method: 'POST',
            url: '/api/admin/users',
            payload: {
                name: 'Field Producer',
                phoneNumber: '5055550001',
                email: 'field@example.com',
                team: 'News Team',
                companyCode: 'NEWS',
            },
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.user.create).toHaveBeenCalledWith({
            data: expect.objectContaining({
                name: 'Field Producer',
                phoneNumber: '5055550001',
                role: 'USER',
                companyCode: 'NEWS',
            }),
        });
    });

    it('rejects organization deletion while users are assigned', async () => {
        prismaMock.organization.findUnique.mockResolvedValueOnce({
            companyName: 'Sea Lion',
            companyCode: 'SLM',
            _count: { users: 2 },
        });

        const response = await app.inject({
            method: 'DELETE',
            url: '/api/admin/organizations/SLM',
        });

        expect(response.statusCode).toBe(409);
        expect(response.json().error).toContain('still assigned');
        expect(prismaMock.organization.delete).not.toHaveBeenCalled();
    });

    it('returns no changes error when editing user without any fields', async () => {
        prismaMock.user.findFirst.mockResolvedValueOnce({
            id: 'user-1',
            name: 'Reporter',
            phoneNumber: '5055551000',
        });

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/admin/users/user-1',
            payload: {},
        });

        expect(response.statusCode).toBe(400);
        expect(response.json()).toEqual({ error: 'No changes provided' });
    });

    it('updates organization code in transaction and reassigns affected users', async () => {
        prismaMock.organization.findUnique
            .mockResolvedValueOnce({
                id: 'org-1',
                companyName: 'Sea Lion',
                companyCode: 'SLM',
            })
            .mockResolvedValueOnce(null);
        prismaMock.user.findMany.mockResolvedValueOnce([{ id: 'user-1' }, { id: 'user-2' }]);
        prismaMock.organization.update.mockResolvedValueOnce({
            id: 'org-1',
            companyName: 'Sea Lion Media',
            companyCode: 'SLMX',
            createdAt: new Date('2026-05-09T00:00:00.000Z'),
        });

        const response = await app.inject({
            method: 'PUT',
            url: '/api/admin/organizations/SLM',
            payload: {
                companyName: 'Sea Lion Media',
                companyCode: 'SLMX',
            },
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.user.findMany).toHaveBeenCalledWith({
            where: { companyCode: 'SLM' },
            select: { id: true },
        });
        expect(prismaMock.user.updateMany).toHaveBeenNthCalledWith(1, {
            where: { id: { in: ['user-1', 'user-2'] } },
            data: { companyCode: null },
        });
        expect(prismaMock.organization.update).toHaveBeenCalledWith({
            where: { companyCode: 'SLM' },
            data: {
                companyName: 'Sea Lion Media',
                companyCode: 'SLMX',
            },
        });
        expect(prismaMock.user.updateMany).toHaveBeenNthCalledWith(2, {
            where: { id: { in: ['user-1', 'user-2'] } },
            data: { companyCode: 'SLMX' },
        });
        expect(response.json().organization.companyCode).toBe('SLMX');
    });

    it('rejects deleting own admin account', async () => {
        const response = await app.inject({
            method: 'DELETE',
            url: '/api/admin/users/admin-1',
        });

        expect(response.statusCode).toBe(400);
        expect(response.json()).toEqual({ error: 'Cannot delete your own account' });
    });

    it('returns not found when deleting a missing user', async () => {
        prismaMock.user.findUnique.mockResolvedValueOnce(null);

        const response = await app.inject({
            method: 'DELETE',
            url: '/api/admin/users/user-missing',
        });

        expect(response.statusCode).toBe(404);
        expect(response.json()).toEqual({ error: 'User not found' });
    });

    it('deletes user data including mux assets and local files', async () => {
        muxState.enabled = true;
        prismaMock.user.findUnique.mockResolvedValueOnce({
            id: 'user-delete',
            name: 'Delete Me',
            phoneNumber: '5055552222',
        });
        prismaMock.clip.findMany.mockResolvedValueOnce([
            { muxAssetId: 'mux-1', storageUrl: '/uploads/delete-1.mp4' },
            { muxAssetId: null, storageUrl: '/uploads/delete-2.mp4' },
        ]);
        prismaMock.chatMessage.deleteMany.mockResolvedValueOnce({ count: 4 });
        prismaMock.errorLog.deleteMany.mockResolvedValueOnce({ count: 1 });
        prismaMock.asset.deleteMany.mockResolvedValueOnce({ count: 2 });

        const response = await app.inject({
            method: 'DELETE',
            url: '/api/admin/users/user-delete',
        });

        expect(response.statusCode).toBe(200);
        expect(muxMock.deleteMuxAsset).toHaveBeenCalledWith('mux-1');
        expect(fsMock.unlink).toHaveBeenCalledTimes(2);
        expect(prismaMock.chatMessage.deleteMany).toHaveBeenCalledWith({ where: { userId: 'user-delete' } });
        expect(prismaMock.errorLog.deleteMany).toHaveBeenCalledWith({ where: { userId: 'user-delete' } });
        expect(prismaMock.asset.deleteMany).toHaveBeenCalledWith({ where: { userId: 'user-delete' } });
        expect(prismaMock.user.delete).toHaveBeenCalledWith({ where: { id: 'user-delete' } });
        expect(response.json().deleted).toEqual({
            assets: 2,
            clips: 2,
            chatMessages: 4,
            errorLogs: 1,
            muxAssets: 1,
            localFiles: 2,
        });
    });
});
