// Last updated: May 12, 2026 - 3:35pm - GitHub Copilot (GPT-5.3-Codex)
/**
 * Error logging routes — Persist errors from iOS, server, dashboard.
 * Future: trigger text/email notifications for CRITICAL errors.
 */
import prisma from '../lib/prisma.js';
import { isSuperAdmin, normalizeRole, Role } from '../lib/rbac.js';

export default async function errorRoutes(fastify) {
    /**
     * POST /api/errors
     * Log an error from a client (iOS, dashboard, etc.)
     * Body: { source, category, message, details?, severity?, assetId? }
     */
    fastify.post('/api/errors', {
        preHandler: [fastify.authenticate],
        schema: {
            body: {
                type: 'object',
                properties: {
                    source: { type: 'string' },
                    category: { type: 'string' },
                    message: { type: 'string' },
                    details: {
                        anyOf: [
                            { type: 'object', additionalProperties: true },
                            { type: 'array' },
                            { type: 'string' },
                            { type: 'number' },
                            { type: 'boolean' },
                            { type: 'null' },
                        ],
                    },
                    severity: { type: 'string', enum: ['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL', 'debug', 'info', 'warning', 'error', 'critical'] },
                    assetId: { type: 'string' },
                },
            },
        },
        config: {
            rateLimit: { max: 20, timeWindow: '1 minute' },
        },
    }, async (request) => {
        const { source, category, message, details, severity, assetId } = request.body || {};
        const requestId = request.id;

        if (!source || !category || !message) {
            return { error: 'Missing required fields: source, category, message' };
        }

        const normalizedDetails = (details && typeof details === 'object' && !Array.isArray(details))
            ? { ...details, requestId }
            : (details != null ? { requestId, value: details } : { requestId });

        const errorLog = await prisma.errorLog.create({
            data: {
                userId: request.user.id,
                assetId: assetId || null,
                source: source || 'unknown',
                category: category || 'general',
                message,
                details: normalizedDetails,
                severity: severity?.toUpperCase() || 'WARNING',
            },
        });

        // TODO: Future — check severity, send text/email for CRITICAL/ERROR
        // if (severity === 'CRITICAL' || severity === 'ERROR') {
        //   await sendNotification(request.user, errorLog);
        // }

        request.log.warn(
            {
                requestId,
                severity: severity?.toUpperCase() || 'WARNING',
                source,
                category,
                messageLength: String(message).length,
                assetId: assetId || null,
            },
            'Client error log captured'
        );

        return { errorLog: { id: errorLog.id, createdAt: errorLog.createdAt } };
    });

    /**
     * GET /api/admin/errors
     * Retrieve recent errors for dashboard.
     */
    fastify.get('/api/admin/errors', {
        preHandler: [fastify.authenticate, fastify.authorizeOrgAdmin],
    }, async (request) => {
        const role = normalizeRole(request.user?.role) || Role.EDITOR;
        const where = isSuperAdmin(role)
            ? {}
            : { user: { companyCode: request.user?.companyCode || null } };

        const errors = await prisma.errorLog.findMany({
            where,
            orderBy: { createdAt: 'desc' },
            take: 50,
        });

        return { errors };
    });
}
