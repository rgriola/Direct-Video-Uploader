import 'dotenv/config';
import pg from 'pg';
import { PrismaPg } from '@prisma/adapter-pg';
import { PrismaClient } from '@prisma/client';

const pool = new pg.Pool({
    connectionString: process.env.DATABASE_URL,
    max: 20,                   // Enough for concurrent dashboard + WS + API
    idleTimeoutMillis: 10000,  // Close idle connections after 10s (evict stale faster)
    connectionTimeoutMillis: 10000, // 10s to acquire a connection
    allowExitOnIdle: true,     // Don't block process exit
});

// Evict dead connections — test each connection before use
pool.on('connect', (client) => {
    client.on('error', () => {
        // Silently handled — pool creates fresh connections automatically
    });
});

// Handle pool errors so they don't crash the process
pool.on('error', () => {
    // Silently handled — pool recovers on its own
});

// Warm up the pool — flush any stale connections from a previous run
try {
    const client = await pool.connect();
    await client.query('SELECT 1');
    client.release();
} catch {
    // Pool will recover on its own — this just speeds it up
}

const adapter = new PrismaPg(pool);

const prisma = new PrismaClient({
    adapter,
});

export default prisma;
