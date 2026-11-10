import prisma from '../lib/prisma.js';
import { createStorageDriver } from '../lib/storage/driver.js';
import { acquireOriginalReadLock } from '../lib/mux-original-read-lock.js';
import { findReadableOriginal, muxOriginalReadServerInstanceId, registerOriginalRead } from '../lib/mux-original-read.js';
import { verifyMuxOriginalRead } from '../lib/mux-original-signing.js';

const OPERATION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CHECK_INTERVAL_MS = 1000;
const CHECK_TIMEOUT_MS = 3000;

function parseRange(value, size) {
    if (value === undefined) return null;
    if (typeof value !== 'string') return false;
    const match = /^bytes=(\d{0,15})-(\d{0,15})$/.exec(value);
    if (!match || (!match[1] && !match[2])) return false;
    if (!match[1]) {
        const suffix = Number(match[2]);
        if (!Number.isSafeInteger(suffix) || suffix < 1) return false;
        return { start: Math.max(0, size - suffix), end: size - 1 };
    }
    const start = Number(match[1]);
    const requestedEnd = match[2] ? Number(match[2]) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(requestedEnd)
        || start >= size || requestedEnd < start) return false;
    return { start, end: Math.min(requestedEnd, size - 1) };
}

function withTimeout(promise, milliseconds) {
    let timer;
    return Promise.race([
        promise,
        new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('Original read coordination timed out')), milliseconds);
        }),
    ]).finally(() => clearTimeout(timer));
}

