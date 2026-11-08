// Last updated: May 9, 2026 - 8:23pm - GPT-5.3-Codex
import Fastify from 'fastify';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = {
    $transaction: vi.fn(),
    $queryRaw: vi.fn(),
    clip: {
        findFirst: vi.fn(),
        findUnique: vi.fn(),
        update: vi.fn(),
    },
    asset: {
        update: vi.fn(),
        findUnique: vi.fn(),
    },
};

const muxLibMock = {
    disableMuxPlayback: vi.fn(),
    getMuxAsset: vi.fn(),
    getMuxUpload: vi.fn(),
};

const fsMock = {
    unlink: vi.fn(),
};

const verifySignatureMock = vi.fn();

vi.mock('../lib/prisma.js', () => ({
    default: prismaMock,
}));

vi.mock('../lib/mux.js', () => ({
    disableMuxPlayback: muxLibMock.disableMuxPlayback,
    getMuxAsset: muxLibMock.getMuxAsset,
    getMuxUpload: muxLibMock.getMuxUpload,
    MUX_ENV_KEY: 'env-key-123',
}));

vi.mock('fs/promises', () => ({
    unlink: fsMock.unlink,
    default: fsMock,
}));

vi.mock('@mux/mux-node', () => ({
    default: class MockMux {
        constructor() {
            this.webhooks = {
                verifySignature: verifySignatureMock,
            };
        }
    },
}));

let app;
let ioEmitSpy;
let actor;

async function buildApp(secret = 'mux-webhook-secret') {
    if (secret === undefined) {
        delete process.env.MUX_WEBHOOK_SECRET;
    } else {
        process.env.MUX_WEBHOOK_SECRET = secret;
    }

    vi.resetModules();
    const { default: muxWebhookRoutes } = await import('../routes/mux-webhooks.js');

    ioEmitSpy = vi.fn();
    app = Fastify({ logger: false });

    app.decorate('authenticate', async (request, reply) => {
        if (!actor) return reply.status(401).send({ error: 'Unauthorized' });
        request.user = actor;
    });
    app.decorate('io', {
        to: vi.fn(() => ({ emit: ioEmitSpy })),
    });
    app.decorate('userSockets', new Map([['user-1', new Set(['socket-1'])]]));

    await app.register(muxWebhookRoutes);
}

beforeEach(() => {
    vi.clearAllMocks();
    actor = { id: 'user-1', role: 'USER' };

    prismaMock.$transaction.mockImplementation(async callback => callback(prismaMock));
    prismaMock.$queryRaw.mockResolvedValue([{ moderation: 'ACTIVE' }]);
    prismaMock.clip.findFirst.mockResolvedValue(null);
    prismaMock.clip.findUnique.mockResolvedValue(null);
    prismaMock.clip.update.mockResolvedValue({});
    prismaMock.asset.update.mockResolvedValue({});
    prismaMock.asset.findUnique.mockResolvedValue(null);

    muxLibMock.getMuxAsset.mockResolvedValue(null);
    muxLibMock.getMuxUpload.mockResolvedValue(null);
    muxLibMock.disableMuxPlayback.mockResolvedValue({ ok: true });

    fsMock.unlink.mockResolvedValue(undefined);
    verifySignatureMock.mockReturnValue(undefined);
});

afterEach(async () => {
    if (app) {
        await app.close();
        app = null;
    }
});

