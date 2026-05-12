// Last updated: May 12, 2026 - 4:39pm - GitHub Copilot (GPT-5.3-Codex)
/**
 * Slack integration — posts messages to channels and DMs via Slack Web API.
 *
 * Requires a Bot User OAuth Token (xoxb-...) stored in SLACK_BOT_TOKEN env var.
 * Bot scopes needed: chat:write, users:read, im:write
 */
import { WebClient } from '@slack/web-api';
import { PUBLIC_URL } from './config.js';

const token = process.env.SLACK_BOT_TOKEN;
const slack = token ? new WebClient(token) : null;

// Cache: Slack display_name (lowercase) → user ID
const userIdCache = new Map();

/**
 * Whether Slack is configured (bot token is set).
 */
export function isConfigured() {
    return !!slack;
}

/**
 * Post a message to a Slack channel by name.
 * @param {string} channelName — channel name without # (e.g. "storms")
 * @param {string} text — fallback text
 * @param {object[]} [blocks] — Block Kit blocks
 * @param {{ requestId?: string }} [context]
 * @returns {{ ok: boolean, ts?: string, error?: string }}
 */
export async function postToChannel(channelName, text, blocks, context = {}) {
    if (!slack) return { ok: false, error: 'Slack not configured' };

    try {
        const result = await slack.chat.postMessage({
            channel: `#${channelName}`,
            text,
            blocks,
            unfurl_links: true,
        });
        return { ok: result.ok, ts: result.ts };
    } catch (err) {
        const error = err.data?.error || err.message;
        console.error({
            event: 'slack.postToChannel.error',
            channelName,
            requestId: context?.requestId || null,
            error,
        });
        return { ok: false, error };
    }
}

/**
 * Post a DM to a Slack user by display name.
 * Resolves display name → Slack user ID → opens DM → posts message.
 * @param {string} displayName — e.g. "carrie.smith" (without @)
 * @param {string} text — fallback text
 * @param {object[]} [blocks] — Block Kit blocks
 * @param {{ requestId?: string }} [context]
 * @returns {{ ok: boolean, ts?: string, error?: string }}
 */
export async function postDM(displayName, text, blocks, context = {}) {
    if (!slack) return { ok: false, error: 'Slack not configured' };

    try {
        const slackUserId = await resolveUserId(displayName);
        if (!slackUserId) {
            return { ok: false, error: `User "${displayName}" not found in Slack workspace` };
        }

        // Open a DM channel with the user
        const conv = await slack.conversations.open({ users: slackUserId });
        if (!conv.ok) {
            return { ok: false, error: 'Could not open DM conversation' };
        }

        const result = await slack.chat.postMessage({
            channel: conv.channel.id,
            text,
            blocks,
            unfurl_links: true,
        });
        return { ok: result.ok, ts: result.ts };
    } catch (err) {
        const error = err.data?.error || err.message;
        console.error({
            event: 'slack.postDM.error',
            displayName,
            requestId: context?.requestId || null,
            error,
        });
        return { ok: false, error };
    }
}

/**
 * Resolve a display name to a Slack user ID.
 * Caches results to avoid repeated API calls.
 */
async function resolveUserId(displayName) {
    const key = displayName.toLowerCase();
    if (userIdCache.has(key)) return userIdCache.get(key);

    try {
        // Paginate through workspace members
        let cursor;
        do {
            const result = await slack.users.list({ limit: 200, cursor });
            for (const member of result.members || []) {
                if (member.deleted || member.is_bot) continue;
                // Cache all members we see (display_name, real_name, name)
                const names = [
                    member.profile?.display_name,
                    member.profile?.real_name,
                    member.name,
                ].filter(Boolean).map(n => n.toLowerCase());

                for (const n of names) {
                    userIdCache.set(n, member.id);
                }
            }
            cursor = result.response_metadata?.next_cursor;
        } while (cursor);

        return userIdCache.get(key) || null;
    } catch (err) {
        console.error({
            event: 'slack.resolveUserId.error',
            displayName,
            message: err.message,
        });
        return null;
    }
}

/**
 * Escape Slack mrkdwn special characters in user-provided strings (C5).
 * Prevents injection of bold, italic, code, links, etc.
 */
function escapeSlackMrkdwn(str) {
    if (!str) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
}

    function formatProductionDate(capturedAt) {
        if (!capturedAt) return '';

        const date = new Date(capturedAt);
        if (Number.isNaN(date.getTime())) return '';

        return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
        + ' '
        + date.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
    }

