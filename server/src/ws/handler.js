/**
 * WebSocket handler — Socket.IO event management.
 * Handles real-time communication between the iOS app and server.
 */
import crypto from 'node:crypto';
import prisma from '../lib/prisma.js';

/** Return a time-of-day greeting personalised with the user's first name. */
function getGreeting(name) {
    const hour = new Date().getHours();
    let timeOfDay;
    if (hour < 12) timeOfDay = 'Good Morning';
    else if (hour < 17) timeOfDay = 'Good Afternoon';
    else timeOfDay = 'Good Evening';
    return `🙋‍♂️ ${timeOfDay} ${name}! I am ready for your video.`;
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

    io.use(async (socket, next) => {
        try {
            const token = socket.handshake.auth?.token
                || socket.handshake.headers?.authorization?.replace('Bearer ', '');

            if (!token) {
                return next(new Error('Authentication required'));
            }

            // Verify JWT
            const decoded = fastify.jwt.verify(token);
            socket.userId = decoded.id;
            socket.userName = decoded.name;
            socket.phoneNumber = decoded.phoneNumber;
            next();
        } catch (err) {
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

        // Only greet iOS users, and only once per session (skip admin & reconnects)
        const isFirstConnect = !connectedUsers.has(userId);
        connectedUsers.add(userId);

        if (clientType === 'ios') {
            console.log(`✅ IOS connected: ${socket.userName} — iOS: ${iosSockets.size}`);

            if (isFirstConnect) {
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

                // Persist greeting (best-effort — don't block connection)
                prisma.chatMessage.create({
                    data: {
                        userId,
                        direction: 'INCOMING',
                        messageType: 'GREETING',
                        content: { text: greetingText },
                    },
                }).catch(err => console.error('Failed to persist greeting:', err.message));
            }
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

        // NOTE: slack:post handler removed — Slack integration is Phase 3.
        // The iOS app no longer sends this event.

        /**
         * message:send — Client sends a text message.
         */
        socket.on('message:send', async (data) => {
            try {
                const { text, assetId } = data;
                console.log(`💬 Message from ${socket.userName}: ${text}`);

                // Store outgoing message (best-effort — don't let DB failure block reply)
                try {
                    await prisma.chatMessage.create({
                        data: {
                            userId,
                            assetId: assetId || null,
                            direction: 'OUTGOING',
                            messageType: 'TEXT',
                            content: { text },
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

                        // Store reply (best-effort)
                        let replyId;
                        try {
                            const saved = await prisma.chatMessage.create({
                                data: {
                                    userId,
                                    direction: 'INCOMING',
                                    messageType: 'TEXT',
                                    content: { text: replyText },
                                },
                            });
                            replyId = saved.id;
                        } catch (dbErr) {
                            console.error('DB write failed (reply):', dbErr.message);
                        }

                        // Always send reply — shape matches REST /api/messages so iOS can decode
                        socket.emit('message:new', {
                            id: replyId || crypto.randomUUID(),
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
