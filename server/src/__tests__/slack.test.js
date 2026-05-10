// Last updated: May 9, 2026 - 6:55pm - GPT-5.3-Codex
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
});
