import prisma from './prisma.js';

export async function authenticate(request, reply) {
    try {
        await request.jwtVerify();

        const user = await prisma.user.findUnique({
            where: { id: request.user.id },
            select: {
                id: true,
                name: true,
                phoneNumber: true,
                role: true,
                status: true,
                companyCode: true,
            },
        });

        if (!user) {
            return reply.status(401).send({ error: 'Unauthorized' });
        }

        if (user.status !== 'ACTIVE') {
            return reply.status(403).send({ error: 'Account suspended' });
        }

        request.user = {
            ...request.user,
            id: user.id,
            name: user.name,
            phoneNumber: user.phoneNumber,
            role: user.role || 'USER',
            status: user.status,
            companyCode: user.companyCode || null,
        };
    } catch (err) {
        if (!reply.sent) {
            reply.status(401).send({ error: 'Unauthorized' });
        }
    }
}
