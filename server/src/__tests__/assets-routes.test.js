// Last updated: May 10, 2026 - 10:37am - GitHub Copilot (GPT-5.3-Codex)
import Fastify from 'fastify';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = {
    $executeRawUnsafe: vi.fn(),
    $queryRawUnsafe: vi.fn(),
    asset: {
        create: vi.fn(),
        findUnique: vi.fn(),
        findMany: vi.fn(),
        update: vi.fn(),
    },
    clip: {
        findFirst: vi.fn(),
        create: vi.fn(),
        update: vi.fn(),
        updateMany: vi.fn(),
        delete: vi.fn(),
    },
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

vi.mock('../lib/prisma.js', () => ({
    default: prismaMock,
}));

vi.mock('../lib/mux.js', () => ({
    isMuxEnabled: true,
    createDirectUpload: muxMock.createDirectUpload,
    getMuxUpload: muxMock.getMuxUpload,
    MUX_ENV_KEY: 'test-env',
}));

let assetRoutes;
let app;
let ioEmitSpy;
let ioToSpy;

beforeAll(async () => {
    ({ default: assetRoutes } = await import('../routes/assets.js'));
});

beforeEach(async () => {
    vi.clearAllMocks();

    prismaMock.$executeRawUnsafe.mockResolvedValue(undefined);
    prismaMock.$queryRawUnsafe.mockResolvedValue([{ val: 100000001 }]);

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

    prismaMock.clip.findFirst.mockResolvedValue(null);
    prismaMock.clip.create.mockResolvedValue({});
    prismaMock.clip.update.mockResolvedValue({});
    prismaMock.clip.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.clip.delete.mockResolvedValue({});

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
    });

    it('rejects unsupported mux upload mime types', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({
            id: 'asset-1',
            userId: 'user-1',
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

    it('reuses existing waiting mux upload for idempotency', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({
            id: 'asset-1',
            userId: 'user-1',
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
            id: 'asset-1', userId: 'user-1', mediasourceId: '100000001',
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
        expect(prismaMock.clip.delete).not.toHaveBeenCalled();
        expect(prismaMock.asset.update).not.toHaveBeenCalled();
        expect(prismaMock.clip.create).not.toHaveBeenCalled();
        expect(muxMock.createDirectUpload).not.toHaveBeenCalled();
    });

    it('preserves the clip if checking mux upload status throws', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({ id: 'asset-1', userId: 'user-1' });
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
        expect(prismaMock.clip.delete).not.toHaveBeenCalled();
        expect(prismaMock.asset.update).not.toHaveBeenCalled();
        expect(prismaMock.clip.create).not.toHaveBeenCalled();
        expect(muxMock.createDirectUpload).not.toHaveBeenCalled();
    });

    it('replaces stale mux upload and creates a fresh processing clip', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({
            id: 'asset-1',
            userId: 'user-1',
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

        expect(prismaMock.clip.delete).toHaveBeenCalledWith({ where: { id: 'clip-stale' } });
        expect(prismaMock.clip.create).toHaveBeenCalledTimes(1);
        expect(prismaMock.asset.update).toHaveBeenCalled();
        expect(ioToSpy).toHaveBeenCalledWith('socket-1');
        expect(ioEmitSpy).toHaveBeenCalledWith(
            'upload:complete',
            expect.objectContaining({
                assetId: 'asset-1',
                mediasourceId: '100000001',
            })
        );
    });

    it('submits form and emits coded form confirmation payload', async () => {
        prismaMock.asset.findUnique.mockResolvedValue({
            id: 'asset-1',
            userId: 'user-1',
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
        expect(ioToSpy).toHaveBeenCalledWith('socket-1');
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
