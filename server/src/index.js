/**
 * Fixer — Server Entry Point
 *
 * Fastify + Socket.IO + Prisma
 * Real-time chat server for the video upload platform.
 */
import 'dotenv/config';
import Fastify from 'fastify';
import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import fastifyJwt from '@fastify/jwt';
import fastifyStatic from '@fastify/static';
import rateLimit from '@fastify/rate-limit';
import helmet from '@fastify/helmet';
import cookie from '@fastify/cookie';
import formbody from '@fastify/formbody';
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
import { startMuxSync, stopMuxSync } from './jobs/mux-sync.js';
import { startUploadCleanup, stopUploadCleanup } from './jobs/upload-cleanup.js';
import { CORS_ORIGINS, WS_CORS_ORIGINS } from './lib/config.js';

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
    origin: CORS_ORIGINS,
    credentials: true,
});

// B8: Security headers (HSTS, X-Frame-Options, X-Content-Type-Options, CSP)
await fastify.register(helmet, {
    contentSecurityPolicy: isProduction
        ? {
            directives: {
                defaultSrc: ["'self'"],
                scriptSrc: ["'self'", "'unsafe-inline'", 'https://cdn.jsdelivr.net'],
                styleSrc: ["'self'", "'unsafe-inline'", 'https://fonts.googleapis.com'],
                imgSrc: ["'self'", 'data:', 'https://image.mux.com', 'https://*.mux.com'],
                mediaSrc: ["'self'", 'https://*.mux.com', 'https://*.edgemv.mux.com', 'blob:'],
                connectSrc: ["'self'", 'https://*.mux.com', 'https://*.edgemv.mux.com', 'https://*.litix.io'],
                fontSrc: ["'self'", 'https://fonts.gstatic.com'],
                frameSrc: ["'none'"],
            },
        }
        : false, // Disable CSP in dev (allows inline scripts for dashboard)
    // Clip viewer loads cross-origin media/scripts from Mux CDN + jsdelivr.
    // Helmet defaults (same-origin) block those fetches independently of CSP.
    crossOriginResourcePolicy: { policy: 'cross-origin' },
    crossOriginEmbedderPolicy: false,
});

// Cookie support for clip viewer auth (HttpOnly session cookie)
await fastify.register(cookie);

// Form body parsing for clip viewer login form (application/x-www-form-urlencoded)
await fastify.register(formbody);

// B7: Global rate limiting — sensible defaults, per-route overrides below
await fastify.register(rateLimit, {
    global: true,
    max: 100,               // 100 requests per window per IP
    timeWindow: '1 minute',
});

await fastify.register(multipart, {
    limits: {
        fileSize: 1024 * 1024 * 500, // 500 MB max upload
    },
});

// JWT secret — required in production, random fallback in dev (A7)
if (!process.env.JWT_SECRET && isProduction) {
    console.error('\n🛑  JWT_SECRET is required in production. Set it in your environment variables.\n');
    process.exit(1);
}
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

// Admin authorization — requires authenticate to run first (A5)
fastify.decorate('authorizeAdmin', async function (request, reply) {
    if (request.user?.role !== 'ADMIN') {
        reply.status(403).send({ error: 'Admin access required' });
    }
});

// Clip viewer cookie-based auth (reads JWT from HttpOnly cookie)
fastify.decorate('clipAuthenticate', async function (request, reply) {
    const token = request.cookies?.fixer_clip_token;
    if (!token) return null; // No cookie → caller decides what to do
    try {
        const decoded = fastify.jwt.verify(token);
        request.user = decoded;
        return decoded;
    } catch {
        // Expired/invalid cookie — clear it
        reply.clearCookie('fixer_clip_token', { path: '/clips' });
        return null;
    }
});

// ─── Socket.IO ───────────────────────────────────────────
const io = new SocketIOServer(fastify.server, {
    cors: {
        origin: WS_CORS_ORIGINS,
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
    service: 'Fixer',
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
║  🎬 Fixer Server                           ║
║                                            ║
║  URL:    ${baseUrl.padEnd(33)}║
║  Env:    ${(isProduction ? 'production' : 'development').padEnd(33)}║
║                                            ║
║  Status: Running ✅                         ║
╚══════════════════════════════════════════  ╝
    `);

        // Start background jobs
        startMuxSync(fastify);
        startUploadCleanup();
    } catch (err) {
        fastify.log.error(err);
        process.exit(1);
    }
};

// ─── Graceful Shutdown ───────────────────────────────────
// Clean up connections when Render sends SIGTERM during deploys
const shutdown = async (signal) => {
    console.log(`\n🛑 ${signal} received — shutting down gracefully...`);
    try {
        stopMuxSync();          // Stop background jobs
        stopUploadCleanup();
        io.close();       // Close WebSocket connections
        await fastify.close(); // Stop accepting HTTP, finish in-flight requests
        console.log('👋 Server stopped cleanly');
    } catch (err) {
        console.error('Shutdown error:', err.message);
    }
    process.exit(0);
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

start();
