// Last updated: May 9, 2026 - 7:30pm - GPT-5.3-Codex
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = {
    chatMessage: {
        create: vi.fn(),
    },
    asset: {
        findFirst: vi.fn(),
    },
};

const slackMock = {
    isConfigured: vi.fn(),
    buildAssetMessage: vi.fn(),
    postToChannel: vi.fn(),
    postDM: vi.fn(),
};

vi.mock('../lib/prisma.js', () => ({
    default: prismaMock,
}));

vi.mock('../lib/slack.js', () => ({
    isConfigured: slackMock.isConfigured,
    buildAssetMessage: slackMock.buildAssetMessage,
    postToChannel: slackMock.postToChannel,
    postDM: slackMock.postDM,
}));

vi.mock('../lib/config.js', () => ({
    PUBLIC_URL: 'https://ms-fixer.test',
}));

let setupWebSocket;

beforeAll(async () => {
    ({ setupWebSocket } = await import('../ws/handler.js'));
});

beforeEach(() => {
    vi.clearAllMocks();

    prismaMock.chatMessage.create.mockResolvedValue({});
    prismaMock.asset.findFirst.mockResolvedValue({
        mediasourceId: '100000001',
        formResponse: { slug: 'breaking-news' },
        clips: [{ muxPlaybackId: 'play-1', capturedAt: new Date('2026-05-09T00:00:00.000Z') }],
    });

    slackMock.isConfigured.mockReturnValue(false);
    slackMock.buildAssetMessage.mockReturnValue({
        text: 'message-text',
        blocks: [],
    });
    slackMock.postToChannel.mockResolvedValue({ ok: true, channel: '#news' });
    slackMock.postDM.mockResolvedValue({ ok: true, user: '@carrie' });
});

afterEach(() => {
    vi.useRealTimers();
});

function createIoHarness() {
    const harness = {
        authMiddleware: null,
        connectionHandler: null,
        engineErrorHandler: null,
    };

    const ioEmitSpy = vi.fn();

    const io = {
        engine: {
            on: vi.fn((event, cb) => {
                if (event === 'connection_error') {
                    harness.engineErrorHandler = cb;
                }
            }),
        },
        use: vi.fn((cb) => {
            harness.authMiddleware = cb;
        }),
        on: vi.fn((event, cb) => {
            if (event === 'connection') {
                harness.connectionHandler = cb;
            }
        }),
        to: vi.fn(() => ({ emit: ioEmitSpy })),
    };

    return { io, ioEmitSpy, harness };
}

function createFastifyHarness() {
    const fastify = {
        jwt: {
            verify: vi.fn(),
        },
        log: {
            info: vi.fn(),
            warn: vi.fn(),
            error: vi.fn(),
            debug: vi.fn(),
        },
        decorate(name, value) {
            this[name] = value;
        },
    };

    return fastify;
}

function createSocket({ token = 'valid-token', clientType = 'ios' } = {}) {
    const handlers = {};

    const socket = {
        id: 'socket-1',
        handshake: {
            auth: {
                token,
                clientType,
                deviceName: 'Rod iPhone',
                deviceModel: 'iPhone 17 Pro',
            },
            headers: {},
        },
        on: vi.fn((event, cb) => {
            handlers[event] = cb;
        }),
        emit: vi.fn(),
        handlers,
    };

    return socket;
}

