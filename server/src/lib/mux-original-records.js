import { queueAssetMediaSync, recordMuxAssetReference } from './media-reconciliation.js';

export function originalIngestEligibility(session) {
    if (!session || session.status !== 'COMPLETED'
        || session.asset.userId !== session.ownerId
        || session.asset.moderation === 'REMOVED'
        || session.clip.assetId !== session.assetId
        || session.clip.storageKey !== session.storageKey
        || session.clip.storageDriver !== session.storageDriver
        || !session.expectedSha256 || session.clip.sha256 !== session.expectedSha256
        || !session.expectedSizeBytes || session.clip.fileSize !== session.expectedSizeBytes
        || session.clip.muxUploadId || session.clip.muxAssetId) return 'INVALID';
    if (session.owner.status !== 'ACTIVE' || session.asset.moderation !== 'ACTIVE') return 'DEFERRED';
    if (session.asset.status === 'ERROR') return 'INVALID';
    return 'READY';
}

export async function enqueueMuxOriginal(tx, session) {
    return tx.muxIngestJob.upsert({
        where: { uploadSessionId: session.id },
        create: { uploadSessionId: session.id },
        update: {},
    });
}

export async function lockMuxOriginalRows(tx, session) {
    await tx.$queryRaw`SELECT id FROM users WHERE id = ${session.ownerId} FOR UPDATE`;
    await tx.$queryRaw`SELECT id FROM assets WHERE id = ${session.assetId} FOR UPDATE`;
    await tx.$queryRaw`SELECT id FROM upload_sessions WHERE id = ${session.id} FOR UPDATE`;
    await tx.$queryRaw`
        SELECT upload_session_id FROM mux_ingest_jobs
        WHERE upload_session_id = ${session.id} FOR UPDATE
    `;
}

export async function retainRetiredMuxOriginalAsset(tx, { operationId, muxAssetId }) {
    const retired = await tx.muxRetiredIngestAttempt.findUnique({ where: { operationId } });
    if (!retired) return false;
    await tx.muxRetiredIngestEvent.createMany({
        data: [{ operationId, muxAssetId }],
        skipDuplicates: true,
    });
    return true;
}

export async function retainMuxOriginalAsset(tx, {
    operationId, muxAssetId, expectedAssetId, expectedClipId, now = new Date(),
}) {
    const initial = await tx.muxIngestAttempt.findUnique({
        where: { id: operationId },
        include: { job: { include: { uploadSession: true } } },
    });
    if (!initial) return { matched: false };
    const session = initial.job.uploadSession;
    if ((expectedAssetId && session.assetId !== expectedAssetId)
        || (expectedClipId && session.clipId !== expectedClipId)) {
        throw new Error('Mux ingest operation references conflicting local media');
    }

    await lockMuxOriginalRows(tx, session);
    const attempt = await tx.muxIngestAttempt.findUnique({
        where: { id: operationId },
        include: { job: true },
    });
    if (!attempt) return { matched: false };
    const clip = await tx.clip.findUnique({
        where: { id: session.clipId },
        select: { id: true, assetId: true, status: true, muxAssetId: true, muxUploadId: true },
    });
    await recordMuxAssetReference(tx, {
        assetId: session.assetId,
        clipId: session.clipId,
        muxAssetId,
    });

    const conflict = attempt.job.currentAttemptId !== operationId
        || !['CREATING', 'UNKNOWN', 'LINKED'].includes(attempt.job.status)
        || ['REJECTED', 'CONFIRMED_ABSENT'].includes(attempt.status)
        || (attempt.muxAssetId && attempt.muxAssetId !== muxAssetId)
        || !clip || clip.assetId !== session.assetId || clip.muxUploadId
        || (clip.muxAssetId && clip.muxAssetId !== muxAssetId);

    if (!attempt.muxAssetId || attempt.muxAssetId === muxAssetId) {
        await tx.muxIngestAttempt.update({
            where: { id: operationId },
            data: { status: 'LINKED', muxAssetId, resolvedAt: now },
        });
    }
    if (conflict) {
        await tx.muxIngestJob.update({
            where: { uploadSessionId: session.id },
            data: {
                status: 'CONFLICT',
                nextAttemptAt: null,
                lastError: 'Mux ingest references require manual reconciliation',
            },
        });
    } else {
        if (!clip.muxAssetId) {
            await tx.clip.update({
                where: { id: clip.id },
                data: {
                    muxAssetId,
                    ...(clip.status === 'UPLOADING' ? { status: 'PROCESSING' } : {}),
                },
            });
        }
        await tx.asset.updateMany({
            where: { id: session.assetId, moderation: 'ACTIVE', status: 'UPLOADING' },
            data: { status: 'PROCESSING' },
        });
        await tx.muxIngestJob.update({
            where: { uploadSessionId: session.id },
            data: { status: 'LINKED', nextAttemptAt: null, lastError: null },
        });
    }
    await queueAssetMediaSync(tx, session.assetId, { resetPlayback: Boolean(conflict) });
    return { matched: true, conflict: Boolean(conflict), assetId: session.assetId };
}
