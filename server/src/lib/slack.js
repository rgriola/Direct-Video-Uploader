/**
 * Slack integration — posts messages to channels and DMs via Slack Web API.
 *
 * Requires a Bot User OAuth Token (xoxb-...) stored in SLACK_BOT_TOKEN env var.
 * Bot scopes needed: chat:write, users:read, im:write
 */
import { WebClient } from '@slack/web-api';

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
 * @returns {{ ok: boolean, ts?: string, error?: string }}
 */
export async function postToChannel(channelName, text, blocks) {
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
        console.error(`Slack postToChannel #${channelName} failed:`, err.data?.error || err.message);
        return { ok: false, error: err.data?.error || err.message };
    }
}

/**
 * Post a DM to a Slack user by display name.
 * Resolves display name → Slack user ID → opens DM → posts message.
 * @param {string} displayName — e.g. "carrie.smith" (without @)
 * @param {string} text — fallback text
 * @param {object[]} [blocks] — Block Kit blocks
 * @returns {{ ok: boolean, ts?: string, error?: string }}
 */
export async function postDM(displayName, text, blocks) {
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
        console.error(`Slack postDM @${displayName} failed:`, err.data?.error || err.message);
        return { ok: false, error: err.data?.error || err.message };
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
        console.error('Slack resolveUserId failed:', err.message);
        return null;
    }
}

/**
 * Build a rich Slack message for a mediasource asset.
 * @param {{ userName: string, mediasourceId: string, clipUrl: string, mention?: string }} opts
 * @returns {{ text: string, blocks: object[] }}
 */
export function buildAssetMessage({ userName, mediasourceId, clipUrl, mention, thumbnailUrl }) {
    const mentionLine = mention ? `\n${mention} please review` : '';
    const text = `🎬 New Video from ${userName}\n🔗 ${clipUrl}${mentionLine}`;

    const sectionBlock = {
        type: 'section',
        text: {
            type: 'mrkdwn',
            text: `*MS#* \`${mediasourceId}\` by: @${userName}`,
        },
    };

    // Thumbnail — use Mux thumbnail if available, otherwise a film placeholder
    const baseUrl = process.env.NODE_ENV === 'production'
        ? 'https://rodgriola.com'
        : `http://localhost:${process.env.PORT || 3000}`;
    const imageUrl = thumbnailUrl || `${baseUrl}/assets/film-placeholder.svg`;

    sectionBlock.accessory = {
        type: 'image',
        image_url: imageUrl,
        alt_text: `Video thumbnail for ${mediasourceId}`,
    };

    const blocks = [
        sectionBlock,
        {
            type: 'actions',
            elements: [
                {
                    type: 'button',
                    text: { type: 'plain_text', text: '▶️ View Clip' },
                    url: clipUrl,
                    action_id: 'view_clip',
                },
            ],
        },
    ];

    if (mention) {
        blocks.push({
            type: 'context',
            elements: [{ type: 'mrkdwn', text: `${mention} please review` }],
        });
    }

    return { text, blocks };
}
