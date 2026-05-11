// Last updated: May 11, 2026 - 5:21pm - GitHub Copilot (GPT-5.3-Codex)
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const muxApi = {
    constructorArgs: [],
    uploadsCreate: vi.fn(),
    uploadsRetrieve: vi.fn(),
    assetsRetrieve: vi.fn(),
    assetsDelete: vi.fn(),
    assetsList: vi.fn(),
};

const createReadStreamMock = vi.fn(() => 'mock-stream');
const statMock = vi.fn();

vi.mock('@mux/mux-node', () => ({
    default: class MockMux {
        constructor(opts) {
            muxApi.constructorArgs.push(opts);
            this.video = {
                uploads: {
                    create: muxApi.uploadsCreate,
                    retrieve: muxApi.uploadsRetrieve,
                },
                assets: {
                    retrieve: muxApi.assetsRetrieve,
                    delete: muxApi.assetsDelete,
                    list: muxApi.assetsList,
                },
            };
        }
    },
}));

vi.mock('fs', () => ({
    createReadStream: createReadStreamMock,
}));

vi.mock('fs/promises', () => ({
    stat: statMock,
}));

const originalEnv = { ...process.env };

async function importMuxModule(env = {}) {
    process.env = { ...originalEnv };

    if (env.tokenId === undefined) delete process.env.MUX_TOKEN_ID;
    else process.env.MUX_TOKEN_ID = env.tokenId;

    if (env.tokenSecret === undefined) delete process.env.MUX_TOKEN_SECRET;
    else process.env.MUX_TOKEN_SECRET = env.tokenSecret;

    if (env.envKey === undefined) delete process.env.MUX_ENV_KEY;
    else process.env.MUX_ENV_KEY = env.envKey;

    vi.resetModules();
    return import('../lib/mux.js');
}

beforeEach(() => {
    muxApi.constructorArgs = [];
    muxApi.uploadsCreate.mockReset();
    muxApi.uploadsRetrieve.mockReset();
    muxApi.assetsRetrieve.mockReset();
    muxApi.assetsDelete.mockReset();
    muxApi.assetsList.mockReset();

    createReadStreamMock.mockClear();
    statMock.mockReset();

    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});

    vi.stubGlobal('fetch', vi.fn());
});

afterEach(() => {
    process.env = { ...originalEnv };
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
});

