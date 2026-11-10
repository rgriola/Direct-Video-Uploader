const DEFAULT_READ_TTL_SECONDS = 60 * 60;
const MIN_READ_TTL_SECONDS = 5 * 60;
const MAX_READ_TTL_SECONDS = 24 * 60 * 60;

export function getMuxOriginalConfig(env = process.env) {
    const enabled = env.MUX_ORIGINAL_INGEST_ENABLED || 'false';
    if (!['true', 'false'].includes(enabled)) {
        throw new Error('MUX_ORIGINAL_INGEST_ENABLED must be true or false');
    }
    if (enabled === 'false') return { enabled: false };
    if (env.UPLOAD_SESSIONS_ENABLED !== 'true') {
        throw new Error('MUX_ORIGINAL_INGEST_ENABLED requires UPLOAD_SESSIONS_ENABLED');
    }
    if (env.DEBUG === 'true') {
        throw new Error('DEBUG=true exposes signed URLs through the Mux SDK and cannot be used with original ingest');
    }
    for (const name of ['MUX_TOKEN_ID', 'MUX_TOKEN_SECRET', 'MUX_WEBHOOK_SECRET']) {
        if (typeof env[name] !== 'string' || !env[name].trim()) {
            throw new Error(`${name} is required for original Mux ingest`);
        }
    }

    const signingSecret = env.MUX_ORIGINAL_READ_SIGNING_SECRET;
    if (typeof signingSecret !== 'string' || Buffer.byteLength(signingSecret) < 32) {
        throw new Error('MUX_ORIGINAL_READ_SIGNING_SECRET must contain at least 32 bytes');
    }
    if (signingSecret === env.JWT_SECRET || signingSecret === env.UPLOAD_SESSION_SIGNING_SECRET) {
        throw new Error('MUX_ORIGINAL_READ_SIGNING_SECRET must differ from other signing secrets');
    }

    let origin;
    try {
        origin = new URL(env.MUX_ORIGINAL_READ_BASE_URL);
    } catch {
        throw new Error('MUX_ORIGINAL_READ_BASE_URL must be an absolute HTTPS origin');
    }
    const localHttp = env.NODE_ENV !== 'production'
        && origin.protocol === 'http:'
        && ['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname);
    if ((!localHttp && origin.protocol !== 'https:')
        || origin.username || origin.password || origin.pathname !== '/'
        || origin.search || origin.hash) {
        throw new Error('MUX_ORIGINAL_READ_BASE_URL must be an absolute HTTPS origin');
    }

    const rawTtl = env.MUX_ORIGINAL_READ_TTL_SECONDS ?? String(DEFAULT_READ_TTL_SECONDS);
    const ttlSeconds = typeof rawTtl === 'string' && /^\d{1,5}$/.test(rawTtl)
        ? Number(rawTtl)
        : NaN;
    if (!Number.isSafeInteger(ttlSeconds)
        || ttlSeconds < MIN_READ_TTL_SECONDS || ttlSeconds > MAX_READ_TTL_SECONDS) {
        throw new Error(`MUX_ORIGINAL_READ_TTL_SECONDS must be between ${MIN_READ_TTL_SECONDS} and ${MAX_READ_TTL_SECONDS}`);
    }

    return {
        enabled: true,
        baseUrl: origin.origin,
        signingSecret,
        readTtlMs: ttlSeconds * 1000,
    };
}
