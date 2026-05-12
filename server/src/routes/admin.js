// Last updated: May 12, 2026 - 3:12pm - GitHub Copilot (GPT-5.3-Codex)
/**
 * Admin routes — Dashboard data, user management, asset overview.
 * All data is LIVE — no simulated actions.
 */
import { Prisma } from '@prisma/client';
import prisma from '../lib/prisma.js';
import { hashPin } from '../lib/utils.js';
import { deleteMuxAsset, isMuxEnabled } from '../lib/mux.js';
import { redactCompanyCode, redactPersonName, redactPhoneNumber } from '../lib/redact.js';
import { revokeUserSessions } from '../lib/session-store.js';

export default async function adminRoutes(fastify) {

    /**
     * GET /api/admin/status
     * Triad health — database, server, WebSocket, iOS clients.
     */
    fastify.get('/api/admin/status', {
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
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
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async () => {
        const result = await prisma.$queryRaw`
            SELECT 
                (SELECT COUNT(*)::int FROM users) as users,
                (SELECT COUNT(*)::int FROM users WHERE status = 'ACTIVE') as "activeUsers",
                (SELECT COUNT(*)::int FROM users WHERE last_login_at IS NOT NULL) as "loggedInUsers",
                (SELECT COUNT(*)::int FROM assets) as assets,
                (SELECT COUNT(*)::int FROM assets WHERE status = 'READY') as "readyAssets",
                (SELECT COUNT(*)::int FROM assets WHERE status = 'UPLOADING') as "uploadingAssets",
                (SELECT COUNT(*)::int FROM chat_messages) as messages,
                (SELECT COUNT(*)::int FROM clips WHERE status = 'READY') as clips
        `;

        const stats = result[0] || {};
        const userSockets = fastify.userSockets || new Map();
        const iosSockets = fastify.iosSockets || new Set();
        const adminSockets = fastify.adminSockets || new Set();

        // Count online users excluding admin-only connections
        let onlineUsers = 0;
        for (const [, sids] of userSockets) {
            const hasNonAdmin = [...sids].some(sid => !adminSockets.has(sid));
            if (hasNonAdmin) onlineUsers++;
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
            iosClients: iosSockets.size,
            wsConnections: fastify.io?.of('/')?.sockets?.size || 0,
        };
    });

    /**
     * GET /api/admin/users
     * List all registered users with live status.
     */
    fastify.get('/api/admin/users', {
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async () => {
        const users = await prisma.$queryRaw`
            SELECT u.id, u.phone_number AS "phoneNumber", u.name, u.email, u.team, u.status,
                   u.company_code AS "companyCode",
                   o.company_name AS "companyName",
                   u.created_at AS "createdAt",
                   u.last_login_at AS "lastLoginAt",
                   (SELECT COUNT(*)::int FROM assets a WHERE a.user_id = u.id) AS "assetCount"
            FROM users u
            LEFT JOIN organizations o ON o.company_code = u.company_code
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
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async (request) => {
        // Role-based filtering: admins see all, non-admins see only their org's assets
        const isAdmin = request.user?.role === 'ADMIN';
        const userCompanyCode = request.user?.companyCode || null;

        // Build WHERE clause for company filtering
        const companyFilter = (!isAdmin && userCompanyCode)
            ? Prisma.sql`WHERE u.company_code = ${userCompanyCode}`
            : Prisma.empty;

        const assets = await prisma.$queryRaw`
            SELECT a.id, a.mediasource_id AS "mediasourceId",
                   a.mediasource_url AS "mediasourceUrl", a.status,
                   a.clip_count::int AS "clipCount", a.total_duration_seconds::int AS "totalDuration",
                   a.created_at AS "createdAt",
                   json_build_object('id', u.id, 'name', u.name, 'phoneNumber', u.phone_number) AS "user",
                   COALESCE(
                       (SELECT json_agg(json_build_object(
                           'id', c.id, 'assetId', c.asset_id,
                           'status', c.status, 'resolution', c.resolution,
                           'duration', c.duration_seconds, 'orientation', c.orientation
                       )) FROM clips c WHERE c.asset_id = a.id),
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
            ${companyFilter}
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
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async () => {
        const messages = await prisma.chatMessage.findMany({
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
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async (request) => {
        // Find UPLOADING assets with 0 clips using Prisma ORM
        const staleAssets = await prisma.asset.findMany({
            where: {
                status: 'UPLOADING',
                clips: { none: {} },
            },
            select: { id: true },
        });

        if (staleAssets.length === 0) {
            return { cleaned: 0, message: 'No stale assets found' };
        }

        const ids = staleAssets.map(a => a.id);

        // Delete chat messages referencing these assets first (FK constraint)
        await prisma.chatMessage.deleteMany({
            where: { assetId: { in: ids } },
        });

        // Delete the stale assets
        await prisma.asset.deleteMany({
            where: { id: { in: ids } },
        });

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
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
        schema: {
            body: {
                type: 'object',
                properties: {
                    name: { type: 'string' },
                    phoneNumber: { type: 'string' },
                    email: { type: 'string' },
                    team: { type: 'string' },
                    companyCode: { type: 'string' },
                },
            },
        },
    }, async (request, reply) => {
        const { name, phoneNumber, email, team, companyCode } = request.body || {};

        if (!name || !phoneNumber) {
            return reply.status(400).send({ error: 'name and phoneNumber are required' });
        }

        // Validate company code if provided
        if (companyCode) {
            const org = await prisma.organization.findUnique({ where: { companyCode } });
            if (!org) {
                return reply.status(400).send({ error: `Organization with code '${companyCode}' not found` });
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
                companyCode: companyCode || null,
                pinHash: await hashPin('0000'),
                role: 'USER',
            },
        });

        request.log.info(
            {
                userName: redactPersonName(name),
                phoneNumber: redactPhoneNumber(phoneNumber),
                companyCode: redactCompanyCode(companyCode),
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
     * POST /api/admin/users/:id/revoke-sessions
     * Revoke all active JWT sessions for a user and disconnect active sockets.
     */
    fastify.post('/api/admin/users/:id/revoke-sessions', {
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
        schema: {
            params: {
                type: 'object',
                required: ['id'],
                properties: {
                    id: { type: 'string', minLength: 1 },
                },
            },
        },
    }, async (request, reply) => {
        const { id } = request.params;

        const target = await prisma.user.findUnique({
            where: { id },
            select: {
                id: true,
                name: true,
                phoneNumber: true,
            },
        });

        if (!target) {
            return reply.status(404).send({ error: 'User not found' });
        }

        const revokedSessions = await revokeUserSessions(id);

        let disconnectedSockets = 0;
        const userSocketIds = fastify.userSockets?.get(id) || new Set();
        for (const socketId of userSocketIds) {
            const socket = fastify.io?.of('/')?.sockets?.get(socketId);
            if (!socket) continue;
            socket.emit('session:revoked', { reason: 'Admin revoked sessions' });
            socket.disconnect(true);
            disconnectedSockets += 1;
        }

        request.log.warn(
            {
                userName: redactPersonName(target.name),
                phoneNumber: redactPhoneNumber(target.phoneNumber),
                revokedSessions,
                disconnectedSockets,
            },
            'Admin revoked user sessions'
        );

        return {
            message: `Revoked ${revokedSessions} session(s) for ${target.name}`,
            revokedSessions,
            disconnectedSockets,
        };
    });

    /**
     * POST /api/admin/nuclear-reset
     * Delete ALL assets, clips, form responses, chat messages, error logs.
     * Also deletes all Mux assets. Preserves user accounts.
     */
    fastify.post('/api/admin/nuclear-reset', {
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async () => {
        const results = { muxDeleted: 0, muxFailed: 0, muxSkipped: false };

        // 1. Collect all Mux asset IDs from clips before deleting DB rows
        const clipsWithMux = await prisma.clip.findMany({
            where: { muxAssetId: { not: null } },
            select: { muxAssetId: true },
        });

        // 2. Delete Mux assets
        if (isMuxEnabled && clipsWithMux.length > 0) {
            for (const clip of clipsWithMux) {
                const ok = await deleteMuxAsset(clip.muxAssetId);
                if (ok) results.muxDeleted++;
                else results.muxFailed++;
            }
        } else if (!isMuxEnabled) {
            results.muxSkipped = true;
        }

        // 3. Delete DB tables in FK-safe order
        const chatDeleted = await prisma.chatMessage.deleteMany({});
        const errorDeleted = await prisma.errorLog.deleteMany({});
        const formDeleted = await prisma.formResponse.deleteMany({});
        const clipDeleted = await prisma.clip.deleteMany({});
        const assetDeleted = await prisma.asset.deleteMany({});

        // 4. Reset mediasource_id sequence counter (must start at 100000001 for 9-digit IDs)
        try {
            await prisma.$executeRaw`ALTER SEQUENCE IF EXISTS mediasource_id_seq RESTART WITH 100000001`;
        } catch { /* sequence may not exist — safe to ignore */ }

        request.log.warn(
            {
                assetCount: assetDeleted.count,
                clipCount: clipDeleted.count,
                muxDeleted: results.muxDeleted,
                muxFailed: results.muxFailed,
            },
            'Admin performed nuclear reset'
        );

        return {
            message: 'Nuclear reset complete — all data wiped except users',
            deleted: {
                assets: assetDeleted.count,
                clips: clipDeleted.count,
                formResponses: formDeleted.count,
                chatMessages: chatDeleted.count,
                errorLogs: errorDeleted.count,
            },
            mux: {
                deleted: results.muxDeleted,
                failed: results.muxFailed,
                skipped: results.muxSkipped,
            },
        };
    });

    /**
     * DELETE /api/admin/users/:id
     * Hard-wipe a user and ALL their data: Mux assets, local files,
     * clips, assets, form responses, chat messages, error logs.
     */
    fastify.delete('/api/admin/users/:id', {
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async (request, reply) => {
        const { id } = request.params;

        // Guard: admin cannot delete themselves
        if (request.user.sub === id) {
            return reply.status(400).send({ error: 'Cannot delete your own account' });
        }

        // Verify user exists
        const target = await prisma.user.findUnique({ where: { id } });
        if (!target) {
            return reply.status(404).send({ error: 'User not found' });
        }

        const counts = { muxAssets: 0, localFiles: 0 };

        // 1. Collect Mux asset IDs from user's clips before deleting DB rows
        const userClips = await prisma.clip.findMany({
            where: { asset: { userId: id } },
            select: { muxAssetId: true, storageUrl: true },
        });

        // 2. Delete Mux assets remotely
        if (isMuxEnabled) {
            for (const clip of userClips) {
                if (clip.muxAssetId) {
                    const ok = await deleteMuxAsset(clip.muxAssetId);
                    if (ok) counts.muxAssets++;
                }
            }
        }

        // 3. Delete local video files from disk
        const { unlink } = await import('fs/promises');
        const path = await import('path');
        for (const clip of userClips) {
            if (clip.storageUrl?.startsWith('/uploads/')) {
                try {
                    const filePath = path.resolve(process.cwd(), clip.storageUrl.slice(1));
                    await unlink(filePath);
                    counts.localFiles++;
                } catch (err) {
                    if (err.code !== 'ENOENT') {
                        request.log.warn(
                            { storageUrl: clip.storageUrl, err: { message: err.message } },
                            'Failed to delete local clip file during user delete'
                        );
                    }
                }
            }
        }

        // 4. Delete DB records in FK-safe order
        const chatDeleted = await prisma.chatMessage.deleteMany({ where: { userId: id } });
        const errorDeleted = await prisma.errorLog.deleteMany({ where: { userId: id } });
        // Assets cascade-delete their clips, form responses, and asset-linked chat messages
        const assetDeleted = await prisma.asset.deleteMany({ where: { userId: id } });

        // 5. Delete the user record
        await prisma.user.delete({ where: { id } });

        request.log.warn(
            {
                userName: redactPersonName(target.name),
                phoneNumber: redactPhoneNumber(target.phoneNumber),
                assetCount: assetDeleted.count,
                muxAssetCount: counts.muxAssets,
                localFileCount: counts.localFiles,
            },
            'Admin deleted user and associated data'
        );

        return {
            message: `User ${target.name} deleted with all associated data`,
            deleted: {
                assets: assetDeleted.count,
                clips: userClips.length,
                chatMessages: chatDeleted.count,
                errorLogs: errorDeleted.count,
                muxAssets: counts.muxAssets,
                localFiles: counts.localFiles,
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
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async () => {
        const orgs = await prisma.organization.findMany({
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
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
        schema: {
            body: {
                type: 'object',
                properties: {
                    companyName: { type: 'string' },
                    companyCode: { type: 'string' },
                },
            },
        },
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
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
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
        const updated = await prisma.$transaction(async (tx) => {
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

            return org;
        });

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
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
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
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
        schema: {
            params: {
                type: 'object',
                required: ['id'],
                properties: {
                    id: { type: 'string', minLength: 1 },
                },
            },
            body: {
                type: 'object',
                properties: {
                    companyCode: {
                        oneOf: [
                            { type: 'string' },
                            { type: 'null' },
                        ],
                    },
                    name: { type: 'string' },
                    team: {
                        oneOf: [
                            { type: 'string' },
                            { type: 'null' },
                        ],
                    },
                    email: {
                        oneOf: [
                            { type: 'string' },
                            { type: 'null' },
                        ],
                    },
                },
            },
        },
    }, async (request, reply) => {
        const { id } = request.params;
        const { companyCode, name, team, email } = request.body || {};

        const user = await prisma.user.findUnique({ where: { id } });
        if (!user) {
            return reply.status(404).send({ error: 'User not found' });
        }

        const data = {};

        // Handle companyCode — null removes assignment
        if (companyCode !== undefined) {
            if (companyCode === null || companyCode === '') {
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

        const updated = await prisma.user.update({
            where: { id },
            data,
            include: { organization: true },
        });

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

}
