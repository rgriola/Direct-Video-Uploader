/**
 * ImageKit client — handles authentication for client-side (iOS) photo uploads.
 *
 * Pattern mirrors lib/mux.js: server generates auth tokens, iOS uploads directly
 * to ImageKit's CDN, bypassing the server for large file transfers.
 *
 * Requires env vars:
 *   IMAGEKIT_PRIVATE_KEY  — secret key (never sent to client)
 *   IMAGEKIT_URL_ENDPOINT — e.g. https://ik.imagekit.io/rgriola
 */
import ImageKit from '@imagekit/nodejs';

const privateKey = process.env.IMAGEKIT_PRIVATE_KEY;
const urlEndpoint = process.env.IMAGEKIT_URL_ENDPOINT;

export const isImageKitEnabled = !!(privateKey && urlEndpoint);

let client = null;

/**
 * Lazy-init the ImageKit client (same pattern as Mux in lib/mux.js).
 */
function getClient() {
    if (!client) {
        if (!isImageKitEnabled) {
            console.warn('⚠️ ImageKit credentials not configured — photo uploads disabled');
            return null;
        }
        client = new ImageKit({ privateKey });
        console.log('📸 ImageKit client initialized');
    }
    return client;
}

/**
 * Generate authentication parameters for a client-side (iOS) upload.
 * Returns { token, expire, signature } that iOS sends with its upload request.
 *
 * @param {number} [expireSeconds=1800] — token validity in seconds (default 30min)
 * @returns {{ token: string, expire: number, signature: string } | null}
 */
export function getUploadAuthParams(expireSeconds = 1800) {
    const ik = getClient();
    if (!ik) return null;

    return ik.helper.getAuthenticationParameters(undefined, expireSeconds);
}

/**
 * Get the ImageKit URL endpoint for constructing public image URLs.
 */
export function getUrlEndpoint() {
    return urlEndpoint;
}
