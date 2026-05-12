// Last updated: May 12, 2026 - 4:28pm - GitHub Copilot (GPT-5.3-Codex)
import 'dotenv/config';
import pg from 'pg';
import { PrismaPg } from '@prisma/adapter-pg';
import { PrismaClient } from '@prisma/client';

const isProduction = process.env.NODE_ENV === 'production';

const pool = new pg.Pool({
    connectionString: process.env.DATABASE_URL,
    max: 20,                   // Enough for concurrent dashboard + WS + API
    idleTimeoutMillis: isProduction ? 30000 : 10000,  // Keep connections alive longer in prod
    connectionTimeoutMillis: 15000, // 15s to acquire a connection (Render DB can be slow to wake)
    allowExitOnIdle: true,     // Don't block process exit
    // Render managed PostgreSQL requires SSL
    ...(isProduction && { ssl: { rejectUnauthorized: false } }),
});

// Evict dead connections — test each connection before use
pool.on('connect', (client) => {
    client.on('error', (err) => {
        console.error({ event: 'db.pgClient.error', message: err.message });
    });
});

// Handle pool errors so they don't crash the process
pool.on('error', (err) => {
    console.error({ event: 'db.pool.error', message: err.message });
});

// Warm up the pool — flush any stale connections from a previous run
try {
    const client = await pool.connect();
    await client.query('SELECT 1');
    client.release();
    console.log({ event: 'db.pool.warmup.ok' });
} catch (err) {
    console.error({ event: 'db.pool.warmup.failed', message: err.message });
    // Pool will recover on its own — this just speeds it up
}

const adapter = new PrismaPg(pool);

const prisma = new PrismaClient({
    adapter,
});

export default prisma;
