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
 * Generate a short slug from a string.
 * e.g., "Santana Standup" → "santana-standup"
 */
export function generateSlug(name) {
    const base = name
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-|-$/g, '');
    const suffix = crypto.randomBytes(3).toString('hex');
    return `${base}-${suffix}`;
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
