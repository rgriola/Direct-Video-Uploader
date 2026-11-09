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

export async function waitForBlockedQuery(pool, queryFragment, pid = null) {
    const deadline = Date.now() + 4000;
    while (Date.now() < deadline) {
        const result = await pool.query(`
            SELECT EXISTS (
                SELECT 1 FROM pg_stat_activity
                WHERE datname = current_database()
                  AND wait_event_type = 'Lock'
                  AND ($1::integer IS NULL OR pid = $1)
                  AND query LIKE $2
            ) AS waiting
        `, [pid, `%${queryFragment}%`]);
        if (result.rows[0].waiting) return;
        await new Promise(resolve => setTimeout(resolve, 20));
    }
    throw new Error(`Timed out waiting for a database lock: ${queryFragment}`);
}
