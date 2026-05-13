// Last updated: May 13, 2026 - 1:18pm - GitHub Copilot (GPT-5.3-Codex)
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
import authSsoRoutes from './routes/auth-sso.js';
import assetRoutes from './routes/assets.js';
import adminRoutes from './routes/admin.js';
import clipRoutes from './routes/clips.js';
import errorRoutes from './routes/errors.js';
import muxWebhookRoutes from './routes/mux-webhooks.js';
import { setupWebSocket } from './ws/handler.js';
import { startMuxSync, stopMuxSync } from './jobs/mux-sync.js';
import { startUploadCleanup, stopUploadCleanup } from './jobs/upload-cleanup.js';
import { CORS_ORIGINS, WS_CORS_ORIGINS } from './lib/config.js';
import prisma from './lib/prisma.js';
import redis, { closeRedis, isRedisConfigured, redisMode } from './lib/redis.js';
import { listMuxAssets } from './lib/mux.js';
import { hasSession } from './lib/session-store.js';
import { Role, normalizeRole, isSuperAdmin } from './lib/rbac.js';

// ─── Global Crash Protection ─────────────────────────────
// Prevent the process from dying on unhandled errors (Render shows 502 when this happens)
process.on('unhandledRejection', (reason) => {
    console.error({
        event: 'process.unhandledRejection',
        reason: reason instanceof Error ? reason.message : reason,
    });
});
process.on('uncaughtException', (err) => {
    console.error({
        event: 'process.uncaughtException',
        message: err?.message || 'Unknown uncaught exception',
    });
    // Give the logger time to flush, then exit so Render restarts us
    setTimeout(() => process.exit(1), 1000);
});

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = parseInt(process.env.PORT || '3000', 10);
const isProduction = process.env.NODE_ENV === 'production';
const HOST = process.env.HOST || (isProduction ? '0.0.0.0' : '::');
const LOG_LEVEL = process.env.LOG_LEVEL?.trim() || (isProduction ? 'info' : 'debug');
const APP_VERSION = process.env.npm_package_version || '1.0.0';
const MAX_NON_MULTIPART_BODY_BYTES = 2 * 1024 * 1024;
const SOCKET_IO_PATH = '/socket.io';
const WEB_SESSION_COOKIE_NAME = 'fixer_clip_token';
const REQUEST_START_TIME_KEY = Symbol('requestStartTimeMs');

const DEFAULT_GLOBAL_RATE_LIMIT_MAX = isProduction ? 100 : 2000;
const parsedGlobalRateLimitMax = Number.parseInt(process.env.GLOBAL_RATE_LIMIT_MAX || '', 10);
const GLOBAL_RATE_LIMIT_MAX = Number.isFinite(parsedGlobalRateLimitMax) && parsedGlobalRateLimitMax > 0
    ? parsedGlobalRateLimitMax
    : DEFAULT_GLOBAL_RATE_LIMIT_MAX;

function shouldBypassGlobalRateLimit(request) {
    if (isProduction) return false;
    const url = request.raw?.url || request.url || '';

    // In dev, static/HMR/browser probes can flood non-API paths and create noisy false positives.
    return !url.startsWith('/api/');
}

const REQUIRED_PROD_ENV = ['DATABASE_URL', 'JWT_SECRET', 'REDIS_URL'];
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

function getBearerToken(rawHeader) {
    const header = Array.isArray(rawHeader) ? rawHeader[0] : rawHeader;
    if (typeof header !== 'string') return null;
    if (!header.startsWith('Bearer ')) return null;

    const token = header.slice(7).trim();
    return token || null;
}

function getWebSessionToken(cookies) {
    const token = cookies?.[WEB_SESSION_COOKIE_NAME];
    if (typeof token !== 'string') return null;

    const trimmed = token.trim();
    return trimmed || null;
}

function validateEnvironment() {
    const missingCore = missingEnvVars(REQUIRED_PROD_ENV);
    const missingMux = missingEnvVars(REQUIRED_MUX_ENV);
    const hasAnyMux = REQUIRED_MUX_ENV.some((key) => !!process.env[key]);

    if (isProduction) {
        const missing = [...missingCore, ...missingMux];
        if (missing.length > 0) {
            console.error({
                event: 'env.missingRequired',
                missing,
            });
            process.exit(1);
        }
        return;
    }

    // In dev, Mux can be disabled, but partial config usually means a typo.
    if (hasAnyMux && missingMux.length > 0) {
        console.warn({
            event: 'env.partialMuxConfig',
            missing: missingMux,
        });
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
    trustProxy: isProduction, // Trust Render's reverse proxy for correct client IPs
    bodyLimit: MAX_NON_MULTIPART_BODY_BYTES,
});

fastify.decorate('redis', redis);
fastify.decorate('redisMode', redisMode);

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

// Track request start for precise access logging without external middleware.
fastify.addHook('onRequest', async (request) => {
    request[REQUEST_START_TIME_KEY] = Date.now();
});

