// Last updated: May 9, 2026 - 8:22pm - GPT-5.3-Codex
import Fastify from 'fastify';
import cookie from '@fastify/cookie';
import fastifyJwt from '@fastify/jwt';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { hashPin } from '../lib/utils.js';

const prismaMock = {
    user: {
        findUnique: vi.fn(),
        findFirst: vi.fn(),
        update: vi.fn(),
    },
    asset: {
        findFirst: vi.fn(),
    },
    clip: {
        findFirst: vi.fn(),
        findMany: vi.fn(),
    },
    formResponse: {
        findFirst: vi.fn(),
    },
};

vi.mock('../lib/prisma.js', () => ({
    default: prismaMock,
}));

vi.mock('../lib/mux.js', () => ({
    MUX_ENV_KEY: 'test-env-key',
    isMuxEnabled: true,
}));

let clipRoutes;
let app;

beforeAll(async () => {
    ({ default: clipRoutes } = await import('../routes/clips.js'));
});

beforeEach(async () => {
    vi.clearAllMocks();

    prismaMock.user.findUnique.mockResolvedValue(null);
    prismaMock.user.findFirst.mockResolvedValue({ companyCode: 'NEWS' });
    prismaMock.user.update.mockResolvedValue({});

    prismaMock.asset.findFirst.mockResolvedValue(null);
    prismaMock.clip.findFirst.mockResolvedValue(null);
    prismaMock.clip.findMany.mockResolvedValue([]);
    prismaMock.formResponse.findFirst.mockResolvedValue(null);

    app = Fastify({ logger: false });
    await app.register(cookie);
    await app.register(fastifyJwt, { secret: 'test-clip-jwt-secret' });

    app.decorate('csrfProtection', async () => null);

    await app.register(clipRoutes);
});

afterEach(async () => {
    await app.close();
});

function authCookieFor(user) {
    prismaMock.user.findUnique.mockImplementation(async ({ where }) =>
        where.id === user.id ? { ...user, status: 'ACTIVE' } : null
    );
    const token = app.jwt.sign(user, { expiresIn: '7d' });
    return `fixer_clip_token=${token}`;
}

