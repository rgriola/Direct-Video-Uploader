import { createHash, randomUUID } from 'node:crypto';
import { lstat, mkdtemp, mkdir, readFile, readdir, rm, unlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { createUploadSessionCleanupWorker, startUploadSessionCleanup } from '../jobs/upload-session-cleanup.js';
import { createLocalStorageDriver } from '../lib/storage/local-driver.js';
import { createStorageCapacity, SESSION_OVERHEAD_BYTES } from '../lib/storage/capacity.js';
import { getUploadSessionCleanupConfig } from '../lib/upload-session-cleanup-config.js';
import { createUploadSessionService } from '../lib/upload-sessions.js';
import {
    acquireIntegrationDatabaseLock, INTEGRATION_SETUP_TIMEOUT_MS, waitForBlockedQuery,
} from './helpers/database-lock.js';

const databaseUrl = process.env.TEST_DATABASE_URL;
if (process.env.CI && !databaseUrl) {
    throw new Error('TEST_DATABASE_URL is required for upload cleanup integration tests in CI');
}
if (databaseUrl) {
    const url = new URL(databaseUrl);
    if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
        || !url.pathname.slice(1).startsWith('dvu_scope_test_')
        || process.env.DATABASE_URL !== databaseUrl) {
        throw new Error('Upload cleanup tests require a dedicated local dvu_scope_test_ database');
    }
}

const integration = databaseUrl ? describe : describe.skip;
const sha256 = content => createHash('sha256').update(content).digest('hex');
const reservationFor = content => BigInt(content.length) * 2n + SESSION_OVERHEAD_BYTES;

async function waitFor(predicate) {
    for (let attempt = 0; attempt < 400; attempt += 1) {
        if (await predicate()) return;
        await new Promise(resolve => setTimeout(resolve, 10));
    }
    throw new Error('Timed out waiting for upload cleanup test state');
}

