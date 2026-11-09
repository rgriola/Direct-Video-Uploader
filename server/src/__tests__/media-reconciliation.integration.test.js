import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { acquireIntegrationDatabaseLock } from './helpers/database-lock.js';
import { notifyDashboardAssetChange } from '../ws/dashboard-notifications.js';

vi.mock('../ws/dashboard-notifications.js', () => ({
    notifyDashboardAssetChange: vi.fn(async () => {}),
}));

vi.mock('../lib/slack.js', () => ({ isConfigured: () => false }));

const databaseUrl = process.env.TEST_DATABASE_URL;
if (process.env.CI && !databaseUrl) {
    throw new Error('TEST_DATABASE_URL is required for media reconciliation tests in CI');
}
if (databaseUrl) {
    const url = new URL(databaseUrl);
    if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
        || !url.pathname.slice(1).startsWith('dvu_scope_test_')
        || process.env.DATABASE_URL !== databaseUrl) {
        throw new Error('Media reconciliation tests require a dedicated local dvu_scope_test_ database');
    }
    process.env.MUX_TOKEN_ID = '';
    process.env.MUX_TOKEN_SECRET = '';
}

const integration = databaseUrl ? describe : describe.skip;

integration('media reconciliation against PostgreSQL', () => {
    let prisma;
    let releaseDatabaseLock;
    let createMediaReconciler;
    let withAssetMediaLock;
    let remoteAssets;
    let remoteUploads;
    let muxApi;
    let fastify;
    let reconcile;
    let emitted;

    beforeAll(async () => {
        const database = await import('../lib/prisma.js');
        prisma = database.default;
        releaseDatabaseLock = await acquireIntegrationDatabaseLock(database.pool);
        ({ withAssetMediaLock } = await import('../lib/media-lock.js'));
        ({ createMediaReconciler } = await import('../lib/media-reconciliation.js'));
        await prisma.user.create({
            data: {
                id: 'media-reconcile-user',
                name: 'Media Test',
                phoneNumber: '5590000001',
                pinHash: 'integration-test',
            },
        });
    });

    beforeEach(async () => {
        vi.clearAllMocks();
        await prisma.asset.deleteMany({ where: { userId: 'media-reconcile-user' } });
        remoteAssets = new Map();
        remoteUploads = new Map();
        emitted = vi.fn();
        fastify = {
            log: { error: vi.fn(), warn: vi.fn(), info: vi.fn() },
            io: { to: vi.fn(() => ({ emit: emitted })) },
        };
        muxApi = {
            inspectMuxAsset: vi.fn(async id => ({
                ok: true,
                asset: remoteAssets.has(id) ? structuredClone(remoteAssets.get(id)) : null,
            })),
            inspectMuxUpload: vi.fn(async id => remoteUploads.has(id)
                ? { ok: true, upload: structuredClone(remoteUploads.get(id)) }
                : { ok: false, error: 'Mux upload inspection failed' }),
            disableMuxPlayback: vi.fn(async id => {
                const asset = remoteAssets.get(id);
                if (asset) asset.playback_ids = (asset.playback_ids || []).filter(item => item.policy !== 'public');
                return { ok: true };
            }),
            deleteMuxAsset: vi.fn(async id => {
                remoteAssets.delete(id);
                return true;
            }),
            cancelMuxUpload: vi.fn(async id => {
                const upload = remoteUploads.get(id);
                if (!upload || upload.status !== 'waiting') return { ok: false, error: 'Cancellation failed' };
                upload.status = 'cancelled';
                return { ok: true };
            }),
            createMuxPublicPlayback: vi.fn(async id => {
                const asset = remoteAssets.get(id);
                const playbackId = `new-${id}`;
                asset.playback_ids.push({ policy: 'public', id: playbackId });
                return { ok: true, playbackId };
            }),
        };
        reconcile = createMediaReconciler({ db: prisma, muxApi, withLock: withAssetMediaLock });
    });

    afterAll(async () => {
        if (prisma) {
            try {
                await prisma.asset.deleteMany({ where: { userId: 'media-reconcile-user' } });
                await prisma.user.deleteMany({ where: { id: 'media-reconcile-user' } });
            } finally {
                await releaseDatabaseLock?.();
                await prisma.$disconnect();
            }
        }
    });

    async function createAsset({ moderation = 'ACTIVE', reset = false, clip = {} } = {}) {
        return prisma.asset.create({
            data: {
                id: 'media-reconcile-asset',
                userId: 'media-reconcile-user',
                moderation,
                mediaPlaybackReset: reset,
                clips: {
                    create: {
                        id: 'media-reconcile-clip',
                        status: 'PROCESSING',
                        ...clip,
                    },
                },
            },
            include: { clips: true },
        });
    }

    it('reconciles an active ready asset with no automatic playback ID', async () => {
        await createAsset({ clip: { muxAssetId: 'mux-active' } });
        remoteAssets.set('mux-active', { status: 'ready', playback_ids: [] });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'SYNCED' });
        const clip = await prisma.clip.findUnique({ where: { id: 'media-reconcile-clip' } });
        expect(clip.muxPlaybackId).toBe('new-mux-active');
        expect(clip.status).toBe('READY');
        expect(clip.thumbnailUrl).toBe('https://image.mux.com/new-mux-active/thumbnail.png?width=640');
        expect(fastify.io.to).toHaveBeenCalledWith('user:media-reconcile-user');
        expect(emitted).toHaveBeenCalledWith('mux:ready', expect.objectContaining({
            clipId: clip.id,
            muxPlaybackId: 'new-mux-active',
            thumbnailUrl: clip.thumbnailUrl,
        }));
        expect(notifyDashboardAssetChange).toHaveBeenCalledWith(fastify, 'media-reconcile-asset');

        await reconcile(fastify, 'media-reconcile-asset');
        expect(muxApi.createMuxPublicPlayback).toHaveBeenCalledTimes(1);
    });

    it('does not expose revoked playback after restored playback creation is rejected', async () => {
        await createAsset({
            reset: true,
            clip: {
                status: 'READY',
                muxAssetId: 'mux-restoring',
                muxPlaybackId: 'old-playback',
                streamUrl: 'https://stream.mux.com/old-playback.m3u8',
                thumbnailUrl: 'https://image.mux.com/old-playback/thumbnail.png',
            },
        });
        remoteAssets.set('mux-restoring', {
            status: 'ready',
            playback_ids: [{ policy: 'public', id: 'old-playback' }],
        });
        muxApi.createMuxPublicPlayback.mockResolvedValueOnce({
            ok: false,
            indeterminate: false,
            error: 'Mux playback creation was rejected',
        });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'ERROR' });
        expect(remoteAssets.get('mux-restoring').playback_ids).toEqual([]);
        const clip = await prisma.clip.findUnique({ where: { id: 'media-reconcile-clip' } });
        expect(clip).toMatchObject({ muxPlaybackId: null, streamUrl: null, thumbnailUrl: null });
        expect(emitted).not.toHaveBeenCalled();
    });

    it('retains old playback evidence when restore revocation is not verified', async () => {
        await createAsset({
            reset: true,
            clip: {
                status: 'READY',
                muxAssetId: 'mux-unverified',
                muxPlaybackId: 'old-playback',
                streamUrl: 'https://stream.mux.com/old-playback.m3u8',
                thumbnailUrl: 'https://image.mux.com/old-playback/thumbnail.png',
            },
        });
        remoteAssets.set('mux-unverified', {
            status: 'ready',
            playback_ids: [{ policy: 'public', id: 'old-playback' }],
        });
        muxApi.disableMuxPlayback.mockResolvedValueOnce({ ok: false, error: 'Revocation was not verified' });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'ERROR' });
        const [asset, clip] = await Promise.all([
            prisma.asset.findUnique({ where: { id: 'media-reconcile-asset' } }),
            prisma.clip.findUnique({ where: { id: 'media-reconcile-clip' } }),
        ]);
        expect(asset.mediaPlaybackReset).toBe(true);
        expect(clip).toMatchObject({
            muxPlaybackId: 'old-playback',
            streamUrl: 'https://stream.mux.com/old-playback.m3u8',
            thumbnailUrl: 'https://image.mux.com/old-playback/thumbnail.png',
        });
        expect(muxApi.createMuxPublicPlayback).not.toHaveBeenCalled();
    });

    it('discovers and revokes a late asset when a paused upload misses its webhook', async () => {
        await createAsset({
            moderation: 'PAUSED',
            reset: true,
            clip: { muxUploadId: 'upload-paused', status: 'ERROR' },
        });
        remoteUploads.set('upload-paused', { status: 'waiting' });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'PENDING' });

        remoteUploads.set('upload-paused', { status: 'asset_created', asset_id: 'mux-paused' });
        remoteAssets.set('mux-paused', {
            status: 'ready',
            playback_ids: [{ policy: 'public', id: 'legacy-public' }],
        });
        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'SYNCED' });
        expect(remoteAssets.get('mux-paused').playback_ids).toEqual([]);
        const clip = await prisma.clip.findUnique({ where: { id: 'media-reconcile-clip' } });
        expect(clip.muxAssetId).toBe('mux-paused');
        expect(clip.muxPlaybackId).toBeNull();
        expect(emitted).not.toHaveBeenCalled();
    });

    it('does not let a stale pause revoke the ID created by a later restore', async () => {
        await createAsset({ moderation: 'PAUSED', reset: true, clip: { muxAssetId: 'mux-race' } });
        remoteAssets.set('mux-race', {
            status: 'ready',
            playback_ids: [{ policy: 'public', id: 'old-public' }],
        });

        let enter;
        let release;
        const entered = new Promise(resolve => { enter = resolve; });
        const released = new Promise(resolve => { release = resolve; });
        const disable = muxApi.disableMuxPlayback.getMockImplementation();
        muxApi.disableMuxPlayback.mockImplementationOnce(async id => {
            enter();
            await released;
            return disable(id);
        });

        const pausing = reconcile(fastify, 'media-reconcile-asset');
        try {
            await entered;
            await prisma.asset.update({
                where: { id: 'media-reconcile-asset' },
                data: {
                    moderation: 'ACTIVE',
                    mediaPlaybackReset: true,
                    mediaSyncState: 'PENDING',
                    mediaSyncRevision: { increment: 1 },
                },
            });
        } finally {
            release();
        }
        await expect(pausing).resolves.toMatchObject({ state: 'PENDING' });
        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'SYNCED' });
        expect(remoteAssets.get('mux-race').playback_ids).toEqual([
            { policy: 'public', id: 'new-mux-race' },
        ]);
        const clip = await prisma.clip.findUnique({ where: { id: 'media-reconcile-clip' } });
        expect(clip.muxPlaybackId).toBe('new-mux-race');
    });

    it('revokes an ID created while a pause is being requested', async () => {
        await createAsset({ clip: { muxAssetId: 'mux-create-race' } });
        remoteAssets.set('mux-create-race', { status: 'ready', playback_ids: [] });

        let enter;
        let release;
        const entered = new Promise(resolve => { enter = resolve; });
        const released = new Promise(resolve => { release = resolve; });
        const create = muxApi.createMuxPublicPlayback.getMockImplementation();
        muxApi.createMuxPublicPlayback.mockImplementationOnce(async id => {
            enter();
            await released;
            return create(id);
        });

        const creating = reconcile(fastify, 'media-reconcile-asset');
        try {
            await entered;
            await prisma.asset.update({
                where: { id: 'media-reconcile-asset' },
                data: {
                    moderation: 'PAUSED',
                    mediaPlaybackReset: true,
                    mediaSyncState: 'PENDING',
                    mediaSyncRevision: { increment: 1 },
                },
            });
            await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'PENDING' });
        } finally {
            release();
        }
        await expect(creating).resolves.toMatchObject({ state: 'SYNCED' });
        expect(remoteAssets.get('mux-create-race').playback_ids).toEqual([]);
        expect(emitted).not.toHaveBeenCalled();
        const clip = await prisma.clip.findUnique({ where: { id: 'media-reconcile-clip' } });
        expect(clip.muxPlaybackId).toBeNull();
    });

    it('keeps an uncertain playback creation unresolved and revokes IDs that appear later', async () => {
        await createAsset({
            clip: {
                muxAssetId: 'mux-uncertain',
                muxPlaybackId: 'old-uncertain-playback',
                streamUrl: 'https://stream.mux.com/old-uncertain-playback.m3u8',
            },
        });
        remoteAssets.set('mux-uncertain', { status: 'ready', playback_ids: [] });
        muxApi.createMuxPublicPlayback.mockResolvedValueOnce({
            ok: false,
            indeterminate: true,
            error: 'Mux playback creation outcome is unknown',
        });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'ERROR' });
        let asset = await prisma.asset.findUnique({ where: { id: 'media-reconcile-asset' } });
        expect(asset.mediaCreateOperationId).toBeTruthy();
        expect(asset.mediaPlaybackReset).toBe(true);
        expect((await prisma.clip.findUnique({ where: { id: 'media-reconcile-clip' } })).muxPlaybackId)
            .toBe('old-uncertain-playback');

        remoteAssets.get('mux-uncertain').playback_ids.push({ policy: 'public', id: 'late-public' });
        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'ERROR' });
        asset = await prisma.asset.findUnique({ where: { id: 'media-reconcile-asset' } });
        expect(asset.mediaCreateOperationId).toBeTruthy();
        expect(remoteAssets.get('mux-uncertain').playback_ids).toEqual([]);
        expect(muxApi.createMuxPublicPlayback).toHaveBeenCalledTimes(1);
    });

    it('retains and revokes the Mux asset named by an unresolved creation marker', async () => {
        await createAsset();
        await prisma.asset.update({
            where: { id: 'media-reconcile-asset' },
            data: {
                mediaCreateOperationId: 'missing-reference-operation',
                mediaCreateMuxAssetId: 'mux-from-operation',
                mediaCreateStartedAt: new Date(),
            },
        });
        remoteAssets.set('mux-from-operation', {
            status: 'ready',
            playback_ids: [{ policy: 'public', id: 'late-public' }],
        });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'ERROR' });
        expect(remoteAssets.get('mux-from-operation').playback_ids).toEqual([]);
        expect(await prisma.muxAssetReference.findUnique({ where: { muxAssetId: 'mux-from-operation' } }))
            .toMatchObject({ assetId: 'media-reconcile-asset' });
    });

    it('cancels waiting uploads for removed assets', async () => {
        await createAsset({
            moderation: 'REMOVED',
            reset: true,
            clip: { muxUploadId: 'upload-removed' },
        });
        remoteUploads.set('upload-removed', { status: 'waiting' });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'SYNCED' });
        expect(remoteUploads.get('upload-removed').status).toBe('cancelled');
        expect(muxApi.cancelMuxUpload).toHaveBeenCalledWith('upload-removed');
    });

    it('retains and revokes late Mux media even when its clip is gone', async () => {
        await createAsset({ moderation: 'PAUSED', reset: true });
        await prisma.muxAssetReference.create({
            data: { muxAssetId: 'mux-orphan', assetId: 'media-reconcile-asset', clipId: 'deleted-clip' },
        });
        remoteAssets.set('mux-orphan', {
            status: 'ready',
            playback_ids: [{ policy: 'public', id: 'late-public' }],
        });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'SYNCED' });
        expect(remoteAssets.get('mux-orphan').playback_ids).toEqual([]);
        expect(await prisma.muxAssetReference.findUnique({ where: { muxAssetId: 'mux-orphan' } }))
            .toMatchObject({ assetId: 'media-reconcile-asset' });
    });

    it('removes orphaned Mux media for a removed asset', async () => {
        await createAsset({ moderation: 'REMOVED', reset: true });
        await prisma.muxAssetReference.create({
            data: { muxAssetId: 'mux-orphan', assetId: 'media-reconcile-asset' },
        });
        remoteAssets.set('mux-orphan', { status: 'ready', playback_ids: [] });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'SYNCED' });
        expect(remoteAssets.has('mux-orphan')).toBe(false);
    });

    it('does not delete a local file that another asset still references', async () => {
        await createAsset({
            moderation: 'REMOVED',
            reset: true,
            clip: { storageUrl: '/uploads/shared-media.mp4' },
        });
        await prisma.asset.create({
            data: {
                id: 'media-reconcile-other',
                userId: 'media-reconcile-user',
                clips: { create: { id: 'media-reconcile-other-clip', storageUrl: '/uploads/shared-media.mp4' } },
            },
        });
        const fileSystem = { unlink: vi.fn(), stat: vi.fn(), realpath: vi.fn(async value => value) };
        reconcile = createMediaReconciler({ db: prisma, muxApi, withLock: withAssetMediaLock, fileSystem });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({
            state: 'ERROR',
            message: 'Local media is shared by multiple clips and requires manual review',
        });
        expect(fileSystem.unlink).not.toHaveBeenCalled();
        expect((await prisma.clip.findUnique({ where: { id: 'media-reconcile-clip' } })).storageUrl)
            .toBe('/uploads/shared-media.mp4');
    });

    it('does not delete a local file reached through a symbolic link', async () => {
        await createAsset({
            moderation: 'REMOVED',
            reset: true,
            clip: { storageUrl: '/uploads/alias/video.mp4' },
        });
        const fileSystem = {
            unlink: vi.fn(),
            stat: vi.fn(),
            realpath: vi.fn(async value => value.endsWith('/alias/video.mp4') ? '/outside/video.mp4' : value),
        };
        reconcile = createMediaReconciler({ db: prisma, muxApi, withLock: withAssetMediaLock, fileSystem });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({
            state: 'ERROR',
            message: 'Local upload path contains a symbolic link',
        });
        expect(fileSystem.unlink).not.toHaveBeenCalled();
        expect((await prisma.clip.findUnique({ where: { id: 'media-reconcile-clip' } })).storageUrl)
            .toBe('/uploads/alias/video.mp4');
    });

    it('does not claim cleanup for an unrecognized local media URL', async () => {
        await createAsset({
            moderation: 'REMOVED',
            reset: true,
            clip: { storageUrl: 'https://storage.example/unknown-video' },
        });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({
            state: 'ERROR',
            message: 'Unrecognized local media URL requires manual review',
        });
        expect((await prisma.clip.findUnique({ where: { id: 'media-reconcile-clip' } })).storageUrl)
            .toBe('https://storage.example/unknown-video');
    });

    it('revokes every Mux asset when a clip has conflicting references', async () => {
        await createAsset({
            moderation: 'PAUSED',
            reset: true,
            clip: { muxAssetId: 'mux-first', muxUploadId: 'upload-conflict' },
        });
        remoteUploads.set('upload-conflict', { status: 'asset_created', asset_id: 'mux-second' });
        for (const id of ['mux-first', 'mux-second']) {
            remoteAssets.set(id, { status: 'ready', playback_ids: [{ policy: 'public', id: `public-${id}` }] });
        }

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'ERROR' });
        expect(remoteAssets.get('mux-first').playback_ids).toEqual([]);
        expect(remoteAssets.get('mux-second').playback_ids).toEqual([]);
        expect(await prisma.muxAssetReference.count({ where: { assetId: 'media-reconcile-asset' } })).toBe(2);
    });

    it('creates only one playback ID when multiple clips reference the same Mux asset', async () => {
        await createAsset({ clip: { muxAssetId: 'mux-shared' } });
        await prisma.clip.create({
            data: { id: 'media-reconcile-clip-two', assetId: 'media-reconcile-asset', muxAssetId: 'mux-shared' },
        });
        remoteAssets.set('mux-shared', { status: 'ready', playback_ids: [] });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'SYNCED' });
        expect(muxApi.createMuxPublicPlayback).toHaveBeenCalledTimes(1);
        expect(await prisma.clip.findMany({
            where: { assetId: 'media-reconcile-asset' },
            select: { muxPlaybackId: true },
        })).toEqual([{ muxPlaybackId: 'new-mux-shared' }, { muxPlaybackId: 'new-mux-shared' }]);
    });

    it('recognizes media linked to a live clip even when its retained reference names a deleted clip', async () => {
        await createAsset({ clip: { muxAssetId: 'mux-relinked' } });
        await prisma.muxAssetReference.create({
            data: { muxAssetId: 'mux-relinked', assetId: 'media-reconcile-asset', clipId: 'deleted-clip' },
        });
        remoteAssets.set('mux-relinked', { status: 'ready', playback_ids: [] });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'SYNCED' });
        expect(muxApi.createMuxPublicPlayback).toHaveBeenCalledTimes(1);
        expect((await prisma.clip.findUnique({ where: { id: 'media-reconcile-clip' } })).muxPlaybackId)
            .toBe('new-mux-relinked');
    });

    it('does not overwrite a newer queued revision when stale work fails', async () => {
        await createAsset({ clip: { muxAssetId: 'mux-stale-error' } });
        muxApi.inspectMuxAsset.mockImplementationOnce(async () => {
            await prisma.asset.update({
                where: { id: 'media-reconcile-asset' },
                data: { mediaSyncRevision: { increment: 1 }, mediaSyncState: 'PENDING' },
            });
            throw new Error('injected failure');
        });

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'ERROR' });
        const asset = await prisma.asset.findUnique({ where: { id: 'media-reconcile-asset' } });
        expect(asset.mediaSyncRevision).toBe(1);
        expect(asset.mediaSyncState).toBe('PENDING');
        expect(asset.mediaSyncError).toBeNull();
    });

    it('retains an in-flight create marker when its lock is lost', async () => {
        await createAsset({ clip: { muxAssetId: 'mux-lock-loss' } });
        remoteAssets.set('mux-lock-loss', { status: 'ready', playback_ids: [] });
        let lost = false;
        const create = muxApi.createMuxPublicPlayback.getMockImplementation();
        muxApi.createMuxPublicPlayback.mockImplementationOnce(async id => {
            const result = await create(id);
            lost = true;
            return result;
        });
        const losingLock = async (_assetId, work) => ({
            acquired: true,
            value: await work(async () => {
                if (lost) throw new Error('lock lost');
            }),
        });
        const interrupted = createMediaReconciler({ db: prisma, muxApi, withLock: losingLock });

        await expect(interrupted(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'ERROR' });
        let asset = await prisma.asset.findUnique({ where: { id: 'media-reconcile-asset' } });
        expect(asset.mediaCreateOperationId).toBeTruthy();
        expect(asset.mediaSyncState).toBe('PENDING');

        await expect(reconcile(fastify, 'media-reconcile-asset')).resolves.toMatchObject({ state: 'ERROR' });
        asset = await prisma.asset.findUnique({ where: { id: 'media-reconcile-asset' } });
        expect(asset.mediaCreateOperationId).toBeTruthy();
        expect(remoteAssets.get('mux-lock-loss').playback_ids).toEqual([]);
    });
});
