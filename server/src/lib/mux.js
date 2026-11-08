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
            playback_policy: ['public'],
            passthrough: JSON.stringify({
                clipId: opts.clipId,
                assetId: opts.assetId,
            }),
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
                passthrough: JSON.stringify({
                    clipId: opts.clipId,
                    assetId: opts.assetId,
                }),
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
        console.error('🎬 Mux asset fetch error:', err.message);
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
        console.error('🎬 Mux upload fetch error:', err.message);
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
        console.error('🎬 Mux asset delete error:', err.message);
        return false;
    }
}

/**
 * Revoke every public playback ID for an asset.
 * A missing Mux asset is already non-playable and is treated as success.
 */
export async function disableMuxPlayback(muxAssetId) {
    if (!muxClient || !muxAssetId) {
        return { ok: false, error: 'Mux is not configured for playback revocation' };
    }

    try {
        const asset = await muxClient.video.assets.retrieve(muxAssetId);
        const playbackIds = (asset.playback_ids || [])
            .filter(playback => playback.policy === 'public')
            .map(playback => playback.id);
        for (const playbackId of playbackIds) {
            await muxClient.video.assets.deletePlaybackId(muxAssetId, playbackId);
        }
        return { ok: true };
    } catch (err) {
        if (err.status === 404) return { ok: true };
        console.error('🎬 Mux playback revocation error:', err.message);
        return { ok: false, error: 'Mux playback revocation failed' };
    }
}

/**
 * Ensure an active, ready Mux asset has a public playback ID.
 * Pending assets receive their public playback ID from Mux when processing completes.
 */
export async function enableMuxPlayback(muxAssetId) {
    if (!muxClient || !muxAssetId) {
        return { ok: false, error: 'Mux is not configured for playback restoration' };
    }

    try {
        const asset = await muxClient.video.assets.retrieve(muxAssetId);
        const publicPlayback = asset.playback_ids?.find(playback => playback.policy === 'public');
        if (publicPlayback) return { ok: true, playbackId: publicPlayback.id };
        if (asset.status !== 'ready') return { ok: true, playbackId: null, pending: true };

        const playback = await muxClient.video.assets.createPlaybackId(muxAssetId, { policy: 'public' });
        return { ok: true, playbackId: playback.id };
    } catch (err) {
        console.error('🎬 Mux playback restoration error:', err.message);
        return { ok: false, error: 'Mux playback restoration failed' };
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
        console.error('🎬 Mux list assets error:', err.message);
        return null;
    }
}