integration('upload session cleanup against PostgreSQL and local storage', () => {
    const ownerId = `cleanup-owner-${randomUUID()}`;
    let prisma;
    let pool;
    let releaseDatabaseLock;
    let withAssetMediaLock;
    let enqueueMuxOriginal;
    let storageRoot;
    let storage;
    let capacity;
    let service;
    let currentTime;
    let log;
    let workers;

    beforeAll(async () => {
        const database = await import('../lib/prisma.js');
        prisma = database.default;
        pool = database.pool;
        releaseDatabaseLock = await acquireIntegrationDatabaseLock(pool);
        ({ withAssetMediaLock } = await import('../lib/media-lock.js'));
        ({ enqueueMuxOriginal } = await import('../lib/mux-original-records.js'));
        await prisma.user.create({
            data: {
                id: ownerId,
                name: 'Upload Cleanup Test',
                phoneNumber: `cleanup-${randomUUID()}`,
                pinHash: 'integration-test',
            },
        });
    }, INTEGRATION_SETUP_TIMEOUT_MS);

    beforeEach(async () => {
        storageRoot = await mkdtemp(path.join(os.tmpdir(), 'dvu-upload-cleanup-'));
        storage = createLocalStorageDriver({ root: storageRoot });
        capacity = createStorageCapacity({
            db: prisma,
            storage,
            maxStorageBytes: 10n * 1024n * 1024n * 1024n,
            minFreeBytes: 1n,
        });
        currentTime = new Date('2026-11-09T12:00:00.000Z');
        service = createUploadSessionService({
            db: prisma, storage, capacity, now: () => new Date(currentTime),
        });
        log = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };
        workers = [];
    });

    afterEach(async () => {
        vi.restoreAllMocks();
        await Promise.all(workers.map(worker => worker.close()));
        await prisma.storageWriteLease.deleteMany({});
        await prisma.asset.deleteMany({ where: { userId: ownerId } });
        await prisma.user.update({ where: { id: ownerId }, data: { status: 'ACTIVE' } });
        if (storageRoot) await rm(storageRoot, { recursive: true, force: true });
    });

    afterAll(async () => {
        if (!prisma) return;
        try {
            await prisma.storageWriteLease.deleteMany({});
            await prisma.asset.deleteMany({ where: { userId: ownerId } });
            await prisma.user.deleteMany({ where: { id: ownerId } });
        } finally {
            await releaseDatabaseLock?.();
            await prisma.$disconnect();
        }
    });

    async function assetWithClip() {
        const assetId = randomUUID();
        const clipId = randomUUID();
        await prisma.asset.create({
            data: {
                id: assetId,
                userId: ownerId,
                status: 'UPLOADING',
                clips: { create: { id: clipId, status: 'UPLOADING' } },
            },
        });
        return { assetId, clipId };
    }

    async function trackedUpload(value, { upload = true, checksum = true } = {}) {
        const content = Buffer.from(value);
        const target = await assetWithClip();
        const session = await service.create({
            ownerId,
            ...target,
            expectedSizeBytes: content.length,
            ...(checksum ? { expectedSha256: sha256(content) } : {}),
        });
        if (upload) {
            await service.uploadPart({
                ownerId,
                uploadSessionId: session.id,
                partNumber: 1,
                body: content,
                expectedSizeBytes: content.length,
            });
        }
        return { session, content };
    }

    function createWorker(options = {}) {
        const worker = createUploadSessionCleanupWorker({
            db: prisma,
            storage,
            log,
            withLock: withAssetMediaLock,
            clock: () => new Date(currentTime),
            ...options,
        });
        workers.push(worker);
        return worker;
    }

    async function expireAtCurrentTime(session) {
        await prisma.uploadSession.update({
            where: { id: session.id }, data: { expiresAt: new Date(currentTime) },
        });
    }

    function sessionPath(session) {
        return path.join(storageRoot, '.uploads', session.id);
    }

    function originalPath(session) {
        return path.join(storageRoot, ...session.storageKey.split('/'));
    }

    it('expires only due sessions and preserves active uploads, originals, and untracked directories', async () => {
        const expired = await trackedUpload('expired parts');
        const active = await trackedUpload('active parts');
        const completed = await trackedUpload('retained original');
        await service.complete({ ownerId, uploadSessionId: completed.session.id });
        const untracked = await storage.createUpload({
            ownerId, assetId: randomUUID(), clipId: randomUUID(),
        });
        await prisma.uploadSession.update({
            where: { id: expired.session.id },
            data: { expiresAt: new Date(currentTime.getTime() + 1) },
        });
        const worker = createWorker();
        expect((await worker.runOnce()).sessions.processed).toBe(0);
        currentTime = new Date(currentTime.getTime() + 1);
        const result = await worker.runOnce();

        expect(result.sessions).toMatchObject({ processed: 1, failed: 0 });
        expect(await prisma.uploadSession.findUnique({ where: { id: expired.session.id } }))
            .toMatchObject({ status: 'EXPIRED', storageReservationBytes: 0n });
        expect(await storage.hasUpload(expired.session.id)).toBe(false);
        expect(await prisma.uploadSession.findUnique({ where: { id: active.session.id } }))
            .toMatchObject({ status: 'OPEN', storageReservationBytes: reservationFor(active.content) });
        expect(await readFile(path.join(sessionPath(active.session), 'parts', '00001'))).toEqual(active.content);
        expect(await readFile(originalPath(completed.session))).toEqual(completed.content);
        expect(await storage.hasUpload(untracked.uploadId)).toBe(true);
        expect(log.warn).toHaveBeenCalledWith(
            { uploadSessionId: untracked.uploadId, kind: 'directory' },
            'Possible untracked original upload data requires manual review',
        );
    });

    it('retains failed cleanup reservations and retries after partial filesystem success', async () => {
        const { session, content } = await trackedUpload('cleanup failure');
        await expireAtCurrentTime(session);
        const abortUpload = storage.abortUpload.bind(storage);
        vi.spyOn(storage, 'abortUpload').mockImplementationOnce(async (uploadId, options) => {
            await abortUpload(uploadId, options);
            throw new Error('cleanup interrupted after removing staged files');
        });
        const worker = createWorker();

        expect((await worker.runOnce()).sessions.failed).toBe(1);
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
            .toMatchObject({ status: 'EXPIRED', storageReservationBytes: reservationFor(content) });
        expect(await storage.hasUpload(session.id)).toBe(false);
        expect(log.error).toHaveBeenCalledWith(
            expect.objectContaining({ uploadSessionId: session.id }),
            'Original upload cleanup failed; recovery is required',
        );

        expect((await worker.runOnce()).sessions.processed).toBe(1);
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes)
            .toBe(0n);
    });

    it('retains the reservation if the asset lock is lost after staged files are removed', async () => {
        const { session, content } = await trackedUpload('lock lost after cleanup');
        await expireAtCurrentTime(session);
        let removed = false;
        const abortUpload = storage.abortUpload.bind(storage);
        vi.spyOn(storage, 'abortUpload').mockImplementation(async (uploadId, options) => {
            const result = await abortUpload(uploadId, options);
            removed = true;
            return result;
        });
        const withLock = async (_assetId, work) => ({
            acquired: true,
            value: await work(async () => {
                if (removed) throw new Error('asset media lock lost');
            }),
        });
        expect((await createWorker({ withLock }).runOnce()).sessions.failed).toBe(1);
        expect(await storage.hasUpload(session.id)).toBe(false);
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
            .toMatchObject({ status: 'EXPIRED', storageReservationBytes: reservationFor(content) });
        expect((await createWorker().runOnce()).sessions.processed).toBe(1);
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes)
            .toBe(0n);
    });

    it('cleans aborted sessions with unknown legacy reservations', async () => {
        const { session } = await trackedUpload('legacy reservation');
        await prisma.uploadSession.update({
            where: { id: session.id }, data: { status: 'ABORTED', storageReservationBytes: null },
        });
        const result = await createWorker().runOnce();
        expect(result.sessions.processed).toBe(1);
        expect(await storage.hasUpload(session.id)).toBe(false);
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
            .toMatchObject({ status: 'ABORTED', storageReservationBytes: 0n });
    });

    it('removes verified completed-session leftovers without deleting the original', async () => {
        const { session, content } = await trackedUpload('completed with leftovers');
        const manifest = await readFile(path.join(sessionPath(session), 'manifest.json'));
        await service.complete({ ownerId, uploadSessionId: session.id });
        await mkdir(path.join(sessionPath(session), 'parts'), { recursive: true });
        await writeFile(path.join(sessionPath(session), 'manifest.json'), manifest);
        await writeFile(path.join(sessionPath(session), 'parts', '00001'), content);
        await prisma.uploadSession.update({
            where: { id: session.id }, data: { storageReservationBytes: reservationFor(content) },
        });

        expect((await createWorker().runOnce()).sessions.processed).toBe(1);
        expect(await storage.hasUpload(session.id)).toBe(false);
        expect(await readFile(originalPath(session))).toEqual(content);
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
            .toMatchObject({ status: 'COMPLETED', storageReservationBytes: 0n });
    });

    it('reopens interrupted completion before expiry and later expires it', async () => {
        const { session, content } = await trackedUpload('interrupted completion');
        await prisma.uploadSession.update({ where: { id: session.id }, data: { status: 'COMPLETING' } });
        const worker = createWorker();
        expect((await worker.runOnce()).sessions.processed).toBe(1);
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
            .toMatchObject({ status: 'OPEN', storageReservationBytes: reservationFor(content) });
        expect(await readFile(path.join(sessionPath(session), 'parts', '00001'))).toEqual(content);

        await expireAtCurrentTime(session);
        expect((await worker.runOnce()).sessions.processed).toBe(1);
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
            .toMatchObject({ status: 'EXPIRED', storageReservationBytes: 0n });
    });

    it.each([false, true])(
        'recovers a published original and respects the current Mux handoff setting: %s',
        async handoffEnabled => {
            const { session, content } = await trackedUpload('published original');
            await storage.completeUpload(session.id, {
                expectedSizeBytes: content.length, expectedSha256: sha256(content),
            });
            await prisma.uploadSession.update({ where: { id: session.id }, data: { status: 'COMPLETING' } });
            const worker = createWorker({ onCompleted: handoffEnabled ? enqueueMuxOriginal : undefined });

            expect((await worker.runOnce()).sessions.processed).toBe(1);
            expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
                .toMatchObject({ status: 'COMPLETED', storageReservationBytes: 0n });
            expect(await prisma.clip.findUnique({ where: { id: session.clipId } }))
                .toMatchObject({
                    storageKey: session.storageKey, storageDriver: 'local',
                    sha256: sha256(content), fileSize: BigInt(content.length),
                });
            expect(await readFile(originalPath(session))).toEqual(content);
            const job = await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } });
            if (handoffEnabled) expect(job).toMatchObject({ status: 'QUEUED' });
            else expect(job).toBeNull();
        },
    );

    it('leaves a live completion alone and recovers it after the lock is released', async () => {
        const { session, content } = await trackedUpload('live completion');
        await prisma.uploadSession.update({ where: { id: session.id }, data: { status: 'COMPLETING' } });
        let release;
        let markStarted;
        const started = new Promise(resolve => { markStarted = resolve; });
        const gate = new Promise(resolve => { release = resolve; });
        const holding = storage.withCompletionLock(session.id, async () => {
            markStarted();
            await gate;
        });
        await started;
        const worker = createWorker();
        try {
            expect((await worker.runOnce()).sessions.deferred).toBe(1);
            expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
                .toMatchObject({ status: 'COMPLETING', storageReservationBytes: reservationFor(content) });
            expect(await readFile(path.join(sessionPath(session), 'parts', '00001'))).toEqual(content);
        } finally {
            release();
            await holding;
        }
        expect((await worker.runOnce()).sessions.processed).toBe(1);
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('OPEN');
    });

    it('does not remove an in-flight part or release its reservation', async () => {
        const { session, content } = await trackedUpload('streaming-part', { upload: false });
        const stream = new PassThrough();
        const writing = service.uploadPart({
            ownerId, uploadSessionId: session.id, partNumber: 1,
            body: stream, expectedSizeBytes: content.length,
        }).then(value => ({ value }), error => ({ error }));
        stream.write(content.subarray(0, 3));
        const partsPath = path.join(sessionPath(session), 'parts');
        await waitFor(async () => {
            try {
                return (await readdir(partsPath)).some(name => name.startsWith('.partial-'));
            } catch (error) {
                if (error.code === 'ENOENT') return false;
                throw error;
            }
        });
        await expireAtCurrentTime(session);
        const worker = createWorker();
        try {
            expect((await worker.runOnce()).sessions.deferred).toBe(1);
            expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
                .toMatchObject({ status: 'OPEN', storageReservationBytes: reservationFor(content) });
            expect(await storage.hasUpload(session.id)).toBe(true);
        } finally {
            stream.end(content.subarray(3));
        }
        expect((await writing).error).toMatchObject({ code: 'EXPIRED' });
        expect((await worker.runOnce()).sessions.processed).toBe(1);
        expect(await storage.hasUpload(session.id)).toBe(false);
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes)
            .toBe(0n);
    });

    it('defers cleanup when a write lease exists before any part file is created', async () => {
        const { session, content } = await trackedUpload('write not yet staged', { upload: false });
        let release;
        let markStarted;
        const started = new Promise(resolve => { markStarted = resolve; });
        const gate = new Promise(resolve => { release = resolve; });
        const holding = capacity.withWritePermit(session, BigInt(content.length), async () => {
            markStarted();
            await gate;
        });
        await started;
        await expireAtCurrentTime(session);
        const worker = createWorker();
        try {
            expect((await worker.runOnce()).sessions.deferred).toBe(1);
            expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
                .toMatchObject({ status: 'EXPIRED', storageReservationBytes: reservationFor(content) });
            expect(await storage.hasUpload(session.id)).toBe(true);
            expect(await prisma.storageWriteLease.count({ where: { uploadSessionId: session.id } })).toBe(1);
        } finally {
            release();
            await holding;
        }
        expect((await worker.runOnce()).sessions.processed).toBe(1);
        expect(await storage.hasUpload(session.id)).toBe(false);
    });

    it.each(['abort', 'get'])('keeps active writes safe when session %s triggers cleanup', async operation => {
        const { session, content } = await trackedUpload(`active ${operation}`, { upload: false });
        let release;
        let markStarted;
        const started = new Promise(resolve => { markStarted = resolve; });
        const gate = new Promise(resolve => { release = resolve; });
        const holding = capacity.withWritePermit(session, BigInt(content.length), async () => {
            markStarted();
            await gate;
        });
        await started;
        if (operation === 'get') await expireAtCurrentTime(session);
        const invoke = () => service[operation]({ ownerId, uploadSessionId: session.id });
        try {
            await expect(invoke()).rejects.toMatchObject({ code: 'SESSION_BUSY' });
            expect(await storage.hasUpload(session.id)).toBe(true);
            expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes)
                .toBe(reservationFor(content));
        } finally {
            release();
            await holding;
        }
        await invoke();
        expect(await storage.hasUpload(session.id)).toBe(false);
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes)
            .toBe(0n);
    });

    it('waits for existing writes during completion and denies new write permits', async () => {
        const { session, content } = await trackedUpload('completion with write lease', { upload: false });
        let release;
        let markStarted;
        const started = new Promise(resolve => { markStarted = resolve; });
        const gate = new Promise(resolve => { release = resolve; });
        const holding = capacity.withWritePermit(session, BigInt(content.length), async () => {
            markStarted();
            await gate;
        });
        await started;
        await prisma.uploadSession.update({ where: { id: session.id }, data: { status: 'COMPLETING' } });
        const worker = createWorker();
        try {
            expect((await worker.runOnce()).sessions.deferred).toBe(1);
            const work = vi.fn();
            await expect(capacity.withWritePermit(session, BigInt(content.length), work))
                .rejects.toMatchObject({ code: 'SESSION_BUSY' });
            expect(work).not.toHaveBeenCalled();
            expect(await storage.hasUpload(session.id)).toBe(true);
        } finally {
            release();
            await holding;
        }
        expect((await worker.runOnce()).sessions.processed).toBe(1);
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('OPEN');
    });

    it.each([
        { host: `remote-${os.hostname()}`, pid: 1, deferred: true },
        { host: os.hostname(), pid: 2_147_483_647, deferred: false },
    ])('only reclaims verifiably stale write leases: $host', async ({ host, pid, deferred }) => {
        const { session, content } = await trackedUpload('lease recovery');
        const storageIdentity = session.storageKey.split('/').at(-1).split('.')[0];
        await prisma.storageWriteLease.create({
            data: {
                id: randomUUID(), uploadSessionId: session.id,
                storageIdentity, sizeBytes: 1n, host, pid,
            },
        });
        await expireAtCurrentTime(session);
        const worker = createWorker();
        const result = await worker.runOnce();
        if (deferred) {
            expect(result.sessions.deferred).toBe(1);
            expect(await storage.hasUpload(session.id)).toBe(true);
            expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes)
                .toBe(reservationFor(content));
            await prisma.storageWriteLease.deleteMany({ where: { uploadSessionId: session.id } });
            expect((await worker.runOnce()).sessions.processed).toBe(1);
        } else {
            expect(result.sessions.processed).toBe(1);
            expect(await prisma.storageWriteLease.count({ where: { uploadSessionId: session.id } })).toBe(0);
        }
        expect(await storage.hasUpload(session.id)).toBe(false);
    });

    it('preserves staged data when the published original fails its checksum', async () => {
        const { session, content } = await trackedUpload('verify original');
        const manifest = await readFile(path.join(sessionPath(session), 'manifest.json'));
        await storage.completeUpload(session.id, {
            expectedSizeBytes: content.length, expectedSha256: sha256(content),
        });
        await mkdir(path.join(sessionPath(session), 'parts'), { recursive: true });
        await writeFile(path.join(sessionPath(session), 'manifest.json'), manifest);
        await writeFile(path.join(sessionPath(session), 'parts', '00001'), content);
        await writeFile(originalPath(session), Buffer.alloc(content.length, 'x'));
        await prisma.uploadSession.update({ where: { id: session.id }, data: { status: 'COMPLETING' } });
        const worker = createWorker({ onCompleted: enqueueMuxOriginal });

        expect((await worker.runOnce()).sessions.failed).toBe(1);
        expect(await readFile(path.join(sessionPath(session), 'parts', '00001'))).toEqual(content);
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
            .toMatchObject({ status: 'COMPLETING', storageReservationBytes: reservationFor(content) });
        expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } })).toBeNull();

        await writeFile(originalPath(session), content);
        expect((await worker.runOnce()).sessions.processed).toBe(1);
        expect(await readFile(originalPath(session))).toEqual(content);
        expect(await storage.hasUpload(session.id)).toBe(false);
        expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } }))
            .toMatchObject({ status: 'QUEUED' });
    });

    it('does not automatically finalize a legacy published original without a verifiable checksum', async () => {
        const { session, content } = await trackedUpload('unverified original', { checksum: false });
        await storage.completeUpload(session.id, { expectedSizeBytes: content.length });
        await prisma.uploadSession.update({ where: { id: session.id }, data: { status: 'COMPLETING' } });
        const result = await createWorker().runOnce();
        expect(result.sessions.failed).toBe(1);
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
            .toMatchObject({ status: 'COMPLETING', storageReservationBytes: reservationFor(content) });
        expect(await readFile(originalPath(session))).toEqual(content);
    });

    it('rejects a mismatched manifest before marking or deleting an expired session', async () => {
        const { session, content } = await trackedUpload('manifest mismatch');
        const manifestPath = path.join(sessionPath(session), 'manifest.json');
        const original = await readFile(manifestPath, 'utf8');
        const manifest = JSON.parse(original);
        const pieces = manifest.key.split('/');
        pieces[pieces.length - 1] = `${pieces.at(-1).split('.')[0]}.${randomUUID()}`;
        manifest.key = pieces.join('/');
        await writeFile(manifestPath, JSON.stringify(manifest));
        await expireAtCurrentTime(session);
        const worker = createWorker();
        expect((await worker.runOnce()).sessions.failed).toBe(1);
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
            .toMatchObject({ status: 'OPEN', storageReservationBytes: reservationFor(content) });
        expect(await readFile(path.join(sessionPath(session), 'parts', '00001'))).toEqual(content);

        await writeFile(manifestPath, original);
        expect((await worker.runOnce()).sessions.processed).toBe(1);
        expect(await storage.hasUpload(session.id)).toBe(false);
    });

    it.each([
        { relative: 'unexpected.txt', deferred: false },
        { relative: 'parts/unexpected.txt', deferred: false },
        { relative: '.busy.recovery', deferred: true },
        { relative: 'parts/.part-00001.recovery', deferred: true },
    ])('preserves ambiguous tracked upload contents: $relative', async ({ relative, deferred }) => {
        const { session, content } = await trackedUpload('ambiguous session contents');
        const extra = path.join(sessionPath(session), ...relative.split('/'));
        await writeFile(extra, 'manual review');
        await expireAtCurrentTime(session);
        const worker = createWorker();
        const result = await worker.runOnce();
        expect(result.sessions[deferred ? 'deferred' : 'failed']).toBe(1);
        expect(await readFile(extra, 'utf8')).toBe('manual review');
        expect(await readFile(path.join(sessionPath(session), 'parts', '00001'))).toEqual(content);
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
            .toMatchObject({ status: 'OPEN', storageReservationBytes: reservationFor(content) });

        await unlink(extra);
        expect((await worker.runOnce()).sessions.processed).toBe(1);
        expect(await storage.hasUpload(session.id)).toBe(false);
    });

    it('retains a part lock with unverified ownership until it is resolved', async () => {
        const { session } = await trackedUpload('unverified part lock');
        const lock = path.join(sessionPath(session), 'parts', '.part-00001');
        await writeFile(lock, JSON.stringify({ host: 'another-host', pid: 1 }));
        await expireAtCurrentTime(session);
        const worker = createWorker();
        expect((await worker.runOnce()).sessions.deferred).toBe(1);
        expect(await readFile(lock, 'utf8')).toContain('another-host');
        await unlink(lock);
        expect((await worker.runOnce()).sessions.processed).toBe(1);
    });

    it('reclaims a verified dead same-host part lock before cleanup', async () => {
        const { session } = await trackedUpload('stale part lock');
        const lock = path.join(sessionPath(session), 'parts', '.part-00001');
        await writeFile(lock, JSON.stringify({ host: os.hostname(), pid: 2_147_483_647 }));
        await expireAtCurrentTime(session);
        expect((await createWorker().runOnce()).sessions.processed).toBe(1);
        expect(await storage.hasUpload(session.id)).toBe(false);
    });

    it('does not delete unattributed assembly partials while cleaning a tracked session', async () => {
        const { session } = await trackedUpload('tracked parts');
        const destinationDirectory = path.dirname(originalPath(session));
        await mkdir(destinationDirectory, { recursive: true });
        const partial = path.join(destinationDirectory, `.partial-2147483647-${randomUUID()}`);
        await writeFile(partial, 'unattributed assembly');
        await expireAtCurrentTime(session);

        expect((await createWorker().runOnce()).sessions.processed).toBe(1);
        expect(await storage.hasUpload(session.id)).toBe(false);
        expect(await readFile(partial, 'utf8')).toBe('unattributed assembly');
    });

    it('retains both an unexpected original and its staged parts for review', async () => {
        const { session, content } = await trackedUpload('still staged');
        await mkdir(path.dirname(originalPath(session)), { recursive: true });
        await writeFile(originalPath(session), 'unexpected original');
        await expireAtCurrentTime(session);
        expect((await createWorker().runOnce()).sessions.failed).toBe(1);
        expect(await readFile(originalPath(session), 'utf8')).toBe('unexpected original');
        expect(await readFile(path.join(sessionPath(session), 'parts', '00001'))).toEqual(content);
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } }))
            .toMatchObject({ status: 'OPEN', storageReservationBytes: reservationFor(content) });
    });

    it('fails closed if the configured storage identity changes', async () => {
        const { session, content } = await trackedUpload('storage identity');
        const identityPath = path.join(storageRoot, '.dvu-storage-id');
        const identity = await readFile(identityPath, 'utf8');
        await writeFile(identityPath, `${randomUUID()}\n`);
        await expireAtCurrentTime(session);
        const worker = createWorker();
        expect((await worker.runOnce()).sessions.failed).toBe(1);
        expect(await readFile(path.join(sessionPath(session), 'parts', '00001'))).toEqual(content);
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('OPEN');
        await writeFile(identityPath, identity);
        expect((await worker.runOnce()).sessions.processed).toBe(1);
    });

    it('does not create a missing storage root during inventory', async () => {
        const missing = path.join(storageRoot, 'missing-originals');
        const worker = createWorker({ storage: createLocalStorageDriver({ root: missing }) });
        await expect(worker.runOnce()).rejects.toMatchObject({ message: 'Upload session cleanup cycle failed' });
        await expect(lstat(missing)).rejects.toMatchObject({ code: 'ENOENT' });
    });

    it('treats a fresh unmarked storage root as empty but refuses an unmarked root with files', async () => {
        const fresh = path.join(storageRoot, 'fresh-originals');
        await mkdir(fresh);
        const worker = createWorker({ storage: createLocalStorageDriver({ root: fresh }) });
        await expect(worker.runOnce()).resolves.toBeTruthy();
        await expect(lstat(path.join(fresh, '.dvu-storage-id'))).rejects.toMatchObject({ code: 'ENOENT' });

        await writeFile(path.join(fresh, 'unexpected'), 'not ours');
        await expect(worker.runOnce()).rejects.toMatchObject({ message: 'Upload session cleanup cycle failed' });
    });

    it.each(['active upload', 'retained original', 'write lease'])(
        'refuses a fresh-looking unmarked root when there is a tracked %s',
        async tracked => {
            let session;
            let content;
            if (tracked === 'write lease') {
                await prisma.storageWriteLease.create({
                    data: {
                        id: randomUUID(),
                        uploadSessionId: randomUUID(),
                        storageIdentity: randomUUID(),
                        sizeBytes: 1n,
                        host: 'another-host',
                        pid: 1,
                    },
                });
            } else {
                ({ session, content } = await trackedUpload('tracked storage'));
                if (tracked === 'retained original') {
                    await service.complete({ ownerId, uploadSessionId: session.id });
                }
            }
            const fresh = path.join(storageRoot, 'other-originals');
            await mkdir(fresh);
            const worker = createWorker({ storage: createLocalStorageDriver({ root: fresh }) });

            await expect(worker.runOnce()).rejects.toMatchObject({
                message: 'Upload session cleanup cycle failed',
                errors: [expect.objectContaining({ code: 'STORAGE_UNAVAILABLE' })],
            });
            if (session) {
                const existing = tracked === 'retained original'
                    ? originalPath(session) : path.join(sessionPath(session), 'parts', '00001');
                expect(await readFile(existing)).toEqual(content);
            }
        },
    );

    it('rechecks a root initialized while its inventory was opening', async () => {
        const fresh = path.join(storageRoot, 'concurrent-originals');
        await mkdir(fresh);
        const freshStorage = createLocalStorageDriver({ root: fresh });
        const openInventory = freshStorage.openUploadInventory.bind(freshStorage);
        let untracked;
        vi.spyOn(freshStorage, 'openUploadInventory').mockImplementationOnce(async () => {
            const inventory = await openInventory();
            untracked = await freshStorage.createUpload({
                ownerId, assetId: randomUUID(), clipId: randomUUID(),
            });
            return inventory;
        });
        const worker = createWorker({ storage: freshStorage });

        expect((await worker.runOnce()).inventory).toEqual({ inspected: 0, reported: 0 });
        expect((await worker.runOnce()).inventory).toMatchObject({ inspected: 1, reported: 1 });
        expect(log.warn).toHaveBeenCalledWith(
            { uploadSessionId: untracked.uploadId, kind: 'directory' },
            'Possible untracked original upload data requires manual review',
        );
    });

    it('defers completion while an asset is moderated and resumes once active', async () => {
        const { session, content } = await trackedUpload('moderated completion');
        await prisma.uploadSession.update({ where: { id: session.id }, data: { status: 'COMPLETING' } });
        await prisma.asset.update({ where: { id: session.assetId }, data: { moderation: 'FLAGGED_FOR_REMOVAL' } });
        const worker = createWorker();
        expect((await worker.runOnce()).sessions.deferred).toBe(1);
        expect(await readFile(path.join(sessionPath(session), 'parts', '00001'))).toEqual(content);
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('COMPLETING');

        await prisma.asset.update({ where: { id: session.assetId }, data: { moderation: 'ACTIVE' } });
        expect((await worker.runOnce()).sessions.processed).toBe(1);
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('OPEN');
    });

    it('defers while moderation holds the asset media lock', async () => {
        const { session, content } = await trackedUpload('moderation in progress');
        await expireAtCurrentTime(session);
        let release;
        let markStarted;
        const started = new Promise(resolve => { markStarted = resolve; });
        const gate = new Promise(resolve => { release = resolve; });
        const holding = withAssetMediaLock(session.assetId, async () => {
            markStarted();
            await gate;
        });
        await started;
        const worker = createWorker();
        try {
            expect((await worker.runOnce()).sessions.deferred).toBe(1);
            expect(await readFile(path.join(sessionPath(session), 'parts', '00001'))).toEqual(content);
            expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('OPEN');
        } finally {
            release();
            await holding;
        }
        expect((await worker.runOnce()).sessions.processed).toBe(1);
    });

    it('runs the opt-in worker with upload intake disabled', async () => {
        const { session } = await trackedUpload('independent cleanup');
        await prisma.uploadSession.update({
            where: { id: session.id }, data: { expiresAt: new Date(0) },
        });
        const config = getUploadSessionCleanupConfig({
            UPLOAD_SESSION_CLEANUP_ENABLED: 'true',
            UPLOAD_SESSIONS_ENABLED: 'false',
            STORAGE_LOCAL_ROOT: storageRoot,
        });
        const stop = startUploadSessionCleanup({ log }, {
            config, db: prisma, withLock: withAssetMediaLock,
        });
        try {
            await waitFor(async () => {
                const current = await prisma.uploadSession.findUnique({ where: { id: session.id } });
                return current.status === 'EXPIRED' && current.storageReservationBytes === 0n;
            });
            expect(await storage.hasUpload(session.id)).toBe(false);
        } finally {
            await stop();
        }
    });

    it('moves past repeatedly failing sessions instead of starving later candidates', async () => {
        const uploads = [];
        for (let index = 0; index < 5; index += 1) {
            const upload = await trackedUpload(`batch-${index}`);
            await expireAtCurrentTime(upload.session);
            uploads.push(upload);
        }
        uploads.sort((left, right) => left.session.id < right.session.id ? -1 : 1);
        const failingId = uploads[0].session.id;
        const abortUpload = storage.abortUpload.bind(storage);
        vi.spyOn(storage, 'abortUpload').mockImplementation(async (uploadId, options) => {
            if (uploadId === failingId) throw new Error('persistent cleanup failure');
            return abortUpload(uploadId, options);
        });
        const worker = createWorker({ sessionBatchSize: 2 });
        await worker.runOnce();
        await worker.runOnce();
        await worker.runOnce();

        expect(await storage.hasUpload(failingId)).toBe(true);
        for (const upload of uploads.slice(1)) {
            expect(await storage.hasUpload(upload.session.id)).toBe(false);
            expect((await prisma.uploadSession.findUnique({ where: { id: upload.session.id } }))
                .storageReservationBytes).toBe(0n);
        }
    });

    it('reports untracked directories in bounded batches without deleting them', async () => {
        const untracked = [];
        for (let index = 0; index < 3; index += 1) {
            untracked.push(await storage.createUpload({
                ownerId, assetId: randomUUID(), clipId: randomUUID(),
            }));
        }
        const worker = createWorker({ inventoryBatchSize: 1 });
        for (let index = 0; index < 4; index += 1) {
            expect((await worker.runOnce()).inventory.inspected).toBeLessThanOrEqual(1);
        }
        for (const item of untracked) {
            expect(await storage.hasUpload(item.uploadId)).toBe(true);
            expect(log.warn).toHaveBeenCalledWith(
                { uploadSessionId: item.uploadId, kind: 'directory' },
                'Possible untracked original upload data requires manual review',
            );
        }
    });

    it('reports untracked and persistent finished-session locks without removing them', async () => {
        const { session } = await trackedUpload('completed for lock inventory');
        await service.complete({ ownerId, uploadSessionId: session.id });
        const untracked = randomUUID();
        const trackedLock = path.join(storageRoot, '.uploads', `.completion-${session.id}`);
        const untrackedLock = path.join(storageRoot, '.uploads', `.completion-${untracked}`);
        const recoveryLock = `${untrackedLock}.recovery`;
        await writeFile(trackedLock, 'review');
        await writeFile(untrackedLock, 'review');
        await writeFile(recoveryLock, 'review');

        expect((await createWorker().runOnce()).inventory.reported).toBe(3);
        expect(log.warn).toHaveBeenCalledWith(
            { uploadSessionId: session.id, status: 'COMPLETED' },
            'Finished upload completion lock may require manual review if it persists',
        );
        for (const [file, kind] of [[untrackedLock, 'completion-lock'], [recoveryLock, 'recovery-lock']]) {
            expect(await readFile(file, 'utf8')).toBe('review');
            expect(log.warn).toHaveBeenCalledWith(
                { uploadSessionId: untracked, kind },
                'Possible untracked original upload data requires manual review',
            );
        }
        expect(await readFile(trackedLock, 'utf8')).toBe('review');
    });

    it('does not report a directory created by an uncommitted upload transaction as orphaned', async () => {
        const { assetId, clipId } = await assetWithClip();
        const content = Buffer.from('creating');
        let release;
        let markCreated;
        const created = new Promise(resolve => { markCreated = resolve; });
        const gate = new Promise(resolve => { release = resolve; });
        const createUpload = storage.createUpload.bind(storage);
        vi.spyOn(storage, 'createUpload').mockImplementation(async input => {
            const result = await createUpload(input);
            markCreated();
            await gate;
            return result;
        });
        const creating = service.create({
            ownerId, assetId, clipId, expectedSizeBytes: content.length, expectedSha256: sha256(content),
        });
        await created;
        const worker = createWorker();
        const scanning = worker.runOnce();
        try {
            await waitForBlockedQuery(pool, 'pg_advisory_xact_lock');
        } finally {
            release();
        }
        const session = await creating;
        await scanning;
        expect(await storage.hasUpload(session.id)).toBe(true);
        expect(log.warn).not.toHaveBeenCalledWith(
            expect.objectContaining({ uploadSessionId: session.id }),
            'Possible untracked original upload data requires manual review',
        );
    });
});
