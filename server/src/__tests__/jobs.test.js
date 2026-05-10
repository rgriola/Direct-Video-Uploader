// Last updated: May 9, 2026 - 7:33pm - GPT-5.3-Codex
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = {
    clip: {
        findMany: vi.fn(),
        update: vi.fn(),
    },
    asset: {
        findMany: vi.fn(),
        update: vi.fn(),
        findUnique: vi.fn(),
    },
};

const muxState = {
    enabled: true,
};

const muxMock = {
    getMuxAsset: vi.fn(),
    getMuxUpload: vi.fn(),
};

const slackMock = {
    isConfigured: vi.fn(),
    postToChannel: vi.fn(),
};

const fsMock = {
    unlink: vi.fn(),
};

vi.mock('../lib/prisma.js', () => ({
    default: prismaMock,
}));

vi.mock('../lib/mux.js', () => ({
    get isMuxEnabled() {
        return muxState.enabled;
    },
    getMuxAsset: muxMock.getMuxAsset,
    getMuxUpload: muxMock.getMuxUpload,
}));

vi.mock('../lib/slack.js', () => ({
    isConfigured: slackMock.isConfigured,
    postToChannel: slackMock.postToChannel,
}));

vi.mock('../lib/utils.js', async () => {
    const actual = await vi.importActual('../lib/utils.js');
    return {
        ...actual,
        dbRetry: async (fn) => fn(),
    };
});

vi.mock('fs/promises', () => ({
    default: fsMock,
    unlink: fsMock.unlink,
}));

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

    prismaMock.clip.findMany.mockResolvedValue([]);
    prismaMock.clip.update.mockResolvedValue({});
    prismaMock.asset.findMany.mockResolvedValue([]);
    prismaMock.asset.update.mockResolvedValue({});
    prismaMock.asset.findUnique.mockResolvedValue({
        originalFileName: 'field.mp4',
        formResponse: {
            slug: 'slug',
            type: 'Raw',
            description: 'desc',
            priority: 'HIGH',
        },
    });

    muxMock.getMuxAsset.mockResolvedValue(null);
    muxMock.getMuxUpload.mockResolvedValue(null);

    slackMock.isConfigured.mockReturnValue(false);
    slackMock.postToChannel.mockResolvedValue({ ok: true });

    fsMock.unlink.mockResolvedValue(undefined);
});

afterEach(() => {
    stopMuxSync();
    stopUploadCleanup();
    vi.useRealTimers();
});

afterAll(() => {
    stopMuxSync();
    stopUploadCleanup();
});

function createFastifyHarness() {
    const ioEmitSpy = vi.fn();

    const fastify = {
        log: {
            info: vi.fn(),
            warn: vi.fn(),
            error: vi.fn(),
        },
        io: {
            to: vi.fn(() => ({ emit: ioEmitSpy })),
        },
        userSockets: new Map([['user-1', new Set(['socket-1'])]]),
    };

    return { fastify, ioEmitSpy };
}

describe('background jobs coverage', () => {
    it('skips mux sync when mux is disabled', () => {
        const { fastify } = createFastifyHarness();
        muxState.enabled = false;

        startMuxSync(fastify);

        expect(fastify.log.info).toHaveBeenCalledWith('Mux sync skipped because mux is not configured');
    });

    it('syncs processing clips to READY and emits mux:ready event', async () => {
        const { fastify, ioEmitSpy } = createFastifyHarness();

        prismaMock.clip.findMany.mockResolvedValueOnce([
            {
                id: 'clip-1',
                status: 'PROCESSING',
                muxAssetId: 'mux-1',
                muxUploadId: null,
                duration: 21,
                resolution: '1920x1080',
                fileSize: 1234n,
                createdAt: new Date(Date.now() - 10 * 60 * 1000),
                asset: {
                    id: 'asset-1',
                    mediasourceId: '100000001',
                    userId: 'user-1',
                },
            },
        ]);
        prismaMock.clip.findMany.mockResolvedValueOnce([]);

        muxMock.getMuxAsset.mockResolvedValue({
            status: 'ready',
            playback_ids: [{ policy: 'public', id: 'playback-1' }],
        });

        startMuxSync(fastify);

        await vi.advanceTimersByTimeAsync(10_000);

        expect(prismaMock.clip.update).toHaveBeenCalledWith({
            where: { id: 'clip-1' },
            data: {
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
        expect(ioEmitSpy).toHaveBeenCalledWith(
            'mux:ready',
            expect.objectContaining({
                assetId: 'asset-1',
                clipId: 'clip-1',
                muxPlaybackId: 'playback-1',
            })
        );
    });

    it('marks clip as ERROR on mux errored status and sends slack alert', async () => {
        const { fastify } = createFastifyHarness();

        prismaMock.clip.findMany.mockResolvedValueOnce([
            {
                id: 'clip-err',
                status: 'PROCESSING',
                muxAssetId: 'mux-err',
                muxUploadId: null,
                createdAt: new Date(Date.now() - 15 * 60 * 1000),
                asset: {
                    id: 'asset-err',
                    mediasourceId: '100000555',
                    userId: 'user-1',
                },
            },
        ]);
        prismaMock.clip.findMany.mockResolvedValueOnce([]);

        muxMock.getMuxAsset.mockResolvedValue({ status: 'errored' });
        slackMock.isConfigured.mockReturnValue(true);

        startMuxSync(fastify);

        await vi.advanceTimersByTimeAsync(10_000);

        expect(prismaMock.clip.update).toHaveBeenCalledWith({
            where: { id: 'clip-err' },
            data: { status: 'ERROR' },
        });
        expect(prismaMock.asset.update).toHaveBeenCalledWith({
            where: { id: 'asset-err' },
            data: { status: 'ERROR' },
        });
        expect(slackMock.postToChannel).toHaveBeenCalledWith(
            'general',
            expect.stringContaining('Mux processing error'),
            undefined,
            { requestId: 'job:mux-sync' }
        );
    });

    it('cleans orphaned uploads, updates asset status, and alerts slack', async () => {
        const { fastify } = createFastifyHarness();

        prismaMock.asset.findMany.mockResolvedValueOnce([
            {
                id: 'asset-orphan',
                mediasourceId: '100000999',
                createdAt: new Date(Date.now() - 90 * 60 * 1000),
                clips: [{ id: 'clip-1', storageUrl: '/uploads/orphan.mp4' }],
                user: { name: 'Reporter Name' },
            },
        ]);
        slackMock.isConfigured.mockReturnValue(true);

        startUploadCleanup(fastify);

        await vi.advanceTimersByTimeAsync(5 * 60 * 1000);

        expect(prismaMock.asset.update).toHaveBeenCalledWith({
            where: { id: 'asset-orphan' },
            data: { status: 'ERROR' },
        });
        expect(slackMock.postToChannel).toHaveBeenCalledWith(
            'general',
            expect.stringContaining('Orphaned upload cleaned up'),
            undefined,
            { requestId: 'job:upload-cleanup' }
        );
    });
});
