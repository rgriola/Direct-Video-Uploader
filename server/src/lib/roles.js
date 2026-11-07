/**
 * User roles and the rules for changing them (roadmap Step 2.1).
 *
 * SUPER_ADMIN is granted only by the bootstrap script (SUPER_ADMIN_PHONE),
 * never through the API. ADMIN is a team admin scoped to one organization.
 */

export const ROLES = Object.freeze({
    USER: 'USER',
    ADMIN: 'ADMIN',
    SUPER_ADMIN: 'SUPER_ADMIN',
});

/** Roles the API may assign. SUPER_ADMIN is deliberately excluded. */
export const ASSIGNABLE_ROLES = Object.freeze([ROLES.USER, ROLES.ADMIN]);

export function isSuperAdmin(role) {
    return role === ROLES.SUPER_ADMIN;
}

/** True for team admins and the super admin. */
export function isAdminRole(role) {
    return role === ROLES.ADMIN || role === ROLES.SUPER_ADMIN;
}

function sameOrg(a, b) {
    return Boolean(a) && Boolean(b) && a.toLowerCase() === b.toLowerCase();
}

/**
 * Decide whether `actor` may set `target`'s role to `newRole`.
 * Returns `{ ok: true }` or `{ ok: false, status, error }`.
 *
 * A team admin asking about a user outside their organization gets 404,
 * so the API never confirms that the user exists.
 */
export function checkRoleChange(actor, target, newRole) {
    if (!ASSIGNABLE_ROLES.includes(newRole)) {
        return { ok: false, status: 400, error: `role must be one of: ${ASSIGNABLE_ROLES.join(', ')}` };
    }
    if (!isAdminRole(actor?.role)) {
        return { ok: false, status: 403, error: 'Admin access required' };
    }
    if (!target) {
        return { ok: false, status: 404, error: 'User not found' };
    }

    const actorIsSuper = isSuperAdmin(actor.role);
    if (!actorIsSuper && !sameOrg(actor.companyCode, target.companyCode)) {
        return { ok: false, status: 404, error: 'User not found' };
    }
    if (actor.id === target.id) {
        return { ok: false, status: 400, error: 'You cannot change your own role' };
    }
    if (isSuperAdmin(target.role)) {
        return { ok: false, status: 403, error: 'The Super Admin role can only be changed on the server' };
    }
    if (newRole === ROLES.ADMIN && !target.companyCode) {
        return { ok: false, status: 400, error: 'Assign the user to an organization before making them an admin' };
    }
    return { ok: true };
}
