// Last updated: May 9, 2026 - 9:07pm - GPT-5.3-Codex
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const fastifyState = {
    instances: [],
    listenError: null,
    closeError: null,
};

const socketState = {
    instances: [],
};

const processHandlers = {};

const prismaMock = {
    user: {
        findUnique: vi.fn(),
    },
    $queryRaw: vi.fn(),
};

const setupWebSocketMock = vi.fn();
const startMuxSyncMock = vi.fn();
const stopMuxSyncMock = vi.fn();
const startUploadCleanupMock = vi.fn();
const stopUploadCleanupMock = vi.fn();

function registerRoute(routeMap, url, optsOrHandler, maybeHandler) {
    const hasOptions = typeof optsOrHandler !== 'function';
    const handler = hasOptions ? maybeHandler : optsOrHandler;
    const options = hasOptions ? (optsOrHandler || {}) : {};
    routeMap.set(url, { options, handler });
}

const fastifyCtorMock = vi.fn((opts) => {
    const routes = { GET: new Map(), POST: new Map() };
    const hooks = {};

    const instance = {
        __opts: opts,
        __routes: routes,
        __hooks: hooks,
        __registerCalls: [],
        __errorHandler: null,
        server: {},
        register: vi.fn(async function (plugin, options) {
            this.__registerCalls.push({ plugin, options });
        }),
        decorate: vi.fn(function (name, value) {
            this[name] = value;
            return this;
        }),
        addHook: vi.fn(function (name, fn) {
            this.__hooks[name] = fn;
        }),
        setErrorHandler: vi.fn(function (fn) {
            this.__errorHandler = fn;
        }),
        get: vi.fn(function (url, optsOrHandler, maybeHandler) {
            registerRoute(this.__routes.GET, url, optsOrHandler, maybeHandler);
        }),
        post: vi.fn(function (url, optsOrHandler, maybeHandler) {
            registerRoute(this.__routes.POST, url, optsOrHandler, maybeHandler);
        }),
        listen: vi.fn(async () => {
            if (fastifyState.listenError) throw fastifyState.listenError;
        }),
        close: vi.fn(async () => {
            if (fastifyState.closeError) throw fastifyState.closeError;
        }),
        jwt: {
            verify: vi.fn(() => ({ id: 'admin-1' })),
        },
        io: {
            of: vi.fn(() => ({ sockets: new Map([['s1', {}]]) })),
        },
        userSockets: new Map([['user-1', new Set(['sid-1'])]]),
        iosSockets: new Set(['sid-1']),
        adminSockets: new Set(['sid-2']),
        log: {
            error: vi.fn(),
        },
    };

    fastifyState.instances.push(instance);
    return instance;
});

const socketCtorMock = vi.fn(class MockSocketIOServer {
    constructor(_server, _opts) {
        this.close = vi.fn();
        this.of = vi.fn(() => ({ sockets: new Map() }));
        this.to = vi.fn(() => ({ emit: vi.fn() }));
        socketState.instances.push(this);
    }
});

vi.mock('fastify', () => ({
    default: fastifyCtorMock,
}));

vi.mock('@fastify/cors', () => ({ default: vi.fn(async () => {}) }));
vi.mock('@fastify/multipart', () => ({ default: vi.fn(async () => {}) }));
vi.mock('@fastify/jwt', () => ({ default: vi.fn(async () => {}) }));
vi.mock('@fastify/static', () => ({ default: vi.fn(async () => {}) }));
vi.mock('@fastify/swagger', () => ({ default: vi.fn(async () => {}) }));
vi.mock('@fastify/swagger-ui', () => ({ default: vi.fn(async () => {}) }));
vi.mock('@fastify/rate-limit', () => ({ default: vi.fn(async () => {}) }));
vi.mock('@fastify/helmet', () => ({ default: vi.fn(async () => {}) }));
vi.mock('@fastify/cookie', () => ({ default: vi.fn(async () => {}) }));
vi.mock('@fastify/formbody', () => ({ default: vi.fn(async () => {}) }));
vi.mock('@fastify/csrf-protection', () => ({ default: vi.fn(async () => {}) }));
vi.mock('ajv-formats', () => ({ default: vi.fn() }));

