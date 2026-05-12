// Last updated: May 12, 2026 - 4:39pm - GitHub Copilot (GPT-5.3-Codex)
/**
 * Mux Video Integration
 *
 * Handles video ingestion via Mux's direct upload flow:
 * 1. After saving to local disk, create a Mux direct upload URL
 * 2. Upload the file to Mux
 * 3. Mux processes → webhook notifies us → we update the clip record with playback IDs
 *
 * Environment variables:
 *   MUX_TOKEN_ID       — API Access Token ID
 *   MUX_TOKEN_SECRET   — API Access Token Secret
 *   MUX_ENV_KEY        — Environment Key (for client-side Mux Player)
 *   MUX_WEBHOOK_SECRET — Webhook signing secret (optional, for signature verification)
 */
import Mux from '@mux/mux-node';
import { createReadStream } from 'fs';
import { stat } from 'fs/promises';

const MUX_TOKEN_ID = process.env.MUX_TOKEN_ID;
const MUX_TOKEN_SECRET = process.env.MUX_TOKEN_SECRET;
export const MUX_ENV_KEY = process.env.MUX_ENV_KEY || '';
const MAX_MUX_PASSTHROUGH_LENGTH = 255;
const MAX_TELEMETRY_CORRELATION_ID_LENGTH = 48;

/** Whether Mux is configured (has API credentials). */
export const isMuxEnabled = !!(MUX_TOKEN_ID && MUX_TOKEN_SECRET);

function buildMuxPassthrough(opts = {}) {
    const passthrough = {
        clipId: opts.clipId,
        assetId: opts.assetId,
    };

    if (opts.passthrough && typeof opts.passthrough === 'object') {
        for (const [key, value] of Object.entries(opts.passthrough)) {
            if (value !== undefined && value !== null) {
                passthrough[key] = value;
            }
        }
    }

    return passthrough;
}

function stringifyMuxPassthrough(opts = {}) {
    const passthrough = buildMuxPassthrough(opts);

    // Mux enforces a 255-char passthrough limit. Keep ms precision field and
    // drop duplicate ISO timestamp to preserve room for correlation metadata.
    if (passthrough.serverUploadCreatedAt !== undefined) {
        delete passthrough.serverUploadCreatedAt;
    }

    if (passthrough.telemetryCorrelationId !== undefined && passthrough.telemetryCorrelationId !== null) {
        passthrough.telemetryCorrelationId = String(passthrough.telemetryCorrelationId)
            .slice(0, MAX_TELEMETRY_CORRELATION_ID_LENGTH);
    }

    let serialized = JSON.stringify(passthrough);
    if (serialized.length <= MAX_MUX_PASSTHROUGH_LENGTH) {
        return serialized;
    }

    const reduced = {
        clipId: passthrough.clipId,
        assetId: passthrough.assetId,
        telemetryCorrelationId: passthrough.telemetryCorrelationId,
    };
    serialized = JSON.stringify(reduced);
    if (serialized.length <= MAX_MUX_PASSTHROUGH_LENGTH) {
        return serialized;
    }

    return JSON.stringify({
        clipId: String(passthrough.clipId || '').slice(0, 64),
        assetId: String(passthrough.assetId || '').slice(0, 64),
    });
}

let muxClient = null;
const shouldLogMuxStartup = process.env.NODE_ENV !== 'test';

if (isMuxEnabled) {
    muxClient = new Mux({
        tokenId: MUX_TOKEN_ID,
        tokenSecret: MUX_TOKEN_SECRET,
    });
    if (shouldLogMuxStartup) {
        console.log({ event: 'mux.integration.enabled' });
    }
} else {
    if (shouldLogMuxStartup) {
        console.log({ event: 'mux.integration.disabled' });
    }
}

/**
 * Create a Mux direct upload URL for iOS to upload to directly.
 * Returns the upload URL and upload ID. iOS PUTs the video file to this URL.
 *
 * @param {object} opts
 * @param {string} opts.clipId — Our clip ID
 * @param {string} opts.assetId — Our asset ID
 * @param {Record<string, unknown>} [opts.passthrough] — Additional passthrough metadata for webhook correlation
 * @returns {Promise<{uploadUrl: string, muxUploadId: string} | null>}
 */
