export function getAssetUploadMode(asset, { hasStoredOriginal = false, hasMuxUpload = false } = {}) {
    const hasOriginal = asset.uploadMode === 'ORIGINAL'
        || (asset.uploadSessions?.length ?? 0) > 0
        || (asset.clips?.some(clip => clip.storageKey != null) ?? false)
        || hasStoredOriginal;
    const hasMux = asset.uploadMode === 'MUX'
        || (asset.clips?.some(clip => clip.muxUploadId != null) ?? false)
        || hasMuxUpload;
    if (hasOriginal === hasMux) return 'UNKNOWN';
    return hasOriginal ? 'ORIGINAL' : 'MUX';
}

export function serializeCreatedAsset(asset) {
    return {
        id: asset.id,
        mediasourceId: asset.mediasourceId,
        mediasourceUrl: asset.mediasourceUrl,
        originalFileName: asset.originalFileName,
        status: asset.status,
        clipCount: asset.clipCount,
        totalDuration: asset.totalDuration,
        uploadMode: getAssetUploadMode(asset),
        uploadSource: asset.uploadSource ?? null,
    };
}