/**
 * Build a rich Slack message for a mediasource asset.
 * Layout: Thumbnail + ▶ Play side-by-side, then metadata lines with clipboard on MS#.
 * @param {{ userName: string, mediasourceId: string, clipUrl: string, mention?: string, thumbnailUrl?: string, slug?: string, capturedAt?: string }} opts
 * @returns {{ text: string, blocks: object[] }}
 */
export function buildAssetMessage({ userName, mediasourceId, clipUrl, mention, thumbnailUrl, slug, capturedAt }) {
    // C5: Escape user-provided strings before inserting into mrkdwn
    const safeName = escapeSlackMrkdwn(userName);
    const safeId = escapeSlackMrkdwn(mediasourceId);
    const safeSlug = escapeSlackMrkdwn(slug);
    const safeMention = escapeSlackMrkdwn(mention);
    const mentionLine = mention ? `\n${safeMention} please review` : '';
    const text = `🎬 New Video from ${safeName}\n🔗 ${clipUrl}${mentionLine}`;

    // Thumbnail — use Mux thumbnail if available, otherwise a film placeholder
    const imageUrl = thumbnailUrl || `${PUBLIC_URL}/assets/film-placeholder.svg`;

    const prodDateTime = formatProductionDate(capturedAt);

    // Build metadata text (left side) — each field on its own line
    const metaLines = [`*@${safeName}*`, `MS# \`${safeId}\``];
    if (safeSlug) metaLines.push(safeSlug);
    if (prodDateTime) metaLines.push(prodDateTime);
    const metaText = metaLines.join('\n');

    const blocks = [
        // Metadata left, thumbnail right
        {
            type: 'section',
            text: {
                type: 'mrkdwn',
                text: metaText,
            },
            accessory: {
                type: 'image',
                image_url: imageUrl,
                alt_text: safeId,
            },
        },
        // Play button (green)
        {
            type: 'actions',
            elements: [
                {
                    type: 'button',
                    text: { type: 'plain_text', text: '▶️ Play' },
                    style: 'primary',
                    url: clipUrl,
                    action_id: 'play_clip',
                },
            ],
        },
    ];

    if (mention) {
        blocks.push({
            type: 'context',
            elements: [{ type: 'mrkdwn', text: `${safeMention} please review` }],
        });
    }

    return { text, blocks };
}

/**
 * Build a rich Slack message for multiple mediasource assets.
 * @param {{ userName: string, assets: Array<{ mediasourceId: string, clipUrl: string, slug?: string, capturedAt?: string|Date, duration?: number, resolution?: string }>, mention?: string }} opts
 * @returns {{ text: string, blocks: object[] }}
 */
export function buildBatchAssetMessage({ userName, assets = [], mention }) {
    const safeName = escapeSlackMrkdwn(userName);
    const safeMention = escapeSlackMrkdwn(mention);
    const clipCount = assets.length;
    const limitedAssets = assets.slice(0, 12);
    const remainingCount = Math.max(clipCount - limitedAssets.length, 0);

    const summaryText = `🎬 ${clipCount} New Videos from ${safeName}`;
    const mentionLine = mention ? `\n${safeMention} please review` : '';
    const text = `${summaryText}${mentionLine}`;

    const assetLines = limitedAssets.map((asset, index) => {
        const safeId = escapeSlackMrkdwn(asset.mediasourceId || 'N/A');
        const safeSlug = escapeSlackMrkdwn(asset.slug || 'Untitled');
        const safeResolution = escapeSlackMrkdwn(asset.resolution || '');
        const prodDateTime = formatProductionDate(asset.capturedAt);
        const durationText = Number.isFinite(asset.duration)
            ? `${Math.max(0, Number(asset.duration))}s`
            : '';
        const metaParts = [prodDateTime, durationText, safeResolution].filter(Boolean);
        const metaText = metaParts.length > 0 ? ` · ${metaParts.join(' · ')}` : '';
        return `*${index + 1}. MS# \`${safeId}\`*\n• Title: ${safeSlug}${metaText}\n• URL: <${asset.clipUrl}|Open clip>`;
    });

    if (remainingCount > 0) {
        assetLines.push(`_...and ${remainingCount} more clips_`);
    }

    const blocks = [
        {
            type: 'section',
            text: {
                type: 'mrkdwn',
                text: `*@${safeName}* uploaded *${clipCount}* clips.`,
            },
        },
        {
            type: 'section',
            text: {
                type: 'mrkdwn',
                text: assetLines.join('\n\n'),
            },
        },
    ];

    if (mention) {
        blocks.push({
            type: 'context',
            elements: [{ type: 'mrkdwn', text: `${safeMention} please review` }],
        });
    }

    return { text, blocks };
}
