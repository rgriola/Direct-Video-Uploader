// Last updated: May 10, 2026 - 10:37am - GitHub Copilot (GPT-5.3-Codex)
import Fastify from 'fastify';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = {
    $executeRawUnsafe: vi.fn(),
    $queryRawUnsafe: vi.fn(),
    $transaction: vi.fn(),
    asset: {
        create: vi.fn(),
        findUnique: vi.fn(),
        findMany: vi.fn(),
        update: vi.fn(),
        updateMany: vi.fn(),
    },
    clip: {
        findFirst: vi.fn(),
        create: vi.fn(),
        update: vi.fn(),
        updateMany: vi.fn(),
        delete: vi.fn(),
        deleteMany: vi.fn(),
    },
    muxAssetReference: { findFirst: vi.fn() },
    user: {
        findUnique: vi.fn(),
    },
    formResponse: {
        upsert: vi.fn(),
    },
    chatMessage: {
        create: vi.fn(),
        findMany: vi.fn(),
    },
};

const muxMock = {
    createDirectUpload: vi.fn(),
    getMuxUpload: vi.fn(),
};
const notifyDashboardAssetChange = vi.fn();
const queueAssetMediaSync = vi.fn();
const withAssetMediaLock = vi.fn();

vi.mock('../lib/prisma.js', () => ({
    default: prismaMock,
}));

vi.mock('../lib/mux.js', () => ({
    isMuxEnabled: true,
    createDirectUpload: muxMock.createDirectUpload,
    getMuxUpload: muxMock.getMuxUpload,
    MUX_ENV_KEY: 'test-env',
}));
vi.mock('../ws/dashboard-notifications.js', () => ({ notifyDashboardAssetChange }));
vi.mock('../lib/media-reconciliation.js', () => ({ queueAssetMediaSync }));
vi.mock('../lib/media-lock.js', () => ({ withAssetMediaLock }));

let assetRoutes;
let app;
let ioEmitSpy;
let ioToSpy;

beforeAll(async () => {
    ({ default: assetRoutes } = await import('../routes/assets.js'));
});

beforeEach(async () => {
    vi.clearAllMocks();
    notifyDashboardAssetChange.mockResolvedValue(undefined);

    prismaMock.$executeRawUnsafe.mockResolvedValue(undefined);
    prismaMock.$queryRawUnsafe.mockResolvedValue([{ val: 100000001 }]);
    prismaMock.$transaction.mockImplementation(async callback => callback(prismaMock));
    queueAssetMediaSync.mockResolvedValue({ count: 1 });
    withAssetMediaLock.mockImplementation(async (_id, work) => ({
        acquired: true,
        value: await work(async () => {}),
    }));

    prismaMock.asset.create.mockResolvedValue({
        id: 'asset-1',
        mediasourceId: '100000001',
        mediasourceUrl: '/clips/100000001',
        originalFileName: 'video.mp4',
        status: 'UPLOADING',
        clipCount: 0,
        totalDuration: 0,
    });
    prismaMock.asset.findUnique.mockResolvedValue(null);
    prismaMock.asset.findMany.mockResolvedValue([]);
    prismaMock.asset.update.mockResolvedValue({});
    prismaMock.asset.updateMany.mockResolvedValue({ count: 1 });

    prismaMock.clip.findFirst.mockResolvedValue(null);
    prismaMock.clip.create.mockResolvedValue({});
    prismaMock.clip.update.mockResolvedValue({});
    prismaMock.clip.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.clip.delete.mockResolvedValue({});
    prismaMock.clip.deleteMany.mockResolvedValue({ count: 1 });
    prismaMock.muxAssetReference.findFirst.mockResolvedValue(null);

    prismaMock.user.findUnique.mockResolvedValue({ id: 'user-1', name: 'Fallback User' });
    prismaMock.formResponse.upsert.mockResolvedValue({
        id: 'form-1',
        assetId: 'asset-1',
        slug: 'fallback-user',
        type: 'Raw',
        description: 'Fallback User',
        priority: 'MEDIUM',
    });
    prismaMock.chatMessage.create.mockResolvedValue({});
    prismaMock.chatMessage.findMany.mockResolvedValue([{ id: 'msg-1', content: { text: 'hello' } }]);

    muxMock.createDirectUpload.mockResolvedValue({
        uploadUrl: 'https://mux.example/upload/new',
        muxUploadId: 'upload-new',
    });
    muxMock.getMuxUpload.mockResolvedValue(null);

    ioEmitSpy = vi.fn();
    ioToSpy = vi.fn(() => ({ emit: ioEmitSpy }));

    app = Fastify({ logger: false });

    app.decorate('authenticate', async (request) => {
        request.user = {
            id: 'user-1',
            name: 'David Burgess',
            role: 'USER',
        };
    });

    app.decorate('io', { to: ioToSpy });
    app.decorate('userSockets', new Map([['user-1', new Set(['socket-1'])]]));

    await app.register(assetRoutes);
});

