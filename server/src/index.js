// Last updated: May 10, 2026 - 3:19pm - GPT-5.3-Codex
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
import fastifySwagger from '@fastify/swagger';
import fastifySwaggerUi from '@fastify/swagger-ui';
import rateLimit from '@fastify/rate-limit';
import helmet from '@fastify/helmet';
import cookie from '@fastify/cookie';
import formbody from '@fastify/formbody';
import csrfProtection from '@fastify/csrf-protection';
import ajvFormats from 'ajv-formats';
import { Server as SocketIOServer } from 'socket.io';
import path from 'path';
import crypto from 'crypto';
import { fileURLToPath } from 'url';

import authRoutes from './routes/auth.js';
import assetRoutes from './routes/assets.js';
import adminRoutes from './routes/admin.js';
import moderationRoutes from './routes/moderation.js';
import clipRoutes from './routes/clips.js';
import errorRoutes from './routes/errors.js';
import muxWebhookRoutes from './routes/mux-webhooks.js';
import { setupWebSocket } from './ws/handler.js';
import { startMuxSync, stopMuxSync } from './jobs/mux-sync.js';
import { startUploadCleanup, stopUploadCleanup } from './jobs/upload-cleanup.js';
import { CORS_ORIGINS, WS_CORS_ORIGINS } from './lib/config.js';
import prisma from './lib/prisma.js';
import { requireRole } from './lib/authorization.js';
import { ROLES } from './lib/roles.js';

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
const LOG_LEVEL = process.env.LOG_LEVEL?.trim() || (isProduction ? 'info' : 'debug');
const MAX_NON_MULTIPART_BODY_BYTES = 2 * 1024 * 1024;
const SOCKET_IO_PATH = '/socket.io';

const REQUIRED_PROD_ENV = ['DATABASE_URL', 'JWT_SECRET'];
const REQUIRED_MUX_ENV = ['MUX_TOKEN_ID', 'MUX_TOKEN_SECRET', 'MUX_ENV_KEY', 'MUX_WEBHOOK_SECRET'];

function missingEnvVars(keys) {
    return keys.filter((key) => !process.env[key] || process.env[key].trim() === '');
}

function normalizeRequestId(rawValue) {
    const value = Array.isArray(rawValue) ? rawValue[0] : rawValue;
    if (typeof value !== 'string') return null;
    const trimmed = value.trim();
    if (!trimmed) return null;
    return trimmed.slice(0, 128);
}

function validateEnvironment() {
    const missingCore = missingEnvVars(REQUIRED_PROD_ENV);
    const missingMux = missingEnvVars(REQUIRED_MUX_ENV);
    const hasAnyMux = REQUIRED_MUX_ENV.some((key) => !!process.env[key]);

    if (isProduction) {
        const missing = [...missingCore, ...missingMux];
        if (missing.length > 0) {
            console.error(`\n🛑 Missing required environment variables: ${missing.join(', ')}\n`);
            process.exit(1);
        }
        return;
    }

    // In dev, Mux can be disabled, but partial config usually means a typo.
    if (hasAnyMux && missingMux.length > 0) {
        console.warn(`\n⚠️  Partial Mux configuration detected. Missing: ${missingMux.join(', ')}\n`);
    }
}

validateEnvironment();

