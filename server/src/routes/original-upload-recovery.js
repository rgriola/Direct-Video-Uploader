import prisma from '../lib/prisma.js';
import { UploadSessionError } from '../lib/upload-sessions.js';
import { handleErrors } from '../lib/upload-route-errors.js';
import {
    SESSION_ID_PATTERN, lockCancellationIntent, cancellationAssetVisibility, hasInconsistentSessionReferences,
} from '../lib/original-upload-inspection.js';

const MAX_SESSIONS = 100;
const MAX_UNRESERVED_CANCELLATIONS = 100;
const CANCELLATION_QUOTA_WINDOW_MS = 24 * 60 * 60 * 1000;
const MAX_CANCELLATION_SESSIONS = 100;

export default async function originalUploadRecoveryRoutes(fastify, { db = prisma } = {}) {
    fastify.addHook('onSend', async (_request, reply, payload) => {
        reply.header('Cache-Control', 'no-store');
        return payload;
    });

    fastify.get('/api/original-upload-recovery/:clientRequestId', {
        preHandler: [fastify.authenticate],
        config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
    }, async (request, reply) => handleErrors(reply, async () => {
        const rawRequestId = request.params.clientRequestId;
        if (typeof rawRequestId !== 'string' || !SESSION_ID_PATTERN.test(rawRequestId)
            || Object.keys(request.query).length) {
            throw new UploadSessionError('INVALID_ARGUMENT', 'A client request UUID is required');
        }
        const ownerId = request.user.id;
        const result = await db.$transaction(async tx => {
            const { intent } = await lockCancellationIntent(tx, ownerId, rawRequestId.toLowerCase());
            if (!intent) throw new UploadSessionError('NOT_FOUND', 'Original upload intent not found');
            const state = intent.cancelledAt ? 'CANCELLED' : intent.assetId ? 'ACTIVE' : 'REMOVED';
            if (!intent.assetId) return { state, assetId: null, sessions: [], truncated: false };
            const visibility = await cancellationAssetVisibility(tx, intent.assetId, ownerId);
            if (visibility === 'hidden') throw new UploadSessionError('NOT_FOUND', 'Asset not found');
            if (visibility === 'inconsistent' || await hasInconsistentSessionReferences(tx, intent.assetId)) {
                throw new UploadSessionError('INTENT_INCONSISTENT', 'Original upload intent cannot be verified');
            }
            const sessions = await tx.uploadSession.findMany({
                where: { assetId: intent.assetId },
                select: { id: true, ownerId: true, status: true },
                orderBy: { id: 'asc' },
                take: MAX_SESSIONS + 1,
            });
            if (sessions.some(session => session.ownerId !== ownerId || !SESSION_ID_PATTERN.test(session.id))) {
                throw new UploadSessionError('INTENT_INCONSISTENT', 'Original upload intent cannot be verified');
            }
            return {
                state,
                assetId: intent.assetId,
                sessions: sessions.slice(0, MAX_SESSIONS).map(({ id, status }) => ({ id, status })),
                truncated: sessions.length > MAX_SESSIONS,
            };
        }, { isolationLevel: 'ReadCommitted' });
        return reply.send(result);
    }));

    fastify.post('/api/assets/original-uploads/:clientRequestId/cancel', {
        preHandler: [fastify.authenticate],
        config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
    }, async (request, reply) => handleErrors(reply, async () => {
        const rawRequestId = request.params.clientRequestId;
        if (typeof rawRequestId !== 'string' || !SESSION_ID_PATTERN.test(rawRequestId)) {
            throw new UploadSessionError('INVALID_ARGUMENT', 'A client request UUID is required');
        }
        const ownerId = request.user.id;
        const result = await db.$transaction(async tx => {
            const { key, where, intent: lockedIntent } = await lockCancellationIntent(
                tx, ownerId, rawRequestId.toLowerCase());
            let intent = lockedIntent;
            const [{ cancellationTime }] = await tx.$queryRaw`
                SELECT clock_timestamp() AT TIME ZONE 'UTC' AS "cancellationTime"`;
            if (!intent) {
                const recent = await tx.originalUploadIntent.findMany({
                    where: {
                        userId: ownerId,
                        assetId: null,
                        cancelledAt: { gte: new Date(cancellationTime.getTime() - CANCELLATION_QUOTA_WINDOW_MS) },
                    },
                    select: { cancelledAt: true },
                    orderBy: { cancelledAt: 'desc' },
                    take: MAX_UNRESERVED_CANCELLATIONS,
                });
                if (recent.length === MAX_UNRESERVED_CANCELLATIONS) {
                    const oldest = recent[recent.length - 1].cancelledAt;
                    return {
                        retryAfter: Math.max(1, Math.ceil(
                            (oldest.getTime() + CANCELLATION_QUOTA_WINDOW_MS - cancellationTime.getTime()) / 1000)),
                    };
                }
                intent = await tx.originalUploadIntent.create({ data: { ...key, cancelledAt: cancellationTime } });
            } else if (!intent.cancelledAt) {
                if (!intent.assetId) {
                    throw new UploadSessionError('INTENT_REMOVED', 'Original upload asset was removed');
                }
                intent = await tx.originalUploadIntent.update({ where, data: { cancelledAt: cancellationTime } });
            }
            if (!intent.assetId) return { assetId: null, sessionIds: [] };
            const visibility = await cancellationAssetVisibility(tx, intent.assetId, ownerId);
            if (visibility !== 'visible') return { [visibility]: true };
            if (await hasInconsistentSessionReferences(tx, intent.assetId)) return { inconsistent: true };
            const sessions = await tx.uploadSession.findMany({
                where: { assetId: intent.assetId },
                select: { id: true, ownerId: true },
                orderBy: { id: 'asc' },
                take: MAX_CANCELLATION_SESSIONS + 1,
            });
            if (sessions.length > MAX_CANCELLATION_SESSIONS) return { overflow: true };
            if (sessions.some(session => session.ownerId !== ownerId || !SESSION_ID_PATTERN.test(session.id))) {
                return { inconsistent: true };
            }
            return { assetId: intent.assetId, sessionIds: sessions.map(session => session.id) };
        }, { isolationLevel: 'ReadCommitted' });
        if (result.retryAfter) {
            return reply.header('Retry-After', String(result.retryAfter)).status(429).send({
                code: 'INTENT_CANCELLATION_QUOTA',
                error: 'Too many recent unreserved cancellations; retry later',
            });
        }
        if (result.hidden) throw new UploadSessionError('NOT_FOUND', 'Asset not found');
        if (result.inconsistent) {
            throw new UploadSessionError('INTENT_INCONSISTENT', 'Original upload intent cannot be verified');
        }
        if (result.overflow) {
            request.log.error({ code: 'INTENT_SESSION_LIMIT' }, 'Too many original upload sessions to reconcile');
            return reply.status(503).send({
                code: 'INTENT_SESSION_LIMIT',
                error: 'Too many original upload sessions to reconcile',
            });
        }
        return reply.send(result);
    }));

    fastify.get('/api/assets/original-uploads/:clientRequestId/sessions', {
        preHandler: [fastify.authenticate],
        config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
    }, async (request, reply) => handleErrors(reply, async () => {
        const rawRequestId = request.params.clientRequestId;
        const { after } = request.query;
        if (typeof rawRequestId !== 'string' || !SESSION_ID_PATTERN.test(rawRequestId)
            || Object.keys(request.query).some(key => key !== 'after')
            || (after !== undefined && (typeof after !== 'string' || !SESSION_ID_PATTERN.test(after)))) {
            throw new UploadSessionError('INVALID_ARGUMENT', 'A client request UUID and optional cursor UUID are required');
        }
        const ownerId = request.user.id;
        const result = await db.$transaction(async tx => {
            const { intent } = await lockCancellationIntent(tx, ownerId, rawRequestId.toLowerCase());
            if (!intent?.cancelledAt) throw new UploadSessionError('NOT_FOUND', 'Cancelled upload intent not found');
            if (!intent.assetId) {
                if (after) {
                    throw new UploadSessionError('INTENT_INCONSISTENT', 'Original upload intent cannot be verified');
                }
                return { assetId: null, sessionIds: [], nextCursor: null };
            }
            const visibility = await cancellationAssetVisibility(tx, intent.assetId, ownerId);
            if (visibility === 'hidden') throw new UploadSessionError('NOT_FOUND', 'Asset not found');
            if (visibility === 'inconsistent') {
                throw new UploadSessionError('INTENT_INCONSISTENT', 'Original upload intent cannot be verified');
            }
            if (await hasInconsistentSessionReferences(tx, intent.assetId)) {
                throw new UploadSessionError('INTENT_INCONSISTENT', 'Original upload intent cannot be verified');
            }
            const sessions = await tx.uploadSession.findMany({
                where: { assetId: intent.assetId, ...(after ? { id: { gt: after } } : {}) },
                select: { id: true, ownerId: true },
                orderBy: { id: 'asc' },
                take: MAX_CANCELLATION_SESSIONS + 1,
            });
            if (sessions.some(session => session.ownerId !== ownerId || !SESSION_ID_PATTERN.test(session.id))) {
                throw new UploadSessionError('INTENT_INCONSISTENT', 'Original upload intent cannot be verified');
            }
            const page = sessions.slice(0, MAX_CANCELLATION_SESSIONS);
            return {
                assetId: intent.assetId,
                sessionIds: page.map(session => session.id),
                nextCursor: sessions.length > MAX_CANCELLATION_SESSIONS ? page[page.length - 1].id : null,
            };
        }, { isolationLevel: 'ReadCommitted' });
        return reply.send(result);
    }));
}
