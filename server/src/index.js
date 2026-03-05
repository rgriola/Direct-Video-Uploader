/**
 * Direct Video Uploader — Server Entry Point
 *
 * Fastify + Socket.IO + Prisma
 * Real-time chat server for the video upload demo.
 */
import 'dotenv/config';
import Fastify from 'fastify';
import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import fastifyJwt from '@fastify/jwt';
import fastifyStatic from '@fastify/static';
import rateLimit from '@fastify/rate-limit';
import { Server as SocketIOServer } from 'socket.io';
import path from 'path';
import crypto from 'crypto';
import { fileURLToPath } from 'url';

import authRoutes from './routes/auth.js';
import assetRoutes from './routes/assets.js';
import adminRoutes from './routes/admin.js';
import clipRoutes from './routes/clips.js';
import errorRoutes from './routes/errors.js';
import muxWebhookRoutes from './routes/mux-webhooks.js';
import { setupWebSocket } from './ws/handler.js';

// ─── Global Crash Protection ─────────────────────────────
// Prevent the process from dying on unhandled errors (Render shows 502 when this happens)
process.on('unhandledRejection', (reason, promise) => {
    console.error('⚠️ Unhandled Rejection:', reason);
});
process.on('uncaughtException', (err) => {
    console.error('🔥 Uncaught Exception:', err);
    // Give the logger time to flush, then exit so Render restarts us
    setTimeout(() => process.exit(1), 1000);
});

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '0.0.0.0';
const isProduction = process.env.NODE_ENV === 'production';

// ─── Create Fastify Server ──────────────────────────────
const fastify = Fastify({
    logger: {
        level: 'info',
        // Pretty logs in dev, raw JSON in production (Render captures structured logs)
        ...(isProduction ? {} : {
            transport: {
                target: 'pino-pretty',
                options: { colorize: true },
            },
        }),
    },
    trustProxy: isProduction, // Trust Render's reverse proxy for correct client IPs
});

// ─── Plugins ─────────────────────────────────────────────
await fastify.register(cors, {
    origin: isProduction
        ? ['https://rodgriola.com', 'https://www.rodgriola.com']
        : true,
    credentials: true,
});

await fastify.register(rateLimit, {
    global: false, // Don't rate-limit all routes — applied per-route where needed
});

await fastify.register(multipart, {
    limits: {
        fileSize: 1024 * 1024 * 500, // 500 MB max upload
    },
});

// JWT secret — warn loudly if not configured (#6)
const jwtSecret = process.env.JWT_SECRET || (() => {
    const generated = crypto.randomBytes(64).toString('hex');
    console.warn('\n⚠️  JWT_SECRET not set — using random secret. Sessions will reset on restart.\n');
    return generated;
})();

await fastify.register(fastifyJwt, {
    secret: jwtSecret,
});

// Ensure uploads directory exists (ephemeral on Render — cloud storage replaces this)
import { mkdirSync } from 'fs';
mkdirSync(path.resolve(process.cwd(), 'uploads'), { recursive: true });

// Serve uploaded files statically (demo only — production uses R2/S3)
await fastify.register(fastifyStatic, {
    root: path.resolve(process.cwd(), 'uploads'),
    prefix: '/uploads/',
    decorateReply: false,
});

// Serve dashboard from public/ (wildcard: false so dynamic routes like /clips/:slug aren't swallowed)
await fastify.register(fastifyStatic, {
    root: path.resolve(process.cwd(), 'public'),
    prefix: '/',
    decorateReply: false,
    wildcard: false,
});

// ─── Auth Decorator ──────────────────────────────────────
fastify.decorate('authenticate', async function (request, reply) {
    try {
        await request.jwtVerify();
    } catch (err) {
        reply.status(401).send({ error: 'Unauthorized' });
    }
});

// ─── Socket.IO ───────────────────────────────────────────
const io = new SocketIOServer(fastify.server, {
    cors: {
        origin: '*',
        methods: ['GET', 'POST'],
    },
    transports: ['websocket', 'polling'],
    pingTimeout: 25000,
    pingInterval: 20000,
    connectTimeout: 10000,
});

fastify.decorate('io', io);

// ─── Routes ──────────────────────────────────────────────
await fastify.register(authRoutes);
await fastify.register(assetRoutes);
await fastify.register(adminRoutes);

await fastify.register(clipRoutes);
await fastify.register(errorRoutes);
await fastify.register(muxWebhookRoutes);

// Health check
fastify.get('/api/health', async () => ({
    status: 'ok',
    timestamp: new Date().toISOString(),
    service: 'Direct Video Uploader',
    version: '1.0.0',
    env: isProduction ? 'production' : 'development',
}));

// ─── Start Server ────────────────────────────────────────
const start = async () => {
    try {
        // Set up WebSocket handlers
        setupWebSocket(io, fastify);

        await fastify.listen({ port: PORT, host: HOST });

        const baseUrl = isProduction
            ? `https://${process.env.RENDER_EXTERNAL_HOSTNAME || 'your-app.onrender.com'}`
            : `http://localhost:${PORT}`;

        console.log(`
╔════════════════════════════════════════════╗
║  🎬 Direct Video Uploader Server           ║
║                                            ║
║  URL:    ${baseUrl.padEnd(33)}║
║  Env:    ${(isProduction ? 'production' : 'development').padEnd(33)}║
║                                            ║
║  Status: Running ✅                         ║
╚══════════════════════════════════════════  ╝
    `);
    } catch (err) {
        fastify.log.error(err);
        process.exit(1);
    }
};

start();
