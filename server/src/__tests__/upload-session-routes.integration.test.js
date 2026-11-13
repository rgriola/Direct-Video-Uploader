import Fastify from 'fastify';
import fastifyJwt from '@fastify/jwt';
import cookie from '@fastify/cookie';
import csrfProtection from '@fastify/csrf-protection';
import rateLimit from '@fastify/rate-limit';
import { createHash, randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { link, mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
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
        const { default: originalUploadRecoveryRoutes } = await import('../routes/original-upload-recovery.js');
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
        await app.register(originalUploadRecoveryRoutes, { db: uploadDb });
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

    async function blockedQueryBy(pid, fragment) {
        let blockedPid;
        await vi.waitFor(async () => {
            const rows = await prisma.$queryRaw`
                SELECT pid FROM pg_stat_activity
                WHERE ${pid} = ANY(pg_blocking_pids(pid))
                  AND query LIKE ${`%${fragment}%`}`;
            expect(rows).toHaveLength(1);
            blockedPid = rows[0].pid;
        }, { timeout: 5_000, interval: 10 });
        return blockedPid;
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

    async function withRegistryServers(run) {
        const { authenticate } = await import('../lib/authentication.js');
        const { requireRole } = await import('../lib/authorization.js');
        const { registerApplicationRoutes } = await import('../routes/index.js');
        const servers = [];
        const unusedRoot = path.join(os.tmpdir(), `dvu-disabled-${randomUUID()}`);
        async function buildServer(enabled) {
            vi.stubEnv('UPLOAD_SESSIONS_ENABLED', String(enabled));
            vi.stubEnv('MUX_ORIGINAL_INGEST_ENABLED', 'false');
            vi.stubEnv('STORAGE_LOCAL_ROOT', enabled ? storageRoot : unusedRoot);
            vi.stubEnv('STORAGE_DRIVER', enabled ? 'local' : undefined);
            vi.stubEnv('JWT_SECRET', 'integration-jwt-secret');
            vi.stubEnv('UPLOAD_SESSION_SIGNING_SECRET', enabled ? signingSecret : undefined);
            vi.stubEnv('UPLOAD_STORAGE_MAX_BYTES', enabled ? '10737418240' : undefined);
            vi.stubEnv('UPLOAD_STORAGE_MIN_FREE_BYTES', enabled ? '1048576' : undefined);
            vi.stubEnv('MUX_ORIGINAL_READ_SIGNING_SECRET', undefined);
            vi.stubEnv('MUX_ORIGINAL_READ_BASE_URL', undefined);
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
        try {
            return await run(buildServer);
        } finally {
            try {
                await Promise.all(servers.map(server => server.close()));
                await expect(readdir(unusedRoot)).rejects.toMatchObject({ code: 'ENOENT' });
            } finally {
                vi.unstubAllEnvs();
                await rm(unusedRoot, { recursive: true, force: true });
            }
        }
    }

    function registryRequest(server, userId, method, url, payload, remoteAddress = '127.0.0.1') {
        return server.inject({
            method, url, payload, remoteAddress,
            headers: {
                ...(userId ? { authorization: `Bearer ${tokens[userId]}` } : {}),
                ...(Buffer.isBuffer(payload) ? { 'content-type': 'application/octet-stream' } : {}),
            },
        });
    }

    function intentWhere(userId, clientRequestId) {
        return { userId_clientRequestId: { userId, clientRequestId } };
    }

    async function filesystemInventory(directory = storageRoot) {
        const inventory = [];
        for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) =>
            a.name.localeCompare(b.name))) {
            const fullPath = path.join(directory, entry.name);
            inventory.push([
                path.relative(storageRoot, fullPath),
                entry.isDirectory() ? await filesystemInventory(fullPath) : sha256(await readFile(fullPath)),
            ]);
        }
        return inventory;
    }

    async function originalSnapshot(id) {
        return {
            asset: await prisma.asset.findUniqueOrThrow({ where: { id } }),
            clips: await prisma.clip.findMany({ where: { assetId: id }, orderBy: { id: 'asc' } }),
            sessions: await prisma.uploadSession.findMany({ where: { assetId: id }, orderBy: { id: 'asc' } }),
            parts: await prisma.uploadPart.findMany({
                where: { uploadSession: { assetId: id } },
                orderBy: [{ uploadSessionId: 'asc' }, { partNumber: 'asc' }],
            }),
            jobs: await prisma.muxIngestJob.findMany({ where: { uploadSession: { assetId: id } } }),
            files: await filesystemInventory(),
        };
    }

    it('gates intake while retaining recovery and serves an enabled upload through the application registry', async () => {
        const content = Buffer.from('registered upload');
        const url = `/api/assets/${assetId}/upload-sessions`;
        const payload = { expectedSizeBytes: content.length, expectedSha256: sha256(content) };
        await withRegistryServers(async buildServer => {
            const disabled = await buildServer(false);
            expect((await disabled.inject({ method: 'POST', url, payload })).statusCode).toBe(404);
            expect((await disabled.inject({
                method: 'POST', url: '/api/assets/original-uploads',
                payload: { clientRequestId: randomUUID(), fileName: 'video.mp4' },
            })).statusCode).toBe(404);
            const pageUrl = `/api/assets/original-uploads/${randomUUID()}/sessions`;
            expect((await disabled.inject({ method: 'GET', url: pageUrl })).statusCode).toBe(401);
            const enabled = await buildServer(true);
            expect((await enabled.inject({ method: 'POST', url, payload })).statusCode).toBe(401);
            expect((await enabled.inject({ method: 'GET', url: pageUrl })).statusCode).toBe(401);
            const headers = { authorization: ['Bearer', tokens[ownerId]].join(' ') };
            for (let attempt = 0; attempt < 9; attempt += 1) {
                expect((await enabled.inject({ method: 'GET', url: pageUrl, headers })).statusCode).toBe(404);
            }
            expect((await enabled.inject({ method: 'GET', url: pageUrl, headers })).statusCode).toBe(429);
            const clientRequestId = randomUUID();
            const intent = await enabled.inject({
                method: 'POST',
                url: '/api/assets/original-uploads',
                headers,
                payload: { clientRequestId, fileName: 'video.mp4', ...payload },
            });
            expect(intent.statusCode, intent.body).toBe(201);
            const pendingId = intent.json().asset.id;
            expect(await prisma.uploadSession.count({ where: { assetId: pendingId } })).toBe(0);
            const inspectionUrl = `/api/original-upload-recovery/${clientRequestId}`;
            expect((await disabled.inject({ method: 'GET', url: inspectionUrl })).statusCode).toBe(401);
            const inspection = await disabled.inject({ method: 'GET', url: inspectionUrl, headers });
            expect(inspection.statusCode, inspection.body).toBe(200);
            expect(inspection.headers['cache-control']).toBe('no-store');
            expect(inspection.json()).toEqual({ state: 'ACTIVE', assetId: pendingId, sessions: [], truncated: false });
            const capabilities = await disabled.inject({ method: 'GET', url: '/api/upload-capabilities', headers });
            expect(capabilities.json()).toEqual({ originalUploads: false });
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
        });
    });

    it('preserves direct-to-Mux uploads through the registry while original intake and ingest are disabled', async () => {
        await withRegistryServers(async buildServer => {
            const disabled = await buildServer(false);
            const created = await registryRequest(disabled, ownerId, 'POST', '/api/assets', {
                fileName: 'direct-disabled.mov',
                uploadMode: 'MUX',
            });
            expect(created.statusCode, created.body).toBe(200);
            const asset = created.json().asset;
            const id = asset.id;
            expect(asset.uploadMode).toBe('MUX');

            const uploaded = await registryRequest(disabled, ownerId, 'POST',
                `/api/assets/${id}/mux-upload`, {});
            expect(uploaded.statusCode, uploaded.body).toBe(200);
            expect(muxApi.createDirectUpload).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({ assetId: id }));
            expect(await prisma.originalUploadIntent.findUnique({ where: { assetId: id } })).toBeNull();
            expect(await prisma.uploadSession.count({ where: { assetId: id } })).toBe(0);

            const capabilities = await registryRequest(disabled, ownerId, 'GET', '/api/upload-capabilities');
            expect(capabilities.statusCode, capabilities.body).toBe(200);
            expect(capabilities.json().originalUploads).toBe(false);
        });
    });

    it('cancels and recovers an OPEN original across disabled registry restarts without intake or side effects', async () => {
        const content = Buffer.from('disabled registry original');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const id = reserved.json().asset.id;
        const session = await createSession(content, id);
        const signed = await sign(session.id);
        const where = intentWhere(ownerId, payload.clientRequestId);
        const intentBefore = await prisma.originalUploadIntent.findUniqueOrThrow({ where });
        const before = await originalSnapshot(id);
        const muxCalls = Object.values(muxApi).map(mock => mock.mock.calls.length);
        const notifications = socketEmit.mock.calls.length;
        await withRegistryServers(async buildServer => {
            let disabled = await buildServer(false);
            const cancelUrl = `/api/assets/original-uploads/${payload.clientRequestId}/cancel`;
            const cancelled = await registryRequest(disabled, ownerId, 'POST', cancelUrl);
            expect(cancelled.statusCode, cancelled.body).toBe(200);
            expect(cancelled.headers['cache-control']).toBe('no-store');
            expect(cancelled.json()).toEqual({ assetId: id, sessionIds: [session.id] });
            const fenced = await prisma.originalUploadIntent.findUniqueOrThrow({ where });
            expect(fenced.cancelledAt).toBeInstanceOf(Date);
            expect(fenced).toEqual({ ...intentBefore, cancelledAt: fenced.cancelledAt });
            await disabled.close();
            disabled = await buildServer(false);
            const retry = await registryRequest(disabled, ownerId, 'POST', cancelUrl);
            expect(retry.statusCode, retry.body).toBe(200);
            expect(retry.json()).toEqual(cancelled.json());
            expect(await prisma.originalUploadIntent.findUniqueOrThrow({ where })).toEqual(fenced);
            const page = await registryRequest(disabled, ownerId, 'GET',
                `/api/assets/original-uploads/${payload.clientRequestId}/sessions`);
            expect(page.statusCode, page.body).toBe(200);
            expect(page.headers['cache-control']).toBe('no-store');
            expect(page.json()).toEqual({ assetId: id, sessionIds: [session.id], nextCursor: null });
            const inspected = await registryRequest(disabled, ownerId, 'GET',
                `/api/original-upload-recovery/${payload.clientRequestId}`);
            expect(inspected.statusCode, inspected.body).toBe(200);
            expect(inspected.json()).toEqual({
                state: 'CANCELLED', assetId: id, sessions: [{ id: session.id, status: 'OPEN' }], truncated: false,
            });
            for (const [method, url, body] of [
                ['POST', '/api/assets/original-uploads', payload],
                ['POST', `/api/assets/${id}/upload-sessions`, payload],
                ['GET', `/api/upload-sessions/${session.id}`],
                ['POST', `/api/upload-sessions/${session.id}/parts/1/sign`],
                ['PUT', signed.url, content],
                ['POST', `/api/upload-sessions/${session.id}/complete`],
                ['DELETE', `/api/upload-sessions/${session.id}`],
                ['POST', `/api/upload-sessions/${session.id}/mux-ingest`],
                ['GET', `/api/mux-originals/${randomUUID()}`],
            ]) {
                const response = await registryRequest(disabled, ownerId, method, url, body);
                expect(response.statusCode, `${method} ${url}: ${response.body}`).toBe(404);
            }
        });
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload)).statusCode).toBe(410);
        expect((await requestAs(ownerId, 'POST', `/api/assets/${id}/upload-sessions`, payload)).statusCode).toBe(410);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/parts/1/sign`)).statusCode)
            .toBe(410);
        expect((await put(signed.url, content)).statusCode).toBe(403);
        expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(410);
        expect(await originalSnapshot(id)).toEqual(before);
        expect(Object.values(muxApi).map(mock => mock.mock.calls.length)).toEqual(muxCalls);
        expect(socketEmit.mock.calls.length).toBe(notifications);
    });

    it('keeps disabled cancellation tombstones owner-only and rejects guests and suspended owners', async () => {
        const payload = originalReservation(Buffer.from('disabled owner scope'));
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const id = reserved.json().asset.id;
        const session = await createSession(Buffer.from('disabled owner scope'), id);
        const before = await originalSnapshot(id);
        const ownerIntent = await prisma.originalUploadIntent.findUniqueOrThrow({
            where: intentWhere(ownerId, payload.clientRequestId),
        });
        await withRegistryServers(async buildServer => {
            const disabled = await buildServer(false);
            const missing = originalReservation(Buffer.from('never arrived'));
            const counts = async () => ({
                assets: await prisma.asset.count({ where: { userId: ownerId } }),
                sessions: await prisma.uploadSession.count({ where: { ownerId } }),
                clips: await prisma.clip.count({ where: { asset: { userId: ownerId } } }),
                intents: await prisma.originalUploadIntent.count({ where: { userId: ownerId } }),
            });
            const beforeCounts = await counts();
            const cancelUrl = `/api/assets/original-uploads/${missing.clientRequestId}/cancel`;
            const cancelled = await registryRequest(disabled, ownerId, 'POST', cancelUrl);
            expect(cancelled.statusCode, cancelled.body).toBe(200);
            expect(cancelled.json()).toEqual({ assetId: null, sessionIds: [] });
            expect(await prisma.originalUploadIntent.findUniqueOrThrow({
                where: intentWhere(ownerId, missing.clientRequestId),
            })).toMatchObject({ assetId: null, cancelledAt: expect.any(Date) });
            expect(await counts()).toEqual({ ...beforeCounts, intents: beforeCounts.intents + 1 });
            expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', missing)).statusCode).toBe(410);

            for (const foreignId of [otherId, teamAdminId, adminId]) {
                const foreign = await registryRequest(disabled, foreignId, 'POST',
                    `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
                expect(foreign.statusCode, foreign.body).toBe(200);
                expect(foreign.json()).toEqual({ assetId: null, sessionIds: [] });
                expect(await prisma.originalUploadIntent.findUniqueOrThrow({
                    where: intentWhere(foreignId, payload.clientRequestId),
                })).toMatchObject({ assetId: null, cancelledAt: expect.any(Date) });
                const page = await registryRequest(disabled, foreignId, 'GET',
                    `/api/assets/original-uploads/${payload.clientRequestId}/sessions`);
                expect(page.statusCode, page.body).toBe(200);
                expect(page.json()).toEqual({ assetId: null, sessionIds: [], nextCursor: null });
                expect(page.body).not.toContain(id);
                expect(page.body).not.toContain(session.id);
            }
            const rejectedId = randomUUID();
            for (const [userId, status] of [[null, 401], [ownerId, 403]]) {
                if (userId) await prisma.user.update({ where: { id: userId }, data: { status: 'SUSPENDED' } });
                for (const [method, url] of [
                    ['POST', `/api/assets/original-uploads/${rejectedId}/cancel`],
                    ['GET', `/api/assets/original-uploads/${missing.clientRequestId}/sessions`],
                    ['GET', `/api/original-upload-recovery/${missing.clientRequestId}`],
                ]) {
                    expect((await registryRequest(disabled, userId, method, url)).statusCode).toBe(status);
                }
            }
            expect(await prisma.originalUploadIntent.findUnique({
                where: intentWhere(ownerId, rejectedId),
            })).toBeNull();
        });
        expect(await prisma.originalUploadIntent.findUniqueOrThrow({
            where: intentWhere(ownerId, payload.clientRequestId),
        })).toEqual(ownerIntent);
        expect(await originalSnapshot(id)).toEqual(before);
    });

    it.each(['hidden', 'inconsistent'])('commits disabled %s cancellation fences without exposing IDs', async mode => {
        const content = Buffer.from(`disabled ${mode}`);
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const id = reserved.json().asset.id;
        const session = await createSession(content, id);
        const conflictingAssetId = randomUUID();
        const conflictingClipId = randomUUID();
        if (mode === 'hidden') {
            await prisma.asset.update({ where: { id }, data: { moderation: 'FLAGGED_FOR_REMOVAL' } });
        } else {
            await prisma.asset.create({
                data: {
                    id: conflictingAssetId, userId: otherId, status: 'UPLOADING',
                    clips: { create: { id: conflictingClipId, status: 'UPLOADING' } },
                },
            });
            await prisma.uploadSession.update({
                where: { id: session.id }, data: { clipId: conflictingClipId },
            });
        }
        const before = await originalSnapshot(id);
        await withRegistryServers(async buildServer => {
            const disabled = await buildServer(false);
            for (const [method, url] of [
                ['POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`],
                ['GET', `/api/assets/original-uploads/${payload.clientRequestId}/sessions`],
                ['GET', `/api/original-upload-recovery/${payload.clientRequestId}`],
            ]) {
                const response = await registryRequest(disabled, ownerId, method, url);
                expect(response.statusCode, response.body).toBe(mode === 'hidden' ? 404 : 503);
                for (const secret of [
                    id, session.id, session.clipId, conflictingAssetId, conflictingClipId, ownerId, otherId,
                ]) {
                    expect(response.body).not.toContain(secret);
                }
            }
            expect(await prisma.originalUploadIntent.findUniqueOrThrow({
                where: intentWhere(ownerId, payload.clientRequestId),
            })).toMatchObject({ cancelledAt: expect.any(Date) });
        });
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload)).statusCode).toBe(410);
        expect(await originalSnapshot(id)).toEqual(before);
    });

    it('commits disabled overflow fences and pages all 102 sessions without mutation', async () => {
        const content = Buffer.from('disabled overflow history');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const id = reserved.json().asset.id;
        const session = await createSession(content, id);
        const historicalIds = Array.from({ length: 101 }, () => randomUUID());
        await prisma.uploadSession.createMany({
            data: historicalIds.map(idValue => ({
                id: idValue, ownerId, assetId: id, clipId: session.clipId, status: 'ABORTED',
                storageKey: `disabled-history-${idValue}`, expiresAt: new Date(),
            })),
        });
        const before = await originalSnapshot(id);
        await withRegistryServers(async buildServer => {
            const disabled = await buildServer(false);
            const response = await registryRequest(disabled, ownerId, 'POST',
                `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
            expect(response.statusCode, response.body).toBe(503);
            expect(response.headers['cache-control']).toBe('no-store');
            expect(response.json()).toMatchObject({ code: 'INTENT_SESSION_LIMIT' });
            for (const secret of [id, session.id, ...historicalIds]) expect(response.body).not.toContain(secret);
            expect(await prisma.originalUploadIntent.findUniqueOrThrow({
                where: intentWhere(ownerId, payload.clientRequestId),
            })).toMatchObject({ cancelledAt: expect.any(Date) });
            const ids = [];
            let after;
            // A hard bound prevents a broken cursor from hanging the suite.
            for (let pageNumber = 0; pageNumber < 3; pageNumber += 1) {
                const page = await registryRequest(disabled, ownerId, 'GET',
                    `/api/assets/original-uploads/${payload.clientRequestId}/sessions${after ? `?after=${after}` : ''}`);
                expect(page.statusCode, page.body).toBe(200);
                expect(page.headers['cache-control']).toBe('no-store');
                const body = page.json();
                expect(body.assetId).toBe(id);
                expect(body.sessionIds.length).toBeLessThanOrEqual(100);
                expect(body.sessionIds.length).toBe(pageNumber === 0 ? 100 : 2);
                expect(body.sessionIds).toEqual([...body.sessionIds].sort());
                ids.push(...body.sessionIds);
                after = body.nextCursor;
                if (!after) break;
                expect(after).toBe(body.sessionIds.at(-1));
            }
            expect(after).toBeNull();
            expect(new Set(ids).size).toBe(102);
            expect(ids).toEqual([session.id, ...historicalIds].sort());
        });
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload)).statusCode).toBe(410);
        expect(await originalSnapshot(id)).toEqual(before);
    });

    it('enforces disabled owner quota without persisting rejection and rate limits cancellation at 10 per minute', async () => {
        const quotaOwner = `disabled-quota-${randomUUID()}`;
        await prisma.user.create({
            data: {
                id: quotaOwner, name: 'Synthetic Disabled Quota', phoneNumber: `disabled-quota-${randomUUID()}`,
                pinHash: 'integration-test', role: 'USER',
            },
        });
        tokens[quotaOwner] = app.jwt.sign({ id: quotaOwner });
        try {
            const recentIds = Array.from({ length: 100 }, () => randomUUID());
            const [{ epochMilliseconds }] = await prisma.$queryRaw`
                SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint AS "epochMilliseconds"`;
            await prisma.originalUploadIntent.createMany({
                data: recentIds.map(clientRequestId => ({
                    userId: quotaOwner, clientRequestId,
                    cancelledAt: new Date(Number(epochMilliseconds) - 60_000),
                })),
            });
            const before = await prisma.originalUploadIntent.findMany({
                where: { userId: quotaOwner }, orderBy: { clientRequestId: 'asc' },
            });
            await withRegistryServers(async buildServer => {
                const disabled = await buildServer(false);
                const rejectedId = randomUUID();
                const rejected = await registryRequest(disabled, quotaOwner, 'POST',
                    `/api/assets/original-uploads/${rejectedId}/cancel`);
                expect(rejected.statusCode, rejected.body).toBe(429);
                expect(rejected.json()).toMatchObject({ code: 'INTENT_CANCELLATION_QUOTA' });
                expect(rejected.headers['cache-control']).toBe('no-store');
                expect(Number(rejected.headers['retry-after'])).toBeGreaterThan(0);
                expect(Number(rejected.headers['retry-after'])).toBeLessThanOrEqual(86400);
                expect(await prisma.originalUploadIntent.findUnique({
                    where: intentWhere(quotaOwner, rejectedId),
                })).toBeNull();
                const url = `/api/assets/original-uploads/${recentIds[0]}/cancel`;
                const replay = await registryRequest(disabled, quotaOwner, 'POST', url);
                expect(replay.statusCode, replay.body).toBe(200);
                expect(replay.json()).toEqual({ assetId: null, sessionIds: [] });
                // Fresh server and IP isolate the HTTP limit from quota and prior requests.
                const limited = await buildServer(false);
                for (let attempt = 0; attempt < 10; attempt += 1) {
                    const response = await registryRequest(limited, quotaOwner, 'POST', url, undefined, '127.0.0.42');
                    expect(response.statusCode, response.body).toBe(200);
                }
                const throttled = await registryRequest(limited, quotaOwner, 'POST', url, undefined, '127.0.0.42');
                expect(throttled.statusCode, throttled.body).toBe(429);
                expect(Number(throttled.headers['retry-after'])).toBeGreaterThan(0);
                expect(throttled.headers['cache-control']).toBe('no-store');
            });
            expect(await prisma.originalUploadIntent.findMany({
                where: { userId: quotaOwner }, orderBy: { clientRequestId: 'asc' },
            })).toEqual(before);
            expect(await prisma.asset.count({ where: { userId: quotaOwner } })).toBe(0);
            expect(await prisma.uploadSession.count({ where: { ownerId: quotaOwner } })).toBe(0);
        } finally {
            delete tokens[quotaOwner];
            await prisma.user.delete({ where: { id: quotaOwner } });
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

    it('records an optional upload source on new reservations and rejects conflicting retries', async () => {
        const content = Buffer.from('web original');
        const payload = {
            clientRequestId: randomUUID(), fileName: 'web.mov', uploadSource: 'WEB',
            expectedSizeBytes: content.length, expectedSha256: sha256(content),
        };
        for (const uploadSource of ['web', 'DESKTOP', 1]) {
            expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', {
                ...payload, uploadSource,
            })).statusCode).toBe(400);
        }
        const created = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(created.statusCode).toBe(201);
        expect(created.json().asset.uploadSource).toBe('WEB');
        const { uploadSource: _omitted, ...withoutSource } = payload;
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', withoutSource)).statusCode).toBe(200);
        expect((await requestAs(ownerId, 'POST', '/api/assets/original-uploads', {
            ...payload, uploadSource: 'IOS',
        })).statusCode).toBe(409);
        const detail = await requestAs(ownerId, 'GET', `/api/assets/${created.json().asset.id}`);
        expect(detail.json().asset.uploadSource).toBe('WEB');

        const legacy = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', {
            ...withoutSource, clientRequestId: randomUUID(),
        });
        expect(legacy.statusCode).toBe(201);
        expect(legacy.json().asset.uploadSource).toBeNull();
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
        const completeRetry = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
        expect(completeRetry.statusCode, completeRetry.body).toBe(200);
        expect(completeRetry.json().uploadSession.status).toBe('COMPLETED');
    });

    async function stagedReservedOriginal(content) {
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const session = await createSession(content, reservedAssetId);
        const signed = await sign(session.id);
        const uploaded = await put(signed.url, content);
        expect(uploaded.statusCode, uploaded.body).toBe(200);
        return { payload, session, reservedAssetId };
    }

    it('rejects new signatures and previously signed PUTs after cancellation while preserving parts', async () => {
        const content = Buffer.from('part published before cancellation');
        const { payload, session } = await stagedReservedOriginal(content);
        const signed = await sign(session.id);
        const cancelled = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
        expect(cancelled.statusCode, cancelled.body).toBe(200);

        const deniedSign = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/parts/1/sign`);
        expect(deniedSign.statusCode, deniedSign.body).toBe(410);
        const deniedPut = await put(signed.url, content);
        expect(deniedPut.statusCode, deniedPut.body).toBe(403);
        expect(deniedPut.headers.connection).toBe('close');
        expect(deniedPut.json()).toEqual({ error: 'Invalid or expired upload URL' });
        const earlyResponse = await new Promise((resolve, reject) => {
            const request = httpRequest(new URL(signed.url, address), {
                method: 'PUT',
                headers: { 'content-type': 'application/octet-stream', 'content-length': String(content.length) },
            }, incoming => {
                incoming.resume();
                incoming.on('end', () => resolve(incoming.statusCode));
                incoming.on('error', reject);
            });
            request.on('error', reject);
            request.setTimeout(3000, () => request.destroy(new Error('Early rejection timed out')));
            request.flushHeaders();
        });
        expect(earlyResponse).toBe(403);
        const resumed = await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`);
        expect(resumed.statusCode, resumed.body).toBe(200);
        expect(resumed.json().uploadSession.status).toBe('OPEN');
        expect(resumed.json().uploadSession.parts).toHaveLength(1);
        expect(await storage.listParts(session.id)).toMatchObject([{ partNumber: 1, sha256: sha256(content) }]);
        const service = await handoffService();
        await expect(service.uploadPart({
            ownerId, uploadSessionId: session.id, partNumber: 1, body: content, expectedSizeBytes: content.length,
        })).rejects.toMatchObject({ code: 'INTENT_CANCELLED' });
    });

    it('rechecks cancellation after signing recovery before returning a URL', async () => {
        const content = Buffer.from('cancel during signing');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const session = await createSession(content, reserved.json().asset.id);
        let signalEntered;
        let releaseRecovery;
        const entered = new Promise(resolve => { signalEntered = resolve; });
        const recoveryGate = new Promise(resolve => { releaseRecovery = resolve; });
        const originalRecover = storage.recoverUpload;
        const spy = vi.spyOn(storage, 'recoverUpload').mockImplementation(async (...args) => {
            signalEntered();
            await recoveryGate;
            return originalRecover.apply(storage, args);
        });
        let signing;
        try {
            signing = Promise.resolve(requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/parts/1/sign`));
            await entered;
            const cancelled = await requestAs(
                ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
            expect(cancelled.statusCode, cancelled.body).toBe(200);
        } finally {
            releaseRecovery();
            spy.mockRestore();
        }
        const response = await signing;
        expect(response.statusCode, response.body).toBe(410);
    });

    it('fails closed on an inconsistent original intent without revealing it through signed PUTs', async () => {
        const content = Buffer.from('inconsistent intent');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const session = await createSession(content, reserved.json().asset.id);
        const signed = await sign(session.id);
        await prisma.originalUploadIntent.update({
            where: { assetId: reserved.json().asset.id }, data: { userId: otherId },
        });
        const deniedSign = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/parts/1/sign`);
        expect(deniedSign.statusCode, deniedSign.body).toBe(503);
        const deniedPut = await put(signed.url, content);
        expect(deniedPut.statusCode, deniedPut.body).toBe(403);
        expect(deniedPut.json()).toEqual({ error: 'Invalid or expired upload URL' });
        expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(0);
    });

    it('does not publish a real PUT when cancellation commits during its stream', async () => {
        const content = Buffer.alloc(512 * 1024, 0x65);
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const session = await createSession(content, reserved.json().asset.id);
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
        try {
            request.write(content.subarray(0, 64 * 1024));
            await waitFor(async () => {
                const entries = await readdir(partsDirectory).catch(error => {
                    if (error.code === 'ENOENT') return [];
                    throw error;
                });
                return entries.some(name => name.startsWith('.partial-'));
            });
            const cancelled = await requestAs(
                ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
            expect(cancelled.statusCode, cancelled.body).toBe(200);
            request.end(content.subarray(64 * 1024));
            const result = await response;
            expect(result.status, result.body).toBe(410);
        } finally {
            if (!request.destroyed) request.destroy();
        }
        expect(await storage.listParts(session.id)).toEqual([]);
        expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(0);
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('OPEN');
        expect((await readdir(partsDirectory)).filter(name => name.startsWith('.partial-'))).toEqual([]);
    });

    it('allows publication that holds the cancellation locks first', async () => {
        const content = Buffer.from('publication wins');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const session = await createSession(content, reserved.json().asset.id);
        const signed = await sign(session.id);
        let signalEntered;
        let releasePublication;
        const entered = new Promise(resolve => { signalEntered = resolve; });
        const publicationGate = new Promise(resolve => { releasePublication = resolve; });
        const originalUploadPart = storage.uploadPart;
        const spy = vi.spyOn(storage, 'uploadPart').mockImplementation((id, part, body, options) =>
            originalUploadPart.call(storage, id, part, body, {
                ...options,
                commitPart: (result, publish) => options.commitPart(result, async () => {
                    signalEntered();
                    await publicationGate;
                    await publish();
                }),
            }));
        let writing;
        let cancelling;
        try {
            writing = put(signed.url, content);
            await entered;
            cancelling = Promise.resolve(requestAs(
                ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`));
            await waitFor(async () => {
                const [{ blocked }] = await prisma.$queryRaw`
                    SELECT EXISTS (
                        SELECT 1 FROM pg_stat_activity
                        WHERE datname = current_database() AND wait_event_type = 'Lock'
                          AND query LIKE '%SELECT id, status FROM users WHERE id =%FOR UPDATE%'
                    ) AS blocked`;
                return blocked;
            });
        } finally {
            releasePublication();
            spy.mockRestore();
        }
        const uploaded = await writing;
        expect(uploaded.statusCode, uploaded.body).toBe(200);
        const cancelled = await cancelling;
        expect(cancelled.statusCode, cancelled.body).toBe(200);
        expect(await storage.listParts(session.id)).toMatchObject([{ partNumber: 1, sha256: sha256(content) }]);
        expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(1);
    });

    it('preserves and reconciles a published part when its transaction fails before cancellation', async () => {
        const content = Buffer.from('publication survives rollback');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const session = await createSession(content, reserved.json().asset.id);
        const signed = await sign(session.id);
        const originalUploadPart = storage.uploadPart;
        const spy = vi.spyOn(storage, 'uploadPart').mockImplementation((id, part, body, options) =>
            originalUploadPart.call(storage, id, part, body, {
                ...options,
                commitPart: (result, publish) => options.commitPart(result, async () => {
                    await publish();
                    throw new Error('injected failure after part publication');
                }),
            }));
        try {
            const failed = await put(signed.url, content);
            expect(failed.statusCode, failed.body).toBe(500);
        } finally {
            spy.mockRestore();
        }
        expect(await storage.listParts(session.id)).toMatchObject([{ partNumber: 1, sha256: sha256(content) }]);
        expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(0);
        const cancelled = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
        expect(cancelled.statusCode, cancelled.body).toBe(200);
        const deniedSign = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/parts/1/sign`);
        expect(deniedSign.statusCode, deniedSign.body).toBe(410);
        expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(0);
        const resumed = await requestAs(ownerId, 'GET', `/api/upload-sessions/${session.id}`);
        expect(resumed.statusCode, resumed.body).toBe(200);
        expect(resumed.json().uploadSession.parts).toMatchObject([{ partNumber: 1, sha256: sha256(content) }]);
        expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(1);
    });

    async function handoffService() {
        const { createUploadSessionService } = await import('../lib/upload-sessions.js');
        const { enqueueMuxOriginal } = await import('../lib/mux-original-records.js');
        return createUploadSessionService({
            db: prisma, storage, capacity: unrestrictedTestCapacity, now: () => new Date(currentTime),
            onCompleted: enqueueMuxOriginal,
        });
    }

    async function stagedOpenWithHandoff(content) {
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const { createStorageCapacity } = await import('../lib/storage/capacity.js');
        const { createUploadSessionService } = await import('../lib/upload-sessions.js');
        const { enqueueMuxOriginal } = await import('../lib/mux-original-records.js');
        const { default: uploadSessionRoutes } = await import('../routes/upload-sessions.js');
        const { authenticate } = await import('../lib/authentication.js');
        const { requireRole } = await import('../lib/authorization.js');
        const capacity = createStorageCapacity({
            db: prisma, storage, maxStorageBytes: 10n * 1024n * 1024n * 1024n, minFreeBytes: 1n,
        });
        const service = createUploadSessionService({ db: prisma, storage, capacity, now: () => new Date(currentTime) });
        const session = await service.create({
            ownerId, assetId: reservedAssetId, clipId: randomUUID(), initializeClip: true,
            expectedSizeBytes: content.length, expectedSha256: sha256(content),
        });
        await service.uploadPart({
            ownerId, uploadSessionId: session.id, partNumber: 1, body: content, expectedSizeBytes: content.length,
        });
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        expect(row.storageReservationBytes).toBeGreaterThan(0n);
        const parts = await prisma.uploadPart.findMany({ where: { uploadSessionId: session.id } });
        expect(parts).toHaveLength(1);
        const sessionPath = path.join(storageRoot, '.uploads', session.id);
        const manifest = await readFile(path.join(sessionPath, 'manifest.json'));
        const handoffApp = Fastify({ logger: false });
        await handoffApp.register(fastifyJwt, { secret: 'integration-jwt-secret' });
        handoffApp.decorate('authenticate', authenticate);
        handoffApp.decorate('requireRole', requireRole);
        await handoffApp.register(uploadSessionRoutes, {
            db: prisma, storage, capacity, signingSecret, now: () => new Date(currentTime),
            handoff: { onCompleted: enqueueMuxOriginal },
        });
        const complete = () => handoffApp.inject({
            method: 'POST', url: `/api/upload-sessions/${session.id}/complete`,
            headers: { authorization: `Bearer ${tokens[ownerId]}` },
        });
        const assertRetained = async expectedRow => {
            expect(await readFile(path.join(sessionPath, 'parts', '00001'))).toEqual(content);
            expect(await readFile(path.join(sessionPath, 'manifest.json'))).toEqual(manifest);
            expect(await prisma.uploadPart.findMany({ where: { uploadSessionId: session.id } })).toEqual(parts);
            expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toEqual(expectedRow);
            expect(await storage.stat(row.storageKey)).toBeNull();
            expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } })).toBeNull();
            expect(await prisma.storageWriteLease.count({ where: { uploadSessionId: session.id } })).toBe(0);
        };
        return { payload, session, row, complete, assertRetained, handoffApp };
    }

    async function allowLegacyMissingClipSha(clipId, enabled) {
        if (!enabled) return async () => {};
        // Simulate legacy or corrupted rows that the current schema rejects.
        await prisma.$executeRaw`ALTER TABLE clips DROP CONSTRAINT clips_storage_metadata_check`;
        return async () => {
            await prisma.clip.updateMany({ where: { id: clipId, sha256: null }, data: { storageKey: null } });
            await prisma.$executeRaw`ALTER TABLE clips ADD CONSTRAINT clips_storage_metadata_check
                CHECK (storage_key IS NULL OR (storage_driver IS NOT NULL AND sha256 IS NOT NULL))`;
        };
    }

    it.each([
        ['storage key', row => ({
            storageKey: `${row.storageKey.slice(0, row.storageKey.lastIndexOf('.') + 1)}${randomUUID()}`,
            storageDriver: row.storageDriver, sha256: row.expectedSha256,
        })],
        ['storage driver', row => ({
            storageKey: row.storageKey, storageDriver: 'other', sha256: row.expectedSha256,
        })],
        ['storage URL', () => ({ storageUrl: 'https://example.test/other-original' })],
        ['Mux upload', () => ({ muxUploadId: 'other-upload' })],
        ['Mux asset', () => ({ muxAssetId: 'other-asset' })],
        ['empty storage key', row => ({ storageKey: '', storageDriver: row.storageDriver, sha256: row.expectedSha256 })],
        ['empty storage driver', row => ({ storageKey: row.storageKey, storageDriver: '', sha256: row.expectedSha256 })],
        ['empty storage URL', () => ({ storageUrl: '' })],
        ['empty Mux upload', () => ({ muxUploadId: '' })],
        ['empty Mux asset', () => ({ muxAssetId: '' })],
    ])('retains an OPEN upload before publication on a %s conflict', async (label, conflict) => {
        const content = Buffer.from(`open reference conflict: ${label}`);
        const { session, row, complete, assertRetained, handoffApp } = await stagedOpenWithHandoff(content);
        try {
            const conflictingClip = await prisma.clip.update({
                where: { id: session.clipId }, data: conflict(row),
            });
            const response = await complete();
            expect(response.statusCode, response.body).toBe(503);
            expect(response.json()).toEqual({
                error: ['storage driver', 'empty storage key', 'empty storage driver'].includes(label)
                    ? 'Original storage references require recovery'
                    : 'Upload completion references require manual review',
            });
            await assertRetained(row);
            expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toEqual(conflictingClip);

            await prisma.clip.update({
                where: { id: session.clipId },
                data: {
                    storageKey: null, storageDriver: null, sha256: null, storageUrl: null,
                    muxUploadId: null, muxAssetId: null,
                },
            });
            const repaired = await complete();
            expect(repaired.statusCode, repaired.body).toBe(200);
            expect(repaired.json().uploadSession.status).toBe('COMPLETED');
            expect(await readFile(path.join(storageRoot, row.storageKey))).toEqual(content);
            expect(await storage.hasUpload(session.id)).toBe(false);
            expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toMatchObject({
                status: 'COMPLETED', storageReservationBytes: 0n,
            });
            expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } }))
                .toMatchObject({ status: 'QUEUED' });
            expect((await complete()).statusCode).toBe(200);
            expect(await prisma.muxIngestJob.count({ where: { uploadSessionId: session.id } })).toBe(1);
        } finally {
            await handoffApp.close();
        }
    });

    it('preserves cancellation precedence over an OPEN clip reference conflict', async () => {
        const content = Buffer.from('cancelled clip conflict');
        const { payload, session, row, complete, assertRetained, handoffApp } = await stagedOpenWithHandoff(content);
        try {
            await prisma.clip.update({ where: { id: session.clipId }, data: { muxUploadId: 'other-upload' } });
            const cancelled = await requestAs(
                ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
            expect(cancelled.statusCode, cancelled.body).toBe(200);
            const response = await complete();
            expect(response.statusCode, response.body).toBe(410);
            await assertRetained(row);
        } finally {
            await handoffApp.close();
        }
    });

    it.each(['matching reference', 'null key with driver'])(
        'allows an OPEN completion with %s and a completed retry', async mode => {
            const content = Buffer.from(`legitimate ${mode}`);
            const { session, row, complete, handoffApp } = await stagedOpenWithHandoff(content);
            try {
                await prisma.clip.update({
                    where: { id: session.clipId },
                    data: mode === 'matching reference'
                        ? { storageKey: row.storageKey, storageDriver: row.storageDriver,
                            sha256: sha256(content), fileSize: BigInt(content.length) }
                        : { storageDriver: 'other' },
                });
                const response = await complete();
                expect(response.statusCode, response.body).toBe(200);
                expect(response.json().uploadSession.status).toBe('COMPLETED');
                expect(await readFile(path.join(storageRoot, row.storageKey))).toEqual(content);
                expect(await storage.hasUpload(session.id)).toBe(false);
                expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject({
                    storageKey: row.storageKey, storageDriver: row.storageDriver,
                    sha256: sha256(content), fileSize: BigInt(content.length),
                });
                expect((await complete()).statusCode).toBe(200);
                expect(await prisma.muxIngestJob.count({ where: { uploadSessionId: session.id } })).toBe(1);
            } finally {
                await handoffApp.close();
            }
        },
    );

    it.each([
        ['wrong SHA', { sha256: 'a'.repeat(64) }],
        ['missing SHA', { sha256: null }],
        ['wrong size', { fileSize: 1n }],
        ['missing size', { fileSize: null }],
        ['missing expected SHA', {}, { expectedSha256: null }],
        ['missing expected size', {}, { expectedSizeBytes: null }],
    ])('retains an OPEN same-key upload with %s before publication', async (label, conflict, sessionChange) => {
        const content = Buffer.from(`same-key integrity ${label}`);
        const { session, row, complete, assertRetained, handoffApp } = await stagedOpenWithHandoff(content);
        const restoreConstraint = await allowLegacyMissingClipSha(session.clipId, label === 'missing SHA');
        try {
            const clip = await prisma.clip.update({
                where: { id: session.clipId },
                data: { storageKey: row.storageKey, storageDriver: row.storageDriver,
                    sha256: sha256(content), fileSize: BigInt(content.length), ...conflict },
            });
            const expected = sessionChange
                ? await prisma.uploadSession.update({ where: { id: session.id }, data: sessionChange })
                : row;
            if (sessionChange?.expectedSizeBytes === null) {
                const { createUploadSessionService } = await import('../lib/upload-sessions.js');
                const service = createUploadSessionService({
                    db: prisma, storage, capacity: unrestrictedTestCapacity, now: () => new Date(currentTime),
                });
                await expect(service.complete({ ownerId, uploadSessionId: session.id })).rejects.toMatchObject({
                    code: 'STORAGE_UNAVAILABLE', message: 'Upload completion references require manual review',
                });
            } else {
                const response = await complete();
                expect(response.statusCode, response.body).toBe(503);
                expect(response.json()).toEqual({ error: 'Upload completion references require manual review' });
            }
            await assertRetained(expected);
            expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toEqual(clip);
            await prisma.uploadSession.update({
                where: { id: session.id },
                data: { expectedSha256: row.expectedSha256, expectedSizeBytes: row.expectedSizeBytes },
            });
            await prisma.clip.update({
                where: { id: session.clipId }, data: { sha256: sha256(content), fileSize: BigInt(content.length) },
            });
            expect((await complete()).statusCode).toBe(200);
            expect((await complete()).statusCode).toBe(200);
            expect(await prisma.muxIngestJob.count({ where: { uploadSessionId: session.id } })).toBe(1);
        } finally {
            await restoreConstraint();
            await handoffApp.close();
        }
    });

    it.each(['clipId', 'storageKey', 'storageDriver', 'expectedSizeBytes', 'expectedSha256'])(
        'rejects an OPEN completion when locked session %s changed after its snapshot', async field => {
            const content = Buffer.from(`changed session ${field}`);
            const { session, row, complete, assertRetained, handoffApp } = await stagedOpenWithHandoff(content);
            const replacementClipId = randomUUID();
            if (field === 'clipId') await prisma.clip.create({
                data: { id: replacementClipId, assetId: row.assetId, status: 'UPLOADING' },
            });
            const value = {
                clipId: replacementClipId, storageKey: `${row.storageKey}-other`, storageDriver: 'other',
                expectedSizeBytes: row.expectedSizeBytes + 1n, expectedSha256: 'a'.repeat(64),
            }[field];
            let reportLocked;
            let releaseChange;
            const locked = new Promise(resolve => { reportLocked = resolve; });
            const release = new Promise(resolve => { releaseChange = resolve; });
            const changing = prisma.$transaction(async tx => {
                const [backend] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
                await tx.$queryRaw`SELECT id FROM upload_sessions WHERE id = ${session.id} FOR UPDATE`;
                reportLocked(backend.pid);
                await release;
                return tx.uploadSession.update({ where: { id: session.id }, data: { [field]: value } });
            }, { timeout: 15_000 });
            let completion;
            try {
                const pid = await Promise.race([
                    locked, changing.then(() => { throw new Error('Session lock did not pause'); }),
                ]);
                completion = complete();
                await blockedQueryBy(pid, 'SELECT id FROM upload_sessions');
                releaseChange();
                const response = await completion;
                expect(response.statusCode, response.body).toBe(field === 'clipId' ? 409 : 503);
                const changed = await changing;
                expect(changed).toEqual({ ...row, [field]: value, updatedAt: expect.any(Date) });
                await assertRetained(changed);
                expect((await prisma.clip.findUnique({ where: { id: session.clipId } })).storageKey).toBeNull();
                if (field === 'clipId') {
                    expect((await prisma.clip.findUnique({ where: { id: replacementClipId } })).storageKey).toBeNull();
                }
                await prisma.uploadSession.update({ where: { id: session.id }, data: { [field]: row[field] } });
                const repaired = await complete();
                expect(repaired.statusCode, repaired.body).toBe(200);
                expect(await readFile(path.join(storageRoot, row.storageKey))).toEqual(content);
            } finally {
                releaseChange();
                await Promise.allSettled([changing, completion].filter(Boolean));
                await handoffApp.close();
            }
        }, 20_000,
    );

    it.each(['storage key', 'storage driver', 'Mux upload', 'SHA', 'missing SHA', 'size', 'missing size'])(
        'rechecks locked clip %s after waiting for a conflicting update', async field => {
            const content = Buffer.from(`locked clip ${field} changed`);
            const { session, row, complete, assertRetained, handoffApp } = await stagedOpenWithHandoff(content);
            const restoreConstraint = await allowLegacyMissingClipSha(session.clipId, field === 'missing SHA');
            if (['SHA', 'missing SHA', 'size', 'missing size'].includes(field)) {
                await prisma.clip.update({ where: { id: session.clipId }, data: {
                    storageKey: row.storageKey, storageDriver: row.storageDriver,
                    sha256: sha256(content), fileSize: BigInt(content.length),
                } });
            }
            const conflict = field === 'storage key'
                ? { storageKey: `${row.storageKey.slice(0, row.storageKey.lastIndexOf('.') + 1)}${randomUUID()}`,
                    storageDriver: row.storageDriver, sha256: row.expectedSha256 }
                : field === 'storage driver'
                    ? { storageKey: row.storageKey, storageDriver: 'other', sha256: row.expectedSha256 }
                    : field === 'Mux upload' ? { muxUploadId: 'changed-upload' }
                        : field === 'SHA' ? { sha256: 'a'.repeat(64) }
                            : field === 'missing SHA' ? { sha256: null }
                                : field === 'size' ? { fileSize: 1n } : { fileSize: null };
            let reportLocked;
            let releaseChange;
            const locked = new Promise(resolve => { reportLocked = resolve; });
            const release = new Promise(resolve => { releaseChange = resolve; });
            const changing = prisma.$transaction(async tx => {
                const [backend] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
                await tx.$queryRaw`SELECT id FROM clips WHERE id = ${session.clipId} FOR UPDATE`;
                reportLocked(backend.pid);
                await release;
                return tx.clip.update({ where: { id: session.clipId }, data: conflict });
            }, { timeout: 15_000 });
            let completion;
            try {
                const pid = await Promise.race([
                    locked, changing.then(() => { throw new Error('Clip lock did not pause'); }),
                ]);
                completion = complete();
                await blockedQueryBy(pid, 'SELECT id FROM clips');
                releaseChange();
                const response = await completion;
                expect(response.statusCode, response.body).toBe(503);
                expect(response.json()).toEqual({ error: 'Upload completion references require manual review' });
                const changed = await changing;
                await assertRetained(row);
                expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toEqual(changed);
                await prisma.clip.update({
                    where: { id: session.clipId },
                    data: { storageKey: null, storageDriver: null, sha256: null, muxUploadId: null },
                });
                const repaired = await complete();
                expect(repaired.statusCode, repaired.body).toBe(200);
                expect(await readFile(path.join(storageRoot, row.storageKey))).toEqual(content);
            } finally {
                releaseChange();
                await Promise.allSettled([changing, completion].filter(Boolean));
                await restoreConstraint();
                await handoffApp.close();
            }
        }, 20_000,
    );

    it('does not expose a foreign clip through an inconsistent session', async () => {
        const content = Buffer.from('foreign clip reference');
        const { session, reservedAssetId } = await stagedReservedOriginal(content);
        const foreignAssetId = randomUUID();
        const foreignClipId = randomUUID();
        await prisma.asset.create({
            data: {
                id: foreignAssetId, userId: otherId, status: 'UPLOADING',
                clips: { create: { id: foreignClipId, status: 'UPLOADING' } },
            },
        });
        await prisma.uploadSession.update({ where: { id: session.id }, data: { clipId: foreignClipId } });
        const url = `/api/upload-sessions/${session.id}`;
        const response = await requestAs(ownerId, 'GET', url);
        expect(response.statusCode, response.body).toBe(409);
        expect(response.json()).toEqual({ error: 'Upload session clip does not belong to its asset' });
        for (const id of [session.id, session.clipId, reservedAssetId, foreignAssetId, foreignClipId]) {
            expect(response.body).not.toContain(id);
        }
        expect((await requestAs(otherId, 'GET', url)).statusCode).toBe(404);
        await prisma.asset.update({
            where: { id: reservedAssetId }, data: { moderation: 'FLAGGED_FOR_REMOVAL' },
        });
        expect((await requestAs(ownerId, 'GET', url)).statusCode).toBe(404);
        await prisma.asset.update({ where: { id: reservedAssetId }, data: { moderation: 'ACTIVE' } });
        await prisma.uploadSession.update({ where: { id: session.id }, data: { clipId: session.clipId } });
        const repaired = await requestAs(ownerId, 'GET', url);
        expect(repaired.statusCode, repaired.body).toBe(200);
        expect(repaired.json().uploadSession.clipId).toBe(session.clipId);
        expect(await readFile(path.join(storageRoot, '.uploads', session.id, 'parts', '00001'))).toEqual(content);
    });

    it.each([true, false])('preserves staged evidence during inconsistent recovery (published: %s)', async published => {
        const content = Buffer.from('published before crash with staged evidence');
        const { session, reservedAssetId } = await stagedReservedOriginal(content);
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        const stagedPath = path.join(storageRoot, '.uploads', session.id, 'parts', '00001');
        const publishedPath = path.join(storageRoot, row.storageKey);
        if (published) {
            await mkdir(path.dirname(publishedPath), { recursive: true });
            await link(stagedPath, publishedPath);
        }
        await prisma.uploadSession.update({ where: { id: session.id }, data: { status: 'COMPLETING' } });
        const otherAssetId = randomUUID();
        await prisma.asset.create({ data: { id: otherAssetId, userId: ownerId, status: 'UPLOADING' } });
        await prisma.clip.update({ where: { id: session.clipId }, data: { assetId: otherAssetId } });

        const url = `/api/upload-sessions/${session.id}`;
        for (const [method, target] of [['GET', url], ['POST', `${url}/complete`], ['DELETE', url]]) {
            const response = await requestAs(ownerId, method, target);
            expect(response.statusCode, response.body).toBe(409);
            expect(response.json()).toEqual({ error: 'Upload session clip does not belong to its asset' });
            for (const id of [session.id, session.clipId, reservedAssetId, otherAssetId]) {
                expect(response.body).not.toContain(id);
            }
        }
        expect((await requestAs(otherId, 'GET', url)).statusCode).toBe(404);

        const { createUploadSessionRecovery } = await import('../lib/upload-sessions.js');
        const recovery = createUploadSessionRecovery({ db: prisma, storage, now: () => new Date(currentTime) });
        await expect(withAssetMediaLock(reservedAssetId, assertLocked => recovery.recoverForSweep({
            ownerId, assetId: reservedAssetId, uploadSessionId: session.id, assertLocked,
        }))).rejects.toMatchObject({ code: 'STORAGE_UNAVAILABLE' });

        // Simulate stale outer snapshots while the recovery's own reload sees the pre-existing mismatch.
        let reads = 0;
        const dbWithStaleSnapshots = new Proxy(prisma, {
            get(target, property) {
                if (property !== 'uploadSession') return Reflect.get(target, property, target);
                return new Proxy(target.uploadSession, {
                    get(delegate, method) {
                        if (method !== 'findFirst') return Reflect.get(delegate, method, delegate);
                        return async (...args) => {
                            const result = await delegate.findFirst(...args);
                            reads += 1;
                            if (reads <= 2 && result) return { ...result, clip: { ...result.clip, assetId: reservedAssetId } };
                            return result;
                        };
                    },
                });
            },
        });
        const recoveryWithStaleSnapshots = createUploadSessionRecovery({
            db: dbWithStaleSnapshots, storage, now: () => new Date(currentTime),
        });
        await expect(withAssetMediaLock(reservedAssetId, assertLocked => recoveryWithStaleSnapshots.recoverForSweep({
            ownerId, assetId: reservedAssetId, uploadSessionId: session.id, assertLocked,
        }))).rejects.toMatchObject({ code: 'INVALID_STATE' });
        expect(reads).toBe(3);

        expect(await readFile(stagedPath)).toEqual(content);
        if (published) expect(await readFile(publishedPath)).toEqual(content);
        else expect(await storage.stat(row.storageKey)).toBeNull();
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toMatchObject({
            status: 'COMPLETING', storageReservationBytes: row.storageReservationBytes,
        });
        expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(1);
        expect((await prisma.clip.findUnique({ where: { id: session.clipId } })).storageKey).toBeNull();

        await prisma.clip.update({ where: { id: session.clipId }, data: { assetId: reservedAssetId } });
        const recovered = await requestAs(ownerId, 'GET', url);
        expect(recovered.statusCode, recovered.body).toBe(200);
        expect(recovered.json().uploadSession.status).toBe(published ? 'COMPLETED' : 'OPEN');
        const retry = await requestAs(ownerId, 'POST', `${url}/complete`);
        expect(retry.statusCode, retry.body).toBe(200);
        expect(retry.json().uploadSession.status).toBe('COMPLETED');
        expect(await storage.hasUpload(session.id)).toBe(false);
        expect(await readFile(publishedPath)).toEqual(content);
        expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject({
            storageKey: row.storageKey, sha256: sha256(content), fileSize: BigInt(content.length),
        });
    });

    it.each([
        ['storage key', row => ({
            storageKey: `${row.storageKey}-other`, storageDriver: row.storageDriver, sha256: row.expectedSha256,
        }), false, 'GET'],
        ['storage driver', row => ({
            storageKey: row.storageKey, storageDriver: 'other', sha256: row.expectedSha256,
        }), true, 'POST'],
        ['storage URL', row => ({
            storageKey: row.storageKey, storageDriver: row.storageDriver, sha256: row.expectedSha256,
            storageUrl: 'https://example.test/other-original',
        }), false, 'DELETE'],
        ['Mux upload', row => ({
            storageKey: row.storageKey, storageDriver: row.storageDriver, sha256: row.expectedSha256,
            muxUploadId: 'conflicting-mux-upload',
        }), true, 'GET'],
        ['Mux asset', () => ({ muxAssetId: 'conflicting-mux-asset' }), false, 'POST'],
        ['empty storage key', row => ({
            storageKey: '', storageDriver: row.storageDriver, sha256: row.expectedSha256,
        }), false, 'GET'],
        ['empty storage driver', row => ({
            storageKey: row.storageKey, storageDriver: '', sha256: row.expectedSha256,
        }), true, 'POST'],
        ['empty storage URL', () => ({ storageUrl: '' }), false, 'GET'],
        ['empty Mux upload', () => ({ muxUploadId: '' }), false, 'GET'],
        ['empty Mux asset', () => ({ muxAssetId: '' }), false, 'GET'],
    ])('retains published and staged originals on a static %s conflict', async (_label, conflict, alreadyReferenced, retryMethod) => {
        const content = Buffer.from(`published and staged ${_label}`);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', originalReservation(content));
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const { createStorageCapacity } = await import('../lib/storage/capacity.js');
        const { createUploadSessionService, createUploadSessionRecovery } = await import('../lib/upload-sessions.js');
        const { enqueueMuxOriginal } = await import('../lib/mux-original-records.js');
        const { default: uploadSessionRoutes } = await import('../routes/upload-sessions.js');
        const { authenticate } = await import('../lib/authentication.js');
        const { requireRole } = await import('../lib/authorization.js');
        const capacity = createStorageCapacity({
            db: prisma, storage, maxStorageBytes: 10n * 1024n * 1024n * 1024n, minFreeBytes: 1n,
        });
        const service = createUploadSessionService({ db: prisma, storage, capacity, now: () => new Date(currentTime) });
        const session = await service.create({
            ownerId, assetId: reservedAssetId, clipId: randomUUID(), initializeClip: true,
            expectedSizeBytes: content.length, expectedSha256: sha256(content),
        });
        await service.uploadPart({
            ownerId, uploadSessionId: session.id, partNumber: 1, body: content, expectedSizeBytes: content.length,
        });
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        expect(row.storageReservationBytes).toBeGreaterThan(0n);
        const parts = await prisma.uploadPart.findMany({ where: { uploadSessionId: session.id } });
        expect(parts).toHaveLength(1);
        const stagedPath = path.join(storageRoot, '.uploads', session.id, 'parts', '00001');
        const publishedPath = path.join(storageRoot, row.storageKey);
        await mkdir(path.dirname(publishedPath), { recursive: true });
        await writeFile(publishedPath, content);
        await prisma.uploadSession.update({ where: { id: session.id }, data: { status: 'COMPLETING' } });
        await prisma.clip.update({ where: { id: session.clipId }, data: conflict(row) });
        const completing = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        const conflictingClip = await prisma.clip.findUnique({ where: { id: session.clipId } });

        const handoffApp = Fastify({ logger: false });
        try {
            await handoffApp.register(fastifyJwt, { secret: 'integration-jwt-secret' });
            handoffApp.decorate('authenticate', authenticate);
            handoffApp.decorate('requireRole', requireRole);
            await handoffApp.register(uploadSessionRoutes, {
                db: prisma, storage, capacity, signingSecret, now: () => new Date(currentTime),
                handoff: { onCompleted: enqueueMuxOriginal },
            });
            const url = `/api/upload-sessions/${session.id}`;
            const request = (method, target) => handoffApp.inject({
                method, url: target, headers: { authorization: `Bearer ${tokens[ownerId]}` },
            });
            const assertRetained = async () => {
                expect(await readFile(stagedPath)).toEqual(content);
                expect(await readFile(publishedPath)).toEqual(content);
                expect(await prisma.uploadPart.findMany({ where: { uploadSessionId: session.id } })).toEqual(parts);
                expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toEqual(completing);
                expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toEqual(conflictingClip);
                expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } })).toBeNull();
            };
            for (const [method, target] of [['GET', url], ['POST', `${url}/complete`], ['DELETE', url]]) {
                const response = await request(method, target);
                if (response.statusCode !== 503) await assertRetained();
                expect(response.statusCode, response.body).toBe(503);
                expect(response.json()).toEqual({ error: 'Upload completion references require manual review' });
                for (const id of [
                    ownerId, reservedAssetId, session.id, session.clipId, row.storageKey,
                    conflictingClip.storageKey, conflictingClip.storageUrl,
                    conflictingClip.muxUploadId, conflictingClip.muxAssetId,
                ].filter(Boolean)) {
                    expect(response.body).not.toContain(id);
                }
                await assertRetained();
            }
            const recovery = createUploadSessionRecovery({ db: prisma, storage, now: () => new Date(currentTime) });
            await expect(withAssetMediaLock(reservedAssetId, assertLocked => recovery.recoverForSweep({
                ownerId, assetId: reservedAssetId, uploadSessionId: session.id, assertLocked,
            }))).rejects.toMatchObject({ code: 'STORAGE_UNAVAILABLE' });
            await assertRetained();

            await prisma.clip.update({
                where: { id: session.clipId },
                data: {
                    storageKey: alreadyReferenced ? row.storageKey : null,
                    storageDriver: alreadyReferenced ? row.storageDriver : null,
                    sha256: alreadyReferenced ? sha256(content) : null,
                    fileSize: alreadyReferenced ? BigInt(content.length) : null,
                    storageUrl: null, muxUploadId: null, muxAssetId: null,
                },
            });
            const recovered = await request(retryMethod, retryMethod === 'POST' ? `${url}/complete` : url);
            if (retryMethod === 'DELETE') {
                expect(recovered.statusCode, recovered.body).toBe(409);
                expect(recovered.json()).toEqual({ error: 'Completed originals cannot be aborted' });
            } else {
                expect(recovered.statusCode, recovered.body).toBe(200);
                expect(recovered.json().uploadSession.status).toBe('COMPLETED');
            }
            expect(await storage.hasUpload(session.id)).toBe(false);
            expect(await readFile(publishedPath)).toEqual(content);
            expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toMatchObject({
                status: 'COMPLETED', storageReservationBytes: 0n,
            });
            expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject({
                storageKey: row.storageKey, storageDriver: row.storageDriver,
                sha256: sha256(content), fileSize: BigInt(content.length),
            });
            expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } })).not.toBeNull();
        } finally {
            await handoffApp.close();
        }
    });

    it.each([
        ['wrong SHA', { sha256: 'a'.repeat(64) }, false],
        ['missing SHA', { sha256: null }, false],
        ['wrong size', { fileSize: 1n }, false],
        ['missing size', { fileSize: null }, false],
        ['legacy wrong SHA', { sha256: 'a'.repeat(64) }, true],
        ['legacy missing SHA', { sha256: null }, true],
        ['legacy missing size', { fileSize: null }, true],
    ])('retains same-key staged evidence during recovery with %s', async (label, conflict, legacy) => {
        const content = Buffer.from(`recovery integrity ${label}`);
        const { session, row, complete, handoffApp } = await stagedOpenWithHandoff(content);
        const stagedPath = path.join(storageRoot, '.uploads', session.id, 'parts', '00001');
        const publishedPath = path.join(storageRoot, row.storageKey);
        const restoreConstraint = await allowLegacyMissingClipSha(session.clipId, label.includes('missing SHA'));
        try {
            await mkdir(path.dirname(publishedPath), { recursive: true });
            await link(stagedPath, publishedPath);
            const completing = await prisma.uploadSession.update({
                where: { id: session.id },
                data: { status: 'COMPLETING', ...(legacy ? { expectedSha256: null } : {}) },
            });
            const clip = await prisma.clip.update({ where: { id: session.clipId }, data: {
                storageKey: row.storageKey, storageDriver: row.storageDriver,
                sha256: sha256(content), fileSize: BigInt(content.length), ...conflict,
            } });
            const { createUploadSessionRecovery } = await import('../lib/upload-sessions.js');
            const recovery = createUploadSessionRecovery({ db: prisma, storage, now: () => new Date(currentTime) });
            const response = await complete();
            expect(response.statusCode, response.body).toBe(label === 'legacy wrong SHA' ? 422 : 503);
            await expect(withAssetMediaLock(row.assetId, assertLocked => recovery.recoverForSweep({
                ownerId, assetId: row.assetId, uploadSessionId: session.id, assertLocked,
            }))).rejects.toMatchObject({
                code: label === 'legacy wrong SHA' ? 'INTEGRITY_MISMATCH' : 'STORAGE_UNAVAILABLE',
            });
            expect(await readFile(stagedPath)).toEqual(content);
            expect(await readFile(publishedPath)).toEqual(content);
            expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toEqual(completing);
            expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toEqual(clip);
            expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } })).toBeNull();
            await prisma.clip.update({ where: { id: session.clipId }, data: {
                sha256: sha256(content), fileSize: BigInt(content.length),
            } });
            expect((await complete()).statusCode).toBe(200);
            expect((await complete()).statusCode).toBe(200);
            expect(await storage.hasUpload(session.id)).toBe(false);
        } finally {
            await restoreConstraint();
            await handoffApp.close();
        }
    });

    it.each([
        ['wrong SHA', { sha256: 'a'.repeat(64) }],
        ['missing size', { fileSize: null }],
    ])('retains unpublished same-key staging during recovery with %s', async (label, conflict) => {
        const content = Buffer.from(`unpublished recovery ${label}`);
        const { session, row, complete, assertRetained, handoffApp } = await stagedOpenWithHandoff(content);
        try {
            const completing = await prisma.uploadSession.update({
                where: { id: session.id }, data: { status: 'COMPLETING' },
            });
            await prisma.clip.update({ where: { id: session.clipId }, data: {
                storageKey: row.storageKey, storageDriver: row.storageDriver,
                sha256: sha256(content), fileSize: BigInt(content.length), ...conflict,
            } });
            const response = await complete();
            expect(response.statusCode, response.body).toBe(503);
            await assertRetained(completing);
            await prisma.clip.update({ where: { id: session.clipId }, data: {
                sha256: sha256(content), fileSize: BigInt(content.length),
            } });
            expect((await complete()).statusCode).toBe(200);
        } finally {
            await handoffApp.close();
        }
    });

    it('recovers a verified same-key legacy clip without expected size or SHA', async () => {
        const content = Buffer.from('legacy verified clip');
        const { session, row, complete, handoffApp } = await stagedOpenWithHandoff(content);
        const stagedPath = path.join(storageRoot, '.uploads', session.id, 'parts', '00001');
        const publishedPath = path.join(storageRoot, row.storageKey);
        try {
            await mkdir(path.dirname(publishedPath), { recursive: true });
            await link(stagedPath, publishedPath);
            await prisma.uploadSession.update({ where: { id: session.id }, data: {
                status: 'COMPLETING', expectedSizeBytes: null, expectedSha256: null,
            } });
            await prisma.clip.update({ where: { id: session.clipId }, data: {
                storageKey: row.storageKey, storageDriver: row.storageDriver,
                sha256: sha256(content), fileSize: BigInt(content.length),
            } });
            const response = await complete();
            expect(response.statusCode, response.body).toBe(200);
            expect((await complete()).statusCode).toBe(200);
            expect(await storage.hasUpload(session.id)).toBe(false);
            expect(await readFile(publishedPath)).toEqual(content);
            expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject({
                sha256: sha256(content), fileSize: BigInt(content.length),
            });
            expect(await prisma.muxIngestJob.count({ where: { uploadSessionId: session.id } })).toBe(1);
        } finally {
            await handoffApp.close();
        }
    });

    it.each([
        ['a conflicting SHA is repaired', { sha256: 'a'.repeat(64) }, true],
        ['a conflicting size is repaired', { fileSize: 1n }, true],
        ['a correct SHA becomes conflicting', { sha256: 'a'.repeat(64) }, false],
        ['a correct size becomes conflicting', { fileSize: 1n }, false],
    ])('uses the locked clip when %s while completion waits', async (label, conflict, repaired) => {
        const content = Buffer.from(`locked integrity ${label} ${repaired}`);
        const { session, row, complete, assertRetained, handoffApp } = await stagedOpenWithHandoff(content);
        const correct = {
            storageKey: row.storageKey, storageDriver: row.storageDriver,
            sha256: sha256(content), fileSize: BigInt(content.length),
        };
        let releaseClip;
        const release = new Promise(resolve => { releaseClip = resolve; });
        let reportLocked;
        const locked = new Promise(resolve => { reportLocked = resolve; });
        let changing;
        let completion;
        try {
            await prisma.clip.update({
                where: { id: session.clipId },
                data: repaired ? { ...correct, ...conflict } : correct,
            });
            changing = prisma.$transaction(async tx => {
                const [backend] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
                await tx.$queryRaw`SELECT id FROM clips WHERE id = ${session.clipId} FOR UPDATE`;
                reportLocked(backend.pid);
                await release;
                await tx.clip.update({
                    where: { id: session.clipId },
                    data: repaired ? correct : conflict,
                });
            }, { timeout: 15_000 });
            const pid = await Promise.race([
                locked, changing.then(() => { throw new Error('Clip lock did not pause'); }),
            ]);
            completion = complete();
            await blockedQueryBy(pid, 'SELECT id FROM clips');
            releaseClip();
            await changing;
            const response = await completion;
            if (repaired) {
                expect(response.statusCode, response.body).toBe(200);
                expect(response.json().uploadSession.status).toBe('COMPLETED');
                expect(await readFile(path.join(storageRoot, row.storageKey))).toEqual(content);
                expect(await storage.hasUpload(session.id)).toBe(false);
                expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toMatchObject({
                    status: 'COMPLETED', completedAt: expect.any(Date), storageReservationBytes: 0n,
                });
                expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject(correct);
                expect(await prisma.muxIngestJob.count({ where: { uploadSessionId: session.id } })).toBe(1);
                const retry = await complete();
                expect(retry.statusCode, retry.body).toBe(200);
                expect(retry.json().uploadSession.status).toBe('COMPLETED');
                expect(await readFile(path.join(storageRoot, row.storageKey))).toEqual(content);
                expect(await prisma.muxIngestJob.count({ where: { uploadSessionId: session.id } })).toBe(1);
            } else {
                expect(response.statusCode, response.body).toBe(503);
                expect(response.json()).toEqual({ error: 'Upload completion references require manual review' });
                for (const id of [ownerId, row.assetId, session.id, session.clipId, row.storageKey]) {
                    expect(response.body).not.toContain(id);
                }
                await assertRetained(row);
                expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject(conflict);
            }
        } finally {
            releaseClip();
            await Promise.allSettled([changing, completion].filter(Boolean));
            await handoffApp.close();
        }
    });

    it.each([
        ['missing size', { fileSize: null }],
        ['wrong size', { fileSize: 1n }],
        ['SHA', { sha256: 'a'.repeat(64) }],
        ['missing SHA', { sha256: null }],
        ['key', { storageKey: 'other' }],
        ['driver', { storageDriver: 'other' }],
        ['URL', { storageUrl: 'https://example.test/other' }],
        ['Mux upload', { muxUploadId: 'other' }],
        ['Mux asset', { muxAssetId: 'other' }],
    ])('does not falsely finalize a late same-key %s change', async (label, change) => {
        const content = Buffer.from(`late clip update ${label}`);
        const { session, row, handoffApp } = await stagedOpenWithHandoff(content);
        const restoreConstraint = await allowLegacyMissingClipSha(session.clipId, label === 'missing SHA');
        try {
            await prisma.clip.update({ where: { id: session.clipId }, data: {
                storageKey: row.storageKey, storageDriver: row.storageDriver,
                sha256: sha256(content), fileSize: BigInt(content.length),
            } });
            const changedStorage = new Proxy(storage, {
                get(target, property) {
                    if (property === 'completeUpload') return async (...args) => {
                        const result = await target.completeUpload(...args);
                        await prisma.clip.update({ where: { id: session.clipId }, data: change });
                        return result;
                    };
                    return Reflect.get(target, property, target);
                },
            });
            const { createUploadSessionService } = await import('../lib/upload-sessions.js');
            const service = createUploadSessionService({
                db: prisma, storage: changedStorage, capacity: unrestrictedTestCapacity,
                now: () => new Date(currentTime),
            });
            const result = expect(service.complete({ ownerId, uploadSessionId: session.id })).rejects;
            if (label === 'SHA' || label === 'wrong size') {
                await result.toMatchObject({ code: 'INTEGRITY_MISMATCH' });
            } else {
                await result.toBeDefined();
            }
            expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('COMPLETING');
            expect(await readFile(path.join(storageRoot, row.storageKey))).toEqual(content);
            expect(await storage.hasUpload(session.id)).toBe(false);
            expect(await prisma.clip.findUnique({ where: { id: session.clipId } })).toMatchObject(change);
            expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } })).toBeNull();
        } finally {
            await restoreConstraint();
            await handoffApp.close();
        }
    });

    it.each([
        ['size', { sizeBytes: '1' }, 'Completed upload size does not match the session'],
        ['SHA', { sha256: 'a'.repeat(64) }, 'Completed upload SHA-256 does not match the session'],
        ['malformed SHA', { sha256: 'invalid' }, 'Completed upload SHA-256 must contain 64 hexadecimal characters'],
    ])('still validates a completion with a %s mismatch against the session', async (label, change, message) => {
        const content = Buffer.from(`completion result ${label}`);
        const { session, row, handoffApp } = await stagedOpenWithHandoff(content);
        try {
            const changedStorage = new Proxy(storage, {
                get(target, property) {
                    if (property === 'completeUpload') return async (...args) => ({
                        ...await target.completeUpload(...args), ...change,
                    });
                    return Reflect.get(target, property, target);
                },
            });
            const { createUploadSessionService } = await import('../lib/upload-sessions.js');
            const { enqueueMuxOriginal } = await import('../lib/mux-original-records.js');
            const service = createUploadSessionService({
                db: prisma, storage: changedStorage, capacity: unrestrictedTestCapacity,
                now: () => new Date(currentTime), onCompleted: enqueueMuxOriginal,
            });
            await expect(service.complete({ ownerId, uploadSessionId: session.id })).rejects.toMatchObject({
                code: label === 'malformed SHA' ? 'INVALID_ARGUMENT' : 'INTEGRITY_MISMATCH', message,
            });
            expect(await readFile(path.join(storageRoot, row.storageKey))).toEqual(content);
            expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toMatchObject({
                status: 'COMPLETING', storageReservationBytes: row.storageReservationBytes,
            });
            expect((await prisma.clip.findUnique({ where: { id: session.clipId } })).storageKey).toBeNull();
            expect(await prisma.muxIngestJob.count({ where: { uploadSessionId: session.id } })).toBe(0);
        } finally {
            await handoffApp.close();
        }
    });

    it.each(['session-asset', 'clip-asset'])(
        'fences and withholds every page for an inconsistent %s cross-reference',
        async direction => {
            const content = Buffer.from(`inconsistent ${direction}`);
            const { payload, session, reservedAssetId } = await stagedReservedOriginal(content);
            const original = await prisma.uploadSession.findUnique({ where: { id: session.id } });
            const otherAssetId = randomUUID();
            const otherClipId = randomUUID();
            await prisma.asset.create({
                data: {
                    id: otherAssetId, userId: direction === 'session-asset' ? otherId : ownerId, status: 'UPLOADING',
                    clips: { create: { id: otherClipId, status: 'UPLOADING' } },
                },
            });
            await prisma.uploadSession.update({
                where: { id: session.id },
                data: direction === 'session-asset' ? { clipId: otherClipId } : { assetId: otherAssetId },
            });
            const serviceWithHandoff = await handoffService();
            await expect(serviceWithHandoff.complete({ ownerId, uploadSessionId: session.id }))
                .rejects.toMatchObject({ code: 'INVALID_STATE' });
            expect((await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode)
                .toBe(409);
            const cancelled = await requestAs(
                ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
            expect(cancelled.statusCode, cancelled.body).toBe(503);
            expect(cancelled.json()).toEqual({ error: 'Original upload intent cannot be verified' });
            const intent = await prisma.originalUploadIntent.findUnique({
                where: { userId_clientRequestId: { userId: ownerId, clientRequestId: payload.clientRequestId } },
            });
            expect(intent.cancelledAt).toBeInstanceOf(Date);
            const url = `/api/assets/original-uploads/${payload.clientRequestId}/sessions`;
            for (const suffix of ['', `?after=${session.id}`]) {
                const page = await requestAs(ownerId, 'GET', `${url}${suffix}`);
                expect(page.statusCode, page.body).toBe(503);
                expect(page.json()).toEqual({ error: 'Original upload intent cannot be verified' });
                for (const id of [reservedAssetId, otherAssetId, session.id, session.clipId, otherClipId]) {
                    expect(page.body).not.toContain(id);
                    expect(cancelled.body).not.toContain(id);
                }
            }
            const foreign = await requestAs(otherId, 'GET', url);
            expect(foreign.statusCode).toBe(404);
            expect(foreign.body).not.toContain(reservedAssetId);
            expect(foreign.body).not.toContain(session.id);
            await prisma.asset.update({
                where: { id: reservedAssetId }, data: { moderation: 'FLAGGED_FOR_REMOVAL' },
            });
            const hiddenCancel = await requestAs(
                ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
            const hiddenPage = await requestAs(ownerId, 'GET', url);
            for (const hidden of [hiddenCancel, hiddenPage]) {
                expect(hidden.statusCode).toBe(404);
                expect(hidden.body).not.toContain(reservedAssetId);
                expect(hidden.body).not.toContain(session.id);
            }
            await prisma.asset.update({ where: { id: reservedAssetId }, data: { moderation: 'ACTIVE' } });

            expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toMatchObject({
                status: 'OPEN', storageReservationBytes: original.storageReservationBytes,
            });
            expect(await readFile(path.join(storageRoot, '.uploads', session.id, 'parts', '00001'))).toEqual(content);
            expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(1);
            expect(await storage.stat(original.storageKey)).toBeNull();
            expect((await prisma.clip.findUnique({ where: { id: session.clipId } })).storageKey).toBeNull();
            expect((await prisma.clip.findUnique({ where: { id: otherClipId } })).storageKey).toBeNull();
            expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } })).toBeNull();

            await prisma.uploadSession.update({
                where: { id: session.id }, data: { assetId: reservedAssetId, clipId: session.clipId },
            });
            const retry = await requestAs(
                ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
            expect(retry.statusCode, retry.body).toBe(200);
            expect(retry.json()).toEqual({ assetId: reservedAssetId, sessionIds: [session.id] });
            const page = await requestAs(ownerId, 'GET', url);
            expect(page.statusCode, page.body).toBe(200);
            expect(page.json()).toEqual({ assetId: reservedAssetId, sessionIds: [session.id], nextCursor: null });
            await expect(serviceWithHandoff.complete({ ownerId, uploadSessionId: session.id }))
                .rejects.toMatchObject({ code: 'INTENT_CANCELLED' });
            expect(await readFile(path.join(storageRoot, '.uploads', session.id, 'parts', '00001'))).toEqual(content);
            expect((await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${session.id}`)).statusCode).toBe(200);
        },
    );

    it('rechecks the locked clip after completion waits for a concurrent reference change', async () => {
        const content = Buffer.from('clip changes during completion');
        const { session } = await stagedReservedOriginal(content);
        const original = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        const otherAssetId = randomUUID();
        await prisma.asset.create({ data: { id: otherAssetId, userId: ownerId, status: 'UPLOADING' } });
        let reportLocked;
        let releaseClip;
        const locked = new Promise(resolve => { reportLocked = resolve; });
        const release = new Promise(resolve => { releaseClip = resolve; });
        const changing = prisma.$transaction(async tx => {
            const [backend] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
            await tx.$queryRaw`SELECT id FROM clips WHERE id = ${session.clipId} FOR UPDATE`;
            reportLocked(backend.pid);
            await release;
            await tx.clip.update({ where: { id: session.clipId }, data: { assetId: otherAssetId } });
        }, { timeout: 15_000 });
        let completion;
        try {
            const pid = await Promise.race([
                locked, changing.then(() => { throw new Error('Clip lock did not pause'); }),
            ]);
            completion = requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
            await blockedQueryBy(pid, 'SELECT id FROM clips');
            releaseClip();
            const result = await completion;
            expect(result.statusCode, result.body).toBe(409);
        } finally {
            releaseClip();
            await Promise.allSettled([changing, completion].filter(Boolean));
        }
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('OPEN');
        expect(await storage.stat(original.storageKey)).toBeNull();
        expect(await readFile(path.join(storageRoot, '.uploads', session.id, 'parts', '00001'))).toEqual(content);
        await prisma.clip.update({ where: { id: session.clipId }, data: { assetId: original.assetId } });
        const recovered = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
        expect(recovered.statusCode, recovered.body).toBe(200);
        expect(recovered.json().uploadSession.status).toBe('COMPLETED');
    }, 20_000);

    it('serializes cancellation first against completion and retains the staged original for abort', async () => {
        const content = Buffer.from('cancel wins completion');
        const { payload, session, reservedAssetId } = await stagedReservedOriginal(content);
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        let reportLocked;
        let releaseAsset;
        const locked = new Promise(resolve => { reportLocked = resolve; });
        const release = new Promise(resolve => { releaseAsset = resolve; });
        const holding = prisma.$transaction(async tx => {
            const [backend] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
            await tx.$queryRaw`SELECT id FROM assets WHERE id = ${reservedAssetId} FOR UPDATE`;
            reportLocked(backend.pid);
            await release;
        }, { timeout: 15_000 });
        let cancellation;
        let completion;
        try {
            const pid = await Promise.race([
                locked, holding.then(() => { throw new Error('Asset lock did not pause'); }),
            ]);
            cancellation = requestAs(ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
            const cancelPid = await blockedQueryBy(pid, 'SELECT id FROM assets');
            completion = requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
            await blockedQueryBy(cancelPid, 'SELECT id FROM users');
            releaseAsset();
            const cancelled = await cancellation;
            const completed = await completion;
            expect(cancelled.statusCode, cancelled.body).toBe(200);
            expect(cancelled.json()).toEqual({ assetId: reservedAssetId, sessionIds: [session.id] });
            expect(completed.statusCode, completed.body).toBe(410);
        } finally {
            releaseAsset();
            await Promise.allSettled([holding, cancellation, completion].filter(Boolean));
        }
        const serviceWithHandoff = await handoffService();
        await expect(serviceWithHandoff.complete({ ownerId, uploadSessionId: session.id }))
            .rejects.toMatchObject({ code: 'INTENT_CANCELLED' });
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toMatchObject({ status: 'OPEN' });
        expect(await prisma.uploadPart.count({ where: { uploadSessionId: session.id } })).toBe(1);
        expect(await storage.listParts(session.id)).toMatchObject([{ partNumber: 1, sizeBytes: String(content.length) }]);
        expect(await readFile(path.join(storageRoot, '.uploads', session.id, 'parts', '00001'))).toEqual(content);
        expect(await storage.stat(row.storageKey)).toBeNull();
        expect((await prisma.clip.findUnique({ where: { id: session.clipId } })).storageKey).toBeNull();
        expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } })).toBeNull();
        const aborted = await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${session.id}`);
        expect(aborted.statusCode, aborted.body).toBe(200);
        expect(aborted.json().uploadSession.status).toBe('ABORTED');
        expect(await storage.hasUpload(session.id)).toBe(false);
    }, 20_000);

    it('retains the real storage reservation after fenced completion until abort', async () => {
        const content = Buffer.from('cancel with real storage reservation');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const { createStorageCapacity } = await import('../lib/storage/capacity.js');
        const { createUploadSessionService } = await import('../lib/upload-sessions.js');
        const { enqueueMuxOriginal } = await import('../lib/mux-original-records.js');
        const capacity = createStorageCapacity({
            db: prisma, storage, maxStorageBytes: 10n * 1024n * 1024n * 1024n, minFreeBytes: 1n,
        });
        const guardedService = createUploadSessionService({
            db: prisma, storage, capacity, now: () => new Date(currentTime), onCompleted: enqueueMuxOriginal,
        });
        const session = await guardedService.create({
            ownerId, assetId: reservedAssetId, clipId: randomUUID(), initializeClip: true,
            expectedSizeBytes: content.length, expectedSha256: sha256(content),
        });
        await guardedService.uploadPart({
            ownerId, uploadSessionId: session.id, partNumber: 1, body: content, expectedSizeBytes: content.length,
        });
        const before = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        expect(before.storageReservationBytes).toBeGreaterThan(0n);
        const cancelled = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
        expect(cancelled.statusCode, cancelled.body).toBe(200);
        await expect(guardedService.complete({ ownerId, uploadSessionId: session.id }))
            .rejects.toMatchObject({ code: 'INTENT_CANCELLED' });
        expect(await prisma.uploadSession.findUnique({ where: { id: session.id } })).toMatchObject({
            status: 'OPEN', storageReservationBytes: before.storageReservationBytes,
        });
        expect(await prisma.storageWriteLease.count({ where: { uploadSessionId: session.id } })).toBe(0);
        expect(await storage.listParts(session.id)).toHaveLength(1);
        expect(await storage.stat(session.storageKey)).toBeNull();
        expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } })).toBeNull();
        await expect(guardedService.abort({ ownerId, uploadSessionId: session.id }))
            .resolves.toMatchObject({ status: 'ABORTED' });
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).storageReservationBytes).toBe(0n);
        expect(await storage.hasUpload(session.id)).toBe(false);
    });

    it('allows a completion that transitioned first to finish and enqueue after cancellation', async () => {
        const content = Buffer.from('completion wins cancellation');
        const { payload, session, reservedAssetId } = await stagedReservedOriginal(content);
        const serviceWithHandoff = await handoffService();
        const listParts = storage.listParts.bind(storage);
        let reportStarted;
        let releaseCompletion;
        const started = new Promise(resolve => { reportStarted = resolve; });
        const release = new Promise(resolve => { releaseCompletion = resolve; });
        storage.listParts = async (...args) => {
            reportStarted();
            await release;
            return listParts(...args);
        };
        const completion = serviceWithHandoff.complete({ ownerId, uploadSessionId: session.id });
        try {
            await Promise.race([
                started, completion.then(() => { throw new Error('Completion did not pause'); }),
            ]);
            expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('COMPLETING');
            const cancelled = await requestAs(
                ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
            expect(cancelled.statusCode, cancelled.body).toBe(200);
            expect(cancelled.json()).toEqual({ assetId: reservedAssetId, sessionIds: [session.id] });
        } finally {
            releaseCompletion();
            try {
                await completion;
            } finally {
                storage.listParts = listParts;
            }
        }
        expect((await completion).status).toBe('COMPLETED');
        expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } }))
            .toMatchObject({ status: 'QUEUED' });
        const retry = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
        expect(retry.statusCode, retry.body).toBe(200);
        expect(retry.json().uploadSession.status).toBe('COMPLETED');
    }, 20_000);

    it.each(['published', 'unpublished'])(
        'recovers a previously completing %s original after cancellation',
        async state => {
            const content = Buffer.from(`recover ${state} after cancellation`);
            const { payload, session } = await stagedReservedOriginal(content);
            if (state === 'published') await storage.completeUpload(session.id);
            await prisma.uploadSession.update({ where: { id: session.id }, data: { status: 'COMPLETING' } });
            const cancelled = await requestAs(
                ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
            expect(cancelled.statusCode, cancelled.body).toBe(200);
            const serviceWithHandoff = await handoffService();
            if (state === 'published') {
                const recovered = await serviceWithHandoff.complete({ ownerId, uploadSessionId: session.id });
                expect(recovered.status).toBe('COMPLETED');
                expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } }))
                    .toMatchObject({ status: 'QUEUED' });
                const retry = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
                expect(retry.statusCode, retry.body).toBe(200);
            } else {
                await expect(serviceWithHandoff.complete({ ownerId, uploadSessionId: session.id }))
                    .rejects.toMatchObject({ code: 'INTENT_CANCELLED' });
                expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('OPEN');
                expect(await storage.listParts(session.id)).toHaveLength(1);
                expect(await prisma.muxIngestJob.findUnique({ where: { uploadSessionId: session.id } })).toBeNull();
                const retry = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
                expect(retry.statusCode, retry.body).toBe(410);
                expect((await requestAs(ownerId, 'DELETE', `/api/upload-sessions/${session.id}`)).statusCode).toBe(200);
            }
        },
    );

    it('rechecks the intent after completion waits for the asset lock', async () => {
        const content = Buffer.from('intent changes before completion');
        const { payload, session, reservedAssetId } = await stagedReservedOriginal(content);
        let reportLocked;
        let releaseIntent;
        const locked = new Promise(resolve => { reportLocked = resolve; });
        const release = new Promise(resolve => { releaseIntent = resolve; });
        const intentChange = prisma.$transaction(async tx => {
            const [backend] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
            await tx.$queryRaw`SELECT id FROM assets WHERE id = ${reservedAssetId} FOR UPDATE`;
            reportLocked(backend.pid);
            await release;
            await tx.originalUploadIntent.update({
                where: { userId_clientRequestId: { userId: ownerId, clientRequestId: payload.clientRequestId } },
                data: { cancelledAt: new Date() },
            });
        }, { timeout: 15_000 });
        let completion;
        try {
            const pid = await Promise.race([
                locked, intentChange.then(() => { throw new Error('Intent change did not pause'); }),
            ]);
            completion = requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
            await blockedQueryBy(pid, 'SELECT id FROM assets');
            releaseIntent();
            const response = await completion;
            expect(response.statusCode, response.body).toBe(410);
        } finally {
            releaseIntent();
            await Promise.allSettled([intentChange, completion].filter(Boolean));
        }
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('OPEN');
        expect(await storage.listParts(session.id)).toHaveLength(1);
    }, 20_000);

    it('rejects completion when the asset intent belongs to a different owner', async () => {
        const content = Buffer.from('inconsistent intent owner');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        await prisma.originalUploadIntent.create({
            data: { userId: otherId, clientRequestId: randomUUID(), assetId, cancelledAt: new Date() },
        });
        const response = await requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
        expect(response.statusCode, response.body).toBe(503);
        expect((await prisma.uploadSession.findUnique({ where: { id: session.id } })).status).toBe('OPEN');
        expect(await storage.listParts(session.id)).toHaveLength(1);
    });

    it('rejects completion if the session asset changes while its row is locked', async () => {
        const content = Buffer.from('session asset changed');
        const session = await createSession(content);
        const signed = await sign(session.id);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        const otherAssetId = randomUUID();
        await prisma.asset.create({ data: { id: otherAssetId, userId: ownerId, status: 'UPLOADING' } });
        let reportLocked;
        let releaseChange;
        const locked = new Promise(resolve => { reportLocked = resolve; });
        const release = new Promise(resolve => { releaseChange = resolve; });
        const changing = prisma.$transaction(async tx => {
            const [backend] = await tx.$queryRaw`SELECT pg_backend_pid() AS pid`;
            await tx.$queryRaw`SELECT id FROM upload_sessions WHERE id = ${session.id} FOR UPDATE`;
            reportLocked(backend.pid);
            await release;
            await tx.uploadSession.update({ where: { id: session.id }, data: { assetId: otherAssetId } });
        }, { timeout: 15_000 });
        let completion;
        try {
            const pid = await Promise.race([
                locked, changing.then(() => { throw new Error('Session change did not pause'); }),
            ]);
            completion = requestAs(ownerId, 'POST', `/api/upload-sessions/${session.id}/complete`);
            await blockedQueryBy(pid, 'SELECT id FROM upload_sessions');
            releaseChange();
            const response = await completion;
            expect(response.statusCode, response.body).toBe(409);
        } finally {
            releaseChange();
            await Promise.allSettled([changing, completion].filter(Boolean));
        }
        const row = await prisma.uploadSession.findUnique({ where: { id: session.id } });
        expect(row).toMatchObject({ status: 'OPEN', assetId: otherAssetId });
        expect(await storage.stat(row.storageKey)).toBeNull();
        expect(await storage.listParts(session.id)).toHaveLength(1);
    }, 20_000);

    it('does not fence another owner with the same request ID', async () => {
        const content = Buffer.from('independent owner completion');
        const payload = originalReservation(content);
        const cancelled = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
        expect(cancelled.statusCode, cancelled.body).toBe(200);
        const reserved = await requestAs(otherId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const session = await createSession(content, reserved.json().asset.id, otherId);
        const signed = await sign(session.id, 1, otherId);
        expect((await put(signed.url, content)).statusCode).toBe(200);
        const completed = await requestAs(otherId, 'POST', `/api/upload-sessions/${session.id}/complete`);
        expect(completed.statusCode, completed.body).toBe(200);
        expect(completed.json().uploadSession.status).toBe('COMPLETED');
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

    it('inspects bounded intent history without mutating uploads', async () => {
        const content = Buffer.from('read-only recovery');
        const payload = originalReservation(content);
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        expect(reserved.statusCode, reserved.body).toBe(201);
        const reservedAssetId = reserved.json().asset.id;
        const session = await createSession(content, reservedAssetId);
        const history = Array.from({ length: 99 }, () => randomUUID());
        await prisma.uploadSession.createMany({
            data: history.map(id => ({
                id, ownerId, assetId: reservedAssetId, clipId: session.clipId,
                status: 'ABORTED', storageKey: `historical-${id}`, expiresAt: new Date(),
            })),
        });
        const url = `/api/original-upload-recovery/${payload.clientRequestId}`;
        const beforeIntent = await prisma.originalUploadIntent.findUniqueOrThrow({
            where: { userId_clientRequestId: { userId: ownerId, clientRequestId: payload.clientRequestId } },
        });
        const beforeSessions = await prisma.uploadSession.findMany({
            where: { assetId: reservedAssetId }, orderBy: { id: 'asc' },
        });
        const response = await requestAs(ownerId, 'GET', url);
        expect(response.statusCode, response.body).toBe(200);
        expect(response.headers['cache-control']).toBe('no-store');
        expect(response.json()).toEqual({
            state: 'ACTIVE',
            assetId: reservedAssetId,
            sessions: beforeSessions.map(({ id, status }) => ({ id, status })),
            truncated: false,
        });
        expect(await prisma.originalUploadIntent.findUniqueOrThrow({
            where: { userId_clientRequestId: { userId: ownerId, clientRequestId: payload.clientRequestId } },
        })).toEqual(beforeIntent);
        expect(await prisma.uploadSession.findMany({
            where: { assetId: reservedAssetId }, orderBy: { id: 'asc' },
        })).toEqual(beforeSessions);

        const extraId = randomUUID();
        await prisma.uploadSession.create({
            data: {
                id: extraId, ownerId, assetId: reservedAssetId, clipId: session.clipId,
                status: 'EXPIRED', storageKey: `historical-${extraId}`, expiresAt: new Date(),
            },
        });
        const truncated = await requestAs(ownerId, 'GET', url);
        expect(truncated.statusCode, truncated.body).toBe(200);
        expect(truncated.json().sessions).toHaveLength(100);
        expect(truncated.json().truncated).toBe(true);

        const cancelled = await requestAs(
            ownerId, 'POST', `/api/assets/original-uploads/${payload.clientRequestId}/cancel`);
        expect(cancelled.statusCode).toBe(503);
        expect((await requestAs(ownerId, 'GET', url)).json().state).toBe('CANCELLED');
        await prisma.asset.delete({ where: { id: reservedAssetId } });
        const removed = await requestAs(ownerId, 'GET', url);
        expect(removed.json()).toEqual({ state: 'CANCELLED', assetId: null, sessions: [], truncated: false });
    });

    it('protects recovery inspection from unauthorized and inconsistent references', async () => {
        const payload = originalReservation(Buffer.from('private recovery'));
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        const reservedAssetId = reserved.json().asset.id;
        const session = await createSession(Buffer.from('private recovery'), reservedAssetId);
        const url = `/api/original-upload-recovery/${payload.clientRequestId}`;
        expect((await requestAs(null, 'GET', url)).statusCode).toBe(401);
        await prisma.user.update({ where: { id: ownerId }, data: { status: 'SUSPENDED' } });
        expect((await requestAs(ownerId, 'GET', url)).statusCode).toBe(403);
        await prisma.user.update({ where: { id: ownerId }, data: { status: 'ACTIVE' } });
        for (const response of [
            await requestAs(otherId, 'GET', url),
            await requestAs(ownerId, 'GET', `/api/original-upload-recovery/${randomUUID()}`),
        ]) {
            expect(response.statusCode).toBe(404);
            expect(response.body).not.toContain(reservedAssetId);
            expect(response.body).not.toContain(session.id);
        }
        expect((await requestAs(ownerId, 'GET', '/api/original-upload-recovery/not-a-uuid')).statusCode).toBe(400);
        expect((await requestAs(ownerId, 'GET', `${url}?unexpected=1`)).statusCode).toBe(400);
        await prisma.asset.update({ where: { id: reservedAssetId }, data: { moderation: 'FLAGGED_FOR_REMOVAL' } });
        const hidden = await requestAs(ownerId, 'GET', url);
        expect(hidden.statusCode).toBe(404);
        expect(hidden.body).not.toContain(reservedAssetId);
        await prisma.asset.update({ where: { id: reservedAssetId }, data: { moderation: 'ACTIVE' } });
        await prisma.uploadSession.update({ where: { id: session.id }, data: { ownerId: otherId } });
        const inconsistent = await requestAs(ownerId, 'GET', url);
        expect(inconsistent.statusCode).toBe(503);
        expect(inconsistent.body).not.toContain(reservedAssetId);
        expect(inconsistent.body).not.toContain(session.id);
        await prisma.uploadSession.update({ where: { id: session.id }, data: { ownerId } });
        await prisma.clip.update({ where: { id: session.clipId }, data: { assetId } });
        const mismatchedClip = await requestAs(ownerId, 'GET', url);
        expect(mismatchedClip.statusCode).toBe(503);
        expect(mismatchedClip.body).not.toContain(reservedAssetId);
        expect(mismatchedClip.body).not.toContain(session.id);
    });

    it('inspects the retained tombstone if deletion wins the asset lock', async () => {
        const payload = originalReservation(Buffer.from('recovery deletion race'));
        const reserved = await requestAs(ownerId, 'POST', '/api/assets/original-uploads', payload);
        const reservedAssetId = reserved.json().asset.id;
        const url = `/api/original-upload-recovery/${payload.clientRequestId}`;
        let reportLocked;
        let releaseDeletion;
        const locked = new Promise(resolve => { reportLocked = resolve; });
        const release = new Promise(resolve => { releaseDeletion = resolve; });
        const deletion = prisma.$transaction(async tx => {
            await tx.asset.delete({ where: { id: reservedAssetId } });
            reportLocked();
            await release;
        }, { timeout: 15_000 });
        let inspection;
        try {
            await locked;
            inspection = requestAs(ownerId, 'GET', url);
            await waitFor(async () => {
                const rows = await prisma.$queryRaw`
                    SELECT count(*)::int AS count FROM pg_stat_activity
                    WHERE datname = current_database() AND wait_event_type = 'Lock'
                        AND query LIKE '%SELECT id FROM assets%'
                `;
                return rows[0].count > 0;
            });
        } finally {
            releaseDeletion();
            await deletion;
        }
        const response = await inspection;
        expect(response.statusCode, response.body).toBe(200);
        expect(response.json()).toEqual({ state: 'REMOVED', assetId: null, sessions: [], truncated: false });
        expect(response.body).not.toContain(reservedAssetId);
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
        expect((await requestAs(otherId, 'POST', `/api/upload-sessions/${session.id}/complete`)).statusCode).toBe(404);
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
