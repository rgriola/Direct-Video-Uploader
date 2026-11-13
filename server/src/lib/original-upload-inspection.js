import { UploadSessionError } from './upload-sessions.js';

export const SESSION_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function lockCancellationIntent(tx, ownerId, clientRequestId) {
    const users = await tx.$queryRaw`SELECT id, status FROM users WHERE id = ${ownerId} FOR UPDATE`;
    if (!users.length || users[0].status !== 'ACTIVE') {
        throw new UploadSessionError('ACCOUNT_SUSPENDED', 'Account is suspended');
    }
    const key = { userId: ownerId, clientRequestId };
    const where = { userId_clientRequestId: key };
    let intent = await tx.originalUploadIntent.findUnique({ where });
    if (intent?.assetId) {
        // Asset deletion clears the intent under the asset lock.
        const assetId = intent.assetId;
        await tx.$queryRaw`SELECT id FROM assets WHERE id = ${assetId} FOR UPDATE`;
        intent = await tx.originalUploadIntent.findUnique({ where });
        if (!intent || (intent.assetId && intent.assetId !== assetId)) {
            throw new UploadSessionError('INTENT_INCONSISTENT', 'Original upload intent cannot be verified');
        }
    }
    return { key, where, intent };
}

export async function cancellationAssetVisibility(tx, assetId, ownerId) {
    const asset = await tx.asset.findUnique({
        where: { id: assetId },
        select: { userId: true, moderation: true },
    });
    if (!asset || asset.userId !== ownerId) return 'inconsistent';
    return ['ACTIVE', 'PAUSED'].includes(asset.moderation) ? 'visible' : 'hidden';
}

export async function hasInconsistentSessionReferences(tx, assetId) {
    // Both branches can use asset/clip indexes and cover all sessions, not just the requested page.
    const rows = await tx.$queryRaw`
        SELECT 1 FROM upload_sessions s JOIN clips c ON c.id = s.clip_id
        WHERE s.asset_id = ${assetId} AND c.asset_id <> ${assetId}
        UNION ALL
        SELECT 1 FROM clips c JOIN upload_sessions s ON s.clip_id = c.id
        WHERE c.asset_id = ${assetId} AND s.asset_id <> ${assetId}
        LIMIT 1`;
    return rows.length !== 0;
}
