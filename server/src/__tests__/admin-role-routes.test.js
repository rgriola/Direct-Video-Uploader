import Fastify from 'fastify';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = {
    user: {
        findUnique: vi.fn(),
        update: vi.fn(),
    },
    organization: {
        findUnique: vi.fn(),
    },
};

vi.mock('../lib/prisma.js', () => ({ default: prismaMock }));
vi.mock('../lib/mux.js', () => ({ isMuxEnabled: false, deleteMuxAsset: vi.fn() }));

let adminRoutes;
let isAdminRole;
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
    ({ isAdminRole } = await import('../lib/roles.js'));
});

beforeEach(async () => {
    vi.clearAllMocks();
    actor = TEAM_ADMIN;
    prismaMock.user.update.mockImplementation(async ({ where, data }) => ({
        id: where.id, name: 'Pat Reporter', companyCode: 'NEWS', ...data,
    }));

    app = Fastify({ logger: false });
    app.decorate('authenticate', async (request) => {
        request.user = { ...actor };
    });
    app.decorate('authorizeAdmin', async (request, reply) => {
        if (!isAdminRole(request.user?.role)) {
            return reply.status(403).send({ error: 'Admin access required' });
        }
    });
    app.decorate('io', { of: () => ({ sockets: new Map() }) });
    app.decorate('userSockets', new Map());
    app.decorate('iosSockets', new Set());
    app.decorate('adminSockets', new Set());
    await app.register(adminRoutes);
});

afterEach(async () => {
    await app.close();
});

describe('PATCH /api/admin/users/:id/role', () => {
    it('lets a team admin promote a user in their organization', async () => {
        prismaMock.user.findUnique.mockResolvedValue(target());

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(200);
        expect(res.json().user.role).toBe('ADMIN');
        expect(prismaMock.user.update).toHaveBeenCalledWith(expect.objectContaining({
            where: { id: 'user-1' },
            data: { role: 'ADMIN' },
        }));
    });

    it('lets a team admin demote another team admin in their organization', async () => {
        prismaMock.user.findUnique.mockResolvedValue(target({ id: 'admin-2', role: 'ADMIN' }));

        const res = await patchRole('admin-2', { role: 'USER' });

        expect(res.statusCode).toBe(200);
        expect(res.json().user.role).toBe('USER');
    });

    it('matches organizations case-insensitively', async () => {
        prismaMock.user.findUnique.mockResolvedValue(target({ companyCode: 'news' }));

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(200);
    });

    it('returns 404 when a team admin targets another organization', async () => {
        prismaMock.user.findUnique.mockResolvedValue(target({ companyCode: 'OTHER' }));

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(404);
        expect(prismaMock.user.update).not.toHaveBeenCalled();
    });

    it('returns 404 when a team admin targets a user with no organization', async () => {
        prismaMock.user.findUnique.mockResolvedValue(target({ companyCode: null }));

        const res = await patchRole('user-1', { role: 'USER' });

        expect(res.statusCode).toBe(404);
    });

    it('returns 404 for an unknown user', async () => {
        prismaMock.user.findUnique.mockResolvedValue(null);

        const res = await patchRole('missing', { role: 'ADMIN' });

        expect(res.statusCode).toBe(404);
    });

    it('lets the super admin change roles in any organization', async () => {
        actor = SUPER;
        prismaMock.user.findUnique.mockResolvedValue(target({ companyCode: 'OTHER' }));

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(200);
    });

    it('rejects granting SUPER_ADMIN through the API', async () => {
        actor = SUPER;
        prismaMock.user.findUnique.mockResolvedValue(target());

        const res = await patchRole('user-1', { role: 'SUPER_ADMIN' });

        expect(res.statusCode).toBe(400);
        expect(prismaMock.user.update).not.toHaveBeenCalled();
    });

    it('rejects a missing or unknown role', async () => {
        prismaMock.user.findUnique.mockResolvedValue(target());

        expect((await patchRole('user-1', {})).statusCode).toBe(400);
        expect((await patchRole('user-1', { role: 'OWNER' })).statusCode).toBe(400);
        expect(prismaMock.user.update).not.toHaveBeenCalled();
    });

    it("refuses to change the super admin's role", async () => {
        actor = SUPER;
        prismaMock.user.findUnique.mockResolvedValue(target({ id: 'super-2', role: 'SUPER_ADMIN' }));

        const res = await patchRole('super-2', { role: 'USER' });

        expect(res.statusCode).toBe(403);
        expect(prismaMock.user.update).not.toHaveBeenCalled();
    });

    it('refuses to let an admin change their own role', async () => {
        prismaMock.user.findUnique.mockResolvedValue(target({ id: 'admin-1', role: 'ADMIN' }));

        const res = await patchRole('admin-1', { role: 'USER' });

        expect(res.statusCode).toBe(400);
        expect(prismaMock.user.update).not.toHaveBeenCalled();
    });

    it('requires an organization before promoting to ADMIN', async () => {
        actor = SUPER;
        prismaMock.user.findUnique.mockResolvedValue(target({ companyCode: null }));

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(400);
        expect(prismaMock.user.update).not.toHaveBeenCalled();
    });

    it('does not write when the role is unchanged', async () => {
        prismaMock.user.findUnique.mockResolvedValue(target({ role: 'ADMIN', id: 'admin-2' }));

        const res = await patchRole('admin-2', { role: 'ADMIN' });

        expect(res.statusCode).toBe(200);
        expect(prismaMock.user.update).not.toHaveBeenCalled();
    });

    it('rejects non-admin callers', async () => {
        actor = { id: 'user-9', sub: 'user-9', role: 'USER', companyCode: 'NEWS' };

        const res = await patchRole('user-1', { role: 'ADMIN' });

        expect(res.statusCode).toBe(403);
        expect(prismaMock.user.findUnique).not.toHaveBeenCalled();
    });
});

describe('PATCH /api/admin/users/:id organization guard', () => {
    it('refuses to remove the organization from an admin', async () => {
        prismaMock.user.findUnique.mockResolvedValue(target({ id: 'admin-2', role: 'ADMIN' }));

        const res = await app.inject({
            method: 'PATCH', url: '/api/admin/users/admin-2', payload: { companyCode: null },
        });

        expect(res.statusCode).toBe(400);
        expect(prismaMock.user.update).not.toHaveBeenCalled();
    });
});
