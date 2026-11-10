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
const CONTROL_REQUEST_OPTIONS = { timeout: 15_000, maxRetries: 0 };

function muxErrorSummary(error) {
    return Number.isInteger(error?.status) ? `HTTP ${error.status}` : 'request failed';
}

/** Whether Mux is configured (has API credentials). */
export const isMuxEnabled = !!(MUX_TOKEN_ID && MUX_TOKEN_SECRET);

let muxClient = null;

if (isMuxEnabled) {
    muxClient = new Mux({
        tokenId: MUX_TOKEN_ID,
        tokenSecret: MUX_TOKEN_SECRET,
    });
    console.log('🎬 Mux Video integration enabled');
} else {
    console.log('⏭️  Mux Video not configured — videos will be served locally');
}

/**
 * Create a Mux direct upload URL for iOS to upload to directly.
 * Returns the upload URL and upload ID. iOS PUTs the video file to this URL.
 *
 * @param {object} opts
 * @param {string} opts.clipId — Our clip ID
 * @param {string} opts.assetId — Our asset ID
 * @returns {Promise<{uploadUrl: string, muxUploadId: string} | null>}
 */
export async function createDirectUpload(opts = {}) {
    if (!isMuxEnabled || !muxClient) {
        return null;
    }

    const upload = await muxClient.video.uploads.create({
        new_asset_settings: {
            passthrough: JSON.stringify({
                clipId: opts.clipId,
                assetId: opts.assetId,
            }),
        },
        cors_origin: '*',
        timeout: 3600, // 1 hour expiry for the upload URL
    }, CONTROL_REQUEST_OPTIONS);

    if (typeof upload?.id !== 'string' || !upload.id || typeof upload.url !== 'string' || !upload.url) {
        throw new Error('Mux upload creation returned an invalid response');
    }

    return {
        uploadUrl: upload.url,
        muxUploadId: upload.id,
    };
}

export async function createMuxOriginalAsset({ sourceUrl, assetId, clipId, operationId }) {
    if (!muxClient) {
        return { ok: false, indeterminate: false, retryable: false, error: 'Mux asset creation is not configured' };
    }
    try {
        const asset = await muxClient.video.assets.create({
            inputs: [{ url: sourceUrl }],
            passthrough: JSON.stringify({ assetId, clipId, ingestOperationId: operationId }),
        }, CONTROL_REQUEST_OPTIONS);
        if (typeof asset?.id !== 'string' || !asset.id) {
            return { ok: false, indeterminate: true, retryable: false, error: 'Mux asset creation outcome is unknown' };
        }
        return { ok: true, muxAssetId: asset.id };
    } catch (error) {
        const status = error?.status;
        if (status === 429) {
            return { ok: false, indeterminate: false, retryable: true, error: 'Mux rate limited asset creation' };
        }
        return { ok: false, indeterminate: true, retryable: false, error: 'Mux asset creation outcome is unknown' };
    }
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
                // passthrough lets us correlate webhook events back to our clip
                passthrough: JSON.stringify({
                    clipId: opts.clipId,
                    assetId: opts.assetId,
                }),
            },
            cors_origin: '*',
        }, CONTROL_REQUEST_OPTIONS);

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
            console.error('🎬 Mux upload failed:', response.status, await response.text());
            return null;
        }

        console.log(`🎬 Mux upload started: uploadId=${upload.id}`);

        return {
            muxUploadId: upload.id,
            muxAssetId: null, // Asset ID comes when Mux processes the upload
        };
    } catch (err) {
        console.error('🎬 Mux ingest error:', err.message);
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
        console.error('🎬 Mux asset fetch error:', muxErrorSummary(err));
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
        return await muxClient.video.uploads.retrieve(muxUploadId, CONTROL_REQUEST_OPTIONS);
    } catch (err) {
        console.error('🎬 Mux upload fetch error:', err.message);
        return null;
    }
}

export async function inspectMuxAsset(muxAssetId) {
    if (!muxClient || !muxAssetId) {
        return { ok: false, error: 'Mux asset inspection is not configured' };
    }

    try {
        const asset = await muxClient.video.assets.retrieve(muxAssetId, CONTROL_REQUEST_OPTIONS);
        if (!asset || typeof asset.status !== 'string'
            || (asset.playback_ids != null && (
                !Array.isArray(asset.playback_ids)
                || asset.playback_ids.some(playback =>
                    typeof playback?.id !== 'string' || !playback.id
                    || typeof playback.policy !== 'string' || !playback.policy)
            ))) {
            console.error('🎬 Mux asset inspection returned an invalid response');
            return { ok: false, error: 'Mux asset inspection returned an invalid response' };
        }
        return { ok: true, asset };
    } catch (err) {
        if (err.status === 404) return { ok: true, asset: null };
        console.error('🎬 Mux asset inspection error:', muxErrorSummary(err));
        return { ok: false, error: 'Mux asset inspection failed' };
    }
}

