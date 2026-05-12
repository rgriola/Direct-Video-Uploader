// Last updated: May 12, 2026 - 4:28pm - GitHub Copilot (GPT-5.3-Codex)
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const fastifyState = {
    instances: [],
    listenError: null,
};

const socketState = {
    instances: [],
};

const processHandlers = {};

const setupWebSocketMock = vi.fn();
const startMuxSyncMock = vi.fn();
const stopMuxSyncMock = vi.fn();
const startUploadCleanupMock = vi.fn();
const stopUploadCleanupMock = vi.fn();

const fastifyCtorMock = vi.fn((opts) => {
    const instance = {
        __opts: opts,
        server: {},
        register: vi.fn(async () => {}),
        decorate: vi.fn(function (name, value) {
            this[name] = value;
            return this;
        }),
        addHook: vi.fn(),
        setErrorHandler: vi.fn(),
        get: vi.fn(),
        listen: vi.fn(async () => {
            if (fastifyState.listenError) throw fastifyState.listenError;
        }),
        close: vi.fn(async () => {}),
        log: {
            info: vi.fn(),
            warn: vi.fn(),
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
vi.mock('../routes/auth-sso.js', () => ({ default: vi.fn(async () => {}) }));
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
    default: {
        user: {
            findUnique: vi.fn().mockResolvedValue({
                id: 'admin-1',
                status: 'ACTIVE',
                role: 'ADMIN',
            }),
        },
        $queryRaw: vi.fn().mockResolvedValue([{ ok: 1 }]),
    },
}));

const originalEnv = { ...process.env };
let consoleLogSpy;
let consoleWarnSpy;
let consoleErrorSpy;
let processOnSpy;
let processExitSpy;

async function importIndexModule() {
    vi.resetModules();
    await import('../index.js');
    await new Promise((resolve) => setImmediate(resolve));
}

beforeEach(() => {
    process.env = { ...originalEnv };
    process.env.NODE_ENV = 'test';
    process.env.PORT = '4455';
    process.env.HOST = '127.0.0.1';

    delete process.env.MUX_TOKEN_ID;
    delete process.env.MUX_TOKEN_SECRET;
    delete process.env.MUX_ENV_KEY;
    delete process.env.MUX_WEBHOOK_SECRET;

    fastifyState.instances = [];
    fastifyState.listenError = null;
    socketState.instances = [];
    for (const key of Object.keys(processHandlers)) delete processHandlers[key];

    setupWebSocketMock.mockReset();
    startMuxSyncMock.mockReset();
    stopMuxSyncMock.mockReset();
    startUploadCleanupMock.mockReset();
    stopUploadCleanupMock.mockReset();

    consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
    consoleWarnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    processOnSpy = vi.spyOn(process, 'on').mockImplementation((event, handler) => {
        processHandlers[event] = handler;
        return process;
    });
    processExitSpy = vi.spyOn(process, 'exit').mockImplementation(() => undefined);
});

afterEach(() => {
    process.env = { ...originalEnv };
    vi.restoreAllMocks();
});

describe('server index bootstrap coverage', () => {
    it('boots server, wires websocket + jobs, and handles SIGTERM shutdown', async () => {
        await importIndexModule();

        const fastify = fastifyState.instances[0];
        const io = socketState.instances[0];

        expect(fastifyCtorMock).toHaveBeenCalledTimes(1);
        expect(fastify.listen).toHaveBeenCalledWith({ port: 4455, host: '127.0.0.1' });
        expect(setupWebSocketMock).toHaveBeenCalledWith(io, fastify);
        expect(startMuxSyncMock).toHaveBeenCalledWith(fastify);
        expect(startUploadCleanupMock).toHaveBeenCalledWith(fastify);

        expect(processOnSpy).toHaveBeenCalledWith('SIGTERM', expect.any(Function));
        expect(processOnSpy).toHaveBeenCalledWith('SIGINT', expect.any(Function));

        await processHandlers.SIGTERM();

        expect(stopMuxSyncMock).toHaveBeenCalledTimes(1);
        expect(stopUploadCleanupMock).toHaveBeenCalledTimes(1);
        expect(io.close).toHaveBeenCalledTimes(1);
        expect(fastify.close).toHaveBeenCalledTimes(1);
        expect(processExitSpy).toHaveBeenCalledWith(0);
    });

    it('logs startup failure and exits with code 1 when listen fails', async () => {
        fastifyState.listenError = new Error('listen failed');

        await importIndexModule();

        const fastify = fastifyState.instances[0];
        expect(fastify.log.error).toHaveBeenCalledWith(expect.objectContaining({
            event: 'server.start.error',
            err: expect.any(Error),
        }), 'Server startup failed');
        expect(processExitSpy).toHaveBeenCalledWith(1);
    });
});
