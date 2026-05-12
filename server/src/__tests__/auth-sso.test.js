// Last updated: May 12, 2026 - 3:52pm - GitHub Copilot (GPT-5.3-Codex)
import Fastify from 'fastify';
import cookie from '@fastify/cookie';
import formbody from '@fastify/formbody';
import fastifyJwt from '@fastify/jwt';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = {
    organization: {
        findUnique: vi.fn(),
    },
    user: {
        findUnique: vi.fn(),
        findFirst: vi.fn(),
        create: vi.fn(),
        update: vi.fn(),
    },
};

const sessionStoreMock = {
    createSession: vi.fn(),
};

vi.mock('../lib/prisma.js', () => ({
    default: prismaMock,
}));

vi.mock('../lib/session-store.js', () => ({
    createSession: sessionStoreMock.createSession,
}));

let authSsoRoutes;
let app;

beforeAll(async () => {
    ({ default: authSsoRoutes } = await import('../routes/auth-sso.js'));
});

beforeEach(async () => {
    vi.clearAllMocks();

    prismaMock.organization.findUnique.mockResolvedValue(null);
    prismaMock.user.findUnique.mockResolvedValue(null);
    prismaMock.user.findFirst.mockResolvedValue(null);
    prismaMock.user.create.mockResolvedValue({
        id: 'user-sso-1',
        name: 'SSO User',
        phoneNumber: '9555123456',
        email: 'sso@example.com',
        team: null,
        role: 'EDITOR',
        companyCode: 'NEWS',
        status: 'ACTIVE',
    });
    prismaMock.user.update.mockResolvedValue({
        id: 'user-sso-1',
        name: 'SSO User',
        phoneNumber: '9555123456',
        email: 'sso@example.com',
        team: null,
        role: 'EDITOR',
        companyCode: 'NEWS',
        status: 'ACTIVE',
    });

    sessionStoreMock.createSession.mockResolvedValue(undefined);

    app = Fastify({ logger: false });
    await app.register(cookie);
    await app.register(formbody);
    await app.register(fastifyJwt, { secret: 'test-jwt-secret' });
    await app.register(authSsoRoutes);
});

afterEach(async () => {
    await app.close();
});

describe('auth sso routes', () => {
    it('returns service provider metadata xml', async () => {
        const response = await app.inject({
            method: 'GET',
            url: '/api/auth/sso/metadata',
        });

        expect(response.statusCode).toBe(200);
        expect(response.headers['content-type']).toContain('application/samlmetadata+xml');
        expect(response.body).toContain('EntityDescriptor');
        expect(response.body).toContain('AssertionConsumerService');
    });

    it('returns org sso config', async () => {
        prismaMock.organization.findUnique.mockResolvedValueOnce({
            companyCode: 'NEWS',
            companyName: 'News Org',
            ssoEnabled: true,
            samlMetadataUrl: 'https://idp.example.com/metadata',
            samlEntityId: 'urn:news:idp',
            samlAttributeMapping: { email: 'mail' },
        });

        const response = await app.inject({
            method: 'GET',
            url: '/api/auth/sso/config/NEWS',
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual(expect.objectContaining({
            companyCode: 'NEWS',
            ssoEnabled: true,
            samlEntityId: 'urn:news:idp',
        }));
    });

    it('redirects to dev sso login in non-production', async () => {
        prismaMock.organization.findUnique.mockResolvedValueOnce({
            companyCode: 'NEWS',
            companyName: 'News Org',
            ssoEnabled: true,
            samlMetadataUrl: 'https://idp.example.com/metadata',
        });

        const response = await app.inject({
            method: 'GET',
            url: '/api/auth/sso/start?companyCode=NEWS',
        });

        expect(response.statusCode).toBe(302);
        expect(response.headers.location).toContain('/api/auth/sso/dev-login?state=');
    });

    it('creates a session token from sso callback', async () => {
        prismaMock.organization.findUnique.mockResolvedValueOnce({
            companyCode: 'NEWS',
            companyName: 'News Org',
            ssoEnabled: true,
            samlAttributeMapping: null,
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/auth/sso/saml',
            payload: {
                companyCode: 'NEWS',
                email: 'reporter@example.com',
                name: 'Reporter',
            },
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual(expect.objectContaining({
            token: expect.any(String),
            user: expect.objectContaining({
                companyCode: 'NEWS',
                role: 'EDITOR',
            }),
        }));
        expect(sessionStoreMock.createSession).toHaveBeenCalledTimes(1);
    });
});
