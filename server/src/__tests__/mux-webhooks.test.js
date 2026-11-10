import Fastify from 'fastify';
import { Writable } from 'node:stream';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = {
    $transaction: vi.fn(),
    clip: {
        findFirst: vi.fn(),
        findUnique: vi.fn(),
        updateMany: vi.fn(),
    },
    muxAssetReference: { findUnique: vi.fn() },
};
const queueAssetMediaSync = vi.fn();
const recordMuxAssetReference = vi.fn();
const reconcileAssetMedia = vi.fn();
const verifySignatureMock = vi.fn();

vi.mock('../lib/prisma.js', () => ({ default: prismaMock }));
vi.mock('../lib/mux.js', () => ({ MUX_ENV_KEY: 'env-key-123' }));
vi.mock('../lib/media-reconciliation.js', () => ({
    queueAssetMediaSync,
    recordMuxAssetReference,
    reconcileAssetMedia,
}));
vi.mock('@mux/mux-node', () => ({
    default: class MockMux {
        constructor() {
            this.webhooks = { verifySignature: verifySignatureMock };
        }
    },
}));

let app;
let actor;

async function buildApp(secret = 'mux-webhook-secret', logger = false) {
    process.env.MUX_WEBHOOK_SECRET = secret;
    vi.resetModules();
    const { default: muxWebhookRoutes } = await import('../routes/mux-webhooks.js');
    app = Fastify({ logger });
    app.decorate('authenticate', async (request, reply) => {
        if (!actor) return reply.status(401).send({ error: 'Unauthorized' });
        request.user = actor;
    });
    await app.register(muxWebhookRoutes);
}

function webhook(type, data) {
    return app.inject({
        method: 'POST',
        url: '/api/webhooks/mux',
        headers: { 'mux-signature': 'sig-ok' },
        payload: { type, data },
    });
}

function statusClip(overrides = {}) {
    return {
        id: 'clip-1',
        assetId: 'asset-1',
        muxAssetId: 'mux-1',
        muxUploadId: 'upload-1',
        muxPlaybackId: null,
        streamUrl: null,
        thumbnailUrl: null,
        status: 'PROCESSING',
        asset: { mediaPlaybackReset: false, mediaCreateOperationId: null, mediaSyncState: 'PENDING' },
        ...overrides,
    };
}

beforeEach(() => {
    vi.clearAllMocks();
    actor = { id: 'user-1', role: 'USER' };
    prismaMock.$transaction.mockImplementation(async callback => callback(prismaMock));
    prismaMock.clip.findFirst.mockResolvedValue(null);
    prismaMock.clip.findUnique.mockResolvedValue(null);
    prismaMock.clip.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.muxAssetReference.findUnique.mockResolvedValue(null);
    queueAssetMediaSync.mockResolvedValue({ count: 1 });
    recordMuxAssetReference.mockResolvedValue(undefined);
    reconcileAssetMedia.mockResolvedValue({ state: 'SYNCED' });
    verifySignatureMock.mockReturnValue(undefined);
});

afterEach(async () => {
    await app?.close();
    app = null;
});

