/**
 * Admin routes — Dashboard data, user management, asset overview.
 * All data is LIVE — no simulated actions.
 */
import prisma from '../lib/prisma.js';

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
            await prisma.$queryRawUnsafe('SELECT 1');
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
        const result = await prisma.$queryRawUnsafe(`
            SELECT 
                (SELECT COUNT(*)::int FROM users) as users,
                (SELECT COUNT(*)::int FROM users WHERE status = 'ACTIVE') as "activeUsers",
                (SELECT COUNT(*)::int FROM users WHERE last_login_at IS NOT NULL) as "loggedInUsers",
                (SELECT COUNT(*)::int FROM assets) as assets,
                (SELECT COUNT(*)::int FROM assets WHERE status = 'READY') as "readyAssets",
                (SELECT COUNT(*)::int FROM assets WHERE status = 'UPLOADING') as "uploadingAssets",
                (SELECT COUNT(*)::int FROM chat_messages) as messages
        `);

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
        const users = await prisma.$queryRawUnsafe(`
            SELECT u.id, u.phone_number AS "phoneNumber", u.name, u.email, u.team, u.status,
                   u.created_at AS "createdAt",
                   u.last_login_at AS "lastLoginAt",
                   (SELECT COUNT(*)::int FROM assets a WHERE a.user_id = u.id) AS "assetCount"
            FROM users u
            ORDER BY u.created_at ASC
        `);

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
    }, async () => {
        // Single raw SQL query — avoids multiple Prisma ORM roundtrips that exhaust the pool
        const assets = await prisma.$queryRawUnsafe(`
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
            ORDER BY a.created_at DESC
            LIMIT 50
        `);

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
    }, async () => {
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

        console.log(`🧹 Cleaned ${ids.length} stale UPLOADING assets:`, ids.map(id => id.slice(0, 8)));

        return {
            cleaned: ids.length,
            message: `Removed ${ids.length} stale UPLOADING asset(s)`,
            assetIds: ids,
        };
    });

    /**
     * POST /api/admin/users
     * Add a new user (admin action).
     */
    fastify.post('/api/admin/users', {
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async (request, reply) => {
        const { phoneNumber, name, email, team, pin } = request.body || {};

        if (!phoneNumber || !name || !pin) {
            return reply.status(400).send({
                error: 'phoneNumber, name, and pin are required',
            });
        }

        const { hashPin } = await import('../lib/utils.js');

        const existing = await prisma.user.findUnique({ where: { phoneNumber } });
        if (existing) {
            return reply.status(409).send({ error: 'Phone number already registered' });
        }

        const user = await prisma.user.create({
            data: {
                phoneNumber,
                name,
                email,
                team,
                pinHash: await hashPin(pin),
            },
        });

        return {
            user: {
                id: user.id,
                name: user.name,
                phoneNumber: user.phoneNumber,
                email: user.email,
                team: user.team,
                status: user.status,
            },
        };
    });

    /**
     * PATCH /api/admin/users/:id
     * Update a user's status (suspend/activate).
     */
    fastify.patch('/api/admin/users/:id', {
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async (request, reply) => {
        const { id } = request.params;
        const { status, team, email } = request.body || {};

        const user = await prisma.user.findUnique({ where: { id } });
        if (!user) {
            return reply.status(404).send({ error: 'User not found' });
        }

        const updated = await prisma.user.update({
            where: { id },
            data: {
                ...(status && { status }),
                ...(team && { team }),
                ...(email && { email }),
            },
        });

        return {
            user: {
                id: updated.id,
                name: updated.name,
                phoneNumber: updated.phoneNumber,
                status: updated.status,
                team: updated.team,
            },
        };
    });

    /**
     * POST /api/admin/sync-mux-status
     * Fix assets stuck in PROCESSING — checks clips and syncs asset status.
     */
    fastify.post('/api/admin/sync-mux-status', {
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async () => {
        // Find assets stuck in PROCESSING/UPLOADING that have READY clips
        const stuck = await prisma.$queryRawUnsafe(`
            SELECT a.id, a.mediasource_id, a.status as asset_status, c.status as clip_status
            FROM assets a
            JOIN clips c ON c.asset_id = a.id
            WHERE a.status IN ('PROCESSING', 'UPLOADING')
              AND c.status = 'READY'
        `);

        const fixed = [];
        for (const row of stuck) {
            await prisma.asset.update({
                where: { id: row.id },
                data: { status: 'READY' },
            });
            fixed.push({ id: row.id, mediasourceId: row.mediasource_id, was: row.asset_status });
        }

        return { fixed, count: fixed.length };
    });
}
