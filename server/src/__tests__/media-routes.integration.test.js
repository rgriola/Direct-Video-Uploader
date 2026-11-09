import Fastify from 'fastify';
import { readFile } from 'node:fs/promises';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { requireRole } from '../lib/authorization.js';
import { acquireIntegrationDatabaseLock, waitForBlockedQuery } from './helpers/database-lock.js';

const muxApi = vi.hoisted(() => ({
    createDirectUpload: vi.fn(),
    getMuxUpload: vi.fn(),
    inspectMuxUpload: vi.fn(),
    inspectMuxAsset: vi.fn(),
    cancelMuxUpload: vi.fn(),
    deleteMuxAsset: vi.fn(),
    disableMuxPlayback: vi.fn(),
    createMuxPublicPlayback: vi.fn(),
}));

vi.mock('../lib/mux.js', () => ({ ...muxApi, isMuxEnabled: true, MUX_ENV_KEY: '' }));
vi.mock('../lib/slack.js', () => ({ isConfigured: () => false }));
vi.mock('../ws/dashboard-notifications.js', () => ({ notifyDashboardAssetChange: vi.fn(async () => {}) }));

const databaseUrl = process.env.TEST_DATABASE_URL;
if (process.env.CI && !databaseUrl) {
    throw new Error('TEST_DATABASE_URL is required for media route integration tests in CI');
}
if (databaseUrl) {
    const url = new URL(databaseUrl);
    if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
        || !url.pathname.slice(1).startsWith('dvu_scope_test_')
        || process.env.DATABASE_URL !== databaseUrl) {
        throw new Error('Media route integration tests require a dedicated local dvu_scope_test_ database');
    }
}

const integration = databaseUrl ? describe : describe.skip;

function deferred() {
    let resolve;
    const promise = new Promise(done => { resolve = done; });
    return { promise, resolve };
}

