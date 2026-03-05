/**
 * Auth routes — Simple phone# + PIN login for demo.
 */
import prisma from '../lib/prisma.js';
import { verifyPin, dbRetry } from '../lib/utils.js';

export default async function authRoutes(fastify) {
    /**
     * POST /api/auth/login
     * Body: { phoneNumber: string, pin: string }
     * Returns: { token: string, user: { id, name, phoneNumber, team } }
     */
    fastify.post('/api/auth/login', {
        config: {
            rateLimit: {
                max: 5,
                timeWindow: '1 minute',
            },
        },
    }, async (request, reply) => {
        const { phoneNumber, pin } = request.body || {};

        if (!phoneNumber || !pin) {
            return reply.status(400).send({
                error: 'Phone number and PIN are required',
            });
        }

        // Look up user by phone number
        const user = await dbRetry(() => prisma.user.findUnique({
            where: { phoneNumber },
        }));

        if (!user) {
            return reply.status(401).send({
                error: 'Invalid phone number or PIN',
            });
        }

        if (user.status !== 'ACTIVE') {
            return reply.status(403).send({
                error: 'Account is suspended',
            });
        }

        // Verify PIN
        if (!verifyPin(pin, user.pinHash)) {
            return reply.status(401).send({
                error: 'Invalid phone number or PIN',
            });
        }

        // Track login time (skip for admin dashboard auto-login)
        const clientType = request.body.clientType || 'unknown';
        if (clientType !== 'admin') {
            await dbRetry(() => prisma.user.update({
                where: { id: user.id },
                data: { lastLoginAt: new Date() },
            }));
        }

        // Generate JWT
        const token = fastify.jwt.sign(
            {
                id: user.id,
                phoneNumber: user.phoneNumber,
                name: user.name,
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
                status: true,
                createdAt: true,
            },
        });

        return { user };
    });
}
