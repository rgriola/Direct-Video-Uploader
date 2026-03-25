/**
 * Error logging routes — Persist errors from iOS, server, dashboard.
 * Future: trigger text/email notifications for CRITICAL errors.
 */
import prisma from '../lib/prisma.js';

export default async function errorRoutes(fastify) {
    /**
     * POST /api/errors
     * Log an error from a client (iOS, dashboard, etc.)
     * Body: { source, category, message, details?, severity?, assetId? }
     */
    fastify.post('/api/errors', {
        preHandler: [fastify.authenticate],
        config: {
            rateLimit: { max: 20, timeWindow: '1 minute' },
        },
    }, async (request) => {
        const { source, category, message, details, severity, assetId } = request.body || {};

        if (!source || !category || !message) {
            return { error: 'Missing required fields: source, category, message' };
        }

        const errorLog = await prisma.errorLog.create({
            data: {
                userId: request.user.id,
                assetId: assetId || null,
                source: source || 'unknown',
                category: category || 'general',
                message,
                details: details || null,
                severity: severity?.toUpperCase() || 'WARNING',
            },
        });

        // TODO: Future — check severity, send text/email for CRITICAL/ERROR
        // if (severity === 'CRITICAL' || severity === 'ERROR') {
        //   await sendNotification(request.user, errorLog);
        // }

        console.log(`⚠️ [ErrorLog] ${severity || 'WARNING'} — ${source}/${category}: ${message}`);

        return { errorLog: { id: errorLog.id, createdAt: errorLog.createdAt } };
    });

    /**
     * GET /api/admin/errors
     * Retrieve recent errors (admin only — useful for dashboard).
     */
    fastify.get('/api/admin/errors', {
        preHandler: [fastify.authenticate, fastify.authorizeAdmin],
    }, async (request) => {
        const errors = await prisma.errorLog.findMany({
            orderBy: { createdAt: 'desc' },
            take: 50,
        });

        return { errors };
    });
}
