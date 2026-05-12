// Last updated: May 12, 2026 - 3:52pm - GitHub Copilot (GPT-5.3-Codex)
import Fastify from 'fastify';
import fastifyJwt from '@fastify/jwt';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { hashPin, hashPinLegacy } from '../lib/utils.js';

const prismaMock = {
    organization: {
        findUnique: vi.fn(),
    },
    user: {
        findUnique: vi.fn(),
        update: vi.fn(),
    },
    errorLog: {
        create: vi.fn(),
        findMany: vi.fn(),
    },
};

vi.mock('../lib/prisma.js', () => ({
    default: prismaMock,
}));

let authRoutes;
let errorRoutes;

/** @type {import('fastify').FastifyInstance} */
let app;

beforeAll(async () => {
    ({ default: authRoutes } = await import('../routes/auth.js'));
    ({ default: errorRoutes } = await import('../routes/errors.js'));
});

beforeEach(async () => {
    vi.clearAllMocks();
    prismaMock.organization.findUnique.mockResolvedValue(null);

    app = Fastify({ logger: false });
    await app.register(fastifyJwt, { secret: 'test-jwt-secret' });

    app.decorate('authenticate', async (request) => {
        request.user = { id: 'user-1', role: 'SUPER_ADMIN', companyCode: 'NEWS' };
    });

    app.decorate('authorizeAdmin', async (request, reply) => {
        if (request.user?.role !== 'SUPER_ADMIN') {
            return reply.status(403).send({ error: 'Admin access required' });
        }
    });

    app.decorate('authorizeOrgAdmin', async (request, reply) => {
        if (!['SUPER_ADMIN', 'ORG_ADMIN'].includes(request.user?.role || '')) {
            return reply.status(403).send({ error: 'Admin access required' });
        }
    });

    await app.register(authRoutes);
    await app.register(errorRoutes);
});

afterEach(async () => {
    await app.close();
});

