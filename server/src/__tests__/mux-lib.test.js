// Last updated: May 9, 2026 - 8:33pm - GPT-5.3-Codex
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const muxApi = {
    constructorArgs: [],
    uploadsCreate: vi.fn(),
    uploadsRetrieve: vi.fn(),
    uploadsCancel: vi.fn(),
    assetsCreate: vi.fn(),
    assetsRetrieve: vi.fn(),
    assetsDelete: vi.fn(),
    playbackCreate: vi.fn(),
    playbackDelete: vi.fn(),
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
                    cancel: muxApi.uploadsCancel,
                },
                assets: {
                    create: muxApi.assetsCreate,
                    retrieve: muxApi.assetsRetrieve,
                    delete: muxApi.assetsDelete,
                    createPlaybackId: muxApi.playbackCreate,
                    deletePlaybackId: muxApi.playbackDelete,
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
    muxApi.uploadsCancel.mockReset();
    muxApi.assetsCreate.mockReset();
    muxApi.assetsRetrieve.mockReset();
    muxApi.assetsDelete.mockReset();
    muxApi.playbackCreate.mockReset();
    muxApi.playbackDelete.mockReset();
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
                    passthrough: JSON.stringify({ clipId: 'clip-1', assetId: 'asset-1' }),
                },
                cors_origin: '*',
                timeout: 3600,
            }),
            { timeout: 15_000, maxRetries: 0 },
        );
    });

    it('creates a source-URL asset without automatically creating playback', async () => {
        muxApi.assetsCreate.mockResolvedValueOnce({ id: 'mux-original' });
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        const result = await mux.createMuxOriginalAsset({
            sourceUrl: 'https://origin.example.test/source?signature=test',
            assetId: 'asset-1',
            clipId: 'clip-1',
            operationId: 'operation-1',
        });
        expect(result).toEqual({ ok: true, muxAssetId: 'mux-original' });
        expect(muxApi.assetsCreate).toHaveBeenCalledWith({
            inputs: [{ url: 'https://origin.example.test/source?signature=test' }],
            passthrough: JSON.stringify({
                assetId: 'asset-1', clipId: 'clip-1', ingestOperationId: 'operation-1',
            }),
        }, { timeout: 15_000, maxRetries: 0 });
    });

    it('distinguishes rejected creation from an unknown outcome without logging the source URL', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        const input = {
            sourceUrl: 'https://origin.example.test/source?signature=private',
            assetId: 'asset-1', clipId: 'clip-1', operationId: 'operation-1',
        };
        muxApi.assetsCreate.mockRejectedValueOnce({ status: 429, message: input.sourceUrl });
        expect(await mux.createMuxOriginalAsset(input)).toMatchObject({
            ok: false, indeterminate: false, retryable: true,
        });
        muxApi.assetsCreate.mockRejectedValueOnce({ status: 400, message: input.sourceUrl });
        expect(await mux.createMuxOriginalAsset(input)).toMatchObject({
            ok: false, indeterminate: true, retryable: false,
        });
        for (const failure of [{ status: 408 }, { status: 500 }, new Error(input.sourceUrl)]) {
            muxApi.assetsCreate.mockRejectedValueOnce(failure);
            expect(await mux.createMuxOriginalAsset(input)).toMatchObject({
                ok: false, indeterminate: true, retryable: false,
            });
        }
        muxApi.assetsCreate.mockResolvedValueOnce({});
        expect(await mux.createMuxOriginalAsset(input)).toMatchObject({ ok: false, indeterminate: true });
        expect(console.error).not.toHaveBeenCalled();
    });

    it('does not log source capabilities embedded in Mux asset errors', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.assetsRetrieve.mockRejectedValueOnce({
            status: 500, message: 'source https://origin.example.test/?signature=private-capability',
        });
        await expect(mux.inspectMuxAsset('mux-original')).resolves.toEqual({
            ok: false, error: 'Mux asset inspection failed',
        });
        expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toContain('private-capability');
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

        expect(muxApi.uploadsCreate.mock.calls[0][0].new_asset_settings).not.toHaveProperty('playback_policy');
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
        expect(muxApi.uploadsRetrieve).toHaveBeenCalledWith(
            'upload-fail', { timeout: 15_000, maxRetries: 0 },
        );
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

    it('revokes every public playback ID even if one was already deleted', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.assetsRetrieve
            .mockResolvedValueOnce({
                status: 'ready',
                playback_ids: [
                    { policy: 'public', id: 'public-1' },
                    { policy: 'signed', id: 'signed-1' },
                    { policy: 'public', id: 'public-2' },
                ],
            })
            .mockResolvedValueOnce({ status: 'ready', playback_ids: [{ policy: 'signed', id: 'signed-1' }] });
        muxApi.playbackDelete
            .mockRejectedValueOnce({ status: 404, message: 'not found' })
            .mockResolvedValueOnce(undefined);

        await expect(mux.disableMuxPlayback('mux-1')).resolves.toEqual({ ok: true });
        expect(muxApi.playbackDelete.mock.calls).toEqual([
            ['mux-1', 'public-1', { timeout: 15_000, maxRetries: 0 }],
            ['mux-1', 'public-2', { timeout: 15_000, maxRetries: 0 }],
        ]);
        expect(muxApi.assetsRetrieve).toHaveBeenCalledTimes(2);
    });

    it('attempts remaining IDs and reports failure if any public ID remains', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.assetsRetrieve
            .mockResolvedValueOnce({
                status: 'ready',
                playback_ids: [
                    { policy: 'public', id: 'public-1' },
                    { policy: 'public', id: 'public-2' },
                ],
            })
            .mockResolvedValueOnce({ status: 'ready', playback_ids: [{ policy: 'public', id: 'public-1' }] });
        muxApi.playbackDelete
            .mockRejectedValueOnce({ status: 503, message: 'unavailable' })
            .mockResolvedValueOnce(undefined);

        await expect(mux.disableMuxPlayback('mux-1')).resolves.toEqual({
            ok: false,
            error: 'Mux still has public playback IDs',
        });
        expect(muxApi.playbackDelete).toHaveBeenCalledTimes(2);
        expect(console.error).toHaveBeenCalled();
    });

    it('does not confirm revocation if the verification lookup fails', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.assetsRetrieve
            .mockResolvedValueOnce({ status: 'ready', playback_ids: [{ policy: 'public', id: 'public-1' }] })
            .mockRejectedValueOnce({ status: 503, message: 'unavailable' });
        muxApi.playbackDelete.mockResolvedValue(undefined);

        await expect(mux.disableMuxPlayback('mux-1')).resolves.toEqual({
            ok: false,
            error: 'Mux playback revocation failed',
        });
    });

    it('does not delete playback IDs after the reconciliation lock is lost', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.assetsRetrieve.mockResolvedValueOnce({
            status: 'ready',
            playback_ids: [{ policy: 'public', id: 'public-1' }],
        });
        const assertLocked = vi.fn().mockRejectedValue(new Error('lock lost'));

        await expect(mux.disableMuxPlayback('mux-1', assertLocked)).rejects.toThrow('lock lost');
        expect(muxApi.playbackDelete).not.toHaveBeenCalled();
    });

    it('stops revoking before the next ID if the reconciliation lock is lost', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.assetsRetrieve.mockResolvedValueOnce({
            status: 'ready',
            playback_ids: [
                { policy: 'public', id: 'public-1' },
                { policy: 'public', id: 'public-2' },
            ],
        });
        muxApi.playbackDelete.mockResolvedValue(undefined);
        const assertLocked = vi.fn()
            .mockResolvedValueOnce(undefined)
            .mockResolvedValueOnce(undefined)
            .mockRejectedValueOnce(new Error('lock lost'));

        await expect(mux.disableMuxPlayback('mux-1', assertLocked)).rejects.toThrow('lock lost');
        expect(muxApi.playbackDelete.mock.calls).toEqual([
            ['mux-1', 'public-1', { timeout: 15_000, maxRetries: 0 }],
        ]);
    });

    it('treats a missing Mux asset as already revoked', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.assetsRetrieve.mockRejectedValueOnce({ status: 404, message: 'not found' });

        await expect(mux.disableMuxPlayback('mux-missing')).resolves.toEqual({ ok: true });
        expect(muxApi.playbackDelete).not.toHaveBeenCalled();
    });

    it('distinguishes a missing asset from an unavailable Mux lookup', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.assetsRetrieve.mockRejectedValueOnce({ status: 404, message: 'not found' });
        await expect(mux.inspectMuxAsset('mux-missing')).resolves.toEqual({ ok: true, asset: null });

        muxApi.assetsRetrieve.mockRejectedValueOnce({ status: 503, message: 'unavailable' });
        await expect(mux.inspectMuxAsset('mux-unavailable')).resolves.toEqual({
            ok: false,
            error: 'Mux asset inspection failed',
        });

        muxApi.assetsRetrieve.mockResolvedValueOnce({ status: 'ready', playback_ids: [{ policy: 'public' }] });
        await expect(mux.inspectMuxAsset('mux-invalid')).resolves.toEqual({
            ok: false,
            error: 'Mux asset inspection returned an invalid response',
        });
    });

    it('only confirms cancellation when Mux reports the upload cancelled', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.uploadsCancel.mockResolvedValueOnce({ status: 'cancelled' });
        await expect(mux.cancelMuxUpload('upload-1')).resolves.toEqual({ ok: true });

        muxApi.uploadsCancel.mockResolvedValueOnce({ status: 'waiting' });
        await expect(mux.cancelMuxUpload('upload-2')).resolves.toEqual({
            ok: false,
            error: 'Mux upload cancellation was not confirmed',
        });
    });

    it('does not retry a playback creation whose outcome could be unknown', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.playbackCreate.mockRejectedValueOnce(new Error('request timed out'));

        await expect(mux.createMuxPublicPlayback('mux-1')).resolves.toEqual({
            ok: false,
            indeterminate: true,
            error: 'Mux playback creation outcome is unknown',
        });
        expect(muxApi.playbackCreate).toHaveBeenCalledWith(
            'mux-1',
            { policy: 'public' },
            { timeout: 15_000, maxRetries: 0 },
        );
        expect(muxApi.playbackCreate).toHaveBeenCalledTimes(1);
    });

    it('distinguishes rejected playback creation from an indeterminate response', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.playbackCreate.mockRejectedValueOnce({ status: 403, message: 'forbidden' });
        await expect(mux.createMuxPublicPlayback('mux-1')).resolves.toEqual({
            ok: false,
            indeterminate: false,
            error: 'Mux playback creation was rejected',
        });

        muxApi.playbackCreate.mockResolvedValueOnce({});
        await expect(mux.createMuxPublicPlayback('mux-1')).resolves.toEqual({
            ok: false,
            indeterminate: true,
            error: 'Mux playback creation outcome is unknown',
        });
    });

    it('only accepts a playback creation response that confirms public policy', async () => {
        const mux = await importMuxModule({ tokenId: 'id', tokenSecret: 'secret' });
        muxApi.playbackCreate.mockResolvedValueOnce({ id: 'public-1', policy: 'public' });
        await expect(mux.createMuxPublicPlayback('mux-1')).resolves.toEqual({
            ok: true, playbackId: 'public-1',
        });

        muxApi.playbackCreate.mockResolvedValueOnce({ id: 'other-1', policy: 'signed' });
        await expect(mux.createMuxPublicPlayback('mux-1')).resolves.toEqual({
            ok: false,
            indeterminate: true,
            error: 'Mux playback creation outcome is unknown',
        });
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