describe('clip routes deeper coverage', () => {
    it('redirects with an error when login fields are missing', async () => {
        const response = await app.inject({
            method: 'POST',
            url: '/clips/login',
            payload: {
                phoneNumber: '5055551234',
                pin: '1234',
            },
        });

        expect(response.statusCode).toBe(302);
        expect(response.headers.location).toContain('/clips/login?error=All%20fields%20are%20required');
    });

    it('rejects login when company code does not match', async () => {
        prismaMock.user.findUnique.mockResolvedValue({
            id: 'user-1',
            name: 'Reporter',
            phoneNumber: '5055551234',
            pinHash: await hashPin('1234'),
            status: 'ACTIVE',
            role: 'USER',
            companyCode: 'NEWS',
            organization: { companyName: 'News Org' },
        });

        const response = await app.inject({
            method: 'POST',
            url: '/clips/login',
            payload: {
                companyCode: 'WRNG',
                phoneNumber: '5055551234',
                pin: '1234',
                redirect: '/clips/100000001',
            },
        });

        expect(response.statusCode).toBe(302);
        expect(response.headers.location).toContain('Invalid%20credentials');
    });

    it('sets clip auth cookie and redirects on successful login', async () => {
        prismaMock.user.findUnique.mockResolvedValue({
            id: 'user-1',
            name: 'Reporter',
            phoneNumber: '5055551234',
            pinHash: await hashPin('1234'),
            status: 'ACTIVE',
            role: 'USER',
            companyCode: 'NEWS',
            organization: { companyName: 'News Org' },
        });

        const response = await app.inject({
            method: 'POST',
            url: '/clips/login',
            payload: {
                companyCode: 'news',
                phoneNumber: '5055551234',
                pin: '1234',
                redirect: '/clips/100000001',
            },
        });

        expect(response.statusCode).toBe(302);
        expect(response.headers.location).toBe('/clips/100000001');
        const setCookie = response.headers['set-cookie'];
        expect(setCookie).toContain('fixer_clip_token=');
    });

    it('requires auth cookie for status polling endpoint', async () => {
        const response = await app.inject({
            method: 'GET',
            url: '/clips/100000001/status',
        });

        expect(response.statusCode).toBe(401);
        expect(response.json()).toEqual({ error: 'Unauthorized' });
    });

    it('enforces organization access on status endpoint', async () => {
        const cookieHeader = authCookieFor({
            id: 'viewer-1',
            name: 'Viewer',
            role: 'USER',
            companyCode: 'NEWS',
        });

        prismaMock.asset.findFirst.mockResolvedValue({
            id: 'asset-1',
            mediasourceId: '100000001',
            status: 'PROCESSING',
            userId: 'uploader-1',
        });
        prismaMock.user.findFirst.mockResolvedValue({ companyCode: 'SPORT' });

        const response = await app.inject({
            method: 'GET',
            url: '/clips/100000001/status',
            headers: {
                cookie: cookieHeader,
            },
        });

        expect(response.statusCode).toBe(404);
        expect(response.json()).toEqual({ error: 'Not found' });
    });

    it('returns ready payload when mux playback id exists', async () => {
        const cookieHeader = authCookieFor({
            id: 'viewer-1',
            name: 'Viewer',
            role: 'SUPER_ADMIN',
            companyCode: null,
        });

        prismaMock.asset.findFirst.mockResolvedValue({
            id: 'asset-1',
            mediasourceId: '100000001',
            status: 'READY',
            userId: 'uploader-1',
        });
        prismaMock.user.findFirst.mockResolvedValue({ companyCode: 'SPORT' });
        prismaMock.clip.findFirst.mockResolvedValue({
            muxPlaybackId: 'playback-123',
            status: 'READY',
        });

        const response = await app.inject({
            method: 'GET',
            url: '/clips/100000001/status',
            headers: {
                cookie: cookieHeader,
            },
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual({
            ready: true,
            muxPlaybackId: 'playback-123',
            status: 'READY',
        });
    });

    it('redirects unauthenticated clip viewer requests to login', async () => {
        const response = await app.inject({
            method: 'GET',
            url: '/clips/100000001',
        });

        expect(response.statusCode).toBe(302);
        expect(response.headers.location).toContain('/clips/login?redirect=');
    });

    it('returns not found page for invalid mediasource id value', async () => {
        const cookieHeader = authCookieFor({
            id: 'viewer-1',
            name: 'Viewer',
            role: 'ADMIN',
            companyCode: null,
        });

        const response = await app.inject({
            method: 'GET',
            url: '/clips/undefined',
            headers: {
                cookie: cookieHeader,
            },
        });

        expect(response.statusCode).toBe(404);
        expect(response.body).toContain('Clip not found');
    });

    it('renders mux player view when clip has playback id', async () => {
        const cookieHeader = authCookieFor({
            id: 'viewer-1',
            name: 'Viewer',
            role: 'SUPER_ADMIN',
            companyCode: null,
        });

        prismaMock.asset.findFirst.mockResolvedValueOnce({
            id: 'asset-1',
            mediasourceId: '100000111',
            mediasourceUrl: '/clips/100000111',
            originalFileName: 'field-clip.mp4',
            status: 'READY',
            clipCount: 1,
            totalDuration: 42,
            createdAt: new Date('2026-05-09T00:00:00.000Z'),
            updatedAt: new Date('2026-05-09T00:10:00.000Z'),
            userId: 'uploader-1',
        });
        prismaMock.clip.findMany.mockResolvedValueOnce([
            {
                id: 'clip-1',
                status: 'READY',
                muxPlaybackId: 'playback-999',
                streamUrl: 'https://stream.mux.com/playback-999.m3u8',
                storageUrl: '/uploads/field-clip.mp4',
                duration: 42,
                resolution: '1920x1080',
                fileSize: 1000000,
                transcript: 'Reporter voice-over transcript',
                createdAt: new Date('2026-05-09T00:00:00.000Z'),
            },
        ]);
        prismaMock.formResponse.findFirst.mockResolvedValueOnce({
            id: 'form-1',
            slug: 'breaking-flood',
            type: 'Raw',
            priority: 'HIGH',
            description: 'River over bank',
            submittedAt: new Date('2026-05-09T00:02:00.000Z'),
        });
        prismaMock.user.findFirst.mockResolvedValueOnce({
            name: 'Uploader',
            team: 'Field',
            companyCode: 'NEWS',
            organization: { companyName: 'News Org' },
        });

        const response = await app.inject({
            method: 'GET',
            url: '/clips/100000111',
            headers: {
                cookie: cookieHeader,
            },
        });

        expect(response.statusCode).toBe(200);
        expect(response.body).toContain('<mux-player');
        expect(response.body).toContain('playback-id="playback-999"');
        expect(response.body).toContain('Context Form');
        expect(response.body).toContain('Reporter voice-over transcript');
        expect(response.body).toContain('breaking-flood');
    });

    it('renders processing placeholder and no-context banner when form is missing', async () => {
        const cookieHeader = authCookieFor({
            id: 'viewer-1',
            name: 'Viewer',
            role: 'SUPER_ADMIN',
            companyCode: null,
        });

        prismaMock.asset.findFirst.mockResolvedValueOnce({
            id: 'asset-2',
            mediasourceId: '100000777',
            mediasourceUrl: '/clips/100000777',
            originalFileName: 'overnight.mp4',
            status: 'READY',
            clipCount: 1,
            totalDuration: 0,
            createdAt: new Date('2026-05-09T01:00:00.000Z'),
            updatedAt: new Date('2026-05-09T01:05:00.000Z'),
            userId: 'uploader-2',
        });
        prismaMock.clip.findMany.mockResolvedValueOnce([
            {
                id: 'clip-2',
                status: 'PROCESSING',
                muxPlaybackId: null,
                createdAt: new Date('2026-05-09T01:00:00.000Z'),
            },
        ]);
        prismaMock.formResponse.findFirst.mockResolvedValueOnce(null);
        prismaMock.user.findFirst.mockResolvedValueOnce({
            name: 'Uploader',
            team: null,
            companyCode: 'NEWS',
            organization: { companyName: 'News Org' },
        });

        const response = await app.inject({
            method: 'GET',
            url: '/clips/100000777',
            headers: {
                cookie: cookieHeader,
            },
        });

        expect(response.statusCode).toBe(200);
        expect(response.body).toContain('Video Processing');
        expect(response.body).toContain('NO CONTEXT FORM');
        expect(response.body).toContain("fetch('/clips/' + mediasourceId + '/status')");
        expect(response.body).toContain('status-READY');
    });
});
