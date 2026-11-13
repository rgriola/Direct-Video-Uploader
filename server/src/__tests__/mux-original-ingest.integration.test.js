import Fastify from 'fastify';
import rateLimit from '@fastify/rate-limit';
import { createHash, randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { PassThrough, Readable } from 'node:stream';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { createLocalStorageDriver } from '../lib/storage/local-driver.js';
import { acquireIntegrationDatabaseLock, INTEGRATION_SETUP_TIMEOUT_MS } from './helpers/database-lock.js';
import { unrestrictedTestCapacity } from './helpers/storage-capacity.js';

const muxApi = vi.hoisted(() => ({
    createMuxOriginalAsset: vi.fn(),
    inspectMuxAsset: vi.fn(),
    inspectMuxUpload: vi.fn(),
    cancelMuxUpload: vi.fn(),
    deleteMuxAsset: vi.fn(),
    disableMuxPlayback: vi.fn(),
    createMuxPublicPlayback: vi.fn(),
}));
const verifyWebhook = vi.hoisted(() => vi.fn());

vi.mock('../lib/mux.js', () => ({ ...muxApi, isMuxEnabled: true, MUX_ENV_KEY: '' }));
vi.mock('../lib/slack.js', () => ({ isConfigured: () => false }));
vi.mock('../ws/dashboard-notifications.js', () => ({ notifyDashboardAssetChange: vi.fn(async () => {}) }));
vi.mock('@mux/mux-node', () => ({
    default: class {
        constructor() { this.webhooks = { verifySignature: verifyWebhook }; }
    },
}));

const databaseUrl = process.env.TEST_DATABASE_URL;
if (process.env.CI && !databaseUrl) {
    throw new Error('TEST_DATABASE_URL is required for Mux original ingest integration tests in CI');
}
if (databaseUrl) {
    const url = new URL(databaseUrl);
    if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
        || !url.pathname.slice(1).startsWith('dvu_scope_test_')
        || process.env.DATABASE_URL !== databaseUrl) {
        throw new Error('Mux original ingest tests require a dedicated local dvu_scope_test_ database');
    }
}
const integration = databaseUrl ? describe : describe.skip;
const sha256 = content => createHash('sha256').update(content).digest('hex');
const pathAndQuery = url => `${new URL(url).pathname}${new URL(url).search}`;

async function waitFor(predicate) {
    for (let attempt = 0; attempt < 200; attempt += 1) {
        if (await predicate()) return;
        await new Promise(resolve => setTimeout(resolve, 20));
    }
    throw new Error('Timed out waiting for Mux original ingest state');
}