describe('mux lib coverage', () => {
    it('returns null operations when mux is not configured', async () => {
        const mux = await importMuxModule({});

        expect(mux.isMuxEnabled).toBe(false);
        expect(mux.MUX_ENV_KEY).toBe('');

        await expect(mux.createDirectUpload({ clipId: 'c1', assetId: 'a1' })).resolves.toBeNull();
        await expect(mux.ingestVideo('/tmp/file.mp4', { clipId: 'c1', assetId: 'a1' })).resolves.toBeNull();
        await expect(mux.getMuxAsset('mux-1')).resolves.toBeNull();
        await expect(mux.getMuxUpload('upload-1')).resolves.toBeNull();
        await expect(mux.deleteMuxAsset('mux-1')).resolves.toBe(false);
        await expect(mux.listMuxAssets()).resolves.toBeNull();
    });

    it('creates direct upload with passthrough metadata when configured', async () => {
        muxApi.uploadsCreate.mockResolvedValueOnce({
            id: 'upload-123',
            url: 'https://mux.example/upload/123',
        });

        const mux = await importMuxModule({
            tokenId: 'token-id',
            tokenSecret: 'token-secret',
            envKey: 'env-key-1',
        });

        const result = await mux.createDirectUpload({ clipId: 'clip-1', assetId: 'asset-1' });

        expect(mux.isMuxEnabled).toBe(true);
        expect(mux.MUX_ENV_KEY).toBe('env-key-1');
        expect(muxApi.constructorArgs).toEqual([{ tokenId: 'token-id', tokenSecret: 'token-secret' }]);
        expect(result).toEqual({
            uploadUrl: 'https://mux.example/upload/123',
            muxUploadId: 'upload-123',
        });
        expect(muxApi.uploadsCreate).toHaveBeenCalledWith(
            expect.objectContaining({
                new_asset_settings: {
                    playback_policy: ['public'],
                    passthrough: JSON.stringify({ clipId: 'clip-1', assetId: 'asset-1' }),
                },
                cors_origin: '*',
                timeout: 3600,
            })
        );
    });

    it('merges optional telemetry passthrough fields for direct upload creation', async () => {
        muxApi.uploadsCreate.mockResolvedValueOnce({
            id: 'upload-124',
            url: 'https://mux.example/upload/124',
        });

        const mux = await importMuxModule({
            tokenId: 'token-id',
            tokenSecret: 'token-secret',
        });

        await mux.createDirectUpload({
            clipId: 'clip-2',
            assetId: 'asset-2',
            passthrough: {
                telemetryCorrelationId: 'ios-correlation-1',
                clientUploadStartedAtMs: 1715000000000,
                serverUploadCreatedAtMs: 1715000000500,
            },
        });

        expect(muxApi.uploadsCreate).toHaveBeenCalledWith(
            expect.objectContaining({
                new_asset_settings: expect.objectContaining({
                    passthrough: JSON.stringify({
                        clipId: 'clip-2',
                        assetId: 'asset-2',
                        telemetryCorrelationId: 'ios-correlation-1',
                        clientUploadStartedAtMs: 1715000000000,
                        serverUploadCreatedAtMs: 1715000000500,
                    }),
                }),
            })
        );
    });

    it('ingests local video to mux and returns upload id', async () => {
        muxApi.uploadsCreate.mockResolvedValueOnce({
            id: 'upload-200',
            url: 'https://mux.example/upload/200',
        });
        statMock.mockResolvedValueOnce({ size: 12345 });

        const fetchMock = vi.mocked(globalThis.fetch);
        fetchMock.mockResolvedValueOnce({
            ok: true,
            text: vi.fn().mockResolvedValue('ok'),
        });

        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        const result = await mux.ingestVideo('/tmp/video.mp4', { clipId: 'clip-200', assetId: 'asset-200' });

        expect(createReadStreamMock).toHaveBeenCalledWith('/tmp/video.mp4');
        expect(fetchMock).toHaveBeenCalledWith('https://mux.example/upload/200', {
            method: 'PUT',
            headers: {
                'Content-Length': '12345',
                'Content-Type': 'application/octet-stream',
            },
            body: 'mock-stream',
            duplex: 'half',
        });
        expect(result).toEqual({ muxUploadId: 'upload-200', muxAssetId: null });
    });

    it('returns null when mux ingest upload response is not ok', async () => {
        muxApi.uploadsCreate.mockResolvedValueOnce({
            id: 'upload-500',
            url: 'https://mux.example/upload/500',
        });
        statMock.mockResolvedValueOnce({ size: 999 });

        const fetchMock = vi.mocked(globalThis.fetch);
        fetchMock.mockResolvedValueOnce({
            ok: false,
            status: 500,
            text: vi.fn().mockResolvedValue('failed'),
        });

        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });

        await expect(mux.ingestVideo('/tmp/video-fail.mp4')).resolves.toBeNull();
    });

    it('gets mux asset on success and returns null on retrieval failure', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });

        muxApi.assetsRetrieve.mockResolvedValueOnce({ id: 'mux-ok', status: 'ready' });
        await expect(mux.getMuxAsset('mux-ok')).resolves.toEqual({ id: 'mux-ok', status: 'ready' });

        muxApi.assetsRetrieve.mockRejectedValueOnce(new Error('retrieve failed'));
        await expect(mux.getMuxAsset('mux-fail')).resolves.toBeNull();
    });

    it('returns null when getMuxUpload throws', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });

        muxApi.uploadsRetrieve.mockRejectedValueOnce(new Error('upload lookup failed'));
        await expect(mux.getMuxUpload('upload-fail')).resolves.toBeNull();
    });

    it('deletes mux asset and handles 404 as success', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });

        muxApi.assetsDelete.mockResolvedValueOnce(undefined);
        await expect(mux.deleteMuxAsset('mux-delete')).resolves.toBe(true);

        muxApi.assetsDelete.mockRejectedValueOnce({ status: 404, message: 'not found' });
        await expect(mux.deleteMuxAsset('mux-missing')).resolves.toBe(true);

        muxApi.assetsDelete.mockRejectedValueOnce({ status: 500, message: 'server error' });
        await expect(mux.deleteMuxAsset('mux-error')).resolves.toBe(false);
    });

    it('lists mux assets and returns null on list failure', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });

        muxApi.assetsList.mockResolvedValueOnce({
            data: [{ id: 'asset-1' }, { id: 'asset-2' }],
        });
        await expect(mux.listMuxAssets()).resolves.toEqual([{ id: 'asset-1' }, { id: 'asset-2' }]);

        muxApi.assetsList.mockRejectedValueOnce(new Error('list failed'));
        await expect(mux.listMuxAssets()).resolves.toBeNull();
    });
});
