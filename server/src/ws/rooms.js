import { ROLES } from '../lib/roles.js';

export const SUPER_ROOM = 'super';

export function userRoom(userId) {
    return `user:${userId}`;
}

export function teamRoom(companyCode) {
    return `team:${companyCode}`;
}

export function joinAuthorizedRooms(socket, user) {
    socket.data.userId = user.id;
    socket.join(userRoom(user.id));

    if (socket.clientType !== 'admin') return;
    if (user.role === ROLES.SUPER_ADMIN) {
        socket.join(SUPER_ROOM);
    } else if (user.role === ROLES.ADMIN && user.companyCode) {
        socket.join(teamRoom(user.companyCode));
    }
}

export function invalidateUserSockets(fastify, userIds, { dashboardOnly = false } = {}) {
    if (userIds.length === 0) return;

    if (fastify.socketAuthState) {
        fastify.socketAuthState.revision += 1;
    }

    for (const userId of userIds) {
        const socketIds = fastify.userSockets?.get(userId) || [];
        for (const socketId of socketIds) {
            if (dashboardOnly && !fastify.adminSockets?.has(socketId)) continue;
            fastify.io?.sockets?.sockets?.get(socketId)?.disconnect(true);
        }
    }
}
