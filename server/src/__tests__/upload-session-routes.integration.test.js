import Fastify from 'fastify';
import fastifyJwt from '@fastify/jwt';
import cookie from '@fastify/cookie';
import csrfProtection from '@fastify/csrf-protection';
import rateLimit from '@fastify/rate-limit';
import { createHash, randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { mkdtemp, readdir, rename, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { createLocalStorageDriver, MAX_PART_SIZE_BYTES } from '../lib/storage/local-driver.js';
import { acquireIntegrationDatabaseLock, INTEGRATION_SETUP_TIMEOUT_MS } from './helpers/database-lock.js';

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
    let assetId;
    let currentTime;
    let tokens;

    beforeAll(async () => {
        const database = await import('../lib/prisma.js');
        prisma = database.default;
        releaseDatabaseLock = await acquireIntegrationDatabaseLock(database.pool);
        const { authenticate } = await import('../lib/authentication.js');
        const { requireRole } = await import('../lib/authorization.js');
        const { default: assetRoutes } = await import('../routes/assets.js');
        const { default: moderationRoutes } = await import('../routes/moderation.js');
        const { default: uploadSessionRoutes } = await import('../routes/upload-sessions.js');
        ({ cleanupOrphanedUploads } = await import('../jobs/upload-cleanup.js'));
        ({ reconcileAssetMedia, createMediaReconciler } = await import('../lib/media-reconciliation.js'));
        ({ withAssetMediaLock } = await import('../lib/media-lock.js'));

        for (const [index, id] of [ownerId, otherId, adminId].entries()) {
            await prisma.user.create({
                data: {
                    id,
                    name: `Upload Route Test ${index}`,
                    phoneNumber: `upload-route-${randomUUID()}`,
                    pinHash: 'integration-test',
                    role: id === adminId ? 'SUPER_ADMIN' : 'USER',
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
            to: () => ({ emit: () => {} }),
            of: () => ({ sockets: new Map() }),
            sockets: { sockets: new Map() },
        });
        await app.register(assetRoutes);
        await app.register(moderationRoutes);
        await app.register(uploadSessionRoutes, {
            storage,
            signingSecret,
            now: () => new Date(currentTime),
        });
        tokens = Object.fromEntries([ownerId, otherId, adminId].map(id => [id, app.jwt.sign({ id })]));
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
        await prisma.asset.deleteMany({ where: { userId: { in: [ownerId, otherId] } } });
    });

    afterAll(async () => {
        try {
            if (app) await app.close();
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
            await registerApplicationRoutes(server);
            return server;
        }

        vi.stubEnv('STORAGE_DRIVER', 'local');
        vi.stubEnv('JWT_SECRET', 'integration-jwt-secret');
        vi.stubEnv('UPLOAD_SESSION_SIGNING_SECRET', signingSecret);
        const content = Buffer.from('registered upload');
        const url = `/api/assets/${assetId}/upload-sessions`;
        const payload = { expectedSizeBytes: content.length, expectedSha256: sha256(content) };
        try {
            const disabled = await buildServer(false);
            expect((await disabled.inject({ method: 'POST', url, payload })).statusCode).toBe(404);
            const enabled = await buildServer(true);
            expect((await enabled.inject({ method: 'POST', url, payload })).statusCode).toBe(401);
            const headers = { authorization: ['Bearer', tokens[ownerId]].join(' ') };
            const created = await enabled.inject({ method: 'POST', url, payload, headers });
            expect(created.statusCode, created.body).toBe(201);
            const session = created.json().uploadSession;
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
        const service = createUploadSessionService({ db: prisma, storage, now: () => new Date(currentTime) });
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
        source.push(null);
        await writing;
        expect((await reconcileAssetMedia(app, assetId)).state).toBe('SYNCED');
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
        expect(await prisma.asset.findUnique({ where: { id: assetId } })).toMatchObject({ mediaSyncState: 'ERROR' });
        expect((await reconcileAssetMedia(app, assetId)).state).toBe('SYNCED');
        expect(await storage.stat(row.storageKey)).toBeNull();
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
            const wrongService = createUploadSessionService({ db: prisma, storage: wrongStorage });
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
});
