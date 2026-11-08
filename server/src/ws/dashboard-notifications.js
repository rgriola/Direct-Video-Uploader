import prisma from '../lib/prisma.js';
import { ROLES } from '../lib/roles.js';
import { SUPER_ROOM, teamRoom } from './rooms.js';

/**
 * Send a payload-free refresh signal only to currently authorized dashboards.
 * Room membership identifies candidates, not their current authorization.
 */
export async function notifyDashboardAssetChange(fastify, assetId) {
    try {
        const asset = await prisma.asset.findUnique({
            where: { id: assetId },
            select: { moderation: true, user: { select: { companyCode: true } } },
        });
        if (!asset || asset.moderation !== 'ACTIVE') return;
        if (!asset.user) throw new Error('Asset owner is missing');

        const companyCode = asset.user.companyCode;
        const rooms = companyCode ? [teamRoom(companyCode), SUPER_ROOM] : [SUPER_ROOM];
        const sockets = await fastify.io.in(rooms).fetchSockets();
        const userIds = [...new Set(sockets.map(socket => socket.data.userId).filter(Boolean))];
        if (userIds.length === 0) return;

        const authorized = await prisma.user.findMany({
            where: {
                id: { in: userIds },
                status: 'ACTIVE',
                OR: [
                    { role: ROLES.SUPER_ADMIN },
                    ...(companyCode ? [{ role: ROLES.ADMIN, companyCode }] : []),
                ],
            },
            select: { id: true },
        });
        const authorizedIds = new Set(authorized.map(user => user.id));
        const socketIds = sockets
            .filter(socket => authorizedIds.has(socket.data.userId))
            .map(socket => socket.id);

        if (socketIds.length > 0) {
            fastify.io.to(socketIds).emit('dashboard:asset-changed');
        }
    } catch (err) {
        fastify.log.error(
            { err: { message: err.message }, assetId },
            'Could not notify dashboards of asset change'
        );
    }
}
