// Last updated: May 10, 2026 - 6:46pm - GitHub Copilot (GPT-5.3-Codex)
import { afterEach, describe, expect, it, vi } from 'vitest';

const originalSlackToken = process.env.SLACK_BOT_TOKEN;

async function loadSlackModule(token) {
    if (token === undefined) delete process.env.SLACK_BOT_TOKEN;
    else process.env.SLACK_BOT_TOKEN = token;

    vi.resetModules();
    return import('../lib/slack.js');
}

afterEach(() => {
    if (originalSlackToken === undefined) delete process.env.SLACK_BOT_TOKEN;
    else process.env.SLACK_BOT_TOKEN = originalSlackToken;
    vi.resetModules();
});

describe('lib/slack', () => {
    it('reports not configured when token is absent', async () => {
        const mod = await loadSlackModule(undefined);

        expect(mod.isConfigured()).toBe(false);
        await expect(mod.postToChannel('general', 'hello')).resolves.toEqual({
            ok: false,
            error: 'Slack not configured',
        });
        await expect(mod.postDM('carrie', 'hello')).resolves.toEqual({
            ok: false,
            error: 'Slack not configured',
        });
    });

    it('builds asset message with escaped user content and mention context', async () => {
        const mod = await loadSlackModule(undefined);

        const message = mod.buildAssetMessage({
            userName: '<alice&bob>',
            mediasourceId: '<MS&1>',
            clipUrl: 'https://clips.example.com/abc',
            mention: '@team <all>',
            slug: 'storm <watch> & report',
            capturedAt: '2026-05-09T18:00:00.000Z',
            thumbnailUrl: null,
        });

        expect(message.text).toContain('🎬 New Video from &lt;alice&amp;bob&gt;');
        expect(message.text).toContain('@team &lt;all&gt; please review');
        expect(message.blocks[0].text.text).toContain('*@&lt;alice&amp;bob&gt;*');
        expect(message.blocks[0].text.text).toContain('MS# `&lt;MS&amp;1&gt;`');
        expect(message.blocks[0].text.text).toContain('storm &lt;watch&gt; &amp; report');
        expect(message.blocks[0].accessory.image_url).toContain('/assets/film-placeholder.svg');
        expect(message.blocks.at(-1)).toEqual({
            type: 'context',
            elements: [{ type: 'mrkdwn', text: '@team &lt;all&gt; please review' }],
        });
    });

    it('omits mention context block when mention is absent', async () => {
        const mod = await loadSlackModule(undefined);

        const message = mod.buildAssetMessage({
            userName: 'David',
            mediasourceId: '123456789',
            clipUrl: 'https://clips.example.com/abc',
            mention: '',
            slug: '',
            capturedAt: '',
            thumbnailUrl: 'https://img.example.com/tn.jpg',
        });

        expect(message.blocks).toHaveLength(2);
        expect(message.blocks[0].accessory.image_url).toBe('https://img.example.com/tn.jpg');
        expect(message.text.includes('please review')).toBe(false);
    });

    it('builds multiclip message with ordered MS IDs, metadata, and URLs', async () => {
        const mod = await loadSlackModule(undefined);

        const message = mod.buildBatchAssetMessage({
            userName: 'David',
            mention: '@desk',
            assets: [
                {
                    mediasourceId: '100000101',
                    clipUrl: 'https://ms-fixer.test/clips/100000101',
                    slug: 'Protest 1',
                    capturedAt: '2026-05-10T18:00:00.000Z',
                    duration: 12,
                    resolution: '1920×1080',
                },
                {
                    mediasourceId: '100000102',
                    clipUrl: 'https://ms-fixer.test/clips/100000102',
                    slug: 'Protest 2',
                    capturedAt: '2026-05-10T18:01:00.000Z',
                    duration: 14,
                    resolution: '1920×1080',
                },
            ],
        });

        expect(message.text).toContain('2 New Videos from David');
        expect(message.blocks[1].text.text).toContain('1. MS# `100000101`');
        expect(message.blocks[1].text.text).toContain('2. MS# `100000102`');
        expect(message.blocks[1].text.text).toContain('<https://ms-fixer.test/clips/100000101|Open clip>');
        expect(message.blocks[1].text.text).toContain('<https://ms-fixer.test/clips/100000102|Open clip>');
        expect(message.blocks.at(-1)).toEqual({
            type: 'context',
            elements: [{ type: 'mrkdwn', text: '@desk please review' }],
        });
    });
});
