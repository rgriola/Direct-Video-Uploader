import prisma from '../lib/prisma.js';
import { queueAssetMediaSync, recordMuxAssetReference, reconcileAssetMedia } from '../lib/media-reconciliation.js';
import { withAssetMediaLock } from '../lib/media-lock.js';
import { originalReadLockKey } from '../lib/mux-original-read-lock-key.js';
import { lockMuxOriginalRows } from '../lib/mux-original-records.js';
import { teamScope } from '../lib/authorization.js';
import { isSuperAdmin, ROLES } from '../lib/roles.js';
import { invalidateUserSockets } from '../ws/rooms.js';

const ADMIN_ROLES = [ROLES.ADMIN, ROLES.SUPER_ADMIN];
const MAX_REASON_LENGTH = 500;

function parseReason(value, reply) {
    if (value !== undefined && (typeof value !== 'string' || value.length > MAX_REASON_LENGTH)) {
        reply.status(400).send({ error: `reason must be a string up to ${MAX_REASON_LENGTH} characters` });
        return undefined;
    }
    return value?.trim() || null;
}

function canTransitionModeration(current, next, isSuperAdmin) {
    if (current === next) return true;
    if (current === 'ACTIVE') return ['PAUSED', 'FLAGGED_FOR_REMOVAL'].includes(next);
    if (current === 'PAUSED') return ['ACTIVE', 'FLAGGED_FOR_REMOVAL'].includes(next);
    if (current === 'FLAGGED_FOR_REMOVAL' && isSuperAdmin) {
        return ['ACTIVE', 'REMOVED'].includes(next);
    }
    return current === 'REMOVED' && next === 'REMOVED' && isSuperAdmin;
}

function actorId(user) {
    return user.id;
}

async function writeUserStatus({ id, currentStatus, status, actor, reason, pausedAt, protectLastSuperAdmin }) {
    return prisma.$transaction(async (tx) => {
        if (protectLastSuperAdmin) {
            const activeAdmins = await tx.$queryRaw`
                SELECT id
                FROM users
                WHERE role = 'SUPER_ADMIN' AND status = 'ACTIVE'
                ORDER BY id
                FOR UPDATE
            `;
            if (activeAdmins.length <= 1) return { ok: false, lastActiveSuperAdmin: true };
        }

        const updated = await tx.user.updateMany({
            where: {
                id,
                status: currentStatus,
                ...(actor.role === ROLES.ADMIN ? { companyCode: actor.companyCode } : {}),
            },
            data: {
                status,
                pausedAt: status === 'SUSPENDED' ? pausedAt : null,
                pausedById: status === 'SUSPENDED' ? actorId(actor) : null,
            },
        });
        if (updated.count !== 1) return { ok: false, lastActiveSuperAdmin: false };

        await tx.auditLog.create({
            data: {
                actorUserId: actorId(actor),
                targetType: 'USER',
                targetId: id,
                action: status === 'SUSPENDED' ? 'USER_PAUSED' : 'USER_UNPAUSED',
                reason,
            },
        });
        return { ok: true };
    });
}

async function writeAssetModeration({ id, currentModeration, moderation, actor, reason }) {
    return prisma.$transaction(async (tx) => {
        const updated = await tx.asset.updateMany({
            where: { id, moderation: currentModeration },
            data: {
                moderation,
                moderatedAt: new Date(),
                moderatedById: actorId(actor),
                moderationReason: reason,
                mediaSyncState: 'PENDING',
                mediaSyncError: null,
                mediaSyncRevision: { increment: 1 },
                mediaSyncNextAt: new Date(),
                mediaPlaybackReset: true,
            },
        });
        if (updated.count !== 1) return false;
        await tx.auditLog.create({
            data: {
                actorUserId: actorId(actor),
                targetType: 'ASSET',
                targetId: id,
                action: moderation === 'PAUSED'
                    ? 'ASSET_PAUSED'
                    : moderation === 'ACTIVE'
                        ? (currentModeration === 'FLAGGED_FOR_REMOVAL' ? 'ASSET_RESTORED' : 'ASSET_UNPAUSED')
                        : moderation === 'FLAGGED_FOR_REMOVAL'
                            ? 'ASSET_FLAGGED'
                            : 'ASSET_REMOVED',
                reason,
            },
        });
        return true;
    });
}