integration('media routes against PostgreSQL', () => {
    const adminId = 'media-routes-admin';
    const userId = 'media-routes-user';
    const assetId = 'media-routes-asset';
    let app;
    let prisma;
    let pool;
    let releaseDatabaseLock;
    let withAssetMediaLock;
    let cleanupOrphanedUploads;

    beforeAll(async () => {
        const database = await import('../lib/prisma.js');
        prisma = database.default;
        pool = database.pool;
        releaseDatabaseLock = await acquireIntegrationDatabaseLock(pool);
        ({ withAssetMediaLock } = await import('../lib/media-lock.js'));
        ({ cleanupOrphanedUploads } = await import('../jobs/upload-cleanup.js'));
        const { default: adminRoutes } = await import('../routes/admin.js');
        const { default: assetRoutes } = await import('../routes/assets.js');
        const { default: moderationRoutes } = await import('../routes/moderation.js');

        await prisma.user.create({
            data: {
                id: adminId,
                name: 'Media Admin',
                phoneNumber: '5590000010',
                pinHash: 'integration-test',
                role: 'SUPER_ADMIN',
            },
        });

        app = Fastify({ logger: false });
        app.decorate('authenticate', async (request, reply) => {
            const user = await prisma.user.findUnique({ where: { id: request.headers['x-test-user'] || '' } });
            if (!user || user.status !== 'ACTIVE') return reply.status(401).send({ error: 'Unauthorized' });
            request.user = user;
        });
        app.decorate('requireRole', requireRole);
        app.decorate('io', {
            to: () => ({ emit: () => {} }),
            of: () => ({ sockets: new Map() }),
            sockets: { sockets: new Map() },
        });
        app.decorate('userSockets', new Map());
        await app.register(adminRoutes);
        await app.register(assetRoutes);
        await app.register(moderationRoutes);
    });

    beforeEach(async () => {
        await prisma.asset.deleteMany({ where: { userId } });
        await prisma.user.upsert({
            where: { id: userId },
            create: {
                id: userId,
                name: 'Media User',
                phoneNumber: '5590000011',
                pinHash: 'integration-test',
            },
            update: {},
        });
        await prisma.auditLog.deleteMany({ where: { actorUserId: adminId } });
        vi.resetAllMocks();
        muxApi.createDirectUpload.mockResolvedValue({
            uploadUrl: 'https://upload.example/video',
            muxUploadId: 'media-route-upload',
        });
        muxApi.inspectMuxUpload.mockResolvedValue({ ok: true, upload: { status: 'waiting' } });
        muxApi.inspectMuxAsset.mockResolvedValue({ ok: true, asset: null });
        muxApi.disableMuxPlayback.mockResolvedValue({ ok: true });
    });

    afterAll(async () => {
        if (app) await app.close();
        if (prisma) {
            try {
                await prisma.asset.deleteMany({ where: { userId } });
                await prisma.auditLog.deleteMany({ where: { actorUserId: adminId } });
                await prisma.user.deleteMany({ where: { id: { in: [adminId, userId] } } });
            } finally {
                await releaseDatabaseLock?.();
                await prisma.$disconnect();
            }
        }
    });

    function requestAs(actor, method, url, payload) {
        return app.inject({
            method,
            url,
            headers: { 'x-test-user': actor },
            ...(payload === undefined ? {} : { payload }),
        });
    }

    async function createAsset(data = {}) {
        return prisma.asset.create({ data: { id: assetId, userId, ...data } });
    }

    it('does not return an upload URL when moderation changes during Mux creation', async () => {
        await createAsset();
        const entered = deferred();
        const release = deferred();
        muxApi.createDirectUpload.mockImplementationOnce(async () => {
            entered.resolve();
            await release.promise;
            return { uploadUrl: 'https://upload.example/video', muxUploadId: 'media-route-upload' };
        });

        const uploading = requestAs(userId, 'POST', `/api/assets/${assetId}/mux-upload`, {});
        try {
            await entered.promise;
            const pause = await requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
                moderation: 'PAUSED',
            });
            expect(pause.statusCode).toBe(202);
            expect(pause.json().mediaSyncState).toBe('PENDING');
        } finally {
            release.resolve();
        }
        const response = await uploading;
        expect(response.statusCode).toBe(409);
        expect(response.json()).not.toHaveProperty('uploadUrl');
        expect(await prisma.clip.findFirst({ where: { assetId } })).toMatchObject({
            muxUploadId: 'media-route-upload',
        });
        expect(await prisma.asset.findUnique({ where: { id: assetId } })).toMatchObject({
            moderation: 'PAUSED',
            mediaSyncState: 'PENDING',
            mediaPlaybackReset: true,
        });
    });

    it('prevents hard deletion while a verified asset is being reconciled', async () => {
        await createAsset({ moderation: 'REMOVED', mediaSyncState: 'SYNCED' });
        const entered = deferred();
        const release = deferred();
        const reconciliation = withAssetMediaLock(assetId, async () => {
            entered.resolve();
            await release.promise;
        });
        try {
            await entered.promise;
            const blocked = await requestAs(adminId, 'DELETE', `/api/admin/users/${userId}`);
            expect(blocked.statusCode).toBe(409);
            expect(await prisma.asset.findUnique({ where: { id: assetId } })).not.toBeNull();
        } finally {
            release.resolve();
        }
        await reconciliation;
        expect((await requestAs(adminId, 'DELETE', `/api/admin/users/${userId}`)).statusCode).toBe(200);
        expect(await prisma.user.findUnique({ where: { id: userId } })).toBeNull();
    });

    it('retains unresolved playback evidence and blocks deletion when its Mux asset is unknown', async () => {
        await createAsset({
            clips: {
                create: {
                    id: 'media-routes-clip',
                    muxPlaybackId: 'unknown-public-id',
                    streamUrl: 'https://stream.mux.com/unknown-public-id.m3u8',
                    thumbnailUrl: 'https://image.mux.com/unknown-public-id/thumbnail.png',
                },
            },
        });

        const pause = await requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
            moderation: 'PAUSED',
        });
        expect(pause.statusCode).toBe(202);
        expect(pause.json().mediaSyncState).toBe('ERROR');
        expect((await prisma.clip.findUnique({ where: { id: 'media-routes-clip' } })).muxPlaybackId)
            .toBe('unknown-public-id');
        const visible = await requestAs(userId, 'GET', `/api/assets/${assetId}`);
        expect(visible.statusCode).toBe(200);
        expect(visible.json().asset.clips[0]).toMatchObject({
            muxPlaybackId: null, streamUrl: null, thumbnailUrl: null,
        });

        for (const moderation of ['FLAGGED_FOR_REMOVAL', 'REMOVED']) {
            const response = await requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
                moderation, reason: 'Unresolved playback requires cleanup',
            });
            expect(response.statusCode).toBe(202);
            expect(response.json().mediaSyncState).toBe('ERROR');
        }
        expect((await requestAs(adminId, 'DELETE', `/api/admin/users/${userId}`)).statusCode).toBe(409);
        expect((await prisma.clip.findUnique({ where: { id: 'media-routes-clip' } })).muxPlaybackId)
            .toBe('unknown-public-id');
    });

    it('does not return a revoked playback URL when restored playback creation fails', async () => {
        await createAsset({
            moderation: 'PAUSED',
            mediaPlaybackReset: true,
            clips: {
                create: {
                    id: 'media-routes-clip',
                    status: 'READY',
                    muxAssetId: 'mux-restoring',
                    muxPlaybackId: 'old-playback',
                    streamUrl: 'https://stream.mux.com/old-playback.m3u8',
                    thumbnailUrl: 'https://image.mux.com/old-playback/thumbnail.png',
                },
            },
        });
        const remote = { status: 'ready', playback_ids: [{ policy: 'public', id: 'old-playback' }] };
        muxApi.inspectMuxAsset.mockImplementation(async () => ({ ok: true, asset: structuredClone(remote) }));
        muxApi.disableMuxPlayback.mockImplementation(async () => {
            remote.playback_ids = [];
            return { ok: true };
        });
        muxApi.createMuxPublicPlayback.mockResolvedValue({
            ok: false,
            indeterminate: false,
            error: 'Mux playback creation was rejected',
        });

        const restore = await requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
            moderation: 'ACTIVE',
        });
        expect(restore.statusCode).toBe(202);
        expect(restore.json().mediaSyncState).toBe('ERROR');

        for (const url of [`/api/assets/${assetId}`, '/api/assets/mine']) {
            const response = await requestAs(userId, 'GET', url);
            expect(response.statusCode).toBe(200);
            const asset = url.endsWith('/mine') ? response.json().assets[0] : response.json().asset;
            expect(asset.clips[0]).toMatchObject({
                muxPlaybackId: null, streamUrl: null, thumbnailUrl: null,
            });
        }
        expect(remote.playback_ids).toEqual([]);
        expect(muxApi.createMuxPublicPlayback).toHaveBeenCalledTimes(1);
    });

    it('retains the user when a concurrent new asset commits before deletion', async () => {
        const entered = deferred();
        const release = deferred();
        const creating = prisma.$transaction(async tx => {
            await tx.asset.create({ data: { id: assetId, userId } });
            entered.resolve();
            await release.promise;
        }, { timeout: 10000 });

        let deleting;
        try {
            await entered.promise;
            deleting = requestAs(adminId, 'DELETE', `/api/admin/users/${userId}`);
            await waitForBlockedQuery(pool, 'SELECT role FROM users');
        } finally {
            release.resolve();
        }
        await creating;
        expect((await deleting).statusCode).toBe(409);
        expect(await prisma.asset.findUnique({ where: { id: assetId } })).not.toBeNull();
        expect(await prisma.user.findUnique({ where: { id: userId } })).not.toBeNull();
    });

    it('blocks new assets until an in-progress hard deletion commits', async () => {
        await createAsset({ moderation: 'REMOVED', mediaSyncState: 'SYNCED' });
        const blocker = await pool.connect();
        const inserter = await pool.connect();
        try {
            await blocker.query('BEGIN');
            await blocker.query('SELECT id FROM assets WHERE id = $1 FOR UPDATE', [assetId]);
            const deleting = requestAs(adminId, 'DELETE', `/api/admin/users/${userId}`);
            await waitForBlockedQuery(pool, 'SELECT id, moderation, media_sync_state');

            const pid = (await inserter.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
            const creating = inserter.query(
                'INSERT INTO assets (id, user_id, updated_at) VALUES ($1, $2, NOW())',
                ['media-routes-late-asset', userId],
            ).then(() => null, err => err);
            await waitForBlockedQuery(pool, 'INSERT INTO assets', pid);
            await blocker.query('COMMIT');

            expect((await deleting).statusCode).toBe(200);
            expect((await creating)?.code).toBe('23503');
            expect(await prisma.asset.findUnique({ where: { id: 'media-routes-late-asset' } })).toBeNull();
        } finally {
            await blocker.query('ROLLBACK');
            blocker.release();
            inserter.release();
        }
    });

    it.each(['clip', 'reference'])('retains an uploading asset when a concurrent %s is committed', async kind => {
        await createAsset();
        const entered = deferred();
        const release = deferred();
        const creating = prisma.$transaction(async tx => {
            if (kind === 'clip') {
                await tx.clip.create({ data: { id: 'media-routes-clip', assetId } });
            } else {
                await tx.muxAssetReference.create({ data: { muxAssetId: 'media-routes-mux', assetId } });
            }
            entered.resolve();
            await release.promise;
        }, { timeout: 10000 });

        let cleanup;
        try {
            await entered.promise;
            cleanup = requestAs(adminId, 'POST', '/api/admin/cleanup-assets', {});
            await waitForBlockedQuery(pool, 'SELECT id FROM assets WHERE id IN');
        } finally {
            release.resolve();
        }
        await creating;
        const response = await cleanup;
        expect(response.statusCode).toBe(200);
        expect(response.json().cleaned).toBe(0);
        expect(await prisma.asset.findUnique({ where: { id: assetId } })).not.toBeNull();
    });

    it.each(['clip', 'reference'])('rejects a new %s once uploading-asset cleanup has acquired its lock', async kind => {
        await createAsset();
        const blocker = await pool.connect();
        const inserter = await pool.connect();
        try {
            await blocker.query('BEGIN');
            await blocker.query('SELECT id FROM assets WHERE id = $1 FOR UPDATE', [assetId]);
            const cleanup = requestAs(adminId, 'POST', '/api/admin/cleanup-assets', {});
            await waitForBlockedQuery(pool, 'SELECT id FROM assets WHERE id IN');

            const pid = (await inserter.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
            const statement = kind === 'clip'
                ? 'INSERT INTO clips (id, asset_id) VALUES ($1, $2)'
                : 'INSERT INTO mux_asset_references (mux_asset_id, asset_id) VALUES ($1, $2)';
            const creating = inserter.query(statement, ['media-routes-late-child', assetId])
                .then(() => null, err => err);
            await waitForBlockedQuery(pool, 'INSERT INTO', pid);
            await blocker.query('COMMIT');

            const response = await cleanup;
            expect(response.statusCode).toBe(200);
            expect(response.json().cleaned).toBe(1);
            expect((await creating)?.code).toBe('23503');
            expect(await prisma.asset.findUnique({ where: { id: assetId } })).toBeNull();
        } finally {
            await blocker.query('ROLLBACK');
            blocker.release();
            inserter.release();
        }
    });

    it('preserves local media when a queued moderation update wins the orphan-cleanup race', async () => {
        await createAsset({
            createdAt: new Date(Date.now() - 2 * 60 * 60 * 1000),
            clips: { create: { id: 'media-routes-clip', storageUrl: '/uploads/orphan-race.mp4' } },
        });
        const blocker = await pool.connect();
        const fileSystem = { realpath: vi.fn(async value => value), unlink: vi.fn() };
        try {
            await blocker.query('BEGIN');
            await blocker.query('SELECT id FROM assets WHERE id = $1 FOR UPDATE', [assetId]);
            const pause = requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
                moderation: 'PAUSED',
            });
            await waitForBlockedQuery(pool, 'UPDATE "public"."assets"');
            const cleanup = cleanupOrphanedUploads(app, { fileSystem });
            await waitForBlockedQuery(pool, 'SELECT id FROM assets WHERE id =');
            await blocker.query('COMMIT');

            expect([200, 202]).toContain((await pause).statusCode);
            await cleanup;
            expect(fileSystem.unlink).not.toHaveBeenCalled();
            expect(await prisma.clip.findUnique({ where: { id: 'media-routes-clip' } }))
                .toMatchObject({ storageUrl: '/uploads/orphan-race.mp4' });
            expect(await prisma.asset.findUnique({ where: { id: assetId } }))
                .toMatchObject({ moderation: 'PAUSED', status: 'UPLOADING' });
        } finally {
            await blocker.query('ROLLBACK');
            blocker.release();
        }
    });

    it('blocks Nuclear Reset while any asset and its references remain', async () => {
        await createAsset({ moderation: 'REMOVED', mediaSyncState: 'SYNCED' });
        await prisma.muxAssetReference.create({ data: { assetId, muxAssetId: 'media-routes-retained' } });

        const response = await requestAs(adminId, 'POST', '/api/admin/nuclear-reset', {});
        expect(response.statusCode).toBe(409);
        expect(await prisma.muxAssetReference.findUnique({ where: { muxAssetId: 'media-routes-retained' } }))
            .not.toBeNull();
    });

    it('serializes Nuclear Reset with a new asset created after its empty-table check', async () => {
        await pool.query('CREATE SEQUENCE IF NOT EXISTS mediasource_id_seq START WITH 100000001');
        const before = (await pool.query("SELECT nextval('mediasource_id_seq') AS id")).rows[0].id;
        const blocker = await pool.connect();
        const inserter = await pool.connect();
        try {
            await blocker.query('BEGIN');
            await blocker.query('LOCK TABLE chat_messages IN ACCESS EXCLUSIVE MODE');
            const reset = requestAs(adminId, 'POST', '/api/admin/nuclear-reset', {});
            await waitForBlockedQuery(pool, 'DELETE FROM "public"."chat_messages"');

            const pid = (await inserter.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
            const creating = inserter.query(
                'INSERT INTO assets (id, user_id, updated_at) VALUES ($1, $2, NOW())',
                [assetId, userId],
            );
            await waitForBlockedQuery(pool, 'INSERT INTO assets', pid);
            await blocker.query('COMMIT');

            const response = await reset;
            expect(response.statusCode).toBe(200);
            expect(response.json().message).toContain('Mux media was not changed');
            await creating;
            expect(await prisma.asset.findUnique({ where: { id: assetId } })).not.toBeNull();
            const after = (await pool.query("SELECT nextval('mediasource_id_seq') AS id")).rows[0].id;
            expect(BigInt(after)).toBe(BigInt(before) + 1n);
        } finally {
            await blocker.query('ROLLBACK');
            blocker.release();
            inserter.release();
        }
    });

    it('retains the exact confirmed Mux operation ID in the audit history', async () => {
        await createAsset({
            moderation: 'PAUSED',
            mediaSyncState: 'ERROR',
            mediaPlaybackReset: true,
            mediaCreateOperationId: 'operation-audit-test',
            mediaCreateMuxAssetId: 'mux-audit-test',
            mediaCreateStartedAt: new Date(),
        });
        const response = await requestAs(adminId, 'POST', `/api/admin/assets/${assetId}/media-sync/confirm-create`, {
            operationId: 'operation-audit-test',
            confirmed: true,
            reason: 'Mux support confirmed the request cannot complete',
        });
        expect(response.statusCode).toBe(200);
        expect(await prisma.auditLog.findFirst({ where: { targetId: assetId, action: 'MEDIA_CREATE_CONFIRMED' } }))
            .toMatchObject({
                reason: 'Operation operation-audit-test: Mux support confirmed the request cannot complete',
            });
        expect(await prisma.muxAssetReference.findUnique({ where: { muxAssetId: 'mux-audit-test' } }))
            .toMatchObject({ assetId });
    });

    it('backfills moderated resets and deduplicated Mux references in the migrations', async () => {
        const reconciliationSql = await readFile(new URL(
            '../../prisma/migrations/20261108221126_media_reconciliation/migration.sql', import.meta.url,
        ), 'utf8');
        const referencesSql = await readFile(new URL(
            '../../prisma/migrations/20261108221922_mux_asset_references/migration.sql', import.meta.url,
        ), 'utf8');
        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            await client.query('CREATE TEMP TABLE assets (id TEXT PRIMARY KEY, moderation TEXT NOT NULL)');
            await client.query('CREATE TEMP TABLE clips (id TEXT PRIMARY KEY, asset_id TEXT NOT NULL, mux_asset_id TEXT)');
            await client.query('SET LOCAL search_path TO pg_temp');
            await client.query(`
                INSERT INTO assets (id, moderation) VALUES ('active', 'ACTIVE'), ('paused', 'PAUSED'), ('removed', 'REMOVED')
            `);
            await client.query(`
                INSERT INTO clips VALUES ('clip-b', 'paused', 'mux-one'), ('clip-a', 'paused', 'mux-one')
            `);
            await client.query(reconciliationSql);
            await client.query(referencesSql);
            const assets = await client.query('SELECT id, media_sync_state, media_playback_reset FROM assets ORDER BY id');
            expect(assets.rows).toEqual([
                { id: 'active', media_sync_state: 'PENDING', media_playback_reset: false },
                { id: 'paused', media_sync_state: 'PENDING', media_playback_reset: true },
                { id: 'removed', media_sync_state: 'PENDING', media_playback_reset: true },
            ]);
            expect((await client.query('SELECT * FROM mux_asset_references')).rows).toEqual([
                { mux_asset_id: 'mux-one', asset_id: 'paused', clip_id: 'clip-a' },
            ]);
        } finally {
            await client.query('ROLLBACK');
            client.release();
        }
    });

    it('rejects migration backfill when one Mux asset belongs to different assets', async () => {
        const referencesSql = await readFile(new URL(
            '../../prisma/migrations/20261108221922_mux_asset_references/migration.sql', import.meta.url,
        ), 'utf8');
        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            await client.query('CREATE TEMP TABLE assets (id TEXT PRIMARY KEY)');
            await client.query('CREATE TEMP TABLE clips (id TEXT PRIMARY KEY, asset_id TEXT NOT NULL, mux_asset_id TEXT)');
            await client.query('SET LOCAL search_path TO pg_temp');
            await client.query("INSERT INTO assets VALUES ('first'), ('second')");
            await client.query("INSERT INTO clips VALUES ('clip-a', 'first', 'mux-one'), ('clip-b', 'second', 'mux-one')");
            await client.query('SAVEPOINT before_migration');
            await expect(client.query(referencesSql)).rejects.toThrow('associated with more than one asset');
            await client.query('ROLLBACK TO SAVEPOINT before_migration');
            expect((await client.query("SELECT to_regclass('pg_temp.mux_asset_references') AS reference_table"))
                .rows[0].reference_table).toBeNull();
        } finally {
            await client.query('ROLLBACK');
            client.release();
        }
    });
});
