// Last updated: May 12, 2026 - 3:05pm - GitHub Copilot (GPT-5.3-Codex)
/**
 * WebSocket handler — Socket.IO event management.
 * Handles real-time communication between the iOS app and server.
 */
import crypto from 'node:crypto';
import prisma from '../lib/prisma.js';
import * as slack from '../lib/slack.js';
import { PUBLIC_URL } from '../lib/config.js';
import { redactPersonName } from '../lib/redact.js';
import { hasSession } from '../lib/session-store.js';

/** Greeting templates — `{time}` is replaced with time-of-day, `{name}` with first name. */
const GREETINGS = [
    `🙋‍♂️ {time} {name}. I am ready for your video.`,
    `📹 {time} {name}. Let's get your footage uploaded.`,
    `👋 {time} {name}! Drop a video and I'll handle the rest.`,
    `🎬 {time} {name}. I am speeding, rack and roll.`,
    `⚡ {time} {name}, Time to make great TV!`,
    `🚀 {time} {name}, Upload away, I've got you covered.`,
    `🎥 {time} {name}. Videos dont'upload themselves.`,
    `✌️ {time} {name}. Standing by for your next masterpiece.`,
    `📡 {time} {name}. Signal is 5 x 5 — send it over.`,
    `🔥 {time} {name}, To grow your audience just add content.`,
];

/** Track last index so we never repeat the same greeting consecutively. */
let lastGreetingIndex = -1;

/** Return a time-of-day greeting personalised with the user's first name. */
function getGreeting(name) {
    const hour = new Date().getHours();
    const timeOptions = [
        [12, ['Good Morning', 'Rise and shine', 'Top of the morning', 'Morning', 'Suuup.']],
        [19, ['Good Afternoon', 'Hey there', 'Afternoon', 'Hello']],
        [24, ['Good Evening', 'Evening', 'Hey night owl', 'Burning the midnight oil']],
    ].find(([h]) => hour < h)[1];
    const timeOfDay = timeOptions[Math.floor(Math.random() * timeOptions.length)];

    // Pick a random greeting that isn't the same as last time
    let index;
    do {
        index = Math.floor(Math.random() * GREETINGS.length);
    } while (index === lastGreetingIndex);
    lastGreetingIndex = index;

    return GREETINGS[index].replace('{time}', timeOfDay).replace('{name}', name);
}

/** Feature tips — shown as a second bubble after the greeting. */
const TIPS = [
    `Tap the ＋ button and choose your video.`,
    `Once uploaded, type @name or #channel to Slack your video.`,
    `I'll archive your video when its finished.`,
    `You can start a new upload as soon as the current one finishes.`,
    `Use the transcribe toggle to create a transcript.`,
    `Keep Fixer open until the progress bar is 100%`,
    `I'll send your metadata once I read the video file.`,
    `Don't skip the slug form, Fixer can fix just so much.`,
    `Permissions are in your profile. So is logout but I don't want you to go.`,
];

const LAST_TIPS = ['The Guide Dog 🐕‍🦺 , top right, leads you to how Fixer works.'];

/** Track last tip index so we never repeat consecutively. */
let lastTipIndex = -1;

/** Return a random feature tip, never the same as last time. */
function getTip() {
    let index;
    do {
        index = Math.floor(Math.random() * TIPS.length);
    } while (index === lastTipIndex);
    lastTipIndex = index;
    // DONT REMOVE THIS comment  return TIPS[index] + LAST_TIPS;
    return LAST_TIPS[0];
}

const MESSAGE_SCHEMA_VERSION = 1;
const WEB_SESSION_COOKIE_NAME = 'fixer_clip_token';

function stringifyParams(params = {}) {
    return Object.fromEntries(
        Object.entries(params)
            .filter(([, value]) => value !== undefined && value !== null)
            .map(([key, value]) => [key, String(value)])
    );
}

function buildContent({ code, params = {}, fallbackText, text, ...extra }) {
    const safeText = text ?? fallbackText ?? '';
    const safeFallback = fallbackText ?? safeText;
    const normalizedParams = stringifyParams(params);

    return {
        text: safeText,
        code,
        params: Object.keys(normalizedParams).length > 0 ? normalizedParams : undefined,
        fallbackText: safeFallback,
        schemaVersion: MESSAGE_SCHEMA_VERSION,
        ...extra,
    };
}

