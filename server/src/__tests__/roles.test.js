import { describe, expect, it } from 'vitest';
import { ASSIGNABLE_ROLES, checkRoleChange, isAdminRole, isSuperAdmin } from '../lib/roles.js';

describe('role helpers', () => {
    it('treats ADMIN and SUPER_ADMIN as admins', () => {
        expect(isAdminRole('ADMIN')).toBe(true);
        expect(isAdminRole('SUPER_ADMIN')).toBe(true);
        expect(isAdminRole('USER')).toBe(false);
        expect(isAdminRole(undefined)).toBe(false);
    });

    it('identifies only SUPER_ADMIN as super admin', () => {
        expect(isSuperAdmin('SUPER_ADMIN')).toBe(true);
        expect(isSuperAdmin('ADMIN')).toBe(false);
    });

    it('never lets the API assign SUPER_ADMIN', () => {
        expect(ASSIGNABLE_ROLES).not.toContain('SUPER_ADMIN');
    });
});

describe('checkRoleChange', () => {
    const admin = { id: 'a', role: 'ADMIN', companyCode: 'NEWS' };
    const user = { id: 'u', role: 'USER', companyCode: 'NEWS' };

    it('allows a valid in-organization change', () => {
        expect(checkRoleChange(admin, user, 'ADMIN')).toEqual({ ok: true });
    });

    it('rejects non-admin actors', () => {
        expect(checkRoleChange({ ...user, id: 'x' }, user, 'ADMIN').status).toBe(403);
    });

    it('treats an admin without an organization as out of scope', () => {
        const orphanAdmin = { id: 'a', role: 'ADMIN', companyCode: null };
        expect(checkRoleChange(orphanAdmin, { ...user, companyCode: null }, 'USER').status).toBe(404);
    });
});
