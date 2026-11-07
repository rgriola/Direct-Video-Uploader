import { beforeEach, describe, expect, it, vi } from 'vitest';
import { bootstrapSuperAdmin } from '../scripts/bootstrap-super-admin.js';

const prismaMock = {
    user: {
        findUnique: vi.fn(),
        count: vi.fn(),
        update: vi.fn(),
    },
};
const log = { log: vi.fn(), warn: vi.fn() };

beforeEach(() => {
    vi.clearAllMocks();
    prismaMock.user.count.mockResolvedValue(0);
    prismaMock.user.update.mockResolvedValue({});
});

describe('bootstrapSuperAdmin', () => {
    it('promotes the configured account', async () => {
        prismaMock.user.findUnique.mockResolvedValue({ id: 'u1', role: 'ADMIN', status: 'ACTIVE' });

        const result = await bootstrapSuperAdmin(prismaMock, ' 5055550000 ', log);

        expect(result).toEqual({ changed: true });
        expect(prismaMock.user.findUnique).toHaveBeenCalledWith(expect.objectContaining({
            where: { phoneNumber: '5055550000' },
        }));
        expect(prismaMock.user.update).toHaveBeenCalledWith({
            where: { id: 'u1' },
            data: { role: 'SUPER_ADMIN' },
        });
    });

    it('does nothing when the account is already super admin', async () => {
        prismaMock.user.findUnique.mockResolvedValue({ id: 'u1', role: 'SUPER_ADMIN', status: 'ACTIVE' });

        const result = await bootstrapSuperAdmin(prismaMock, '5055550000', log);

        expect(result).toEqual({ changed: false });
        expect(prismaMock.user.update).not.toHaveBeenCalled();
    });

    it('fails when SUPER_ADMIN_PHONE is missing', async () => {
        await expect(bootstrapSuperAdmin(prismaMock, undefined, log)).rejects.toThrow('SUPER_ADMIN_PHONE');
        await expect(bootstrapSuperAdmin(prismaMock, '  ', log)).rejects.toThrow('SUPER_ADMIN_PHONE');
        expect(prismaMock.user.findUnique).not.toHaveBeenCalled();
    });

    it('fails without revealing the full number when the account does not exist', async () => {
        prismaMock.user.findUnique.mockResolvedValue(null);

        await expect(bootstrapSuperAdmin(prismaMock, '5055550000', log))
            .rejects.toThrow('***-***-0000');
        expect(prismaMock.user.update).not.toHaveBeenCalled();
    });

    it('warns about other super admins and inactive accounts', async () => {
        prismaMock.user.findUnique.mockResolvedValue({ id: 'u1', role: 'USER', status: 'SUSPENDED' });
        prismaMock.user.count.mockResolvedValue(1);

        await bootstrapSuperAdmin(prismaMock, '5055550000', log);

        expect(log.warn).toHaveBeenCalledTimes(2);
        expect(prismaMock.user.update).toHaveBeenCalled();
    });
});
