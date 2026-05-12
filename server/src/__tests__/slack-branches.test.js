// Last updated: May 12, 2026 - 4:39pm - GitHub Copilot (GPT-5.3-Codex)
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const webClientState = {
    instances: [],
    postMessage: vi.fn(),
    conversationsOpen: vi.fn(),
    usersList: vi.fn(),
};

const WebClientMock = vi.fn(class MockWebClient {
    constructor(token) {
        this.token = token;
        this.chat = {
            postMessage: webClientState.postMessage,
        };
        this.conversations = {
            open: webClientState.conversationsOpen,
        };
        this.users = {
            list: webClientState.usersList,
        };
        webClientState.instances.push(this);
    }
});

vi.mock('@slack/web-api', () => ({
    WebClient: WebClientMock,
}));

vi.mock('../lib/config.js', () => ({
    PUBLIC_URL: 'https://ms-fixer.test',
}));

const originalSlackToken = process.env.SLACK_BOT_TOKEN;

async function loadSlackModule(token) {
    if (token === undefined) delete process.env.SLACK_BOT_TOKEN;
    else process.env.SLACK_BOT_TOKEN = token;

    vi.resetModules();
    return import('../lib/slack.js');
}

beforeEach(() => {
    webClientState.instances = [];
    webClientState.postMessage.mockReset();
    webClientState.conversationsOpen.mockReset();
    webClientState.usersList.mockReset();

    vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(() => {
    if (originalSlackToken === undefined) delete process.env.SLACK_BOT_TOKEN;
    else process.env.SLACK_BOT_TOKEN = originalSlackToken;

    vi.restoreAllMocks();
    vi.resetModules();
});

describe('slack lib branch coverage', () => {
    it('configures WebClient and posts to channel successfully', async () => {
        webClientState.postMessage.mockResolvedValueOnce({ ok: true, ts: '171234.12' });
        const mod = await loadSlackModule('xoxb-123');

        expect(mod.isConfigured()).toBe(true);
        expect(WebClientMock).toHaveBeenCalledWith('xoxb-123');

        const result = await mod.postToChannel('team-alerts', 'hello world', [{ type: 'section' }], { requestId: 'rq-1' });

        expect(webClientState.postMessage).toHaveBeenCalledWith({
            channel: '#team-alerts',
            text: 'hello world',
            blocks: [{ type: 'section' }],
            unfurl_links: true,
        });
        expect(result).toEqual({ ok: true, ts: '171234.12' });
    });

    it('returns API error from postToChannel catch branch', async () => {
        webClientState.postMessage.mockRejectedValueOnce({
            data: { error: 'channel_not_found' },
            message: 'request failed',
        });

        const mod = await loadSlackModule('xoxb-123');
        const result = await mod.postToChannel('missing', 'msg', null, { requestId: 'rq-2' });

        expect(result).toEqual({ ok: false, error: 'channel_not_found' });
        expect(console.error).toHaveBeenCalledWith(expect.objectContaining({
            event: 'slack.postToChannel.error',
            channelName: 'missing',
            requestId: 'rq-2',
            error: 'channel_not_found',
        }));
    });

    it('returns not found when DM user cannot be resolved', async () => {
        webClientState.usersList.mockResolvedValueOnce({
            members: [],
            response_metadata: { next_cursor: '' },
        });

        const mod = await loadSlackModule('xoxb-123');
        const result = await mod.postDM('nobody', 'ping', null, { requestId: 'rq-3' });

        expect(result).toEqual({ ok: false, error: 'User "nobody" not found in Slack workspace' });
        expect(webClientState.conversationsOpen).not.toHaveBeenCalled();
    });

    it('handles DM conversation open failure branch', async () => {
        webClientState.usersList.mockResolvedValueOnce({
            members: [
                {
                    id: 'U1',
                    deleted: false,
                    is_bot: false,
                    profile: { display_name: 'carrie', real_name: 'Carrie Smith' },
                    name: 'carrie.smith',
                },
            ],
            response_metadata: { next_cursor: '' },
        });
        webClientState.conversationsOpen.mockResolvedValueOnce({ ok: false });

        const mod = await loadSlackModule('xoxb-123');
        const result = await mod.postDM('carrie', 'ping');

        expect(result).toEqual({ ok: false, error: 'Could not open DM conversation' });
    });

    it('posts DM successfully and reuses user-id cache on repeated calls', async () => {
        webClientState.usersList.mockResolvedValueOnce({
            members: [
                {
                    id: 'U2',
                    deleted: false,
                    is_bot: false,
                    profile: { display_name: 'carrie', real_name: 'Carrie Smith' },
                    name: 'carrie.smith',
                },
            ],
            response_metadata: { next_cursor: '' },
        });
        webClientState.conversationsOpen.mockResolvedValue({ ok: true, channel: { id: 'D2' } });
        webClientState.postMessage.mockResolvedValue({ ok: true, ts: '123.45' });

        const mod = await loadSlackModule('xoxb-123');

        const first = await mod.postDM('carrie', 'first');
        const second = await mod.postDM('carrie', 'second');

        expect(first).toEqual({ ok: true, ts: '123.45' });
        expect(second).toEqual({ ok: true, ts: '123.45' });
        expect(webClientState.usersList).toHaveBeenCalledTimes(1);
        expect(webClientState.conversationsOpen).toHaveBeenCalledTimes(2);
        expect(webClientState.postMessage).toHaveBeenCalledWith({
            channel: 'D2',
            text: 'second',
            blocks: undefined,
            unfurl_links: true,
        });
    });

    it('walks paginated users list and skips deleted/bot accounts', async () => {
        webClientState.usersList
            .mockResolvedValueOnce({
                members: [
                    { id: 'Ubot', deleted: false, is_bot: true, profile: { display_name: 'bot' }, name: 'bot' },
                    { id: 'Udel', deleted: true, is_bot: false, profile: { display_name: 'old' }, name: 'old' },
                ],
                response_metadata: { next_cursor: 'cursor-2' },
            })
            .mockResolvedValueOnce({
                members: [
                    {
                        id: 'Utarget',
                        deleted: false,
                        is_bot: false,
                        profile: { display_name: 'target.user', real_name: 'Target User' },
                        name: 'target',
                    },
                ],
                response_metadata: { next_cursor: '' },
            });
        webClientState.conversationsOpen.mockResolvedValueOnce({ ok: true, channel: { id: 'Dtarget' } });
        webClientState.postMessage.mockResolvedValueOnce({ ok: true, ts: '222.1' });

        const mod = await loadSlackModule('xoxb-123');
        const result = await mod.postDM('target.user', 'hello');

        expect(result).toEqual({ ok: true, ts: '222.1' });
        expect(webClientState.usersList).toHaveBeenCalledTimes(2);
    });

    it('returns DM error when postMessage throws with API error payload', async () => {
        webClientState.usersList.mockResolvedValueOnce({
            members: [
                {
                    id: 'U3',
                    deleted: false,
                    is_bot: false,
                    profile: { display_name: 'editor' },
                    name: 'editor',
                },
            ],
            response_metadata: { next_cursor: '' },
        });
        webClientState.conversationsOpen.mockResolvedValueOnce({ ok: true, channel: { id: 'D3' } });
        webClientState.postMessage.mockRejectedValueOnce({
            data: { error: 'cannot_dm' },
            message: 'cannot dm',
        });

        const mod = await loadSlackModule('xoxb-123');
        const result = await mod.postDM('editor', 'hello', null, { requestId: 'rq-4' });

        expect(result).toEqual({ ok: false, error: 'cannot_dm' });
        expect(console.error).toHaveBeenCalledWith(expect.objectContaining({
            event: 'slack.postDM.error',
            displayName: 'editor',
            requestId: 'rq-4',
            error: 'cannot_dm',
        }));
    });

    it('returns user-not-found when resolveUserId throws internally', async () => {
        webClientState.usersList.mockRejectedValueOnce(new Error('slack users.list timeout'));

        const mod = await loadSlackModule('xoxb-123');
        const result = await mod.postDM('missing', 'hello');

        expect(result).toEqual({ ok: false, error: 'User "missing" not found in Slack workspace' });
        expect(console.error).toHaveBeenCalledWith(expect.objectContaining({
            event: 'slack.resolveUserId.error',
            displayName: 'missing',
            message: 'slack users.list timeout',
        }));
    });
});
