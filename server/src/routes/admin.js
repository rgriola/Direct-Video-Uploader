// Last updated: May 9, 2026 - 7:34pm - GPT-5.3-Codex
/**
 * Admin routes — Dashboard data, user management, asset overview.
 * All data is LIVE — no simulated actions.
 */
import { Prisma } from '@prisma/client';
import prisma from '../lib/prisma.js';
import { hashPin } from '../lib/utils.js';
import { assetMediaLockKey } from '../lib/media-lock-key.js';
import { redactCompanyCode, redactPersonName, redactPhoneNumber } from '../lib/redact.js';
import { teamScope, userScope } from '../lib/authorization.js';
import { checkRoleChange, isSuperAdmin, ROLES, sameOrganization } from '../lib/roles.js';
import { invalidateUserSockets } from '../ws/rooms.js';

const ALL_ROLES = [ROLES.SUPER_ADMIN, ROLES.ADMIN, ROLES.USER];
const ADMIN_ROLES = [ROLES.SUPER_ADMIN, ROLES.ADMIN];

function scopedUserFilter(user) {
    const scope = userScope(user);
    if (scope.companyCode) return Prisma.sql`WHERE u.company_code = ${scope.companyCode}`;
    if (scope.id) return Prisma.sql`WHERE u.id = ${scope.id}`;
    return Prisma.empty;
}

function scopedAssetFilter(user, moderationStates) {
    const scope = userScope(user);
    const moderationFilter = Prisma.sql`a.moderation IN (${Prisma.join(moderationStates)})`;
    if (scope.companyCode) {
        return Prisma.sql`WHERE u.company_code = ${scope.companyCode} AND ${moderationFilter}`;
    }
    if (scope.id) {
        return Prisma.sql`WHERE u.id = ${scope.id} AND ${moderationFilter}`;
    }
    return Prisma.sql`WHERE ${moderationFilter}`;
}

