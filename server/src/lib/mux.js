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
