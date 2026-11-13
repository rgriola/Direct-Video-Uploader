import prisma from '../lib/prisma.js';
import { UploadSessionError } from '../lib/upload-sessions.js';
import { handleErrors } from '../lib/upload-route-errors.js';
import {
    SESSION_ID_PATTERN, lockCancellationIntent, cancellationAssetVisibility, hasInconsistentSessionReferences,
} from '../lib/original-upload-inspection.js';

const MAX_SESSIONS = 100;

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
}
