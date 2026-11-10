import { pool } from './prisma.js';
import { originalReadLockKey } from './mux-original-read-lock-key.js';

const MAX_ACTIVE_READS = 4;
let activeReads = 0;

export async function acquireOriginalReadLock(assetId, onLost) {
    if (typeof assetId !== 'string' || !assetId || typeof onLost !== 'function') {
        throw new TypeError('An asset ID and lock-loss handler are required');
    }
    if (activeReads >= MAX_ACTIVE_READS) return null;
    activeReads += 1;
    let client;
    let acquired = false;
    let broken = false;
    let released = false;
    const key = originalReadLockKey(assetId);
    const lost = () => {
        if (released || broken) return;
        broken = true;
        onLost();
    };

    try {
        client = await pool.connect();
        client.on('error', lost);
        client.on('end', lost);
        const result = await client.query(
            'SELECT pg_try_advisory_lock_shared(hashtextextended($1, 0)) AS acquired',
            [key],
        );
        acquired = result.rows[0].acquired;
        if (!acquired) {
            client.removeListener('error', lost);
            client.removeListener('end', lost);
            client.release();
            activeReads -= 1;
            return null;
        }
    } catch (error) {
        if (client) {
            client.removeListener('error', lost);
            client.removeListener('end', lost);
            client.release(true);
        }
        activeReads -= 1;
        throw error;
    }

    return {
        async assertHeld() {
            if (broken || released) throw new Error('Original read lock connection was lost');
            await client.query('SELECT 1');
            if (broken || released) throw new Error('Original read lock connection was lost');
        },
        async release({ destroy = false } = {}) {
            if (released) return;
            released = true;
            try {
                if (acquired && !broken && !destroy) {
                    const result = await client.query(
                        'SELECT pg_advisory_unlock_shared(hashtextextended($1, 0)) AS released',
                        [key],
                    );
                    if (!result.rows[0].released) {
                        broken = true;
                        throw new Error('Original read lock was not held');
                    }
                }
            } catch (error) {
                broken = true;
                throw error;
            } finally {
                client.removeListener('error', lost);
                client.removeListener('end', lost);
                client.release(broken || destroy);
                activeReads -= 1;
            }
        },
    };
}
