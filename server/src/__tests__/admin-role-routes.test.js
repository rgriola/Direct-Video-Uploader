import Fastify from 'fastify';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { requireRole } from '../lib/authorization.js';

const prismaMock = {
    user: {
        findUnique: vi.fn(),
        findFirst: vi.fn(),
        update: vi.fn(),
        updateMany: vi.fn(),
    },
    organization: {
        findUnique: vi.fn(),
    },
};

vi.mock('../lib/prisma.js', () => ({ default: prismaMock }));
vi.mock('../lib/mux.js', () => ({ isMuxEnabled: false, deleteMuxAsset: vi.fn() }));

let adminRoutes;
let app;
let actor;

const TEAM_ADMIN = { id: 'admin-1', sub: 'admin-1', role: 'ADMIN', companyCode: 'NEWS' };
const SUPER = { id: 'super-1', sub: 'super-1', role: 'SUPER_ADMIN', companyCode: null };

function target(overrides = {}) {
    return { id: 'user-1', name: 'Pat Reporter', phoneNumber: '5055551000', role: 'USER', companyCode: 'NEWS', ...overrides };
}

function patchRole(id, body) {
    return app.inject({ method: 'PATCH', url: `/api/admin/users/${id}/role`, payload: body });
}

beforeAll(async () => {
    ({ default: adminRoutes } = await import('../routes/admin.js'));
});

beforeEach(async () => {
    vi.clearAllMocks();
    actor = TEAM_ADMIN;
    prismaMock.user.findFirst.mockResolvedValue(null);
    prismaMock.user.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.user.update.mockImplementation(async ({ where, data }) => ({
        id: where.id, name: 'Pat Reporter', companyCode: 'NEWS', ...data,
    }));

    app = Fastify({ logger: false });
    app.decorate('authenticate', async (request, reply) => {
        if (!actor) return reply.code(401).send({ error: 'Unauthorized' });
        request.user = { ...actor };
    });
    app.decorate('requireRole', requireRole);
    app.decorate('io', { of: () => ({ sockets: new Map() }), sockets: { sockets: new Map() } });
    app.decorate('socketAuthState', { revision: 0 });
    app.decorate('userSockets', new Map());
    app.decorate('iosSockets', new Set());
    app.decorate('adminSockets', new Set());
    app.decorate('monitoring', {
        snapshot: () => ({ enabled: true, checkedAt: null, checks: [], stale: false }),
    });
    await app.register(adminRoutes);
});

afterEach(async () => {
    await app.close();
});

describe('GET /api/admin/monitoring', () => {
    it('restricts monitoring to super admins and disables caching', async () => {
        actor = null;
        expect((await app.inject({ method: 'GET', url: '/api/admin/monitoring' })).statusCode).toBe(401);
        actor = TEAM_ADMIN;
        expect((await app.inject({ method: 'GET', url: '/api/admin/monitoring' })).statusCode).toBe(403);
        actor = { ...TEAM_ADMIN, role: 'USER' };
        expect((await app.inject({ method: 'GET', url: '/api/admin/monitoring' })).statusCode).toBe(403);
        actor = SUPER;
        const response = await app.inject({ method: 'GET', url: '/api/admin/monitoring' });
        expect(response.statusCode).toBe(200);
        expect(response.headers['cache-control']).toBe('no-store');
        expect(response.json()).toMatchObject({ enabled: true, checks: [] });
    });

    it('reports an unavailable monitoring service instead of claiming it is disabled', async () => {
        actor = SUPER;
        app.monitoring = null;
        const response = await app.inject({ method: 'GET', url: '/api/admin/monitoring' });
        expect(response.statusCode).toBe(503);
        expect(response.headers['cache-control']).toBe('no-store');
        expect(response.json()).toEqual({ error: 'Monitoring service is unavailable' });
    });
});