// Security policy: explicitly disable sensitive browser features.
fastify.addHook('onSend', async (request, reply, payload) => {
    reply.header('X-Request-ID', request.id);
    reply.header('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
    return payload;
});

// Phase 4.2: production-grade HTTP access logs with latency + request correlation IDs.
fastify.addHook('onResponse', async (request, reply) => {
    const startedAt = request[REQUEST_START_TIME_KEY];
    const responseTimeMs = typeof startedAt === 'number'
        ? Math.max(Date.now() - startedAt, 0)
        : null;

    request.log.info({
        method: request.method,
        url: request.raw?.url || request.url,
        statusCode: reply.statusCode,
        responseTimeMs,
        requestId: request.id,
        userId: request.user?.id || null,
    }, 'HTTP access');
});

// B7: Global rate limiting — sensible defaults, per-route overrides below
await fastify.register(multipart, {
    limits: {
        fileSize: 1024 * 1024 * 500, // 500 MB max upload
    },
});

// JWT secret — required in production, random fallback in dev (A7)
const jwtSecret = process.env.JWT_SECRET || (() => {
    const generated = crypto.randomBytes(64).toString('hex');
    fastify.log.warn({
        event: 'auth.jwtSecret.generated',
    }, 'JWT_SECRET not set; using random secret. Sessions will reset on restart.');
    return generated;
})();

await fastify.register(fastifyJwt, {
    secret: jwtSecret,
});

function rateLimitKeyGenerator(request) {
    const token =
        getBearerToken(request.headers?.authorization)
        || getWebSessionToken(request.cookies);

    // Authenticated requests are rate-limited per user ID.
    if (token) {
        try {
            const decoded = fastify.jwt.verify(token);
            if (decoded?.id) {
                return `user:${decoded.id}`;
            }
        } catch {
            // Fall back to IP-based limiting for invalid or expired tokens.
        }
    }

    return `ip:${request.ip}`;
}

// B7: Global rate limiting — Redis-backed in production, in-memory fallback for local dev.
await fastify.register(rateLimit, {
    global: true,
    // Keep production strict, but avoid noisy local throttling during dev/HMR.
    max: GLOBAL_RATE_LIMIT_MAX,
    timeWindow: '1 minute',
    allowList: (request) => shouldBypassGlobalRateLimit(request),
    keyGenerator: rateLimitKeyGenerator,
    redis: isRedisConfigured ? redis : undefined,
    nameSpace: 'fixer-rate-limit-',
    skipOnError: true,
    addHeadersOnExceeding: {
        'x-ratelimit-limit': true,
        'x-ratelimit-remaining': true,
        'x-ratelimit-reset': true,
    },
    addHeaders: {
        'x-ratelimit-limit': true,
        'x-ratelimit-remaining': true,
        'x-ratelimit-reset': true,
        'retry-after': true,
    },
});

const docsGuard = async (request, reply) => {
    if (!isProduction) return;

    const token =
        getBearerToken(request.headers.authorization)
        || getWebSessionToken(request.cookies);

    if (!token) {
        return reply.status(401).send({ error: 'Unauthorized' });
    }

    let decoded;
    try {
        decoded = fastify.jwt.verify(token);
    } catch {
        return reply.status(401).send({ error: 'Unauthorized' });
    }

    if (!decoded?.jti || !(await hasSession(decoded.jti))) {
        return reply.status(401).send({ error: 'Unauthorized' });
    }

    const user = await prisma.user.findUnique({
        where: { id: decoded.id },
        select: { role: true, status: true },
    });

    if (!user || user.status !== 'ACTIVE' || !isSuperAdmin(user.role)) {
        return reply.status(403).send({ error: 'Admin access required' });
    }
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
        const token =
            getBearerToken(request.headers.authorization)
            || getWebSessionToken(request.cookies);

        if (!token) {
            return reply.status(401).send({ error: 'Unauthorized' });
        }

        const decoded = fastify.jwt.verify(token);

        if (!decoded?.jti || !(await hasSession(decoded.jti))) {
            return reply.status(401).send({ error: 'Unauthorized' });
        }

        request.user = decoded;

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
            role: normalizeRole(user.role) || Role.EDITOR,
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

// Role authorization helpers — requires authenticate to run first.
fastify.decorate('authorize', function (allowedRoles = [], errorMessage = 'Forbidden') {
    const allowed = new Set(
        allowedRoles
            .map((role) => normalizeRole(role))
            .filter(Boolean)
    );

    return async function (request, reply) {
        const role = normalizeRole(request.user?.role);
        if (!role || !allowed.has(role)) {
            return reply.status(403).send({ error: errorMessage });
        }
    };
});

fastify.decorate('authorizeAdmin', fastify.authorize([Role.SUPER_ADMIN], 'Admin access required'));
fastify.decorate('authorizeOrgAdmin', fastify.authorize([Role.SUPER_ADMIN, Role.ORG_ADMIN], 'Admin access required'));

// Clip viewer cookie-based auth (reads JWT from HttpOnly cookie)
fastify.decorate('clipAuthenticate', async function (request, reply) {
    const token = getWebSessionToken(request.cookies);
    if (!token) return null; // No cookie → caller decides what to do
    try {
        const decoded = fastify.jwt.verify(token);
        request.user = decoded;
        return decoded;
    } catch {
        // Expired/invalid cookie — clear it
        reply.clearCookie(WEB_SESSION_COOKIE_NAME, { path: '/' });
        reply.clearCookie(WEB_SESSION_COOKIE_NAME, { path: '/clips' });
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
await fastify.register(authSsoRoutes);
await fastify.register(assetRoutes);
await fastify.register(adminRoutes);

await fastify.register(clipRoutes);
await fastify.register(errorRoutes);
await fastify.register(muxWebhookRoutes);

// Chrome probes this path repeatedly when DevTools are open.
// Return 204 to avoid noisy 404 logs and request storms.
fastify.get('/.well-known/appspecific/com.chrome.devtools.json', async (_request, reply) => {
    reply.code(204).type('application/json').send('');
});

// Browsers routinely request favicon even when the app does not define one.
fastify.get('/favicon.ico', async (_request, reply) => {
    reply.code(204).send();
});

// Legacy URL compatibility so old bookmarks/deep-links do not dead-end in dev/prod.
fastify.get('/login', async (_request, reply) => reply.redirect('/'));
fastify.get('/dashboard', async (_request, reply) => reply.redirect('/'));
fastify.get('/dashboard/*', async (_request, reply) => reply.redirect('/'));

// Health check
fastify.get('/api/health', async () => ({
    status: 'ok',
    timestamp: new Date().toISOString(),
    service: 'Fixer',
    version: APP_VERSION,
    env: isProduction ? 'production' : 'development',
}));

fastify.get('/api/health/live', async () => ({
    status: 'ok',
    timestamp: new Date().toISOString(),
    service: 'Fixer',
    version: APP_VERSION,
    env: isProduction ? 'production' : 'development',
}));

fastify.get('/api/health/ready', async (request, reply) => {
    const checks = {
        database: { status: 'ok', message: 'Connected' },
        redis: {
            status: 'ok',
            message: isRedisConfigured
                ? 'Connected'
                : 'In-memory fallback (REDIS_URL unset)',
        },
        mux: { status: 'ok', message: 'Configured' },
    };

    try {
        await prisma.$queryRaw`SELECT 1`;
    } catch (err) {
        checks.database = { status: 'error', message: err.message };
    }

    if (isRedisConfigured) {
        try {
            await redis.ping();
        } catch (err) {
            checks.redis = { status: 'error', message: err.message };
        }
    }

    const muxConfigured = !!(
        process.env.MUX_TOKEN_ID
        && process.env.MUX_TOKEN_SECRET
        && process.env.MUX_ENV_KEY
        && process.env.MUX_WEBHOOK_SECRET
    );

    if (!muxConfigured) {
        checks.mux = { status: 'error', message: 'Mux env vars missing' };
    } else {
        const muxAssets = await listMuxAssets();
        if (!Array.isArray(muxAssets)) {
            checks.mux = { status: 'error', message: 'Mux API unreachable' };
        } else {
            checks.mux = { status: 'ok', message: 'Reachable' };
        }
    }

    const isReady = checks.database.status === 'ok'
        && checks.redis.status === 'ok'
        && checks.mux.status === 'ok';

    const responsePayload = {
        status: isReady ? 'ok' : 'degraded',
        timestamp: new Date().toISOString(),
        version: APP_VERSION,
        uptime: Math.floor(process.uptime()),
        uptimeSeconds: Math.floor(process.uptime()),
        db: checks.database.status,
        redis: checks.redis.status,
        mux: checks.mux.status,
        checks,
    };

    if (!isReady) {
        return reply.status(503).send(responsePayload);
    }

    return responsePayload;
});

// Lightweight admin metrics endpoint for dashboards and ops visibility.
fastify.get('/api/metrics', {
    preHandler: [fastify.authenticate, fastify.authorizeAdmin],
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
            ? `https://${process.env.RENDER_EXTERNAL_HOSTNAME || 'your-app.onrender.com'}`
            : `http://localhost:${PORT}`;

        fastify.log.info({
            event: 'server.started',
            baseUrl,
            env: isProduction ? 'production' : 'development',
            host: HOST,
            port: PORT,
        }, 'Fixer server started');

        // Start background jobs
        startMuxSync(fastify);
        startUploadCleanup(fastify);
    } catch (err) {
        fastify.log.error({
            event: 'server.start.error',
            err,
        }, 'Server startup failed');
        process.exit(1);
    }
};

// ─── Graceful Shutdown ───────────────────────────────────
// Clean up connections when Render sends SIGTERM during deploys
const shutdown = async (signal) => {
    fastify.log.info({ event: 'server.shutdown.start', signal }, 'Shutdown signal received');
    try {
        stopMuxSync();          // Stop background jobs
        stopUploadCleanup();
        io.close();       // Close WebSocket connections
        await fastify.close(); // Stop accepting HTTP, finish in-flight requests
        await closeRedis();
        fastify.log.info({ event: 'server.shutdown.complete', signal }, 'Server stopped cleanly');
    } catch (err) {
        fastify.log.error({
            event: 'server.shutdown.error',
            signal,
            message: err.message,
        }, 'Shutdown error');
    }
    process.exit(0);
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

start();
