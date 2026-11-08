export function canExposePlayback(asset) {
    return asset?.moderation === 'ACTIVE'
        && !asset.mediaPlaybackReset
        && !asset.mediaCreateOperationId;
}
