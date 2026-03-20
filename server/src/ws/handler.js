/**
 * WebSocket handler — Socket.IO event management.
 * Handles real-time communication between the iOS app and server.
 */
import crypto from 'node:crypto';
import prisma from '../lib/prisma.js';
import * as slack from '../lib/slack.js';

/** Return a time-of-day greeting personalised with the user's first name. */
function getGreeting(name) {
    const hour = new Date().getHours();
    let timeOfDay;
    if (hour < 12) timeOfDay = 'Good Morning';
    else if (hour < 17) timeOfDay = 'Good Afternoon';
    else timeOfDay = 'Good Evening';
    return `🙋‍♂️ ${timeOfDay} ${name}! I am ready for your video.`;
}

/**
 * Handle a Slack command — parse #channels and @mentions, post via Slack API,
 * persist to DB, and send confirmation/error bubble back to iOS.
 */
async function handleSlackCommand(socket, userId, assetId, channels, mentions, originalText) {
    const now = new Date().toISOString();

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
                },
            },
        });
    } catch (dbErr) {
        console.error('DB write failed (slack command):', dbErr.message);
    }

    // Check if Slack is configured
    if (!slack.isConfigured()) {
        socket.emit('message:new', {
            id: crypto.randomUUID(),
            userId: null,
            assetId: assetId || null,
            direction: 'INCOMING',
            messageType: 'SLACK_POST',
            content: { text: '❌ Slack is not configured. Set SLACK_BOT_TOKEN on the server.' },
            createdAt: now,
        });
        return;
    }

    // Resolve asset — use explicit assetId if provided (archive), else most recent READY
    let mediasourceId = null;
    let clipUrl = null;
    let thumbnailUrl = null;
    let asset = null;
    try {
        const where = assetId
            ? { id: assetId, userId }
            : { userId, status: 'READY' };
        asset = await prisma.asset.findFirst({
            where,
            orderBy: { createdAt: 'desc' },
            select: {
                mediasourceId: true,
                formResponse: { select: { slug: true } },
                clips: { select: { muxPlaybackId: true, capturedAt: true }, take: 1, orderBy: { createdAt: 'desc' } },
            },
        });
        if (asset?.mediasourceId) {
            mediasourceId = asset.mediasourceId;
            const baseUrl = process.env.NODE_ENV === 'production'
                ? 'https://rodgriola.com'
                : `http://localhost:${process.env.PORT || 3000}`;
            clipUrl = `${baseUrl}/clips/${mediasourceId}`;
            const playbackId = asset.clips?.[0]?.muxPlaybackId;
            if (playbackId) {
                thumbnailUrl = `https://image.mux.com/${playbackId}/thumbnail.png?width=640`;
            }
        }
    } catch (err) {
        console.error('Failed to look up asset for Slack:', err.message);
    }

    // No asset found — tell user to upload first
    if (!mediasourceId) {
        socket.emit('message:new', {
            id: crypto.randomUUID(),
            userId: null,
            assetId: null,
            direction: 'INCOMING',
            messageType: 'TEXT',
            content: { text: 'Upload a video first and I can grab the metadata so you can Slack it. Previous uploads are in your Archive — you can Slack from there.' },
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

    const { text: msgText, blocks } = slack.buildAssetMessage({
        userName: socket.userName,
        mediasourceId: mediasourceId || 'N/A',
        clipUrl: clipUrl || '(no clip ready)',
        mention: slackMentionStr,
        thumbnailUrl,
        slug: asset?.formResponse?.slug,
        capturedAt: asset?.clips?.[0]?.capturedAt,
    });

    const results = [];

    // Post to each #channel
    for (const ch of channels) {
        console.log(`📣 Posting to #${ch} for ${socket.userName}`);
        const result = await slack.postToChannel(ch, msgText, blocks);
        results.push({ type: 'channel', target: `#${ch}`, ...result });
    }

    // Send DM to each @mention (only if not also posting to a channel — avoids double-notify)
    if (channels.length === 0) {
        for (const name of mentions) {
            console.log(`📨 DM to @${name} for ${socket.userName}`);
            const result = await slack.postDM(name, msgText, blocks);
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

    // Send confirmation bubble to iOS
    socket.emit('message:new', {
        id: crypto.randomUUID(),
        userId: null,
        assetId: assetId || null,
        direction: 'INCOMING',
        messageType: 'SLACK_POST',
        content: {
            text: confirmText,
            channel: channels[0] || null,
            mention: mentions[0] || null,
            mediasourceId,
            userName: socket.userName,
            slug: mediasourceId,
            thumbnailUrl: thumbnailUrl || null,
            capturedAt: asset?.clips?.[0]?.capturedAt?.toISOString?.() ?? asset?.clips?.[0]?.capturedAt ?? null,
        },
        createdAt: now,
    });
}

export function setupWebSocket(io, fastify) {
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
        console.error('🔌 [Engine.IO] Connection error:', err.message, err.context || '');
    });

    io.use(async (socket, next) => {
        try {
            const token = socket.handshake.auth?.token
                || socket.handshake.headers?.authorization?.replace('Bearer ', '');

            if (!token) {
                console.warn('🔐 [WS Auth] No token provided — rejecting connection');
                return next(new Error('Authentication required'));
            }

            // Verify JWT
            const decoded = fastify.jwt.verify(token);
            socket.userId = decoded.id;
            socket.userName = decoded.name;
            socket.phoneNumber = decoded.phoneNumber;
            next();
        } catch (err) {
            console.warn(`🔐 [WS Auth] Token verification failed: ${err.message}`);
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
            const socketCount = userSockets.get(userId)?.size ?? 0;
            console.log(`✅ iOS connected: ${socket.userName} (userId=${userId}) — iOS clients: ${iosSockets.size}, user sockets: ${socketCount}`);

            // Only send greeting on fresh connections (not reconnects from tab switch / background return)
            if (socketCount <= 1) {
                const greetingText = getGreeting(socket.userName);
                socket.emit('message:new', {
                    id: crypto.randomUUID(),
                    userId: null,
                    assetId: null,
                    direction: 'INCOMING',
                    messageType: 'GREETING',
                    content: { text: greetingText },
                    createdAt: new Date().toISOString(),
                });
            } else {
                console.log(`↩️ Reconnect for ${socket.userName} — skipping greeting`);
            }

            // Greeting is ephemeral — not persisted (Option B: only persist meaningful events)
        }

        // ─── Client Events ─────────────────────────────────────

        /**
         * video:upload — Client signals a video upload is starting.
         */
        socket.on('video:upload', async (data) => {
            console.log(`📹 Upload started by ${socket.userName}:`, data);

            // Cancel any pending debounced auto-reply — user is uploading
            const pending = pendingReplies.get(userId);
            if (pending) {
                clearTimeout(pending.timer);
                pendingReplies.delete(userId);
                console.log(`⏱️ Cancelled debounced reply for ${socket.userName} (upload started)`);
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
                const { text, assetId } = data;

                // C4: Sanitize incoming message — length limit + strip control chars
                const MAX_MESSAGE_LENGTH = 5000;
                const sanitized = (text || '')
                    .slice(0, MAX_MESSAGE_LENGTH)
                    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '') // strip control chars except \n \r \t
                    .trim();

                if (!sanitized) return; // Drop empty messages

                console.log(`💬 Message from ${socket.userName}: ${sanitized}`);

                // ─── Slack command detection ───
                const trimmed = sanitized;
                const channels = [...trimmed.matchAll(/#([\w-]+)/g)].map(m => m[1]);
                const mentions = [...trimmed.matchAll(/@([\w.-]+)/g)].map(m => m[1]);
                const isSlackCommand = channels.length > 0 || mentions.length > 0;

                if (isSlackCommand) {
                    await handleSlackCommand(socket, userId, assetId, channels, mentions, trimmed);
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
                    console.error('DB write failed (outgoing):', dbErr.message);
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

                        const replyText = `📱 Hey ${socket.userName}, I can't text just yet — send me your videos! Tap the ＋ button to pick a video from your camera roll.`;
                        const now = new Date().toISOString();

                        // Auto-reply is ephemeral — not persisted (Option B)

                        // Send reply — shape matches REST /api/messages so iOS can decode
                        socket.emit('message:new', {
                            id: crypto.randomUUID(),
                            userId: null,
                            assetId: assetId || null,
                            direction: 'INCOMING',
                            messageType: 'TEXT',
                            content: { text: replyText },
                            createdAt: now,
                        });
                    }, DEBOUNCE_MS);
                }
            } catch (err) {
                console.error('message:send error:', err);
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
                console.log(`❌ IOS disconnected: ${socket.userName} — iOS: ${iosSockets.size}`);
            }
        });
    });
}
