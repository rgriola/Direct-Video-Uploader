import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import prisma from './prisma.js';
import * as mux from './mux.js';
import { withAssetMediaLock } from './media-lock.js';
import { LocalMediaError, localUploadPath, removeLocalUpload } from './local-media.js';
import { createStorageDriver } from './storage/driver.js';
import { StorageError } from './storage/local-driver.js';
import { releaseStorageReservation } from './storage/capacity.js';
import * as slack from './slack.js';
import { notifyDashboardAssetChange } from '../ws/dashboard-notifications.js';
import { userRoom } from '../ws/rooms.js';

const RETRY_INTERVAL_MS = 2 * 60 * 1000;
const UNKNOWN_CREATE = 'Mux playback creation outcome is unknown; Super Admin confirmation is required';
const UNKNOWN_ORIGINAL = 'Mux original ingest outcome is unknown; Super Admin confirmation is required';
const CONFLICTING_ORIGINAL = 'Mux original ingest references require manual reconciliation';

export async function queueAssetMediaSync(db, assetId, { resetPlayback = false } = {}) {
    return db.asset.updateMany({
        where: { id: assetId },
        data: {
            mediaSyncState: 'PENDING',
            mediaSyncError: null,
            mediaSyncRevision: { increment: 1 },
            mediaSyncNextAt: new Date(),
            ...(resetPlayback ? { mediaPlaybackReset: true } : {}),
        },
    });
}

export async function recordMuxAssetReference(db, { assetId, clipId = null, muxAssetId }) {
    if (!assetId || !muxAssetId) throw new TypeError('Asset and Mux asset IDs are required');
    const reference = await db.muxAssetReference.upsert({
        where: { muxAssetId },
        create: { muxAssetId, assetId, clipId },
        update: {},
    });
    if (reference.assetId !== assetId) {
        throw new Error('Mux asset is already associated with another asset');
    }
    if (!reference.clipId && clipId) {
        await db.muxAssetReference.updateMany({
            where: { muxAssetId, assetId, clipId: null },
            data: { clipId },
        });
    }
}