// ─── Create Fastify Server ──────────────────────────────
const fastify = Fastify({
    logger: {
        level: LOG_LEVEL,
        redact: {
            paths: [
                'req.headers.authorization',
                'req.headers.cookie',
                'req.body.phoneNumber',
                'req.body.companyCode',
                'req.body.token',
                'request.user.phoneNumber',
                'request.user.companyCode',
                'request.user.token',
            ],
            censor: '[REDACTED]',
        },
        serializers: {
            req: (req) => ({
                id: req.id,
                method: req.method,
                url: req.url,
                ip: req.ip,
            }),
            res: (res) => ({
                statusCode: res.statusCode,
            }),
            err: (err) => ({
                type: err.name,
                message: err.message,
                ...(isProduction ? {} : { stack: err.stack }),
            }),
        },
        // Pretty logs in dev, raw JSON in production (Render captures structured logs)
        ...(isProduction ? {} : {
            transport: {
                target: 'pino-pretty',
                options: { colorize: true },
            },
        }),
    },
    requestIdHeader: 'x-request-id',
    requestIdLogLabel: 'requestId',
    genReqId: (req) => normalizeRequestId(req.headers['x-request-id']) || crypto.randomUUID(),
    childLoggerFactory: (logger, bindings) => {
        const requestId = bindings.requestId || bindings.reqId;
        return logger.child({ ...bindings, requestId });
    },
    ajv: {
        plugins: [ajvFormats],
    },
    trustProxy: isProduction, // Trust the reverse proxy (Cloud Run / Cloudflare Tunnel) for correct client IPs
    bodyLimit: MAX_NON_MULTIPART_BODY_BYTES,
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

// CSRF tokens for cookie-authenticated browser forms (clip viewer login).
await fastify.register(csrfProtection);

// Form body parsing for clip viewer login form (application/x-www-form-urlencoded)
await fastify.register(formbody);

// Security policy: explicitly disable sensitive browser features.
fastify.addHook('onSend', async (request, reply, payload) => {
    reply.header('X-Request-ID', request.id);
    reply.header('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
    return payload;
});

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
const jwtSecret = process.env.JWT_SECRET || (() => {
    const generated = crypto.randomBytes(64).toString('hex');
    console.warn('\n⚠️  JWT_SECRET not set — using random secret. Sessions will reset on restart.\n');
    return generated;
})();

await fastify.register(fastifyJwt, {
    secret: jwtSecret,
});

const docsGuard = async (request, reply) => {
    if (!isProduction) return;

    const authHeader = request.headers.authorization || '';
    const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : null;

    if (!token) {
        return reply.status(401).send({ error: 'Unauthorized' });
    }

    let decoded;
    try {
        decoded = fastify.jwt.verify(token);
    } catch {
        return reply.status(401).send({ error: 'Unauthorized' });
    }

    const user = await prisma.user.findUnique({
        where: { id: decoded.id },
        select: { role: true, status: true, companyCode: true },
    });

    if (!user || user.status !== 'ACTIVE') {
        return reply.status(403).send({ error: 'Admin access required' });
    }

    request.user = user;
    return requireRole(ROLES.SUPER_ADMIN, ROLES.ADMIN)(request, reply);
};

await fastify.register(fastifySwagger, {
    openapi: {
        info: {
            title: 'Fixer API',
            description: 'Fixer server API documentation',
            version: '1.0.0',
        },
    },
});

await fastify.register(fastifySwaggerUi, {
    routePrefix: '/api/docs',
    uiHooks: {
        onRequest: docsGuard,
    },
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

        const user = await prisma.user.findUnique({
            where: { id: request.user.id },
            select: {
                id: true,
                name: true,
                phoneNumber: true,
                role: true,
                status: true,
                companyCode: true,
            },
        });

        if (!user) {
            return reply.status(401).send({ error: 'Unauthorized' });
        }

        if (user.status !== 'ACTIVE') {
            return reply.status(403).send({ error: 'Account suspended' });
        }

        request.user = {
            ...request.user,
            id: user.id,
            name: user.name,
            phoneNumber: user.phoneNumber,
            role: user.role || 'USER',
            status: user.status,
            companyCode: user.companyCode || null,
        };
    } catch (err) {
        if (!reply.sent) {
            reply.status(401).send({ error: 'Unauthorized' });
        }
    }
});

// Centralized error response policy: never leak stacks to clients in production.
fastify.setErrorHandler((err, request, reply) => {
    fastify.log.error({ err, url: request.raw?.url, method: request.method }, 'Request failed');

    if (reply.sent) return;

    if (err.code === 'FST_CSRF_INVALID_TOKEN') {
        return reply.status(403).send({ error: 'Invalid CSRF token' });
    }

    if (err.validation) {
        return reply.status(422).send({
            error: 'Validation failed',
            ...(isProduction ? {} : { details: err.validation }),
        });
    }

    const statusCode = Number.isInteger(err.statusCode) ? err.statusCode : 500;
    if (statusCode >= 500) {
        return reply.status(500).send({
            error: 'Internal Server Error',
            ...(isProduction ? {} : { details: err.message }),
        });
    }

    return reply.status(statusCode).send({ error: err.message || 'Request failed' });
});

fastify.decorate('requireRole', requireRole);

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
    path: SOCKET_IO_PATH,
    addTrailingSlash: false,
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
await fastify.register(moderationRoutes);

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

fastify.get('/api/health/live', async () => ({
    status: 'ok',
    timestamp: new Date().toISOString(),
    service: 'Fixer',
    version: '1.0.0',
    env: isProduction ? 'production' : 'development',
}));

fastify.get('/api/health/ready', async (request, reply) => {
    const checks = {
        database: { status: 'ok', message: 'Connected' },
        mux: { status: 'ok', message: 'Configured' },
    };

    try {
        await prisma.$queryRaw`SELECT 1`;
    } catch (err) {
        checks.database = { status: 'error', message: err.message };
    }

    const muxConfigured = !!(
        process.env.MUX_TOKEN_ID
        && process.env.MUX_TOKEN_SECRET
        && process.env.MUX_ENV_KEY
        && process.env.MUX_WEBHOOK_SECRET
    );

    if (!muxConfigured) {
        checks.mux = { status: 'error', message: 'Mux env vars missing' };
    }

    const isReady = checks.database.status === 'ok' && checks.mux.status === 'ok';

    if (!isReady) {
        return reply.status(503).send({
            status: 'degraded',
            timestamp: new Date().toISOString(),
            checks,
        });
    }

    return {
        status: 'ok',
        timestamp: new Date().toISOString(),
        checks,
    };
});

// Lightweight admin metrics endpoint for dashboards and ops visibility.
fastify.get('/api/metrics', {
    preHandler: [fastify.authenticate, fastify.requireRole(ROLES.SUPER_ADMIN)],
}, async () => {
    const [counts = {}] = await prisma.$queryRaw`
        SELECT
            (SELECT COUNT(*)::int FROM users) AS users,
            (SELECT COUNT(*)::int FROM assets) AS assets,
            (SELECT COUNT(*)::int FROM assets WHERE status = 'READY') AS "readyAssets",
            (SELECT COUNT(*)::int FROM clips) AS clips,
            (SELECT COUNT(*)::int FROM clips WHERE status = 'READY') AS "readyClips",
            (SELECT COUNT(*)::int FROM error_logs) AS "errorLogs"
    `;

    const memory = process.memoryUsage();
    const ioSockets = fastify.io?.of('/')?.sockets?.size || 0;
    const iosClients = fastify.iosSockets?.size || 0;
    const adminClients = fastify.adminSockets?.size || 0;
    const connectedUsers = fastify.userSockets?.size || 0;

    return {
        timestamp: new Date().toISOString(),
        uptimeSeconds: Math.floor(process.uptime()),
        process: {
            pid: process.pid,
            nodeVersion: process.version,
            memoryRssBytes: memory.rss,
            memoryHeapUsedBytes: memory.heapUsed,
            memoryHeapTotalBytes: memory.heapTotal,
        },
        websocket: {
            totalConnections: ioSockets,
            iosClients,
            adminClients,
            connectedUsers,
        },
        database: {
            users: counts.users || 0,
            assets: counts.assets || 0,
            readyAssets: counts.readyAssets || 0,
            clips: counts.clips || 0,
            readyClips: counts.readyClips || 0,
            errorLogs: counts.errorLogs || 0,
        },
    };
});

// ─── Start Server ────────────────────────────────────────
const start = async () => {
    try {
        // Set up WebSocket handlers
        setupWebSocket(io, fastify);

        await fastify.listen({ port: PORT, host: HOST });

        const baseUrl = isProduction
    ? (process.env.PUBLIC_URL || `https://${process.env.RENDER_EXTERNAL_HOSTNAME || 'cloud-run'}`)
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
        startUploadCleanup(fastify);
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