export async function createDirectUpload(opts = {}) {
    if (!isMuxEnabled || !muxClient) {
        return null;
    }

    const upload = await muxClient.video.uploads.create({
        new_asset_settings: {
            playback_policy: ['public'],
            passthrough: stringifyMuxPassthrough(opts),
        },
        cors_origin: '*',
        timeout: 3600, // 1 hour expiry for the upload URL
    });

    return {
        uploadUrl: upload.url,
        muxUploadId: upload.id,
    };
}

/**
 * Ingest a local video file into Mux.
 *
 * Flow:
 * 1. Create an Asset with input URL (via direct upload)
 * 2. Upload the file bytes to the upload URL
 * 3. Return the Mux asset ID (playback ID comes later via webhook)
 *
 * @param {string} filePath — Absolute path to the local video file
 * @param {object} opts — Optional metadata
 * @param {string} opts.clipId — Our clip ID (stored as passthrough for webhook)
 * @param {string} opts.assetId — Our asset ID
 * @param {Record<string, unknown>} [opts.passthrough] — Additional passthrough metadata for webhook correlation
 * @returns {Promise<{muxAssetId: string, muxUploadId: string} | null>}
 */
export async function ingestVideo(filePath, opts = {}) {
    if (!isMuxEnabled || !muxClient) {
        return null;
    }

    try {
        // Create a direct upload — Mux gives us a PUT URL
        const upload = await muxClient.video.uploads.create({
            new_asset_settings: {
                playback_policy: ['public'],
                // passthrough lets us correlate webhook events back to our clip
                passthrough: stringifyMuxPassthrough(opts),
            },
            cors_origin: '*',
        });

        // Upload the file to Mux's upload URL
        const fileStats = await stat(filePath);
        const fileStream = createReadStream(filePath);

        const response = await fetch(upload.url, {
            method: 'PUT',
            headers: {
                'Content-Length': fileStats.size.toString(),
                'Content-Type': 'application/octet-stream',
            },
            body: fileStream,
            duplex: 'half',
        });

        if (!response.ok) {
            console.error({
                event: 'mux.upload.failed',
                statusCode: response.status,
                responseBody: await response.text(),
            });
            return null;
        }

        console.log({
            event: 'mux.upload.started',
            muxUploadId: upload.id,
        });

        return {
            muxUploadId: upload.id,
            muxAssetId: null, // Asset ID comes when Mux processes the upload
        };
    } catch (err) {
        console.error({ event: 'mux.ingest.error', message: err.message });
        return null;
    }
}

/**
 * Get Mux asset details (for checking status, getting playback IDs).
 * @param {string} muxAssetId
 */
export async function getMuxAsset(muxAssetId) {
    if (!muxClient) return null;
    try {
        return await muxClient.video.assets.retrieve(muxAssetId);
    } catch (err) {
        console.error({ event: 'mux.asset.fetch.error', message: err.message, muxAssetId });
        return null;
    }
}

/**
 * Get the upload object to check its status and get the asset_id once processing is done.
 * @param {string} muxUploadId
 */
export async function getMuxUpload(muxUploadId) {
    if (!muxClient) return null;
    try {
        return await muxClient.video.uploads.retrieve(muxUploadId);
    } catch (err) {
        console.error({ event: 'mux.upload.fetch.error', message: err.message, muxUploadId });
        return null;
    }
}

/**
 * Delete a Mux asset by ID.
 * @param {string} muxAssetId
 * @returns {Promise<boolean>} true if deleted, false on error or not configured
 */
export async function deleteMuxAsset(muxAssetId) {
    if (!muxClient || !muxAssetId) return false;
    try {
        await muxClient.video.assets.delete(muxAssetId);
        return true;
    } catch (err) {
        // 404 = already gone, treat as success
        if (err.status === 404) return true;
        console.error({ event: 'mux.asset.delete.error', message: err.message, muxAssetId });
        return false;
    }
}

/**
 * List all Mux assets (paginated, returns first page).
 * Used by nuclear reset to catch orphaned assets.
 * @returns {Promise<Array|null>}
 */
export async function listMuxAssets() {
    if (!muxClient) return null;
    try {
        const page = await muxClient.video.assets.list({ limit: 100 });
        return page.data || [];
    } catch (err) {
        console.error({ event: 'mux.assets.list.error', message: err.message });
        return null;
    }
}
