import { describe, expect, it, vi } from 'vitest';
import { requireRole, teamScope, userScope } from '../lib/authorization.js';
import { ROLES, sameOrganization } from '../lib/roles.js';

const superAdmin = { id: 'super', role: ROLES.SUPER_ADMIN, companyCode: null };
const teamAdmin = { id: 'admin', role: ROLES.ADMIN, companyCode: 'NEWS' };
const user = { id: 'user', role: ROLES.USER, companyCode: 'NEWS' };
const orphanAdmin = { id: 'orphan', role: ROLES.ADMIN, companyCode: null };

function reply() {
    return {
        status: vi.fn().mockReturnThis(),
        send: vi.fn().mockReturnThis(),
    };
}

describe('authorization scope', () => {
    it('scopes super admins globally, team admins to their organization, and users to themselves', () => {
        expect(userScope(superAdmin)).toEqual({});
        expect(teamScope(superAdmin)).toEqual({});
        expect(userScope(teamAdmin)).toEqual({ companyCode: 'NEWS' });
        expect(teamScope(teamAdmin)).toEqual({ user: { companyCode: 'NEWS' } });
        expect(userScope(user)).toEqual({ id: 'user' });
        expect(teamScope(user)).toEqual({ userId: 'user' });
    });

    it('restricts an unassigned admin to their own records', () => {
        expect(userScope(orphanAdmin)).toEqual({ id: 'orphan' });
        expect(teamScope(orphanAdmin)).toEqual({ userId: 'orphan' });
    });

    it('fails closed for missing users and unknown roles', () => {
        expect(() => userScope(null)).toThrow('authenticated user');
        expect(() => teamScope({ id: 'unknown', role: 'OWNER' })).toThrow('authenticated user');
        expect(() => requireRole()).toThrow('valid role');
        expect(() => requireRole('OWNER')).toThrow('valid role');
    });

    it('compares the case-sensitive organization foreign key exactly', () => {
        expect(sameOrganization('NEWS', 'NEWS')).toBe(true);
        expect(sameOrganization('NEWS', 'news')).toBe(false);
        expect(sameOrganization(null, null)).toBe(false);
    });
});

describe('requireRole', () => {
    it('rejects roles not permitted by the endpoint', async () => {
        const response = reply();
        await requireRole(ROLES.SUPER_ADMIN)({ user: teamAdmin }, response);
        expect(response.status).toHaveBeenCalledWith(403);
    });

    it('rejects an unassigned admin from team management', async () => {
        const response = reply();
        await requireRole(ROLES.SUPER_ADMIN, ROLES.ADMIN)({ user: orphanAdmin }, response);
        expect(response.status).toHaveBeenCalledWith(403);
        expect(response.send).toHaveBeenCalledWith({ error: 'Admin account must belong to an organization' });
    });

    it('allows an unassigned admin to access endpoints scoped to their own records', async () => {
        const response = reply();
        await requireRole(ROLES.SUPER_ADMIN, ROLES.ADMIN, ROLES.USER)({ user: orphanAdmin }, response);
        expect(response.status).not.toHaveBeenCalled();
    });
});
