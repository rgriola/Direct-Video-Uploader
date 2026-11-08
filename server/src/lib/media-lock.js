import { pool } from './prisma.js';
import { assetMediaLockKey } from './media-lock-key.js';

const MAX_ACTIVE_LOCKS = 4;
let activeLocks = 0;

export async function withAssetMediaLock(assetId, work) {
    if (typeof assetId !== 'string' || !assetId) {
        throw new TypeError('An asset ID is required for media reconciliation');
    }
    if (activeLocks >= MAX_ACTIVE_LOCKS) return { acquired: false };

    activeLocks += 1;
    let client;
    let acquired = false;
    let broken = false;
    let workError;
    const key = assetMediaLockKey(assetId);
    const onError = () => { broken = true; };

    try {
        client = await pool.connect();
        client.on('error', onError);
        const result = await client.query(
            'SELECT pg_try_advisory_lock(hashtextextended($1, 0)) AS acquired',
            [key],
        );
        acquired = result.rows[0].acquired;
        if (!acquired) return { acquired: false };

        const assertLocked = async () => {
            if (broken) throw new Error('Media reconciliation lock connection was lost');
            await client.query('SELECT 1');
            if (broken) throw new Error('Media reconciliation lock connection was lost');
        };
        const value = await work(assertLocked);
        await assertLocked();
        return { acquired: true, value };
    } catch (err) {
        workError = err;
        throw err;
    } finally {
        try {
            if (client && acquired && !broken) {
                const result = await client.query(
                    'SELECT pg_advisory_unlock(hashtextextended($1, 0)) AS released',
                    [key],
                );
                if (!result.rows[0].released) {
                    throw new Error('Media reconciliation lock was not held');
                }
            }
        } catch (err) {
            broken = true;
            if (workError) {
                console.error('Media reconciliation lock release failed:', err.message);
            } else {
                throw err;
            }
        } finally {
            if (client) {
                client.removeListener('error', onError);
                client.release(broken);
            }
            activeLocks -= 1;
        }
    }
}
