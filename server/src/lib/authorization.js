import { ROLES } from './roles.js';

const knownRoles = new Set(Object.values(ROLES));

export function requireRole(...roles) {
    if (roles.length === 0 || roles.some(role => !knownRoles.has(role))) {
        throw new Error('requireRole needs at least one valid role');
    }

    return async (request, reply) => {
        const user = request.user;
        if (!roles.includes(user?.role)) {
            return reply.status(403).send({ error: 'Access denied' });
        }
        if (user.role === ROLES.ADMIN && !user.companyCode && !roles.includes(ROLES.USER)) {
            return reply.status(403).send({ error: 'Admin account must belong to an organization' });
        }
    };
}

export function userScope(user) {
    if (!user?.id || !knownRoles.has(user.role)) {
        throw new Error('A valid authenticated user is required for authorization scope');
    }

    if (user.role === ROLES.SUPER_ADMIN) return {};
    if (user.role === ROLES.ADMIN && user.companyCode) {
        return { companyCode: user.companyCode };
    }
    return { id: user.id };
}

export function teamScope(user) {
    const scope = userScope(user);
    if (scope.companyCode) return { user: { companyCode: scope.companyCode } };
    if (scope.id) return { userId: scope.id };
    return {};
}
