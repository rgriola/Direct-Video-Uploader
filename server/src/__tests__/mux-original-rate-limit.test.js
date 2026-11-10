import Fastify from 'fastify';
import rateLimit from '@fastify/rate-limit';
import { randomUUID } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import muxOriginalRoutes from '../routes/mux-originals.js';
import { signMuxOriginalRead } from '../lib/mux-original-signing.js';

vi.mock('../lib/prisma.js', () => ({ default: {}, pool: {} }));

describe('Mux original read rate limiting', () => {
    const signingSecret = 'mux-original-rate-limit-test-secret-32-bytes';
    const sourceIp = '192.0.2.1';
    const otherIp = '192.0.2.2';
    let app;
    let findAttempt;
    let validUrl;
    let invalidUrl;

    beforeEach(async () => {
        const operationId = randomUUID();
        const expires = Math.floor(Date.now() / 1000) + 3600;
        const signature = signMuxOriginalRead(signingSecret, operationId, expires);
        validUrl = `/api/mux-originals/${operationId}?expires=${expires}&signature=${signature}`;
        invalidUrl = `/api/mux-originals/${operationId}?expires=${expires}&signature=${'0'.repeat(64)}`;
        findAttempt = vi.fn(async () => null);
        app = Fastify({ logger: false });
        await app.register(rateLimit, { global: true, max: 100, timeWindow: '1 minute' });
        await app.register(muxOriginalRoutes, {
            db: { muxIngestAttempt: { findUnique: findAttempt } },
            signingSecret,
        });
        await app.ready();
    });

    afterEach(async () => {
        await app.close();
        vi.restoreAllMocks();
    });

    it.each(['GET', 'HEAD'])('limits %s before authorization or database access', async method => {
        const now = Date.now();
        const clock = vi.spyOn(Date, 'now').mockReturnValue(now);
        for (let count = 0; count < 120; count += 1) {
            const response = await app.inject({
                method,
                url: count % 2 === 0 ? validUrl : invalidUrl,
                remoteAddress: sourceIp,
            });
            expect(response.statusCode).toBe(403);
            expect(response.headers['x-ratelimit-limit']).toBe('120');
        }
        expect(findAttempt).toHaveBeenCalledTimes(60);

        const blocked = await app.inject({ method, url: validUrl, remoteAddress: sourceIp });
        expect(blocked.statusCode).toBe(429);
        expect(Number(blocked.headers['retry-after'])).toBeGreaterThan(0);
        expect(findAttempt).toHaveBeenCalledTimes(60);

        const otherClient = await app.inject({ method, url: validUrl, remoteAddress: otherIp });
        expect(otherClient.statusCode).toBe(403);
        expect(findAttempt).toHaveBeenCalledTimes(61);

        clock.mockReturnValue(now + 60_001);
        const afterWindow = await app.inject({ method, url: validUrl, remoteAddress: sourceIp });
        expect(afterWindow.statusCode).toBe(403);
        expect(findAttempt).toHaveBeenCalledTimes(62);
    });

    it('shares the GET and HEAD request limit', async () => {
        for (let count = 0; count < 120; count += 1) {
            const method = count % 2 === 0 ? 'GET' : 'HEAD';
            expect((await app.inject({ method, url: invalidUrl, remoteAddress: sourceIp })).statusCode)
                .toBe(403);
        }
        expect((await app.inject({ method: 'GET', url: invalidUrl, remoteAddress: sourceIp })).statusCode)
            .toBe(429);
        expect((await app.inject({ method: 'HEAD', url: invalidUrl, remoteAddress: sourceIp })).statusCode)
            .toBe(429);
        expect((await app.inject({ method: 'HEAD', url: invalidUrl, remoteAddress: otherIp })).statusCode)
            .toBe(403);
    });

    it('refuses to register without the rate-limit plugin', async () => {
        const unprotected = Fastify({ logger: false });
        try {
            await expect(unprotected.register(muxOriginalRoutes, {
                db: { muxIngestAttempt: { findUnique: findAttempt } },
                signingSecret,
            }).ready()).rejects.toThrow('Original read routes require @fastify/rate-limit');
        } finally {
            await unprotected.close();
        }
    });
});
