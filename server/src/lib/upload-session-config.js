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
    return {
        enabled: true,
        signingSecret,
        storageDriver: env.STORAGE_DRIVER || 'local',
    };
}
