import { randomUUID } from 'node:crypto';
import prisma from '../lib/prisma.js';
import { withAssetMediaLock } from '../lib/media-lock.js';
import { signUploadPart, verifyUploadPart } from '../lib/upload-part-signing.js';
import { assertAcceptingUploads, createUploadSessionService, UploadSessionError } from '../lib/upload-sessions.js';
import { MAX_PART_SIZE_BYTES, StorageError } from '../lib/storage/local-driver.js';
import { createStorageCapacity } from '../lib/storage/capacity.js';
import { getAssetUploadMode, serializeCreatedAsset } from '../lib/asset-serialization.js';
import { generateMediasourceId, notifyUserSockets, parseClientMetadata } from '../lib/utils.js';
import { notifyDashboardAssetChange } from '../ws/dashboard-notifications.js';

const MAX_UPLOAD_SIZE_BYTES = 500 * 1024 * 1024;
const PART_URL_TTL_MS = 5 * 60 * 1000;
const SESSION_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const METADATA_FIELDS = [
    'gpsLat', 'gpsLon', 'gpsAltitude', 'capturedAt', 'deviceModel', 'osVersion',
    'codec', 'resolution', 'orientation', 'duration',
];
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
    STORAGE_CHANGED: 503,
    STORAGE_CAPACITY_EXCEEDED: 507,
    PART_CONFLICT: 409,
    PART_SIZE_MISMATCH: 400,
    PART_TOO_LARGE: 413,
    IDEMPOTENCY_CONFLICT: 409,
    INTENT_REMOVED: 410,
    INTENT_INCONSISTENT: 503,
};

function validateOriginalAssetInput(body) {
    if (!body || typeof body !== 'object' || Array.isArray(body)
        || typeof body.clientRequestId !== 'string' || !SESSION_ID_PATTERN.test(body.clientRequestId)
        || (body.fileName != null && typeof body.fileName !== 'string')) {
        throw new UploadSessionError('INVALID_ARGUMENT', 'A client request UUID and optional file name are required');
    }
    const { sizeBytes, sha256 } = validateCreateInput(body);
    return { clientRequestId: body.clientRequestId.toLowerCase(), fileName: body.fileName || null, sizeBytes, sha256 };
}

function validateMetadata(raw) {
    if (raw == null) return null;
    if (typeof raw !== 'object' || Array.isArray(raw)) {
        throw new UploadSessionError('INVALID_ARGUMENT', 'metadata must be an object');
    }
    for (const field of ['deviceModel', 'osVersion', 'codec', 'resolution', 'orientation', 'capturedAt']) {
        if (raw[field] != null && typeof raw[field] !== 'string') {
            throw new UploadSessionError('INVALID_ARGUMENT', `metadata.${field} must be a string`);
        }
    }
    for (const field of ['gpsLat', 'gpsLon', 'gpsAltitude', 'duration']) {
        if (raw[field] != null && !['number', 'string'].includes(typeof raw[field])) {
            throw new UploadSessionError('INVALID_ARGUMENT', `metadata.${field} must be numeric`);
        }
    }
    const metadata = parseClientMetadata(raw);
    for (const field of ['gpsLat', 'gpsLon', 'gpsAltitude', 'duration']) {
        const value = raw[field];
        if (value == null || value === '') continue;
        if (typeof value === 'string'
            && !/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i.test(value.trim())) {
            throw new UploadSessionError('INVALID_ARGUMENT', `metadata.${field} must be numeric`);
        }
        const number = Number(value);
        if (!Number.isFinite(number) || (field === 'duration' && number < 0)) {
            throw new UploadSessionError('INVALID_ARGUMENT', `metadata.${field} must be numeric`);
        }
        metadata[field] = field === 'duration' ? Math.trunc(number) : number;
    }
    if (!Number.isFinite(metadata.capturedAt.getTime())
        || !Number.isSafeInteger(metadata.duration) || metadata.duration < 0 || metadata.duration > 2_147_483_647
        || ['gpsLat', 'gpsLon', 'gpsAltitude'].some(field => metadata[field] != null && !Number.isFinite(metadata[field]))
        || (metadata.gpsLat != null && Math.abs(metadata.gpsLat) > 90)
        || (metadata.gpsLon != null && Math.abs(metadata.gpsLon) > 180)) {
        throw new UploadSessionError('INVALID_ARGUMENT', 'metadata contains an invalid date, duration, or location');
    }
    return metadata;
}

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
    return { sizeBytes, sha256: body.expectedSha256.toLowerCase(), metadata: validateMetadata(body.metadata) };
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
            if (error.code === 'STORAGE_UNAVAILABLE' || error.code === 'STORAGE_CHANGED') {
                reply.request.log.error({ err: { message: error.message } }, 'Original storage is unavailable');
            }
            if (error.code === 'STORAGE_CAPACITY_EXCEEDED') {
                reply.request.log.warn({ code: error.code }, 'Original storage capacity is insufficient');
            }
            if (error.code === 'INTENT_INCONSISTENT') {
                reply.request.log.error({ code: error.code }, 'Original upload intent is inconsistent');
            }
            if (closeConnection) reply.header('Connection', 'close');
            return reply.status(ERROR_STATUS[error.code]).send({ error: error.message });
        }
        if (error?.code === 'ENOSPC' || error?.code === 'EDQUOT') {
            reply.request.log.error({ code: error.code }, 'Original storage write failed for lack of space');
            if (closeConnection) reply.header('Connection', 'close');
            return reply.status(507).send({ error: 'Original storage has insufficient free space' });
        }
        throw error;
    }
}