export async function inspectMuxUpload(muxUploadId) {
    if (!muxClient || !muxUploadId) {
        return { ok: false, error: 'Mux upload inspection is not configured' };
    }

    try {
        const upload = await muxClient.video.uploads.retrieve(muxUploadId, CONTROL_REQUEST_OPTIONS);
        if (!upload || typeof upload.status !== 'string') {
            console.error('🎬 Mux upload inspection returned an invalid response');
            return { ok: false, error: 'Mux upload inspection returned an invalid response' };
        }
        return { ok: true, upload };
    } catch (err) {
        console.error('🎬 Mux upload inspection error:', err.message);
        return { ok: false, error: 'Mux upload inspection failed' };
    }
}

export async function cancelMuxUpload(muxUploadId) {
    if (!muxClient || !muxUploadId) {
        return { ok: false, error: 'Mux upload cancellation is not configured' };
    }

    try {
        const upload = await muxClient.video.uploads.cancel(muxUploadId, CONTROL_REQUEST_OPTIONS);
        if (upload?.status !== 'cancelled') {
            console.error('🎬 Mux upload cancellation was not confirmed');
            return { ok: false, error: 'Mux upload cancellation was not confirmed' };
        }
        return { ok: true };
    } catch (err) {
        console.error('🎬 Mux upload cancellation error:', err.message);
        return { ok: false, error: 'Mux upload cancellation failed' };
    }
}

export async function createMuxPublicPlayback(muxAssetId) {
    if (!muxClient || !muxAssetId) {
        return { ok: false, indeterminate: false, error: 'Mux playback creation is not configured' };
    }

    try {
        const playback = await muxClient.video.assets.createPlaybackId(
            muxAssetId,
            { policy: 'public' },
            CONTROL_REQUEST_OPTIONS,
        );
        if (typeof playback?.id !== 'string' || !playback.id || playback.policy !== 'public') {
            console.error('🎬 Mux playback creation returned an invalid response');
            return { ok: false, indeterminate: true, error: 'Mux playback creation outcome is unknown' };
        }
        return { ok: true, playbackId: playback.id };
    } catch (err) {
        const status = err?.status;
        const rejected = Number.isInteger(status) && status >= 400 && status < 500
            && status !== 408 && status !== 429;
        console.error('🎬 Mux playback creation error:', muxErrorSummary(err));
        return {
            ok: false,
            indeterminate: !rejected,
            error: rejected ? 'Mux playback creation was rejected' : 'Mux playback creation outcome is unknown',
        };
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
        await muxClient.video.assets.delete(muxAssetId, CONTROL_REQUEST_OPTIONS);
        return true;
    } catch (err) {
        // 404 = already gone, treat as success
        if (err.status === 404) return true;
        console.error('🎬 Mux asset delete error:', muxErrorSummary(err));
        return false;
    }
}

/**
 * Revoke every public playback ID for an asset.
 * A missing Mux asset is already non-playable and is treated as success.
 */
export async function disableMuxPlayback(muxAssetId, assertLocked = async () => {}) {
    if (!muxClient || !muxAssetId) {
        return { ok: false, error: 'Mux is not configured for playback revocation' };
    }

    const inspection = await inspectMuxAsset(muxAssetId);
    await assertLocked();
    if (!inspection.ok) return { ok: false, error: 'Mux playback revocation failed' };
    if (!inspection.asset) return { ok: true };

    const playbackIds = (inspection.asset.playback_ids || [])
        .filter(playback => playback.policy === 'public')
        .map(playback => playback.id);
    for (const playbackId of playbackIds) {
        await assertLocked();
        try {
            await muxClient.video.assets.deletePlaybackId(muxAssetId, playbackId, CONTROL_REQUEST_OPTIONS);
        } catch (err) {
            if (err.status !== 404) {
                console.error('🎬 Mux playback revocation error:', muxErrorSummary(err));
            }
        }
    }

    await assertLocked();
    const current = await inspectMuxAsset(muxAssetId);
    await assertLocked();
    if (!current.ok) {
        return { ok: false, error: 'Mux playback revocation failed' };
    }
    if (current.asset?.playback_ids?.some(playback => playback.policy === 'public')) {
        return { ok: false, error: 'Mux still has public playback IDs' };
    }
    return { ok: true };
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
        console.error('🎬 Mux list assets error:', muxErrorSummary(err));
        return null;
    }
}