function readCookieValue(rawCookieHeader, cookieName) {
    if (typeof rawCookieHeader !== 'string' || !rawCookieHeader) return null;

    for (const segment of rawCookieHeader.split(';')) {
        const [rawKey, ...rawValueParts] = segment.split('=');
        if (!rawKey) continue;

        const key = rawKey.trim();
        if (key !== cookieName) continue;

        const value = rawValueParts.join('=').trim();
        if (!value) return null;

        try {
            return decodeURIComponent(value);
        } catch {
            return value;
        }
    }

    return null;
}

/**
 * Handle a Slack command — parse #channels and @mentions, post via Slack API,
 * persist to DB, and send confirmation/error bubble back to iOS.
 */
async function handleSlackCommand(socket, userId, assetId, assetIds, channels, mentions, originalText, log) {
    const now = new Date().toISOString();
    const correlation = { requestId: `ws:${socket.id}` };

    // Persist the outgoing Slack command message
    try {
        await prisma.chatMessage.create({
            data: {
                userId,
                assetId: assetId || null,
                direction: 'OUTGOING',
                messageType: 'SLACK_POST',
                content: {
                    text: originalText,
                    channel: channels[0] || null,
                    mention: mentions[0] || null,
                    assetIds: Array.isArray(assetIds) && assetIds.length > 0 ? assetIds : undefined,
                },
            },
        });
    } catch (dbErr) {
        log.error({ err: { message: dbErr.message } }, 'DB write failed for slack command');
    }

    // Check if Slack is configured
    if (!slack.isConfigured()) {
        const fallbackText = 'Slack is not configured. Set SLACK_BOT_TOKEN on the server.';
        socket.emit('message:new', {
            id: crypto.randomUUID(),
            userId: null,
            assetId: assetId || null,
            direction: 'INCOMING',
            messageType: 'SLACK_POST',
            content: buildContent({
                code: 'WS_SLACK_NOT_CONFIGURED',
                fallbackText,
                text: fallbackText,
            }),
            createdAt: now,
        });
        return;
    }

    // Resolve assets for Slack payload.
    // If iOS sends assetIds, build a multiclip post in that exact order.
    // Otherwise fall back to explicit assetId or most recent READY asset.
    let slackAssets = [];
    let primaryAsset = null;

    try {
        if (Array.isArray(assetIds) && assetIds.length > 0) {
            const requestedIds = [...new Set(assetIds)].slice(0, 20);
            const assets = await prisma.asset.findMany({
                where: {
                    userId,
                    id: { in: requestedIds },
                },
                select: {
                    id: true,
                    mediasourceId: true,
                    formResponse: { select: { slug: true } },
                    clips: {
                        select: { muxPlaybackId: true, capturedAt: true, duration: true, resolution: true },
                        take: 1,
                        orderBy: { createdAt: 'desc' },
                    },
                },
            });

            const assetMap = new Map(assets.map((entry) => [entry.id, entry]));
            const orderedAssets = requestedIds.map((id) => assetMap.get(id)).filter(Boolean);

            slackAssets = orderedAssets
                .filter((entry) => entry.mediasourceId)
                .map((entry) => {
                    const clip = entry.clips?.[0];
                    const playbackId = clip?.muxPlaybackId;
                    return {
                        assetId: entry.id,
                        mediasourceId: entry.mediasourceId,
                        clipUrl: `${PUBLIC_URL}/clips/${entry.mediasourceId}`,
                        slug: entry.formResponse?.slug || null,
                        capturedAt: clip?.capturedAt || null,
                        duration: clip?.duration || null,
                        resolution: clip?.resolution || null,
                        thumbnailUrl: playbackId
                            ? `https://image.mux.com/${playbackId}/thumbnail.png?width=640`
                            : null,
                    };
                });
        }

        if (slackAssets.length === 0) {
            const where = assetId
                ? { id: assetId, userId }
                : { userId, status: 'READY' };
            const asset = await prisma.asset.findFirst({
                where,
                orderBy: { createdAt: 'desc' },
                select: {
                    id: true,
                    mediasourceId: true,
                    formResponse: { select: { slug: true } },
                    clips: {
                        select: { muxPlaybackId: true, capturedAt: true, duration: true, resolution: true },
                        take: 1,
                        orderBy: { createdAt: 'desc' },
                    },
                },
            });

            if (asset?.mediasourceId) {
                const clip = asset.clips?.[0];
                const playbackId = clip?.muxPlaybackId;
                slackAssets = [
                    {
                        assetId: asset.id,
                        mediasourceId: asset.mediasourceId,
                        clipUrl: `${PUBLIC_URL}/clips/${asset.mediasourceId}`,
                        slug: asset.formResponse?.slug || null,
                        capturedAt: clip?.capturedAt || null,
                        duration: clip?.duration || null,
                        resolution: clip?.resolution || null,
                        thumbnailUrl: playbackId
                            ? `https://image.mux.com/${playbackId}/thumbnail.png?width=640`
                            : null,
                    },
                ];
            }
        }

        primaryAsset = slackAssets[0] || null;
    } catch (err) {
        log.error({ err: { message: err.message } }, 'Failed to look up asset for slack command');
    }

    // No asset found — tell user to upload first
    if (!primaryAsset?.mediasourceId) {
        const fallbackText = 'You can Slack your team after your first video of the day. Check the archive for previous uploads.';
        socket.emit('message:new', {
            id: crypto.randomUUID(),
            userId: null,
            assetId: null,
            direction: 'INCOMING',
            messageType: 'TEXT',
            content: buildContent({
                code: 'WS_SLACK_REQUIRES_UPLOAD',
                fallbackText,
                text: fallbackText,
            }),
            createdAt: now,
        });
        return;
    }

    // Build Slack mention string (resolve display names to <@USERID> for channel posts)
    let slackMentionStr = null;
    if (mentions.length > 0 && channels.length > 0) {
        // For channel posts with mentions, resolve to Slack user IDs for proper @notification
        const resolved = [];
        for (const name of mentions) {
            const { postDM } = slack; // just need the resolver
            // We'll resolve and use in buildAssetMessage
            resolved.push(`@${name}`);
        }
        slackMentionStr = resolved.join(' ');
    }

    let payload;
    if (slackAssets.length > 1) {
        payload = slack.buildBatchAssetMessage({
            userName: socket.userName,
            assets: slackAssets.map((entry) => ({
                mediasourceId: entry.mediasourceId,
                clipUrl: entry.clipUrl,
                slug: entry.slug,
                capturedAt: entry.capturedAt,
                duration: entry.duration,
                resolution: entry.resolution,
            })),
            mention: slackMentionStr,
        });
    } else {
        payload = slack.buildAssetMessage({
            userName: socket.userName,
            mediasourceId: primaryAsset.mediasourceId || 'N/A',
            clipUrl: primaryAsset.clipUrl || '(no clip ready)',
            mention: slackMentionStr,
            thumbnailUrl: primaryAsset.thumbnailUrl,
            slug: primaryAsset.slug,
            capturedAt: primaryAsset.capturedAt,
        });
    }

    const { text: msgText, blocks } = payload;
    log.info(
        {
            mediasourceId: primaryAsset.mediasourceId,
            hasSlug: !!primaryAsset.slug,
            clipCount: slackAssets.length,
        },
        'Prepared slack post payload'
    );

    const results = [];

    // Post to each #channel
    for (const ch of channels) {
        log.info({ channel: `#${ch}` }, 'Posting slack channel message');
        const result = await slack.postToChannel(ch, msgText, blocks, correlation);
        results.push({ type: 'channel', target: `#${ch}`, ...result });
    }

    // Send DM to each @mention (only if not also posting to a channel — avoids double-notify)
    if (channels.length === 0) {
        for (const name of mentions) {
            log.info({ mention: `@${name}` }, 'Posting slack direct message');
            const result = await slack.postDM(name, msgText, blocks, correlation);
            results.push({ type: 'dm', target: `@${name}`, ...result });
        }
    }

    // Build confirmation text
    const successes = results.filter(r => r.ok);
    const failures = results.filter(r => !r.ok);

    let confirmText;
    if (successes.length > 0 && failures.length === 0) {
        const targets = successes.map(r => r.target).join(', ');
        confirmText = `${targets}`; /// post is finished in MessageBubble.swift 256
    } else if (failures.length > 0 && successes.length === 0) {
        const targets = failures.map(r => `${r.target} (${r.error})`).join(', ');
        confirmText = `❌ Couldn't post to ${targets}`;
    } else {
        const ok = successes.map(r => r.target).join(', ');
        const fail = failures.map(r => `${r.target} (${r.error})`).join(', ');
        confirmText = `✅ Posted to ${ok}\n❌ Failed: ${fail}`;
    }

    let confirmCode = 'WS_SLACK_CONFIRMATION_OK';
    let confirmParams = {
        targets: successes.map(r => r.target).join(', '),
    };
    if (failures.length > 0 && successes.length === 0) {
        confirmCode = 'WS_SLACK_CONFIRMATION_FAILED';
        confirmParams = {
            failedTargets: failures.map(r => `${r.target} (${r.error})`).join(', '),
        };
    } else if (failures.length > 0 && successes.length > 0) {
        confirmCode = 'WS_SLACK_CONFIRMATION_PARTIAL';
        confirmParams = {
            okTargets: successes.map(r => r.target).join(', '),
            failedTargets: failures.map(r => `${r.target} (${r.error})`).join(', '),
        };
    }

    // Send confirmation bubble to iOS
    socket.emit('message:new', {
        id: crypto.randomUUID(),
        userId: null,
        assetId: assetId || null,
        direction: 'INCOMING',
        messageType: 'SLACK_POST',
        content: buildContent({
            code: confirmCode,
            params: confirmParams,
            fallbackText: confirmText,
            text: confirmText,
            channel: channels[0] || null,
            mention: mentions[0] || null,
            mediasourceId: primaryAsset.mediasourceId,
            userName: socket.userName,
            slug: primaryAsset.slug || primaryAsset.mediasourceId,
            thumbnailUrl: primaryAsset.thumbnailUrl || null,
            capturedAt: primaryAsset.capturedAt?.toISOString?.() ?? primaryAsset.capturedAt ?? null,
        }),
        createdAt: now,
    });
}