export function createMediaReconciler({
    db,
    muxApi,
    withLock,
    fileSystem = fs,
    clock = () => new Date(),
    storageFactory = createStorageDriver,
}) {
    async function setResult(asset, state, message) {
        const nextAt = state === 'SYNCED' && asset.moderation === 'ACTIVE'
            ? null
            : new Date(clock().getTime() + RETRY_INTERVAL_MS);
        const updated = await db.asset.updateMany({
            where: {
                id: asset.id,
                mediaSyncRevision: asset.mediaSyncRevision,
                ...(state === 'SYNCED' ? { mediaCreateOperationId: null } : {}),
            },
            data: {
                mediaSyncState: state,
                mediaSyncError: state === 'ERROR' ? message : null,
                mediaSyncNextAt: nextAt,
            },
        });
        if (updated.count !== 1) {
            return { state: 'PENDING', message: 'Media state changed; reconciliation will retry' };
        }
        return { state, message };
    }

    async function inspectLocalFile(clip, remove, log) {
        let filePath;
        try {
            filePath = localUploadPath(clip.storageUrl);
        } catch (err) {
            log.error({ clipId: clip.id, err: { message: err.message } }, 'Invalid local media path');
            return { ok: false, error: err instanceof LocalMediaError ? err.message : 'Could not verify local media' };
        }
        if (!filePath) return { ok: true, exists: false };

        try {
            if (remove) {
                await removeLocalUpload(db, clip, fileSystem);
                return { ok: true, exists: false };
            }
            await fileSystem.stat(filePath);
            return { ok: true, exists: true };
        } catch (err) {
            if (err.code === 'ENOENT') return { ok: true, exists: false };
            log.error({ clipId: clip.id, err: { message: err.message } }, 'Could not inspect local media');
            return { ok: false, error: err instanceof LocalMediaError ? err.message : 'Could not verify local media' };
        }
    }

    async function inspectClip(asset, clip, log, assertLocked) {
        const ids = new Set([
            ...(clip.muxAssetId ? [clip.muxAssetId] : []),
            ...asset.muxAssetReferences
                .filter(reference => reference.clipId === clip.id)
                .map(reference => reference.muxAssetId),
        ]);
        let pending = false;
        const errors = [];

        if (clip.muxUploadId) {
            const result = await muxApi.inspectMuxUpload(clip.muxUploadId);
            if (!result.ok) {
                errors.push(result.error);
            } else if (result.upload.status === 'waiting') {
                if (asset.moderation === 'REMOVED') {
                    await assertLocked();
                    const cancelled = await muxApi.cancelMuxUpload(clip.muxUploadId);
                    if (!cancelled.ok) errors.push(cancelled.error);
                } else {
                    pending = true;
                }
            } else if (result.upload.status === 'asset_created') {
                const uploadAssetId = result.upload.asset_id;
                if (typeof uploadAssetId !== 'string' || !uploadAssetId) {
                    errors.push('Mux upload has no associated asset ID');
                } else {
                    ids.add(uploadAssetId);
                    await recordMuxAssetReference(db, {
                        assetId: asset.id,
                        clipId: clip.id,
                        muxAssetId: uploadAssetId,
                    });
                    if (clip.muxAssetId && clip.muxAssetId !== uploadAssetId) {
                        errors.push('Mux upload and clip refer to different assets');
                    } else if (!clip.muxAssetId) {
                        const linked = await db.clip.updateMany({
                            where: { id: clip.id, assetId: asset.id, muxUploadId: clip.muxUploadId, muxAssetId: null },
                            data: { muxAssetId: uploadAssetId },
                        });
                        if (linked.count !== 1) pending = true;
                        else clip.muxAssetId = uploadAssetId;
                    }
                }
            } else if (!['cancelled', 'timed_out', 'errored'].includes(result.upload.status)) {
                errors.push('Mux upload has an unrecognized status');
            }
        }

        if (ids.size === 0 && (clip.muxPlaybackId || clip.streamUrl || clip.thumbnailUrl)) {
            errors.push('Mux playback cannot be verified without its asset ID');
        }
        if (ids.size > 1 && asset.moderation !== 'REMOVED') {
            errors.push('Multiple Mux assets belong to one clip');
        }

        for (const muxAssetId of ids) {
            await recordMuxAssetReference(db, { assetId: asset.id, clipId: clip.id, muxAssetId });
        }
        if (!clip.muxAssetId && ids.size === 1) {
            const muxAssetId = [...ids][0];
            const linked = await db.clip.updateMany({
                where: { id: clip.id, assetId: asset.id, muxAssetId: null },
                data: { muxAssetId },
            });
            if (linked.count === 1) clip.muxAssetId = muxAssetId;
            else pending = true;
        }

        const assets = [];
        for (const muxAssetId of ids) {
            const result = await muxApi.inspectMuxAsset(muxAssetId);
            if (!result.ok) {
                errors.push(result.error);
            } else {
                assets.push({ id: muxAssetId, asset: result.asset });
            }
        }
        if (errors.length) {
            log.error({ assetId: asset.id, clipId: clip.id, errors }, 'Could not inspect all clip media');
        }
        return { clip, assets, pending, errors };
    }

    async function publishPlayback(fastify, asset, clip, muxAssetId, playbackId) {
        const streamUrl = `https://stream.mux.com/${playbackId}.m3u8`;
        const thumbnailUrl = `https://image.mux.com/${playbackId}/thumbnail.png?width=640`;
        const result = await db.$transaction(async tx => {
            const rows = await tx.$queryRaw`
                SELECT moderation, media_sync_revision, media_playback_reset, media_create_operation_id
                FROM assets WHERE id = ${asset.id} FOR UPDATE
            `;
            const current = rows[0];
            if (!current || current.moderation !== 'ACTIVE'
                || current.media_sync_revision !== asset.mediaSyncRevision
                || current.media_playback_reset || current.media_create_operation_id) {
                return { published: false };
            }
            const previous = await tx.clip.findFirst({
                where: { id: clip.id, assetId: asset.id, muxAssetId },
                select: { muxPlaybackId: true, status: true },
            });
            if (!previous) return { published: false };
            await tx.clip.update({
                where: { id: clip.id },
                data: { muxPlaybackId: playbackId, streamUrl, thumbnailUrl, status: 'READY' },
            });
            await tx.asset.update({ where: { id: asset.id }, data: { status: 'READY' } });
            return { published: true, changed: previous.muxPlaybackId !== playbackId || previous.status !== 'READY' };
        });
        if (!result.published || !result.changed) return result.published;

        const current = await db.asset.findFirst({
            where: {
                id: asset.id,
                moderation: 'ACTIVE',
                mediaSyncRevision: asset.mediaSyncRevision,
                mediaPlaybackReset: false,
                mediaCreateOperationId: null,
            },
            include: { formResponse: true },
        });
        if (!current) return false;

        fastify.io.to(userRoom(current.userId)).emit('mux:ready', {
            assetId: current.id,
            clipId: clip.id,
            mediasourceId: current.mediasourceId,
            mediasourceUrl: current.mediasourceUrl,
            originalFileName: current.originalFileName || null,
            muxPlaybackId: playbackId,
            streamUrl,
            thumbnailUrl,
            formSlug: current.formResponse?.slug || null,
            formType: current.formResponse?.type || null,
            formDescription: current.formResponse?.description || null,
            formPriority: current.formResponse?.priority || null,
            duration: clip.duration,
            resolution: clip.resolution,
            fileSize: clip.fileSize?.toString() || null,
        });
        await notifyDashboardAssetChange(fastify, current.id);
        return true;
    }

    async function createPlayback(asset, muxAssetId, assertLocked) {
        const operationId = randomUUID();
        await assertLocked();
        const started = await db.asset.updateMany({
            where: {
                id: asset.id,
                moderation: 'ACTIVE',
                mediaSyncRevision: asset.mediaSyncRevision,
                mediaPlaybackReset: false,
                mediaCreateOperationId: null,
            },
            data: {
                mediaCreateOperationId: operationId,
                mediaCreateMuxAssetId: muxAssetId,
                mediaCreateStartedAt: clock(),
            },
        });
        if (started.count !== 1) return { retry: true };

        const result = await muxApi.createMuxPublicPlayback(muxAssetId);
        await assertLocked();
        if (!result.ok && result.indeterminate) {
            await db.asset.updateMany({
                where: { id: asset.id, mediaCreateOperationId: operationId },
                data: { mediaPlaybackReset: true },
            });
            return { error: UNKNOWN_CREATE };
        }

        const cleared = await db.asset.updateMany({
            where: { id: asset.id, mediaCreateOperationId: operationId },
            data: { mediaCreateOperationId: null, mediaCreateMuxAssetId: null, mediaCreateStartedAt: null },
        });
        if (cleared.count !== 1) {
            throw new Error('Playback creation outcome could not be recorded');
        }
        if (!result.ok) return { error: result.error };
        return { playbackId: result.playbackId };
    }

    async function runPass(fastify, assetId, assertLocked, context) {
        const asset = await db.asset.findUnique({
            where: { id: assetId },
            include: {
                clips: true,
                muxAssetReferences: true,
                uploadSessions: { include: { muxIngestJob: { include: { attempts: true } } } },
                _count: { select: { originalReadLeases: true } },
            },
        });
        if (!asset) return { state: 'MISSING', message: 'Asset not found' };
        context.revision = asset.mediaSyncRevision;

        if (asset.mediaCreateOperationId) {
            await recordMuxAssetReference(db, {
                assetId: asset.id,
                muxAssetId: asset.mediaCreateMuxAssetId,
            });
            if (!asset.muxAssetReferences.some(reference => reference.muxAssetId === asset.mediaCreateMuxAssetId)) {
                asset.muxAssetReferences.push({
                    assetId: asset.id,
                    muxAssetId: asset.mediaCreateMuxAssetId,
                    clipId: null,
                });
            }
            await db.asset.updateMany({
                where: { id: asset.id, mediaCreateOperationId: asset.mediaCreateOperationId },
                data: { mediaPlaybackReset: true },
            });
            asset.mediaPlaybackReset = true;
        }

        const inspections = [];
        for (const clip of asset.clips) {
            inspections.push(await inspectClip(asset, clip, fastify.log, assertLocked));
        }
        const errors = inspections.flatMap(item => item.errors);
        let pending = inspections.some(item => item.pending);
        const jobs = asset.uploadSessions.map(session => session.muxIngestJob).filter(Boolean);
        const attempts = jobs.flatMap(job => job.attempts);
        const creatingOriginal = attempts.some(attempt => attempt.status === 'CREATING');
        const unknownOriginal = attempts.some(attempt => attempt.status === 'UNKNOWN');
        const conflictingOriginal = asset.moderation === 'ACTIVE'
            && jobs.some(job => job.status === 'CONFLICT');
        const uncertain = Boolean(asset.mediaCreateOperationId)
            || creatingOriginal || unknownOriginal || conflictingOriginal;
        if (asset.mediaCreateOperationId) errors.push(UNKNOWN_CREATE);
        if (unknownOriginal) errors.push(UNKNOWN_ORIGINAL);
        if (conflictingOriginal) errors.push(CONFLICTING_ORIGINAL);
        if (creatingOriginal) pending = true;
        const readsPending = asset.moderation !== 'ACTIVE' && asset._count.originalReadLeases > 0;
        if (readsPending) pending = true;
        const playbackIds = new Map();

        if (asset.moderation === 'REMOVED') {
            if (asset.clips.some(clip => clip.storageKey && !asset.uploadSessions.some(session =>
                session.clipId === clip.id
                && session.storageKey === clip.storageKey
                && session.storageDriver === clip.storageDriver))) {
                errors.push('Original file has no upload session; manual recovery is required');
            }
            for (const session of asset.uploadSessions) {
                if (readsPending) continue;
                const clip = asset.clips.find(item => item.id === session.clipId);
                const expectedPrefix = `originals/${session.ownerId}/${asset.id}/${session.clipId}/`;
                if (!clip || session.ownerId !== asset.userId
                    || (session.storageDriver === 'local' && !session.storageKey.startsWith(expectedPrefix))) {
                    errors.push('Original upload references are inconsistent; manual recovery is required');
                    continue;
                }
                try {
                    const storage = storageFactory({ provider: session.storageDriver });
                    await storage.assertStorageLocation(session.storageKey);
                    const locked = await storage.withCompletionLock(session.id, async () => {
                        await assertLocked();
                        await storage.abortUpload(session.id);
                        await storage.delete(session.storageKey);
                        if (await storage.stat(session.storageKey)) {
                            throw new Error('Original file deletion could not be verified');
                        }
                        await assertLocked();
                        await db.$transaction(async tx => {
                            await tx.uploadSession.updateMany({
                                where: { id: session.id, assetId: asset.id, status: { in: ['OPEN', 'COMPLETING'] } },
                                data: { status: 'ABORTED' },
                            });
                            const updated = await tx.clip.updateMany({
                                where: { id: session.clipId, assetId: asset.id, storageKey: session.storageKey },
                                data: { storageKey: null, storageDriver: null, sha256: null, fileSize: null },
                            });
                            if (clip.storageKey === session.storageKey && updated.count !== 1) {
                                throw new Error('Original clip changed during cleanup');
                            }
                            await releaseStorageReservation(tx, session.id);
                        }, { timeout: 60000 });
                    });
                    if (!locked.acquired) pending = true;
                } catch (err) {
                    if (err instanceof StorageError && err.code === 'SESSION_BUSY') {
                        pending = true;
                    } else {
                        fastify.log.error(
                            { assetId: asset.id, uploadSessionId: session.id, err: { message: err.message } },
                            'Could not remove original upload data',
                        );
                        errors.push('Original upload cleanup failed');
                    }
                }
            }
        }

        for (const item of inspections) {
            const { clip } = item;
            const removeLocal = asset.moderation === 'REMOVED'
                || item.assets.some(remote => remote.asset?.status === 'ready');
            if (asset.moderation !== 'ACTIVE' || removeLocal) {
                const local = await inspectLocalFile(clip, removeLocal, fastify.log);
                if (!local.ok) errors.push(local.error);
                else if (removeLocal && clip.storageUrl?.startsWith('/uploads/')) {
                    await db.clip.updateMany({
                        where: { id: clip.id, assetId: asset.id, storageUrl: clip.storageUrl },
                        data: { storageUrl: null },
                    });
                }
            }

            for (const remote of item.assets) {
                if (!remote.asset) {
                    if (asset.moderation === 'ACTIVE') errors.push('Mux asset is unavailable');
                    continue;
                }
                if (asset.moderation === 'REMOVED') {
                    await assertLocked();
                    if (!await muxApi.deleteMuxAsset(remote.id)) {
                        errors.push('Mux asset deletion failed');
                        continue;
                    }
                    const verified = await muxApi.inspectMuxAsset(remote.id);
                    if (!verified.ok || verified.asset) {
                        errors.push('Mux asset deletion could not be verified');
                    } else {
                        await db.clip.updateMany({
                            where: { id: clip.id, assetId: asset.id, muxAssetId: remote.id },
                            data: { muxAssetId: null, muxPlaybackId: null, streamUrl: null, thumbnailUrl: null },
                        });
                    }
                    continue;
                }

                if (asset.moderation !== 'ACTIVE' || asset.mediaPlaybackReset || uncertain) {
                    const revoked = await muxApi.disableMuxPlayback(remote.id, assertLocked);
                    if (!revoked.ok) errors.push(revoked.error);
                    if (remote.asset.status === 'preparing') pending = true;
                    continue;
                }

                if (remote.asset.status === 'preparing') {
                    pending = true;
                } else if (remote.asset.status === 'errored') {
                    const failed = await db.clip.updateMany({
                        where: { id: clip.id, assetId: asset.id, muxAssetId: remote.id, status: { not: 'ERROR' } },
                        data: { status: 'ERROR' },
                    });
                    await db.asset.updateMany({
                        where: { id: asset.id, mediaSyncRevision: asset.mediaSyncRevision, moderation: 'ACTIVE' },
                        data: { status: 'ERROR' },
                    });
                    if (failed.count) {
                        await notifyDashboardAssetChange(fastify, asset.id);
                        if (slack.isConfigured()) {
                            const ageMin = Math.round((clock().getTime() - new Date(clip.createdAt).getTime()) / 60000);
                            const alert = await slack.postToChannel(
                                'general',
                                `⚠️ Mux processing error — clip #${asset.mediasourceId} failed after ${ageMin}min`,
                                undefined,
                                { requestId: 'job:mux-sync' },
                            );
                            if (!alert.ok) fastify.log.error({ assetId: asset.id }, 'Could not send Mux error alert');
                        }
                    }
                    errors.push('Mux video processing failed');
                } else if (remote.asset.status === 'ready') {
                    if (item.assets.length !== 1 || item.errors.length) continue;
                    let playbackId = playbackIds.get(remote.id)
                        || remote.asset.playback_ids?.find(item => item.policy === 'public')?.id;
                    if (!playbackId) {
                        const created = await createPlayback(asset, remote.id, assertLocked);
                        if (created.retry) return { retry: true };
                        if (created.error) {
                            if (created.error === UNKNOWN_CREATE) return { retry: true };
                            errors.push(created.error);
                            break;
                        }
                        playbackId = created.playbackId;
                    }
                    playbackIds.set(remote.id, playbackId);
                    await assertLocked();
                    if (!await publishPlayback(fastify, asset, clip, remote.id, playbackId)) {
                        return { retry: true };
                    }
                } else {
                    errors.push('Mux asset has an unrecognized status');
                }
            }
        }

        const knownClipIds = new Set(asset.clips.map(clip => clip.id));
        const inspectedMuxIds = new Set(inspections.flatMap(item => item.assets.map(remote => remote.id)));
        for (const reference of asset.muxAssetReferences) {
            if (inspectedMuxIds.has(reference.muxAssetId)
                || (reference.clipId && knownClipIds.has(reference.clipId))) continue;
            const remote = await muxApi.inspectMuxAsset(reference.muxAssetId);
            if (!remote.ok) {
                errors.push(remote.error);
            } else if (remote.asset && asset.moderation === 'REMOVED') {
                await assertLocked();
                if (!await muxApi.deleteMuxAsset(reference.muxAssetId)) {
                    errors.push('Mux asset deletion failed');
                } else {
                    const verified = await muxApi.inspectMuxAsset(reference.muxAssetId);
                    if (!verified.ok || verified.asset) errors.push('Mux asset deletion could not be verified');
                }
            } else if (remote.asset && (asset.moderation !== 'ACTIVE' || uncertain || asset.mediaPlaybackReset)) {
                const revoked = await muxApi.disableMuxPlayback(reference.muxAssetId, assertLocked);
                if (!revoked.ok) errors.push(revoked.error);
                if (remote.asset.status === 'preparing') pending = true;
            } else if (remote.asset) {
                errors.push('Mux media has no associated clip');
            }
        }

        if (asset.moderation === 'ACTIVE' && asset.mediaPlaybackReset && !uncertain && !pending && !errors.length) {
            await assertLocked();
            const reset = await db.$transaction(async tx => {
                const updated = await tx.asset.updateMany({
                    where: {
                        id: asset.id,
                        moderation: 'ACTIVE',
                        mediaSyncRevision: asset.mediaSyncRevision,
                        mediaPlaybackReset: true,
                        mediaCreateOperationId: null,
                    },
                    data: { mediaPlaybackReset: false },
                });
                if (updated.count === 1) {
                    // Retain old URLs until revocation is verified, then remove them before reopening playback.
                    await tx.clip.updateMany({
                        where: { assetId: asset.id },
                        data: { muxPlaybackId: null, streamUrl: null, thumbnailUrl: null },
                    });
                }
                return updated;
            });
            return { retry: true, changed: reset.count === 1 };
        }

        await assertLocked();
        if (errors.length) {
            fastify.log.error({ assetId: asset.id, errors }, 'Media reconciliation requires attention');
            return setResult(asset, 'ERROR', errors[0]);
        }
        if (pending) return setResult(asset, 'PENDING', 'Media processing or cleanup is pending');
        return setResult(asset, 'SYNCED', 'Media reconciliation completed');
    }

    return async function reconcileAssetMedia(fastify, assetId) {
        const message = 'Media reconciliation failed; retry or check server logs';
        try {
            const locked = await withLock(assetId, async assertLocked => {
                const context = { revision: null };
                try {
                    for (let attempt = 0; attempt < 4; attempt += 1) {
                        const result = await runPass(fastify, assetId, assertLocked, context);
                        if (!result.retry) return result;
                    }
                    return { state: 'PENDING', message: 'Media state changed; reconciliation will retry' };
                } catch (err) {
                    fastify.log.error({ assetId, err: { message: err.message } }, 'Media reconciliation failed');
                    await assertLocked();
                    if (context.revision !== null) {
                        await db.asset.updateMany({
                            where: { id: assetId, mediaSyncRevision: context.revision },
                            data: {
                                mediaSyncState: 'ERROR',
                                mediaSyncError: message,
                                mediaSyncNextAt: new Date(clock().getTime() + RETRY_INTERVAL_MS),
                            },
                        });
                    }
                    return { state: 'ERROR', message };
                }
            });
            return locked.acquired
                ? locked.value
                : { state: 'PENDING', message: 'Media reconciliation is already in progress' };
        } catch (err) {
            fastify.log.error({ assetId, err: { message: err.message } }, 'Media reconciliation lock failed');
            return { state: 'ERROR', message };
        }
    };
}

export const reconcileAssetMedia = createMediaReconciler({
    db: prisma,
    muxApi: mux,
    withLock: withAssetMediaLock,
});
