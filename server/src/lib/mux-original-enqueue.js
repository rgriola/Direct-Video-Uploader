import { UploadSessionError } from './upload-sessions.js';
import { lockMuxOriginalRows, originalIngestEligibility } from './mux-original-records.js';

export async function requestMuxOriginalIngest(db, snapshot, ownerId, now = new Date()) {
    return db.$transaction(async tx => {
        await lockMuxOriginalRows(tx, snapshot);
        const session = await tx.uploadSession.findUnique({
            where: { id: snapshot.id },
            include: {
                owner: { select: { status: true } },
                asset: { select: { userId: true, moderation: true, status: true } },
                clip: true,
                muxIngestJob: { include: { attempts: true } },
            },
        });
        if (!session || session.ownerId !== ownerId || session.asset.userId !== ownerId
            || !['ACTIVE', 'PAUSED'].includes(session.asset.moderation)) {
            throw new UploadSessionError('NOT_FOUND', 'Upload session not found');
        }
        if (session.owner.status !== 'ACTIVE') {
            throw new UploadSessionError('ACCOUNT_SUSPENDED', 'Account is suspended');
        }
        if (session.asset.moderation !== 'ACTIVE') {
            throw new UploadSessionError('ASSET_NOT_ACTIVE', 'Asset is not available for Mux ingest');
        }
        if (session.status !== 'COMPLETED') {
            throw new UploadSessionError('INVALID_STATE', 'Original upload is not complete');
        }

        const job = session.muxIngestJob;
        if (job?.status === 'LINKED') {
            if (session.asset.status === 'ERROR' || session.clip.status === 'ERROR') {
                throw new UploadSessionError('INVALID_STATE', 'Mux processing failed; the linked asset requires investigation');
            }
            return job;
        }
        if (job?.status === 'QUEUED') return job;
        if (job && job.status !== 'FAILED') {
            throw new UploadSessionError('INVALID_STATE', 'Mux ingest requires reconciliation before retry');
        }
        if (originalIngestEligibility(session) !== 'READY'
            || job?.attempts.some(attempt => !['REJECTED', 'CONFIRMED_ABSENT'].includes(attempt.status))
            || await tx.muxAssetReference.findFirst({ where: { assetId: session.assetId } })) {
            throw new UploadSessionError('CLIP_CHANGED', 'Original is not eligible for Mux ingest');
        }
        return job
            ? tx.muxIngestJob.update({
                where: { uploadSessionId: session.id },
                data: {
                    status: 'QUEUED',
                    retryCount: 0,
                    nextAttemptAt: now,
                    lastError: null,
                },
            })
            : tx.muxIngestJob.create({
                data: { uploadSessionId: session.id, nextAttemptAt: now },
            });
    });
}