describe('ws handler targeted coverage', () => {
    it('rejects socket connections without auth token', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();

        setupWebSocket(io, fastify);

        const socket = createSocket({ token: undefined });
        socket.handshake.auth = {};

        const next = vi.fn();
        await harness.authMiddleware(socket, next);

        expect(next).toHaveBeenCalledTimes(1);
        expect(next.mock.calls[0][0]).toBeInstanceOf(Error);
        expect(next.mock.calls[0][0].message).toBe('Authentication required');
    });

    it('authenticates and registers iOS socket event handlers', async () => {
        vi.useFakeTimers();

        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({
            id: 'user-1',
            name: 'David Burgess',
            phoneNumber: '5055551000',
        });

        setupWebSocket(io, fastify);

        const socket = createSocket({ token: 'valid-token', clientType: 'ios' });
        const next = vi.fn();

        await harness.authMiddleware(socket, next);
        expect(next).toHaveBeenCalledWith();

        harness.connectionHandler(socket);

        expect(socket.on).toHaveBeenCalledWith('video:upload', expect.any(Function));
        expect(socket.on).toHaveBeenCalledWith('message:send', expect.any(Function));
        expect(socket.on).toHaveBeenCalledWith('disconnect', expect.any(Function));

        expect(socket.emit).toHaveBeenCalledWith(
            'message:new',
            expect.objectContaining({
                messageType: 'GREETING',
            })
        );

        await vi.advanceTimersByTimeAsync(500);
        expect(socket.emit).toHaveBeenCalledWith(
            'message:new',
            expect.objectContaining({
                messageType: 'SYSTEM_NOTE',
            })
        );
    });

    it('emits upload progress when video upload starts', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({
            id: 'user-1',
            name: 'David Burgess',
            phoneNumber: '5055551000',
        });

        setupWebSocket(io, fastify);

        const socket = createSocket({ token: 'valid-token', clientType: 'ios' });
        await harness.authMiddleware(socket, vi.fn());
        harness.connectionHandler(socket);

        await socket.handlers['video:upload']({ assetId: 'asset-1' });

        expect(socket.emit).toHaveBeenCalledWith('upload:progress', {
            assetId: 'asset-1',
            percent: 0,
            status: 'uploading',
        });
    });

    it('handles slack command when slack is not configured', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({
            id: 'user-1',
            name: 'David Burgess',
            phoneNumber: '5055551000',
        });

        setupWebSocket(io, fastify);

        const socket = createSocket({ token: 'valid-token', clientType: 'ios' });
        await harness.authMiddleware(socket, vi.fn());
        harness.connectionHandler(socket);

        await socket.handlers['message:send']({
            text: '#team-alerts @carrie clip is ready',
            assetId: 'asset-1',
        });

        expect(prismaMock.chatMessage.create).toHaveBeenCalledWith({
            data: expect.objectContaining({
                userId: 'user-1',
                messageType: 'SLACK_POST',
            }),
        });
        expect(socket.emit).toHaveBeenCalledWith(
            'message:new',
            expect.objectContaining({
                messageType: 'SLACK_POST',
                content: expect.objectContaining({
                    text: expect.stringContaining('Slack is not configured'),
                }),
            })
        );
    });

    it('stores text messages and sends debounced auto-reply', async () => {
        vi.useFakeTimers();

        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({
            id: 'user-1',
            name: 'David Burgess',
            phoneNumber: '5055551000',
        });

        setupWebSocket(io, fastify);

        const socket = createSocket({ token: 'valid-token', clientType: 'ios' });
        await harness.authMiddleware(socket, vi.fn());
        harness.connectionHandler(socket);

        await socket.handlers['message:send']({ text: 'hello fixer', assetId: 'asset-1' });

        expect(prismaMock.chatMessage.create).toHaveBeenCalledWith({
            data: expect.objectContaining({
                userId: 'user-1',
                assetId: 'asset-1',
                direction: 'OUTGOING',
                messageType: 'TEXT',
            }),
        });

        await vi.advanceTimersByTimeAsync(5000);

        expect(socket.emit).toHaveBeenCalledWith(
            'message:new',
            expect.objectContaining({
                messageType: 'TEXT',
                direction: 'INCOMING',
                content: expect.objectContaining({
                    text: expect.stringContaining('send me your videos'),
                }),
            })
        );
    });

    it('cleans up socket tracking on disconnect', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({
            id: 'user-1',
            name: 'David Burgess',
            phoneNumber: '5055551000',
        });

        setupWebSocket(io, fastify);

        const socket = createSocket({ token: 'valid-token', clientType: 'ios' });
        await harness.authMiddleware(socket, vi.fn());
        harness.connectionHandler(socket);

        expect(fastify.userSockets.has('user-1')).toBe(true);

        socket.handlers.disconnect();

        expect(fastify.userSockets.has('user-1')).toBe(false);
    });
});
