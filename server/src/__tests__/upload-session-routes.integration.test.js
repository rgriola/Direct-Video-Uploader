import Fastify from 'fastify';
import fastifyJwt from '@fastify/jwt';
import cookie from '@fastify/cookie';
import csrfProtection from '@fastify/csrf-protection';
import rateLimit from '@fastify/rate-limit';
import { createHash, randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { createLocalStorageDriver, MAX_PART_SIZE_BYTES } from '../lib/storage/local-driver.js';
import { acquireIntegrationDatabaseLock, INTEGRATION_SETUP_TIMEOUT_MS } from './helpers/database-lock.js';
import { unrestrictedTestCapacity } from './helpers/storage-capacity.js';

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
    throw new Error('TEST_DATABASE_URL is required for upload route integration tests in CI');
}
if (databaseUrl) {
    const url = new URL(databaseUrl);
    if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
        || !url.pathname.slice(1).startsWith('dvu_scope_test_')
        || process.env.DATABASE_URL !== databaseUrl) {
        throw new Error('Upload route tests require a dedicated local dvu_scope_test_ database');
    }
}

const integration = databaseUrl ? describe : describe.skip;
const sha256 = content => createHash('sha256').update(content).digest('hex');

async function waitFor(predicate) {
    for (let attempt = 0; attempt < 150; attempt += 1) {
        if (await predicate()) return;
        await new Promise(resolve => setTimeout(resolve, 20));
    }
    throw new Error('Timed out waiting for upload state');
}

