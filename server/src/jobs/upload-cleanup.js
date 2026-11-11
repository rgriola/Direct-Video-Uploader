// Last updated: May 9, 2026 - 7:22pm - GPT-5.3-Codex
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
import { cleanupEligibleUploadModes } from '../lib/upload-intents.js';
import { withAssetMediaLock } from '../lib/media-lock.js';
import { localUploadPath, removeLocalUpload } from '../lib/local-media.js';
import * as slack from '../lib/slack.js';
import { redactPersonName } from '../lib/redact.js';
import { notifyDashboardAssetChange } from '../ws/dashboard-notifications.js';
import fs from 'fs/promises';

const CLEANUP_INTERVAL_MS = 5 * 60 * 1000;   // 5 minutes
const ORPHAN_THRESHOLD_MS = 60 * 60 * 1000;  // 1 hour
let intervalId = null;
let cleanupLog = null;

/**
 * Find and clean up orphaned UPLOADING assets.
 */
export async function cleanupOrphanedUploads(fastify, { fileSystem = fs } = {}) {
    const log = fastify?.log ?? null;
    try {
        const now = Date.now();
        const cutoff = new Date(now - ORPHAN_THRESHOLD_MS);
        const eligibleMode = cleanupEligibleUploadModes(now);

        const orphanedAssets = await dbRetry(() => prisma.asset.findMany({
            where: {
                status: 'UPLOADING',
                moderation: 'ACTIVE',
                createdAt: { lt: cutoff },
                uploadSessions: { none: {} },
                NOT: { originalUploadIntent: { is: { cancelledAt: { not: null } } } },
                ...eligibleMode,
            },
            select: { id: true },
        }));

        if (orphanedAssets.length === 0) return;

        log?.info({ orphanedCount: orphanedAssets.length }, 'Upload cleanup found orphaned uploading assets');

        for (const candidate of orphanedAssets) {
            let asset;
            try {
                const locked = await withAssetMediaLock(candidate.id, async assertLocked => {
                    return prisma.$transaction(async tx => {
                        await tx.$queryRaw`SELECT id FROM assets WHERE id = ${candidate.id} FOR UPDATE`;
                        const current = await tx.asset.findFirst({
                            where: {
                                id: candidate.id,
                                status: 'UPLOADING',
                                moderation: 'ACTIVE',
                                mediaPlaybackReset: false,
                                mediaCreateOperationId: null,
                                createdAt: { lt: cutoff },
                                uploadSessions: { none: {} },
                                NOT: { originalUploadIntent: { is: { cancelledAt: { not: null } } } },
                                ...eligibleMode,
                            },
                            include: {
                                clips: { select: { id: true, storageUrl: true } },
                                user: { select: { name: true } },
                            },
                        });
                        if (!current) return null;

                        for (const clip of current.clips) {
                            const filePath = localUploadPath(clip.storageUrl);
                            if (!filePath) continue;
                            await assertLocked();
                            await removeLocalUpload(tx, clip, fileSystem);
                            await tx.clip.updateMany({
                                where: { id: clip.id, assetId: current.id, storageUrl: clip.storageUrl },
                                data: { storageUrl: null },
                            });
                        }

                        await tx.asset.update({ where: { id: current.id }, data: { status: 'ERROR' } });
                        return current;
                    }, { timeout: 30000, isolationLevel: 'ReadCommitted' });
                });
                if (!locked.acquired || !locked.value) continue;
                asset = locked.value;
            } catch (err) {
                log?.error({ assetId: candidate.id, err: { message: err.message } }, 'Could not clean orphaned upload');
                continue;
            }

            const ageMin = Math.round((Date.now() - new Date(asset.createdAt).getTime()) / 60000);
            const redactedUserName = redactPersonName(asset.user?.name) || 'unknown';

            await notifyDashboardAssetChange(fastify, asset.id);

            log?.warn(
                {
                    mediasourceId: asset.mediasourceId,
                    ageMinutes: ageMin,
                    userName: redactedUserName,
                },
                'Marked orphaned uploading asset as error'
            );

            // Alert via Slack
            if (slack.isConfigured()) {
                const alert = await slack.postToChannel('general',
                    `🧹 Orphaned upload cleaned up — #${asset.mediasourceId} was stuck in UPLOADING for ${ageMin}min (user: ${redactedUserName})`,
                    undefined,
                    { requestId: 'job:upload-cleanup' }
                );
                if (!alert.ok) log?.error({ assetId: asset.id }, 'Could not send orphaned upload alert');
            }
        }
    } catch (err) {
        log?.error({ err: { message: err.message } }, 'Upload cleanup job failed');
    }
}

/**
 * Start the periodic cleanup job.
 */
export function startUploadCleanup(fastify) {
    if (intervalId) return;
    cleanupLog = fastify?.log ?? null;
    cleanupLog?.info(
        { intervalMinutes: 5, orphanThresholdMinutes: 60 },
        'Upload cleanup worker started'
    );
    intervalId = setInterval(() => cleanupOrphanedUploads(fastify), CLEANUP_INTERVAL_MS);
    // Run once immediately on startup
    cleanupOrphanedUploads(fastify);
}

/**
 * Stop the cleanup job.
 */
export function stopUploadCleanup() {
    if (intervalId) {
        clearInterval(intervalId);
        intervalId = null;
        cleanupLog?.info('Upload cleanup worker stopped');
    }
}
