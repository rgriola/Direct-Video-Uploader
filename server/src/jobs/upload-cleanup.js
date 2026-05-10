// Last updated: May 9, 2026 - 6:40pm - GPT-5.3-Codex
/**
 * Upload Cleanup — Background Job (B4)
 *
 * Periodically checks for assets stuck in UPLOADING state and marks
 * them as ERROR. Cleans up partial files from the uploads directory.
 * Alerts via Slack when orphaned uploads are found.
 *
 * Runs every 5 minutes. An upload is "orphaned" if it's been in
 * UPLOADING state for more than 1 hour.
 */
import prisma from '../lib/prisma.js';
import { dbRetry } from '../lib/utils.js';
import * as slack from '../lib/slack.js';
import { redactPersonName } from '../lib/redact.js';
import fs from 'fs/promises';
import path from 'path';

const CLEANUP_INTERVAL_MS = 5 * 60 * 1000;   // 5 minutes
const ORPHAN_THRESHOLD_MS = 60 * 60 * 1000;  // 1 hour
let intervalId = null;

/**
 * Find and clean up orphaned UPLOADING assets.
 */
async function cleanupOrphanedUploads() {
    try {
        const cutoff = new Date(Date.now() - ORPHAN_THRESHOLD_MS);

        const orphanedAssets = await dbRetry(() => prisma.asset.findMany({
            where: {
                status: 'UPLOADING',
                createdAt: { lt: cutoff },
            },
            include: {
                clips: { select: { id: true, storageUrl: true } },
                user: { select: { name: true } },
            },
        }));

        if (orphanedAssets.length === 0) return;

        console.log(`🧹 Upload cleanup: found ${orphanedAssets.length} orphaned UPLOADING asset(s)`);

        for (const asset of orphanedAssets) {
            const ageMin = Math.round((Date.now() - new Date(asset.createdAt).getTime()) / 60000);
            const redactedUserName = redactPersonName(asset.user?.name) || 'unknown';

            // Clean up partial upload files
            for (const clip of asset.clips) {
                if (clip.storageUrl) {
                    const filePath = path.resolve(process.cwd(), clip.storageUrl.replace(/^\//, ''));
                    try {
                        await fs.unlink(filePath);
                        console.log(`🧹 Deleted orphaned file: ${filePath}`);
                    } catch {
                        // File may not exist — that's fine
                    }
                }
            }

            // Mark asset as ERROR
            await dbRetry(() => prisma.asset.update({
                where: { id: asset.id },
                data: { status: 'ERROR' },
            }));

            console.log(`🧹 Marked asset ${asset.mediasourceId} as ERROR (stuck ${ageMin}min, user: ${redactedUserName})`);

            // Alert via Slack
            if (slack.isConfigured()) {
                await slack.postToChannel('general',
                    `🧹 Orphaned upload cleaned up — #${asset.mediasourceId} was stuck in UPLOADING for ${ageMin}min (user: ${redactedUserName})`,
                    undefined,
                    { requestId: 'job:upload-cleanup' }
                );
            }
        }
    } catch (err) {
        console.error('🧹 Upload cleanup error:', err.message);
    }
}

/**
 * Start the periodic cleanup job.
 */
export function startUploadCleanup() {
    if (intervalId) return;
    console.log('🧹 Upload cleanup job started (every 5 min, orphan threshold: 1 hour)');
    intervalId = setInterval(cleanupOrphanedUploads, CLEANUP_INTERVAL_MS);
    // Run once immediately on startup
    cleanupOrphanedUploads();
}

/**
 * Stop the cleanup job.
 */
export function stopUploadCleanup() {
    if (intervalId) {
        clearInterval(intervalId);
        intervalId = null;
    }
}
