import { randomUUID } from 'node:crypto';
import { lockMuxOriginalRows } from './mux-original-records.js';

export const muxOriginalReadServerInstanceId = randomUUID();
const READABLE_STATES = ['CREATING', 'UNKNOWN', 'LINKED'];

const attemptInclude = {
    job: {
        include: {
            uploadSession: {
                include: {
                    owner: { select: { status: true } },
                    asset: { select: { userId: true, moderation: true, status: true } },
                    clip: {
                        select: {
                            assetId: true,
                            storageKey: true,
                            storageDriver: true,
                            sha256: true,
                            fileSize: true,
                        },
                    },
                },
            },
        },
    },
};

export function isReadableOriginal(attempt, expires, now = new Date()) {
    if (!attempt || !Number.isSafeInteger(expires) || expires * 1000 <= now.getTime()) return false;
    const { job } = attempt;
    const session = job?.uploadSession;
    const { owner, asset, clip } = session || {};
    return Boolean(
        session && owner && asset && clip
        && attempt.readExpiresAt.getTime() === expires * 1000
        && job.currentAttemptId === attempt.id
        && READABLE_STATES.includes(job.status)
        && READABLE_STATES.includes(attempt.status)
        && session.status === 'COMPLETED'
        && owner.status === 'ACTIVE'
        && asset.userId === session.ownerId
        && asset.moderation === 'ACTIVE'
        && asset.status !== 'ERROR'
        && clip.assetId === session.assetId
        && clip.storageKey === session.storageKey
        && clip.storageDriver === session.storageDriver
        && session.expectedSha256 && clip.sha256 === session.expectedSha256
        && session.expectedSizeBytes && clip.fileSize === session.expectedSizeBytes
    );
}

export async function findReadableOriginal(db, operationId, expires, now = new Date()) {
    const attempt = await db.muxIngestAttempt.findUnique({
        where: { id: operationId },
        include: attemptInclude,
    });
    return isReadableOriginal(attempt, expires, now) ? attempt.job.uploadSession : null;
}

export async function registerOriginalRead(db, operationId, expires, now = new Date()) {
    const initial = await db.muxIngestAttempt.findUnique({
        where: { id: operationId },
        include: { job: { include: { uploadSession: true } } },
    });
    if (!initial) return null;
    return db.$transaction(async tx => {
        await lockMuxOriginalRows(tx, initial.job.uploadSession);
        const session = await findReadableOriginal(tx, operationId, expires, now);
        if (!session) return null;
        const lease = await tx.muxOriginalReadLease.create({
            data: {
                id: randomUUID(),
                assetId: session.assetId,
                attemptId: operationId,
                serverInstanceId: muxOriginalReadServerInstanceId,
            },
        });
        return { session, lease };
    });
}
