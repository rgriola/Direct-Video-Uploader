/**
 * Promote the account whose phone number is in SUPER_ADMIN_PHONE to SUPER_ADMIN.
 * SUPER_ADMIN can't be granted through the API; this script is the only way.
 * Safe to run on every deploy: it does nothing if the account is already Super Admin.
 *
 * Run: npm run bootstrap:super-admin
 */
import { pathToFileURL } from 'url';
import { redactPhoneNumber } from '../lib/redact.js';
import { ROLES } from '../lib/roles.js';

export async function bootstrapSuperAdmin(prisma, phoneNumber, log = console) {
    const phone = String(phoneNumber ?? '').trim();
    if (!phone) {
        throw new Error('SUPER_ADMIN_PHONE is not set');
    }

    const user = await prisma.user.findUnique({
        where: { phoneNumber: phone },
        select: { id: true, role: true, status: true },
    });
    if (!user) {
        throw new Error(`No user with phone ${redactPhoneNumber(phone)}. Create the account first.`);
    }

    const others = await prisma.user.count({
        where: { role: ROLES.SUPER_ADMIN, id: { not: user.id } },
    });
    if (others > 0) {
        log.warn(`Warning: ${others} other account(s) are also SUPER_ADMIN.`);
    }
    if (user.status !== 'ACTIVE') {
        log.warn(`Warning: ${redactPhoneNumber(phone)} is ${user.status} and can't log in until reactivated.`);
    }

    if (user.role === ROLES.SUPER_ADMIN) {
        log.log(`${redactPhoneNumber(phone)} is already SUPER_ADMIN.`);
        return { changed: false };
    }

    await prisma.user.update({
        where: { id: user.id },
        data: { role: ROLES.SUPER_ADMIN },
    });
    log.log(`${redactPhoneNumber(phone)} promoted from ${user.role} to SUPER_ADMIN.`);
    return { changed: true };
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
    await import('dotenv/config');
    const { default: prisma } = await import('../lib/prisma.js');
    try {
        await bootstrapSuperAdmin(prisma, process.env.SUPER_ADMIN_PHONE);
    } catch (err) {
        console.error(err.message);
        process.exitCode = 1;
    } finally {
        await prisma.$disconnect();
    }
}
