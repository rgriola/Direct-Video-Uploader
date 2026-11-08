import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const databaseUrl = process.env.TEST_DATABASE_URL;
if (process.env.CI && !databaseUrl) {
    throw new Error('TEST_DATABASE_URL is required for media lock tests in CI');
}
if (databaseUrl) {
    const url = new URL(databaseUrl);
    if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
        || !url.pathname.slice(1).startsWith('dvu_scope_test_')
        || process.env.DATABASE_URL !== databaseUrl) {
        throw new Error('Media lock tests require a dedicated local dvu_scope_test_ database');
    }
}

const integration = databaseUrl ? describe : describe.skip;

integration('media reconciliation lock against PostgreSQL', () => {
    let prisma;
    let withAssetMediaLock;

    beforeAll(async () => {
        ({ default: prisma } = await import('../lib/prisma.js'));
        ({ withAssetMediaLock } = await import('../lib/media-lock.js'));
    });

    afterAll(async () => {
        await prisma?.$disconnect();
    });

    it('serializes work for one asset without blocking another asset', async () => {
        let enter;
        let release;
        const entered = new Promise(resolve => { enter = resolve; });
        const released = new Promise(resolve => { release = resolve; });

        const first = withAssetMediaLock('lock-asset-a', async assertLocked => {
            await assertLocked();
            enter();
            await released;
            return 'finished';
        });

        try {
            await entered;
            const sameAsset = await withAssetMediaLock('lock-asset-a', async () => 'unexpected');
            const otherAsset = await withAssetMediaLock('lock-asset-b', async () => 'other');
            expect(sameAsset).toEqual({ acquired: false });
            expect(otherAsset).toEqual({ acquired: true, value: 'other' });
        } finally {
            release();
        }

        await expect(first).resolves.toEqual({ acquired: true, value: 'finished' });
        await expect(withAssetMediaLock('lock-asset-a', async () => 'next'))
            .resolves.toEqual({ acquired: true, value: 'next' });
    });

    it('releases the lock when work fails', async () => {
        await expect(withAssetMediaLock('lock-asset-error', async () => {
            throw new Error('failed work');
        })).rejects.toThrow('failed work');

        await expect(withAssetMediaLock('lock-asset-error', async () => 'recovered'))
            .resolves.toEqual({ acquired: true, value: 'recovered' });
    });
});
