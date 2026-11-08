import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = {
    $transaction: vi.fn(),
    $queryRaw: vi.fn(),
    clip: { findFirst: vi.fn(), findMany: vi.fn(), findUnique: vi.fn(), updateMany: vi.fn() },
    asset: { findFirst: vi.fn(), findMany: vi.fn(), update: vi.fn(), updateMany: vi.fn() },
};
const muxState = { enabled: true };
const queueAssetMediaSync = vi.fn();
const reconcileAssetMedia = vi.fn();
const notifyDashboardAssetChange = vi.fn();
const slackMock = { isConfigured: vi.fn(), postToChannel: vi.fn() };
const fsMock = { realpath: vi.fn(), unlink: vi.fn() };
const withAssetMediaLock = vi.fn();

vi.mock('../lib/prisma.js', () => ({ default: prismaMock }));
vi.mock('../lib/mux.js', () => ({
    get isMuxEnabled() { return muxState.enabled; },
}));
vi.mock('../lib/media-reconciliation.js', () => ({ queueAssetMediaSync, reconcileAssetMedia }));
vi.mock('../lib/media-lock.js', () => ({ withAssetMediaLock }));
vi.mock('../ws/dashboard-notifications.js', () => ({ notifyDashboardAssetChange }));
vi.mock('../lib/slack.js', () => ({
    isConfigured: slackMock.isConfigured,
    postToChannel: slackMock.postToChannel,
}));
vi.mock('../lib/utils.js', async () => {
    const actual = await vi.importActual('../lib/utils.js');
    return { ...actual, dbRetry: async fn => fn() };
});
vi.mock('fs/promises', () => ({ default: fsMock, ...fsMock }));

let startMuxSync;
let stopMuxSync;
let startUploadCleanup;
let stopUploadCleanup;

beforeAll(async () => {
    ({ startMuxSync, stopMuxSync } = await import('../jobs/mux-sync.js'));
    ({ startUploadCleanup, stopUploadCleanup } = await import('../jobs/upload-cleanup.js'));
});

beforeEach(() => {
    vi.useFakeTimers();
    vi.resetAllMocks();
    muxState.enabled = true;
    prismaMock.$transaction.mockImplementation(async callback => callback(prismaMock));
    prismaMock.$queryRaw.mockResolvedValue([]);
    prismaMock.asset.findFirst.mockResolvedValue(null);
    prismaMock.asset.findMany.mockResolvedValue([]);
    prismaMock.asset.update.mockResolvedValue({});
    prismaMock.asset.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.clip.findMany.mockResolvedValue([]);
    prismaMock.clip.findFirst.mockResolvedValue(null);
    prismaMock.clip.findUnique.mockResolvedValue(null);
    prismaMock.clip.updateMany.mockResolvedValue({ count: 1 });
    queueAssetMediaSync.mockResolvedValue({ count: 1 });
    reconcileAssetMedia.mockResolvedValue({ state: 'SYNCED' });
    notifyDashboardAssetChange.mockResolvedValue(undefined);
    slackMock.isConfigured.mockReturnValue(false);
    slackMock.postToChannel.mockResolvedValue({ ok: true });
    fsMock.unlink.mockResolvedValue(undefined);
    fsMock.realpath.mockImplementation(async value => value);
    withAssetMediaLock.mockImplementation(async (_id, work) => ({
        acquired: true,
        value: await work(async () => {}),
    }));
});

afterEach(() => {
    stopMuxSync();
    stopUploadCleanup();
    vi.useRealTimers();
});

function createFastifyHarness() {
    return {
        log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
        io: { to: vi.fn(() => ({ emit: vi.fn() })) },
    };
}