afterEach(async () => {
    await app.close();
});

describe('assets route deeper coverage', () => {
    it('creates an asset with generated mediasource id', async () => {
        const response = await app.inject({
            method: 'POST',
            url: '/api/assets',
            payload: { fileName: 'field-clip.mp4' },
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.$executeRawUnsafe).toHaveBeenCalled();
        expect(prismaMock.$queryRawUnsafe).toHaveBeenCalled();

        const body = response.json();
        expect(body.asset.mediasourceId).toBe('100000001');
        expect(body.asset.status).toBe('UPLOADING');
        expect(notifyDashboardAssetChange.mock.calls[0][0].io).toBe(app.io);
        expect(notifyDashboardAssetChange.mock.calls[0][1]).toBe('asset-1');
    });

    it('rejects unsupported mux upload mime types', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({
            id: 'asset-1',
            userId: 'user-1',
            moderation: 'ACTIVE',
            mediasourceId: '100000001',
            mediasourceUrl: '/clips/100000001',
            originalFileName: 'video.mp4',
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/assets/asset-1/mux-upload',
            payload: {
                metadata: { mimeType: 'text/plain' },
            },
        });

        expect(response.statusCode).toBe(415);
        expect(response.json().error).toContain('Unsupported media type');
        expect(prismaMock.clip.create).not.toHaveBeenCalled();
    });

    it('does not create a new upload for a paused asset', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({
            id: 'asset-1',
            userId: 'user-1',
            moderation: 'PAUSED',
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/assets/asset-1/mux-upload',
            payload: { metadata: { mimeType: 'video/mp4' } },
        });

        expect(response.statusCode).toBe(409);
        expect(prismaMock.clip.create).not.toHaveBeenCalled();
        expect(muxMock.createDirectUpload).not.toHaveBeenCalled();
    });

    it('keeps paused assets in the owner archive without exposing playback URLs', async () => {
        prismaMock.asset.findMany.mockResolvedValue([{
            id: 'asset-paused',
            moderation: 'PAUSED',
            clips: [{
                id: 'clip-paused',
                muxPlaybackId: 'old-playback-id',
                streamUrl: 'https://stream.mux.com/old-playback-id.m3u8',
                thumbnailUrl: 'https://image.mux.com/old-playback-id/thumbnail.png',
                fileSize: BigInt(1234),
            }],
            formResponse: null,
        }]);

        const response = await app.inject({ method: 'GET', url: '/api/assets/mine' });

        expect(response.statusCode).toBe(200);
        expect(response.json().assets[0].moderation).toBe('PAUSED');
        expect(response.json().assets[0].clips[0]).toMatchObject({
            muxPlaybackId: null,
            streamUrl: null,
            thumbnailUrl: null,
            fileSize: '1234',
        });
    });

    it.each([
        ['a playback reset', { mediaPlaybackReset: true, mediaCreateOperationId: null }],
        ['an uncertain playback creation', { mediaPlaybackReset: false, mediaCreateOperationId: 'operation-1' }],
    ])('hides active media during %s', async (_label, pending) => {
        prismaMock.asset.findMany.mockResolvedValue([{
            id: 'asset-1',
            moderation: 'ACTIVE',
            ...pending,
            mediaCreateMuxAssetId: 'mux-1',
            mediaCreateStartedAt: new Date(),
            mediaSyncRevision: 3,
            mediaSyncError: 'internal error',
            clips: [{
                id: 'clip-1',
                storageUrl: '/uploads/old.mp4',
                muxPlaybackId: 'old-id',
                streamUrl: 'old-stream',
                thumbnailUrl: 'old-thumbnail',
            }],
            formResponse: null,
        }]);

        const response = await app.inject({ method: 'GET', url: '/api/assets/mine' });
        const asset = response.json().assets[0];
        expect(asset.clips[0]).toMatchObject({
            storageUrl: null, muxPlaybackId: null, streamUrl: null, thumbnailUrl: null,
        });
        expect(asset).not.toHaveProperty('mediaCreateOperationId');
        expect(asset).not.toHaveProperty('mediaCreateMuxAssetId');
        expect(asset).not.toHaveProperty('mediaSyncError');
    });

    it('reuses existing waiting mux upload for idempotency', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({
            id: 'asset-1',
            userId: 'user-1',
            moderation: 'ACTIVE',
            mediasourceId: '100000001',
            mediasourceUrl: '/clips/100000001',
            originalFileName: 'video.mp4',
        });
        prismaMock.clip.findFirst.mockResolvedValue({
            id: 'clip-existing',
            muxUploadId: 'upload-existing',
        });
        muxMock.getMuxUpload.mockResolvedValue({
            id: 'upload-existing',
            status: 'waiting',
            url: 'https://mux.example/upload/existing',
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/assets/asset-1/mux-upload',
            payload: {
                metadata: { mimeType: 'video/mp4' },
            },
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual({
            uploadUrl: 'https://mux.example/upload/existing',
            clipId: 'clip-existing',
            muxUploadId: 'upload-existing',
        });
        expect(prismaMock.clip.create).not.toHaveBeenCalled();
    });

    it.each([
        ['missing upload', null, 503],
        ['missing status', {}, 503],
        ['unknown status', { status: 'new_state' }, 503],
        ['waiting without URL', { status: 'waiting' }, 503],
        ['already processing', { status: 'asset_created' }, 409],
    ])('preserves the clip when the existing mux upload is %s', async (_label, upload, status) => {
        prismaMock.asset.findUnique.mockResolvedValue({
            id: 'asset-1', userId: 'user-1', moderation: 'ACTIVE', mediasourceId: '100000001',
            mediasourceUrl: '/clips/100000001', originalFileName: 'video.mp4',
        });
        prismaMock.clip.findFirst.mockResolvedValue({
            id: 'clip-existing', muxUploadId: 'upload-existing',
        });
        muxMock.getMuxUpload.mockResolvedValue(upload);

        const response = await app.inject({
            method: 'POST',
            url: '/api/assets/asset-1/mux-upload',
            payload: { metadata: { mimeType: 'video/mp4' } },
        });

        expect(response.statusCode).toBe(status);
        expect(prismaMock.clip.deleteMany).not.toHaveBeenCalled();
        expect(prismaMock.asset.updateMany).not.toHaveBeenCalled();
        expect(prismaMock.clip.create).not.toHaveBeenCalled();
        expect(muxMock.createDirectUpload).not.toHaveBeenCalled();
    });

    it('preserves the clip if checking mux upload status throws', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({ id: 'asset-1', userId: 'user-1', moderation: 'ACTIVE' });
        prismaMock.clip.findFirst.mockResolvedValue({
            id: 'clip-existing', muxUploadId: 'upload-existing',
        });
        muxMock.getMuxUpload.mockRejectedValue(new Error('Mux unavailable'));

        const response = await app.inject({
            method: 'POST',
            url: '/api/assets/asset-1/mux-upload',
            payload: { metadata: { mimeType: 'video/mp4' } },
        });

        expect(response.statusCode).toBe(503);
        expect(prismaMock.clip.deleteMany).not.toHaveBeenCalled();
        expect(prismaMock.asset.updateMany).not.toHaveBeenCalled();
        expect(prismaMock.clip.create).not.toHaveBeenCalled();
        expect(muxMock.createDirectUpload).not.toHaveBeenCalled();
    });

    it('replaces stale mux upload and creates a fresh processing clip', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({
            id: 'asset-1',
            userId: 'user-1',
            moderation: 'ACTIVE',
            mediasourceId: '100000001',
            mediasourceUrl: '/clips/100000001',
            originalFileName: 'video.mp4',
        });
        prismaMock.clip.findFirst.mockResolvedValue({
            id: 'clip-stale',
            muxUploadId: 'upload-stale',
        });
        muxMock.getMuxUpload.mockResolvedValue({
            id: 'upload-stale',
            status: 'timed_out',
            url: null,
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/assets/asset-1/mux-upload',
            payload: {
                metadata: {
                    mimeType: 'video/mp4',
                    fileName: 'late-night.mp4',
                    fileSize: '1234',
                    duration: '12',
                    resolution: '1920x1080',
                    codec: 'h264',
                },
            },
        });

        expect(response.statusCode).toBe(200);
        expect(response.json().uploadUrl).toBe('https://mux.example/upload/new');
        expect(response.json().muxUploadId).toBe('upload-new');

        expect(prismaMock.clip.deleteMany).toHaveBeenCalledWith({
            where: { id: 'clip-stale', assetId: 'asset-1', status: 'PROCESSING', muxAssetId: null },
        });
        expect(prismaMock.clip.create).toHaveBeenCalledTimes(1);
        expect(prismaMock.asset.updateMany).toHaveBeenCalled();
        expect(prismaMock.clip.create.mock.invocationCallOrder[0]).toBeLessThan(muxMock.createDirectUpload.mock.invocationCallOrder[0]);
        expect(queueAssetMediaSync).toHaveBeenCalledTimes(2);
        expect(ioToSpy).toHaveBeenCalledWith('user:user-1');
        expect(notifyDashboardAssetChange.mock.calls[0][0].io).toBe(app.io);
        expect(notifyDashboardAssetChange.mock.calls[0][1]).toBe('asset-1');
        expect(ioEmitSpy).toHaveBeenCalledWith(
            'upload:complete',
            expect.objectContaining({
                assetId: 'asset-1',
                mediasourceId: '100000001',
            })
        );
    });

    it('retains the upload reference but withholds the URL if moderation changes during creation', async () => {
        prismaMock.asset.findUnique
            .mockResolvedValueOnce({
                id: 'asset-1', userId: 'user-1', moderation: 'ACTIVE', mediasourceId: '100000001',
            })
            .mockResolvedValueOnce({ id: 'asset-1', userId: 'user-1', moderation: 'PAUSED' });

        const response = await app.inject({
            method: 'POST',
            url: '/api/assets/asset-1/mux-upload',
            payload: { metadata: { mimeType: 'video/mp4' } },
        });

        expect(response.statusCode).toBe(409);
        expect(response.body).not.toContain('https://mux.example/upload/new');
        expect(prismaMock.clip.updateMany).toHaveBeenCalledWith(expect.objectContaining({
            data: { muxUploadId: 'upload-new' },
        }));
        expect(queueAssetMediaSync).toHaveBeenCalledTimes(2);
        expect(ioEmitSpy).not.toHaveBeenCalled();
    });

    it('marks a failed upload creation as an error without exposing an upload URL', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({ id: 'asset-1', userId: 'user-1', moderation: 'ACTIVE' });
        muxMock.createDirectUpload.mockRejectedValueOnce(new Error('Mux unavailable'));

        const response = await app.inject({
            method: 'POST',
            url: '/api/assets/asset-1/mux-upload',
            payload: { metadata: { mimeType: 'video/mp4' } },
        });

        expect(response.statusCode).toBe(502);
        expect(prismaMock.clip.updateMany).toHaveBeenCalledWith(expect.objectContaining({ data: { status: 'ERROR' } }));
        expect(queueAssetMediaSync).toHaveBeenCalledTimes(2);
        expect(ioEmitSpy).not.toHaveBeenCalled();
    });

    it('does not replace a stale clip that still has a retained Mux reference', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({ id: 'asset-1', userId: 'user-1', moderation: 'ACTIVE' });
        prismaMock.clip.findFirst.mockResolvedValue({ id: 'clip-stale', muxUploadId: 'upload-stale' });
        muxMock.getMuxUpload.mockResolvedValue({ status: 'timed_out' });
        prismaMock.muxAssetReference.findFirst.mockResolvedValue({ muxAssetId: 'mux-late' });

        const response = await app.inject({
            method: 'POST',
            url: '/api/assets/asset-1/mux-upload',
            payload: { metadata: { mimeType: 'video/mp4' } },
        });

        expect(response.statusCode).toBe(409);
        expect(prismaMock.clip.deleteMany).not.toHaveBeenCalled();
        expect(queueAssetMediaSync).toHaveBeenCalledWith(prismaMock, 'asset-1');
        expect(muxMock.createDirectUpload).not.toHaveBeenCalled();
    });

    it.each(['muxPlaybackId', 'storageUrl', 'streamUrl', 'thumbnailUrl'])(
        'does not replace a stale clip with an unresolved %s',
        async field => {
            prismaMock.asset.findUnique.mockResolvedValue({ id: 'asset-1', userId: 'user-1', moderation: 'ACTIVE' });
            prismaMock.clip.findFirst.mockResolvedValue({
                id: 'clip-stale', muxUploadId: 'upload-stale', [field]: 'unresolved-media',
            });
            muxMock.getMuxUpload.mockResolvedValue({ status: 'timed_out' });

            const response = await app.inject({
                method: 'POST',
                url: '/api/assets/asset-1/mux-upload',
                payload: { metadata: { mimeType: 'video/mp4' } },
            });

            expect(response.statusCode).toBe(409);
            expect(prismaMock.clip.deleteMany).not.toHaveBeenCalled();
            expect(queueAssetMediaSync).toHaveBeenCalledWith(prismaMock, 'asset-1');
            expect(muxMock.createDirectUpload).not.toHaveBeenCalled();
        },
    );

    it('submits form and emits coded form confirmation payload', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({
            id: 'asset-1',
            userId: 'user-1',
            moderation: 'ACTIVE',
            mediasourceId: '100000001',
            mediasourceUrl: '/clips/100000001',
            originalFileName: 'field-report.mp4',
            clips: [{ originalFileName: 'clip-fallback.mp4', capturedAt: new Date('2026-05-10T01:02:03.000Z') }],
        });
        prismaMock.formResponse.upsert.mockResolvedValue({
            id: 'form-1',
            assetId: 'asset-1',
            slug: 'breaking',
            type: 'Raw',
            description: 'A short description',
            priority: 'HIGH',
        });

        const response = await app.inject({
            method: 'POST',
            url: '/api/assets/asset-1/form',
            payload: {
                slug: 'breaking',
                type: 'Raw',
                description: 'A short description',
                priority: 'High',
            },
        });

        expect(response.statusCode).toBe(200);
        expect(ioToSpy).toHaveBeenCalledWith('user:user-1');
        expect(notifyDashboardAssetChange.mock.calls[0][0].io).toBe(app.io);
        expect(notifyDashboardAssetChange.mock.calls[0][1]).toBe('asset-1');
        expect(ioEmitSpy).toHaveBeenCalledWith(
            'form:confirmed',
            expect.objectContaining({
                assetId: 'asset-1',
                messageCode: 'WS_FORM_CONFIRMED',
                messageSchemaVersion: 1,
                messageFallbackText: expect.any(String),
                message: expect.any(String),
            })
        );

        expect(prismaMock.chatMessage.create).toHaveBeenCalledWith({
            data: expect.objectContaining({
                userId: 'user-1',
                assetId: 'asset-1',
                messageType: 'FORM_SUBMITTED',
                content: expect.objectContaining({
                    code: 'WS_FORM_SUBMITTED',
                    fallbackText: 'Form submitted',
                    schemaVersion: 1,
                }),
            }),
        });
    });

    it('validates transcript payload and handles missing clip', async () => {
        const badRequest = await app.inject({
            method: 'PATCH',
            url: '/api/assets/asset-1/transcript',
            payload: {},
        });

        expect(badRequest.statusCode).toBe(400);

        prismaMock.clip.findFirst.mockResolvedValue(null);
        const missingClip = await app.inject({
            method: 'PATCH',
            url: '/api/assets/asset-1/transcript',
            payload: { transcript: 'hello world' },
        });

        expect(missingClip.statusCode).toBe(404);
        expect(missingClip.json()).toEqual({ error: 'No clip found for this asset' });
    });

    it('saves transcript text and segment list', async () => {
        prismaMock.clip.findFirst.mockResolvedValue({ id: 'clip-1' });

        const response = await app.inject({
            method: 'PATCH',
            url: '/api/assets/asset-1/transcript',
            payload: {
                transcript: 'First sentence. Second sentence.',
                segments: [
                    { word: 'First', start: 0, end: 0.2, confidence: 0.99 },
                    { word: 'sentence', start: 0.21, end: 0.5, confidence: 0.96 },
                ],
            },
        });

        expect(response.statusCode).toBe(200);
        expect(prismaMock.clip.updateMany).toHaveBeenCalledWith({
            where: { id: 'clip-1', assetId: 'asset-1', asset: { userId: 'user-1' } },
            data: {
                transcript: 'First sentence. Second sentence.',
                transcriptSegments: [
                    { word: 'First', start: 0, end: 0.2, confidence: 0.99 },
                    { word: 'sentence', start: 0.21, end: 0.5, confidence: 0.96 },
                ],
            },
        });
        expect(response.json()).toEqual({ ok: true, clipId: 'clip-1', segmentCount: 2 });
    });

    it('saves a transcript only to the requested owned clip', async () => {
        const response = await app.inject({
            method: 'PATCH',
            url: '/api/assets/asset-1/clips/clip-original/transcript',
            payload: { transcript: 'hello', clipId: 'clip-original', segments: [] },
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual({ ok: true, clipId: 'clip-original', segmentCount: 0 });
        expect(prismaMock.clip.updateMany).toHaveBeenCalledWith({
            where: { id: 'clip-original', assetId: 'asset-1', asset: { userId: 'user-1' } },
            data: { transcript: 'hello', transcriptSegments: [] },
        });
        expect(prismaMock.clip.findFirst).not.toHaveBeenCalled();
        expect(prismaMock.clip.update).not.toHaveBeenCalled();
    });

    it('uses the path clip when the request body omits a clip identifier', async () => {
        const response = await app.inject({
            method: 'PATCH',
            url: '/api/assets/asset-1/clips/clip-original/transcript',
            payload: { transcript: 'hello' },
        });

        expect(response.statusCode).toBe(200);
        expect(response.json()).toEqual({ ok: true, clipId: 'clip-original', segmentCount: 0 });
        expect(prismaMock.clip.updateMany).toHaveBeenCalledWith({
            where: { id: 'clip-original', assetId: 'asset-1', asset: { userId: 'user-1' } },
            data: { transcript: 'hello', transcriptSegments: undefined },
        });
    });

    it('rechecks ownership when updating a legacy first-clip transcript', async () => {
        prismaMock.clip.findFirst.mockResolvedValue({ id: 'clip-1' });
        prismaMock.clip.updateMany.mockResolvedValue({ count: 0 });
        const response = await app.inject({
            method: 'PATCH',
            url: '/api/assets/asset-1/transcript',
            payload: { transcript: 'hello' },
        });

        expect(response.statusCode).toBe(404);
        expect(prismaMock.clip.update).not.toHaveBeenCalled();
    });

    it('rejects invalid or replaced clip identifiers without updating another clip', async () => {
        const invalid = await app.inject({
            method: 'PATCH',
            url: '/api/assets/asset-1/transcript',
            payload: { transcript: 'hello', clipId: '' },
        });
        expect(invalid.statusCode).toBe(400);
        expect(prismaMock.clip.updateMany).not.toHaveBeenCalled();

        const mismatch = await app.inject({
            method: 'PATCH',
            url: '/api/assets/asset-1/clips/clip-original/transcript',
            payload: { transcript: 'hello', clipId: 'clip-other' },
        });
        expect(mismatch.statusCode).toBe(400);
        expect(prismaMock.clip.updateMany).not.toHaveBeenCalled();

        prismaMock.clip.updateMany.mockResolvedValue({ count: 0 });
        const missing = await app.inject({
            method: 'PATCH',
            url: '/api/assets/asset-1/clips/clip-replaced/transcript',
            payload: { transcript: 'hello', clipId: 'clip-replaced' },
        });
        expect(missing.statusCode).toBe(404);
        expect(prismaMock.clip.findFirst).not.toHaveBeenCalled();
        expect(prismaMock.clip.update).not.toHaveBeenCalled();
    });
});
