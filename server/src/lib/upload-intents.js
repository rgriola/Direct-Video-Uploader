import { SESSION_TTL_MS } from './upload-sessions.js';

export function cleanupEligibleUploadModes(now = Date.now()) {
    return {
        OR: [
            { uploadMode: null },
            { uploadMode: 'MUX' },
            { uploadMode: 'ORIGINAL', createdAt: { lt: new Date(now - SESSION_TTL_MS) } },
        ],
    };
}
