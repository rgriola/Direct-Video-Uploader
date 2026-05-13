// Last updated: May 13, 2026 - 1:18pm - GitHub Copilot (GPT-5.3-Codex)
/**
 * Auth routes — Simple phone# + PIN login for demo.
 */
import crypto from 'node:crypto';
import prisma from '../lib/prisma.js';
import { verifyPin, hashPin, dbRetry } from '../lib/utils.js';
import { createSession, deleteSession } from '../lib/session-store.js';
import { Role, normalizeRole, isDashboardAdmin } from '../lib/rbac.js';

function getBearerToken(rawHeader) {
    if (typeof rawHeader !== 'string') return null;
    if (!rawHeader.startsWith('Bearer ')) return null;
    const token = rawHeader.slice(7).trim();
    return token || null;
}

const WEB_SESSION_COOKIE_NAME = 'fixer_clip_token';

function webSessionCookieOptions(isSecure) {
    return {
        path: '/',
        httpOnly: true,
        secure: isSecure,
        sameSite: 'lax',
        maxAge: 7 * 24 * 60 * 60,
    };
}

export default async function authRoutes(fastify) {
    // Auth responses should never be cached by intermediaries or clients.
    fastify.addHook('onSend', async (request, reply, payload) => {
        reply.header('Cache-Control', 'no-store');
        return payload;
    });

    /**
     * POST /api/auth/login
     * Body: { phoneNumber: string, pin: string }
     * Returns: { token: string, user: { id, name, phoneNumber, team } }
     */
    fastify.post('/api/auth/login', {
        schema: {
            body: {
                type: 'object',
                required: ['phoneNumber', 'pin'],
                properties: {
                    phoneNumber: { type: 'string' },
                    pin: { type: 'string' },
                    clientType: { type: 'string' },
                    companyCode: { type: 'string' },
                },
            },
        },
        config: {
            rateLimit: {
                max: 5,
                timeWindow: '1 minute',
            },
        },
    }, async (request, reply) => {
        const { phoneNumber, pin } = request.body;
        const clientType = request.body.clientType || 'unknown';
        const companyCode = request.body.companyCode || null;
        const normalizedCompanyCode = typeof companyCode === 'string'
            ? companyCode.trim().toUpperCase()
            : null;

        // If the org is SSO-enabled, require SSO flow instead of PIN login.
        if (normalizedCompanyCode) {
            const org = await dbRetry(() => prisma.organization.findUnique({
                where: { companyCode: normalizedCompanyCode },
                select: { ssoEnabled: true },
            }));

            if (org?.ssoEnabled) {
                return reply.status(409).send({
                    error: 'SSO required for this organization',
                    code: 'SSO_REQUIRED',
                    ssoStartUrl: `/api/auth/sso/start?companyCode=${encodeURIComponent(normalizedCompanyCode)}`,
                });
            }
        }

        // Look up user by phone number (include organization for company name)
        const user = await dbRetry(() => prisma.user.findUnique({
            where: { phoneNumber },
            include: { organization: true },
        }));

        if (!user) {
            return reply.status(401).send({
                error: 'Invalid credentials',
            });
        }

        if (user.status !== 'ACTIVE') {
            return reply.status(403).send({
                error: 'Account is suspended',
            });
        }

        // Verify PIN
        if (!(await verifyPin(pin, user.pinHash))) {
            return reply.status(401).send({
                error: 'Invalid credentials',
            });
        }

        const normalizedRole = normalizeRole(user.role) || Role.EDITOR;
        const isAdminClient = clientType === 'admin';
        const isAdminUser = isDashboardAdmin(normalizedRole);

        if (user.organization?.ssoEnabled && !isAdminUser) {
            return reply.status(409).send({
                error: 'SSO required for this organization',
                code: 'SSO_REQUIRED',
                ssoStartUrl: `/api/auth/sso/start?companyCode=${encodeURIComponent(user.companyCode || normalizedCompanyCode || '')}`,
            });
        }

        // Company code is required for non-admin users and non-admin clients.
        // Only a real ADMIN using the admin client can bypass this check.
        if (!(isAdminClient && isAdminUser)) {
            if (!companyCode) {
                return reply.status(401).send({
                    error: 'Company code is required',
                });
            }
            if (!user.companyCode || user.companyCode.toLowerCase() !== companyCode.toLowerCase()) {
                return reply.status(401).send({
                    error: 'Invalid credentials',
                });
            }
        }

        // Auto-migrate legacy SHA-256 hash to bcrypt
        if (user.pinHash && !user.pinHash.startsWith('$2')) {
            const bcryptHash = await hashPin(pin);
            await dbRetry(() => prisma.user.update({
                where: { id: user.id },
                data: { pinHash: bcryptHash },
            }));
        }

        // Track login time (skip for admin dashboard auto-login)
        if (!(isAdminClient && isAdminUser)) {
            await dbRetry(() => prisma.user.update({
                where: { id: user.id },
                data: { lastLoginAt: new Date() },
            }));
        }

        const jti = crypto.randomUUID();

        // Generate JWT (include companyCode for filtering)
        const token = fastify.jwt.sign(
            {
                id: user.id,
                phoneNumber: user.phoneNumber,
                name: user.name,
                role: normalizedRole,
                companyCode: user.companyCode || null,
                jti,
            },
            { expiresIn: '7d' }
        );

        try {
            await createSession({ userId: user.id, jti });
        } catch (err) {
            request.log.error(
                { err: { message: err.message }, userId: user.id },
                'Failed to create login session'
            );
            return reply.status(503).send({ error: 'Unable to establish session' });
        }

        // Root (/) is the canonical web login entrypoint; set shared cookie for clip viewer access too.
        if (typeof reply.setCookie === 'function') {
            const isSecure = request.protocol === 'https';
            reply.setCookie(WEB_SESSION_COOKIE_NAME, token, webSessionCookieOptions(isSecure));
            reply.clearCookie(WEB_SESSION_COOKIE_NAME, { path: '/clips' });
        }

        return {
            token,
            user: {
                id: user.id,
                name: user.name,
                phoneNumber: user.phoneNumber,
                team: user.team,
                role: normalizedRole,
                companyCode: user.companyCode || null,
                companyName: user.organization?.companyName || null,
            },
        };
    });

    /**
     * GET /api/auth/me
     * Returns the authenticated user's profile.
     * Requires: Authorization: Bearer <token>
     */
    fastify.get('/api/auth/me', {
        preHandler: [fastify.authenticate],
    }, async (request) => {
        const user = await prisma.user.findUnique({
            where: { id: request.user.id },
            select: {
                id: true,
                name: true,
                phoneNumber: true,
                email: true,
                team: true,
                role: true,
                status: true,
                companyCode: true,
                createdAt: true,
                organization: { select: { companyName: true } },
            },
        });

        // Flatten the organization join for the response
        const { organization, ...rest } = user || {};
        const normalizedRole = normalizeRole(rest?.role) || Role.EDITOR;
        return {
            user: user ? {
                ...rest,
                role: normalizedRole,
                companyName: organization?.companyName || null,
            } : null,
        };
    });

    /**
     * POST /api/auth/logout
     * Invalidates token session and clears web session cookies used by dashboard/clip viewer.
     */
    fastify.post('/api/auth/logout', {
        schema: {
            headers: {
                type: 'object',
                properties: {
                    authorization: { type: 'string' },
                },
            },
        },
    }, async (request, reply) => {
        const bearerToken = getBearerToken(request.headers?.authorization);
        const cookieToken = request.cookies?.[WEB_SESSION_COOKIE_NAME];
        const token = bearerToken || cookieToken || null;

        if (token) {
            try {
                const decoded = fastify.jwt.verify(token);
                await deleteSession({ userId: decoded.id, jti: decoded.jti });
            } catch {
                // Best-effort logout: still clear cookies and return ok.
            }
        }

        reply.clearCookie(WEB_SESSION_COOKIE_NAME, { path: '/' });
        reply.clearCookie(WEB_SESSION_COOKIE_NAME, { path: '/clips' });
        return { ok: true };
    });
}