export default async function uploadSessionRoutes(fastify, {
    db = prisma,
    storage,
    storageDriver = 'local',
    signingSecret,
    capacity,
    capacityLimits,
    now = () => new Date(),
    withLock = withAssetMediaLock,
    handoff,
}) {
    if (!storage || typeof signingSecret !== 'string' || Buffer.byteLength(signingSecret) < 32) {
        throw new TypeError('Upload routes require a storage driver and signing secret');
    }
    const storageCapacity = capacity ?? createStorageCapacity({ db, storage, ...capacityLimits });
    const sessions = createUploadSessionService({
        db, storage, storageDriver, capacity: storageCapacity, now, onCompleted: handoff?.onCompleted,
    });

    async function serializeForResponse(session) {
        const result = serializeSession(session);
        if (handoff) {
            const job = await db.muxIngestJob.findUnique({
                where: { uploadSessionId: session.id },
                select: { status: true, attemptCount: true, nextAttemptAt: true, lastError: true },
            });
            result.muxIngest = job;
        }
        return result;
    }

    async function assertMatchingMetadata(previous, metadata, raw) {
        if (!metadata) return;
        const fields = METADATA_FIELDS.filter(field => raw[field] != null && raw[field] !== '');
        if (!fields.length) return;
        const clip = await db.clip.findUnique({
            where: { id: previous.clipId },
            select: {
                assetId: true, gpsLat: true, gpsLon: true, gpsAltitude: true, capturedAt: true,
                deviceModel: true, osVersion: true, codec: true, resolution: true, orientation: true, duration: true,
            },
        });
        if (!clip || clip.assetId !== previous.assetId) {
            throw new UploadSessionError('CLIP_CHANGED', 'Upload session clip cannot be verified');
        }
        const differs = fields.some(field => field === 'capturedAt'
            ? clip.capturedAt?.getTime() !== metadata.capturedAt.getTime()
            : clip[field] !== metadata[field]);
        if (differs) {
            throw new UploadSessionError('IDEMPOTENCY_CONFLICT', 'Upload metadata differs from the original session');
        }
    }

    fastify.decorateRequest('uploadPartAuthorization', null);
    fastify.addContentTypeParser('application/octet-stream', (_request, payload, done) => done(null, payload));
    fastify.addHook('onSend', async (_request, reply, payload) => {
        reply.header('Cache-Control', 'no-store');
        return payload;
    });

    fastify.post('/api/assets/original-uploads', {
        preHandler: [fastify.authenticate],
        config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
    }, async (request, reply) => handleErrors(reply, async () => {
        const { clientRequestId, fileName, sizeBytes, sha256 } = validateOriginalAssetInput(request.body);
        const ownerId = request.user.id;
        const result = await db.$transaction(async tx => {
            const users = await tx.$queryRaw`SELECT id, status FROM users WHERE id = ${ownerId} FOR UPDATE`;
            if (!users.length || users[0].status !== 'ACTIVE') {
                throw new UploadSessionError('ACCOUNT_SUSPENDED', 'Account is suspended');
            }
            const intent = await tx.originalUploadIntent.findUnique({
                where: { userId_clientRequestId: { userId: ownerId, clientRequestId } },
            });
            if (intent) {
                if (!intent.assetId) throw new UploadSessionError('INTENT_REMOVED', 'Original upload asset was removed');
                await tx.$queryRaw`SELECT id FROM assets WHERE id = ${intent.assetId} FOR UPDATE`;
                const asset = await tx.asset.findUnique({
                    where: { id: intent.assetId },
                    include: {
                        clips: { select: { muxUploadId: true } },
                        uploadSessions: { take: 1, select: { id: true } },
                    },
                });
                if (!asset) throw new UploadSessionError('INTENT_REMOVED', 'Original upload asset was removed');
                if (asset.userId !== ownerId || getAssetUploadMode(asset) !== 'ORIGINAL') {
                    throw new UploadSessionError('INTENT_INCONSISTENT', 'Original upload intent cannot be verified');
                }
                if (!['ACTIVE', 'PAUSED'].includes(asset.moderation)) {
                    throw new UploadSessionError('NOT_FOUND', 'Asset not found');
                }
                if (asset.originalIntentSizeBytes == null || asset.originalIntentSha256 == null) {
                    throw new UploadSessionError('INTENT_INCONSISTENT', 'Original upload intent cannot be verified');
                }
                if (asset.originalFileName !== fileName || asset.originalIntentSizeBytes !== Number(sizeBytes)
                    || asset.originalIntentSha256 !== sha256) {
                    throw new UploadSessionError('IDEMPOTENCY_CONFLICT', 'Client request ID belongs to another upload');
                }
                return { asset, created: false };
            }

            const mediasourceId = await generateMediasourceId(tx);
            const asset = await tx.asset.create({
                data: {
                    userId: ownerId,
                    mediasourceId,
                    mediasourceUrl: `/clips/${mediasourceId}`,
                    originalFileName: fileName,
                    status: 'UPLOADING',
                    uploadMode: 'ORIGINAL',
                    originalIntentSizeBytes: Number(sizeBytes),
                    originalIntentSha256: sha256,
                },
            });
            await tx.originalUploadIntent.create({ data: { userId: ownerId, clientRequestId, assetId: asset.id } });
            return { asset, created: true };
        });
        if (result.created) await notifyDashboardAssetChange(fastify, result.asset.id);
        return reply.status(result.created ? 201 : 200).send({ asset: serializeCreatedAsset(result.asset) });
    }));

    fastify.post('/api/assets/:id/upload-sessions', {
        preHandler: [fastify.authenticate],
        config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
    }, async (request, reply) => handleErrors(reply, async () => {
        const { sizeBytes, sha256, metadata: suppliedMetadata } = validateCreateInput(request.body);
        const metadata = suppliedMetadata ?? parseClientMetadata();
        const assetId = request.params.id;
        const ownerId = request.user.id;
        const locked = await withLock(assetId, async assertLocked => {
            const asset = await db.asset.findUnique({
                where: { id: assetId },
                include: { clips: { where: { muxUploadId: { not: null } }, take: 1, select: { id: true } } },
            });
            if (!asset || asset.userId !== ownerId) {
                throw new UploadSessionError('NOT_FOUND', 'Asset not found');
            }
            if (asset.moderation !== 'ACTIVE') {
                throw new UploadSessionError('ASSET_NOT_ACTIVE', 'Asset is not accepting original uploads');
            }
            if (asset.uploadMode === 'MUX' || asset.clips.length) {
                throw new UploadSessionError('CLIP_CHANGED', 'Asset is reserved for a direct Mux upload');
            }
            if ((asset.originalIntentSizeBytes != null || asset.originalIntentSha256 != null)
                && (asset.originalIntentSizeBytes !== Number(sizeBytes) || asset.originalIntentSha256 !== sha256)) {
                throw new UploadSessionError('IDEMPOTENCY_CONFLICT', 'Upload content differs from the original reservation');
            }
            const recoverable = await db.uploadSession.findMany({
                where: { assetId, status: { in: ['OPEN', 'COMPLETING', 'COMPLETED'] } },
                orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
                take: 2,
            });
            if (recoverable.length > 1) {
                throw new UploadSessionError('CLIP_CHANGED', 'Asset has multiple recoverable original sessions');
            }
            const previous = recoverable[0] || await db.uploadSession.findFirst({
                where: { assetId },
                orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
            });
            if (previous && previous.ownerId !== ownerId) {
                throw new UploadSessionError('CLIP_CHANGED', 'Asset has an upload owned by another user');
            }
            if (previous) await assertMatchingMetadata(previous, suppliedMetadata, request.body.metadata);
            if (previous?.status === 'COMPLETED') {
                if (previous.expectedSizeBytes !== sizeBytes || previous.expectedSha256 !== sha256) {
                    throw new UploadSessionError('SESSION_EXISTS', 'Asset already has a completed original');
                }
                return { session: await sessions.get({ ownerId, uploadSessionId: previous.id }), created: false };
            }
            if (asset.status !== 'UPLOADING') {
                throw new UploadSessionError('ASSET_NOT_ACTIVE', 'Asset is not accepting original uploads');
            }
            await assertLocked();
            const session = await sessions.create({
                ownerId,
                assetId,
                clipId: previous?.clipId || randomUUID(),
                expectedSizeBytes: sizeBytes,
                expectedSha256: sha256,
                initializeClip: true,
                metadata,
            });
            await assertLocked();
            const resumed = await sessions.get({ ownerId, uploadSessionId: session.id });
            return { session: resumed, created: session.id !== previous?.id, notify: !previous, asset };
        });
        if (!locked.acquired) {
            throw new UploadSessionError('SESSION_BUSY', 'Asset media is being changed; retry the request');
        }
        const uploadSession = await serializeForResponse(locked.value.session);
        if (locked.value.notify) {
            const asset = locked.value.asset;
            const originalFileName = asset.originalFileName || asset.mediasourceId;
            notifyUserSockets(fastify.io, ownerId, {
                assetId,
                asset: { mediasourceId: asset.mediasourceId, mediasourceUrl: asset.mediasourceUrl, originalFileName },
                userName: request.user.name,
                metadata,
                clip: { id: uploadSession.clipId, fileSize: sizeBytes.toString() },
            });
            await notifyDashboardAssetChange(fastify, assetId);
        }
        return reply.status(locked.value.created ? 201 : 200).send({ uploadSession });
    }));

    fastify.get('/api/upload-sessions/:sessionId', {
        preHandler: [fastify.authenticate],
    }, async (request, reply) => handleErrors(reply, async () => {
        const session = await sessions.get({
            ownerId: request.user.id,
            uploadSessionId: request.params.sessionId,
        });
        assertVisibleSession(session, request.user.id);
        return { uploadSession: await serializeForResponse(session) };
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
        return { uploadSession: await serializeForResponse(session) };
    }));

    if (handoff) {
        fastify.post('/api/upload-sessions/:sessionId/mux-ingest', {
            preHandler: [fastify.authenticate],
            config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
        }, async (request, reply) => handleErrors(reply, async () => {
            const ownerId = request.user.id;
            const session = await sessions.get({ ownerId, uploadSessionId: request.params.sessionId });
            assertVisibleSession(session, ownerId);
            const locked = await withLock(session.assetId, async assertLocked => {
                await assertLocked();
                return handoff.request(db, session, ownerId, now());
            });
            if (!locked.acquired) {
                throw new UploadSessionError('SESSION_BUSY', 'Asset media is being changed; retry the request');
            }
            return reply.status(202).send({ uploadSession: await serializeForResponse(session) });
        }));
    }

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