describe('Mux webhook verification and reconciliation', () => {
    it('rejects webhooks when the secret or signature is missing', async () => {
        await buildApp('');
        expect((await webhook('video.asset.ready', { id: 'mux-1' })).statusCode).toBe(500);
        await app.close();
        await buildApp();
        expect((await app.inject({
            method: 'POST',
            url: '/api/webhooks/mux',
            payload: { type: 'video.asset.ready', data: { id: 'mux-1' } },
        })).statusCode).toBe(401);
    });

    it('rejects an invalid signature before touching media', async () => {
        await buildApp();
        verifySignatureMock.mockImplementationOnce(() => { throw new Error('bad signature'); });
        expect((await webhook('video.asset.ready', { id: 'mux-1' })).statusCode).toBe(401);
        expect(queueAssetMediaSync).not.toHaveBeenCalled();
    });

    it('records an upload-created reference and queues it transactionally', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce({ id: 'clip-1', assetId: 'asset-1' });
        const response = await webhook('video.upload.asset_created', { id: 'upload-1', asset_id: 'mux-1' });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.$transaction).toHaveBeenCalledTimes(1);
        expect(queueAssetMediaSync).toHaveBeenCalledWith(prismaMock, 'asset-1');
        expect(recordMuxAssetReference).toHaveBeenCalledWith(prismaMock, {
            assetId: 'asset-1', clipId: 'clip-1', muxAssetId: 'mux-1',
        });
        expect(prismaMock.clip.updateMany).toHaveBeenCalledWith({
            where: { id: 'clip-1', assetId: 'asset-1', OR: [{ muxAssetId: null }, { muxAssetId: 'mux-1' }] },
            data: { muxAssetId: 'mux-1' },
        });
        expect(reconcileAssetMedia.mock.calls[0][1]).toBe('asset-1');
    });

    it('handles ready events without an automatic public playback ID', async () => {
        await buildApp();
        prismaMock.clip.findUnique.mockResolvedValueOnce({ id: 'clip-1', assetId: 'asset-1' });
        const response = await webhook('video.asset.ready', {
            id: 'mux-1',
            passthrough: JSON.stringify({ clipId: 'clip-1', assetId: 'asset-1' }),
        });

        expect(response.statusCode).toBe(200);
        expect(recordMuxAssetReference).toHaveBeenCalledWith(prismaMock, {
            assetId: 'asset-1', clipId: 'clip-1', muxAssetId: 'mux-1',
        });
        expect(reconcileAssetMedia.mock.calls[0][1]).toBe('asset-1');
    });

    it('retains a late reference when the passthrough clip was deleted', async () => {
        await buildApp();
        const response = await webhook('video.asset.ready', {
            id: 'mux-late',
            passthrough: JSON.stringify({ clipId: 'deleted-clip', assetId: 'asset-1' }),
        });

        expect(response.statusCode).toBe(200);
        expect(recordMuxAssetReference).toHaveBeenCalledWith(prismaMock, {
            assetId: 'asset-1', clipId: 'deleted-clip', muxAssetId: 'mux-late',
        });
        expect(prismaMock.clip.updateMany).not.toHaveBeenCalled();
        expect(reconcileAssetMedia.mock.calls[0][1]).toBe('asset-1');
    });

    it('retains a late upload-created reference using its asset-settings passthrough', async () => {
        await buildApp();
        const response = await webhook('video.upload.asset_created', {
            id: 'upload-late',
            asset_id: 'mux-late',
            new_asset_settings: { passthrough: JSON.stringify({ clipId: 'deleted-clip', assetId: 'asset-1' }) },
        });

        expect(response.statusCode).toBe(200);
        expect(recordMuxAssetReference).toHaveBeenCalledWith(prismaMock, {
            assetId: 'asset-1', clipId: 'deleted-clip', muxAssetId: 'mux-late',
        });
        expect(prismaMock.clip.updateMany).not.toHaveBeenCalled();
        expect(reconcileAssetMedia.mock.calls[0][1]).toBe('asset-1');
    });

    it('queues errored events rather than independently changing media state', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce({ id: 'clip-1', assetId: 'asset-1' });
        const response = await webhook('video.asset.errored', { id: 'mux-1', errors: ['encode failed'] });
        expect(response.statusCode).toBe(200);
        expect(reconcileAssetMedia.mock.calls[0][1]).toBe('asset-1');
    });

    it('does not log signed source URLs from Mux error payloads or invalid passthrough', async () => {
        const lines = [];
        const stream = new Writable({
            write(chunk, _encoding, done) { lines.push(chunk.toString()); done(); },
        });
        await buildApp('mux-webhook-secret', { stream });
        prismaMock.clip.findFirst.mockResolvedValueOnce({ id: 'clip-1', assetId: 'asset-1' });
        const response = await webhook('video.asset.errored', {
            id: 'mux-1',
            passthrough: 'invalid https://source.example/?signature=secret-passthrough',
            errors: { messages: ['https://source.example/?signature=secret-error'] },
        });
        expect(response.statusCode).toBe(200);
        const logs = lines.join('');
        expect(logs).toContain('Mux asset errored');
        expect(logs).not.toContain('secret-passthrough');
        expect(logs).not.toContain('secret-error');
    });

    it('refuses conflicting Mux ownership and retries if the asset disappeared', async () => {
        await buildApp();
        prismaMock.muxAssetReference.findUnique.mockResolvedValueOnce({ assetId: 'asset-1' });
        prismaMock.clip.findFirst.mockResolvedValueOnce({ id: 'clip-2', assetId: 'asset-2' });
        expect((await webhook('video.asset.ready', { id: 'mux-1' })).statusCode).toBe(500);
        expect(queueAssetMediaSync).not.toHaveBeenCalled();

        prismaMock.clip.findFirst.mockResolvedValueOnce({ id: 'clip-1', assetId: 'asset-1' });
        queueAssetMediaSync.mockResolvedValueOnce({ count: 0 });
        expect((await webhook('video.asset.ready', { id: 'mux-2' })).statusCode).toBe(503);
        expect(recordMuxAssetReference).not.toHaveBeenCalled();
    });

    it('acknowledges unrecognized events and reports malformed media events', async () => {
        await buildApp();
        expect((await webhook('video.other', {})).statusCode).toBe(200);
        expect((await webhook('video.asset.ready', {})).statusCode).toBe(400);
        expect((await webhook('video.upload.asset_created', { id: '', asset_id: 'mux-1' })).statusCode).toBe(400);
        expect(queueAssetMediaSync).not.toHaveBeenCalled();
    });

    it('keeps the durable queue when reconciliation needs attention', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce({ id: 'clip-1', assetId: 'asset-1' });
        reconcileAssetMedia.mockResolvedValueOnce({ state: 'ERROR', message: 'Mux unavailable' });
        expect((await webhook('video.asset.ready', { id: 'mux-1' })).statusCode).toBe(200);
        expect(queueAssetMediaSync).toHaveBeenCalledWith(prismaMock, 'asset-1');
    });
});