describe('media reconciliation job', () => {
    it('reconciles due assets through the coordinator in bounded batches', async () => {
        const fastify = createFastifyHarness();
        prismaMock.asset.findMany.mockResolvedValueOnce([{ id: 'asset-active' }, { id: 'asset-paused' }]);
        startMuxSync(fastify);
        await vi.advanceTimersByTimeAsync(10_000);

        expect(prismaMock.asset.findMany).toHaveBeenCalledWith(expect.objectContaining({
            where: { mediaSyncNextAt: { lte: expect.any(Date) } },
            take: 20,
        }));
        expect(reconcileAssetMedia.mock.calls.map(call => call[1])).toEqual(['asset-active', 'asset-paused']);
    });

    it('continues local-media cleanup even when Mux is not configured', async () => {
        const fastify = createFastifyHarness();
        muxState.enabled = false;
        prismaMock.asset.findMany.mockResolvedValueOnce([{ id: 'local-asset' }]);
        startMuxSync(fastify);
        await vi.advanceTimersByTimeAsync(10_000);

        expect(reconcileAssetMedia.mock.calls[0][1]).toBe('local-asset');
        expect(prismaMock.clip.findMany).not.toHaveBeenCalled();
    });

    it('queues each active ready asset with missing playback only once', async () => {
        const fastify = createFastifyHarness();
        prismaMock.clip.findMany.mockResolvedValueOnce([{ assetId: 'asset-1' }, { assetId: 'asset-1' }]);
        startMuxSync(fastify);
        await vi.advanceTimersByTimeAsync(10_000);

        expect(queueAssetMediaSync).toHaveBeenCalledTimes(1);
        expect(queueAssetMediaSync).toHaveBeenCalledWith(prismaMock, 'asset-1');
        expect(reconcileAssetMedia.mock.calls[0][1]).toBe('asset-1');
    });

    it('marks a still-missing upload as ERROR and sends the existing Slack alert', async () => {
        const fastify = createFastifyHarness();
        prismaMock.clip.findMany
            .mockResolvedValueOnce([])
            .mockResolvedValueOnce([{
                id: 'clip-1',
                createdAt: new Date(Date.now() - 20 * 60 * 1000),
                asset: { id: 'asset-1', mediasourceId: '100000001', mediaSyncState: 'PENDING' },
            }]);
        prismaMock.clip.findUnique.mockResolvedValueOnce({ status: 'PROCESSING', muxAssetId: null });
        slackMock.isConfigured.mockReturnValue(true);
        startMuxSync(fastify);
        await vi.advanceTimersByTimeAsync(10_000);

        expect(prismaMock.clip.updateMany).toHaveBeenCalledWith({
            where: { id: 'clip-1', status: 'PROCESSING', muxAssetId: null },
            data: { status: 'ERROR' },
        });
        expect(prismaMock.asset.updateMany).toHaveBeenCalledWith({
            where: { id: 'asset-1' }, data: { status: 'ERROR' },
        });
        expect(notifyDashboardAssetChange).toHaveBeenCalledWith(fastify, 'asset-1');
        expect(slackMock.postToChannel).toHaveBeenCalledWith(
            'general', expect.stringContaining('Upload failed'), undefined, { requestId: 'job:mux-sync' },
        );
    });

    it('does not mark an upload ERROR if its Mux asset was linked concurrently', async () => {
        const fastify = createFastifyHarness();
        prismaMock.clip.findMany
            .mockResolvedValueOnce([])
            .mockResolvedValueOnce([{
                id: 'clip-1',
                createdAt: new Date(Date.now() - 20 * 60 * 1000),
                asset: { id: 'asset-1', mediasourceId: '100000001', mediaSyncState: 'PENDING' },
            }]);
        prismaMock.clip.findUnique.mockResolvedValueOnce({ status: 'PROCESSING', muxAssetId: null });
        prismaMock.clip.updateMany.mockResolvedValueOnce({ count: 0 });
        startMuxSync(fastify);
        await vi.advanceTimersByTimeAsync(10_000);

        expect(prismaMock.asset.updateMany).not.toHaveBeenCalled();
        expect(notifyDashboardAssetChange).not.toHaveBeenCalled();
    });

    it('logs failures and stops the pending startup timer', async () => {
        const fastify = createFastifyHarness();
        prismaMock.asset.findMany.mockRejectedValueOnce(new Error('database unavailable'));
        startMuxSync(fastify);
        await vi.advanceTimersByTimeAsync(10_000);
        expect(fastify.log.error).toHaveBeenCalledWith(
            { err: { message: 'database unavailable' } }, 'Mux sync job failed',
        );
        stopMuxSync();
        startMuxSync(fastify);
        stopMuxSync();
        prismaMock.asset.findMany.mockClear();
        await vi.advanceTimersByTimeAsync(10_000);
        expect(prismaMock.asset.findMany).not.toHaveBeenCalled();
    });
});

