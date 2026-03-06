import crypto from 'crypto';

/**
 * Hash a PIN for storage (simple demo auth — NOT production-grade).
 * Uses SHA-256 for simplicity. In production, use bcrypt/argon2.
 */
export function hashPin(pin) {
    return crypto.createHash('sha256').update(pin).digest('hex');
}

/**
 * Verify a PIN against its hash.
 */
export function verifyPin(pin, hash) {
    return hashPin(pin) === hash;
}

/**
 * Generate an incremental 9-digit Mediasource ID from DB sequence.
 * Falls back to random if DB call fails.
 */
export async function generateMediasourceId(prismaClient) {
    try {
        // Ensure sequence exists, then get next value (#12)
        await prismaClient.$executeRawUnsafe(
            `CREATE SEQUENCE IF NOT EXISTS mediasource_id_seq START WITH 100000001 INCREMENT BY 1`
        );
        const result = await prismaClient.$queryRawUnsafe(
            `SELECT nextval('mediasource_id_seq') AS val`
        );
        return result[0]?.val?.toString();
    } catch {
        // Final fallback: random 9-digit
        return Math.floor(100000000 + Math.random() * 900000000).toString();
    }
}

/**
 * Retry a DB operation up to `maxRetries` times on pool timeout errors.
 * Returns the result of the first successful call.
 */
export async function dbRetry(fn, maxRetries = 2) {
    for (let attempt = 0; attempt <= maxRetries; attempt++) {
        try {
            return await fn();
        } catch (err) {
            const isTimeout = err.message?.includes('Connection terminated')
                || err.message?.includes('ECONNREFUSED')
                || err.message?.includes('connection timeout');
            if (!isTimeout || attempt === maxRetries) throw err;
            // Brief pause before retry
            await new Promise(r => setTimeout(r, 200 * (attempt + 1)));
        }
    }
}

/**
 * Parse client-provided metadata from iOS upload into a normalized object.
 * Used by both multipart upload and Mux direct upload routes.
 */
export function parseClientMetadata(raw = {}) {
    return {
        gpsLat: raw.gpsLat ? parseFloat(raw.gpsLat) : null,
        gpsLon: raw.gpsLon ? parseFloat(raw.gpsLon) : null,
        gpsAltitude: raw.gpsAltitude ? parseFloat(raw.gpsAltitude) : null,
        capturedAt: raw.capturedAt ? new Date(raw.capturedAt) : new Date(),
        deviceModel: raw.deviceModel || 'Unknown Device',
        osVersion: raw.osVersion || 'Unknown OS',
        codec: raw.codec || 'Unknown',
        resolution: raw.resolution || 'Unknown',
        orientation: raw.orientation || 'landscape',
        duration: raw.duration ? parseInt(raw.duration, 10) : 0,
    };
}

/**
 * Serialize a Prisma Clip record for JSON — converts BigInt fileSize to string.
 */
export function serializeClip(clip) {
    return {
        ...clip,
        fileSize: clip.fileSize?.toString() || null,
    };
}

/**
 * Send upload-related WebSocket events (upload:complete, message:new, form:request)
 * to all of a user's connected sockets. Consolidates the ~30 lines of emission
 * logic that was duplicated across upload and mux-upload routes.
 *
 * @param {import('socket.io').Server} io - Socket.IO server instance
 * @param {Set<string>|undefined} socketIds - Set of socket IDs for the user
 * @param {object} payload - Event data
 * @param {string} payload.assetId
 * @param {object} payload.asset - { mediasourceId, mediasourceUrl, originalFileName }
 * @param {string} payload.userName
 * @param {object} payload.metadata - Parsed metadata from parseClientMetadata()
 * @param {object} payload.clip - { id, storageUrl?, fileSize, originalFileName }
 * @param {string} payload.messageText - Text for the FORM_REQUEST message
 */
export function notifyUserSockets(io, socketIds, payload) {
    if (!socketIds) return;

    const { assetId, asset, userName, metadata, clip, messageText } = payload;
    const hasRichMeta = metadata.gpsLat
        || metadata.codec !== 'Unknown'
        || metadata.deviceModel !== 'Unknown Device';

    for (const socketId of socketIds) {
        // 1. Upload complete with full metadata
        io.to(socketId).emit('upload:complete', {
            assetId,
            mediasourceId: asset.mediasourceId,
            mediasourceUrl: asset.mediasourceUrl,
            originalFileName: asset.originalFileName,
            userName,
            hasRichMeta,
            metadata,
            clip: {
                id: clip.id,
                storageUrl: clip.storageUrl || undefined,
                fileSize: clip.fileSize,
                originalFileName: asset.originalFileName,
            },
        });

        // 2. Form request chat message
        io.to(socketId).emit('message:new', {
            id: crypto.randomUUID(),
            userId: null,
            assetId,
            direction: 'INCOMING',
            messageType: 'FORM_REQUEST',
            content: {
                text: messageText,
                mediasourceId: asset.mediasourceId,
                mediasourceUrl: asset.mediasourceUrl,
                originalFileName: asset.originalFileName,
                userName,
                clipCount: 1,
                duration: metadata.duration || 0,
                gpsLat: metadata.gpsLat,
                gpsLon: metadata.gpsLon,
                capturedAt: metadata.capturedAt?.toISOString() || null,
                codec: metadata.codec !== 'Unknown' ? metadata.codec : null,
                resolution: metadata.resolution !== 'Unknown' ? metadata.resolution : null,
                hasRichMeta,
            },
            createdAt: new Date().toISOString(),
        });

        // 3. Form request event — opens the form sheet on iOS
        io.to(socketId).emit('form:request', {
            assetId,
            originalFileName: asset.originalFileName,
            capturedAt: metadata.capturedAt,
            clipCount: 1,
            duration: metadata.duration,
            prefilledData: {},
        });
    }
}