describe('mux-webhooks routes focused coverage', () => {
    it('returns 500 when webhook secret is missing', async () => {
        await buildApp('');

        const response = await app.inject({
            method: 'POST',
            url: '/api/webhooks/mux',
            headers: {
                'mux-signature': 'sig-1',
            },
            payload: {
                type: 'video.upload.asset_created',
                data: { id: 'upload-1', asset_id: 'mux-1' },
            },
        });

        expect(response.statusCode).toBe(500);
        expect(response.json()).toEqual({ error: 'Webhook signature verification not configured' });
    });

    it('returns 401 when mux signature header is missing', async () => {
        await buildApp();

        const response = await app.inject({
            method: 'POST',
            url: '/api/webhooks/mux',
            payload: {
                type: 'video.upload.asset_created',
                data: { id: 'upload-1', asset_id: 'mux-1' },
            },
        });

        expect(response.statusCode).toBe(401);
        expect(response.json()).toEqual({ error: 'Missing signature' });
    });

    it('returns 401 when signature verification fails', async () => {
        verifySignatureMock.mockImplementationOnce(() => {
            throw new Error('bad signature');
        });
        await buildApp();

        const response = await app.inject({
            method: 'POST',
            url: '/api/webhooks/mux',
            headers: {
                'mux-signature': 'sig-bad',
            },
            payload: {
                type: 'video.upload.asset_created',
                data: { id: 'upload-1', asset_id: 'mux-1' },
            },
        });

        expect(response.statusCode).toBe(401);
        expect(response.json()).toEqual({ error: 'Invalid signature' });
    });

    it('links mux asset to clip on video.upload.asset_created', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce({ id: 'clip-1' });

        const response = await app.inject({
            method: 'POST',
            url: '/api/webhooks/mux',
            headers: {
                'mux-signature': 'sig-ok',
            },
            payload: {
                type: 'video.upload.asset_created',
                data: {
                    id: 'upload-1',
                    asset_id: 'mux-asset-1',
                },
            },
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual({ received: true });
        expect(prismaMock.clip.findFirst).toHaveBeenCalledWith({ where: { muxUploadId: 'upload-1' } });
        expect(prismaMock.clip.update).toHaveBeenCalledWith({
            where: { id: 'clip-1' },
            data: { muxAssetId: 'mux-asset-1' },
        });
    });

    it('handles ready event with passthrough clip lookup and owner socket emit', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce(null);
        prismaMock.clip.findUnique.mockResolvedValueOnce({
            id: 'clip-fallback',
            assetId: 'asset-1',
            duration: 12,
            resolution: '1920x1080',
            fileSize: 1234,
            storageUrl: '/uploads/test-clip.mp4',
        });
        prismaMock.asset.findUnique.mockResolvedValueOnce({
            id: 'asset-1',
            userId: 'user-1',
            moderation: 'ACTIVE',
            mediasourceId: '100000001',
            originalFileName: 'field.mp4',
            formResponse: {
                slug: 'storm-night',
                type: 'Raw',
                description: 'Heavy wind',
                priority: 'HIGH',
            },
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/webhooks/mux',
            headers: {
                'mux-signature': 'sig-ok',
            },
            payload: {
                type: 'video.asset.ready',
                data: {
                    id: 'mux-ready-1',
                    playback_ids: [{ policy: 'public', id: 'playback-1' }],
                    passthrough: JSON.stringify({ clipId: 'clip-fallback' }),
                },
            },
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.clip.update).toHaveBeenCalledWith({
            where: { id: 'clip-fallback' },
            data: {
                muxAssetId: 'mux-ready-1',
                muxPlaybackId: 'playback-1',
                streamUrl: 'https://stream.mux.com/playback-1.m3u8',
                thumbnailUrl: 'https://image.mux.com/playback-1/thumbnail.png?width=640',
                status: 'READY',
            },
        });
        expect(prismaMock.asset.update).toHaveBeenCalledWith({
            where: { id: 'asset-1' },
            data: { status: 'READY' },
        });
        expect(fsMock.unlink).toHaveBeenCalledWith(expect.stringContaining('/uploads/test-clip.mp4'));
        expect(ioEmitSpy).toHaveBeenCalledWith(
            'mux:ready',
            expect.objectContaining({
                assetId: 'asset-1',
                clipId: 'clip-fallback',
                muxPlaybackId: 'playback-1',
                mediasourceId: '100000001',
            })
        );
    });

    it('revokes playback instead of exposing a ready event for a paused asset', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce({
            id: 'clip-paused',
            assetId: 'asset-paused',
            storageUrl: null,
        });
        prismaMock.$queryRaw.mockResolvedValueOnce([{ moderation: 'PAUSED' }]);

        const response = await app.inject({
            method: 'POST',
            url: '/api/webhooks/mux',
            headers: { 'mux-signature': 'sig-ok' },
            payload: {
                type: 'video.asset.ready',
                data: {
                    id: 'mux-paused',
                    playback_ids: [{ policy: 'public', id: 'public-paused-id' }],
                },
            },
        });

        expect(response.statusCode).toBe(200);
        expect(muxLibMock.disableMuxPlayback).toHaveBeenCalledWith('mux-paused');
        expect(prismaMock.clip.update).toHaveBeenCalledWith({
            where: { id: 'clip-paused' },
            data: {
                muxAssetId: 'mux-paused',
                muxPlaybackId: null,
                streamUrl: null,
                thumbnailUrl: null,
                status: 'READY',
            },
        });
        expect(ioEmitSpy).not.toHaveBeenCalled();
    });

    it('handles mux asset errored events by setting clip and asset to ERROR', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce({
            id: 'clip-err',
            assetId: 'asset-err',
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/webhooks/mux',
            headers: {
                'mux-signature': 'sig-ok',
            },
            payload: {
                type: 'video.asset.errored',
                data: {
                    id: 'mux-err-1',
                    errors: [{ type: 'video', messages: ['encode failed'] }],
                },
            },
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.clip.update).toHaveBeenCalledWith({
            where: { id: 'clip-err' },
            data: { status: 'ERROR' },
        });
        expect(prismaMock.asset.update).toHaveBeenCalledWith({
            where: { id: 'asset-err' },
            data: { status: 'ERROR' },
        });
    });

    it('returns 404 from status endpoint when clip is not found', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce(null);

        const response = await app.inject({
            method: 'GET',
            url: '/api/mux/status/clip-missing',
        });

        expect(response.statusCode).toBe(404);
        expect(response.json()).toEqual({ error: 'Clip not found' });
        expect(prismaMock.clip.findFirst).toHaveBeenCalledWith(expect.objectContaining({
            where: { id: 'clip-missing', asset: { userId: 'user-1', moderation: 'ACTIVE' } },
        }));
    });

    it('requires authentication before reading a clip status', async () => {
        await buildApp();
        actor = null;

        const response = await app.inject({ method: 'GET', url: '/api/mux/status/clip-1' });

        expect(response.statusCode).toBe(401);
        expect(prismaMock.clip.findFirst).not.toHaveBeenCalled();
    });

    it('limits a team admin status lookup to their organization', async () => {
        await buildApp();
        actor = { id: 'admin-1', role: 'ADMIN', companyCode: 'NEWS' };
        prismaMock.clip.findFirst.mockResolvedValueOnce(null);

        const response = await app.inject({ method: 'GET', url: '/api/mux/status/clip-other' });

        expect(response.statusCode).toBe(404);
        expect(prismaMock.clip.findFirst).toHaveBeenCalledWith(expect.objectContaining({
            where: { id: 'clip-other', asset: { user: { companyCode: 'NEWS' }, moderation: 'ACTIVE' } },
        }));
    });

    it('promotes processing clip to ready via upload and asset checks', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce({
            id: 'clip-status-1',
            assetId: 'asset-status-1',
            muxAssetId: null,
            muxPlaybackId: null,
            muxUploadId: 'upload-status-1',
            streamUrl: null,
            thumbnailUrl: null,
            status: 'PROCESSING',
        });
        muxLibMock.getMuxUpload.mockResolvedValueOnce({ asset_id: 'mux-status-1' });
        muxLibMock.getMuxAsset.mockResolvedValueOnce({
            status: 'ready',
            playback_ids: [{ policy: 'public', id: 'playback-status-1' }],
        });

        const response = await app.inject({
            method: 'GET',
            url: '/api/mux/status/clip-status-1',
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.clip.update).toHaveBeenNthCalledWith(1, {
            where: { id: 'clip-status-1' },
            data: { muxAssetId: 'mux-status-1' },
        });
        expect(prismaMock.clip.update).toHaveBeenNthCalledWith(2, {
            where: { id: 'clip-status-1' },
            data: {
                muxPlaybackId: 'playback-status-1',
                streamUrl: 'https://stream.mux.com/playback-status-1.m3u8',
                thumbnailUrl: 'https://image.mux.com/playback-status-1/thumbnail.png?width=640',
                status: 'READY',
            },
        });
        expect(prismaMock.asset.update).toHaveBeenCalledWith({
            where: { id: 'asset-status-1' },
            data: { status: 'READY' },
        });
        expect(response.json()).toEqual({
            status: 'ready',
            muxPlaybackId: 'playback-status-1',
            streamUrl: 'https://stream.mux.com/playback-status-1.m3u8',
            thumbnailUrl: 'https://image.mux.com/playback-status-1/thumbnail.png?width=640',
        });
    });

    it('returns processing status when clip is still in progress', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce({
            id: 'clip-processing',
            assetId: 'asset-processing',
            muxAssetId: null,
            muxPlaybackId: null,
            muxUploadId: null,
            streamUrl: null,
            thumbnailUrl: null,
            status: 'PROCESSING',
        });

        const response = await app.inject({
            method: 'GET',
            url: '/api/mux/status/clip-processing',
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual({ status: 'processing' });
    });
});