integration('Mux original handoff against PostgreSQL and HTTP', () => {
    const ownerId = `mux-owner-${randomUUID()}`;
    const otherId = `mux-other-${randomUUID()}`;
    const adminId = `mux-super-${randomUUID()}`;
    const uploadSecret = 'upload-session-integration-secret-32-bytes';
    const readSecret = 'mux-original-integration-secret-32-bytes';
    const previousRoot = process.env.STORAGE_LOCAL_ROOT;
    const previousWebhookSecret = process.env.MUX_WEBHOOK_SECRET;
    let app;
    let address;
    let prisma;
    let releaseDatabaseLock;
    let storageRoot;
    let storage;
    let readStorage;
    let createUploadSessionService;
    let createMuxOriginalWorker;
    let reconcileAssetMedia;
    let signMuxOriginalRead;
    let acquireOriginalReadLock;
    let readLockFactory;
    let enqueueMuxOriginal;
    let requestMuxOriginalIngest;
    let worker;
    let currentTime;
    let remoteAssets;
    let assetIds;
    let activeStreams;

    beforeAll(async () => {
        process.env.MUX_WEBHOOK_SECRET = 'mux-integration-webhook-secret';
        const database = await import('../lib/prisma.js');
        prisma = database.default;
        releaseDatabaseLock = await acquireIntegrationDatabaseLock(database.pool);
        const { requireRole } = await import('../lib/authorization.js');
        const { default: uploadSessionRoutes } = await import('../routes/upload-sessions.js');
        const { default: muxOriginalRoutes } = await import('../routes/mux-originals.js');
        const { default: moderationRoutes } = await import('../routes/moderation.js');
        const { default: adminRoutes } = await import('../routes/admin.js');
        const { default: muxWebhookRoutes } = await import('../routes/mux-webhooks.js');
        ({ createUploadSessionService } = await import('../lib/upload-sessions.js'));
        ({ createMuxOriginalWorker } = await import('../jobs/mux-original-ingest.js'));
        ({ reconcileAssetMedia } = await import('../lib/media-reconciliation.js'));
        ({ signMuxOriginalRead } = await import('../lib/mux-original-signing.js'));
        ({ acquireOriginalReadLock } = await import('../lib/mux-original-read-lock.js'));
        ({ enqueueMuxOriginal } = await import('../lib/mux-original-records.js'));
        ({ requestMuxOriginalIngest } = await import('../lib/mux-original-enqueue.js'));

        for (const [index, id] of [ownerId, otherId, adminId].entries()) {
            await prisma.user.create({
                data: {
                    id,
                    name: `Mux Original Test ${index}`,
                    phoneNumber: `mux-original-${randomUUID()}`,
                    pinHash: 'integration-test',
                    role: id === adminId ? 'SUPER_ADMIN' : 'USER',
                },
            });
        }
        storageRoot = await mkdtemp(path.join(os.tmpdir(), 'dvu-mux-original-'));
        process.env.STORAGE_LOCAL_ROOT = storageRoot;
        storage = createLocalStorageDriver({ root: storageRoot });
        readStorage = storage;
        app = Fastify({ logger: false });
        await app.register(rateLimit, { global: false });
        app.decorate('authenticate', async (request, reply) => {
            const id = request.headers.authorization?.replace(/^Bearer /, '');
            const user = id && await prisma.user.findUnique({ where: { id } });
            if (!user || user.status !== 'ACTIVE') return reply.status(401).send({ error: 'Unauthorized' });
            request.user = { id: user.id, role: user.role, companyCode: user.companyCode };
        });
        app.decorate('requireRole', requireRole);
        app.decorate('socketAuthState', { revision: 0 });
        app.decorate('userSockets', new Map());
        app.decorate('io', {
            to: () => ({ emit: () => {} }),
            of: () => ({ sockets: new Map() }),
            sockets: { sockets: new Map() },
        });
        await app.register(uploadSessionRoutes, {
            db: prisma,
            storage,
            capacity: unrestrictedTestCapacity,
            signingSecret: uploadSecret,
            handoff: { onCompleted: enqueueMuxOriginal, request: requestMuxOriginalIngest },
        });
        await app.register(muxOriginalRoutes, {
            db: prisma,
            signingSecret: readSecret,
            storageFactory: () => readStorage,
            acquireLock: (...args) => readLockFactory(...args),
        });
        await app.register(moderationRoutes);
        await app.register(adminRoutes);
        await app.register(muxWebhookRoutes);
        address = await app.listen({ host: '127.0.0.1', port: 0 });
    }, INTEGRATION_SETUP_TIMEOUT_MS);

    beforeEach(async () => {
        vi.clearAllMocks();
        verifyWebhook.mockReturnValue(undefined);
        remoteAssets = new Map();
        assetIds = [];
        activeStreams = [];
        readStorage = storage;
        readLockFactory = acquireOriginalReadLock;
        currentTime = Date.now();
        muxApi.inspectMuxAsset.mockImplementation(async id => ({
            ok: true, asset: remoteAssets.get(id) || null,
        }));
        muxApi.inspectMuxUpload.mockResolvedValue({ ok: true, upload: { status: 'waiting' } });
        muxApi.cancelMuxUpload.mockResolvedValue({ ok: true });
        muxApi.disableMuxPlayback.mockResolvedValue({ ok: true });
        muxApi.deleteMuxAsset.mockImplementation(async id => { remoteAssets.delete(id); return true; });
        muxApi.createMuxPublicPlayback.mockResolvedValue({ ok: true, playbackId: 'published-playback' });
        await prisma.user.updateMany({
            where: { id: { in: [ownerId, otherId] } },
            data: { status: 'ACTIVE' },
        });
        worker = createMuxOriginalWorker({
            db: prisma,
            muxApi,
            storageFactory: () => storage,
            clock: () => new Date(currentTime),
            config: {
                enabled: true,
                baseUrl: address,
                signingSecret: readSecret,
                readTtlMs: 60 * 60 * 1000,
            },
        });
    });

    afterEach(async () => {
        for (const stream of activeStreams) stream.destroy();
        await waitFor(async () => (await prisma.muxOriginalReadLease.count({
            where: { assetId: { in: assetIds } },
        })) === 0);
        await prisma.auditLog.deleteMany({ where: { actorUserId: adminId } });
        await prisma.asset.deleteMany({ where: { id: { in: assetIds } } });
    });

    afterAll(async () => {
        try {
            await app?.close();
            if (prisma) {
                await prisma.asset.deleteMany({ where: { userId: { in: [ownerId, otherId] } } });
                await prisma.auditLog.deleteMany({ where: { actorUserId: adminId } });
                await prisma.user.deleteMany({ where: { id: { in: [ownerId, otherId, adminId] } } });
            }
        } finally {
            await releaseDatabaseLock?.();
            await prisma?.$disconnect();
            if (previousRoot === undefined) delete process.env.STORAGE_LOCAL_ROOT;
            else process.env.STORAGE_LOCAL_ROOT = previousRoot;
            if (previousWebhookSecret === undefined) delete process.env.MUX_WEBHOOK_SECRET;
            else process.env.MUX_WEBHOOK_SECRET = previousWebhookSecret;
            if (storageRoot) await rm(storageRoot, { recursive: true, force: true });
        }
    });

    function requestAs(id, method, url, payload, headers = {}) {
        return app.inject({
            method, url, payload,
            headers: { ...(id ? { authorization: `Bearer ${id}` } : {}), ...headers },
        });
    }

    async function createAsset() {
        const id = randomUUID();
        assetIds.push(id);
        await prisma.asset.create({ data: { id, userId: ownerId, status: 'UPLOADING' } });
        return id;
    }

    async function uploadOriginal(content, { autoQueue = true, onCompleted = enqueueMuxOriginal } = {}) {
        const assetId = await createAsset();
        const service = createUploadSessionService({
            db: prisma,
            storage,
            capacity: unrestrictedTestCapacity,
            ...(autoQueue ? { onCompleted } : {}),
        });
        const session = await service.create({
            ownerId,
            assetId,
            clipId: randomUUID(),
            expectedSizeBytes: content.length,
            expectedSha256: sha256(content),
            initializeClip: true,
        });
        await service.uploadPart({
            ownerId, uploadSessionId: session.id, partNumber: 1,
            body: Readable.from(content), expectedSizeBytes: content.length,
        });
        return { assetId, session, service };
    }

    async function completeOriginal(content, options) {
        const fixture = await uploadOriginal(content, options);
        await fixture.service.complete({ ownerId, uploadSessionId: fixture.session.id });
        currentTime = Math.max(currentTime, Date.now() + 1000);
        return fixture;
    }

    function originalWebhook(type, operation, muxAssetId) {
        return app.inject({
            method: 'POST',
            url: '/api/webhooks/mux',
            headers: { 'mux-signature': 'test-signature' },
            payload: {
                type,
                data: {
                    id: muxAssetId,
                    passthrough: JSON.stringify({
                        assetId: operation.assetId,
                        clipId: operation.clipId,
                        ingestOperationId: operation.operationId,
                    }),
                },
            },
        });
    }

    async function beginSlowRead(url, content) {
        readStorage = {
            ...storage,
            getReadStream: async () => {
                const stream = new PassThrough();
                activeStreams.push(stream);
                stream.write(content.subarray(0, 4));
                return stream;
            },
        };
        return new Promise((resolve, reject) => {
            const request = httpRequest(new URL(url, address), response => {
                const closed = new Promise(done => response.once('close', done));
                response.on('error', () => {});
                response.once('data', chunk => resolve({ request, response, closed, chunk }));
                activeStreams.push(response);
            });
            activeStreams.push(request);
            request.once('error', reject);
            request.end();
        });
    }

    it('atomically queues completion and recovers after a failed enqueue transaction', async () => {
        const content = Buffer.from('transactional original');
        const fixture = await uploadOriginal(content, {
            onCompleted: async () => { throw new Error('injected enqueue failure'); },
        });
        await expect(fixture.service.complete({ ownerId, uploadSessionId: fixture.session.id }))
            .rejects.toThrow('injected enqueue failure');
        expect((await prisma.uploadSession.findUnique({ where: { id: fixture.session.id } })).status)
            .toBe('COMPLETING');
        expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } })).toBeNull();
        expect((await prisma.clip.findUnique({ where: { id: fixture.session.clipId } })).storageKey).toBeNull();

        const resumed = createUploadSessionService({
            db: prisma, storage, capacity: unrestrictedTestCapacity, onCompleted: enqueueMuxOriginal,
        });
        expect((await resumed.get({ ownerId, uploadSessionId: fixture.session.id })).status).toBe('COMPLETED');
        expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } }))
            .toMatchObject({ status: 'QUEUED', attemptCount: 0 });
    });

    it('leaves old completed originals untouched until their owner explicitly requests ingest', async () => {
        const fixture = await completeOriginal(Buffer.from('older original'), { autoQueue: false });
        await worker.runOnce(app);
        expect(muxApi.createMuxOriginalAsset).not.toHaveBeenCalled();
        const url = `/api/upload-sessions/${fixture.session.id}/mux-ingest`;
        expect((await requestAs(null, 'POST', url)).statusCode).toBe(401);
        expect((await requestAs(otherId, 'POST', url)).statusCode).toBe(404);
        expect((await requestAs(adminId, 'POST', url)).statusCode).toBe(404);
        const response = await requestAs(ownerId, 'POST', url);
        expect(response.statusCode, response.body).toBe(202);
        expect(response.json().uploadSession.muxIngest).toMatchObject({ status: 'QUEUED', attemptCount: 0 });
        expect((await requestAs(ownerId, 'POST', url)).statusCode).toBe(202);
        expect(await prisma.muxIngestJob.count({ where: { uploadSessionId: fixture.session.id } })).toBe(1);
    });

    it('queues newly completed uploads through the authenticated HTTP contract', async () => {
        const content = Buffer.from('HTTP upload and handoff');
        const assetId = await createAsset();
        const created = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
            expectedSizeBytes: content.length, expectedSha256: sha256(content),
        });
        expect(created.statusCode, created.body).toBe(201);
        const sessionId = created.json().uploadSession.id;
        const signed = await requestAs(ownerId, 'POST', `/api/upload-sessions/${sessionId}/parts/1/sign`);
        expect(signed.statusCode, signed.body).toBe(200);
        const uploaded = await requestAs(null, 'PUT', signed.json().url, content, {
            'content-type': 'application/octet-stream', 'content-length': String(content.length),
        });
        expect(uploaded.statusCode, uploaded.body).toBe(200);
        const completed = await requestAs(ownerId, 'POST', `/api/upload-sessions/${sessionId}/complete`);
        expect(completed.statusCode, completed.body).toBe(200);
        expect(completed.json().uploadSession).toMatchObject({
            status: 'COMPLETED', muxIngest: { status: 'QUEUED', attemptCount: 0 },
        });
        expect(completed.body).not.toContain('storageKey');
        expect(completed.body).not.toContain('signature');
        expect((await requestAs(ownerId, 'GET', `/api/upload-sessions/${sessionId}`)).json().uploadSession.muxIngest.status)
            .toBe('QUEUED');
    });

    it('serves authenticated-by-capability GET, HEAD, and ranges while the create lock is held', async () => {
        const content = Buffer.from('0123456789-verified-original');
        const fixture = await completeOriginal(content);
        let sourceUrl;
        const read = async (url, options) => {
            const response = await fetch(new URL(url, address), options);
            const body = Buffer.from(await response.arrayBuffer());
            await waitFor(async () => (await prisma.muxOriginalReadLease.count({
                where: { assetId: fixture.assetId },
            })) === 0);
            return { statusCode: response.status, headers: response.headers, rawPayload: body, body: body.toString() };
        };
        muxApi.createMuxOriginalAsset.mockImplementation(async operation => {
            sourceUrl = operation.sourceUrl;
            const url = pathAndQuery(sourceUrl);
            const get = await read(url);
            expect(get.statusCode, get.body).toBe(200);
            expect(get.rawPayload).toEqual(content);
            expect(get.headers.get('cache-control')).toBe('no-store');
            const head = await read(url, { method: 'HEAD' });
            expect(head.statusCode).toBe(200);
            expect(head.headers.get('content-length')).toBe(String(content.length));
            expect(head.rawPayload.length).toBe(0);
            const range = await read(url, { headers: { range: 'bytes=3-7' } });
            expect(range.statusCode).toBe(206);
            expect(range.body).toBe(content.subarray(3, 8).toString());
            expect(range.headers.get('content-range')).toBe(`bytes 3-7/${content.length}`);
            const headRange = await read(url, { method: 'HEAD', headers: { range: 'bytes=3-7' } });
            expect(headRange.statusCode).toBe(206);
            expect(headRange.headers.get('content-length')).toBe('5');
            expect(headRange.headers.get('content-range')).toBe(`bytes 3-7/${content.length}`);
            expect(headRange.rawPayload.length).toBe(0);
            const suffix = await read(url, { headers: { range: 'bytes=-4' } });
            expect(suffix.body).toBe(content.subarray(-4).toString());
            expect((await read(url, { headers: { range: 'bytes=999-' } })).statusCode).toBe(416);
            expect((await read(`${url}x`)).statusCode).toBe(403);
            remoteAssets.set('mux-source-1', { status: 'preparing', playback_ids: [] });
            return { ok: true, muxAssetId: 'mux-source-1' };
        });
        await worker.runOnce(app);
        expect(muxApi.createMuxOriginalAsset).toHaveBeenCalledOnce();
        await expect(muxApi.createMuxOriginalAsset.mock.results[0].value)
            .resolves.toEqual({ ok: true, muxAssetId: 'mux-source-1' });
        const job = await prisma.muxIngestJob.findUnique({
            where: { uploadSessionId: fixture.session.id }, include: { attempts: true },
        });
        expect(job).toMatchObject({ status: 'LINKED', attemptCount: 1 });
        expect(job.attempts[0]).toMatchObject({ status: 'LINKED', muxAssetId: 'mux-source-1' });
        expect((await prisma.clip.findUnique({ where: { id: fixture.session.clipId } })).muxPlaybackId).toBeNull();
        expect((await read(pathAndQuery(sourceUrl))).rawPayload).toEqual(content);
    });

    it('backs off only after confirmed rejection and requires an explicit retry after the cap', async () => {
        const fixture = await completeOriginal(Buffer.from('rate limited original'));
        muxApi.createMuxOriginalAsset.mockResolvedValue({
            ok: false, indeterminate: false, retryable: true, error: 'Mux rate limited asset creation',
        });
        for (let attempt = 1; attempt <= 3; attempt += 1) {
            await worker.runOnce(app);
            const job = await prisma.muxIngestJob.findUnique({
                where: { uploadSessionId: fixture.session.id }, include: { attempts: true },
            });
            expect(job.attemptCount).toBe(attempt);
            expect(job.attempts.every(item => item.status === 'REJECTED')).toBe(true);
            if (attempt < 3) {
                expect(job.status).toBe('QUEUED');
                await worker.runOnce(app);
                expect(muxApi.createMuxOriginalAsset).toHaveBeenCalledTimes(attempt);
                currentTime = job.nextAttemptAt.getTime() + 1;
            } else {
                expect(job.status).toBe('FAILED');
                expect(job.nextAttemptAt).toBeNull();
            }
        }
        const response = await requestAs(ownerId, 'POST', `/api/upload-sessions/${fixture.session.id}/mux-ingest`);
        expect(response.statusCode, response.body).toBe(202);
        expect(response.json().uploadSession.muxIngest).toMatchObject({ status: 'QUEUED', attemptCount: 3 });
        expect((await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } })).retryCount)
            .toBe(0);
    });

    it('bounds local preflight failures without contacting Mux', async () => {
        const fixture = await completeOriginal(Buffer.from('missing original'));
        await storage.delete(fixture.session.storageKey);
        for (let failure = 1; failure <= 3; failure += 1) {
            await worker.runOnce(app);
            const job = await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } });
            expect(job.retryCount).toBe(failure);
            expect(job.attemptCount).toBe(0);
            if (failure < 3) {
                expect(job.status).toBe('QUEUED');
                currentTime = job.nextAttemptAt.getTime() + 1;
            } else {
                expect(job.status).toBe('FAILED');
                expect(job.nextAttemptAt).toBeNull();
            }
        }
        expect(muxApi.createMuxOriginalAsset).not.toHaveBeenCalled();
    });

    it('defers a queued handoff while the account or asset is inactive', async () => {
        const fixture = await completeOriginal(Buffer.from('paused original'));
        await prisma.user.update({ where: { id: ownerId }, data: { status: 'SUSPENDED' } });
        await worker.runOnce(app);
        let job = await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } });
        expect(job).toMatchObject({ status: 'QUEUED', attemptCount: 0 });
        expect(job.nextAttemptAt.getTime()).toBeGreaterThan(currentTime);
        await prisma.user.update({ where: { id: ownerId }, data: { status: 'ACTIVE' } });
        await prisma.asset.update({ where: { id: fixture.assetId }, data: { moderation: 'PAUSED' } });
        currentTime = job.nextAttemptAt.getTime() + 1;
        await worker.runOnce(app);
        job = await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } });
        expect(job).toMatchObject({ status: 'QUEUED', attemptCount: 0 });
        expect(muxApi.createMuxOriginalAsset).not.toHaveBeenCalled();
        await prisma.asset.update({ where: { id: fixture.assetId }, data: { moderation: 'ACTIVE' } });
        currentTime = job.nextAttemptAt.getTime() + 1;
        remoteAssets.set('mux-resumed', { status: 'preparing', playback_ids: [] });
        muxApi.createMuxOriginalAsset.mockResolvedValue({ ok: true, muxAssetId: 'mux-resumed' });
        await worker.runOnce(app);
        expect((await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } })).status)
            .toBe('LINKED');
    });

    it('keeps an ambiguous create blocked until audited Super Admin confirmation', async () => {
        const fixture = await completeOriginal(Buffer.from('ambiguous original'));
        muxApi.createMuxOriginalAsset.mockResolvedValue({
            ok: false, indeterminate: true, retryable: false, error: 'Mux asset creation outcome is unknown',
        });
        await worker.runOnce(app);
        await worker.runOnce(app);
        expect(muxApi.createMuxOriginalAsset).toHaveBeenCalledTimes(1);
        const job = await prisma.muxIngestJob.findUnique({
            where: { uploadSessionId: fixture.session.id }, include: { attempts: true },
        });
        expect(job.status).toBe('UNKNOWN');
        expect(job.attempts[0].status).toBe('UNKNOWN');
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${fixture.session.id}/mux-ingest`)).statusCode)
            .toBe(409);
        const url = `/api/admin/assets/${fixture.assetId}/mux-ingest/confirm-absent`;
        const payload = { operationId: job.currentAttemptId, confirmed: true, reason: 'Verified in Mux' };
        expect((await requestAs(ownerId, 'POST', url, payload)).statusCode).toBe(403);
        expect((await requestAs(adminId, 'POST', url, { ...payload, reason: '' })).statusCode).toBe(400);

        const leaseId = randomUUID();
        await prisma.muxOriginalReadLease.create({
            data: { id: leaseId, assetId: fixture.assetId, attemptId: job.currentAttemptId, serverInstanceId: 'old-server' },
        });
        expect((await requestAs(adminId, 'POST', url, payload)).statusCode).toBe(409);
        const closeUrl = `/api/admin/assets/${fixture.assetId}/original-reads/confirm-closed`;
        expect((await requestAs(adminId, 'POST', closeUrl, { leaseId, confirmed: true, reason: 'Server stopped' })).statusCode)
            .toBeLessThan(300);
        expect((await requestAs(adminId, 'POST', url, payload)).statusCode).toBeLessThan(300);
        expect(await prisma.muxIngestAttempt.findUnique({ where: { id: job.currentAttemptId } }))
            .toMatchObject({ status: 'CONFIRMED_ABSENT' });
        expect(await prisma.auditLog.count({ where: { targetId: fixture.assetId } })).toBe(2);
        await worker.runOnce(app);
        expect(muxApi.createMuxOriginalAsset).toHaveBeenCalledTimes(1);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${fixture.session.id}/mux-ingest`)).statusCode)
            .toBe(202);
    });

    it('recovers interrupted creates as unknown even when handoff is later disabled', async () => {
        const fixture = await completeOriginal(Buffer.from('interrupted create'));
        const operationId = randomUUID();
        await prisma.$transaction(async tx => {
            await tx.muxIngestAttempt.create({
                data: {
                    id: operationId,
                    uploadSessionId: fixture.session.id,
                    readExpiresAt: new Date(currentTime + 60_000),
                },
            });
            await tx.muxIngestJob.update({
                where: { uploadSessionId: fixture.session.id },
                data: { status: 'CREATING', currentAttemptId: operationId, attemptCount: 1, nextAttemptAt: null },
            });
        });
        const recovery = createMuxOriginalWorker({ db: prisma, muxApi, config: { enabled: false } });
        await recovery.runOnce(app);
        expect((await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } })).status)
            .toBe('UNKNOWN');
        expect((await prisma.muxIngestAttempt.findUnique({ where: { id: operationId } })).status).toBe('UNKNOWN');
        expect(muxApi.createMuxOriginalAsset).not.toHaveBeenCalled();
    });

    it('retains the original and reports an error instead of retrying an errored linked asset', async () => {
        const fixture = await completeOriginal(Buffer.from('original with failed Mux processing'));
        let operation;
        muxApi.createMuxOriginalAsset.mockImplementation(async value => {
            operation = value;
            remoteAssets.set('mux-processing-error', { status: 'preparing', playback_ids: [] });
            return { ok: true, muxAssetId: 'mux-processing-error' };
        });
        await worker.runOnce(app);
        remoteAssets.set('mux-processing-error', { status: 'errored', playback_ids: [] });
        const webhook = await originalWebhook('video.asset.errored', operation, 'mux-processing-error');
        expect(webhook.statusCode, webhook.body).toBe(200);

        expect((await prisma.asset.findUnique({ where: { id: fixture.assetId } })).status).toBe('ERROR');
        expect((await prisma.clip.findUnique({ where: { id: fixture.session.clipId } })).status).toBe('ERROR');
        expect(await storage.stat(fixture.session.storageKey)).not.toBeNull();
        const retry = await requestAs(ownerId, 'POST', `/api/upload-sessions/${fixture.session.id}/mux-ingest`);
        expect(retry.statusCode, retry.body).toBe(409);
        expect(retry.json().error).toContain('Mux processing failed');
        await worker.runOnce(app);
        expect(muxApi.createMuxOriginalAsset).toHaveBeenCalledTimes(1);
        expect(await prisma.muxAssetReference.count({ where: { assetId: fixture.assetId } })).toBe(1);
    });

    it('does not recover a live create and safely retains duplicate or conflicting webhooks', async () => {
        const fixture = await completeOriginal(Buffer.from('concurrent webhook original'));
        let started;
        let finish;
        const startedPromise = new Promise(resolve => { started = resolve; });
        const resultPromise = new Promise(resolve => { finish = resolve; });
        let operation;
        muxApi.createMuxOriginalAsset.mockImplementation(async value => {
            operation = value;
            remoteAssets.set('mux-first', { status: 'preparing', playback_ids: [] });
            started();
            return resultPromise;
        });
        const creating = worker.runOnce(app);
        await startedPromise;
        await worker.runOnce(app);
        expect((await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } })).status)
            .toBe('CREATING');
        expect(muxApi.createMuxOriginalAsset).toHaveBeenCalledTimes(1);
        expect((await originalWebhook('video.asset.created', operation, 'mux-first')).statusCode).toBe(200);
        finish({ ok: true, muxAssetId: 'mux-first' });
        await creating;
        expect((await originalWebhook('video.asset.ready', operation, 'mux-first')).statusCode).toBe(200);
        expect(await prisma.muxAssetReference.count({ where: { assetId: fixture.assetId } })).toBe(1);

        remoteAssets.set('mux-late-conflict', { status: 'preparing', playback_ids: [] });
        expect((await originalWebhook('video.asset.created', operation, 'mux-late-conflict')).statusCode).toBe(200);
        expect((await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } })).status)
            .toBe('CONFLICT');
        expect(await prisma.muxAssetReference.count({ where: { assetId: fixture.assetId } })).toBe(2);
        expect(muxApi.createMuxPublicPlayback).not.toHaveBeenCalled();

        const moderationUrl = `/api/admin/assets/${fixture.assetId}/moderation`;
        expect((await requestAs(adminId, 'PATCH', moderationUrl, {
            moderation: 'FLAGGED_FOR_REMOVAL', reason: 'Remove conflicting originals',
        })).statusCode).toBe(202);
        const removed = await requestAs(adminId, 'PATCH', moderationUrl, {
            moderation: 'REMOVED', reason: 'Remove conflicting originals',
        });
        expect(removed.statusCode, removed.body).toBe(200);
        expect(remoteAssets.size).toBe(0);
        expect(await storage.stat(fixture.session.storageKey)).toBeNull();
    });

    it('retains a late asset after absence confirmation and blocks a concurrent retry from publishing', async () => {
        const fixture = await completeOriginal(Buffer.from('late contradictory result'));
        let firstOperation;
        muxApi.createMuxOriginalAsset.mockImplementationOnce(async operation => {
            firstOperation = operation;
            return { ok: false, indeterminate: true, retryable: false };
        });
        await worker.runOnce(app);
        const confirm = await requestAs(adminId, 'POST', `/api/admin/assets/${fixture.assetId}/mux-ingest/confirm-absent`, {
            operationId: firstOperation.operationId, confirmed: true, reason: 'Checked before retry',
        });
        expect(confirm.statusCode, confirm.body).toBeLessThan(300);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${fixture.session.id}/mux-ingest`)).statusCode)
            .toBe(202);

        let started;
        let finish;
        const startedPromise = new Promise(resolve => { started = resolve; });
        const resultPromise = new Promise(resolve => { finish = resolve; });
        muxApi.createMuxOriginalAsset.mockImplementationOnce(async () => {
            started();
            return resultPromise;
        });
        const retry = worker.runOnce(app);
        await startedPromise;
        remoteAssets.set('mux-old-late', { status: 'preparing', playback_ids: [] });
        expect((await originalWebhook('video.asset.created', firstOperation, 'mux-old-late')).statusCode).toBe(200);
        remoteAssets.set('mux-new', { status: 'preparing', playback_ids: [] });
        finish({ ok: true, muxAssetId: 'mux-new' });
        await retry;
        const job = await prisma.muxIngestJob.findUnique({
            where: { uploadSessionId: fixture.session.id }, include: { attempts: true },
        });
        expect(job.status).toBe('CONFLICT');
        expect(job.attempts.map(attempt => attempt.status)).toEqual(['LINKED', 'LINKED']);
        expect(await prisma.muxAssetReference.count({ where: { assetId: fixture.assetId } })).toBe(2);
        expect(muxApi.createMuxPublicPlayback).not.toHaveBeenCalled();
    });

    it('rechecks account, moderation, metadata, expiry, and original availability on reads', async () => {
        const content = Buffer.from('capability verification original');
        const fixture = await completeOriginal(content);
        let sourceUrl;
        muxApi.createMuxOriginalAsset.mockImplementation(async operation => {
            sourceUrl = operation.sourceUrl;
            remoteAssets.set('mux-readable', { status: 'preparing', playback_ids: [] });
            return { ok: true, muxAssetId: 'mux-readable' };
        });
        await worker.runOnce(app);
        const read = () => fetch(sourceUrl);
        await prisma.user.update({ where: { id: ownerId }, data: { status: 'SUSPENDED' } });
        expect((await read()).status).toBe(403);
        await prisma.user.update({ where: { id: ownerId }, data: { status: 'ACTIVE' } });
        await prisma.asset.update({ where: { id: fixture.assetId }, data: { moderation: 'PAUSED' } });
        expect((await read()).status).toBe(403);
        await prisma.asset.update({ where: { id: fixture.assetId }, data: { moderation: 'ACTIVE' } });
        await prisma.clip.update({ where: { id: fixture.session.clipId }, data: { sha256: '0'.repeat(64) } });
        expect((await read()).status).toBe(403);
        await prisma.clip.update({ where: { id: fixture.session.clipId }, data: { sha256: sha256(content) } });

        const job = await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } });
        const expired = Math.floor(Date.now() / 1000) - 1;
        const signature = signMuxOriginalRead(readSecret, job.currentAttemptId, expired);
        expect((await fetch(`${address}/api/mux-originals/${job.currentAttemptId}?expires=${expired}&signature=${signature}`)).status)
            .toBe(403);
        await storage.delete(fixture.session.storageKey);
        expect((await read()).status).toBe(503);
    });

    it('keeps moderation pending until a live original read is closed', async () => {
        const content = Buffer.from('a long original stream held during moderation');
        const fixture = await completeOriginal(content);
        let sourceUrl;
        muxApi.createMuxOriginalAsset.mockImplementation(async operation => {
            sourceUrl = operation.sourceUrl;
            remoteAssets.set('mux-moderation', { status: 'ready', playback_ids: [] });
            return { ok: true, muxAssetId: 'mux-moderation' };
        });
        await worker.runOnce(app);
        const client = await beginSlowRead(sourceUrl, content);
        expect(client.chunk).toEqual(content.subarray(0, 4));
        const lease = await prisma.muxOriginalReadLease.findFirst({ where: { assetId: fixture.assetId } });
        expect(lease).not.toBeNull();
        const moderationUrl = `/api/admin/assets/${fixture.assetId}/moderation`;
        const flagged = await requestAs(adminId, 'PATCH', moderationUrl, {
            moderation: 'FLAGGED_FOR_REMOVAL', reason: 'Moderation race test',
        });
        expect(flagged.statusCode, flagged.body).toBe(202);
        expect(flagged.json().mediaSyncState).toBe('PENDING');
        expect(await storage.stat(fixture.session.storageKey)).not.toBeNull();
        const confirm = await requestAs(adminId, 'POST', `/api/admin/assets/${fixture.assetId}/original-reads/confirm-closed`, {
            leaseId: lease.id, confirmed: true, reason: 'Attempt to close live read',
        });
        expect(confirm.statusCode).toBe(409);
        await client.closed;
        await waitFor(async () => (await prisma.muxOriginalReadLease.count({ where: { assetId: fixture.assetId } })) === 0);

        const removed = await requestAs(adminId, 'PATCH', moderationUrl, {
            moderation: 'REMOVED', reason: 'Moderation race test',
        });
        expect(removed.statusCode, removed.body).toBe(200);
        expect(await storage.stat(fixture.session.storageKey)).toBeNull();
        expect((await fetch(sourceUrl)).status).toBe(403);
    }, 10_000);

    it('retains the original after a crashed reader until audited lease recovery', async () => {
        const fixture = await completeOriginal(Buffer.from('crashed reader'));
        remoteAssets.set('mux-crashed-reader', { status: 'ready', playback_ids: [] });
        muxApi.createMuxOriginalAsset.mockResolvedValue({ ok: true, muxAssetId: 'mux-crashed-reader' });
        await worker.runOnce(app);
        const job = await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } });
        const leaseId = randomUUID();
        await prisma.muxOriginalReadLease.create({
            data: { id: leaseId, assetId: fixture.assetId, attemptId: job.currentAttemptId, serverInstanceId: 'old-server' },
        });
        await prisma.asset.update({
            where: { id: fixture.assetId },
            data: { moderation: 'REMOVED', mediaSyncRevision: { increment: 1 }, mediaSyncState: 'PENDING' },
        });
        expect(await reconcileAssetMedia(app, fixture.assetId)).toMatchObject({ state: 'PENDING' });
        expect(await storage.stat(fixture.session.storageKey)).not.toBeNull();
        const response = await requestAs(adminId, 'POST', `/api/admin/assets/${fixture.assetId}/original-reads/confirm-closed`, {
            leaseId, confirmed: true, reason: 'Verified old server and connection stopped',
        });
        expect(response.statusCode, response.body).toBe(200);
        expect(await storage.stat(fixture.session.storageKey)).toBeNull();
        expect(await prisma.auditLog.findFirst({ where: { targetId: fixture.assetId } }))
            .toMatchObject({ action: 'ORIGINAL_READ_CONFIRMED_CLOSED' });
    });

    it('terminates in-flight reads after account suspension, expiration, or lock loss', async () => {
        const content = Buffer.from('stream with changing authorization');
        const fixture = await completeOriginal(content);
        let sourceUrl;
        muxApi.createMuxOriginalAsset.mockImplementation(async operation => {
            sourceUrl = operation.sourceUrl;
            remoteAssets.set('mux-stream', { status: 'preparing', playback_ids: [] });
            return { ok: true, muxAssetId: 'mux-stream' };
        });
        await worker.runOnce(app);
        let client = await beginSlowRead(sourceUrl, content);
        const suspended = await requestAs(adminId, 'PATCH', `/api/admin/users/${ownerId}/status`, {
            status: 'SUSPENDED', reason: 'Suspend read test',
        });
        expect(suspended.statusCode, suspended.body).toBe(200);
        await client.closed;
        await waitFor(async () => (await prisma.muxOriginalReadLease.count({ where: { assetId: fixture.assetId } })) === 0);
        await prisma.user.update({ where: { id: ownerId }, data: { status: 'ACTIVE' } });

        let triggerLockLoss;
        readLockFactory = (assetId, onLost) => {
            triggerLockLoss = onLost;
            return acquireOriginalReadLock(assetId, onLost);
        };
        client = await beginSlowRead(sourceUrl, content);
        triggerLockLoss();
        await client.closed;
        await waitFor(async () => (await prisma.muxOriginalReadLease.count({ where: { assetId: fixture.assetId } })) === 0);
        readLockFactory = acquireOriginalReadLock;

        const job = await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } });
        const expires = Math.floor(Date.now() / 1000) + 2;
        await prisma.muxIngestAttempt.update({
            where: { id: job.currentAttemptId },
            data: { readExpiresAt: new Date(expires * 1000) },
        });
        const signature = signMuxOriginalRead(readSecret, job.currentAttemptId, expires);
        client = await beginSlowRead(
            `${address}/api/mux-originals/${job.currentAttemptId}?expires=${expires}&signature=${signature}`,
            content,
        );
        await client.closed;
        await waitFor(async () => (await prisma.muxOriginalReadLease.count({ where: { assetId: fixture.assetId } })) === 0);
    }, 12_000);

    it('releases a read lease when the client disconnects during storage preflight', async () => {
        const content = Buffer.from('disconnect during storage lookup');
        const fixture = await completeOriginal(content);
        let sourceUrl;
        muxApi.createMuxOriginalAsset.mockImplementation(async operation => {
            sourceUrl = operation.sourceUrl;
            remoteAssets.set('mux-disconnect', { status: 'preparing', playback_ids: [] });
            return { ok: true, muxAssetId: 'mux-disconnect' };
        });
        await worker.runOnce(app);
        let started;
        let release;
        const entered = new Promise(resolve => { started = resolve; });
        const gate = new Promise(resolve => { release = resolve; });
        readStorage = {
            ...storage,
            stat: async key => {
                started();
                await gate;
                return storage.stat(key);
            },
        };
        const request = httpRequest(sourceUrl);
        request.on('error', () => {});
        activeStreams.push(request);
        request.end();
        await entered;
        expect(await prisma.muxOriginalReadLease.count({ where: { assetId: fixture.assetId } })).toBe(1);
        request.destroy();
        await waitFor(async () => (await prisma.muxOriginalReadLease.count({ where: { assetId: fixture.assetId } })) === 0);
        release();
    });

    it('cancels live reads during server shutdown before releasing their leases', async () => {
        const content = Buffer.from('shutdown with an active original stream');
        const fixture = await completeOriginal(content);
        let sourceUrl;
        muxApi.createMuxOriginalAsset.mockImplementation(async operation => {
            sourceUrl = operation.sourceUrl;
            remoteAssets.set('mux-shutdown', { status: 'preparing', playback_ids: [] });
            return { ok: true, muxAssetId: 'mux-shutdown' };
        });
        await worker.runOnce(app);
        const { default: muxOriginalRoutes } = await import('../routes/mux-originals.js');
        const other = Fastify({ logger: false });
        await other.register(rateLimit, { global: false });
        await other.register(muxOriginalRoutes, {
            db: prisma,
            signingSecret: readSecret,
            storageFactory: () => readStorage,
        });
        const otherAddress = await other.listen({ host: '127.0.0.1', port: 0 });
        try {
            const client = await beginSlowRead(`${otherAddress}${pathAndQuery(sourceUrl)}`, content);
            expect(await prisma.muxOriginalReadLease.count({ where: { assetId: fixture.assetId } })).toBe(1);
            await other.close();
            await client.closed;
            await waitFor(async () => (await prisma.muxOriginalReadLease.count({ where: { assetId: fixture.assetId } })) === 0);
        } finally {
            await other.close();
        }
    }, 10_000);

    it('blocks hard deletion when an unresolved ingest or orphaned read lease remains', async () => {
        const fixture = await completeOriginal(Buffer.from('hard delete guard'));
        muxApi.createMuxOriginalAsset.mockResolvedValue({
            ok: false, indeterminate: true, retryable: false,
        });
        await worker.runOnce(app);
        const job = await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: fixture.session.id } });
        await prisma.asset.update({
            where: { id: fixture.assetId },
            data: { moderation: 'REMOVED', mediaSyncState: 'SYNCED' },
        });
        const deleteUrl = `/api/admin/users/${ownerId}`;
        expect((await requestAs(adminId, 'DELETE', deleteUrl)).statusCode).toBe(409);

        await prisma.muxIngestAttempt.update({
            where: { id: job.currentAttemptId },
            data: { status: 'LINKED', muxAssetId: 'mux-hard-delete' },
        });
        const leaseId = randomUUID();
        await prisma.muxOriginalReadLease.create({
            data: { id: leaseId, assetId: fixture.assetId, attemptId: job.currentAttemptId, serverInstanceId: 'old-server' },
        });
        expect((await requestAs(adminId, 'DELETE', deleteUrl)).statusCode).toBe(409);
        await prisma.muxOriginalReadLease.delete({ where: { id: leaseId } });
        expect(await prisma.user.findUnique({ where: { id: ownerId } })).not.toBeNull();
    });

    it('retains minimal correlation atomically and records late webhooks after hard deletion', async () => {
        const fixture = await completeOriginal(Buffer.from('late webhook after account deletion'));
        const owner = await prisma.user.findUniqueOrThrow({ where: { id: ownerId } });
        let operation;
        muxApi.createMuxOriginalAsset.mockImplementation(async value => {
            operation = value;
            remoteAssets.set('mux-before-delete', { status: 'preparing', playback_ids: [] });
            return { ok: true, muxAssetId: 'mux-before-delete' };
        });
        await worker.runOnce(app);
        const moderationUrl = `/api/admin/assets/${fixture.assetId}/moderation`;
        expect((await requestAs(adminId, 'PATCH', moderationUrl, {
            moderation: 'FLAGGED_FOR_REMOVAL', reason: 'Remove original',
        })).statusCode).toBe(202);
        expect((await requestAs(adminId, 'PATCH', moderationUrl, {
            moderation: 'REMOVED', reason: 'Remove original',
        })).statusCode).toBe(200);

        try {
            // A failed correlation write must roll back the account deletion.
            await prisma.muxRetiredIngestAttempt.create({
                data: { operationId: operation.operationId },
            });
            expect((await requestAs(adminId, 'DELETE', `/api/admin/users/${ownerId}`)).statusCode).toBe(500);
            expect(await prisma.user.findUnique({ where: { id: ownerId } })).not.toBeNull();
            expect(await prisma.muxIngestAttempt.findUnique({ where: { id: operation.operationId } })).not.toBeNull();
            await prisma.muxRetiredIngestAttempt.delete({ where: { operationId: operation.operationId } });

            let unlock;
            let locked;
            const acquired = new Promise(resolve => { locked = resolve; });
            const release = new Promise(resolve => { unlock = resolve; });
            const holder = prisma.$transaction(async tx => {
                await tx.$queryRaw`SELECT id FROM users WHERE id = ${ownerId} FOR UPDATE`;
                locked();
                await release;
            }, { timeout: 10000 });
            let deleted;
            let concurrentWebhook;
            try {
                await acquired;
                const deleting = requestAs(adminId, 'DELETE', `/api/admin/users/${ownerId}`);
                await waitFor(async () => {
                    const rows = await prisma.$queryRaw`
                        SELECT count(*)::int AS count FROM pg_stat_activity
                        WHERE datname = current_database() AND wait_event_type = 'Lock'
                            AND query LIKE '%SELECT role FROM users%'
                    `;
                    return rows[0].count > 0;
                });
                const late = originalWebhook('video.asset.created', operation, 'mux-after-delete');
                await waitFor(async () => {
                    const rows = await prisma.$queryRaw`
                        SELECT count(*)::int AS count FROM pg_stat_activity
                        WHERE datname = current_database() AND wait_event_type = 'Lock'
                            AND query LIKE '%SELECT id FROM users%'
                    `;
                    return rows[0].count > 0;
                });
                unlock();
                [deleted, concurrentWebhook] = await Promise.all([deleting, late]);
            } finally {
                unlock();
                await holder;
            }
            expect(deleted.statusCode, deleted.body).toBe(200);
            expect(concurrentWebhook.statusCode).toBe(503);
            expect(concurrentWebhook.json().error).toBe('Mux reference retained; manual reconciliation required');
            expect(await prisma.user.findUnique({ where: { id: ownerId } })).toBeNull();
            expect(await prisma.muxIngestAttempt.findUnique({ where: { id: operation.operationId } })).toBeNull();
            const retired = await prisma.muxRetiredIngestAttempt.findUniqueOrThrow({
                where: { operationId: operation.operationId },
            });
            expect(Object.keys(retired).sort()).toEqual(['operationId', 'originalMuxAssetId', 'retiredAt']);
            expect(retired.originalMuxAssetId).toBe('mux-before-delete');

            for (const type of ['video.asset.created', 'video.asset.ready']) {
                expect((await originalWebhook(type, operation, 'mux-after-delete')).statusCode).toBe(503);
            }
            expect(await prisma.muxRetiredIngestEvent.findMany({
                where: { operationId: operation.operationId },
            })).toMatchObject([{ operationId: operation.operationId, muxAssetId: 'mux-after-delete' }]);
            const unknownOperation = randomUUID();
            const unknown = await originalWebhook('video.asset.created', {
                ...operation, operationId: unknownOperation,
            }, 'mux-unknown');
            expect(unknown.statusCode).toBe(503);
            expect(unknown.json().error).toBe('Could not retain Mux ingest reference');
            expect(await prisma.muxRetiredIngestEvent.count({
                where: { operationId: unknownOperation },
            })).toBe(0);
        } finally {
            if (operation) {
                await prisma.muxRetiredIngestEvent.deleteMany({ where: { operationId: operation.operationId } });
                await prisma.muxRetiredIngestAttempt.deleteMany({ where: { operationId: operation.operationId } });
            }
            if (!await prisma.user.findUnique({ where: { id: ownerId } })) {
                await prisma.user.create({ data: owner });
            }
        }
    }, 15000);
});