describe('PATCH /api/admin/users/:id/role', () => {
    it('lets a team admin promote a user in their organization', async () => {
        prismaMock.user.findFirst.mockResolvedValue(target());

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(200);
        expect(res.json().user.role).toBe('ADMIN');
        expect(prismaMock.user.updateMany).toHaveBeenCalledWith(expect.objectContaining({
            where: { id: 'user-1', companyCode: 'NEWS', role: 'USER' },
            data: { role: 'ADMIN' },
        }));
    });

    it('reconnects dashboards after a role change without disconnecting iOS', async () => {
        prismaMock.user.findFirst.mockResolvedValue(target());
        const dashboard = { disconnect: vi.fn() };
        const phone = { disconnect: vi.fn() };
        app.userSockets.set('user-1', new Set(['dashboard', 'phone']));
        app.adminSockets.add('dashboard');
        app.iosSockets.add('phone');
        app.io.sockets.sockets.set('dashboard', dashboard);
        app.io.sockets.sockets.set('phone', phone);

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(200);
        expect(app.socketAuthState.revision).toBe(1);
        expect(dashboard.disconnect).toHaveBeenCalledWith(true);
        expect(phone.disconnect).not.toHaveBeenCalled();
    });

    it('lets a team admin demote another team admin in their organization', async () => {
        prismaMock.user.findFirst.mockResolvedValue(target({ id: 'admin-2', role: 'ADMIN' }));

        const res = await patchRole('admin-2', { role: 'USER' });

        expect(res.statusCode).toBe(200);
        expect(res.json().user.role).toBe('USER');
    });

    it('does not merge organizations whose codes differ only in case', async () => {
        prismaMock.user.findFirst.mockResolvedValue(target({ companyCode: 'news' }));

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(404);
    });

    it('returns 404 when a team admin targets another organization', async () => {
        prismaMock.user.findFirst.mockResolvedValue(target({ companyCode: 'OTHER' }));

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(404);
        expect(prismaMock.user.updateMany).not.toHaveBeenCalled();
    });

    it('returns 404 when a team admin targets a user with no organization', async () => {
        prismaMock.user.findFirst.mockResolvedValue(target({ companyCode: null }));

        const res = await patchRole('user-1', { role: 'USER' });

        expect(res.statusCode).toBe(404);
    });

    it('returns 404 for an unknown user', async () => {
        prismaMock.user.findFirst.mockResolvedValue(null);

        const res = await patchRole('missing', { role: 'ADMIN' });

        expect(res.statusCode).toBe(404);
    });

    it('lets the super admin change roles in any organization', async () => {
        actor = SUPER;
        prismaMock.user.findFirst.mockResolvedValue(target({ companyCode: 'OTHER' }));

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(200);
    });

    it('rejects granting SUPER_ADMIN through the API', async () => {
        actor = SUPER;
        prismaMock.user.findFirst.mockResolvedValue(target());

        const res = await patchRole('user-1', { role: 'SUPER_ADMIN' });

        expect(res.statusCode).toBe(400);
        expect(prismaMock.user.updateMany).not.toHaveBeenCalled();
    });

    it('rejects a missing or unknown role', async () => {
        prismaMock.user.findFirst.mockResolvedValue(target());

        expect((await patchRole('user-1', {})).statusCode).toBe(400);
        expect((await patchRole('user-1', { role: 'OWNER' })).statusCode).toBe(400);
        expect(prismaMock.user.updateMany).not.toHaveBeenCalled();
    });

    it("refuses to change the super admin's role", async () => {
        actor = SUPER;
        prismaMock.user.findFirst.mockResolvedValue(target({ id: 'super-2', role: 'SUPER_ADMIN' }));

        const res = await patchRole('super-2', { role: 'USER' });

        expect(res.statusCode).toBe(403);
        expect(prismaMock.user.updateMany).not.toHaveBeenCalled();
    });

    it('refuses to let an admin change their own role', async () => {
        prismaMock.user.findFirst.mockResolvedValue(target({ id: 'admin-1', role: 'ADMIN' }));

        const res = await patchRole('admin-1', { role: 'USER' });

        expect(res.statusCode).toBe(400);
        expect(prismaMock.user.updateMany).not.toHaveBeenCalled();
    });

    it('requires an organization before promoting to ADMIN', async () => {
        actor = SUPER;
        prismaMock.user.findFirst.mockResolvedValue(target({ companyCode: null }));

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(400);
        expect(prismaMock.user.updateMany).not.toHaveBeenCalled();
    });

    it('does not write when the role is unchanged', async () => {
        prismaMock.user.findFirst.mockResolvedValue(target({ role: 'ADMIN', id: 'admin-2' }));

        const res = await patchRole('admin-2', { role: 'ADMIN' });

        expect(res.statusCode).toBe(200);
        expect(prismaMock.user.updateMany).not.toHaveBeenCalled();
    });

    it('does not change a role after the target leaves the allowed scope', async () => {
        prismaMock.user.findFirst.mockResolvedValue(target());
        prismaMock.user.updateMany.mockResolvedValue({ count: 0 });

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(404);
        expect(prismaMock.user.updateMany).toHaveBeenCalledWith({
            where: { id: 'user-1', companyCode: 'NEWS', role: 'USER' },
            data: { role: 'ADMIN' },
        });
    });

    it('does not promote a user whose organization changed before the write', async () => {
        actor = SUPER;
        prismaMock.user.findFirst.mockResolvedValue(target());
        prismaMock.user.updateMany.mockResolvedValue({ count: 0 });

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(404);
        expect(prismaMock.user.updateMany).toHaveBeenCalledWith({
            where: { id: 'user-1', role: 'USER', companyCode: 'NEWS' },
            data: { role: 'ADMIN' },
        });
    });

    it('rejects non-admin callers', async () => {
        actor = { id: 'user-9', sub: 'user-9', role: 'USER', companyCode: 'NEWS' };

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(403);
        expect(prismaMock.user.findFirst).not.toHaveBeenCalled();
    });
});

