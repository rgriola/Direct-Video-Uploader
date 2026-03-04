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
import { Server as SocketIOServer } from 'socket.io';
import path from 'path';
import crypto from 'crypto';
import { fileURLToPath } from 'url';

import authRoutes from './routes/auth.js';
import assetRoutes from './routes/assets.js';
import adminRoutes from './routes/admin.js';
import clipRoutes from './routes/clips.js';
import { setupWebSocket } from './ws/handler.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '0.0.0.0';

// ─── Create Fastify Server ──────────────────────────────
const fastify = Fastify({
    logger: {
        level: 'info',
        transport: {
            target: 'pino-pretty',
            options: { colorize: true },
        },
    },
});

// ─── Plugins ─────────────────────────────────────────────
await fastify.register(cors, {
    origin: true, // Allow all origins for demo
    credentials: true,
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

// Health check
fastify.get('/api/health', async () => ({
    status: 'ok',
    timestamp: new Date().toISOString(),
    service: 'Direct Video Uploader',
    version: '1.0.0',
}));

// ─── Start Server ────────────────────────────────────────
const start = async () => {
    try {
        // Set up WebSocket handlers
        setupWebSocket(io, fastify);

        await fastify.listen({ port: PORT, host: HOST });

        console.log(`
╔══════════════════════════════════════════  ╗
║  🎬 Direct Video Uploader Server           ║
║                                            ║
║  HTTP:   http://localhost:${PORT}          ║
║  WS:     ws://localhost:${PORT}/socket.io/ ║
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