vi.mock('socket.io', () => ({
    Server: socketCtorMock,
}));

vi.mock('../routes/auth.js', () => ({ default: vi.fn(async () => {}) }));
vi.mock('../routes/assets.js', () => ({ default: vi.fn(async () => {}) }));
vi.mock('../routes/admin.js', () => ({ default: vi.fn(async () => {}) }));
vi.mock('../routes/clips.js', () => ({ default: vi.fn(async () => {}) }));
vi.mock('../routes/errors.js', () => ({ default: vi.fn(async () => {}) }));
vi.mock('../routes/mux-webhooks.js', () => ({ default: vi.fn(async () => {}) }));

vi.mock('../ws/handler.js', () => ({
    setupWebSocket: setupWebSocketMock,
}));

vi.mock('../jobs/mux-sync.js', () => ({
    startMuxSync: startMuxSyncMock,
    stopMuxSync: stopMuxSyncMock,
}));

vi.mock('../jobs/upload-cleanup.js', () => ({
    startUploadCleanup: startUploadCleanupMock,
    stopUploadCleanup: stopUploadCleanupMock,
}));

vi.mock('../lib/config.js', () => ({
    CORS_ORIGINS: ['http://localhost:5173'],
    WS_CORS_ORIGINS: ['http://localhost:5173'],
}));

vi.mock('../lib/prisma.js', () => ({
    default: prismaMock,
}));

function makeReply() {
    return {
        sent: false,
        statusCode: null,
        payload: null,
        headers: {},
        status: vi.fn(function (code) {
            this.statusCode = code;
            return this;
        }),
        send: vi.fn(function (payload) {
            this.payload = payload;
            this.sent = true;
            return payload;
        }),
        header: vi.fn(function (name, value) {
            this.headers[name] = value;
            return this;
        }),
        clearCookie: vi.fn(),
        setCookie: vi.fn(),
        redirect: vi.fn(function (location) {
            this.location = location;
            return this;
        }),
        generateCsrf: vi.fn(async () => 'csrf-token'),
    };
}

function getDocsGuard(fastify) {
    const docsCall = fastify.__registerCalls.find((call) => call.options?.routePrefix === '/api/docs');
    return docsCall?.options?.uiHooks?.onRequest;
}

function getRouteHandler(fastify, method, url) {
    return fastify.__routes[method].get(url)?.handler;
}

const originalEnv = { ...process.env };
let processOnSpy;
let processExitSpy;
let consoleWarnSpy;
let consoleLogSpy;
let consoleErrorSpy;

async function importIndexModule() {
    vi.resetModules();
    await import('../index.js');
    await new Promise((resolve) => setImmediate(resolve));
}

beforeEach(() => {
    process.env = { ...originalEnv };
    process.env.NODE_ENV = 'test';
    process.env.PORT = '4460';
    process.env.HOST = '127.0.0.1';
    process.env.DATABASE_URL = 'postgresql://localhost:5432/directvideo';
    process.env.JWT_SECRET = 'test-secret';

    delete process.env.MUX_TOKEN_ID;
    delete process.env.MUX_TOKEN_SECRET;
    delete process.env.MUX_ENV_KEY;
    delete process.env.MUX_WEBHOOK_SECRET;

    prismaMock.user.findUnique.mockReset();
    prismaMock.$queryRaw.mockReset();
    prismaMock.user.findUnique.mockResolvedValue({
        id: 'admin-1',
        name: 'Admin',
        phoneNumber: '5055551111',
        role: 'ADMIN',
        status: 'ACTIVE',
        companyCode: 'NEWS',
    });
    prismaMock.$queryRaw.mockResolvedValue([{ users: 1, assets: 1, readyAssets: 1, clips: 1, readyClips: 1, errorLogs: 0 }]);

    fastifyState.instances = [];
    fastifyState.listenError = null;
    fastifyState.closeError = null;
    socketState.instances = [];
    for (const key of Object.keys(processHandlers)) delete processHandlers[key];

    setupWebSocketMock.mockReset();
    startMuxSyncMock.mockReset();
    stopMuxSyncMock.mockReset();
    startUploadCleanupMock.mockReset();
    stopUploadCleanupMock.mockReset();

    consoleWarnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
    consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    processOnSpy = vi.spyOn(process, 'on').mockImplementation((event, handler) => {
        processHandlers[event] = handler;
        return process;
    });
    processExitSpy = vi.spyOn(process, 'exit').mockImplementation(() => undefined);
});