describe('PATCH /api/admin/users/:id organization guard', () => {
    it('reconnects dashboards when a user moves organizations', async () => {
        actor = SUPER;
        prismaMock.user.findFirst.mockResolvedValue(target({ role: 'ADMIN' }));
        prismaMock.organization.findUnique.mockResolvedValue({ companyCode: 'SPRT' });
        const dashboard = { disconnect: vi.fn() };
        const phone = { disconnect: vi.fn() };
        app.userSockets.set('user-1', new Set(['dashboard', 'phone']));
        app.adminSockets.add('dashboard');
        app.iosSockets.add('phone');
        app.io.sockets.sockets.set('dashboard', dashboard);
        app.io.sockets.sockets.set('phone', phone);

        const res = await app.inject({
            method: 'PATCH', url: '/api/admin/users/user-1', payload: { companyCode: 'SPRT' },
        });

        expect(res.statusCode).toBe(200);
        expect(app.socketAuthState.revision).toBe(1);
        expect(dashboard.disconnect).toHaveBeenCalledWith(true);
        expect(phone.disconnect).not.toHaveBeenCalled();
    });

    it('refuses to remove the organization from an admin', async () => {
        actor = SUPER;
        prismaMock.user.findFirst.mockResolvedValue(target({ id: 'admin-2', role: 'ADMIN' }));

        const res = await app.inject({
            method: 'PATCH', url: '/api/admin/users/admin-2', payload: { companyCode: null },
        });

        expect(res.statusCode).toBe(400);
        expect(prismaMock.user.update).not.toHaveBeenCalled();
    });

    it('does not remove an organization if the user was concurrently promoted', async () => {
        actor = SUPER;
        prismaMock.user.findFirst.mockResolvedValue(target());
        prismaMock.user.update.mockRejectedValueOnce(Object.assign(new Error('Record not found'), { code: 'P2025' }));

        const res = await app.inject({
            method: 'PATCH', url: '/api/admin/users/user-1', payload: { companyCode: null },
        });

        expect(res.statusCode).toBe(404);
        expect(prismaMock.user.update).toHaveBeenCalledWith({
            where: { id: 'user-1', role: 'USER' },
            data: { companyCode: null },
            include: { organization: true },
        });
    });

    it('conditions team profile edits on the target role and organization', async () => {
        prismaMock.user.findFirst.mockResolvedValue(target());

        const res = await app.inject({
            method: 'PATCH', url: '/api/admin/users/user-1', payload: { name: 'Changed' },
        });

        expect(res.statusCode).toBe(200);
        expect(prismaMock.user.update).toHaveBeenCalledWith({
            where: { id: 'user-1', companyCode: 'NEWS', role: 'USER' },
            data: { name: 'Changed' },
            include: { organization: true },
        });
    });
});