describe('auth routes behavior', () => {
    it('rejects login when user is not found', async () => {
        prismaMock.user.findUnique.mockResolvedValue(null);

        const response = await app.inject({
            method: 'POST',
            url: '/api/auth/login',
            payload: { phoneNumber: '5055551111', pin: '1234' },
        });

        expect(response.statusCode).toBe(401);
        expect(response.json()).toEqual({ error: 'Invalid credentials' });
    });

    it('requires company code for non-admin logins', async () => {
        prismaMock.user.findUnique.mockResolvedValue({
            id: 'user-1',
            name: 'David',
            phoneNumber: '5055551111',
            pinHash: await hashPin('1234'),
            status: 'ACTIVE',
            role: 'EDITOR',
            companyCode: 'NEWS',
            organization: { companyName: 'News Org' },
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/auth/login',
            payload: { phoneNumber: '5055551111', pin: '1234' },
        });

        expect(response.statusCode).toBe(401);
        expect(response.json()).toEqual({ error: 'Company code is required' });
    });

    it('requires SSO flow when company is SSO-enabled', async () => {
        prismaMock.organization.findUnique.mockResolvedValueOnce({
            companyCode: 'NEWS',
            ssoEnabled: true,
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/auth/login',
            payload: { phoneNumber: '5055551111', pin: '1234', companyCode: 'NEWS' },
        });

        expect(response.statusCode).toBe(409);
        expect(response.json()).toEqual({
            error: 'SSO required for this organization',
            code: 'SSO_REQUIRED',
            ssoStartUrl: '/api/auth/sso/start?companyCode=NEWS',
        });
    });

    it('does not allow non-admin users to bypass company code by setting clientType=admin', async () => {
        prismaMock.user.findUnique.mockResolvedValue({
            id: 'user-2',
            name: 'Field User',
            phoneNumber: '5055552222',
            pinHash: await hashPin('1234'),
            status: 'ACTIVE',
            role: 'EDITOR',
            companyCode: 'NEWS',
            organization: { companyName: 'News Org' },
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/auth/login',
            payload: {
                phoneNumber: '5055552222',
                pin: '1234',
                clientType: 'admin',
            },
        });

        expect(response.statusCode).toBe(401);
        expect(response.json()).toEqual({ error: 'Company code is required' });
    });

    it('allows admin login without company code and includes role in JWT payload', async () => {
        prismaMock.user.findUnique.mockResolvedValue({
            id: 'admin-1',
            name: 'Admin User',
            phoneNumber: '8001234567',
            pinHash: await hashPin('0000'),
            status: 'ACTIVE',
            role: 'SUPER_ADMIN',
            companyCode: null,
            team: 'Ops',
            organization: null,
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/auth/login',
            payload: {
                phoneNumber: '8001234567',
                pin: '0000',
                clientType: 'admin',
            },
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.user.update).not.toHaveBeenCalled();

        const body = response.json();
        const decoded = app.jwt.verify(body.token);
        expect(decoded.role).toBe('SUPER_ADMIN');
        expect(body.user.companyName).toBeNull();
    });

    it('auto-migrates legacy sha256 pin hashes to bcrypt and updates login timestamp', async () => {
        prismaMock.user.findUnique.mockResolvedValue({
            id: 'user-legacy',
            name: 'Legacy User',
            phoneNumber: '5051112222',
            pinHash: hashPinLegacy('1234'),
            status: 'ACTIVE',
            role: 'EDITOR',
            companyCode: 'NEWS',
            team: 'Field',
            organization: { companyName: 'News Org' },
        });
        prismaMock.user.update.mockResolvedValue({});

        const response = await app.inject({
            method: 'POST',
            url: '/api/auth/login',
            payload: {
                phoneNumber: '5051112222',
                pin: '1234',
                companyCode: 'news',
            },
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.user.update).toHaveBeenCalledTimes(2);

        const migrationCall = prismaMock.user.update.mock.calls.find(
            ([arg]) => typeof arg?.data?.pinHash === 'string'
        );
        const loginCall = prismaMock.user.update.mock.calls.find(
            ([arg]) => arg?.data?.lastLoginAt instanceof Date
        );

        expect(migrationCall).toBeTruthy();
        expect(migrationCall[0].data.pinHash.startsWith('$2')).toBe(true);
        expect(loginCall).toBeTruthy();
    });

    it('returns flattened companyName from /api/auth/me', async () => {
        prismaMock.user.findUnique.mockResolvedValue({
            id: 'user-1',
            name: 'David',
            phoneNumber: '5055551111',
            email: 'david@example.com',
            team: 'Field',
            role: 'EDITOR',
            status: 'ACTIVE',
            companyCode: 'NEWS',
            createdAt: new Date('2026-05-09T00:00:00.000Z'),
            organization: { companyName: 'News Org' },
        });

        const response = await app.inject({
            method: 'GET',
            url: '/api/auth/me',
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual({
            user: {
                id: 'user-1',
                name: 'David',
                phoneNumber: '5055551111',
                email: 'david@example.com',
                team: 'Field',
                role: 'EDITOR',
                status: 'ACTIVE',
                companyCode: 'NEWS',
                createdAt: '2026-05-09T00:00:00.000Z',
                companyName: 'News Org',
            },
        });
    });
});

describe('error routes behavior', () => {
    it('rejects missing required fields', async () => {
        const response = await app.inject({
            method: 'POST',
            url: '/api/errors',
            payload: { source: 'ios' },
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual({
            error: 'Missing required fields: source, category, message',
        });
        expect(prismaMock.errorLog.create).not.toHaveBeenCalled();
    });

    it('persists an error log with request correlation context', async () => {
        prismaMock.errorLog.create.mockResolvedValue({
            id: 'err-1',
            createdAt: new Date('2026-05-09T01:00:00.000Z'),
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/errors',
            payload: {
                source: 'ios',
                category: 'upload',
                message: 'failed to upload',
                details: { step: 'mux-upload' },
                severity: 'critical',
                assetId: 'asset-1',
            },
        });

        expect(response.statusCode).toBe(200);

        const createArg = prismaMock.errorLog.create.mock.calls[0][0];
        expect(createArg.data.userId).toBe('user-1');
        expect(createArg.data.assetId).toBe('asset-1');
        expect(createArg.data.severity).toBe('CRITICAL');
        expect(createArg.data.details.step).toBe('mux-upload');
        expect(typeof createArg.data.details.requestId).toBe('string');

        expect(response.json()).toEqual({
            errorLog: {
                id: 'err-1',
                createdAt: '2026-05-09T01:00:00.000Z',
            },
        });
    });

    it('returns latest errors for admin dashboard endpoint', async () => {
        prismaMock.errorLog.findMany.mockResolvedValue([{ id: 'err-1' }, { id: 'err-2' }]);

        const response = await app.inject({
            method: 'GET',
            url: '/api/admin/errors',
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual({ errors: [{ id: 'err-1' }, { id: 'err-2' }] });
        expect(prismaMock.errorLog.findMany).toHaveBeenCalledWith({
            where: {},
            orderBy: { createdAt: 'desc' },
            take: 50,
        });
    });
});
