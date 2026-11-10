const MAX_DATABASE_BIGINT = 9_223_372_036_854_775_807n;

function requiredByteLimit(env, name) {
    const value = env[name];
    if (typeof value !== 'string' || !/^\d{1,19}$/.test(value)) {
        throw new Error(`${name} must be a positive number of bytes`);
    }
    const bytes = BigInt(value);
    if (bytes < 1n || bytes > MAX_DATABASE_BIGINT) {
        throw new Error(`${name} must be a positive number of bytes within the supported range`);
    }
    return bytes;
}

export function getUploadSessionConfig(env = process.env) {
    const enabled = env.UPLOAD_SESSIONS_ENABLED || 'false';
    if (!['true', 'false'].includes(enabled)) {
        throw new Error('UPLOAD_SESSIONS_ENABLED must be true or false');
    }
    if (enabled === 'false') return { enabled: false };

    const signingSecret = env.UPLOAD_SESSION_SIGNING_SECRET;
    if (typeof signingSecret !== 'string' || Buffer.byteLength(signingSecret) < 32) {
        throw new Error('UPLOAD_SESSION_SIGNING_SECRET must contain at least 32 bytes');
    }
    if (signingSecret === env.JWT_SECRET) {
        throw new Error('UPLOAD_SESSION_SIGNING_SECRET must differ from JWT_SECRET');
    }
    const storageDriver = env.STORAGE_DRIVER || 'local';
    if (storageDriver !== 'local') {
        throw new Error('Upload capacity safeguards currently require the local storage driver');
    }
    return {
        enabled: true,
        signingSecret,
        storageDriver,
        maxStorageBytes: requiredByteLimit(env, 'UPLOAD_STORAGE_MAX_BYTES'),
        minFreeBytes: requiredByteLimit(env, 'UPLOAD_STORAGE_MIN_FREE_BYTES'),
    };
}
