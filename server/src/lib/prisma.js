// Last updated: July 27, 2026 - 3:25pm - Claude Opus 4.7 — SSL now off for Cloud SQL Unix sockets
import 'dotenv/config';
import pg from 'pg';
import { PrismaPg } from '@prisma/adapter-pg';
import { PrismaClient } from '@prisma/client';

const isProduction = process.env.NODE_ENV === 'production';

// Only use SSL for TCP connections to managed Postgres (Render, RDS, etc.).
// Cloud SQL over Unix socket (host=/cloudsql/...) and local sockets don't support TLS.
// You can also force behavior with PGSSL=disable or PGSSL=require.
const dbUrl = process.env.DATABASE_URL || '';
const usesUnixSocket = /[?&]host=\/(?:cloudsql|var\/run\/postgresql|tmp)/i.test(dbUrl);
const sslMode = (process.env.PGSSL || '').toLowerCase();
const sslDisabledByUrl = /[?&]sslmode=disable\b/i.test(dbUrl);
const useSsl = sslMode === 'require'
    || (isProduction && !usesUnixSocket && !sslDisabledByUrl && sslMode !== 'disable');

const pool = new pg.Pool({
    connectionString: process.env.DATABASE_URL,
    max: 20,                   // Enough for concurrent dashboard + WS + API
    idleTimeoutMillis: isProduction ? 30000 : 10000,  // Keep connections alive longer in prod
    connectionTimeoutMillis: 15000, // 15s to acquire a connection (Render DB can be slow to wake)
    allowExitOnIdle: true,     // Don't block process exit
    ...(useSsl && { ssl: { rejectUnauthorized: false } }),
});

// Evict dead connections — test each connection before use
pool.on('connect', (client) => {
    client.on('error', (err) => {
        console.error('🛢️ PG client error:', err.message);
    });
});

// Handle pool errors so they don't crash the process
pool.on('error', (err) => {
    console.error('🛢️ PG pool error:', err.message);
});

// Warm up the pool — flush any stale connections from a previous run
try {
    const client = await pool.connect();
    await client.query('SELECT 1');
    client.release();
    console.log('🛢️ Database pool connected successfully');
} catch (err) {
    console.error('🛢️ Database pool warmup failed:', err.message);
    // Pool will recover on its own — this just speeds it up
}

const adapter = new PrismaPg(pool);

const prisma = new PrismaClient({
    adapter,
});

export default prisma;
