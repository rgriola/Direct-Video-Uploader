import { afterEach, describe, expect, it, vi } from 'vitest';
import { getUploadSessionConfig } from '../lib/upload-session-config.js';
import { signUploadPart, verifyUploadPart } from '../lib/upload-part-signing.js';

vi.mock('../routes/auth.js', () => ({ default: vi.fn() }));
vi.mock('../routes/assets.js', () => ({ default: vi.fn() }));
vi.mock('../routes/admin.js', () => ({ default: vi.fn() }));
vi.mock('../routes/moderation.js', () => ({ default: vi.fn() }));
vi.mock('../routes/clips.js', () => ({ default: vi.fn() }));
vi.mock('../routes/errors.js', () => ({ default: vi.fn() }));
vi.mock('../routes/mux-webhooks.js', () => ({ default: vi.fn() }));
vi.mock('../routes/upload-sessions.js', () => ({ default: vi.fn() }));
vi.mock('../routes/mux-originals.js', () => ({ default: vi.fn() }));
vi.mock('../lib/mux-original-records.js', () => ({ enqueueMuxOriginal: vi.fn() }));
vi.mock('../lib/mux-original-enqueue.js', () => ({ requestMuxOriginalIngest: vi.fn() }));
vi.mock('../lib/storage/driver.js', () => ({ createStorageDriver: vi.fn(() => ({ provider: 'local' })) }));

const originalEnv = { ...process.env };
const capacitySettings = {
    UPLOAD_STORAGE_MAX_BYTES: '10737418240',
    UPLOAD_STORAGE_MIN_FREE_BYTES: '1073741824',
};

afterEach(() => {
    process.env = { ...originalEnv };
    vi.clearAllMocks();
});

