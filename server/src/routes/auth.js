// Last updated: May 9, 2026 - 6:01pm
/**
 * Auth routes — Simple phone# + PIN login for demo.
 */
import prisma from '../lib/prisma.js';
import { verifyPin, hashPin, dbRetry } from '../lib/utils.js';

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

        // iOS login requires company code
        if (clientType !== 'admin') {
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
        if (clientType !== 'admin') {
            await dbRetry(() => prisma.user.update({
                where: { id: user.id },
                data: { lastLoginAt: new Date() },
            }));
        }

        // Generate JWT (include companyCode for filtering)
        const token = fastify.jwt.sign(
            {
                id: user.id,
                phoneNumber: user.phoneNumber,
                name: user.name,
                role: user.role || 'USER',
                companyCode: user.companyCode || null,
            },
            { expiresIn: '7d' }
        );

        return {
            token,
            user: {
                id: user.id,
                name: user.name,
                phoneNumber: user.phoneNumber,
                team: user.team,
                role: user.role,
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
        return {
            user: user ? {
                ...rest,
                companyName: organization?.companyName || null,
            } : null,
        };
    });
}