describe('Mux status polling', () => {
    it('requires authentication and scopes clip lookups', async () => {
        await buildApp();
        actor = null;
        expect((await app.inject({ method: 'GET', url: '/api/mux/status/clip-1' })).statusCode).toBe(401);
        actor = { id: 'admin-1', role: 'ADMIN', companyCode: 'NEWS' };
        expect((await app.inject({ method: 'GET', url: '/api/mux/status/clip-other' })).statusCode).toBe(404);
        expect(prismaMock.clip.findFirst).toHaveBeenCalledWith(expect.objectContaining({
            where: { id: 'clip-other', asset: { user: { companyCode: 'NEWS' }, moderation: 'ACTIVE' } },
        }));
    });

    it('returns an existing playback ID only when no reset or create is pending', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce(statusClip({
            muxPlaybackId: 'playback-1',
            streamUrl: 'stream-url',
            thumbnailUrl: 'thumbnail-url',
            status: 'READY',
        }));
        const response = await app.inject({ method: 'GET', url: '/api/mux/status/clip-1' });
        expect(response.json()).toEqual({
            status: 'ready', muxPlaybackId: 'playback-1', streamUrl: 'stream-url', thumbnailUrl: 'thumbnail-url',
        });
        expect(reconcileAssetMedia).not.toHaveBeenCalled();
    });

    it('reconciles an unfinished clip and rechecks authorization before returning playback', async () => {
        await buildApp();
        prismaMock.clip.findFirst
            .mockResolvedValueOnce(statusClip({ asset: {
                mediaPlaybackReset: false, mediaCreateOperationId: null, mediaSyncState: 'SYNCED',
            } }))
            .mockResolvedValueOnce(statusClip({
                muxPlaybackId: 'playback-1', streamUrl: 'stream-url', thumbnailUrl: 'thumbnail-url', status: 'READY',
            }));
        const response = await app.inject({ method: 'GET', url: '/api/mux/status/clip-1' });
        expect(queueAssetMediaSync).toHaveBeenCalledWith(prismaMock, 'asset-1');
        expect(reconcileAssetMedia.mock.calls[0][1]).toBe('asset-1');
        expect(response.json()).toMatchObject({ status: 'ready', muxPlaybackId: 'playback-1' });
    });

    it('does not disclose playback during reset or an unresolved create', async () => {
        await buildApp();
        const blocked = statusClip({
            status: 'READY',
            muxPlaybackId: 'old-id',
            asset: { mediaPlaybackReset: true, mediaCreateOperationId: 'operation-1', mediaSyncState: 'ERROR' },
        });
        prismaMock.clip.findFirst.mockResolvedValue(blocked);
        const response = await app.inject({ method: 'GET', url: '/api/mux/status/clip-1' });
        expect(response.json()).toEqual({ status: 'processing', mediaSyncState: 'ERROR' });
        expect(queueAssetMediaSync).not.toHaveBeenCalled();
    });

    it('returns 404 if a clip becomes moderated while reconciling', async () => {
        await buildApp();
        prismaMock.clip.findFirst.mockResolvedValueOnce(statusClip()).mockResolvedValueOnce(null);
        const response = await app.inject({ method: 'GET', url: '/api/mux/status/clip-1' });
        expect(response.statusCode).toBe(404);
    });
});