export default async function muxOriginalRoutes(fastify, {
    db = prisma,
    signingSecret,
    storageFactory = createStorageDriver,
    now = () => new Date(),
    acquireLock = acquireOriginalReadLock,
}) {
    if (typeof signingSecret !== 'string' || Buffer.byteLength(signingSecret) < 32) {
        throw new TypeError('Original read routes require a signing secret');
    }
    fastify.log.info({ serverInstanceId: muxOriginalReadServerInstanceId }, 'Mux original read instance ready');
    const activeReads = new Set();
    fastify.addHook('preClose', async () => {
        for (const cancelRead of activeReads) cancelRead();
    });

    fastify.route({
        method: ['GET', 'HEAD'],
        url: '/api/mux-originals/:operationId',
        exposeHeadRoute: false,
        config: { rateLimit: { max: 120, timeWindow: '1 minute' } },
        handler: async (request, reply) => {
            reply.header('Cache-Control', 'no-store');
            const operationId = request.params.operationId;
            const rawExpires = request.query?.expires;
            const expires = typeof rawExpires === 'string' && /^\d{1,12}$/.test(rawExpires)
                ? Number(rawExpires)
                : NaN;
            if (!OPERATION_ID.test(operationId) || !Number.isSafeInteger(expires)
                || expires * 1000 <= now().getTime()
                || !verifyMuxOriginalRead(signingSecret, operationId, expires, request.query?.signature)) {
                return reply.status(403).send({ error: 'Invalid or expired original read URL' });
            }

            let lock;
            let lease;
            let stream;
            let interval;
            let expiryTimer;
            let closed = false;
            let cancelled = false;
            let checking = false;
            let cleanupPromise;

            const cancel = (forceClose = false) => {
                if (closed) return;
                cancelled = true;
                if (stream) stream.destroy();
                if (forceClose || reply.raw.headersSent) reply.raw.destroy();
            };
            const cancelForShutdown = () => cancel(true);
            const cleanup = () => {
                if (cleanupPromise) return cleanupPromise;
                closed = true;
                activeReads.delete(cancelForShutdown);
                clearInterval(interval);
                clearTimeout(expiryTimer);
                cleanupPromise = (async () => {
                    if (lease) {
                        try {
                            await db.muxOriginalReadLease.deleteMany({ where: { id: lease.id } });
                        } catch {
                            request.log.error({ operationId, leaseId: lease.id }, 'Could not release original read lease');
                        }
                    }
                    if (lock) {
                        try {
                            await lock.release({ destroy: cancelled });
                        } catch {
                            request.log.error({ operationId }, 'Could not release original read lock');
                        }
                    }
                })();
                return cleanupPromise;
            };

            activeReads.add(cancelForShutdown);
            try {
                const initial = await findReadableOriginal(db, operationId, expires, now());
                if (!initial || cancelled) {
                    await cleanup();
                    if (reply.raw.destroyed) return reply;
                    return reply.status(403).send({ error: 'Invalid or expired original read URL' });
                }
                lock = await acquireLock(initial.assetId, cancel);
                if (!lock || cancelled) {
                    await cleanup();
                    if (reply.raw.destroyed) return reply;
                    return reply.header('Retry-After', '5').status(503).send({ error: 'Original read is busy' });
                }
                const registered = await registerOriginalRead(db, operationId, expires, now());
                if (!registered) {
                    await cleanup();
                    return reply.status(403).send({ error: 'Invalid or expired original read URL' });
                }
                lease = registered.lease;
                const socket = request.raw.socket;
                const onSocketClose = () => {
                    if (!reply.raw.writableFinished) {
                        cancelled = true;
                        stream?.destroy();
                    }
                    void cleanup();
                };
                if (socket) {
                    socket.once('close', onSocketClose);
                    if (socket.destroyed) {
                        onSocketClose();
                        await cleanup();
                        return reply;
                    }
                } else {
                    reply.raw.once('close', onSocketClose);
                    if (reply.raw.destroyed) {
                        onSocketClose();
                        await cleanup();
                        return reply;
                    }
                }
                await withTimeout(lock.assertHeld(), CHECK_TIMEOUT_MS);
                if (closed || cancelled || expires * 1000 <= now().getTime()) {
                    await cleanup();
                    if (reply.raw.destroyed) return reply;
                    return reply.status(403).send({ error: 'Invalid or expired original read URL' });
                }

                const session = registered.session;
                const storage = storageFactory({ provider: session.storageDriver });
                await storage.assertStorageLocation(session.storageKey);
                const file = await storage.stat(session.storageKey);
                const size = Number(session.expectedSizeBytes);
                if (!file || !Number.isSafeInteger(size) || size < 1 || file.sizeBytes !== String(size)) {
                    throw new Error('Stored original is unavailable or has changed');
                }
                const current = await withTimeout(
                    findReadableOriginal(db, operationId, expires, now()), CHECK_TIMEOUT_MS,
                );
                if (closed || cancelled || !current) {
                    await cleanup();
                    if (reply.raw.destroyed) return reply;
                    return reply.status(403).send({ error: 'Invalid or expired original read URL' });
                }
                const range = parseRange(request.headers.range, size);
                if (range === false) {
                    await cleanup();
                    return reply.header('Content-Range', `bytes */${size}`)
                        .status(416).send({ error: 'Requested range is not satisfiable' });
                }
                if (request.method === 'GET') {
                    stream = await storage.getReadStream(session.storageKey, range);
                    stream.on('error', () => {
                        request.log.error({ operationId }, 'Original read stream failed');
                    });
                }
                if (cancelled || expires * 1000 <= now().getTime()) {
                    stream?.destroy();
                    await cleanup();
                    return reply.status(403).send({ error: 'Invalid or expired original read URL' });
                }

                expiryTimer = setTimeout(cancel, Math.max(1, expires * 1000 - now().getTime()));
                interval = setInterval(() => {
                    if (checking || closed) return;
                    checking = true;
                    void withTimeout(Promise.all([
                        lock.assertHeld(),
                        findReadableOriginal(db, operationId, expires, now()),
                    ]), CHECK_TIMEOUT_MS).then(([, current]) => {
                        if (!closed && !current) cancel();
                    }).catch(() => {
                        if (!closed) {
                            request.log.error({ operationId }, 'Original read coordination failed');
                            cancel();
                        }
                    }).finally(() => { checking = false; });
                }, CHECK_INTERVAL_MS);

                reply.header('Accept-Ranges', 'bytes');
                reply.header('Connection', 'close');
                reply.header('Content-Type', 'application/octet-stream');
                reply.header('Content-Length', String(range ? range.end - range.start + 1 : size));
                if (range) {
                    reply.header('Content-Range', `bytes ${range.start}-${range.end}/${size}`);
                    reply.status(206);
                }
                return reply.send(stream);
            } catch {
                cancelled = true;
                stream?.destroy();
                await cleanup();
                request.log.error({ operationId }, 'Could not serve original for Mux ingest');
                if (reply.raw.headersSent) {
                    reply.raw.destroy();
                    return reply;
                }
                return reply.status(503).send({ error: 'Original is unavailable' });
            }
        },
    });
}
