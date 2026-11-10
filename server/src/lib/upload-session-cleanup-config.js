import { resolveLocalStorageRoot } from './storage/local-driver.js';

export function getUploadSessionCleanupConfig(env = process.env) {
    const enabled = env.UPLOAD_SESSION_CLEANUP_ENABLED ?? 'false';
    if (!['true', 'false'].includes(enabled)) {
        throw new Error('UPLOAD_SESSION_CLEANUP_ENABLED must be true or false');
    }
    if (enabled === 'false') return { enabled: false };
    if ((env.STORAGE_DRIVER || 'local') !== 'local') {
        throw new Error('Upload session cleanup currently requires the local storage driver');
    }
    if (typeof env.STORAGE_LOCAL_ROOT !== 'string' || !env.STORAGE_LOCAL_ROOT) {
        throw new Error('STORAGE_LOCAL_ROOT is required when upload session cleanup is enabled');
    }
    return {
        enabled: true,
        storageRoot: resolveLocalStorageRoot({ root: env.STORAGE_LOCAL_ROOT, production: true }),
    };
}
