import { randomUUID } from 'node:crypto';
import prisma from '../lib/prisma.js';
import { withAssetMediaLock } from '../lib/media-lock.js';
import { signUploadPart, verifyUploadPart } from '../lib/upload-part-signing.js';
import { assertAcceptingUploads, createUploadSessionService, UploadSessionError } from '../lib/upload-sessions.js';
import { MAX_PART_SIZE_BYTES, StorageError } from '../lib/storage/local-driver.js';

const MAX_UPLOAD_SIZE_BYTES = 500 * 1024 * 1024;
const PART_URL_TTL_MS = 5 * 60 * 1000;
const SESSION_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ERROR_STATUS = {
    INVALID_ARGUMENT: 400,
    NOT_FOUND: 404,
    EXPIRED: 410,
    ACCOUNT_SUSPENDED: 403,
    ASSET_NOT_ACTIVE: 409,
    INVALID_STATE: 409,
    CLIP_CHANGED: 409,
    SESSION_EXISTS: 409,
    SESSION_BUSY: 409,
    INCOMPLETE_UPLOAD: 409,
    INTEGRITY_MISMATCH: 422,
    STORAGE_UNAVAILABLE: 503,
    PART_CONFLICT: 409,
    PART_SIZE_MISMATCH: 400,
    PART_TOO_LARGE: 413,
};

function validateCreateInput(body) {
    const size = body?.expectedSizeBytes;
    if (!((typeof size === 'string' && /^\d{1,9}$/.test(size))
        || (typeof size === 'number' && Number.isSafeInteger(size)))) {
        throw new UploadSessionError('INVALID_ARGUMENT', 'expectedSizeBytes must be a positive integer');
    }
    const sizeBytes = BigInt(size);
    if (sizeBytes < 1n || sizeBytes > BigInt(MAX_UPLOAD_SIZE_BYTES)) {
        throw new UploadSessionError('INVALID_ARGUMENT', `expectedSizeBytes must be between 1 and ${MAX_UPLOAD_SIZE_BYTES}`);
    }
    if (typeof body.expectedSha256 !== 'string' || !/^[a-f0-9]{64}$/i.test(body.expectedSha256)) {
        throw new UploadSessionError('INVALID_ARGUMENT', 'expectedSha256 must contain 64 hexadecimal characters');
    }
    return { sizeBytes, sha256: body.expectedSha256.toLowerCase() };
}

function partSize(session, partNumber) {
    if (!Number.isSafeInteger(partNumber) || partNumber < 1 || session.expectedSizeBytes == null) return null;
    const total = Number(session.expectedSizeBytes);
    if (!Number.isSafeInteger(total) || total < 1 || total > MAX_UPLOAD_SIZE_BYTES) return null;
    const count = Math.ceil(total / MAX_PART_SIZE_BYTES);
    if (partNumber > count) return null;
    return partNumber === count ? total - (count - 1) * MAX_PART_SIZE_BYTES : MAX_PART_SIZE_BYTES;
}

function parsePartNumber(value) {
    return typeof value === 'string' && /^[1-9]\d*$/.test(value) ? Number(value) : NaN;
}

function serializeSession(session) {
    const total = Number(session.expectedSizeBytes);
    return {
        id: session.id,
        assetId: session.assetId,
        clipId: session.clipId,
        status: session.status,
        expectedSizeBytes: session.expectedSizeBytes?.toString() ?? null,
        expectedSha256: session.expectedSha256,
        partSizeBytes: MAX_PART_SIZE_BYTES,
        partCount: Number.isSafeInteger(total) && total > 0
            ? Math.ceil(total / MAX_PART_SIZE_BYTES)
            : null,
        expiresAt: session.expiresAt,
        completedAt: session.completedAt,
        parts: session.parts.map(part => ({
            partNumber: part.partNumber,
            sizeBytes: part.sizeBytes.toString(),
            sha256: part.sha256,
        })),
    };
}

function assertVisibleSession(session, ownerId) {
    if (session.asset.userId !== ownerId || !['ACTIVE', 'PAUSED'].includes(session.asset.moderation)) {
        throw new UploadSessionError('NOT_FOUND', 'Upload session not found');
    }
}

async function handleErrors(reply, work, { closeConnection = false } = {}) {
    try {
        return await work();
    } catch (error) {
        if ((error instanceof UploadSessionError || error instanceof StorageError) && ERROR_STATUS[error.code]) {
            if (error.code === 'STORAGE_UNAVAILABLE') {
                reply.request.log.error({ err: { message: error.message } }, 'Original storage is unavailable');
            }
            if (closeConnection) reply.header('Connection', 'close');
            return reply.status(ERROR_STATUS[error.code]).send({ error: error.message });
        }
        throw error;
    }
}

