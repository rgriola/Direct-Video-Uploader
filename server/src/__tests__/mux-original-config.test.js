import { createHmac } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { getMuxOriginalConfig } from '../lib/mux-original-config.js';
import { signMuxOriginalRead, verifyMuxOriginalRead } from '../lib/mux-original-signing.js';
import { signUploadPart } from '../lib/upload-part-signing.js';

const enabled = {
    MUX_ORIGINAL_INGEST_ENABLED: 'true',
    UPLOAD_SESSIONS_ENABLED: 'true',
    MUX_TOKEN_ID: 'test-token-id',
    MUX_TOKEN_SECRET: 'test-token-secret',
    MUX_WEBHOOK_SECRET: 'test-webhook-secret',
    JWT_SECRET: 'jwt-secret',
    UPLOAD_SESSION_SIGNING_SECRET: 'upload-secret',
    MUX_ORIGINAL_READ_SIGNING_SECRET: 'r'.repeat(32),
    MUX_ORIGINAL_READ_BASE_URL: 'https://origin.example.test',
};

describe('original Mux ingest configuration', () => {
    it('is disabled by default and validates enabled dependencies', () => {
        expect(getMuxOriginalConfig({})).toEqual({ enabled: false });
        expect(() => getMuxOriginalConfig({ MUX_ORIGINAL_INGEST_ENABLED: 'yes' })).toThrow(/true or false/);
        expect(() => getMuxOriginalConfig({ ...enabled, UPLOAD_SESSIONS_ENABLED: 'false' }))
            .toThrow(/requires UPLOAD_SESSIONS_ENABLED/);
        expect(() => getMuxOriginalConfig({ ...enabled, DEBUG: 'true' })).toThrow(/exposes signed URLs/);
        for (const name of ['MUX_TOKEN_ID', 'MUX_TOKEN_SECRET', 'MUX_WEBHOOK_SECRET']) {
            expect(() => getMuxOriginalConfig({ ...enabled, [name]: '' })).toThrow(name);
        }
        expect(() => getMuxOriginalConfig({ ...enabled, MUX_ORIGINAL_READ_SIGNING_SECRET: 'short' }))
            .toThrow(/at least 32 bytes/);
        expect(() => getMuxOriginalConfig({
            ...enabled, JWT_SECRET: enabled.MUX_ORIGINAL_READ_SIGNING_SECRET,
        })).toThrow(/differ from other signing secrets/);
        expect(() => getMuxOriginalConfig({
            ...enabled, UPLOAD_SESSION_SIGNING_SECRET: enabled.MUX_ORIGINAL_READ_SIGNING_SECRET,
        })).toThrow(/differ from other signing secrets/);
        expect(getMuxOriginalConfig(enabled)).toEqual({
            enabled: true,
            baseUrl: 'https://origin.example.test',
            signingSecret: enabled.MUX_ORIGINAL_READ_SIGNING_SECRET,
            readTtlMs: 60 * 60 * 1000,
        });
    });

    it('requires an origin and a bounded read lifetime', () => {
        for (const baseUrl of [
            '', 'not-a-url', 'https://user:pass@example.test', 'https://example.test/path',
            'https://example.test/?query=1', 'https://example.test/#fragment', 'http://example.test',
        ]) {
            expect(() => getMuxOriginalConfig({ ...enabled, MUX_ORIGINAL_READ_BASE_URL: baseUrl }))
                .toThrow(/absolute HTTPS origin/);
        }
        expect(getMuxOriginalConfig({
            ...enabled, MUX_ORIGINAL_READ_BASE_URL: 'http://127.0.0.1:3000',
        }).baseUrl).toBe('http://127.0.0.1:3000');
        expect(() => getMuxOriginalConfig({
            ...enabled, NODE_ENV: 'production', MUX_ORIGINAL_READ_BASE_URL: 'http://127.0.0.1:3000',
        })).toThrow(/absolute HTTPS origin/);
        for (const ttl of ['0', '299', '86401', '1.5', 'invalid']) {
            expect(() => getMuxOriginalConfig({ ...enabled, MUX_ORIGINAL_READ_TTL_SECONDS: ttl }))
                .toThrow(/must be between/);
        }
        expect(getMuxOriginalConfig({ ...enabled, MUX_ORIGINAL_READ_TTL_SECONDS: '300' }).readTtlMs).toBe(300000);
    });
});

describe('signed original reads', () => {
    it('binds the signature to the operation, expiry, secret, and capability type', () => {
        const secret = 'r'.repeat(32);
        const signature = signMuxOriginalRead(secret, 'operation-1', 12345);
        expect(verifyMuxOriginalRead(secret, 'operation-1', 12345, signature)).toBe(true);
        expect(verifyMuxOriginalRead(secret, 'operation-2', 12345, signature)).toBe(false);
        expect(verifyMuxOriginalRead(secret, 'operation-1', 12346, signature)).toBe(false);
        expect(verifyMuxOriginalRead('s'.repeat(32), 'operation-1', 12345, signature)).toBe(false);
        expect(verifyMuxOriginalRead(secret, 'operation-1', 12345, 'bad')).toBe(false);
    });

    it('preserves the existing upload-part signature format', () => {
        const secret = 'u'.repeat(32);
        const values = { ownerId: 'owner', sessionId: 'session', partNumber: 1, sizeBytes: 9, expires: 123 };
        const expected = createHmac('sha256', secret)
            .update('upload-part-v1\nowner\nsession\n1\n9\n123').digest('hex');
        expect(signUploadPart(secret, values)).toBe(expected);
    });
});
