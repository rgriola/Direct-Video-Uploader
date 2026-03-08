/**
 * Seed script — Creates demo users for testing.
 * Run: node src/seed.js
 */
import prisma from './lib/prisma.js';
import { hashPin } from './lib/utils.js';

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
        role: 'ADMIN',
    },
];

async function seed() {
    console.log('🌱 Seeding demo users...\n');

    for (const user of DEMO_USERS) {
        const existing = await prisma.user.findUnique({
            where: { phoneNumber: user.phoneNumber },
        });

        if (existing) {
            console.log(`  ⏭️  ${user.name} (${user.phoneNumber}) — already exists`);
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

        console.log(`  ✅ ${user.name} (${user.phoneNumber}) — created (PIN: ${user.pin})`);
    }

    console.log('\n🎉 Seed complete!\n');
    console.log('Demo login credentials:');
    console.log('  David Burgess  →  Phone: 5055034455  PIN: 1234');
    console.log('  Carrie Smith   →  Phone: 5055551234  PIN: 1234');
    console.log('  Admin User     →  Phone: 8001234567  PIN: 0000');
}

seed()
    .catch(console.error)
    .finally(() => prisma.$disconnect());