export function setupWebSocket(io, fastify) {
    const log = fastify.log;

    // Track which sockets belong to which user
    const userSockets = new Map(); // userId → Set<socketId>
    fastify.decorate('userSockets', userSockets);

    // Debounce map for text-message auto-replies: userId → { timer, texts[] }
    const pendingReplies = new Map();

    // Track client types separately
    const iosSockets = new Set();   // socket IDs from iOS app
    const adminSockets = new Set(); // socket IDs from admin dashboard
    const connectedUsers = new Set(); // userId — for quieting repeated connect logs
    fastify.decorate('iosSockets', iosSockets);
    fastify.decorate('adminSockets', adminSockets);

    // Log Engine.IO-level connection errors (upgrade failures, transport issues)
    io.engine.on('connection_error', (err) => {
        log.error({ err: { message: err.message }, context: err.context || null }, 'Engine.IO connection error');
    });

    io.use(async (socket, next) => {
        try {
            const rawAuthHeader = socket.handshake.headers?.authorization;
            const headerToken =
                typeof rawAuthHeader === 'string' && rawAuthHeader.startsWith('Bearer ')
                    ? rawAuthHeader.slice(7).trim()
                    : null;
            const cookieToken = readCookieValue(socket.handshake.headers?.cookie, WEB_SESSION_COOKIE_NAME);
            const token = socket.handshake.auth?.token || headerToken || cookieToken;

            if (!token) {
                log.warn({ socketId: socket.id }, 'WS auth rejected: no token provided');
                return next(new Error('Authentication required'));
            }

            // Verify JWT
            const decoded = fastify.jwt.verify(token);

            if (!decoded?.jti || !(await hasSession(decoded.jti))) {
                log.warn({ socketId: socket.id, userId: decoded?.id || null }, 'WS auth rejected: session revoked or missing');
                return next(new Error('Unauthorized'));
            }

            // Hydrate and enforce user status/role from DB, not token claims alone.
            const user = await prisma.user.findUnique({
                where: { id: decoded.id },
                select: {
                    id: true,
                    name: true,
                    phoneNumber: true,
                    status: true,
                    role: true,
                },
            });

            if (!user || user.status !== 'ACTIVE') {
                log.warn({ socketId: socket.id, userId: decoded.id || null }, 'WS auth rejected: inactive or missing user');
                return next(new Error('Unauthorized'));
            }

            const requestedClientType = socket.handshake.auth?.clientType || 'unknown';
            if (requestedClientType === 'admin' && user.role !== 'ADMIN') {
                log.warn({ socketId: socket.id, userId: user.id }, 'WS auth rejected: admin client requires admin role');
                return next(new Error('Admin access required'));
            }

            socket.userId = user.id;
            socket.userName = user.name;
            socket.phoneNumber = user.phoneNumber;
            socket.userRole = user.role || 'USER';

            // Device tracking — sent from iOS in the Socket.IO CONNECT auth payload
            socket.deviceId = socket.handshake.auth?.deviceId || null;
            socket.deviceName = socket.handshake.auth?.deviceName || null;
            socket.deviceModel = socket.handshake.auth?.deviceModel || null;
            next();
        } catch (err) {
            log.warn({ err: { message: err.message }, socketId: socket.id }, 'WS auth rejected: token verification failed');
            next(new Error('Invalid token'));
        }
    });

    io.on('connection', (socket) => {
        const userId = socket.userId;
        const clientType = socket.handshake.auth?.clientType || 'unknown';
        socket.clientType = clientType;

        // Track client type
        if (clientType === 'ios') {
            iosSockets.add(socket.id);
        } else if (clientType === 'admin') {
            adminSockets.add(socket.id);
        }

        // Track this socket for the user
        if (!userSockets.has(userId)) {
            userSockets.set(userId, new Set());
        }
        userSockets.get(userId).add(socket.id);

        // Track user for disconnect cleanup
        connectedUsers.add(userId);

        if (clientType === 'ios') {
            // Count only iOS sockets for this user (ignore admin dashboard connections)
            const allUserSockets = userSockets.get(userId) ?? new Set();
            const iosCountForUser = [...allUserSockets].filter(id => iosSockets.has(id)).length;
            const deviceLabel = socket.deviceName ? ` on ${socket.deviceName} (${socket.deviceModel || 'iOS'})` : '';
            log.info(
                {
                    userName: redactPersonName(socket.userName),
                    deviceName: socket.deviceName || null,
                    deviceModel: socket.deviceModel || null,
                    iosClients: iosSockets.size,
                    userIosSockets: iosCountForUser,
                },
                'iOS socket connected'
            );

            // Greet every iOS device — multiple phones uploading is a feature
            const firstName = (socket.userName || '').split(' ')[0] || socket.userName;
            const greetingText = getGreeting(firstName);
            socket.emit('message:new', {
                id: crypto.randomUUID(),
                userId: null,
                assetId: null,
                direction: 'INCOMING',
                messageType: 'GREETING',
                content: buildContent({
                    code: 'WS_GREETING_CONNECTED',
                    params: { firstName },
                    fallbackText: greetingText,
                    text: greetingText,
                }),
                createdAt: new Date().toISOString(),
            });

            // Send a feature tip as a second bubble after a short delay
            setTimeout(() => {
                const tipText = getTip();
                socket.emit('message:new', {
                    id: crypto.randomUUID(),
                    userId: null,
                    assetId: null,
                    direction: 'INCOMING',
                    messageType: 'SYSTEM_NOTE',
                    content: buildContent({
                        code: 'WS_SYSTEM_TIP_GUIDE',
                        fallbackText: tipText,
                        text: tipText,
                    }),
                    createdAt: new Date().toISOString(),
                });
            }, 500);

            // Greeting is ephemeral — not persisted (Option B: only persist meaningful events)
        }

        // ─── Client Events ─────────────────────────────────────

        /**
         * video:upload — Client signals a video upload is starting.
         */
        socket.on('video:upload', async (data) => {
            log.info(
                {
                    userName: redactPersonName(socket.userName),
                    assetId: data?.assetId || null,
                },
                'Websocket upload start event received'
            );

            // Cancel any pending debounced auto-reply — user is uploading
            const pending = pendingReplies.get(userId);
            if (pending) {
                clearTimeout(pending.timer);
                pendingReplies.delete(userId);
                log.debug({ userName: redactPersonName(socket.userName) }, 'Cancelled pending debounced auto-reply on upload start');
            }

            // The actual file upload happens over HTTP (multipart).
            // This event is for real-time UI updates.
            socket.emit('upload:progress', {
                assetId: data.assetId,
                percent: 0,
                status: 'uploading',
            });
        });

        /**
         * message:send — Client sends a text message.
         * If text starts with # or @, treat as Slack command (post to channel/DM).
         * Otherwise, debounced auto-reply.
         */
        socket.on('message:send', async (data) => {
            try {
                const { text, assetId, assetIds: rawAssetIds } = data;
                const assetIds = Array.isArray(rawAssetIds)
                    ? [...new Set(
                        rawAssetIds
                            .filter((id) => typeof id === 'string')
                            .map((id) => id.trim())
                            .filter(Boolean)
                    )].slice(0, 20)
                    : [];

                // C4: Sanitize incoming message — length limit + strip control chars
                const MAX_MESSAGE_LENGTH = 500;
                const sanitized = (text || '')
                    .slice(0, MAX_MESSAGE_LENGTH)
                    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '') // strip control chars except \n \r \t
                    .trim();

                if (!sanitized) return; // Drop empty messages

                log.info(
                    {
                        userName: redactPersonName(socket.userName),
                        messageLength: sanitized.length,
                        assetId: assetId || null,
                        assetIdsCount: assetIds.length,
                    },
                    'Websocket message received'
                );

                // ─── Slack command detection ───
                const trimmed = sanitized;
                const channels = [...trimmed.matchAll(/#([\w-]+)/g)].map(m => m[1]);
                const mentions = [...trimmed.matchAll(/@([\w.-]+)/g)].map(m => m[1]);
                const isSlackCommand = channels.length > 0 || mentions.length > 0;

                if (isSlackCommand) {
                    await handleSlackCommand(
                        socket,
                        userId,
                        assetId,
                        assetIds,
                        channels,
                        mentions,
                        trimmed,
                        log
                    );
                    return; // Skip auto-reply for Slack commands
                }

                // Store outgoing message (best-effort — don't let DB failure block reply)
                try {
                    await prisma.chatMessage.create({
                        data: {
                            userId,
                            assetId: assetId || null,
                            direction: 'OUTGOING',
                            messageType: 'TEXT',
                            content: { text: sanitized },
                        },
                    });
                } catch (dbErr) {
                    log.error({ err: { message: dbErr.message } }, 'DB write failed for outgoing websocket message');
                }

                // Debounced auto-reply — tolerate rapid-fire texts, consolidate into one reply
                {
                    const DEBOUNCE_MS = 5000;
                    const existing = pendingReplies.get(userId);

                    if (existing) {
                        clearTimeout(existing.timer);
                        existing.texts.push(text);
                    } else {
                        pendingReplies.set(userId, { timer: null, texts: [text] });
                    }

                    const entry = pendingReplies.get(userId);
                    entry.timer = setTimeout(async () => {
                        pendingReplies.delete(userId);

                        const firstName = (socket.userName || '').split(' ')[0] || socket.userName || 'there';
                        const replyText =
                            `Hey ${firstName}, I can't text just yet. Send me your videos. Tap the plus button to pick a video from your camera roll.`;
                        const now = new Date().toISOString();

                        // Auto-reply is ephemeral — not persisted (Option B)

                        // Send reply — shape matches REST /api/messages so iOS can decode
                        socket.emit('message:new', {
                            id: crypto.randomUUID(),
                            userId: null,
                            assetId: assetId || null,
                            direction: 'INCOMING',
                            messageType: 'TEXT',
                            content: buildContent({
                                code: 'WS_TEXT_AUTO_REPLY_SEND_VIDEO',
                                params: { userName: firstName },
                                fallbackText: replyText,
                                text: replyText,
                            }),
                            createdAt: now,
                        });
                    }, DEBOUNCE_MS);
                }
            } catch (err) {
                log.error({ err }, 'message:send websocket handler failed');
            }
        });

        // ─── Disconnect ────────────────────────────────────────

        socket.on('disconnect', () => {
            // Clean up client type tracking
            const wasIos = iosSockets.delete(socket.id);
            adminSockets.delete(socket.id);

            const sockets = userSockets.get(userId);
            if (sockets) {
                sockets.delete(socket.id);
                if (sockets.size === 0) {
                    userSockets.delete(userId);
                    connectedUsers.delete(userId);

                    // Clean up any pending debounced reply
                    const pending = pendingReplies.get(userId);
                    if (pending) {
                        clearTimeout(pending.timer);
                        pendingReplies.delete(userId);
                    }
                }
            }

            // Only log iOS disconnects (admin churn is silent)
            if (wasIos) {
                log.info(
                    { userName: redactPersonName(socket.userName), iosClients: iosSockets.size },
                    'iOS socket disconnected'
                );
            }
        });
    });
}
