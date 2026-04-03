/**
 * Admin routes — Dashboard data, user management, asset overview.
 * All data is LIVE — no simulated actions.
 */
import prisma from '../lib/prisma.js';
import { hashPin } from '../lib/utils.js';
import { deleteMuxAsset, isMuxEnabled } from '../lib/mux.js';

export default async function adminRoutes(fastify) {

    /**
     * GET /api/admin/status
     * Triad health — database, server, WebSocket, iOS clients.
     */
    fastify.get('/api/admin/status', {
        preHandler: [fastify.authenticate],
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
        preHandler: [fastify.authenticate],
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
        preHandler: [fastify.authenticate],
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
        preHandler: [fastify.authenticate],
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
        preHandler: [fastify.authenticate],
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
        preHandler: [fastify.authenticate],
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
     * Create a new demo user. Defaults: PIN 0000, role USER.
     */
    fastify.post('/api/admin/users', {
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async (request, reply) => {
        const { name, phoneNumber, email, team } = request.body || {};

        if (!name || !phoneNumber) {
            return reply.status(400).send({ error: 'name and phoneNumber are required' });
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
                pinHash: await hashPin('0000'),
                role: 'USER',
            },
        });

        console.log(`👤 Admin created user: ${name} (${phoneNumber})`);

        return {
            user: {
                id: user.id,
                name: user.name,
                phoneNumber: user.phoneNumber,
                email: user.email,
                team: user.team,
                role: user.role,
            },
            message: `Created user ${name} (PIN: 0000)`,
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
            await prisma.$queryRawUnsafe(`ALTER SEQUENCE IF EXISTS mediasource_id_seq RESTART WITH 100000001`);
        } catch { /* sequence may not exist — safe to ignore */ }

        console.log(`☢️  Nuclear reset by admin — ${assetDeleted.count} assets, ${clipDeleted.count} clips, ${results.muxDeleted} Mux assets deleted`);

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

}
