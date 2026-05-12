// Last updated: May 12, 2026 - 4:28pm - GitHub Copilot (GPT-5.3-Codex)
/**
 * Seed script — Creates demo users for testing.
 * Run: node src/seed.js
 */
import prisma from './lib/prisma.js';
import { hashPin } from './lib/utils.js';
import { redactPhoneNumber } from './lib/redact.js';

const DEMO_USERS = [
    {
        phoneNumber: '5055034455',
        name: 'David Burgess',
        email: 'david.burgess@example.com',
        team: 'Field',
        pin: '1234',
    },
    {
        phoneNumber: '5055551234',
        name: 'Carrie Smith',
        email: 'carrie.smith@example.com',
        team: 'Editorial',
        pin: '1234',
    },
    {
        phoneNumber: '8001234567',
        name: 'Admin User',
        email: 'admin@example.com',
        team: 'Engineering',
        pin: '0000',
        role: 'SUPER_ADMIN',
    },
    {
        phoneNumber: '9176717330',
        name: 'Rod Griola',
        email: 'rodczaro@gmail.com',
        team: 'Engineering',
        pin: '3218',
        role: 'SUPER_ADMIN',
    },
];

async function seed() {
    console.log({ event: 'seed.start', totalUsers: DEMO_USERS.length });

    for (const user of DEMO_USERS) {
        const existing = await prisma.user.findUnique({
            where: { phoneNumber: user.phoneNumber },
        });

        if (existing) {
            // Update role if it differs (fixes pre-existing users missing privileged role)
            if (user.role && existing.role !== user.role) {
                await prisma.user.update({
                    where: { phoneNumber: user.phoneNumber },
                    data: { role: user.role },
                });
                console.log({
                    event: 'seed.user.roleUpdated',
                    phoneNumber: redactPhoneNumber(user.phoneNumber),
                    role: user.role,
                });
            } else {
                console.log({
                    event: 'seed.user.exists',
                    phoneNumber: redactPhoneNumber(user.phoneNumber),
                });
            }
            continue;
        }

        await prisma.user.create({
            data: {
                phoneNumber: user.phoneNumber,
                name: user.name,
                email: user.email,
                team: user.team,
                pinHash: await hashPin(user.pin),
                ...(user.role && { role: user.role }),
            },
        });

        console.log({
            event: 'seed.user.created',
            phoneNumber: redactPhoneNumber(user.phoneNumber),
            role: user.role || null,
        });
    }

    console.log({ event: 'seed.complete', totalUsers: DEMO_USERS.length });
    console.log({ event: 'seed.credentials.redacted' });
}

seed()
    .catch((err) => {
        console.error({ event: 'seed.failed', message: err.message });
    })
    .finally(() => prisma.$disconnect());