describe('upload cleanup job', () => {
    it('cleans orphaned uploads, updates asset status, and alerts Slack', async () => {
        const fastify = createFastifyHarness();
        prismaMock.asset.findMany.mockResolvedValueOnce([{ id: 'asset-orphan' }]);
        prismaMock.asset.findFirst.mockResolvedValueOnce({
            id: 'asset-orphan',
            mediasourceId: '100000999',
            createdAt: new Date(Date.now() - 90 * 60 * 1000),
            clips: [{ id: 'clip-1', storageUrl: '/uploads/orphan.mp4' }],
            user: { name: 'Reporter Name' },
        });
        slackMock.isConfigured.mockReturnValue(true);
        startUploadCleanup(fastify);
        await vi.advanceTimersByTimeAsync(5 * 60 * 1000);

        expect(prismaMock.asset.update).toHaveBeenCalledWith({
            where: { id: 'asset-orphan' }, data: { status: 'ERROR' },
        });
        expect(prismaMock.asset.findFirst).toHaveBeenCalledWith(expect.objectContaining({
            where: expect.objectContaining({ moderation: 'ACTIVE', mediaPlaybackReset: false }),
        }));
        expect(prismaMock.clip.updateMany).toHaveBeenCalledWith({
            where: { id: 'clip-1', assetId: 'asset-orphan', storageUrl: '/uploads/orphan.mp4' },
            data: { storageUrl: null },
        });
        expect(slackMock.postToChannel).toHaveBeenCalledWith(
            'general', expect.stringContaining('Orphaned upload cleaned up'), undefined, { requestId: 'job:upload-cleanup' },
        );
    });

    it('does not delete local media if an asset becomes moderated before cleanup', async () => {
        const fastify = createFastifyHarness();
        prismaMock.asset.findMany.mockResolvedValueOnce([{ id: 'asset-orphan' }]);
        prismaMock.asset.findFirst.mockResolvedValueOnce(null);
        startUploadCleanup(fastify);
        await vi.advanceTimersByTimeAsync(1);

        expect(fsMock.unlink).not.toHaveBeenCalled();
        expect(prismaMock.asset.update).not.toHaveBeenCalled();
    });

    it('reports a shared local file instead of deleting it or claiming cleanup', async () => {
        const fastify = createFastifyHarness();
        prismaMock.asset.findMany.mockResolvedValueOnce([{ id: 'asset-orphan' }]);
        prismaMock.asset.findFirst.mockResolvedValueOnce({
            id: 'asset-orphan',
            clips: [{ id: 'clip-1', storageUrl: '/uploads/shared.mp4' }],
        });
        prismaMock.clip.findFirst.mockResolvedValueOnce({ id: 'other-clip' });
        startUploadCleanup(fastify);
        await vi.advanceTimersByTimeAsync(1);

        expect(fsMock.unlink).not.toHaveBeenCalled();
        expect(prismaMock.asset.update).not.toHaveBeenCalled();
        expect(fastify.log.error).toHaveBeenCalledWith(
            expect.objectContaining({ assetId: 'asset-orphan' }), 'Could not clean orphaned upload',
        );
    });

    it('reports local deletion errors instead of claiming cleanup', async () => {
        const fastify = createFastifyHarness();
        prismaMock.asset.findMany.mockResolvedValueOnce([{ id: 'asset-orphan' }]);
        prismaMock.asset.findFirst.mockResolvedValueOnce({
            id: 'asset-orphan',
            clips: [{ id: 'clip-1', storageUrl: '/uploads/orphan.mp4' }],
        });
        fsMock.unlink.mockRejectedValueOnce(Object.assign(new Error('permission denied'), { code: 'EACCES' }));
        startUploadCleanup(fastify);
        await vi.advanceTimersByTimeAsync(1);

        expect(prismaMock.asset.update).not.toHaveBeenCalled();
        expect(fastify.log.error).toHaveBeenCalledWith(
            expect.objectContaining({ assetId: 'asset-orphan' }), 'Could not clean orphaned upload',
        );
    });
});
