// Last updated: May 12, 2026 - 4:28pm - GitHub Copilot (GPT-5.3-Codex)
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const poolState = {
    constructorCalls: [],
    instances: [],
    handlers: {},
    connectImpl: async () => ({
        query: vi.fn().mockResolvedValue([{ ok: 1 }]),
        release: vi.fn(),
        on: vi.fn(),
    }),
};

const prismaState = {
    adapterArgs: [],
    clientArgs: [],
};

class MockPool {
    constructor(options) {
        poolState.constructorCalls.push(options);
        this.options = options;
        this.handlers = {};
        poolState.instances.push(this);
    }

    on(event, handler) {
        this.handlers[event] = handler;
        poolState.handlers[event] = handler;
    }

    connect() {
        return poolState.connectImpl();
    }
}

class MockPrismaPg {
    constructor(pool) {
        prismaState.adapterArgs.push(pool);
        this.pool = pool;
    }
}

class MockPrismaClient {
    constructor(opts) {
        prismaState.clientArgs.push(opts);
        this.__opts = opts;
    }
}

vi.mock('pg', () => ({
    default: {
        Pool: MockPool,
    },
}));

vi.mock('@prisma/adapter-pg', () => ({
    PrismaPg: MockPrismaPg,
}));

vi.mock('@prisma/client', () => ({
    PrismaClient: MockPrismaClient,
}));

const originalEnv = { ...process.env };

async function importPrismaModule(env = {}) {
    process.env = { ...originalEnv };
    process.env.DATABASE_URL = env.databaseUrl || 'postgresql://local/testdb';
    process.env.NODE_ENV = env.nodeEnv || 'test';

    vi.resetModules();
    return import('../lib/prisma.js');
}

beforeEach(() => {
    poolState.constructorCalls = [];
    poolState.instances = [];
    poolState.handlers = {};
    prismaState.adapterArgs = [];
    prismaState.clientArgs = [];

    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});

    poolState.connectImpl = async () => ({
        query: vi.fn().mockResolvedValue([{ ok: 1 }]),
        release: vi.fn(),
        on: vi.fn(),
    });
});

afterEach(() => {
    process.env = { ...originalEnv };
    vi.restoreAllMocks();
});

describe('prisma lib coverage', () => {
    it('creates pool + adapter/client and warms up successfully in non-production', async () => {
        const warmClient = {
            query: vi.fn().mockResolvedValue([{ ok: 1 }]),
            release: vi.fn(),
            on: vi.fn(),
        };
        poolState.connectImpl = async () => warmClient;

        const module = await importPrismaModule({
            nodeEnv: 'test',
            databaseUrl: 'postgresql://localhost:5432/directvideo',
        });

        const pool = poolState.instances[0];
        expect(poolState.constructorCalls[0]).toEqual(expect.objectContaining({
            connectionString: 'postgresql://localhost:5432/directvideo',
            max: 20,
            idleTimeoutMillis: 10000,
            connectionTimeoutMillis: 15000,
            allowExitOnIdle: true,
        }));
        expect(pool.options.ssl).toBeUndefined();

        expect(warmClient.query).toHaveBeenCalledWith('SELECT 1');
        expect(warmClient.release).toHaveBeenCalledTimes(1);

        expect(prismaState.adapterArgs[0]).toBe(pool);
        expect(prismaState.clientArgs[0]).toEqual({
            adapter: expect.objectContaining({ pool }),
        });
        expect(module.default).toEqual({ __opts: { adapter: { pool } } });

        const fakePgClient = { on: vi.fn() };
        poolState.handlers.connect(fakePgClient);
        expect(fakePgClient.on).toHaveBeenCalledWith('error', expect.any(Function));

        const pgClientErrorHandler = fakePgClient.on.mock.calls[0][1];
        pgClientErrorHandler(new Error('client dropped'));
        expect(console.error).toHaveBeenCalledWith(expect.objectContaining({
            event: 'db.pgClient.error',
            message: 'client dropped',
        }));

        poolState.handlers.error(new Error('pool down'));
        expect(console.error).toHaveBeenCalledWith(expect.objectContaining({
            event: 'db.pool.error',
            message: 'pool down',
        }));
    });

    it('uses production pool settings and logs warmup failure without crashing', async () => {
        poolState.connectImpl = async () => {
            throw new Error('warmup failed');
        };

        const module = await importPrismaModule({
            nodeEnv: 'production',
            databaseUrl: 'postgresql://prod/render-db',
        });

        expect(poolState.constructorCalls[0]).toEqual(expect.objectContaining({
            connectionString: 'postgresql://prod/render-db',
            max: 20,
            idleTimeoutMillis: 30000,
            connectionTimeoutMillis: 15000,
            allowExitOnIdle: true,
            ssl: { rejectUnauthorized: false },
        }));

        expect(console.error).toHaveBeenCalledWith(expect.objectContaining({
            event: 'db.pool.warmup.failed',
            message: 'warmup failed',
        }));
        expect(prismaState.adapterArgs).toHaveLength(1);
        expect(prismaState.clientArgs).toHaveLength(1);
        expect(module.default).toEqual(expect.objectContaining({ __opts: expect.any(Object) }));
    });
});