export default async function adminRoutes(fastify) {

    /**
     * GET /api/admin/status
     * Triad health — database, server, WebSocket, iOS clients.
     */
    fastify.get('/api/admin/status', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async () => {
        const triad = {
            database: { status: 'unknown', message: '' },
            server: { status: 'ok', uptime: Math.floor(process.uptime()) },
            ios: { status: 'disconnected', clients: 0, message: 'No iOS clients connected' },
            admin: { status: 'disconnected', clients: 0 },
        };

        // Check database
        try {
            await prisma.$queryRaw`SELECT 1`;
            triad.database = { status: 'ok', message: 'Connected' };
        } catch (err) {
            triad.database = { status: 'error', message: err.message };
        }

        // WebSocket connection counts
        const iosSockets = fastify.iosSockets || new Set();
        const adminSockets = fastify.adminSockets || new Set();
        const userSockets = fastify.userSockets || new Map();

        triad.ios = {
            status: iosSockets.size > 0 ? 'connected' : 'disconnected',
            clients: iosSockets.size,
            message: iosSockets.size > 0
                ? `${iosSockets.size} iOS client(s) connected`
                : 'No iOS clients connected — build & run from Xcode',
        };

        triad.admin = {
            status: adminSockets.size > 0 ? 'connected' : 'disconnected',
            clients: adminSockets.size,
        };

        return {
            triad,
            connectedUsers: userSockets.size,
            totalWsConnections: fastify.io?.of('/')?.sockets?.size || 0,
        };
    });

    /**
     * GET /api/admin/stats
     * Returns aggregate stats for the dashboard — all live data.
     */
    fastify.get('/api/admin/stats', {
        preHandler: [fastify.authenticate, fastify.requireRole(...ALL_ROLES)],
    }, async (request) => {
        const userFilter = scopedUserFilter(request.user);
        const result = await prisma.$queryRaw`
            WITH scoped_users AS (
                SELECT u.id, u.status, u.last_login_at FROM users u ${userFilter}
            ), scoped_assets AS (
                SELECT a.id, a.status FROM assets a
                JOIN scoped_users u ON u.id = a.user_id
            )
            SELECT
                (SELECT COUNT(*)::int FROM scoped_users) AS users,
                (SELECT COUNT(*)::int FROM scoped_users WHERE status = 'ACTIVE') AS "activeUsers",
                (SELECT COUNT(*)::int FROM scoped_users WHERE last_login_at IS NOT NULL) AS "loggedInUsers",
                (SELECT COUNT(*)::int FROM scoped_assets) AS assets,
                (SELECT COUNT(*)::int FROM scoped_assets WHERE status = 'READY') AS "readyAssets",
                (SELECT COUNT(*)::int FROM scoped_assets WHERE status = 'UPLOADING') AS "uploadingAssets",
                (SELECT COUNT(*)::int FROM chat_messages m JOIN scoped_users u ON u.id = m.user_id) AS messages,
                (SELECT COUNT(*)::int FROM clips c JOIN scoped_assets a ON a.id = c.asset_id WHERE c.status = 'READY') AS clips,
                ARRAY(SELECT id FROM scoped_users) AS "scopedUserIds"
        `;

        const stats = result[0];
        if (!stats || !Array.isArray(stats.scopedUserIds)) {
            throw new Error('Unable to calculate scoped dashboard statistics');
        }
        const visibleUserIds = new Set(stats.scopedUserIds);
        const userSockets = fastify.userSockets || new Map();
        const iosSockets = fastify.iosSockets || new Set();
        const adminSockets = fastify.adminSockets || new Set();

        let onlineUsers = 0;
        let iosClients = 0;
        let wsConnections = 0;
        for (const [userId, sids] of userSockets) {
            if (!visibleUserIds.has(userId)) continue;
            const hasNonAdmin = [...sids].some(sid => !adminSockets.has(sid));
            if (hasNonAdmin) onlineUsers++;
            for (const sid of sids) {
                wsConnections++;
                if (iosSockets.has(sid)) iosClients++;
            }
        }

        return {
            users: stats.users || 0,
            activeUsers: stats.activeUsers || 0,
            loggedInUsers: stats.loggedInUsers || 0,
            onlineUsers,
            assets: stats.assets || 0,
            readyAssets: stats.readyAssets || 0,
            uploadingAssets: stats.uploadingAssets || 0,
            messages: stats.messages || 0,
            clips: stats.clips || 0,
            iosClients,
            wsConnections,
        };
    });

    /**
     * GET /api/admin/users
     * List all registered users with live status.
     */
    fastify.get('/api/admin/users', {
        preHandler: [fastify.authenticate, fastify.requireRole(...ALL_ROLES)],
    }, async (request) => {
        const userFilter = scopedUserFilter(request.user);
        const users = await prisma.$queryRaw`
            SELECT u.id, u.phone_number AS "phoneNumber", u.name, u.email, u.team, u.status, u.role,
                   u.company_code AS "companyCode",
                   o.company_name AS "companyName",
                   u.created_at AS "createdAt",
                   u.paused_at AS "pausedAt",
                   u.paused_by_id AS "pausedById",
                   u.last_login_at AS "lastLoginAt",
                   (SELECT COUNT(*)::int FROM assets a WHERE a.user_id = u.id) AS "assetCount"
            FROM users u
            LEFT JOIN organizations o ON o.company_code = u.company_code
            ${userFilter}
            ORDER BY u.created_at ASC
        `;

        // Annotate with live online status from WS connections
        const userSockets = fastify.userSockets || new Map();
        const iosSockets = fastify.iosSockets || new Set();

        const enriched = users.map(u => ({
            ...u,
            isOnline: userSockets.has(u.id),
            // Check if any of their sockets are iOS connections
            hasIosConnection: [...(userSockets.get(u.id) || [])].some(sid => iosSockets.has(sid)),
        }));

        return { users: enriched };
    });

    /**
     * GET /api/admin/assets
     * List all assets with user info and form responses.
     */
    fastify.get('/api/admin/assets', {
        preHandler: [fastify.authenticate, fastify.requireRole(...ALL_ROLES)],
    }, async (request, reply) => {
        const requestedModeration = request.query?.moderation;
        if (requestedModeration && !['ACTIVE', 'PAUSED', 'FLAGGED_FOR_REMOVAL'].includes(requestedModeration)) {
            return reply.status(400).send({ error: 'Invalid moderation filter' });
        }
        if (requestedModeration === 'FLAGGED_FOR_REMOVAL' && !isSuperAdmin(request.user.role)) {
            return reply.status(403).send({ error: 'Only a Super Admin can view the removal queue' });
        }
        const moderationStates = requestedModeration
            ? [requestedModeration]
            : request.user.role === ROLES.USER
                ? ['ACTIVE', 'PAUSED']
                : ['ACTIVE'];
        const assetFilter = scopedAssetFilter(request.user, moderationStates);
        const assets = await prisma.$queryRaw`
            SELECT a.id, a.mediasource_id AS "mediasourceId",
                   a.mediasource_url AS "mediasourceUrl", a.status,
                   a.moderation, a.moderated_at AS "moderatedAt",
                   a.moderated_by_id AS "moderatedById",
                   a.moderation_reason AS "moderationReason",
                   a.media_sync_state AS "mediaSyncState",
                   a.media_sync_error AS "mediaSyncError",
                   a.media_sync_next_at AS "mediaSyncNextAt",
                   a.media_playback_reset AS "mediaPlaybackReset",
                   media_visibility.unavailable AS "mediaPlaybackUnavailable",
                   CASE WHEN ${isSuperAdmin(request.user.role)} THEN a.media_create_operation_id END AS "mediaCreateOperationId",
                   CASE WHEN ${isSuperAdmin(request.user.role)} THEN a.media_create_mux_asset_id END AS "mediaCreateMuxAssetId",
                   CASE WHEN ${isSuperAdmin(request.user.role)} THEN a.media_create_started_at END AS "mediaCreateStartedAt",
                   a.clip_count::int AS "clipCount", a.total_duration_seconds::int AS "totalDuration",
                   a.created_at AS "createdAt",
                   json_build_object('id', u.id, 'name', u.name, 'phoneNumber', u.phone_number) AS "user",
                   COALESCE(
                       (SELECT json_agg(json_build_object(
                           'id', c.id, 'assetId', c.asset_id,
                           'status', c.status, 'resolution', c.resolution,
                           'duration', c.duration_seconds, 'orientation', c.orientation,
                           'thumbnailUrl', CASE WHEN media_visibility.unavailable
                               THEN NULL ELSE c.thumbnail_url END
                       ) ORDER BY c.created_at DESC, c.id DESC) FROM clips c WHERE c.asset_id = a.id),
                       '[]'::json
                   ) AS clips,
                   CASE WHEN fr.id IS NOT NULL THEN
                       json_build_object(
                           'id', fr.id, 'slug', fr.slug, 'type', fr.type,
                           'description', fr.description, 'priority', fr.priority,
                           'submittedAt', fr.submitted_at
                       )
                   ELSE NULL END AS "formResponse"
            FROM assets a
            JOIN users u ON u.id = a.user_id
            LEFT JOIN form_responses fr ON fr.asset_id = a.id
            CROSS JOIN LATERAL (
                SELECT (a.moderation <> 'ACTIVE' OR a.media_playback_reset
                    OR a.media_create_operation_id IS NOT NULL) AS unavailable
            ) media_visibility
            ${assetFilter}
            ORDER BY a.created_at DESC
            LIMIT 50
        `;

        return { assets };
    });

    /**
     * GET /api/admin/messages
     * List all chat messages across all users (for admin dashboard).
     */
    fastify.get('/api/admin/messages', {
        preHandler: [fastify.authenticate, fastify.requireRole(...ALL_ROLES)],
    }, async (request) => {
        const messages = await prisma.chatMessage.findMany({
            where: teamScope(request.user),
            orderBy: { createdAt: 'desc' },
            take: 200,
            include: {
                user: { select: { id: true, name: true } },
            },
        });

        return { messages };
    });

    /**
     * POST /api/admin/cleanup-assets
     * Delete stale UPLOADING assets that have no clips (abandoned uploads).
     */
    fastify.post('/api/admin/cleanup-assets', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async (request) => {
        const safeFilter = {
            status: 'UPLOADING',
            moderation: 'ACTIVE',
            clips: { none: {} },
            muxAssetReferences: { none: {} },
            mediaCreateOperationId: null,
        };
        const staleAssets = await prisma.asset.findMany({
            where: {
                ...safeFilter,
            },
            select: { id: true },
        });

        if (staleAssets.length === 0) {
            return { cleaned: 0, message: 'No stale assets found' };
        }

        const candidates = staleAssets.map(a => a.id);
        const ids = await prisma.$transaction(async tx => {
            const locked = await tx.$queryRaw`
                SELECT id FROM assets WHERE id IN (${Prisma.join(candidates)}) ORDER BY id FOR UPDATE
            `;
            const safe = await tx.asset.findMany({
                where: { ...safeFilter, id: { in: locked.map(asset => asset.id) } },
                select: { id: true },
            });
            const safeIds = safe.map(asset => asset.id);
            if (!safeIds.length) return [];
            await tx.chatMessage.deleteMany({ where: { assetId: { in: safeIds } } });
            await tx.asset.deleteMany({ where: { id: { in: safeIds } } });
            return safeIds;
        });

        if (!ids.length) return { cleaned: 0, message: 'No stale assets found' };
        request.log.info(
            { cleanedCount: ids.length, assetIdPrefixes: ids.map(id => id.slice(0, 8)) },
            'Cleaned stale uploading assets'
        );

        return {
            cleaned: ids.length,
            message: `Removed ${ids.length} stale UPLOADING asset(s)`,
            assetIds: ids,
        };
    });

    /**
     * POST /api/admin/users
     * Create a new demo user. Defaults: PIN 0000, role USER.
     */
    fastify.post('/api/admin/users', {
        preHandler: [fastify.authenticate, fastify.requireRole(...ADMIN_ROLES)],
    }, async (request, reply) => {
        const { name, phoneNumber, email, team, companyCode } = request.body || {};

        if (!name || !phoneNumber) {
            return reply.status(400).send({ error: 'name and phoneNumber are required' });
        }

        if (companyCode != null && typeof companyCode !== 'string') {
            return reply.status(400).send({ error: 'companyCode must be a string' });
        }
        if (!isSuperAdmin(request.user.role) && companyCode &&
            !sameOrganization(companyCode, request.user.companyCode)) {
            return reply.status(403).send({ error: 'Team admins can only add users to their own organization' });
        }
        const assignedCompanyCode = isSuperAdmin(request.user.role)
            ? companyCode || null
            : request.user.companyCode;

        // Validate company code if provided
        if (assignedCompanyCode) {
            const org = await prisma.organization.findUnique({ where: { companyCode: assignedCompanyCode } });
            if (!org) {
                return reply.status(400).send({ error: 'Organization not found' });
            }
        }

        // Check phone uniqueness
        const existing = await prisma.user.findUnique({
            where: { phoneNumber },
        });
        if (existing) {
            return reply.status(409).send({ error: `Phone number ${phoneNumber} already exists` });
        }

        const user = await prisma.user.create({
            data: {
                phoneNumber,
                name,
                email: email || null,
                team: team || null,
                companyCode: assignedCompanyCode,
                pinHash: await hashPin('0000'),
                role: 'USER',
            },
        });

        request.log.info(
            {
                userName: redactPersonName(name),
                phoneNumber: redactPhoneNumber(phoneNumber),
                companyCode: redactCompanyCode(assignedCompanyCode),
            },
            'Admin created user'
        );

        return {
            user: {
                id: user.id,
                name: user.name,
                phoneNumber: user.phoneNumber,
                email: user.email,
                team: user.team,
                role: user.role,
                companyCode: user.companyCode,
            },
            message: `Created user ${name} (PIN: 0000)`,
        };
    });

    /**
     * POST /api/admin/nuclear-reset
     * Clear non-media data only when no asset records remain.
     */
    fastify.post('/api/admin/nuclear-reset', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async (request, reply) => {
        const result = await prisma.$transaction(async tx => {
            await tx.$executeRaw`LOCK TABLE assets IN ACCESS EXCLUSIVE MODE`;
            if (await tx.asset.count()) return null;
            const chatDeleted = await tx.chatMessage.deleteMany({});
            const errorDeleted = await tx.errorLog.deleteMany({});
            const formDeleted = await tx.formResponse.deleteMany({});
            const clipDeleted = await tx.clip.deleteMany({});
            return { chatDeleted, errorDeleted, formDeleted, clipDeleted };
        });
        if (!result) {
            return reply.status(409).send({
                error: 'Nuclear Reset is temporarily blocked while asset records exist; media references must be retained for recovery.',
            });
        }

        request.log.warn(
            {
                assetCount: 0,
                clipCount: result.clipDeleted.count,
            },
            'Admin cleared non-media data with no asset records present'
        );

        return {
            message: 'Non-media reset complete; Mux media was not changed',
            deleted: {
                assets: 0,
                clips: result.clipDeleted.count,
                formResponses: result.formDeleted.count,
                chatMessages: result.chatDeleted.count,
                errorLogs: result.errorDeleted.count,
            },
            mux: { deleted: 0, failed: 0, skipped: true },
        };
    });

    /**
     * DELETE /api/admin/users/:id
     * Hard-wipe a user only after all of their media has been removed and verified.
     */
    fastify.delete('/api/admin/users/:id', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async (request, reply) => {
        const { id } = request.params;

        // Guard: admin cannot delete themselves
        if (request.user.id === id) {
            return reply.status(400).send({ error: 'Cannot delete your own account' });
        }

        // Verify user exists
        const target = await prisma.user.findUnique({ where: { id } });
        if (!target) {
            return reply.status(404).send({ error: 'User not found' });
        }
        if (isSuperAdmin(target.role)) {
            return reply.status(403).send({ error: 'Super Admin accounts cannot be deleted through the API' });
        }

        const result = await prisma.$transaction(async tx => {
            const users = await tx.$queryRaw`SELECT role FROM users WHERE id = ${id} FOR UPDATE`;
            if (!users.length) return { status: 'missing' };
            if (users[0].role === 'SUPER_ADMIN') return { status: 'protected' };

            const assets = await tx.$queryRaw`
                SELECT id, moderation, media_sync_state, media_create_operation_id
                FROM assets WHERE user_id = ${id} ORDER BY id FOR UPDATE
            `;
            if (assets.some(asset => asset.moderation !== 'REMOVED'
                || asset.media_sync_state !== 'SYNCED' || asset.media_create_operation_id)) {
                return { status: 'needs-cleanup' };
            }
            for (const asset of assets) {
                const key = assetMediaLockKey(asset.id);
                const locks = await tx.$queryRaw`
                    SELECT pg_try_advisory_xact_lock(hashtextextended(${key}, 0)) AS acquired
                `;
                if (!locks[0]?.acquired) return { status: 'busy' };
            }

            const clips = await tx.clip.count({ where: { asset: { userId: id } } });
            const chatDeleted = await tx.chatMessage.deleteMany({ where: { userId: id } });
            const errorDeleted = await tx.errorLog.deleteMany({ where: { userId: id } });
            const assetDeleted = await tx.asset.deleteMany({ where: { userId: id } });
            await tx.auditLog.create({
                data: {
                    actorUserId: request.user.id,
                    targetType: 'USER',
                    targetId: id,
                    action: 'USER_DELETED',
                },
            });
            await tx.user.delete({ where: { id } });
            return { status: 'deleted', clips, chatDeleted, errorDeleted, assetDeleted };
        });
        if (result.status === 'missing') return reply.status(404).send({ error: 'User not found' });
        if (result.status === 'protected') {
            return reply.status(403).send({ error: 'Super Admin accounts cannot be deleted through the API' });
        }
        if (result.status === 'needs-cleanup') {
            return reply.status(409).send({
                error: 'Remove every asset and wait for media cleanup to finish before deleting this user.',
            });
        }
        if (result.status === 'busy') {
            return reply.status(409).send({ error: 'Media reconciliation is in progress. Please try again.' });
        }
        invalidateUserSockets(fastify, [id]);

        request.log.warn(
            {
                userName: redactPersonName(target.name),
                phoneNumber: redactPhoneNumber(target.phoneNumber),
                assetCount: result.assetDeleted.count,
            },
            'Admin deleted user and associated data'
        );

        return {
            message: `User ${target.name} deleted with all associated data`,
            deleted: {
                assets: result.assetDeleted.count,
                clips: result.clips,
                chatMessages: result.chatDeleted.count,
                errorLogs: result.errorDeleted.count,
                muxAssets: 0,
                localFiles: 0,
            },
        };
    });

    // ─── Organization CRUD ───────────────────────────────────────

    /** Validation helpers */
    const COMPANY_NAME_RE = /^[A-Za-z\s]{1,50}$/;
    const COMPANY_CODE_RE = /^[A-Za-z]{3,4}$/;

    /**
     * GET /api/admin/organizations
     * List all organizations.
     */
    fastify.get('/api/admin/organizations', {
        preHandler: [fastify.authenticate, fastify.requireRole(...ADMIN_ROLES)],
    }, async (request) => {
        const orgs = await prisma.organization.findMany({
            where: isSuperAdmin(request.user.role) ? {} : { companyCode: request.user.companyCode },
            orderBy: { createdAt: 'desc' },
            include: { _count: { select: { users: true } } },
        });

        return {
            organizations: orgs.map(o => ({
                id: o.id,
                companyName: o.companyName,
                companyCode: o.companyCode,
                createdAt: o.createdAt,
                userCount: o._count.users,
            })),
        };
    });

    /**
     * POST /api/admin/organizations
     * Create a new organization.
     */
    fastify.post('/api/admin/organizations', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async (request, reply) => {
        const { companyName, companyCode } = request.body || {};

        if (!companyName || !COMPANY_NAME_RE.test(companyName)) {
            return reply.status(400).send({ error: 'Company name must be 1–50 characters, letters and spaces only' });
        }
        if (!companyCode || !COMPANY_CODE_RE.test(companyCode)) {
            return reply.status(400).send({ error: 'Company code must be 3–4 letters (A-Z, a-z)' });
        }

        // Check uniqueness
        const existing = await prisma.organization.findUnique({ where: { companyCode } });
        if (existing) {
            return reply.status(409).send({ error: `Organization code '${companyCode}' already exists` });
        }

        const org = await prisma.organization.create({
            data: {
                companyName: companyName.trim(),
                companyCode: companyCode.trim(),
            },
        });

        request.log.info(
            { companyName: org.companyName, companyCode: org.companyCode },
            'Admin created organization'
        );

        return {
            organization: {
                id: org.id,
                companyName: org.companyName,
                companyCode: org.companyCode,
                createdAt: org.createdAt,
                userCount: 0,
            },
            message: `Created organization ${org.companyName} (${org.companyCode})`,
        };
    });

    /**
     * PUT /api/admin/organizations/:code
     * Edit an organization's name and/or code.
     */
    fastify.put('/api/admin/organizations/:code', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async (request, reply) => {
        const { code } = request.params;
        const { companyName, companyCode: newCode } = request.body || {};

        const org = await prisma.organization.findUnique({ where: { companyCode: code } });
        if (!org) {
            return reply.status(404).send({ error: 'Organization not found' });
        }

        const data = {};
        if (companyName !== undefined) {
            if (!COMPANY_NAME_RE.test(companyName)) {
                return reply.status(400).send({ error: 'Company name must be 1–50 characters, letters and spaces only' });
            }
            data.companyName = companyName.trim();
        }
        if (newCode !== undefined && newCode.toUpperCase() !== code.toUpperCase()) {
            if (!COMPANY_CODE_RE.test(newCode)) {
                return reply.status(400).send({ error: 'Company code must be 3–4 letters (A-Z, a-z)' });
            }
            // Check new code isn't taken
            const conflict = await prisma.organization.findUnique({ where: { companyCode: newCode } });
            if (conflict) {
                return reply.status(409).send({ error: `Code '${newCode}' is already in use` });
            }
            data.companyCode = newCode.trim();
        }

        if (Object.keys(data).length === 0) {
            return reply.status(400).send({ error: 'No changes provided' });
        }

        // Use a transaction to safely handle FK when changing code:
        // 1. Null out users' FK → 2. Update org → 3. Re-assign users
        const isCodeChange = data.companyCode && data.companyCode !== code;
        const { updated, affectedUserIds } = await prisma.$transaction(async (tx) => {
            let affectedUserIds = [];
            if (isCodeChange) {
                // Find which users have the old code before nulling
                const affected = await tx.user.findMany({
                    where: { companyCode: code },
                    select: { id: true },
                });
                affectedUserIds = affected.map(u => u.id);

                await tx.user.updateMany({
                    where: { id: { in: affectedUserIds } },
                    data: { companyCode: null },
                });
            }

            const org = await tx.organization.update({
                where: { companyCode: code },
                data,
            });

            if (isCodeChange && affectedUserIds.length > 0) {
                await tx.user.updateMany({
                    where: { id: { in: affectedUserIds } },
                    data: { companyCode: data.companyCode },
                });
            }

            return { updated: org, affectedUserIds };
        });

        invalidateUserSockets(fastify, affectedUserIds, { dashboardOnly: true });

        request.log.info(
            { companyName: updated.companyName, companyCode: updated.companyCode },
            'Admin updated organization'
        );

        return {
            organization: {
                id: updated.id,
                companyName: updated.companyName,
                companyCode: updated.companyCode,
                createdAt: updated.createdAt,
            },
            message: `Updated organization ${updated.companyName}`,
        };
    });

    /**
     * DELETE /api/admin/organizations/:code
     * Delete an organization. Fails if users are still assigned.
     */
    fastify.delete('/api/admin/organizations/:code', {
        preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
    }, async (request, reply) => {
        const { code } = request.params;

        const org = await prisma.organization.findUnique({
            where: { companyCode: code },
            include: { _count: { select: { users: true } } },
        });

        if (!org) {
            return reply.status(404).send({ error: 'Organization not found' });
        }

        if (org._count.users > 0) {
            return reply.status(409).send({
                error: `Cannot delete organization ${org.companyCode} — ${org._count.users} user(s) are still assigned. Re-assign them first.`,
            });
        }

        await prisma.organization.delete({ where: { companyCode: code } });

        request.log.warn(
            { companyName: org.companyName, companyCode: org.companyCode },
            'Admin deleted organization'
        );

        return { message: `Deleted organization ${org.companyName} (${org.companyCode})` };
    });

    // ─── User Profile Edit ───────────────────────────────────────

    /**
     * PATCH /api/admin/users/:id
     * Edit user profile fields (companyCode, name, team, email).
     */
    fastify.patch('/api/admin/users/:id', {
        preHandler: [fastify.authenticate, fastify.requireRole(...ADMIN_ROLES)],
    }, async (request, reply) => {
        const { id } = request.params;
        const { companyCode, name, team, email } = request.body || {};

        const user = await prisma.user.findFirst({ where: { id, ...userScope(request.user) } });
        if (!user) {
            return reply.status(404).send({ error: 'User not found' });
        }
        if (!isSuperAdmin(request.user.role) && isSuperAdmin(user.role)) {
            return reply.status(403).send({ error: 'Super Admin accounts can only be edited by a Super Admin' });
        }

        const data = {};

        // Handle companyCode — null removes assignment
        if (companyCode !== undefined) {
            if (!isSuperAdmin(request.user.role) && !sameOrganization(companyCode, request.user.companyCode)) {
                return reply.status(403).send({ error: 'Team admins cannot move users between organizations' });
            }
            if (companyCode === null || companyCode === '') {
                if (user.role === ROLES.ADMIN) {
                    return reply.status(400).send({ error: 'Admins must belong to an organization. Change their role first.' });
                }
                data.companyCode = null;
            } else {
                const org = await prisma.organization.findUnique({ where: { companyCode } });
                if (!org) {
                    return reply.status(400).send({ error: `Organization '${companyCode}' not found` });
                }
                data.companyCode = companyCode;
            }
        }

        if (name !== undefined) data.name = name;
        if (team !== undefined) data.team = team || null;
        if (email !== undefined) data.email = email || null;

        if (Object.keys(data).length === 0) {
            return reply.status(400).send({ error: 'No changes provided' });
        }

        let updated;
        try {
            updated = await prisma.user.update({
                where: {
                    id,
                    ...userScope(request.user),
                    // A concurrent promotion must not leave an admin without an organization.
                    role: user.role,
                },
                data,
                include: { organization: true },
            });
        } catch (err) {
            if (err.code === 'P2025') {
                return reply.status(404).send({ error: 'User not found' });
            }
            throw err;
        }

        if (updated.companyCode !== user.companyCode) {
            invalidateUserSockets(fastify, [id], { dashboardOnly: true });
        }

        request.log.info(
            {
                userName: redactPersonName(updated.name),
                phoneNumber: redactPhoneNumber(updated.phoneNumber),
                changedFields: Object.keys(data),
            },
            'Admin edited user profile'
        );

        return {
            user: {
                id: updated.id,
                name: updated.name,
                phoneNumber: updated.phoneNumber,
                email: updated.email,
                team: updated.team,
                companyCode: updated.companyCode,
                companyName: updated.organization?.companyName || null,
            },
            message: `Updated user ${updated.name}`,
        };
    });

    /**
     * PATCH /api/admin/users/:id/role
     * Set a user's role to USER or ADMIN. Team admins can only change users in
     * their own organization; SUPER_ADMIN can't be granted or changed here.
     */
    fastify.patch('/api/admin/users/:id/role', {
        preHandler: [fastify.authenticate, fastify.requireRole(...ADMIN_ROLES)],
    }, async (request, reply) => {
        const { id } = request.params;
        const { role } = request.body || {};

        const target = await prisma.user.findFirst({
            where: { id, ...userScope(request.user) },
            select: { id: true, name: true, phoneNumber: true, role: true, companyCode: true },
        });

        const decision = checkRoleChange(request.user, target, role);
        if (!decision.ok) {
            return reply.status(decision.status).send({ error: decision.error });
        }

        if (target.role === role) {
            return { user: { id: target.id, role: target.role }, message: `${target.name} is already ${role}` };
        }

        const result = await prisma.user.updateMany({
            // The checked organization must still be assigned when promoting an admin.
            where: { id, ...userScope(request.user), role: target.role, companyCode: target.companyCode },
            data: { role },
        });
        if (result.count !== 1) {
            return reply.status(404).send({ error: 'User not found' });
        }
        invalidateUserSockets(fastify, [id], { dashboardOnly: true });
        const updated = { id: target.id, name: target.name, role, companyCode: target.companyCode };

        request.log.warn(
            {
                actorId: request.user.id,
                userName: redactPersonName(target.name),
                phoneNumber: redactPhoneNumber(target.phoneNumber),
                fromRole: target.role,
                toRole: role,
            },
            'Admin changed user role'
        );

        return {
            user: updated,
            message: `${updated.name} is now ${role}`,
        };
    });

}
