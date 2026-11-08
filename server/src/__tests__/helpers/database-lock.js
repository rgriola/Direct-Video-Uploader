export async function acquireIntegrationDatabaseLock(pool) {
    const client = await pool.connect();
    try {
        await client.query('SELECT pg_advisory_lock(hashtextextended($1, 0))', ['dvu:integration-fixtures']);
    } catch (err) {
        client.release(true);
        throw err;
    }

    return async () => {
        try {
            const result = await client.query(
                'SELECT pg_advisory_unlock(hashtextextended($1, 0)) AS released',
                ['dvu:integration-fixtures'],
            );
            if (!result.rows[0].released) throw new Error('Integration fixture lock was not held');
        } finally {
            client.release();
        }
    };
}