export default async function uploadSessionRoutes(fastify, {
    db = prisma,
    storage,
    storageDriver = 'local',
    signingSecret,
    now = () => new Date(),
    withLock = withAssetMediaLock,
}) {
    if (!storage || typeof signingSecret !== 'string' || Buffer.byteLength(signingSecret) < 32) {
        throw new TypeError('Upload routes require a storage driver and signing secret');
    }
    const sessions = createUploadSessionService({ db, storage, storageDriver, now });

    fastify.decorateRequest('uploadPartAuthorization', null);
    fastify.addContentTypeParser('application/octet-stream', (_request, payload, done) => done(null, payload));
    fastify.addHook('onSend', async (_request, reply, payload) => {
        reply.header('Cache-Control', 'no-store');
        return payload;
    });

    fastify.post('/api/assets/:id/upload-sessions', {
        preHandler: [fastify.authenticate],
        config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
    }, async (request, reply) => handleErrors(reply, async () => {
        const { sizeBytes, sha256 } = validateCreateInput(request.body);
        const assetId = request.params.id;
        const ownerId = request.user.id;
        const locked = await withLock(assetId, async assertLocked => {
            const asset = await db.asset.findUnique({ where: { id: assetId } });
            if (!asset || asset.userId !== ownerId) {
                throw new UploadSessionError('NOT_FOUND', 'Asset not found');
            }
            if (asset.moderation !== 'ACTIVE' || asset.status !== 'UPLOADING') {
                throw new UploadSessionError('ASSET_NOT_ACTIVE', 'Asset is not accepting original uploads');
            }
            const previous = await db.uploadSession.findFirst({
                where: { assetId },
                orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
            });
            if (previous && previous.ownerId !== ownerId) {
                throw new UploadSessionError('CLIP_CHANGED', 'Asset has an upload owned by another user');
            }
            if (previous?.status === 'COMPLETED') {
                if (previous.expectedSizeBytes !== sizeBytes || previous.expectedSha256 !== sha256) {
                    throw new UploadSessionError('SESSION_EXISTS', 'Asset already has a completed original');
                }
                return { session: await sessions.get({ ownerId, uploadSessionId: previous.id }), created: false };
            }
            await assertLocked();
            const session = await sessions.create({
                ownerId,
                assetId,
                clipId: previous?.clipId || randomUUID(),
                expectedSizeBytes: sizeBytes,
                expectedSha256: sha256,
                initializeClip: true,
            });
            await assertLocked();
            const resumed = await sessions.get({ ownerId, uploadSessionId: session.id });
            return { session: resumed, created: session.id !== previous?.id };
        });
        if (!locked.acquired) {
            throw new UploadSessionError('SESSION_BUSY', 'Asset media is being changed; retry the request');
        }
        return reply.status(locked.value.created ? 201 : 200).send({
            uploadSession: serializeSession(locked.value.session),
        });
    }));

    fastify.get('/api/upload-sessions/:sessionId', {
        preHandler: [fastify.authenticate],
    }, async (request, reply) => handleErrors(reply, async () => {
        const session = await sessions.get({
            ownerId: request.user.id,
            uploadSessionId: request.params.sessionId,
        });
        assertVisibleSession(session, request.user.id);
        return { uploadSession: serializeSession(session) };
    }));

    fastify.post('/api/upload-sessions/:sessionId/parts/:partNumber/sign', {
        preHandler: [fastify.authenticate],
    }, async (request, reply) => handleErrors(reply, async () => {
        const partNumber = parsePartNumber(request.params.partNumber);
        const session = await sessions.get({
            ownerId: request.user.id,
            uploadSessionId: request.params.sessionId,
        });
        if (session.status === 'EXPIRED') {
            throw new UploadSessionError('EXPIRED', 'Upload session has expired');
        }
        if (session.status !== 'OPEN') {
            throw new UploadSessionError('INVALID_STATE', 'Upload session is not open');
        }
        assertAcceptingUploads(session);
        const sizeBytes = partSize(session, partNumber);
        if (sizeBytes == null) throw new UploadSessionError('INVALID_ARGUMENT', 'Part number is outside this upload');
        const expires = Math.floor(Math.min(now().getTime() + PART_URL_TTL_MS, session.expiresAt.getTime()) / 1000);
        if (expires * 1000 <= now().getTime()) {
            throw new UploadSessionError('EXPIRED', 'Upload session has expired');
        }
        const claims = { ownerId: session.ownerId, sessionId: session.id, partNumber, sizeBytes, expires };
        const signature = signUploadPart(signingSecret, claims);
        const url = `/api/upload-sessions/${session.id}/parts/${partNumber}?expires=${expires}&signature=${signature}`;
        return { url, partNumber, sizeBytes, expiresAt: new Date(expires * 1000) };
    }));

    fastify.put('/api/upload-sessions/:sessionId/parts/:partNumber', {
        bodyLimit: MAX_PART_SIZE_BYTES,
        onRequest: async (request, reply) => {
            const reject = (status, error) => reply.header('Connection', 'close').status(status).send({ error });
            const sessionId = request.params.sessionId;
            const partNumber = parsePartNumber(request.params.partNumber);
            const expiresValue = request.query?.expires;
            const expires = typeof expiresValue === 'string' && /^\d{1,12}$/.test(expiresValue)
                ? Number(expiresValue)
                : NaN;
            if (!SESSION_ID_PATTERN.test(sessionId) || !Number.isSafeInteger(partNumber)
                || !Number.isSafeInteger(expires) || expires * 1000 <= now().getTime()) {
                return reject(403, 'Invalid or expired upload URL');
            }
            const session = await db.uploadSession.findUnique({
                where: { id: sessionId },
                select: {
                    id: true,
                    ownerId: true,
                    expectedSizeBytes: true,
                    expiresAt: true,
                    status: true,
                    owner: { select: { status: true } },
                    asset: { select: { userId: true, moderation: true, status: true } },
                },
            });
            const sizeBytes = session && partSize(session, partNumber);
            const claims = session && { ownerId: session.ownerId, sessionId, partNumber, sizeBytes, expires };
            if (!session || sizeBytes == null || session.status !== 'OPEN'
                || session.expiresAt.getTime() <= now().getTime()
                || expires * 1000 > session.expiresAt.getTime()
                || session.owner.status !== 'ACTIVE'
                || session.asset.userId !== session.ownerId
                || session.asset.moderation !== 'ACTIVE'
                || !['UPLOADING', 'PROCESSING'].includes(session.asset.status)
                || !verifyUploadPart(signingSecret, claims, request.query?.signature)) {
                return reject(403, 'Invalid or expired upload URL');
            }
            const length = request.headers['content-length'];
            if (typeof length !== 'string' || !/^\d+$/.test(length) || request.headers['transfer-encoding']) {
                return reject(411, 'A Content-Length is required for upload parts');
            }
            if (Number(length) > MAX_PART_SIZE_BYTES) return reject(413, 'Upload part is too large');
            if (Number(length) !== sizeBytes) return reject(400, 'Content-Length does not match the signed part size');
            const contentType = request.headers['content-type'];
            if (typeof contentType !== 'string'
                || contentType.split(';', 1)[0].trim().toLowerCase() !== 'application/octet-stream') {
                return reject(415, 'Upload parts require application/octet-stream');
            }
            request.uploadPartAuthorization = { ownerId: session.ownerId, partNumber, sizeBytes };
        },
    }, async (request, reply) => handleErrors(reply, async () => {
        const { ownerId, partNumber, sizeBytes } = request.uploadPartAuthorization;
        const part = await sessions.uploadPart({
            ownerId,
            uploadSessionId: request.params.sessionId,
            partNumber,
            body: request.body,
            expectedSizeBytes: sizeBytes,
        });
        return { part };
    }, { closeConnection: true }));

    fastify.post('/api/upload-sessions/:sessionId/complete', {
        preHandler: [fastify.authenticate],
    }, async (request, reply) => handleErrors(reply, async () => {
        await sessions.complete({
            ownerId: request.user.id,
            uploadSessionId: request.params.sessionId,
        });
        const session = await sessions.get({
            ownerId: request.user.id,
            uploadSessionId: request.params.sessionId,
        });
        assertVisibleSession(session, request.user.id);
        return { uploadSession: serializeSession(session) };
    }));

    fastify.delete('/api/upload-sessions/:sessionId', {
        preHandler: [fastify.authenticate],
    }, async (request, reply) => handleErrors(reply, async () => {
        const session = await sessions.abort({
            ownerId: request.user.id,
            uploadSessionId: request.params.sessionId,
        });
        return { uploadSession: session };
    }));
}