describe('upload session configuration', () => {
    it('defaults to disabled and rejects unsafe enabled configurations', () => {
        expect(getUploadSessionConfig({})).toEqual({ enabled: false });
        expect(getUploadSessionConfig({ UPLOAD_SESSIONS_ENABLED: 'false' })).toEqual({ enabled: false });
        expect(() => getUploadSessionConfig({ UPLOAD_SESSIONS_ENABLED: 'yes' })).toThrow(/true or false/);
        expect(() => getUploadSessionConfig({ UPLOAD_SESSIONS_ENABLED: 'true' })).toThrow(/at least 32 bytes/);
        const secret = 'a'.repeat(32);
        expect(() => getUploadSessionConfig({
            UPLOAD_SESSIONS_ENABLED: 'true', UPLOAD_SESSION_SIGNING_SECRET: secret, JWT_SECRET: secret,
        })).toThrow(/differ from JWT_SECRET/);
        const enabled = {
            UPLOAD_SESSIONS_ENABLED: 'true', UPLOAD_SESSION_SIGNING_SECRET: secret, JWT_SECRET: 'other',
        };
        expect(() => getUploadSessionConfig(enabled)).toThrow(/UPLOAD_STORAGE_MAX_BYTES/);
        expect(() => getUploadSessionConfig({ ...enabled, UPLOAD_STORAGE_MAX_BYTES: '10' }))
            .toThrow(/UPLOAD_STORAGE_MIN_FREE_BYTES/);
        for (const value of ['0', '-1', '1.5', '9223372036854775808', 'invalid']) {
            expect(() => getUploadSessionConfig({ ...enabled, ...capacitySettings, UPLOAD_STORAGE_MAX_BYTES: value }))
                .toThrow(/UPLOAD_STORAGE_MAX_BYTES/);
            expect(() => getUploadSessionConfig({ ...enabled, ...capacitySettings, UPLOAD_STORAGE_MIN_FREE_BYTES: value }))
                .toThrow(/UPLOAD_STORAGE_MIN_FREE_BYTES/);
        }
        expect(() => getUploadSessionConfig({ ...enabled, ...capacitySettings, STORAGE_DRIVER: 's3' }))
            .toThrow(/require the local storage driver/);
        expect(getUploadSessionConfig({
            ...enabled, ...capacitySettings,
        })).toEqual({
            enabled: true, signingSecret: secret, storageDriver: 'local',
            maxStorageBytes: 10737418240n, minFreeBytes: 1073741824n,
        });
    });

    it('does not register upload routes unless explicitly enabled', async () => {
        const { registerApplicationRoutes } = await import('../routes/index.js');
        const { default: uploadSessionRoutes } = await import('../routes/upload-sessions.js');
        const fastify = { register: vi.fn(async () => {}) };
        delete process.env.UPLOAD_SESSIONS_ENABLED;
        await registerApplicationRoutes(fastify);
        expect(fastify.register).not.toHaveBeenCalledWith(uploadSessionRoutes, expect.anything());

        process.env.UPLOAD_SESSIONS_ENABLED = 'true';
        process.env.UPLOAD_SESSION_SIGNING_SECRET = 'x'.repeat(32);
        process.env.JWT_SECRET = 'other';
        Object.assign(process.env, capacitySettings);
        await registerApplicationRoutes(fastify);
        expect(fastify.register).toHaveBeenCalledWith(uploadSessionRoutes, expect.objectContaining({
            signingSecret: 'x'.repeat(32),
            storageDriver: 'local',
            capacityLimits: { maxStorageBytes: 10737418240n, minFreeBytes: 1073741824n },
        }));
    });

    it('registers signed original reads and the completion handoff only when enabled', async () => {
        const { registerApplicationRoutes } = await import('../routes/index.js');
        const { default: uploadSessionRoutes } = await import('../routes/upload-sessions.js');
        const { default: muxOriginalRoutes } = await import('../routes/mux-originals.js');
        const { enqueueMuxOriginal } = await import('../lib/mux-original-records.js');
        const { requestMuxOriginalIngest } = await import('../lib/mux-original-enqueue.js');
        const fastify = { register: vi.fn(async () => {}) };
        Object.assign(process.env, {
            UPLOAD_SESSIONS_ENABLED: 'true',
            UPLOAD_SESSION_SIGNING_SECRET: 'u'.repeat(32),
            MUX_ORIGINAL_INGEST_ENABLED: 'true',
            MUX_ORIGINAL_READ_SIGNING_SECRET: 'r'.repeat(32),
            MUX_ORIGINAL_READ_BASE_URL: 'https://origin.example.test',
            MUX_TOKEN_ID: 'test-id',
            MUX_TOKEN_SECRET: 'test-secret',
            MUX_WEBHOOK_SECRET: 'test-webhook',
            JWT_SECRET: 'test-jwt',
            ...capacitySettings,
        });
        delete process.env.DEBUG;
        const config = await registerApplicationRoutes(fastify);
        expect(config.enabled).toBe(true);
        expect(fastify.register).toHaveBeenCalledWith(muxOriginalRoutes, {
            signingSecret: 'r'.repeat(32),
        });
        expect(fastify.register).toHaveBeenCalledWith(uploadSessionRoutes, expect.objectContaining({
            handoff: { onCompleted: enqueueMuxOriginal, request: requestMuxOriginalIngest },
        }));
    });
});

describe('signed upload parts', () => {
    it('binds the capability to its owner, session, part, size, and expiry', () => {
        const secret = 'x'.repeat(32);
        const claims = { ownerId: 'owner', sessionId: 'session', partNumber: 1, sizeBytes: 9, expires: 123 };
        const signature = signUploadPart(secret, claims);
        expect(verifyUploadPart(secret, claims, signature)).toBe(true);
        for (const change of [
            { ownerId: 'other' },
            { sessionId: 'other' },
            { partNumber: 2 },
            { sizeBytes: 10 },
            { expires: 124 },
        ]) {
            expect(verifyUploadPart(secret, { ...claims, ...change }, signature)).toBe(false);
        }
        expect(verifyUploadPart('y'.repeat(32), claims, signature)).toBe(false);
        expect(verifyUploadPart(secret, claims, 'invalid')).toBe(false);
    });
});
