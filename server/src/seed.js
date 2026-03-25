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
    {
        phoneNumber: '9176717330',
        name: 'Rod Griola',
        email: 'rodczaro@gmail.com',
        team: 'Engineering',
        pin: '3218',
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
            // Update role if it differs (fixes pre-existing users missing ADMIN role)
            if (user.role && existing.role !== user.role) {
                await prisma.user.update({
                    where: { phoneNumber: user.phoneNumber },
                    data: { role: user.role },
                });
                console.log(`  🔄 ${user.name} (${user.phoneNumber}) — role updated to ${user.role}`);
            } else {
                console.log(`  ⏭️  ${user.name} (${user.phoneNumber}) — already exists`);
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

        console.log(`  ✅ ${user.name} (${user.phoneNumber}) — created (PIN: ${user.pin})`);
    }

    console.log('\n🎉 Seed complete!\n');
    console.log('Demo login credentials:');
    console.log('  David Burgess  →  Phone: 5055034455  PIN: 1234');
    console.log('  Carrie Smith   →  Phone: 5055551234  PIN: 1234');
    console.log('  Admin User     →  Phone: 8001234567  PIN: 0000');
    console.log('  Rod Griola     →  Phone: 9176717330  PIN: 3218  (ADMIN)');
}

seed()
    .catch(console.error)
    .finally(() => prisma.$disconnect());