integration('upload session HTTP routes against PostgreSQL and local storage', () => {
    const ownerId = `upload-owner-${randomUUID()}`;
    const otherId = `upload-other-${randomUUID()}`;
    const adminId = `upload-admin-${randomUUID()}`;
    const teamAdminId = `upload-team-admin-${randomUUID()}`;
    const signingSecret = 'upload-route-integration-secret-32-bytes';
    const previousRoot = process.env.STORAGE_LOCAL_ROOT;
    let app;
    let address;
    let prisma;
    let releaseDatabaseLock;
    let storageRoot;
    let storage;
    let cleanupOrphanedUploads;
    let reconcileAssetMedia;
    let createMediaReconciler;
    let withAssetMediaLock;
    let uploadTransactionTimeZone;
    let assetId;
    let currentTime;
    let tokens;
    const socketEmit = vi.fn();
    const socketTo = vi.fn(() => ({ emit: socketEmit }));

    beforeAll(async () => {
        const database = await import('../lib/prisma.js');
        prisma = database.default;
        releaseDatabaseLock = await acquireIntegrationDatabaseLock(database.pool);
        const { authenticate } = await import('../lib/authentication.js');
        const { requireRole } = await import('../lib/authorization.js');
        const { default: adminRoutes } = await import('../routes/admin.js');
        const { default: assetRoutes } = await import('../routes/assets.js');
        const { default: moderationRoutes } = await import('../routes/moderation.js');
        const { default: uploadSessionRoutes } = await import('../routes/upload-sessions.js');
        ({ cleanupOrphanedUploads } = await import('../jobs/upload-cleanup.js'));
        ({ reconcileAssetMedia, createMediaReconciler } = await import('../lib/media-reconciliation.js'));
        ({ withAssetMediaLock } = await import('../lib/media-lock.js'));

        for (const [index, id] of [ownerId, otherId, adminId, teamAdminId].entries()) {
            await prisma.user.create({
                data: {
                    id,
                    name: `Upload Route Test ${index}`,
                    phoneNumber: `upload-route-${randomUUID()}`,
                    pinHash: 'integration-test',
                    role: id === adminId ? 'SUPER_ADMIN' : id === teamAdminId ? 'ADMIN' : 'USER',
                },
            });
        }
        storageRoot = await mkdtemp(path.join(os.tmpdir(), 'dvu-upload-routes-'));
        process.env.STORAGE_LOCAL_ROOT = storageRoot;
        storage = createLocalStorageDriver({ root: storageRoot });
        app = Fastify({ logger: false, bodyLimit: 2 * 1024 * 1024 });
        await app.register(fastifyJwt, { secret: 'integration-jwt-secret' });
        app.decorate('authenticate', authenticate);
        app.decorate('requireRole', requireRole);
        app.decorate('socketAuthState', { revision: 0 });
        app.decorate('userSockets', new Map());
        app.decorate('io', {
            to: socketTo,
            of: () => ({ sockets: new Map() }),
            sockets: { sockets: new Map() },
        });
        const uploadDb = new Proxy(prisma, {
            get(target, property) {
                if (property !== '$transaction') return Reflect.get(target, property, target);
                return (work, options) => {
                    if (!uploadTransactionTimeZone) return target.$transaction(work, options);
                    const timeZone = uploadTransactionTimeZone;
                    return target.$transaction(async tx => {
                        const [{ configuredTimeZone }] = await tx.$queryRaw`
                            SELECT set_config('TimeZone', ${timeZone}, true) AS "configuredTimeZone"`;
                        expect(configuredTimeZone).toBe(timeZone);
                        return work(tx);
                    }, options);
                };
            },
        });
        await app.register(assetRoutes);
        await app.register(adminRoutes);
        await app.register(moderationRoutes);
        await app.register(uploadSessionRoutes, {
            db: uploadDb,
            storage,
            capacity: unrestrictedTestCapacity,
            signingSecret,
            now: () => new Date(currentTime),
        });
        tokens = Object.fromEntries([ownerId, otherId, adminId, teamAdminId].map(id => [id, app.jwt.sign({ id })]));
        address = await app.listen({ host: '127.0.0.1', port: 0 });
    }, INTEGRATION_SETUP_TIMEOUT_MS);

    beforeEach(async () => {
        vi.clearAllMocks();
        muxApi.createDirectUpload.mockResolvedValue({
            uploadUrl: 'https://upload.example.test/video', muxUploadId: 'test-mux-upload',
        });
        muxApi.inspectMuxAsset.mockResolvedValue({ ok: true, asset: null });
        muxApi.inspectMuxUpload.mockResolvedValue({ ok: true, upload: { status: 'waiting' } });
        muxApi.disableMuxPlayback.mockResolvedValue({ ok: true });
        currentTime = Date.now();
        assetId = randomUUID();
        await prisma.user.updateMany({
            where: { id: { in: [ownerId, otherId] } },
            data: { status: 'ACTIVE' },
        });
        await prisma.asset.create({
            data: { id: assetId, userId: ownerId, originalFileName: 'video.mp4', status: 'UPLOADING' },
        });
    });

    afterEach(async () => {
        await prisma.auditLog.deleteMany({ where: { actorUserId: adminId } });
        await prisma.asset.deleteMany({ where: { userId: { in: [ownerId, otherId, adminId, teamAdminId] } } });
    });

    afterAll(async () => {
        try {
            if (app) await app.close();
            if (prisma) {
                await prisma.asset.deleteMany({ where: { userId: { in: [ownerId, otherId, adminId, teamAdminId] } } });
                await prisma.auditLog.deleteMany({ where: { actorUserId: adminId } });
                await prisma.user.deleteMany({ where: { id: { in: [ownerId, otherId, adminId, teamAdminId] } } });
            }
        } finally {
            await releaseDatabaseLock?.();
            await prisma?.$disconnect();
            if (previousRoot === undefined) delete process.env.STORAGE_LOCAL_ROOT;
            else process.env.STORAGE_LOCAL_ROOT = previousRoot;
            if (storageRoot) await rm(storageRoot, { recursive: true, force: true });
        }
    });

    function requestAs(userId, method, url, payload, headers = {}) {
        return app.inject({
            method,
            url,
            payload,
            headers: { ...(userId ? { authorization: `Bearer ${tokens[userId]}` } : {}), ...headers },
        });
    }

    async function createSession(content, targetAssetId = assetId, userId = ownerId) {
        const response = await requestAs(userId, 'POST', `/api/assets/${targetAssetId}/upload-sessions`, {
            expectedSizeBytes: content.length,
            expectedSha256: sha256(content),
        });
        expect(response.statusCode, response.body).toBe(201);
        return response.json().uploadSession;
    }

    function originalReservation(content) {
        return {
            clientRequestId: randomUUID(),
            fileName: 'native.mov',
            expectedSizeBytes: content.length,
            expectedSha256: sha256(content),
        };
    }

    async function waitForBlockedBy(pid) {
        await vi.waitFor(async () => {
            const [result] = await prisma.$queryRaw`
                SELECT EXISTS (
                    SELECT 1 FROM pg_stat_activity
                    WHERE ${pid} = ANY(pg_blocking_pids(pid))
                ) AS blocked`;
            expect(result.blocked).toBe(true);
        }, { timeout: 5_000, interval: 10 });
    }

    async function sign(sessionId, partNumber = 1, userId = ownerId) {
        const response = await requestAs(userId, 'POST', `/api/upload-sessions/${sessionId}/parts/${partNumber}/sign`);
        expect(response.statusCode, response.body).toBe(200);
        expect(response.headers['cache-control']).toBe('no-store');
        return response.json();
    }

    function put(url, payload, headers = {}) {
        return requestAs(null, 'PUT', url, payload, { 'content-type': 'application/octet-stream', ...headers });
    }

    function sendHttp(url, headers, chunks) {
        return new Promise((resolve, reject) => {
            let responded = false;
            const request = httpRequest(new URL(url, address), { method: 'PUT', headers }, response => {
                responded = true;
                let body = '';
                response.setEncoding('utf8');
                response.on('data', chunk => { body += chunk; });
                response.on('end', () => resolve({ status: response.statusCode, body }));
                response.on('error', reject);
            });
            request.on('error', error => { if (!responded) reject(error); });
            Readable.from(chunks).pipe(request);
        });
    }

    it('registers the real routes only when enabled and serves an upload through the application registry', async () => {
        const { authenticate } = await import('../lib/authentication.js');
        const { requireRole } = await import('../lib/authorization.js');
        const { registerApplicationRoutes } = await import('../routes/index.js');
        const servers = [];
        async function buildServer(enabled) {
            vi.stubEnv('UPLOAD_SESSIONS_ENABLED', String(enabled));
            const server = Fastify({ logger: false, bodyLimit: 2 * 1024 * 1024 });
            servers.push(server);
            await server.register(cookie);
            await server.register(csrfProtection);
            await server.register(rateLimit, { global: true, max: 100, timeWindow: '1 minute' });
            await server.register(fastifyJwt, { secret: 'integration-jwt-secret' });
            server.decorate('authenticate', authenticate);
            server.decorate('requireRole', requireRole);
            server.decorate('io', { to: socketTo });
            await registerApplicationRoutes(server);
            return server;
        }

        vi.stubEnv('STORAGE_DRIVER', 'local');
        vi.stubEnv('JWT_SECRET', 'integration-jwt-secret');
        vi.stubEnv('UPLOAD_SESSION_SIGNING_SECRET', signingSecret);
        vi.stubEnv('UPLOAD_STORAGE_MAX_BYTES', '10737418240');
        vi.stubEnv('UPLOAD_STORAGE_MIN_FREE_BYTES', '1048576');
        const content = Buffer.from('registered upload');
        const url = `/api/assets/${assetId}/upload-sessions`;
        const payload = { expectedSizeBytes: content.length, expectedSha256: sha256(content) };
        try {
            const disabled = await buildServer(false);
            expect((await disabled.inject({ method: 'POST', url, payload })).statusCode).toBe(404);
            expect((await disabled.inject({
                method: 'POST', url: '/api/assets/original-uploads',
                payload: { clientRequestId: randomUUID(), fileName: 'video.mp4' },
            })).statusCode).toBe(404);
            const pageUrl = `/api/assets/original-uploads/${randomUUID()}/sessions`;
            expect((await disabled.inject({ method: 'GET', url: pageUrl })).statusCode).toBe(404);
            const enabled = await buildServer(true);
            expect((await enabled.inject({ method: 'POST', url, payload })).statusCode).toBe(401);
            expect((await enabled.inject({ method: 'GET', url: pageUrl })).statusCode).toBe(401);
            const headers = { authorization: ['Bearer', tokens[ownerId]].join(' ') };
            for (let attempt = 0; attempt < 9; attempt += 1) {
                expect((await enabled.inject({ method: 'GET', url: pageUrl, headers })).statusCode).toBe(404);
            }
            expect((await enabled.inject({ method: 'GET', url: pageUrl, headers })).statusCode).toBe(429);
            const intent = await enabled.inject({
                method: 'POST',
                url: '/api/assets/original-uploads',
                headers,
                payload: { clientRequestId: randomUUID(), fileName: 'video.mp4', ...payload },
            });
            expect(intent.statusCode, intent.body).toBe(201);
            const pendingId = intent.json().asset.id;
            expect(await prisma.uploadSession.count({ where: { assetId: pendingId } })).toBe(0);
            const disabledReservation = await disabled.inject({
                method: 'GET', url: `/api/assets/${pendingId}`, headers,
            });
            expect(disabledReservation.statusCode).toBe(200);
            expect(disabledReservation.json().asset.uploadMode).toBe('ORIGINAL');
            const created = await enabled.inject({ method: 'POST', url, payload, headers });
            expect(created.statusCode, created.body).toBe(201);
            const session = created.json().uploadSession;
            const disabledDetail = await disabled.inject({
                method: 'GET', url: `/api/assets/${assetId}`, headers,
            });
            expect(disabledDetail.statusCode).toBe(200);
            expect(disabledDetail.json().asset.uploadMode).toBe('ORIGINAL');
            const signed = await enabled.inject({
                method: 'POST', url: `/api/upload-sessions/${session.id}/parts/1/sign`, headers,
            });
            expect(signed.statusCode).toBe(200);
            const uploaded = await enabled.inject({
                method: 'PUT',
                url: signed.json().url,
                payload: content,
                headers: { 'content-type': 'application/octet-stream' },
            });
            expect(uploaded.statusCode, uploaded.body).toBe(200);
            const completed = await enabled.inject({
                method: 'POST', url: `/api/upload-sessions/${session.id}/complete`, headers,
            });
            expect(completed.statusCode, completed.body).toBe(200);
            expect(completed.json().uploadSession.status).toBe('COMPLETED');
        } finally {
            await Promise.all(servers.map(server => server.close()));
            vi.unstubAllEnvs();
        }
    });

    it('persists an explicit Mux intent before upload and prevents an original session', async () => {
        const content = Buffer.from('new direct upload');
        const created = await requestAs(ownerId, 'POST', '/api/assets', {
            fileName: 'direct.mov', uploadMode: 'MUX',
        });
        expect(created.statusCode).toBe(200);
        const id = created.json().asset.id;
        expect(created.json().asset.uploadMode).toBe('MUX');
        expect(await prisma.asset.findUnique({ where: { id } })).toMatchObject({ uploadMode: 'MUX' });
        expect((await requestAs(ownerId, 'GET', `/api/assets/${id}`)).json().asset.uploadMode).toBe('MUX');
        expect((await requestAs(ownerId, 'GET', '/api/assets/mine')).json().assets
            .find(asset => asset.id === id).uploadMode).toBe('MUX');
        expect((await requestAs(ownerId, 'POST', `/api/assets/${id}/upload-sessions`, {
            expectedSizeBytes: content.length, expectedSha256: sha256(content),
        })).statusCode).toBe(409);
        expect((await requestAs(ownerId, 'POST', `/api/assets/${id}/mux-upload`, {})).statusCode).toBe(200);

        const legacy = await requestAs(ownerId, 'POST', '/api/assets', { fileName: 'legacy.mov' });
        expect(legacy.statusCode).toBe(200);
        expect(legacy.json().asset.uploadMode).toBe('UNKNOWN');
        expect((await requestAs(ownerId, 'POST', `/api/assets/${legacy.json().asset.id}/mux-upload`, {}))
            .statusCode).toBe(200);
    });

    it('creates an owner-scoped original asset idempotently and reserves it before a session exists', async () => {
        const clientRequestId = randomUUID();
        const content = Buffer.from('native original');
        const payload = {
            clientRequestId, fileName: 'native.mov',
            expectedSizeBytes: content.length, expectedSha256: sha256(content),
        };
        expect((await requestAs(null, 'POST', '/api/assets/original-uploads', payload)).statusCode).toBe(401);
        for (const invalid of [
            {},
            { ...payload, clientRequestId: 'not-a-uuid' },
            { ...payload, fileName: { name: 'native.mov' } },
            { ...payload, expectedSizeBytes: 0 },
            { ...payload, expectedSha256: 'not-a-hash' },
        ]) {
            expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', invalid)).statusCode).toBe(400);
        }

        const [first, retry] = await Promise.all([
            requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload),
            requestAs(ownerId, 'POST', '/api/assets/original-uploads', {
                ...payload, clientRequestId: clientRequestId.toUpperCase(),
                expectedSha256: payload.expectedSha256.toUpperCase(),
            }),
        ]);
        expect([first.statusCode, retry.statusCode].sort()).toEqual([200, 201]);
        const created = first.json().asset;
        expect(retry.json().asset.id).toBe(created.id);
        expect(created).toMatchObject({ uploadMode: 'ORIGINAL', originalFileName: 'native.mov', status: 'UPLOADING' });
        expect(await prisma.originalUploadIntent.count({ where: { userId: ownerId, clientRequestId } })).toBe(1);
        expect((await requestAs(ownerId, 'POST', `/api/assets/${created.id}/mux-upload`, {})).statusCode).toBe(409);

        const detail = await requestAs(ownerId, 'GET', `/api/assets/${created.id}`);
        const mine = await requestAs(ownerId, 'GET', '/api/assets/mine');
        expect(detail.json().asset.uploadMode).toBe('ORIGINAL');
        expect(mine.json().assets.find(asset => asset.id === created.id).uploadMode).toBe('ORIGINAL');
        expect(detail.body).not.toContain(clientRequestId);
        expect(detail.json().asset).not.toHaveProperty('originalIntentSizeBytes');
        expect(detail.json().asset).not.toHaveProperty('originalIntentSha256');
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', {
            ...payload, fileName: 'different.mov',
        })).statusCode).toBe(409);
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', {
            ...payload, expectedSizeBytes: content.length + 1,
        })).statusCode).toBe(409);
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', {
            ...payload, expectedSha256: sha256(Buffer.from('different original')),
        })).statusCode).toBe(409);
        const sessionUrl = `/api/assets/${created.id}/upload-sessions`;
        expect((await requestAs(ownerId, 'POST', sessionUrl, {
            expectedSizeBytes: content.length,
            expectedSha256: sha256(Buffer.from('different original')),
        })).statusCode).toBe(409);
        expect(await prisma.uploadSession.count({ where: { assetId: created.id } })).toBe(0);
        expect((await requestAs(ownerId, 'POST', sessionUrl, payload)).statusCode).toBe(201);

        const other = await requestAs(otherId, 'POST', '/api/assets/original-uploads', payload);
        expect(other.statusCode).toBe(201);
        expect(other.json().asset.id).not.toBe(created.id);
        expect((await requestAs(otherId, 'GET', `/api/assets/${created.id}`)).statusCode).toBe(404);
        const admin = await requestAs(adminId, 'POST', '/api/assets/original-uploads', payload);
        expect(admin.statusCode).toBe(201);
        expect(admin.json().asset.id).not.toBe(created.id);
        expect(await prisma.asset.findUnique({ where: { id: admin.json().asset.id } }))
            .toMatchObject({ userId: adminId, uploadMode: 'ORIGINAL' });
        const teamAdmin = await requestAs(teamAdminId, 'POST', '/api/assets/original-uploads', payload);
        expect(teamAdmin.statusCode).toBe(201);
        expect(teamAdmin.json().asset.id).not.toBe(created.id);
        expect(await prisma.asset.findUnique({ where: { id: teamAdmin.json().asset.id } }))
            .toMatchObject({ userId: teamAdminId, uploadMode: 'ORIGINAL' });
    });

    it('fences cancellation before reservation without creating an asset or affecting another owner', async () => {
        const payload = originalReservation(Buffer.from('cancel before reserve'));
        const cancelUrl = `/api/assets/original-uploads/${payload.clientRequestId}/cancel`;
        const originalUrl = '/api/assets/original-uploads';
        const assetsBefore = await prisma.asset.count({ where: { userId: ownerId } });

        expect((await requestAs(null, 'POST', cancelUrl)).statusCode).toBe(401);
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads/not-a-uuid/cancel')).statusCode).toBe(400);
        const cancelled = await requestAs(ownerId, 'POST', cancelUrl);
        expect(cancelled.statusCode, cancelled.body).toBe(200);
        expect(cancelled.json()).toEqual({ assetId: null, sessionIds: [] });
        const where = { userId_clientRequestId: { userId: ownerId, clientRequestId: payload.clientRequestId } };
        const intent = await prisma.originalUploadIntent.findUnique({ where });
        expect(intent.assetId).toBeNull();
        expect(intent.cancelledAt).toBeInstanceOf(Date);

        const retry = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId.toUpperCase()}/cancel`);
        expect(retry.statusCode, retry.body).toBe(200);
        expect(retry.json()).toEqual(cancelled.json());
        expect((await prisma.originalUploadIntent.findUnique({ where })).cancelledAt).toEqual(intent.cancelledAt);
        expect((await requestAs(ownerId, 'POST', originalUrl, payload)).statusCode).toBe(410);
        expect(await prisma.asset.count({ where: { userId: ownerId } })).toBe(assetsBefore);

        const otherOwner = await requestAs(otherId, 'POST', originalUrl, payload);
        expect(otherOwner.statusCode, otherOwner.body).toBe(201);
    });

    it('accepts a bodyless cancellation over HTTP without an empty JSON content type', async () => {
        const clientRequestId = randomUUID();
        const response = await fetch(`${address}/api/assets/original-uploads/${clientRequestId}/cancel`, {
            method: 'POST',
            headers: { authorization: `Bearer ${tokens[ownerId]}` },
        });
        expect(response.status).toBe(200);
        expect(await response.json()).toEqual({ assetId: null, sessionIds: [] });

        const invalidId = randomUUID();
        const invalid = await fetch(`${address}/api/assets/original-uploads/${invalidId}/cancel`, {
            method: 'POST',
            headers: { authorization: `Bearer ${tokens[ownerId]}`, 'content-type': 'application/json' },
        });
        expect(invalid.status).toBe(400);
        expect(await prisma.originalUploadIntent.findUnique({
            where: { userId_clientRequestId: { userId: ownerId, clientRequestId: invalidId } },
        })).toBeNull();
    });

    it('fences a reserved asset before a session can be created', async () => {
        const payload = originalReservation(Buffer.from('cancel before session'));
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const cancelUrl = `/api/assets/original-uploads/${payload.clientRequestId}/cancel`;

        const cancelled = await requestAs(ownerId, 'POST', cancelUrl);
        expect(cancelled.statusCode, cancelled.body).toBe(200);
        expect(cancelled.json()).toEqual({ assetId: reservedAssetId, sessionIds: [] });
        const createUpload = vi.spyOn(storage, 'createUpload');
        try {
            const session = await requestAs(ownerId, 'POST', `/api/assets/${reservedAssetId}/upload-sessions`, payload);
            expect(session.statusCode, session.body).toBe(410);
            const { createUploadSessionService } = await import('../lib/upload-sessions.js');
            const service = createUploadSessionService({
                db: prisma, storage, capacity: unrestrictedTestCapacity, now: () => new Date(currentTime),
            });
            for (const initializeClip of [true, false]) {
                await expect(service.create({
                    ownerId, assetId: reservedAssetId, clipId: randomUUID(), initializeClip,
                    expectedSizeBytes: payload.expectedSizeBytes, expectedSha256: payload.expectedSha256,
                })).rejects.toMatchObject({ code: 'INTENT_CANCELLED' });
            }
            expect(createUpload).not.toHaveBeenCalled();
            expect(await prisma.uploadSession.count({ where: { assetId: reservedAssetId } })).toBe(0);
        } finally {
            createUpload.mockRestore();
        }
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload)).statusCode).toBe(410);
    });

    it('returns existing sessions for explicit cleanup without creating or aborting them', async () => {
        const content = Buffer.from('cancel after session');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const session = await createSession(content, reservedAssetId);
        const cancelUrl = `/api/assets/original-uploads/${payload.clientRequestId}/cancel`;

        const cancelled = await requestAs(ownerId, 'POST', cancelUrl);
        expect(cancelled.statusCode, cancelled.body).toBe(200);
        expect(cancelled.json()).toEqual({ assetId: reservedAssetId, sessionIds: [session.id] });
        const retry = await requestAs(ownerId, 'POST', cancelUrl);
        expect(retry.statusCode, retry.body).toBe(200);
        expect(retry.json()).toEqual(cancelled.json());
        const blocked = await requestAs(ownerId, 'POST', `/api/assets/${reservedAssetId}/upload-sessions`, payload);
        expect(blocked.statusCode, blocked.body).toBe(410);
        expect(await prisma.uploadSession.count({ where: { assetId: reservedAssetId } })).toBe(1);
        const existing = await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`);
        expect(existing.statusCode, existing.body).toBe(200);
        expect(existing.json().uploadSession.status).toBe('OPEN');
        const aborted = await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${session.id}`);
        expect(aborted.statusCode, aborted.body).toBe(200);
    });

    it('does not resume a completed session after its intent is cancelled', async () => {
        const content = Buffer.from('completed before cancellation');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const session = await createSession(content, reservedAssetId);
        const signed = await sign(session.id);
        const uploaded = await put(signed.url, content, { 'content-length': String(content.length) });
        expect(uploaded.statusCode, uploaded.body).toBe(200);
        const completed = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
        expect(completed.statusCode, completed.body).toBe(200);

        const cancelled = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
        expect(cancelled.statusCode, cancelled.body).toBe(200);
        expect(cancelled.json()).toEqual({ assetId: reservedAssetId, sessionIds: [session.id] });
        const retry = await requestAs(ownerId, 'POST', `/api/assets/${reservedAssetId}/upload-sessions`, payload);
        expect(retry.statusCode, retry.body).toBe(410);
        const existing = await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`);
        expect(existing.statusCode, existing.body).toBe(200);
        expect(existing.json().uploadSession.status).toBe('COMPLETED');
    });

    it('fences hidden assets without revealing their asset or session IDs', async () => {
        for (const moderation of ['FLAGGED_FOR_REMOVAL', 'REMOVED']) {
            const content = Buffer.from('moderated original');
            const payload = originalReservation(content);
            const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
            expect(reserved.statusCode, reserved.body).toBe(201);
            const reservedAssetId = reserved.json().asset.id;
            const session = await createSession(content, reservedAssetId);
            await prisma.asset.update({ where: { id: reservedAssetId }, data: { moderation } });
            const cancelUrl = `/api/assets/original-uploads/${payload.clientRequestId}/cancel`;

            const hidden = await requestAs(ownerId, 'POST', cancelUrl);
            expect(hidden.statusCode, hidden.body).toBe(404);
            expect(hidden.body).not.toContain(reservedAssetId);
            expect(hidden.body).not.toContain(session.id);
            const intent = await prisma.originalUploadIntent.findUnique({
                where: { userId_clientRequestId: { userId: ownerId, clientRequestId: payload.clientRequestId } },
            });
            expect(intent.cancelledAt).toBeInstanceOf(Date);

            await prisma.asset.update({ where: { id: reservedAssetId }, data: { moderation: 'ACTIVE' } });
            const retry = await requestAs(ownerId, 'POST', cancelUrl);
            expect(retry.statusCode, retry.body).toBe(200);
            expect(retry.json()).toEqual({ assetId: reservedAssetId, sessionIds: [session.id] });
            const aborted = await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${session.id}`);
            expect(aborted.statusCode, aborted.body).toBe(200);
        }
    });

    it('preserves the fence without revealing inconsistent session IDs or ownership', async () => {
        const content = Buffer.from('inconsistent session ownership');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const session = await createSession(content, reservedAssetId);
        const otherSessionId = randomUUID();
        await prisma.uploadSession.create({
            data: {
                id: otherSessionId, ownerId: otherId, assetId: reservedAssetId, clipId: session.clipId,
                status: 'ABORTED', storageKey: `historical-${otherSessionId}`, expiresAt: new Date(),
            },
        });

        const cancelled = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
        expect(cancelled.statusCode, cancelled.body).toBe(503);
        for (const id of [reservedAssetId, session.id, otherSessionId]) {
            expect(cancelled.body).not.toContain(id);
        }
        const intent = await prisma.originalUploadIntent.findUnique({
            where: { userId_clientRequestId: { userId: ownerId, clientRequestId: payload.clientRequestId } },
        });
        expect(intent.cancelledAt).toBeInstanceOf(Date);
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload)).statusCode).toBe(410);

        await prisma.uploadSession.delete({ where: { id: otherSessionId } });
        const invalidId = `not-a-uuid-${randomUUID()}`;
        await prisma.uploadSession.create({
            data: {
                id: invalidId, ownerId, assetId: reservedAssetId, clipId: session.clipId,
                status: 'ABORTED', storageKey: `historical-${invalidId}`, expiresAt: new Date(),
            },
        });
        const invalid = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
        expect(invalid.statusCode, invalid.body).toBe(503);
        for (const id of [reservedAssetId, session.id, invalidId]) {
            expect(invalid.body).not.toContain(id);
        }
    });

    it('bounds unreserved cancellation admission per owner without expiring accepted fences', async () => {
        const quotaOwner = `upload-quota-${randomUUID()}`;
        await prisma.user.create({
            data: {
                id: quotaOwner, name: 'Upload Quota Test', phoneNumber: `upload-quota-${randomUUID()}`,
                pinHash: 'integration-test', role: 'USER',
            },
        });
        tokens[quotaOwner] = app.jwt.sign({ id: quotaOwner });
        uploadTransactionTimeZone = 'Pacific/Kiritimati';
        try {
            const reservedPayload = originalReservation(Buffer.from('existing reservation'));
            const reserved = await requestAs(quotaOwner, 'POST', '/api/assets/original-uploads', reservedPayload);
            expect(reserved.statusCode, reserved.body).toBe(201);
            const [{ epochMilliseconds }] = await prisma.$queryRaw`
                SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint AS "epochMilliseconds"`;
            const now = new Date(Number(epochMilliseconds));
            const oldId = randomUUID();
            const recentIds = Array.from({ length: 99 }, () => randomUUID());
            await prisma.originalUploadIntent.createMany({
                data: [
                    ...recentIds.map(clientRequestId => ({
                        userId: quotaOwner, clientRequestId,
                        cancelledAt: new Date(now.getTime() - 24 * 60 * 60 * 1000 + 60_000),
                    })),
                    {
                        userId: quotaOwner, clientRequestId: oldId,
                        cancelledAt: new Date(now.getTime() - 25 * 60 * 60 * 1000),
                    },
                ],
            });

            const concurrentIds = [randomUUID(), randomUUID()];
            const responses = await Promise.all(concurrentIds.map(id => requestAs(
                quotaOwner, 'POST', `/api/assets/original-uploads/${id}/cancel`)));
            expect(responses.map(response => response.statusCode).sort()).toEqual([200, 429]);
            const rejectedIndex = responses.findIndex(response => response.statusCode === 429);
            const rejected = responses[rejectedIndex];
            expect(rejected.json()).toMatchObject({ code: 'INTENT_CANCELLATION_QUOTA' });
            expect(Number(rejected.headers['retry-after'])).toBeGreaterThan(0);
            expect(Number(rejected.headers['retry-after'])).toBeLessThanOrEqual(60);
            expect(await prisma.originalUploadIntent.findUnique({
                where: { userId_clientRequestId: { userId: quotaOwner, clientRequestId: concurrentIds[rejectedIndex] } },
            })).toBeNull();

            const acceptedId = concurrentIds[1 - rejectedIndex];
            const acceptedIntent = await prisma.originalUploadIntent.findUnique({
                where: { userId_clientRequestId: { userId: quotaOwner, clientRequestId: acceptedId } },
            });
            const [{ observedEpoch }] = await prisma.$queryRaw`
                SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint AS "observedEpoch"`;
            expect(Math.abs(acceptedIntent.cancelledAt.getTime() - Number(observedEpoch))).toBeLessThan(5_000);
            uploadTransactionTimeZone = 'America/Los_Angeles';
            expect((await requestAs(
                quotaOwner, 'POST', `/api/assets/original-uploads/${acceptedId}/cancel`)).statusCode).toBe(200);
            expect((await requestAs(
                quotaOwner, 'POST', `/api/assets/original-uploads/${oldId}/cancel`)).statusCode).toBe(200);
            const existing = await requestAs(
                quotaOwner, 'POST', `/api/assets/original-uploads/${reservedPayload.clientRequestId}/cancel`);
            expect(existing.statusCode, existing.body).toBe(200);
            expect(existing.json().assetId).toBe(reserved.json().asset.id);
            const anotherOwner = await requestAs(
                otherId, 'POST', `/api/assets/original-uploads/${randomUUID()}/cancel`);
            expect(anotherOwner.statusCode, anotherOwner.body).toBe(200);

            await prisma.originalUploadIntent.updateMany({
                where: { userId: quotaOwner, clientRequestId: { in: recentIds } },
                data: { cancelledAt: new Date(now.getTime() - 25 * 60 * 60 * 1000) },
            });
            const retry = await requestAs(
                quotaOwner, 'POST', `/api/assets/original-uploads/${concurrentIds[rejectedIndex]}/cancel`);
            expect(retry.statusCode, retry.body).toBe(200);
            const oldPayload = { ...originalReservation(Buffer.from('old fence')), clientRequestId: oldId };
            expect((await requestAs(quotaOwner, 'POST', '/api/assets/original-uploads', oldPayload)).statusCode).toBe(410);
        } finally {
            uploadTransactionTimeZone = undefined;
            delete tokens[quotaOwner];
            await prisma.asset.deleteMany({ where: { userId: quotaOwner } });
            await prisma.user.delete({ where: { id: quotaOwner } });
        }
    });

    it('returns the complete session list at the limit and commits a fence on overflow', async () => {
        for (const count of [100, 101]) {
            const content = Buffer.from(`historical sessions ${count}`);
            const payload = originalReservation(content);
            const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
            expect(reserved.statusCode, reserved.body).toBe(201);
            const reservedAssetId = reserved.json().asset.id;
            const session = await createSession(content, reservedAssetId);
            const historicalIds = Array.from({ length: count - 1 }, () => randomUUID());
            await prisma.uploadSession.createMany({
                data: historicalIds.map(id => ({
                    id, ownerId, assetId: reservedAssetId, clipId: session.clipId,
                    status: 'ABORTED', storageKey: `historical-${id}`, expiresAt: new Date(),
                })),
            });
            const cancelled = await requestAs(
                ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
            if (count === 100) {
                expect(cancelled.statusCode, cancelled.body).toBe(200);
                expect(cancelled.json()).toEqual({
                    assetId: reservedAssetId, sessionIds: [session.id, ...historicalIds].sort(),
                });
            } else {
                expect(cancelled.statusCode, cancelled.body).toBe(503);
                expect(cancelled.json()).toMatchObject({ code: 'INTENT_SESSION_LIMIT' });
                expect(cancelled.body).not.toContain(reservedAssetId);
                expect(cancelled.body).not.toContain(session.id);
            }
            const intent = await prisma.originalUploadIntent.findUnique({
                where: { userId_clientRequestId: { userId: ownerId, clientRequestId: payload.clientRequestId } },
            });
            expect(intent.cancelledAt).toBeInstanceOf(Date);
            expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload)).statusCode).toBe(410);
            expect((await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${session.id}`)).statusCode).toBe(200);
        }
    });

    it('pages only fenced, owner-visible sessions without creating or changing work', async () => {
        const content = Buffer.from('paged cancellation history');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const session = await createSession(content, reservedAssetId);
        const historicalIds = Array.from({ length: 204 }, () => randomUUID());
        await prisma.uploadSession.createMany({
            data: historicalIds.map(id => ({
                id, ownerId, assetId: reservedAssetId, clipId: session.clipId,
                status: 'ABORTED', storageKey: `historical-${id}`, expiresAt: new Date(),
            })),
        });
        const url = `/api/assets/original-uploads/${payload.clientRequestId}/sessions`;
        const unfenced = await requestAs(ownerId, 'GET', url);
        expect(unfenced.statusCode, unfenced.body).toBe(404);
        expect(unfenced.body).not.toContain(reservedAssetId);
        expect((await requestAs(null, 'GET', url)).statusCode).toBe(401);
        const foreign = await requestAs(otherId, 'GET', url);
        expect(foreign.statusCode).toBe(404);
        expect(foreign.body).not.toContain(reservedAssetId);
        expect(foreign.body).not.toContain(session.id);

        const cancelled = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
        expect(cancelled.statusCode, cancelled.body).toBe(503);
        expect(cancelled.json()).toMatchObject({ code: 'INTENT_SESSION_LIMIT' });
        const before = await prisma.uploadSession.findMany({
            where: { assetId: reservedAssetId },
            select: { id: true, ownerId: true, status: true, storageKey: true },
            orderBy: { id: 'asc' },
        });
        const received = [];
        const lengths = [];
        let cursor;
        do {
            const response = await requestAs(ownerId, 'GET', cursor ? `${url}?after=${cursor}` : url);
            expect(response.statusCode, response.body).toBe(200);
            expect(response.headers['cache-control']).toBe('no-store');
            const page = response.json();
            expect(page.assetId).toBe(reservedAssetId);
            expect(page.sessionIds.length).toBeLessThanOrEqual(100);
            if (page.nextCursor) expect(page.nextCursor).toBe(page.sessionIds.at(-1));
            lengths.push(page.sessionIds.length);
            expect(lengths.length).toBeLessThanOrEqual(3);
            received.push(...page.sessionIds);
            cursor = page.nextCursor;
        } while (cursor);
        expect(lengths).toEqual([100, 100, 5]);
        expect(received).toEqual([session.id, ...historicalIds].sort());
        expect(await prisma.uploadSession.findMany({
            where: { assetId: reservedAssetId },
            select: { id: true, ownerId: true, status: true, storageKey: true },
            orderBy: { id: 'asc' },
        })).toEqual(before);
        expect((await requestAs(otherId, 'GET', url)).statusCode).toBe(404);

        const invalidId = `not-a-uuid-${randomUUID()}`;
        await prisma.uploadSession.create({
            data: {
                id: invalidId, ownerId, assetId: reservedAssetId, clipId: session.clipId,
                status: 'ABORTED', storageKey: `historical-${invalidId}`, expiresAt: new Date(),
            },
        });
        const invalidSession = await requestAs(ownerId, 'GET', `${url}?after=${received.at(-1)}`);
        expect(invalidSession.statusCode, invalidSession.body).toBe(503);
        expect(invalidSession.body).not.toContain(invalidId);
        await prisma.uploadSession.delete({ where: { id: invalidId } });

        for (const query of ['?after=invalid', `?after=${randomUUID()}&after=${randomUUID()}`, '?extra=1']) {
            expect((await requestAs(ownerId, 'GET', `${url}${query}`)).statusCode).toBe(400);
        }
        await prisma.asset.update({ where: { id: reservedAssetId }, data: { moderation: 'FLAGGED_FOR_REMOVAL' } });
        const hidden = await requestAs(ownerId, 'GET', url);
        expect(hidden.statusCode, hidden.body).toBe(404);
        expect(hidden.body).not.toContain(reservedAssetId);
        expect(hidden.body).not.toContain(session.id);
        await prisma.asset.update({ where: { id: reservedAssetId }, data: { moderation: 'ACTIVE' } });

        await prisma.uploadSession.update({ where: { id: received[0] }, data: { ownerId: otherId } });
        const inconsistent = await requestAs(ownerId, 'GET', url);
        expect(inconsistent.statusCode, inconsistent.body).toBe(503);
        expect(inconsistent.body).not.toContain(reservedAssetId);
        expect(inconsistent.body).not.toContain(received[0]);

        await prisma.asset.delete({ where: { id: reservedAssetId } });
        const disappeared = await requestAs(ownerId, 'GET', `${url}?after=${received[99]}`);
        expect(disappeared.statusCode, disappeared.body).toBe(503);
        expect(disappeared.body).not.toContain(reservedAssetId);
        expect(disappeared.body).not.toContain(session.id);
        const afterDeletion = await requestAs(ownerId, 'GET', url);
        expect(afterDeletion.statusCode, afterDeletion.body).toBe(200);
        expect(afterDeletion.json()).toEqual({ assetId: null, sessionIds: [], nextCursor: null });
    });

    it('enumerates a fenced intent without an asset as an empty page', async () => {
        const id = randomUUID();
        const cancel = await requestAs(ownerId, 'POST', `/api/assets/original-uploads/${id}/cancel`);
        expect(cancel.statusCode, cancel.body).toBe(200);
        const response = await requestAs(ownerId, 'GET', `/api/assets/original-uploads/${id}/sessions`);
        expect(response.statusCode, response.body).toBe(200);
        expect(response.json()).toEqual({ assetId: null, sessionIds: [], nextCursor: null });
    });

    it('fails a cursor continuation if asset deletion wins the row lock', async () => {
        const content = Buffer.from('paged deletion race');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const session = await createSession(content, reservedAssetId);
        await prisma.uploadSession.createMany({
            data: Array.from({ length: 100 }, () => {
                const id = randomUUID();
                return {
                    id, ownerId, assetId: reservedAssetId, clipId: session.clipId,
                    status: 'ABORTED', storageKey: `historical-${id}`, expiresAt: new Date(),
                };
            }),
        });
        const cancel = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
        expect(cancel.statusCode, cancel.body).toBe(503);
        const url = `/api/assets/original-uploads/${payload.clientRequestId}/sessions`;
        const firstPage = await requestAs(ownerId, 'GET', url);
        expect(firstPage.statusCode, firstPage.body).toBe(200);
        const cursor = firstPage.json().nextCursor;
        expect(cursor).toBeTruthy();

        let reportLocked;
        let releaseDeletion;
        const locked = new Promise(resolve => { reportLocked = resolve; });
        const release = new Promise(resolve => { releaseDeletion = resolve; });
        const deletion = prisma.$transaction(async tx => {
            const [backend] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
            await tx.asset.delete({ where: { id: reservedAssetId } });
            reportLocked(backend.pid);
            await release;
        }, { timeout: 15_000 });
        let continuation;
        let response;
        try {
            const pid = await Promise.race([
                locked,
                deletion.then(() => { throw new Error('Asset deletion did not pause'); }),
            ]);
            continuation = requestAs(ownerId, 'GET', `${url}?after=${cursor}`);
            await waitForBlockedBy(pid);
        } finally {
            releaseDeletion();
            await deletion;
            if (continuation) response = await continuation;
        }
        expect(response.statusCode, response.body).toBe(503);
        for (const id of [reservedAssetId, session.id, cursor]) {
            expect(response.body).not.toContain(id);
        }
    }, 15_000);

    it('serializes cancellation with concurrent reservation and session creation', async () => {
        const first = originalReservation(Buffer.from('concurrent reservation'));
        const [reservation, firstCancellation] = await Promise.all([
            requestAs(ownerId, 'POST', '/api/assets/original-uploads', first),
            requestAs(ownerId, 'POST', `/api/assets/original-uploads/${first.clientRequestId}/cancel`),
        ]);
        expect([201, 410]).toContain(reservation.statusCode);
        expect(firstCancellation.statusCode, firstCancellation.body).toBe(200);
        expect(firstCancellation.json()).toEqual({
            assetId: reservation.statusCode === 201 ? reservation.json().asset.id : null,
            sessionIds: [],
        });
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', first)).statusCode).toBe(410);

        const second = originalReservation(Buffer.from('concurrent session'));
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', second);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const [session, secondCancellation] = await Promise.all([
            requestAs(ownerId, 'POST', `/api/assets/${reservedAssetId}/upload-sessions`, second),
            requestAs(ownerId, 'POST', `/api/assets/original-uploads/${second.clientRequestId}/cancel`),
        ]);
        expect([201, 410]).toContain(session.statusCode);
        expect(secondCancellation.statusCode, secondCancellation.body).toBe(200);
        const sessions = await prisma.uploadSession.findMany({
            where: { assetId: reservedAssetId }, select: { id: true }, orderBy: { id: 'asc' },
        });
        expect(sessions).toHaveLength(session.statusCode === 201 ? 1 : 0);
        expect(secondCancellation.json()).toEqual({
            assetId: reservedAssetId, sessionIds: sessions.map(item => item.id),
        });
        const retry = await requestAs(ownerId, 'POST', `/api/assets/${reservedAssetId}/upload-sessions`, second);
        expect(retry.statusCode, retry.body).toBe(410);
    });

    it('rechecks the intent after concurrent asset deletion', async () => {
        for (const alreadyCancelled of [false, true]) {
            const payload = originalReservation(Buffer.from('concurrent asset deletion'));
            const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
            expect(reserved.statusCode, reserved.body).toBe(201);
            const reservedAssetId = reserved.json().asset.id;
            const cancelUrl = `/api/assets/original-uploads/${payload.clientRequestId}/cancel`;
            if (alreadyCancelled) {
                expect((await requestAs(ownerId, 'POST', cancelUrl)).statusCode).toBe(200);
            }

            let reportLocked;
            let releaseDeletion;
            const locked = new Promise(resolve => { reportLocked = resolve; });
            const release = new Promise(resolve => { releaseDeletion = resolve; });
            const deletion = prisma.$transaction(async tx => {
                const [backend] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
                await tx.asset.delete({ where: { id: reservedAssetId } });
                reportLocked(backend.pid);
                await release;
            }, { timeout: 15_000 });
            let cancellation;
            let enumeration;
            try {
                const pid = await Promise.race([
                    locked,
                    deletion.then(() => { throw new Error('Asset deletion did not pause'); }),
                ]);
                cancellation = requestAs(ownerId, 'POST', cancelUrl);
                if (alreadyCancelled) {
                    enumeration = requestAs(
                        ownerId, 'GET', `/api/assets/original-uploads/${payload.clientRequestId}/sessions`);
                }
                await waitForBlockedBy(pid);
                releaseDeletion();
                const response = await cancellation;
                expect(response.statusCode, response.body).toBe(alreadyCancelled ? 200 : 410);
                if (alreadyCancelled) {
                    expect(response.json()).toEqual({ assetId: null, sessionIds: [] });
                    const page = await enumeration;
                    expect(page.statusCode, page.body).toBe(200);
                    expect(page.json()).toEqual({ assetId: null, sessionIds: [], nextCursor: null });
                }
            } finally {
                releaseDeletion();
                await deletion;
                if (cancellation) await cancellation;
                if (enumeration) await enumeration;
            }
        }
    }, 15_000);

    it('rechecks cancellation if an intent appears while waiting for the asset lock', async () => {
        const payload = originalReservation(Buffer.from('concurrent intent creation'));
        const clipId = randomUUID();
        await prisma.clip.create({ data: { id: clipId, assetId, status: 'UPLOADING' } });
        const { createUploadSessionService } = await import('../lib/upload-sessions.js');
        const service = createUploadSessionService({
            db: prisma, storage, capacity: unrestrictedTestCapacity, now: () => new Date(currentTime),
        });
        let reportLocked;
        let releaseIntent;
        const locked = new Promise(resolve => { reportLocked = resolve; });
        const release = new Promise(resolve => { releaseIntent = resolve; });
        const intentCreation = prisma.$transaction(async tx => {
            const [backend] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
            await tx.$queryRaw`SELECT id FROM assets WHERE id = ${assetId} FOR UPDATE`;
            reportLocked(backend.pid);
            await release;
            await tx.originalUploadIntent.create({
                data: { userId: ownerId, clientRequestId: payload.clientRequestId, assetId, cancelledAt: new Date() },
            });
        }, { timeout: 15_000 });
        const createUpload = vi.spyOn(storage, 'createUpload');
        let attempt;
        try {
            const pid = await Promise.race([
                locked,
                intentCreation.then(() => { throw new Error('Intent creation did not pause'); }),
            ]);
            attempt = service.create({
                ownerId, assetId, clipId, expectedSizeBytes: payload.expectedSizeBytes,
                expectedSha256: payload.expectedSha256,
            }).then(value => ({ value }), error => ({ error }));
            await waitForBlockedBy(pid);
            releaseIntent();
            const result = await attempt;
            expect(result.error).toMatchObject({ code: 'INTENT_CANCELLED' });
            expect(result.value).toBeUndefined();
            expect(createUpload).not.toHaveBeenCalled();
        } finally {
            releaseIntent();
            try {
                await intentCreation;
                if (attempt) await attempt;
            } finally {
                createUpload.mockRestore();
            }
        }
    }, 15_000);

    it('does not create an original intent for a suspended account', async () => {
        await prisma.user.update({ where: { id: ownerId }, data: { status: 'SUSPENDED' } });
        const clientRequestId = randomUUID();
        const response = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', {
            clientRequestId, fileName: 'suspended.mov', expectedSizeBytes: 1, expectedSha256: sha256(Buffer.from('a')),
        });
        expect(response.statusCode).toBe(403);
        expect(await prisma.originalUploadIntent.count({ where: { userId: ownerId, clientRequestId } })).toBe(0);
    });

    it('reports contradictory modes even when a Mux clip is not the latest archive clip', async () => {
        await prisma.asset.update({ where: { id: assetId }, data: { uploadMode: 'ORIGINAL' } });
        await prisma.clip.create({
            data: { assetId, muxUploadId: 'older-mux-upload', createdAt: new Date('2026-01-01T00:00:00Z') },
        });
        await prisma.clip.create({
            data: { assetId, createdAt: new Date('2026-02-01T00:00:00Z') },
        });
        const detail = (await requestAs(ownerId, 'GET', `/api/assets/${assetId}`)).json().asset;
        const mine = (await requestAs(ownerId, 'GET', '/api/assets/mine')).json().assets.find(asset => asset.id === assetId);
        expect(detail.uploadMode).toBe('UNKNOWN');
        expect(mine.uploadMode).toBe('UNKNOWN');
        expect(mine.clips).toHaveLength(1);
        expect(mine).not.toHaveProperty('_count');
        const content = Buffer.from('new original');
        const response = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
            expectedSizeBytes: content.length, expectedSha256: sha256(content),
        });
        expect(response.statusCode).toBe(409);
        expect(await prisma.uploadSession.count({ where: { assetId } })).toBe(0);
    });

    it('reports contradictory modes when a retained original is not the latest archive clip', async () => {
        await prisma.clip.create({
            data: {
                assetId,
                storageKey: 'older-retained-original',
                storageDriver: 'local',
                sha256: sha256(Buffer.from('older original')),
                createdAt: new Date('2026-01-01T00:00:00Z'),
            },
        });
        await prisma.clip.create({
            data: { assetId, muxUploadId: 'newer-mux-upload', createdAt: new Date('2026-02-01T00:00:00Z') },
        });
        const detail = (await requestAs(ownerId, 'GET', `/api/assets/${assetId}`)).json().asset;
        const mine = (await requestAs(ownerId, 'GET', '/api/assets/mine')).json().assets.find(asset => asset.id === assetId);
        expect(detail.uploadMode).toBe('UNKNOWN');
        expect(mine.uploadMode).toBe('UNKNOWN');
        expect(mine.clips).toHaveLength(1);
        expect((await requestAs(ownerId, 'POST', `/api/assets/${assetId}/mux-upload`, {})).statusCode).toBe(409);
    });

    it('retains a tombstone after asset deletion and does not recreate a removed upload', async () => {
        const payload = {
            clientRequestId: randomUUID(), fileName: 'removed.mov',
            expectedSizeBytes: 1, expectedSha256: sha256(Buffer.from('a')),
        };
        const created = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(created.statusCode).toBe(201);
        await prisma.asset.delete({ where: { id: created.json().asset.id } });
        await prisma.asset.delete({ where: { id: assetId } });
        const reset = await requestAs(adminId, 'POST', '/api/admin/nuclear-reset', {});
        expect(reset.statusCode, reset.body).toBe(200);

        const retry = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(retry.statusCode).toBe(410);
        const cancellation = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
        expect(cancellation.statusCode).toBe(410);
        const intent = await prisma.originalUploadIntent.findUnique({
            where: { userId_clientRequestId: { userId: ownerId, clientRequestId: payload.clientRequestId } },
        });
        expect(intent.assetId).toBeNull();
        expect(intent.cancelledAt).toBeNull();
        expect(Object.keys(intent).sort()).toEqual(['assetId', 'cancelledAt', 'clientRequestId', 'createdAt', 'userId']);
    });

    it('removes the nonsecret upload tombstone when its owner is deleted', async () => {
        const deletedOwner = `deleted-upload-owner-${randomUUID()}`;
        const payload = {
            clientRequestId: randomUUID(), fileName: 'removed.mov',
            expectedSizeBytes: 1, expectedSha256: sha256(Buffer.from('a')),
        };
        try {
            await prisma.user.create({
                data: {
                    id: deletedOwner,
                    name: 'Deleted Upload Owner',
                    phoneNumber: `upload-route-${randomUUID()}`,
                    pinHash: 'integration-test',
                },
            });
            tokens[deletedOwner] = app.jwt.sign({ id: deletedOwner });
            const created = await requestAs(deletedOwner, 'POST', '/api/assets/original-uploads', payload);
            expect(created.statusCode, created.body).toBe(201);
            await prisma.asset.delete({ where: { id: created.json().asset.id } });
            expect(await prisma.originalUploadIntent.count({ where: { userId: deletedOwner } })).toBe(1);
            await prisma.user.delete({ where: { id: deletedOwner } });
            expect(await prisma.originalUploadIntent.count({ where: { userId: deletedOwner } })).toBe(0);
        } finally {
            await prisma.asset.deleteMany({ where: { userId: deletedOwner } });
            await prisma.user.deleteMany({ where: { id: deletedOwner } });
            delete tokens[deletedOwner];
        }
    });

    it('persists original metadata and emits the existing owner form events only once', async () => {
        const content = Buffer.from('metadata original');
        const metadata = {
            gpsLat: 40.7, gpsLon: -74, gpsAltitude: 15,
            capturedAt: '2026-11-10T12:34:56.000Z',
            deviceModel: 'Test iPhone', osVersion: 'iOS test',
            codec: 'HEVC', resolution: '1920x1080', orientation: 'landscape', duration: 42,
        };
        const payload = { expectedSizeBytes: content.length, expectedSha256: sha256(content), metadata };
        const url = `/api/assets/${assetId}/upload-sessions`;
        const response = await requestAs(ownerId, 'POST', url, payload);
        expect(response.statusCode, response.body).toBe(201);
        const session = response.json().uploadSession;
        const clip = await prisma.clip.findUnique({ where: { id: session.clipId } });
        expect(clip).toMatchObject({
            ...metadata, capturedAt: new Date(metadata.capturedAt), fileSize: null, status: 'UPLOADING',
        });
        expect(await prisma.asset.findUnique({ where: { id: assetId } }))
            .toMatchObject({ uploadMode: 'ORIGINAL', clipCount: 1, totalDuration: 42 });
        expect(socketTo).toHaveBeenCalledWith(`user:${ownerId}`);
        expect(socketEmit).toHaveBeenCalledTimes(2);
        expect(socketEmit).toHaveBeenCalledWith('upload:complete', expect.objectContaining({
            assetId, metadata: expect.objectContaining({ gpsLat: 40.7, duration: 42 }),
            clip: expect.objectContaining({ id: session.clipId, fileSize: String(content.length) }),
        }));
        expect(socketEmit).toHaveBeenCalledWith('form:request', expect.objectContaining({ assetId, duration: 42 }));

        const retry = await requestAs(ownerId, 'POST', url, payload);
        expect(retry.statusCode).toBe(200);
        expect(retry.json().uploadSession.id).toBe(session.id);
        expect(socketEmit).toHaveBeenCalledTimes(2);
        const conflicting = await requestAs(ownerId, 'POST', url, {
            ...payload, metadata: { ...metadata, duration: 43 },
        });
        expect(conflicting.statusCode).toBe(409);
        expect(socketEmit).toHaveBeenCalledTimes(2);
        expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject({ duration: 42 });
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject({
            fileSize: BigInt(content.length), duration: 42, resolution: '1920x1080',
        });
    });

    it('rejects invalid metadata before creating a clip or sending notifications', async () => {
        const content = Buffer.from('invalid metadata');
        const base = { expectedSizeBytes: content.length, expectedSha256: sha256(content) };
        for (const metadata of [
            [],
            { capturedAt: 'not-a-date' },
            { duration: -1 },
            { duration: 'not-a-number' },
            { duration: '12 seconds' },
            { duration: -0.5 },
            { gpsLat: 91 },
            { gpsLat: '1north' },
            { gpsLon: -181 },
            { gpsLon: '0x10' },
            { deviceModel: { unexpected: true } },
        ]) {
            const response = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
                ...base, metadata,
            });
            expect(response.statusCode, response.body).toBe(400);
        }
        expect(await prisma.clip.count({ where: { assetId } })).toBe(0);
        expect(await prisma.uploadSession.count({ where: { assetId } })).toBe(0);
        expect(socketEmit).not.toHaveBeenCalled();
    });

    it('persists the same default metadata that is sent in form events', async () => {
        const session = await createSession(Buffer.from('default metadata'));
        const clip = await prisma.clip.findUnique({ where: { id: session.clipId } });
        const formRequest = socketEmit.mock.calls.find(([event]) => event === 'form:request')[1];
        expect(clip).toMatchObject({
            capturedAt: formRequest.capturedAt,
            deviceModel: 'Unknown Device',
            osVersion: 'Unknown OS',
            codec: 'Unknown',
            resolution: 'Unknown',
            orientation: 'landscape',
            duration: 0,
        });
    });

    it('preserves zero-valued location metadata on initial creation and retry', async () => {
        const content = Buffer.from('equator');
        const payload = {
            expectedSizeBytes: content.length,
            expectedSha256: sha256(content),
            metadata: { gpsLat: 0, gpsLon: 0, gpsAltitude: 0, duration: 0 },
        };
        const url = `/api/assets/${assetId}/upload-sessions`;
        const created = await requestAs(ownerId, 'POST', url, payload);
        expect(created.statusCode, created.body).toBe(201);
        expect(await prisma.clip.findUnique({ where: { id: created.json().uploadSession.clipId } }))
            .toMatchObject({ gpsLat: 0, gpsLon: 0, gpsAltitude: 0, duration: 0 });
        const retry = await requestAs(ownerId, 'POST', url, payload);
        expect(retry.statusCode, retry.body).toBe(200);
    });

    it('discovers legacy original mode without exposing session records', async () => {
        const session = await createSession(Buffer.from('legacy original'));
        await prisma.asset.update({ where: { id: assetId }, data: { uploadMode: null } });
        const detail = await requestAs(ownerId, 'GET', `/api/assets/${assetId}`);
        expect(detail.statusCode).toBe(200);
        expect(detail.json().asset.uploadMode).toBe('ORIGINAL');
        expect(detail.json().asset).not.toHaveProperty('uploadSessions');
        expect(detail.body).not.toContain(session.id);
        expect((await requestAs(ownerId, 'POST', `/api/assets/${assetId}/mux-upload`, {})).statusCode).toBe(409);

        await prisma.asset.update({ where: { id: assetId }, data: { uploadMode: 'MUX' } });
        expect((await requestAs(ownerId, 'GET', `/api/assets/${assetId}`)).json().asset.uploadMode).toBe('UNKNOWN');
        const retry = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
            expectedSizeBytes: session.expectedSizeBytes, expectedSha256: session.expectedSha256,
        });
        expect(retry.statusCode).toBe(409);
    });

    it('prefers active or completed sessions over an aborted session with the same timestamp', async () => {
        const content = Buffer.from('same timestamp');
        const first = await createSession(content);
        expect((await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${first.id}`)).statusCode).toBe(200);
        await prisma.uploadSession.update({
            where: { id: first.id },
            data: { id: 'ffffffff-ffff-4fff-bfff-ffffffffffff' },
        });
        const url = `/api/assets/${assetId}/upload-sessions`;
        const payload = { expectedSizeBytes: content.length, expectedSha256: sha256(content) };
        const replacement = await requestAs(ownerId, 'POST', url, payload);
        expect(replacement.statusCode, replacement.body).toBe(201);
        const retry = await requestAs(ownerId, 'POST', url, payload);
        expect(retry.statusCode, retry.body).toBe(200);
        expect(retry.json().uploadSession.id).toBe(replacement.json().uploadSession.id);
        const signed = await sign(replacement.json().uploadSession.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${replacement.json().uploadSession.id}/complete`))
            .statusCode).toBe(200);
        const completed = await requestAs(ownerId, 'POST', url, payload);
        expect(completed.statusCode, completed.body).toBe(200);
        expect(completed.json().uploadSession).toMatchObject({
            id: replacement.json().uploadSession.id, status: 'COMPLETED',
        });
    });

    it('does not guess between multiple recoverable sessions on an inconsistent asset', async () => {
        const content = Buffer.from('ambiguous session');
        await createSession(content);
        const otherClip = await prisma.clip.create({ data: { assetId } });
        await prisma.uploadSession.create({
            data: {
                id: randomUUID(), ownerId, assetId, clipId: otherClip.id,
                storageKey: `unverified-${randomUUID()}`, expectedSizeBytes: BigInt(content.length),
                expectedSha256: sha256(content), expiresAt: new Date(currentTime + 60_000),
            },
        });
        const response = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
            expectedSizeBytes: content.length, expectedSha256: sha256(content),
        });
        expect(response.statusCode).toBe(409);
        expect(response.json().error).toContain('multiple recoverable original sessions');
        expect(await prisma.uploadSession.count({ where: { assetId } })).toBe(2);
    });

    it('creates, resumes, retries, and completes an owner-only session idempotently', async () => {
        const content = Buffer.from('native original');
        const session = await createSession(content);
        expect(session).toMatchObject({
            assetId, status: 'OPEN', expectedSizeBytes: String(content.length),
            expectedSha256: sha256(content), partSizeBytes: MAX_PART_SIZE_BYTES, partCount: 1, parts: [],
        });
        expect(session).not.toHaveProperty('storageKey');
        expect(await prisma.asset.findUnique({ where: { id: assetId } })).toMatchObject({ clipCount: 1 });
        expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject({ status: 'UPLOADING' });

        const retry = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
            expectedSizeBytes: String(content.length), expectedSha256: sha256(content).toUpperCase(),
        });
        expect(retry.statusCode).toBe(200);
        expect(retry.json().uploadSession.id).toBe(session.id);
        expect((await requestAs(otherId, 'GET', `/api/upload-sessions/${session.id}`)).statusCode).toBe(404);
        expect((await requestAs(otherId, 'POST', `/api/upload-sessions/${session.id}/parts/1/sign`)).statusCode).toBe(404);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(409);

        const signed = await sign(session.id);
        expect(signed).toMatchObject({ partNumber: 1, sizeBytes: content.length });
        const uploaded = await put(signed.url, content);
        expect(uploaded.statusCode, uploaded.body).toBe(200);
        expect(uploaded.json().part).toMatchObject({ partNumber: 1, sizeBytes: String(content.length), sha256: sha256(content) });
        expect((await put(signed.url, content)).statusCode).toBe(200);
        expect((await put(signed.url, Buffer.alloc(content.length, 0x78))).statusCode).toBe(409);
        const resumed = await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`);
        expect(resumed.json().uploadSession.parts).toMatchObject([{ partNumber: 1, sizeBytes: String(content.length) }]);

        const complete = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
        expect(complete.statusCode, complete.body).toBe(200);
        expect(complete.json().uploadSession.status).toBe('COMPLETED');
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${session.id}`)).statusCode).toBe(409);
        const duplicate = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
            expectedSizeBytes: content.length, expectedSha256: sha256(content),
        });
        expect(duplicate.statusCode).toBe(200);
        expect(duplicate.json().uploadSession.id).toBe(session.id);
        for (const status of ['PROCESSING', 'READY', 'ERROR']) {
            await prisma.asset.update({ where: { id: assetId }, data: { status } });
            const recovered = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
                expectedSizeBytes: content.length, expectedSha256: sha256(content),
            });
            expect(recovered.statusCode, recovered.body).toBe(200);
            expect(recovered.json().uploadSession).toMatchObject({ id: session.id, status: 'COMPLETED' });
        }
        expect((await put(signed.url, content)).statusCode).toBe(403);

        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        const clip = await prisma.clip.findUnique({ where: { id: session.clipId } });
        expect(clip).toMatchObject({ storageKey: row.storageKey, sha256: sha256(content), fileSize: BigInt(content.length) });
        expect(await storage.stat(row.storageKey)).toMatchObject({ sizeBytes: String(content.length) });
    });

    it('validates input and rejects cross-owner, tampered, expired, suspended, and moderated capabilities', async () => {
        const content = Buffer.from('signed bytes');
        const payload = { expectedSizeBytes: content.length, expectedSha256: sha256(content) };
        expect((await requestAs(null, 'POST', `/api/assets/${assetId}/upload-sessions`, payload)).statusCode).toBe(401);
        expect((await requestAs(otherId, 'POST', `/api/assets/${assetId}/upload-sessions`, payload)).statusCode).toBe(404);
        for (const invalid of [
            { ...payload, expectedSizeBytes: 0 },
            { ...payload, expectedSizeBytes: 500 * 1024 * 1024 + 1 },
            { ...payload, expectedSizeBytes: '1'.repeat(10000) },
            { ...payload, expectedSha256: 'bad' },
        ]) {
            expect((await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, invalid)).statusCode).toBe(400);
        }
        const session = await createSession(content);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/parts/2/sign`)).statusCode).toBe(400);
        const signed = await sign(session.id);
        expect(new Date(signed.expiresAt).getTime()).toBe(Math.floor((currentTime + 5 * 60 * 1000) / 1000) * 1000);
        const tampered = signed.url.replace(/signature=([0-9a-f])/, (_match, first) => `signature=${first === '0' ? '1' : '0'}`);
        expect((await put(tampered, content)).statusCode).toBe(403);
        expect((await put(signed.url.replace('/parts/1?', '/parts/2?'), content)).statusCode).toBe(403);

        const otherAssetId = randomUUID();
        await prisma.asset.create({ data: { id: otherAssetId, userId: otherId, status: 'UPLOADING' } });
        const other = await createSession(content, otherAssetId, otherId);
        expect((await put(signed.url.replace(session.id, other.id), content)).statusCode).toBe(403);
        await prisma.user.update({ where: { id: ownerId }, data: { status: 'SUSPENDED' } });
        expect((await put(signed.url, content)).statusCode).toBe(403);
        expect((await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`)).statusCode).toBe(403);
        await prisma.user.update({ where: { id: ownerId }, data: { status: 'ACTIVE' } });
        await prisma.asset.update({ where: { id: assetId }, data: { moderation: 'PAUSED' } });
        expect((await put(signed.url, content)).statusCode).toBe(403);
        expect((await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/parts/1/sign`)).statusCode).toBe(409);
        await prisma.asset.update({ where: { id: assetId }, data: { moderation: 'ACTIVE' } });
        currentTime += 5 * 60 * 1000;
        expect((await put(signed.url, content)).statusCode).toBe(403);
    });

    it('accepts the exact 500 MiB session limit and caps signed URLs at session expiry', async () => {
        const response = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
            expectedSizeBytes: 500 * 1024 * 1024,
            expectedSha256: 'a'.repeat(64),
        });
        expect(response.statusCode).toBe(201);
        const session = response.json().uploadSession;
        expect(session.partCount).toBe(10);
        currentTime = new Date(session.expiresAt).getTime() - 60 * 1000;
        const signed = await sign(session.id, 10);
        expect(signed.sizeBytes).toBe(MAX_PART_SIZE_BYTES);
        expect(new Date(signed.expiresAt).getTime()).toBe(Math.floor(new Date(session.expiresAt).getTime() / 1000) * 1000);
    });

    it('rejects invalid HTTP framing and accepts a streamed body larger than the normal Fastify limit', async () => {
        const content = Buffer.alloc(3 * 1024 * 1024 + 17, 0x61);
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, Buffer.from('short'))).statusCode).toBe(400);
        expect((await put(signed.url, Buffer.from('x'), { 'content-length': String(MAX_PART_SIZE_BYTES + 1) })).statusCode).toBe(413);
        expect((await put(signed.url, content, { 'content-type': 'text/plain' })).statusCode).toBe(415);
        const chunked = await sendHttp(signed.url, {
            'content-type': 'application/octet-stream', 'transfer-encoding': 'chunked',
        }, [Buffer.from('x')]);
        expect(chunked.status).toBe(411);

        const streamed = await sendHttp(signed.url, {
            'content-type': 'application/octet-stream', 'content-length': String(content.length),
        }, Array.from({ length: 49 }, (_, index) => content.subarray(index * 65536, (index + 1) * 65536)));
        expect(streamed.status, streamed.body).toBe(200);
        expect(JSON.parse(streamed.body).part).toMatchObject({ sizeBytes: String(content.length), sha256: sha256(content) });
    });

    it('cleans up an interrupted HTTP part and allows a retry', async () => {
        const content = Buffer.alloc(512 * 1024, 0x62);
        const session = await createSession(content);
        const signed = await sign(session.id);
        const partsDirectory = path.join(storageRoot, '.uploads', session.id, 'parts');
        const request = httpRequest(new URL(signed.url, address), {
            method: 'PUT',
            headers: { 'content-type': 'application/octet-stream', 'content-length': String(content.length) },
        });
        const closed = new Promise((resolve, reject) => {
            request.on('error', error => error.code === 'ECONNRESET' ? resolve() : reject(error));
            request.on('close', resolve);
        });
        request.write(content.subarray(0, 64 * 1024));
        await waitFor(async () => {
            const entries = await readdir(partsDirectory).catch(error => {
                if (error.code === 'ENOENT') return [];
                throw error;
            });
            return entries.some(name => name.startsWith('.partial-'));
        });
        request.destroy();
        await closed;
        await waitFor(async () => {
            const entries = await readdir(partsDirectory);
            return !entries.some(name => name.startsWith('.partial-') || name.startsWith('.part-'));
        });
        expect((await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`)).json().uploadSession.parts).toEqual([]);
        expect((await put(signed.url, content)).statusCode).toBe(200);
    });

    it.each([
        ['account suspension', 403, async () => prisma.user.update({
            where: { id: ownerId }, data: { status: 'SUSPENDED' },
        })],
        ['asset moderation', 409, async () => prisma.asset.update({
            where: { id: assetId }, data: { moderation: 'PAUSED' },
        })],
        ['session expiry', 410, async () => { currentTime += 24 * 60 * 60 * 1000 + 1; }],
    ])('does not publish an in-flight part after %s', async (_label, status, changeState) => {
        const content = Buffer.alloc(512 * 1024, 0x64);
        const session = await createSession(content);
        const signed = await sign(session.id);
        const partsDirectory = path.join(storageRoot, '.uploads', session.id, 'parts');
        let request;
        const response = new Promise((resolve, reject) => {
            request = httpRequest(new URL(signed.url, address), {
                method: 'PUT',
                headers: { 'content-type': 'application/octet-stream', 'content-length': String(content.length) },
            }, incoming => {
                let body = '';
                incoming.setEncoding('utf8');
                incoming.on('data', chunk => { body += chunk; });
                incoming.on('end', () => resolve({ status: incoming.statusCode, body }));
                incoming.on('error', reject);
            });
            request.on('error', reject);
        });
        request.write(content.subarray(0, 64 * 1024));
        await waitFor(async () => {
            const entries = await readdir(partsDirectory).catch(error => {
                if (error.code === 'ENOENT') return [];
                throw error;
            });
            return entries.some(name => name.startsWith('.partial-'));
        });
        await changeState();
        request.end(content.subarray(64 * 1024));
        const result = await response;
        expect(result.status, result.body).toBe(status);
        expect(await storage.listParts(session.id)).toEqual([]);
        expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(0);
    });

    it('uses exact 50 MiB parts, permits out-of-order resume, and checks the full original', async () => {
        const chunk = Buffer.alloc(1024 * 1024, 0x63);
        const tail = Buffer.from('end');
        const hash = createHash('sha256');
        for (let i = 0; i < 50; i += 1) hash.update(chunk);
        hash.update(tail);
        const response = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
            expectedSizeBytes: MAX_PART_SIZE_BYTES + tail.length,
            expectedSha256: hash.digest('hex'),
        });
        expect(response.statusCode, response.body).toBe(201);
        const session = response.json().uploadSession;
        expect(session.partCount).toBe(2);
        const first = await sign(session.id, 1);
        const second = await sign(session.id, 2);
        expect(first.sizeBytes).toBe(MAX_PART_SIZE_BYTES);
        expect(second.sizeBytes).toBe(tail.length);
        expect((await put(second.url, tail)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(409);
        const uploaded = await sendHttp(first.url, {
            'content-type': 'application/octet-stream', 'content-length': String(MAX_PART_SIZE_BYTES),
        }, Array(50).fill(chunk));
        expect(uploaded.status, uploaded.body).toBe(200);
        const resumed = await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`);
        expect(resumed.json().uploadSession.parts.map(part => part.partNumber)).toEqual([1, 2]);
        const complete = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
        expect(complete.statusCode, complete.body).toBe(200);
        expect(complete.json().uploadSession.status).toBe('COMPLETED');
    }, 30000);

    it('expires and aborts unfinished sessions without misreporting their state', async () => {
        const session = await createSession(Buffer.from('expires'));
        currentTime += 24 * 60 * 60 * 1000 + 1;
        const resumed = await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`);
        expect(resumed.statusCode).toBe(200);
        expect(resumed.json().uploadSession.status).toBe('EXPIRED');
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/parts/1/sign`)).statusCode).toBe(410);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(410);
        const aborted = await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${session.id}`);
        expect(aborted.json().uploadSession.status).toBe('EXPIRED');
        await expect(storage.listParts(session.id)).rejects.toThrow('Upload session not found');
    });

    it('waits for interrupted abort cleanup before creating a replacement session', async () => {
        const content = Buffer.from('abort while writing');
        const session = await createSession(content);
        const { createUploadSessionService } = await import('../lib/upload-sessions.js');
        const service = createUploadSessionService({
            db: prisma, storage, capacity: unrestrictedTestCapacity, now: () => new Date(currentTime),
        });
        let started;
        const reading = new Promise(resolve => { started = resolve; });
        const source = new Readable({
            read() {
                this._read = () => {};
                this.push(content);
                started();
            },
        });
        const writing = service.uploadPart({
            ownerId, uploadSessionId: session.id, partNumber: 1, body: source, expectedSizeBytes: content.length,
        });
        const writeRejected = expect(writing).rejects.toMatchObject({ code: 'INVALID_STATE' });
        await reading;
        try {
            expect((await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${session.id}`)).statusCode).toBe(409);
            expect((await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
                expectedSizeBytes: content.length, expectedSha256: sha256(content),
            })).statusCode).toBe(409);
            expect(await prisma.uploadSession.count({ where: { assetId } })).toBe(1);
        } finally {
            source.push(null);
            await writeRejected;
        }
        const next = await createSession(content);
        expect(next.clipId).toBe(session.clipId);
        await expect(storage.listParts(session.id)).rejects.toThrow('Upload session not found');
    });

    it('rejects a bad whole-file checksum and permits a fresh session after abort', async () => {
        const content = Buffer.from('checksum');
        const created = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
            expectedSizeBytes: content.length, expectedSha256: '0'.repeat(64),
        });
        expect(created.statusCode).toBe(201);
        const session = created.json().uploadSession;
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        const complete = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
        expect(complete.statusCode).toBe(422);
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        expect(row.status).toBe('OPEN');
        expect(await storage.stat(row.storageKey)).toBeNull();
        expect((await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${session.id}`)).statusCode).toBe(200);
        const next = await createSession(content);
        expect(next.id).not.toBe(session.id);
        expect(next.clipId).toBe(session.clipId);
        expect(await prisma.asset.findUnique({ where: { id: assetId } })).toMatchObject({ clipCount: 1 });
    });

    it('recovers an interrupted completion when the client retries complete', async () => {
        const content = Buffer.from('recover completion');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        await prisma.uploadSession.update({ where: { id: session.id }, data: { status: 'COMPLETING' } });
        const complete = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
        expect(complete.statusCode, complete.body).toBe(200);
        expect(complete.json().uploadSession.status).toBe('COMPLETED');
    });

    it('does not report a completed original as available after its file is lost', async () => {
        const content = Buffer.from('lost original');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        const original = path.join(storageRoot, ...row.storageKey.split('/'));
        const backup = `${original}.test-backup`;
        await rename(original, backup);
        try {
            const get = await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`);
            expect(get.statusCode).toBe(503);
            expect(get.body).not.toContain(row.storageKey);
            expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(503);
            expect((await requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
                expectedSizeBytes: content.length, expectedSha256: sha256(content),
            })).statusCode).toBe(503);
        } finally {
            await rename(backup, original);
        }
        expect((await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`)).statusCode).toBe(200);
    });

    it('reports a missing storage marker and recovers after it is restored', async () => {
        const content = Buffer.from('original on unavailable storage');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        const marker = path.join(storageRoot, '.dvu-storage-id');
        const backup = path.join(storageRoot, '.dvu-storage-id-test-backup');
        await rename(marker, backup);
        try {
            expect((await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`)).statusCode).toBe(503);
            expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(503);
        } finally {
            await rename(backup, marker);
        }
        const recovered = await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`);
        expect(recovered.statusCode).toBe(200);
        expect(recovered.json().uploadSession.status).toBe('COMPLETED');
    });

    it.each([
        ['OPEN', 'FLAGGED_FOR_REMOVAL'],
        ['OPEN', 'REMOVED'],
        ['COMPLETED', 'FLAGGED_FOR_REMOVAL'],
        ['COMPLETED', 'REMOVED'],
    ])('hides a %s session for a %s asset even if storage is unavailable', async (status, moderation) => {
        const content = Buffer.from('hidden original');
        const session = await createSession(content);
        if (status === 'COMPLETED') {
            const signed = await sign(session.id);
            expect((await put(signed.url, content)).statusCode).toBe(200);
            expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        }
        await prisma.asset.update({ where: { id: assetId }, data: { moderation } });
        const marker = path.join(storageRoot, '.dvu-storage-id');
        const backup = path.join(storageRoot, '.dvu-storage-id-test-backup');
        await rename(marker, backup);
        try {
            expect((await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`)).statusCode).toBe(404);
            expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(404);
            expect((await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${session.id}`)).statusCode).toBe(404);
        } finally {
            await rename(backup, marker);
        }
    });

    it('never creates Mux and original uploads concurrently for the same asset', async () => {
        const content = Buffer.from('race');
        const [original, mux] = await Promise.all([
            requestAs(ownerId, 'POST', `/api/assets/${assetId}/upload-sessions`, {
                expectedSizeBytes: content.length, expectedSha256: sha256(content),
            }),
            requestAs(ownerId, 'POST', `/api/assets/${assetId}/mux-upload`, {}),
        ]);
        expect([original.statusCode, mux.statusCode].sort()).toEqual(
            original.statusCode === 201 ? [201, 409] : [200, 409],
        );
        const sessionCount = await prisma.uploadSession.count({ where: { assetId } });
        const muxClipCount = await prisma.clip.count({ where: { assetId, muxUploadId: { not: null } } });
        expect(sessionCount + muxClipCount).toBe(1);
    });

    it.each(['OPEN', 'COMPLETED'])('does not orphan-clean an old asset with a %s original session', async status => {
        await prisma.asset.update({
            where: { id: assetId }, data: { createdAt: new Date(Date.now() - 2 * 60 * 60 * 1000) },
        });
        const content = Buffer.from('keep original');
        const session = await createSession(content);
        if (status === 'COMPLETED') {
            const signed = await sign(session.id);
            expect((await put(signed.url, content)).statusCode).toBe(200);
            expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        }
        await cleanupOrphanedUploads(app);
        expect(await prisma.asset.findUnique({ where: { id: assetId } })).toMatchObject({ status: 'UPLOADING' });
        expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject({ status: 'UPLOADING' });
    });

    it.each(['OPEN', 'COMPLETED'])('removes %s original bytes before reporting moderation synced', async status => {
        const content = Buffer.from('remove original');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        if (status === 'COMPLETED') {
            expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        }
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        const flagged = await requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
            moderation: 'FLAGGED_FOR_REMOVAL', reason: 'integration test',
        });
        expect([200, 202]).toContain(flagged.statusCode);
        const removed = await requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
            moderation: 'REMOVED', reason: 'integration test',
        });
        expect(removed.statusCode, removed.body).toBe(200);
        expect(removed.json().mediaSyncState).toBe('SYNCED');
        expect(await storage.stat(row.storageKey)).toBeNull();
        await expect(storage.listParts(session.id)).rejects.toThrow('Upload session not found');
        expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject({
            storageKey: null, storageDriver: null, sha256: null,
        });
        expect((await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`)).statusCode).toBe(404);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(404);
        expect((await put(signed.url, content)).statusCode).toBe(403);
    });

    it('keeps removal pending while an in-flight part is writing and cleans it on retry', async () => {
        const content = Buffer.from('writing part');
        const session = await createSession(content);
        await prisma.uploadSession.update({
            where: { id: session.id }, data: { storageReservationBytes: 1234n },
        });
        let started;
        const reading = new Promise(resolve => { started = resolve; });
        const source = new Readable({
            read() {
                this._read = () => {};
                this.push(content);
                started();
            },
        });
        const writing = storage.uploadPart(session.id, 1, source, { expectedSizeBytes: content.length });
        await reading;
        const flagged = await requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
            moderation: 'FLAGGED_FOR_REMOVAL', reason: 'integration test',
        });
        expect([200, 202]).toContain(flagged.statusCode);
        const removed = await requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
            moderation: 'REMOVED', reason: 'integration test',
        });
        expect(removed.statusCode, removed.body).toBe(202);
        expect(removed.json().mediaSyncState).toBe('PENDING');
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes).toBe(1234n);
        source.push(null);
        await writing;
        expect((await reconcileAssetMedia(app, assetId)).state).toBe('SYNCED');
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes).toBe(0n);
        await expect(storage.listParts(session.id)).rejects.toThrow('Upload session not found');
    });

    it('does not report removal synced while completion holds the filesystem lock', async () => {
        const session = await createSession(Buffer.from('completion lock'));
        const flagged = await requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
            moderation: 'FLAGGED_FOR_REMOVAL', reason: 'integration test',
        });
        expect([200, 202]).toContain(flagged.statusCode);
        const held = await storage.withCompletionLock(session.id, async () => {
            return requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
                moderation: 'REMOVED', reason: 'integration test',
            });
        });
        expect(held.acquired).toBe(true);
        expect(held.value.statusCode).toBe(202);
        expect(held.value.json().mediaSyncState).toBe('PENDING');
        expect((await reconcileAssetMedia(app, assetId)).state).toBe('SYNCED');
        await expect(storage.listParts(session.id)).rejects.toThrow('Upload session not found');
    });

    it('reports cleanup failures and only marks removal synced after a successful retry', async () => {
        const content = Buffer.from('retained until cleanup');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        await prisma.uploadSession.update({
            where: { id: session.id }, data: { storageReservationBytes: 1234n },
        });
        await prisma.asset.update({
            where: { id: assetId },
            data: { moderation: 'REMOVED', mediaSyncRevision: { increment: 1 }, mediaSyncState: 'PENDING' },
        });
        const failing = createMediaReconciler({
            db: prisma,
            muxApi,
            withLock: withAssetMediaLock,
            storageFactory: () => ({ ...storage, delete: async () => { throw new Error('disk unavailable'); } }),
        });
        expect((await failing(app, assetId)).state).toBe('ERROR');
        expect(await storage.stat(row.storageKey)).not.toBeNull();
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes).toBe(1234n);
        expect(await prisma.asset.findUnique({ where: { id: assetId } })).toMatchObject({ mediaSyncState: 'ERROR' });
        expect((await reconcileAssetMedia(app, assetId)).state).toBe('SYNCED');
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes).toBe(0n);
        expect(await storage.stat(row.storageKey)).toBeNull();
    });

    it('reports changed storage as unavailable and preserves staged data for retry', async () => {
        const content = Buffer.from('retained during verification');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        const sessionPath = path.join(storageRoot, '.uploads', session.id);
        const manifest = await readFile(path.join(sessionPath, 'manifest.json'));
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        await prisma.uploadSession.update({
            where: { id: session.id }, data: { storageReservationBytes: 1234n },
        });
        await mkdir(path.join(sessionPath, 'parts'), { recursive: true });
        await writeFile(path.join(sessionPath, 'manifest.json'), manifest);
        await writeFile(path.join(sessionPath, 'parts', '00001'), content);
        const read = vi.spyOn(storage, 'getReadStream')
            .mockResolvedValueOnce(Readable.from([Buffer.from('changed')]));
        try {
            const response = await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`);
            expect(response.statusCode).toBe(503);
            expect(response.json()).toEqual({ error: 'Stored object changed while recovering completion' });
            expect(await storage.hasUpload(session.id)).toBe(true);
            expect(await readFile(path.join(sessionPath, 'parts', '00001'))).toEqual(content);
            expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes).toBe(1234n);
        } finally {
            read.mockRestore();
        }
        expect((await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`)).statusCode).toBe(200);
        expect(await storage.hasUpload(session.id)).toBe(false);
    });

    it('does not report removal synced against a different storage root', async () => {
        const content = Buffer.from('original on correct volume');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        const wrongRoot = await mkdtemp(path.join(os.tmpdir(), 'dvu-wrong-volume-'));
        try {
            const wrongStorage = createLocalStorageDriver({ root: wrongRoot });
            await wrongStorage.createUpload({ ownerId, assetId, clipId: session.clipId });
            const { createUploadSessionService } = await import('../lib/upload-sessions.js');
            const wrongService = createUploadSessionService({
                db: prisma, storage: wrongStorage, capacity: unrestrictedTestCapacity,
            });
            await expect(wrongService.get({ ownerId, uploadSessionId: session.id }))
                .rejects.toMatchObject({ code: 'STORAGE_UNAVAILABLE' });
            process.env.STORAGE_LOCAL_ROOT = wrongRoot;
            const flagged = await requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
                moderation: 'FLAGGED_FOR_REMOVAL', reason: 'integration test',
            });
            expect([200, 202]).toContain(flagged.statusCode);
            const removed = await requestAs(adminId, 'PATCH', `/api/admin/assets/${assetId}/moderation`, {
                moderation: 'REMOVED', reason: 'integration test',
            });
            expect(removed.statusCode).toBe(202);
            expect(removed.json().mediaSyncState).toBe('ERROR');
            expect(await storage.stat(row.storageKey)).not.toBeNull();
            expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject({
                storageKey: row.storageKey,
            });
            process.env.STORAGE_LOCAL_ROOT = storageRoot;
            expect((await reconcileAssetMedia(app, assetId)).state).toBe('SYNCED');
            expect(await storage.stat(row.storageKey)).toBeNull();
        } finally {
            process.env.STORAGE_LOCAL_ROOT = storageRoot;
            await rm(wrongRoot, { recursive: true, force: true });
        }
    });

    it('does not report abort or expiry cleanup against a different storage root', async () => {
        const content = Buffer.from('keep until root returns');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        const wrongRoot = await mkdtemp(path.join(os.tmpdir(), 'dvu-wrong-volume-'));
        try {
            const wrongStorage = createLocalStorageDriver({ root: wrongRoot });
            await wrongStorage.createUpload({ ownerId, assetId, clipId: session.clipId });
            const { createUploadSessionService } = await import('../lib/upload-sessions.js');
            const service = createUploadSessionService({
                db: prisma,
                storage: wrongStorage,
                capacity: unrestrictedTestCapacity,
                now: () => new Date(currentTime + 25 * 60 * 60 * 1000),
            });
            await expect(service.abort({ ownerId, uploadSessionId: session.id })).rejects.toThrow('does not match');
            await expect(service.get({ ownerId, uploadSessionId: session.id })).rejects.toThrow('does not match');
            await expect(service.create({
                ownerId,
                assetId,
                clipId: session.clipId,
                expectedSizeBytes: content.length,
                expectedSha256: sha256(content),
            })).rejects.toMatchObject({ code: 'STORAGE_UNAVAILABLE' });
            expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toMatchObject({ status: 'OPEN' });
            expect(await prisma.uploadSession.count({ where: { assetId } })).toBe(1);
            expect(await storage.listParts(session.id)).toHaveLength(1);
        } finally {
            await rm(wrongRoot, { recursive: true, force: true });
        }
    });

    it('does not report removal synced if an original has lost its session record', async () => {
        const content = Buffer.from('untracked original');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        await prisma.uploadSession.delete({ where: { id: session.id } });
        await prisma.asset.update({
            where: { id: assetId },
            data: { moderation: 'REMOVED', mediaSyncRevision: { increment: 1 }, mediaSyncState: 'PENDING' },
        });
        expect((await reconcileAssetMedia(app, assetId)).state).toBe('ERROR');
        expect(await storage.stat(row.storageKey)).not.toBeNull();
    });

    it('does not replace a retained original that has lost its session record', async () => {
        const content = Buffer.from('keep untracked original');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(200);
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        await prisma.uploadSession.delete({ where: { id: session.id } });
        await prisma.asset.update({ where: { id: assetId }, data: { uploadMode: null } });

        const detail = await requestAs(ownerId, 'GET', `/api/assets/${assetId}`);
        expect(detail.json().asset.uploadMode).toBe('ORIGINAL');
        expect(detail.json().asset.clips[0]).not.toHaveProperty('storageKey');

        const response = await requestAs(ownerId, 'POST', `/api/assets/${assetId}/mux-upload`, {});
        expect(response.statusCode).toBe(409);
        expect(muxApi.createDirectUpload).not.toHaveBeenCalled();
        expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject({
            storageKey: row.storageKey,
        });
        expect(await storage.stat(row.storageKey)).not.toBeNull();
    });
});
