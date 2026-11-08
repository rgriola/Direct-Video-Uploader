// Last updated: May 10, 2026 - 10:37am - GitHub Copilot (GPT-5.3-Codex)
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = {
    user: {
        findUnique: vi.fn(),
    },
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

    prismaMock.user.findUnique.mockResolvedValue({
        id: 'user-1',
        name: 'David Burgess',
        phoneNumber: '5055551000',
        role: 'USER',
        status: 'ACTIVE',
        companyCode: 'NEWS',
    });
    prismaMock.chatMessage.create.mockResolvedValue({});
    prismaMock.asset.findFirst.mockResolvedValue({
        id: 'asset-1',
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
        data: {},
        conn: { close: vi.fn() },
        join: vi.fn(),
        disconnect: vi.fn(),
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
        await new Promise(resolve => process.nextTick(resolve));

        expect(next).toHaveBeenCalledTimes(1);
        expect(next.mock.calls[0][0]).toBeInstanceOf(Error);
        expect(next.mock.calls[0][0].message).toBe('Authentication required');
        expect(socket.conn.close).toHaveBeenCalled();
    });

    it('uses the database identity and role rather than token claims', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({ id: 'user-1', role: 'SUPER_ADMIN', name: 'Old name' });
        prismaMock.user.findUnique.mockResolvedValueOnce({
            id: 'user-1', name: 'Current name', phoneNumber: '5055551000',
            role: 'ADMIN', status: 'ACTIVE', companyCode: 'NEWS',
        });
        setupWebSocket(io, fastify);

        const socket = createSocket({ clientType: 'admin' });
        const next = vi.fn();
        await harness.authMiddleware(socket, next);
        harness.connectionHandler(socket);

        expect(next).toHaveBeenCalledWith();
        expect(socket.userName).toBe('Current name');
        expect(socket.join).toHaveBeenCalledWith('user:user-1');
        expect(socket.join).toHaveBeenCalledWith('team:NEWS');
        expect(socket.join).not.toHaveBeenCalledWith('super');
    });

    it.each([
        ['missing', null],
        ['suspended', { id: 'user-1', role: 'USER', status: 'SUSPENDED' }],
        ['unknown role', { id: 'user-1', role: 'OTHER', status: 'ACTIVE' }],
    ])('rejects a %s account and closes its transport', async (_label, user) => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({ id: 'user-1' });
        prismaMock.user.findUnique.mockResolvedValueOnce(user);
        setupWebSocket(io, fastify);

        const socket = createSocket();
        const next = vi.fn();
        await harness.authMiddleware(socket, next);
        await new Promise(resolve => process.nextTick(resolve));

        expect(next.mock.calls[0][0].message).toBe('Account unavailable');
        expect(socket.conn.close).toHaveBeenCalled();
        expect(socket.join).not.toHaveBeenCalled();
    });

    it('reports database authentication failures separately from invalid tokens', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({ id: 'user-1' });
        prismaMock.user.findUnique.mockRejectedValueOnce(new Error('database offline'));
        setupWebSocket(io, fastify);

        const socket = createSocket();
        const next = vi.fn();
        await harness.authMiddleware(socket, next);

        expect(next.mock.calls[0][0].message).toBe('Authentication unavailable');
        expect(fastify.log.error).toHaveBeenCalledWith(
            expect.objectContaining({ err: { message: 'database offline' } }),
            'WS auth could not load user'
        );
    });

    it('reloads a user when authorization changes during the handshake', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({ id: 'user-1' });
        let resolveFirst;
        prismaMock.user.findUnique
            .mockImplementationOnce(() => new Promise(resolve => { resolveFirst = resolve; }))
            .mockResolvedValueOnce({
                id: 'user-1', name: 'Current name', role: 'ADMIN', status: 'ACTIVE', companyCode: 'SPRT',
            });
        setupWebSocket(io, fastify);

        const socket = createSocket({ clientType: 'admin' });
        const auth = harness.authMiddleware(socket, vi.fn());
        fastify.socketAuthState.revision += 1;
        resolveFirst({ id: 'user-1', role: 'ADMIN', status: 'ACTIVE', companyCode: 'NEWS' });
        await auth;
        harness.connectionHandler(socket);

        expect(prismaMock.user.findUnique).toHaveBeenCalledTimes(2);
        expect(socket.join).toHaveBeenCalledWith('team:SPRT');
        expect(socket.join).not.toHaveBeenCalledWith('team:NEWS');
    });

    it('disconnects when authorization changes after the handshake', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({ id: 'user-1' });
        setupWebSocket(io, fastify);

        const socket = createSocket({ clientType: 'admin' });
        await harness.authMiddleware(socket, vi.fn());
        fastify.socketAuthState.revision += 1;
        harness.connectionHandler(socket);

        expect(socket.disconnect).toHaveBeenCalledWith(true);
        expect(socket.join).not.toHaveBeenCalled();
    });

    it('disconnects an established socket when its JWT expires', async () => {
        vi.useFakeTimers();
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        const exp = Math.floor(Date.now() / 1000) + 2;
        fastify.jwt.verify.mockReturnValue({ id: 'user-1', exp });
        setupWebSocket(io, fastify);

        const socket = createSocket({ clientType: 'admin' });
        await harness.authMiddleware(socket, vi.fn());
        harness.connectionHandler(socket);
        await vi.advanceTimersByTimeAsync(2100);

        expect(socket.disconnect).toHaveBeenCalledWith(true);
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
                content: expect.objectContaining({
                    code: 'WS_GREETING_CONNECTED',
                }),
            })
        );

        await vi.advanceTimersByTimeAsync(500);
        expect(socket.emit).toHaveBeenCalledWith(
            'message:new',
            expect.objectContaining({
                messageType: 'SYSTEM_NOTE',
                content: expect.objectContaining({
                    code: 'WS_SYSTEM_TIP_GUIDE',
                }),
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
                    code: 'WS_SLACK_NOT_CONFIGURED',
                    text: expect.stringContaining('Slack is not configured'),
                }),
            })
        );
    });

    it('emits coded slack confirmation when channel post succeeds', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({
            id: 'user-1',
            name: 'David Burgess',
            phoneNumber: '5055551000',
        });
        slackMock.isConfigured.mockReturnValue(true);
        slackMock.postToChannel.mockResolvedValue({ ok: true, channel: '#team-alerts' });

        setupWebSocket(io, fastify);

        const socket = createSocket({ token: 'valid-token', clientType: 'ios' });
        await harness.authMiddleware(socket, vi.fn());
        harness.connectionHandler(socket);

        await socket.handlers['message:send']({
            text: '#team-alerts clip ready',
        });

        expect(socket.emit).toHaveBeenCalledWith(
            'message:new',
            expect.objectContaining({
                messageType: 'SLACK_POST',
                content: expect.objectContaining({
                    code: 'WS_SLACK_CONFIRMATION_OK',
                    params: expect.objectContaining({
                        targets: '#team-alerts',
                    }),
                }),
            })
        );
    });

    it('emits requires-upload code when slack command has no ready asset', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({
            id: 'user-1',
            name: 'David Burgess',
            phoneNumber: '5055551000',
        });
        slackMock.isConfigured.mockReturnValue(true);
        prismaMock.asset.findFirst.mockResolvedValue(null);

        setupWebSocket(io, fastify);

        const socket = createSocket({ token: 'valid-token', clientType: 'ios' });
        await harness.authMiddleware(socket, vi.fn());
        harness.connectionHandler(socket);

        await socket.handlers['message:send']({
            text: '#team-alerts clip ready',
        });

        expect(socket.emit).toHaveBeenCalledWith(
            'message:new',
            expect.objectContaining({
                messageType: 'TEXT',
                content: expect.objectContaining({
                    code: 'WS_SLACK_REQUIRES_UPLOAD',
                }),
            })
        );
    });

    it('emits failure confirmation code when slack post fails', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({
            id: 'user-1',
            name: 'David Burgess',
            phoneNumber: '5055551000',
        });
        slackMock.isConfigured.mockReturnValue(true);
        slackMock.postToChannel.mockResolvedValue({ ok: false, error: 'channel_not_found' });

        setupWebSocket(io, fastify);

        const socket = createSocket({ token: 'valid-token', clientType: 'ios' });
        await harness.authMiddleware(socket, vi.fn());
        harness.connectionHandler(socket);

        await socket.handlers['message:send']({
            text: '#does-not-exist clip ready',
        });

        expect(socket.emit).toHaveBeenCalledWith(
            'message:new',
            expect.objectContaining({
                messageType: 'SLACK_POST',
                content: expect.objectContaining({
                    code: 'WS_SLACK_CONFIRMATION_FAILED',
                    params: expect.objectContaining({
                        failedTargets: expect.stringContaining('#does-not-exist'),
                    }),
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
                    code: 'WS_TEXT_AUTO_REPLY_SEND_VIDEO',
                    text: expect.stringContaining('Send me your videos'),
                }),
            })
        );
    });

    it('rejects messages for another user or a moderated asset before persisting', async () => {
        const { io, harness } = createIoHarness();
        const fastify = createFastifyHarness();
        fastify.jwt.verify.mockReturnValue({ id: 'user-1' });
        prismaMock.asset.findFirst.mockResolvedValueOnce(null);
        setupWebSocket(io, fastify);

        const socket = createSocket();
        await harness.authMiddleware(socket, vi.fn());
        harness.connectionHandler(socket);
        socket.emit.mockClear();

        await socket.handlers['message:send']({ text: '#news share this', assetId: 'other-asset' });

        expect(prismaMock.asset.findFirst).toHaveBeenCalledWith({
            where: { id: 'other-asset', userId: 'user-1', moderation: 'ACTIVE' },
            select: { id: true },
        });
        expect(prismaMock.chatMessage.create).not.toHaveBeenCalled();
        expect(slackMock.postToChannel).not.toHaveBeenCalled();
        expect(socket.emit).toHaveBeenCalledWith('message:new', expect.objectContaining({
            messageType: 'SYSTEM_NOTE',
            content: expect.objectContaining({ code: 'WS_ASSET_UNAVAILABLE' }),
        }));
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