afterEach(() => {
    process.env = { ...originalEnv };
    vi.useRealTimers();
    vi.restoreAllMocks();
});

describe('index branch-heavy coverage', () => {
    it('covers request-id plumbing, auth branches, error handler branches, and health readiness branches', async () => {
        await importIndexModule();
        const fastify = fastifyState.instances[0];

        // request ID normalization branches
        expect(fastify.__opts.genReqId({ headers: { 'x-request-id': '  req-123  ' } })).toBe('req-123');
        expect(fastify.__opts.genReqId({ headers: { 'x-request-id': [' req-456 '] } })).toBe('req-456');
        expect(typeof fastify.__opts.genReqId({ headers: { 'x-request-id': '' } })).toBe('string');

        // child logger requestId fallback branch
        const childSpy = vi.fn(() => ({ childLogger: true }));
        const childLogger = fastify.__opts.childLoggerFactory({ child: childSpy }, { reqId: 'rid-1' });
        expect(childSpy).toHaveBeenCalledWith({ reqId: 'rid-1', requestId: 'rid-1' });
        expect(childLogger).toEqual({ childLogger: true });

        // onSend hook branch
        const onSend = fastify.__hooks.onSend;
        const reply = makeReply();
        const payload = { ok: true };
        const sentPayload = await onSend({ id: 'request-1' }, reply, payload);
        expect(reply.header).toHaveBeenCalledWith('X-Request-ID', 'request-1');
        expect(reply.header).toHaveBeenCalledWith('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
        expect(sentPayload).toBe(payload);

        // docs guard in non-production should allow without auth
        const docsGuard = getDocsGuard(fastify);
        const docsReply = makeReply();
        await docsGuard({ headers: {} }, docsReply);
        expect(docsReply.status).not.toHaveBeenCalled();

        // authenticate success branch
        const authRequest = {
            user: { id: 'admin-1' },
            jwtVerify: vi.fn().mockResolvedValue(undefined),
        };
        const authReply = makeReply();
        await fastify.authenticate(authRequest, authReply);
        expect(authRequest.user.status).toBe('ACTIVE');

        // authenticate: missing user branch
        prismaMock.user.findUnique.mockResolvedValueOnce(null);
        const missingUserReq = {
            user: { id: 'gone' },
            jwtVerify: vi.fn().mockResolvedValue(undefined),
        };
        const missingUserReply = makeReply();
        await fastify.authenticate(missingUserReq, missingUserReply);
        expect(missingUserReply.status).toHaveBeenCalledWith(401);

        // authenticate: suspended user branch
        prismaMock.user.findUnique.mockResolvedValueOnce({
            id: 'suspended',
            status: 'SUSPENDED',
            role: 'USER',
            companyCode: null,
            name: 'User',
            phoneNumber: '5055550000',
        });
        const suspendedReq = {
            user: { id: 'suspended' },
            jwtVerify: vi.fn().mockResolvedValue(undefined),
        };
        const suspendedReply = makeReply();
        await fastify.authenticate(suspendedReq, suspendedReply);
        expect(suspendedReply.status).toHaveBeenCalledWith(403);

        // authenticate: jwt verify throws branches
        const badTokenReq = {
            user: { id: 'bad' },
            jwtVerify: vi.fn().mockRejectedValue(new Error('bad token')),
        };
        const badTokenReply = makeReply();
        await fastify.authenticate(badTokenReq, badTokenReply);
        expect(badTokenReply.status).toHaveBeenCalledWith(401);

        const alreadySentReq = {
            user: { id: 'bad' },
            jwtVerify: vi.fn().mockRejectedValue(new Error('bad token')),
        };
        const alreadySentReply = makeReply();
        alreadySentReply.sent = true;
        await fastify.authenticate(alreadySentReq, alreadySentReply);
        expect(alreadySentReply.status).not.toHaveBeenCalled();

        // error handler branches
        const errorHandler = fastify.__errorHandler;

        const csrfReply = makeReply();
        await errorHandler({ code: 'FST_CSRF_INVALID_TOKEN' }, { method: 'POST', raw: { url: '/clips/login' } }, csrfReply);
        expect(csrfReply.status).toHaveBeenCalledWith(403);

        const validationReply = makeReply();
        await errorHandler({ validation: [{ field: 'name' }] }, { method: 'POST', raw: { url: '/api/admin/users' } }, validationReply);
        expect(validationReply.status).toHaveBeenCalledWith(422);
        expect(validationReply.payload).toEqual(expect.objectContaining({ error: 'Validation failed', details: expect.any(Array) }));

        const internalReply = makeReply();
        await errorHandler({ statusCode: 500, message: 'boom' }, { method: 'GET', raw: { url: '/api/health' } }, internalReply);
        expect(internalReply.status).toHaveBeenCalledWith(500);

        const badRequestReply = makeReply();
        await errorHandler({ statusCode: 400, message: 'bad input' }, { method: 'POST', raw: { url: '/api/assets' } }, badRequestReply);
        expect(badRequestReply.status).toHaveBeenCalledWith(400);
        expect(badRequestReply.payload).toEqual({ error: 'bad input' });

        const sentReply = makeReply();
        sentReply.sent = true;
        await errorHandler({ statusCode: 500, message: 'ignored' }, { method: 'GET', raw: { url: '/api/health' } }, sentReply);
        expect(sentReply.status).not.toHaveBeenCalled();

        // readiness route branches
        const readyHandler = getRouteHandler(fastify, 'GET', '/api/health/ready');

        process.env.MUX_TOKEN_ID = 'tid';
        process.env.MUX_TOKEN_SECRET = 'tsec';
        process.env.MUX_ENV_KEY = 'env';
        process.env.MUX_WEBHOOK_SECRET = 'web';

        const okReply = makeReply();
        prismaMock.$queryRaw.mockResolvedValueOnce([{ ok: 1 }]);
        const okResult = await readyHandler({}, okReply);
        expect(okResult.status).toBe('ok');

        prismaMock.$queryRaw.mockRejectedValueOnce(new Error('db down'));
        const dbFailReply = makeReply();
        const dbFailResult = await readyHandler({}, dbFailReply);
        expect(dbFailReply.status).toHaveBeenCalledWith(503);
        expect(dbFailResult.status).toBe('degraded');
        expect(dbFailResult.checks.database.status).toBe('error');

        delete process.env.MUX_TOKEN_ID;
        delete process.env.MUX_TOKEN_SECRET;
        delete process.env.MUX_ENV_KEY;
        delete process.env.MUX_WEBHOOK_SECRET;

        prismaMock.$queryRaw.mockResolvedValueOnce([{ ok: 1 }]);
        const muxFailReply = makeReply();
        const muxFailResult = await readyHandler({}, muxFailReply);
        expect(muxFailReply.status).toHaveBeenCalledWith(503);
        expect(muxFailResult.checks.mux.status).toBe('error');

        // metrics route branch defaults
        const metricsHandler = getRouteHandler(fastify, 'GET', '/api/metrics');
        prismaMock.$queryRaw.mockResolvedValueOnce([{}]);
        fastify.io.of.mockReturnValueOnce({ sockets: new Map([['a', {}], ['b', {}]]) });
        const metrics = await metricsHandler();
        expect(metrics.websocket.totalConnections).toBe(2);
        expect(metrics.database.users).toBe(0);
    });

    it('covers production docs-guard auth checks and production error response shape', async () => {
        process.env.NODE_ENV = 'production';
        process.env.JWT_SECRET = 'prod-secret';
        process.env.DATABASE_URL = 'postgresql://prod-db';
        process.env.MUX_TOKEN_ID = 'tid';
        process.env.MUX_TOKEN_SECRET = 'tsec';
        process.env.MUX_ENV_KEY = 'env';
        process.env.MUX_WEBHOOK_SECRET = 'web';

        await importIndexModule();
        const fastify = fastifyState.instances[0];

        const docsGuard = getDocsGuard(fastify);

        const noTokenReply = makeReply();
        await docsGuard({ headers: {} }, noTokenReply);
        expect(noTokenReply.status).toHaveBeenCalledWith(401);

        fastify.jwt.verify.mockImplementationOnce(() => {
            throw new Error('invalid token');
        });
        const badTokenReply = makeReply();
        await docsGuard({ headers: { authorization: 'Bearer bad-token' } }, badTokenReply);
        expect(badTokenReply.status).toHaveBeenCalledWith(401);

        fastify.jwt.verify.mockReturnValueOnce({ id: 'viewer-1' });
        prismaMock.user.findUnique.mockResolvedValueOnce({ role: 'USER', status: 'ACTIVE' });
        const nonAdminReply = makeReply();
        await docsGuard({ headers: { authorization: 'Bearer viewer' } }, nonAdminReply);
        expect(nonAdminReply.status).toHaveBeenCalledWith(403);

        fastify.jwt.verify.mockReturnValueOnce({ id: 'admin-1' });
        prismaMock.user.findUnique.mockResolvedValueOnce({ role: 'ADMIN', status: 'ACTIVE', companyCode: 'NEWS' });
        const adminReply = makeReply();
        await docsGuard({ headers: { authorization: 'Bearer ok-token' } }, adminReply);
        expect(adminReply.status).not.toHaveBeenCalled();

        const errorHandler = fastify.__errorHandler;
        const internalReply = makeReply();
        await errorHandler({ statusCode: 500, message: 'secret stack' }, { method: 'GET', raw: { url: '/api/admin/stats' } }, internalReply);
        expect(internalReply.payload).toEqual({ error: 'Internal Server Error' });

        const validationReply = makeReply();
        await errorHandler({ validation: [{ field: 'x' }] }, { method: 'POST', raw: { url: '/api/admin/users' } }, validationReply);
        expect(validationReply.payload).toEqual({ error: 'Validation failed' });
    });

    it('covers environment validation and shutdown/error signal handlers', async () => {
        process.env.NODE_ENV = 'production';
        delete process.env.DATABASE_URL;
        delete process.env.JWT_SECRET;
        delete process.env.MUX_TOKEN_ID;
        delete process.env.MUX_TOKEN_SECRET;
        delete process.env.MUX_ENV_KEY;
        delete process.env.MUX_WEBHOOK_SECRET;

        await importIndexModule();

        expect(processExitSpy).toHaveBeenCalledWith(1);
        expect(consoleErrorSpy).toHaveBeenCalledWith(expect.stringContaining('Missing required environment variables'));

        // Partial Mux config warning in non-production
        process.env.NODE_ENV = 'test';
        process.env.JWT_SECRET = 'test-secret';
        process.env.DATABASE_URL = 'postgresql://localhost:5432/directvideo';
        process.env.MUX_TOKEN_ID = 'tid';
        delete process.env.MUX_TOKEN_SECRET;
        delete process.env.MUX_ENV_KEY;
        delete process.env.MUX_WEBHOOK_SECRET;

        await importIndexModule();
        expect(consoleWarnSpy).toHaveBeenCalledWith(expect.stringContaining('Partial Mux configuration detected'));

        const fastify = fastifyState.instances.at(-1);
        const io = socketState.instances.at(-1);

        // Trigger shutdown catch path
        fastifyState.closeError = new Error('close failed');
        await processHandlers.SIGINT();
        expect(stopMuxSyncMock).toHaveBeenCalled();
        expect(stopUploadCleanupMock).toHaveBeenCalled();
        expect(io.close).toHaveBeenCalled();
        expect(consoleErrorSpy).toHaveBeenCalledWith('Shutdown error:', 'close failed');
        expect(processExitSpy).toHaveBeenCalledWith(0);

        // Process-level crash handlers
        processHandlers.unhandledRejection('reason-text');
        expect(consoleErrorSpy).toHaveBeenCalledWith('⚠️ Unhandled Rejection:', 'reason-text');

        vi.useFakeTimers();
        processHandlers.uncaughtException(new Error('fatal'));
        expect(consoleErrorSpy).toHaveBeenCalledWith('🔥 Uncaught Exception:', expect.any(Error));
        vi.runAllTimers();
        expect(processExitSpy).toHaveBeenCalledWith(1);
    });
});