export default async function moderationRoutes(fastify) {
    fastify.patch('/api/admin/users/:id/status', {
        preHandler: [fastify.authenticate, fastify.requireRole(...ADMIN_ROLES)],
    }, async (request, reply) => {
        const { id } = request.params;
        const { status } = request.body || {};
        const reason = parseReason(request.body?.reason, reply);
        if (reply.sent) return;
        if (!['ACTIVE', 'SUSPENDED'].includes(status)) {
            return reply.status(400).send({ error: 'status must be ACTIVE or SUSPENDED' });
        }
        if (id === request.user.id) {
            return reply.status(400).send({ error: 'You cannot pause your own account' });
        }

        const scope = request.user.role === ROLES.ADMIN
            ? { companyCode: request.user.companyCode }
            : {};
        const target = await prisma.user.findFirst({
            where: { id, ...scope },
            select: { id: true, role: true, status: true },
        });
        if (!target || (target.role === ROLES.SUPER_ADMIN && !isSuperAdmin(request.user.role))) {
            return reply.status(404).send({ error: 'User not found' });
        }
        if (target.status === status) {
            if (status === 'SUSPENDED') invalidateUserSockets(fastify, [id]);
            return { user: { id, status }, message: `User is already ${status === 'ACTIVE' ? 'active' : 'paused'}` };
        }

        const result = await writeUserStatus({
            id,
            currentStatus: target.status,
            status,
            actor: request.user,
            reason,
            pausedAt: new Date(),
            protectLastSuperAdmin: status === 'SUSPENDED' && target.role === ROLES.SUPER_ADMIN,
        });
        if (result.lastActiveSuperAdmin) {
            return reply.status(409).send({ error: 'The last active Super Admin cannot be paused' });
        }
        if (!result.ok) {
            return reply.status(409).send({ error: 'User status changed; refresh and try again' });
        }

        invalidateUserSockets(fastify, [id]);

        request.log.info({ targetUserId: id, status }, 'Admin changed user status');
        return { user: { id, status }, message: status === 'SUSPENDED' ? 'User paused' : 'User unpaused' };
    });

    fastify.patch('/api/admin/assets/:id/moderation', {
        preHandler: [fastify.authenticate, fastify.requireRole(...ADMIN_ROLES)],
    }, async (request, reply) => {
        const { id } = request.params;
        const { moderation } = request.body || {};
        const reason = parseReason(request.body?.reason, reply);
        if (reply.sent) return;
        if (!['ACTIVE', 'PAUSED', 'FLAGGED_FOR_REMOVAL', 'REMOVED'].includes(moderation)) {
            return reply.status(400).send({ error: 'Invalid moderation state' });
        }
        if (moderation === 'REMOVED' && !isSuperAdmin(request.user.role)) {
            return reply.status(403).send({ error: 'Only a Super Admin may remove an asset' });
        }
        if (['FLAGGED_FOR_REMOVAL', 'REMOVED'].includes(moderation) && !reason) {
            return reply.status(400).send({ error: 'A reason is required for flagging or removing an asset' });
        }

        const scope = teamScope(request.user);
        const asset = await prisma.asset.findFirst({
            where: { id, ...scope },
            select: { id: true, moderation: true },
        });
        if (!asset || (asset.moderation === 'REMOVED' && !isSuperAdmin(request.user.role))) {
            return reply.status(404).send({ error: 'Asset not found' });
        }

        const current = asset.moderation;
        const isSuper = isSuperAdmin(request.user.role);
        if (!canTransitionModeration(current, moderation, isSuper)) {
            return reply.status(409).send({ error: `Cannot change moderation from ${current} to ${moderation}` });
        }

        let updated;
        if (current !== moderation) {
            updated = await writeAssetModeration({
                id,
                currentModeration: current,
                moderation,
                actor: request.user,
                reason,
            });
        } else {
            const result = await prisma.asset.updateMany({
                where: { id, moderation: current },
                data: {
                    mediaSyncState: 'PENDING',
                    mediaSyncError: null,
                    mediaSyncRevision: { increment: 1 },
                    mediaSyncNextAt: new Date(),
                },
            });
            updated = result.count === 1;
        }
        if (!updated) return reply.status(409).send({ error: 'Asset moderation changed; refresh and try again' });

        const sync = await reconcileAssetMedia(fastify, id);
        if (sync.state === 'MISSING') return reply.status(404).send({ error: 'Asset not found' });
        const latest = await prisma.asset.findUnique({
            where: { id },
            select: { moderation: true, mediaSyncState: true },
        });
        if (!latest) return reply.status(404).send({ error: 'Asset not found' });
        if (latest.moderation !== moderation) {
            return reply.status(409).send({ error: 'Asset moderation changed; refresh and try again' });
        }
        request.log.info({ assetId: id, moderation }, 'Admin changed asset moderation');
        const state = sync.state === 'ERROR' ? 'ERROR' : latest.mediaSyncState;
        const complete = state === 'SYNCED';
        return reply.status(complete ? 200 : 202).send({
            asset: { id, moderation },
            mediaSyncState: state,
            message: complete
                ? `Asset ${moderation.toLowerCase()}`
                : `Asset ${moderation.toLowerCase()}; ${sync.state === state ? sync.message : 'media reconciliation is pending'}`,
        });
    });

    fastify.post('/api/admin/assets/:id/media-sync/confirm-create', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async (request, reply) => {
        const { id } = request.params;
        const { operationId, confirmed } = request.body || {};
        const reason = parseReason(request.body?.reason, reply);
        if (reply.sent) return;
        if (typeof operationId !== 'string' || !operationId || confirmed !== true || !reason) {
            return reply.status(400).send({ error: 'A Mux confirmation, operation ID, and reason are required' });
        }

        const locked = await withAssetMediaLock(id, async assertLocked => {
            await assertLocked();
            return prisma.$transaction(async tx => {
                const rows = await tx.$queryRaw`
                    SELECT media_create_operation_id, media_create_mux_asset_id
                    FROM assets WHERE id = ${id} FOR UPDATE
                `;
                if (!rows.length) return 'missing';
                if (rows[0].media_create_operation_id !== operationId) return 'changed';
                await recordMuxAssetReference(tx, {
                    assetId: id,
                    muxAssetId: rows[0].media_create_mux_asset_id,
                });
                await tx.asset.update({
                    where: { id },
                    data: {
                        mediaCreateOperationId: null,
                        mediaCreateMuxAssetId: null,
                        mediaCreateStartedAt: null,
                        mediaPlaybackReset: true,
                        mediaSyncState: 'PENDING',
                        mediaSyncError: null,
                        mediaSyncRevision: { increment: 1 },
                        mediaSyncNextAt: new Date(),
                    },
                });
                await tx.auditLog.create({
                    data: {
                        actorUserId: actorId(request.user),
                        targetType: 'ASSET',
                        targetId: id,
                        action: 'MEDIA_CREATE_CONFIRMED',
                        reason: `Operation ${operationId}: ${reason}`,
                    },
                });
                return 'confirmed';
            });
        });
        if (!locked.acquired) return reply.status(409).send({ error: 'Media reconciliation is still in progress' });
        if (locked.value === 'missing') return reply.status(404).send({ error: 'Asset not found' });
        if (locked.value !== 'confirmed') return reply.status(409).send({ error: 'Playback operation changed; refresh and try again' });

        const sync = await reconcileAssetMedia(fastify, id);
        if (sync.state === 'MISSING') return reply.status(404).send({ error: 'Asset not found' });
        return reply.status(sync.state === 'SYNCED' ? 200 : 202).send({
            mediaSyncState: sync.state,
            message: sync.message,
        });
    });

    fastify.post('/api/admin/assets/:id/mux-ingest/confirm-absent', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async (request, reply) => {
        const { id } = request.params;
        const { operationId, confirmed } = request.body || {};
        const reason = parseReason(request.body?.reason, reply);
        if (reply.sent) return;
        if (typeof operationId !== 'string' || !operationId || confirmed !== true || !reason) {
            return reply.status(400).send({ error: 'A Mux absence confirmation, operation ID, and reason are required' });
        }
        const initial = await prisma.muxIngestAttempt.findUnique({
            where: { id: operationId },
            include: { job: { include: { uploadSession: true } } },
        });
        if (!initial || initial.job.uploadSession.assetId !== id) {
            return reply.status(404).send({ error: 'Mux ingest attempt not found' });
        }

        const locked = await withAssetMediaLock(id, async assertLocked => {
            await assertLocked();
            return prisma.$transaction(async tx => {
                await lockMuxOriginalRows(tx, initial.job.uploadSession);
                const attempt = await tx.muxIngestAttempt.findUnique({
                    where: { id: operationId },
                    include: { job: { include: { uploadSession: { include: { clip: true } } } } },
                });
                if (!attempt || attempt.job.uploadSession.assetId !== id
                    || attempt.status !== 'UNKNOWN' || attempt.job.status !== 'UNKNOWN'
                    || attempt.job.currentAttemptId !== operationId) return 'changed';
                const key = originalReadLockKey(id);
                const reads = await tx.$queryRaw`
                    SELECT pg_try_advisory_xact_lock(hashtextextended(${key}, 0)) AS acquired
                `;
                if (!reads[0]?.acquired || await tx.muxOriginalReadLease.count({ where: { assetId: id } })) {
                    return 'read-active';
                }
                if (attempt.muxAssetId || attempt.job.uploadSession.clip.muxAssetId
                    || await tx.muxAssetReference.findFirst({ where: { assetId: id } })) return 'changed';

                await tx.muxIngestAttempt.update({
                    where: { id: operationId },
                    data: { status: 'CONFIRMED_ABSENT', resolvedAt: new Date() },
                });
                await tx.muxIngestJob.update({
                    where: { uploadSessionId: attempt.uploadSessionId },
                    data: {
                        status: 'FAILED',
                        nextAttemptAt: null,
                        lastError: 'Mux asset absence confirmed; the owner may request a retry',
                    },
                });
                await queueAssetMediaSync(tx, id);
                await tx.auditLog.create({
                    data: {
                        actorUserId: actorId(request.user),
                        targetType: 'ASSET',
                        targetId: id,
                        action: 'MUX_INGEST_CONFIRMED_ABSENT',
                        reason: `Operation ${operationId}: ${reason}`,
                    },
                });
                return 'confirmed';
            });
        });
        if (!locked.acquired) return reply.status(409).send({ error: 'Media reconciliation is still in progress' });
        if (locked.value === 'read-active') {
            return reply.status(409).send({ error: 'Original reads are still active or require recovery' });
        }
        if (locked.value !== 'confirmed') {
            return reply.status(409).send({ error: 'Mux ingest attempt changed; refresh and try again' });
        }
        const sync = await reconcileAssetMedia(fastify, id);
        return reply.status(sync.state === 'SYNCED' ? 200 : 202).send({
            mediaSyncState: sync.state,
            message: sync.message,
        });
    });

    fastify.post('/api/admin/assets/:id/original-reads/confirm-closed', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async (request, reply) => {
        const { id } = request.params;
        const { leaseId, confirmed } = request.body || {};
        const reason = parseReason(request.body?.reason, reply);
        if (reply.sent) return;
        if (typeof leaseId !== 'string' || !leaseId || confirmed !== true || !reason) {
            return reply.status(400).send({ error: 'A closed-read confirmation, lease ID, and reason are required' });
        }

        const locked = await withAssetMediaLock(id, async assertLocked => {
            await assertLocked();
            return prisma.$transaction(async tx => {
                const rows = await tx.$queryRaw`SELECT id FROM assets WHERE id = ${id} FOR UPDATE`;
                if (!rows.length) return 'missing';
                const key = originalReadLockKey(id);
                const reads = await tx.$queryRaw`
                    SELECT pg_try_advisory_xact_lock(hashtextextended(${key}, 0)) AS acquired
                `;
                if (!reads[0]?.acquired) return 'read-active';
                const removed = await tx.muxOriginalReadLease.deleteMany({ where: { id: leaseId, assetId: id } });
                if (removed.count !== 1) return 'changed';
                await queueAssetMediaSync(tx, id);
                await tx.auditLog.create({
                    data: {
                        actorUserId: actorId(request.user),
                        targetType: 'ASSET',
                        targetId: id,
                        action: 'ORIGINAL_READ_CONFIRMED_CLOSED',
                        reason: `Lease ${leaseId}: ${reason}`,
                    },
                });
                return 'confirmed';
            });
        });
        if (!locked.acquired) return reply.status(409).send({ error: 'Media reconciliation is still in progress' });
        if (locked.value === 'missing') return reply.status(404).send({ error: 'Asset not found' });
        if (locked.value === 'read-active') return reply.status(409).send({ error: 'Original reads are still active' });
        if (locked.value !== 'confirmed') return reply.status(409).send({ error: 'Original read lease changed' });
        const sync = await reconcileAssetMedia(fastify, id);
        return reply.status(sync.state === 'SYNCED' ? 200 : 202).send({
            mediaSyncState: sync.state,
            message: sync.message,
        });
    });

    fastify.get('/api/admin/media-issues', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async () => {
        const issues = await prisma.asset.findMany({
            where: {
                OR: [
                    { mediaSyncState: 'ERROR' },
                    { mediaCreateOperationId: { not: null } },
                    { moderation: 'ACTIVE', mediaPlaybackReset: true },
                    { moderation: { not: 'ACTIVE' }, mediaSyncState: 'PENDING' },
                    { uploadSessions: { some: { muxIngestJob: { is: { status: { in: ['CREATING', 'UNKNOWN', 'CONFLICT', 'FAILED'] } } } } } },
                    { originalReadLeases: { some: {} } },
                ],
            },
            select: {
                id: true,
                mediasourceId: true,
                moderation: true,
                moderationReason: true,
                mediaSyncState: true,
                mediaSyncError: true,
                mediaSyncNextAt: true,
                mediaPlaybackReset: true,
                mediaCreateOperationId: true,
                mediaCreateMuxAssetId: true,
                mediaCreateStartedAt: true,
                uploadSessions: {
                    where: { muxIngestJob: { is: { status: { in: ['CREATING', 'UNKNOWN', 'CONFLICT', 'FAILED'] } } } },
                    select: {
                        id: true,
                        muxIngestJob: {
                            select: {
                                status: true,
                                currentAttemptId: true,
                                attemptCount: true,
                                lastError: true,
                                attempts: {
                                    where: { status: { in: ['CREATING', 'UNKNOWN', 'LINKED'] } },
                                    select: { id: true, status: true, muxAssetId: true, createdAt: true },
                                },
                            },
                        },
                    },
                },
                originalReadLeases: {
                    select: { id: true, attemptId: true, serverInstanceId: true, createdAt: true },
                },
            },
            orderBy: [{ mediaSyncNextAt: 'asc' }, { id: 'asc' }],
            take: 101,
        });
        return { issues: issues.slice(0, 100), hasMore: issues.length > 100 };
    });

    fastify.get('/api/admin/audit-logs', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async (request, reply) => {
        const rawLimit = request.query?.limit;
        const limit = rawLimit === undefined ? 50 : Number(rawLimit);
        if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
            return reply.status(400).send({ error: 'limit must be an integer from 1 to 100' });
        }
        const logs = await prisma.auditLog.findMany({
            orderBy: { createdAt: 'desc' },
            take: limit,
        });
        return { logs };
    });
}
