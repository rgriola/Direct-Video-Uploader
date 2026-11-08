import { unlink } from 'fs/promises';
import path from 'path';
import prisma from '../lib/prisma.js';
import {
    deleteMuxAsset,
    disableMuxPlayback,
    enableMuxPlayback,
} from '../lib/mux.js';
import { teamScope } from '../lib/authorization.js';
import { isSuperAdmin, ROLES } from '../lib/roles.js';

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

function disconnectUserSockets(fastify, userId) {
    const sockets = fastify.userSockets?.get(userId) || [];
    for (const socketId of sockets) {
        fastify.io?.sockets?.sockets?.get(socketId)?.disconnect(true);
    }
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

async function writeAssetModeration({ id, currentModeration, moderation, actor, reason, playbackUpdates = [] }) {
    return prisma.$transaction(async (tx) => {
        const updated = await tx.asset.updateMany({
            where: { id, moderation: currentModeration },
            data: {
                moderation,
                moderatedAt: new Date(),
                moderatedById: actorId(actor),
                moderationReason: reason,
            },
        });
        if (updated.count !== 1) return false;
        for (const playback of playbackUpdates) {
            await tx.clip.update({
                where: { id: playback.clipId },
                data: playback.data,
            });
        }

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

async function preparePublicPlayback(clips, request) {
    const playbackUpdates = [];
    for (const clip of clips) {
        if (!clip.muxAssetId) {
            if (clip.muxPlaybackId) {
                request.log.error({ clipId: clip.id }, 'Cannot restore Mux playback without its asset ID');
                return { ok: false, playbackUpdates };
            }
            continue;
        }

        const result = await enableMuxPlayback(clip.muxAssetId);
        if (!result.ok) {
            request.log.error(
                { clipId: clip.id, muxAssetId: clip.muxAssetId, error: result.error },
                'Could not restore Mux playback'
            );
            return { ok: false, playbackUpdates };
        }

        if (result.playbackId) {
            const playbackId = result.playbackId;
            playbackUpdates.push({
                clipId: clip.id,
                data: {
                    muxPlaybackId: playbackId,
                    streamUrl: `https://stream.mux.com/${playbackId}.m3u8`,
                    thumbnailUrl: `https://image.mux.com/${playbackId}/thumbnail.png?width=640`,
                },
            });
        }
    }
    return { ok: true, playbackUpdates };
}

async function revokePublicPlayback(clips, request) {
    for (const clip of clips) {
        if (!clip.muxAssetId) {
            if (clip.muxPlaybackId) {
                request.log.error({ clipId: clip.id }, 'Cannot revoke Mux playback without its asset ID');
                return false;
            }
            continue;
        }

        const result = await disableMuxPlayback(clip.muxAssetId);
        if (!result.ok) {
            request.log.error(
                { clipId: clip.id, muxAssetId: clip.muxAssetId, error: result.error },
                'Could not revoke Mux playback'
            );
            return false;
        }
        await prisma.clip.update({
            where: { id: clip.id },
            data: { muxPlaybackId: null, streamUrl: null, thumbnailUrl: null },
        });
    }
    return true;
}

async function persistPlaybackIfActive(assetId, playbackUpdates) {
    return prisma.$transaction(async tx => {
        const rows = await tx.$queryRaw`
            SELECT moderation FROM assets WHERE id = ${assetId} FOR UPDATE
        `;
        if (!rows.length || rows[0].moderation !== 'ACTIVE') return false;
        for (const playback of playbackUpdates) {
            await tx.clip.update({
                where: { id: playback.clipId },
                data: playback.data,
            });
        }
        return true;
    });
}

async function deleteLocalOriginals(clips, request) {
    const uploadsRoot = path.resolve(process.cwd(), 'uploads');
    let failed = false;
    for (const clip of clips) {
        if (!clip.storageUrl?.startsWith('/uploads/')) continue;
        const filePath = path.resolve(process.cwd(), clip.storageUrl.slice(1));
        if (!filePath.startsWith(`${uploadsRoot}${path.sep}`)) {
            request.log.error({ clipId: clip.id }, 'Refusing to delete a local file outside uploads');
            failed = true;
            continue;
        }
        try {
            await unlink(filePath);
        } catch (err) {
            if (err.code !== 'ENOENT') {
                request.log.error(
                    { clipId: clip.id, err: { message: err.message } },
                    'Could not delete local original during asset removal'
                );
                failed = true;
            }
        }
    }
    return !failed;
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
            if (status === 'SUSPENDED') disconnectUserSockets(fastify, id);
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

        if (status === 'SUSPENDED') {
            disconnectUserSockets(fastify, id);
        }

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

        let clips = [];
        let playbackUpdates = [];
        if (moderation === 'ACTIVE') {
            clips = await prisma.clip.findMany({
                where: { assetId: id },
                select: { id: true, muxAssetId: true, muxPlaybackId: true, storageUrl: true },
            });
            const prepared = await preparePublicPlayback(clips, request);
            playbackUpdates = prepared.playbackUpdates;
            if (!prepared.ok) {
                const cleanupSucceeded = await revokePublicPlayback(clips, request);
                return reply.status(502).send({
                    error: cleanupSucceeded
                        ? 'Could not restore video playback; asset remains unavailable'
                        : 'Could not restore playback and cleanup partially created Mux IDs; asset remains unavailable',
                });
            }
        }

        if (current !== moderation) {
            let updated;
            try {
                updated = await writeAssetModeration({
                    id,
                    currentModeration: current,
                    moderation,
                    actor: request.user,
                    reason,
                    playbackUpdates,
                });
            } catch (err) {
                if (moderation === 'ACTIVE') await revokePublicPlayback(clips, request);
                throw err;
            }
            if (!updated) {
                if (moderation === 'ACTIVE' && !await revokePublicPlayback(clips, request)) {
                    return reply.status(502).send({ error: 'Asset state changed and playback cleanup failed' });
                }
                return reply.status(409).send({ error: 'Asset moderation changed; refresh and try again' });
            }
        } else if (moderation === 'ACTIVE') {
            let persisted;
            try {
                persisted = await persistPlaybackIfActive(id, playbackUpdates);
            } catch (err) {
                await revokePublicPlayback(clips, request);
                throw err;
            }
            if (!persisted) {
                if (!await revokePublicPlayback(clips, request)) {
                    return reply.status(502).send({ error: 'Asset state changed and playback cleanup failed' });
                }
                return reply.status(409).send({ error: 'Asset moderation changed; refresh and try again' });
            }
        }

        if (moderation === 'PAUSED' || moderation === 'FLAGGED_FOR_REMOVAL') {
            clips = await prisma.clip.findMany({
                where: { assetId: id },
                select: { id: true, muxAssetId: true, muxPlaybackId: true, storageUrl: true },
            });
            if (!await revokePublicPlayback(clips, request)) {
                return reply.status(502).send({
                    error: `Asset is ${moderation.toLowerCase()}, but Mux playback revocation failed. Retry this action.`,
                });
            }
        } else if (moderation === 'REMOVED') {
            clips = await prisma.clip.findMany({
                where: { assetId: id },
                select: { id: true, muxAssetId: true, muxPlaybackId: true, storageUrl: true },
            });
            let muxDeletionFailed = clips.some(clip => clip.muxPlaybackId && !clip.muxAssetId);
            if (muxDeletionFailed) {
                request.log.error({ assetId: id }, 'Cannot remove Mux playback without its asset ID');
            }
            for (const muxAssetId of new Set(clips.map(clip => clip.muxAssetId).filter(Boolean))) {
                if (!await deleteMuxAsset(muxAssetId)) muxDeletionFailed = true;
            }
            const localDeletionSucceeded = await deleteLocalOriginals(clips, request);
            if (muxDeletionFailed || !localDeletionSucceeded) {
                request.log.error({ assetId: id, muxDeletionFailed, localDeletionSucceeded }, 'Asset removal is incomplete');
                return reply.status(502).send({
                    error: 'Asset is marked removed, but media cleanup failed. Retry removal after checking server and Mux availability.',
                });
            }
            await prisma.clip.updateMany({
                where: { assetId: id },
                data: {
                    muxAssetId: null,
                    muxPlaybackId: null,
                    streamUrl: null,
                    thumbnailUrl: null,
                    storageUrl: null,
                },
            });
        }

        request.log.info({ assetId: id, moderation }, 'Admin changed asset moderation');
        return { asset: { id, moderation }, message: `Asset ${moderation.toLowerCase()}` };
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
