// May 14, 2026 - 11:00am - GitHub Copilot (Claude Opus 4.7)
//
// Host protocol conformances extracted from ChatViewModel.swift during P8.

import Foundation
import UIKit

// MARK: - Priority 5b: Upload/Workflow Host Conformances
// These extensions are inlined in this file so they can access ChatViewModel's
// private members (Swift's `private` is file-scoped). Each extension replaces
// the closure-bag `Dependencies` struct that previously sat on each service.

// MARK: WorkflowReconcileExecutionHost

extension ChatViewModel: WorkflowReconcileExecutionHost {
    func wreMarkBatchClipFailed(assetId: String?, reason: String) {
        markBatchClipFailed(assetId: assetId, reason: reason)
    }

    func wreAppendUploadFailedBubble(assetId: String, reason: String) {
        wsAppendUploadFailedBubble(assetId: assetId, reason: reason)
    }

    func wreUpdateBatchMetadataToProcessing(asset: Asset) {
        updateBatchClipMetadata(
            assetId: asset.id,
            mediasourceId: asset.mediasourceId,
            mediasourceUrl: asset.mediasourceUrl,
            formSlug: asset.formResponse?.slug
        )
        setBatchClipPhase(assetId: asset.id, phase: .processing)
    }

    func wreMarkBatchClipReady(asset: Asset) {
        markBatchClipReady(
            assetId: asset.id,
            mediasourceId: asset.mediasourceId,
            mediasourceUrl: asset.mediasourceUrl,
            formSlug: asset.formResponse?.slug
        )
    }

    func wreAppendFormConfirmed(asset: Asset, source: MessagePolicyCoordinator.Source) {
        appendReconciledFormConfirmed(asset: asset, source: source)
    }

    func wreResetReadyMessagePolicy(assetId: String) {
        messagePolicy.resetAssetScope(assetId: assetId)
    }

    func wreApplyReadyWorkflowState(asset: Asset, source: MessagePolicyCoordinator.Source) {
        applyReadyWorkflowState(
            assetId: asset.id,
            mediasourceId: asset.mediasourceId,
            mediasourceUrl: asset.mediasourceUrl,
            originalFileName: asset.originalFileName
                ?? asset.clips?.first?.originalFileName,
            formSlug: asset.formResponse?.slug,
            duration: asset.clips?.first?.duration,
            resolution: asset.clips?.first?.resolution,
            fileSize: asset.clips?.first?.fileSize,
            source: source
        )
    }
}

// MARK: SingleUploadFlowHost

extension ChatViewModel: SingleUploadFlowHost {
    // createAsset
    func sufRegisterAsset(_ asset: Asset) {
        currentAssetId = asset.id
        chatOwnership.registerActiveAsset(asset.id)
        _ = promoteWorkflowStage(for: asset.id, to: .uploading)
        clearBlockingConnectivityIssueIfNeeded(assetId: asset.id)
    }

    func sufAppendOutgoingMessage(_ message: ChatMessage) {
        appendMessage(message, source: .outgoing)
    }

    func sufStoreUploadInfo(messageId: String, assetId: String, uploadInfo: SentUploadInfo) {
        sentUploads[messageId] = uploadInfo
        sentUploadsByAssetId[assetId] = uploadInfo
    }

    func sufSendVideoUpload(assetId: String, fileName: String, fileSize: Int64) {
        ws.sendVideoUpload(assetId: assetId, fileName: fileName, fileSize: fileSize)
    }

    func sufAppendStartErrorBubble() {
        appendErrorBubble(
            "Could not start upload. Please try again.",
            code: "IOS_UPLOAD_START_FAILED"
        )
    }

    func sufReportStartError(errorDescription: String, fileName: String) async {
        await reportError(
            category: "upload",
            message: "Asset creation failed after 3 attempts: \(errorDescription)",
            severity: "ERROR",
            details: ["fileName": fileName]
        )
    }

    // uploadVideo
    func sufSetUploading(_ isUploading: Bool) {
        self.isUploading = isUploading
    }

    func sufUpdateProgress(_ progress: Double) {
        uploadProgress = progress
    }

    func sufMarkAssetFailed(assetId: String) {
        _ = promoteWorkflowStage(for: assetId, to: .failed)
    }

    func sufAppendUploadErrorBubble(assetId: String, reason: String) {
        appendErrorBubble(
            "Upload failed: \(reason)",
            assetId: assetId,
            code: "IOS_UPLOAD_FAILED",
            params: ["reason": reason]
        )
    }

    func sufReportUploadError(assetId: String, errorDescription: String) async {
        await reportError(
            category: "upload",
            message: "File upload failed: \(errorDescription)",
            severity: "ERROR",
            assetId: assetId
        )
    }

    // shared
    func sufIsConnectivityIssue(_ error: Error) -> Bool {
        connectivityIssues.isConnectivityIssue(error)
    }

    func sufNoteBlockingConnectivityIssue(operation: String, assetId: String?) {
        noteBlockingConnectivityIssue(operation: operation, assetId: assetId)
    }
}

// MARK: BatchAssetFlowHost

extension ChatViewModel: BatchAssetFlowHost {
    // createBatchAsset
    func bafRegisterAsset(_ asset: Asset) {
        currentAssetId = asset.id
        chatOwnership.registerActiveAsset(asset.id)
        _ = promoteWorkflowStage(for: asset.id, to: .uploading)
        clearBlockingConnectivityIssueIfNeeded(assetId: asset.id)
    }

    func bafAppendOutgoingMessage(_ message: ChatMessage) {
        appendMessage(message, source: .outgoing)
    }

    func bafStoreUploadInfo(messageId: String, assetId: String, uploadInfo: SentUploadInfo) {
        sentUploads[messageId] = uploadInfo
        sentUploadsByAssetId[assetId] = uploadInfo
    }

    func bafMarkBatchUploadStarted(assetId: String) {
        setBatchClipPhase(assetId: assetId, phase: .uploading)
        updateBatchClipProgress(assetId: assetId, progress: 0)
    }

    func bafSavePHAssetIdentifier(assetId: String, identifier: String) {
        PHAssetIdentifierStore.save(assetId: assetId, phAssetIdentifier: identifier)
    }

    func bafSendVideoUpload(assetId: String, fileName: String, fileSize: Int64) {
        ws.sendVideoUpload(assetId: assetId, fileName: fileName, fileSize: fileSize)
    }

    func bafAppendStartErrorBubble() {
        appendErrorBubble(
            "Could not start batch upload. Please try again.",
            code: "IOS_BATCH_UPLOAD_START_FAILED"
        )
    }

    func bafReportStartError(errorDescription: String, fileName: String) async {
        await reportError(
            category: "upload",
            message: "Batch asset creation failed after 3 attempts: \(errorDescription)",
            severity: "ERROR",
            details: ["fileName": fileName]
        )
    }

    // uploadBatchVideo
    func bafMarkAssetFailed(assetId: String, reason: String) {
        _ = promoteWorkflowStage(for: assetId, to: .failed)
        markBatchClipFailed(assetId: assetId, reason: reason)
    }

    func bafReportUploadError(errorDescription: String, assetId: String) async {
        await reportError(
            category: "upload",
            message: "Batch file upload failed: \(errorDescription)",
            severity: "ERROR",
            assetId: assetId
        )
    }

    // shared
    func bafIsConnectivityIssue(_ error: Error) -> Bool {
        connectivityIssues.isConnectivityIssue(error)
    }

    func bafNoteBlockingConnectivityIssue(operation: String, assetId: String?) {
        noteBlockingConnectivityIssue(operation: operation, assetId: assetId)
    }
}

// MARK: BatchItemProcessingHost

extension ChatViewModel: BatchItemProcessingHost {
    func bipPrepareForProcessing(localId: String) -> BatchItemPreparationResult {
        batchItemExecutionService.prepareForProcessing(
            localId: localId,
            batchItems: &batchItems,
            stagedBatchVideos: stagedBatchVideos,
            lifecycle: batchItemLifecycleService
        )
    }

    func bipNoteItemPreparedForCreation() {
        noteBatchItemPreparedForCreation()
    }

    func bipBuildCreationContext(
        from selectedContext: BatchItemSelectedContext
    ) async -> BatchItemCreationContext {
        await batchItemExecutionService.buildCreationContext(from: selectedContext)
    }

    func bipCreateBatchAsset(creationContext: BatchItemCreationContext) async -> Asset? {
        await createBatchAsset(
            fileName: creationContext.fileName,
            fileURL: creationContext.fileURL,
            thumbnail: creationContext.thumbnail,
            createdDate: creationContext.createdDate,
            hasLocation: creationContext.hasLocation,
            phAssetIdentifier: creationContext.phAssetIdentifier
        )
    }

    func bipPrepareForUpload(localId: String, assetId: String) -> Bool {
        batchItemExecutionService.prepareForUpload(
            localId: localId,
            assetId: assetId,
            batchItems: &batchItems,
            lifecycle: batchItemLifecycleService
        )
    }

    func bipNoteItemPreparedForUpload(assetId: String) {
        noteBatchItemPreparedForUpload(assetId: assetId)
    }

    func bipUploadBatchVideo(
        localId: String,
        assetId: String,
        creationContext: BatchItemCreationContext
    ) async -> Bool {
        await uploadBatchVideo(
            assetId: assetId,
            fileURL: creationContext.fileURL,
            metadata: creationContext.metadata,
            onProgress: { progress in
                self.updateBatchUploadProgress(localId: localId, progress: progress)
            }
        )
    }

    func bipPendingFailureIndex(localId: String, skipAlreadyFailed: Bool) -> Int? {
        batchItemExecutionService.pendingFailureIndex(
            localId: localId,
            batchItems: batchItems,
            skipAlreadyFailed: skipAlreadyFailed
        )
    }

    func bipMarkFailedAtIndex(index: Int, message: String) {
        markBatchItemFailedAtIndex(index: index, message: message)
    }

    func bipNoteUploadSucceeded(assetId: String) {
        setBatchClipPhase(assetId: assetId, phase: .processing)
    }

    func bipPrepareForApplyingForm(localId: String) -> BatchItemProgressUpdate? {
        batchItemExecutionService.prepareForApplyingForm(
            localId: localId,
            batchItems: &batchItems,
            lifecycle: batchItemLifecycleService
        )
    }

    func bipNoteItemPreparedForApplyingForm(
        assetId: String,
        applyingUpdate: BatchItemProgressUpdate
    ) {
        noteBatchItemPreparedForApplyingForm(
            assetId: assetId,
            applyingUpdate: applyingUpdate
        )
    }

    func bipApplyGroupedFormToAsset(assetId: String) async -> Bool {
        await applyGroupedFormToAsset(assetId: assetId)
    }

    func bipPrepareForCompletion(localId: String) -> BatchItemProgressUpdate? {
        batchItemExecutionService.prepareForCompletion(
            localId: localId,
            batchItems: &batchItems,
            lifecycle: batchItemLifecycleService
        )
    }

    func bipNoteItemCompleted(completedUpdate: BatchItemProgressUpdate, fileURL: URL) {
        noteBatchItemCompleted(completedUpdate: completedUpdate, fileURL: fileURL)
    }
}

// MARK: UploadQueueRehydrateHost

extension ChatViewModel: UploadQueueRehydrateHost {
    func uqrHasCurrentAsset() -> Bool {
        currentAssetId != nil
    }

    func uqrSetCurrentAsset(assetId: String) {
        currentAssetId = assetId
    }

    func uqrRegisterActiveAsset(assetId: String?) {
        chatOwnership.registerActiveAsset(assetId)
    }

    func uqrAppendSummaryMessage(_ message: ChatMessage) {
        appendMessage(message, source: .workflow)
    }

    func uqrPromoteWorkflowStage(assetId: String, targetStage: WorkflowStage) {
        _ = promoteWorkflowStage(for: assetId, to: targetStage)
    }

    func uqrSetBatchItems(_ items: [VideoBatchItem]) {
        batchItems = items
    }

    func uqrSyncBatchDisplayState(assetId: String) {
        syncBatchDisplayStateForRehydratedAsset(assetId: assetId)
    }

    func uqrHasUploadFailureMessage(assetId: String) -> Bool {
        hasWorkflowMessage(
            code: "IOS_UPLOAD_FAILED",
            assetId: assetId,
            mediasourceId: nil
        )
    }

    func uqrAppendUploadFailedBubble(assetId: String, reason: String) {
        wsAppendUploadFailedBubble(assetId: assetId, reason: reason)
    }

    func uqrHasActiveBatch() -> Bool {
        hasActiveBatch
    }

    func uqrSetBatchState(_ state: VideoBatchState) {
        batchState = state
    }

    func uqrUpdateBatchProgress() {
        batchProgress = computeBatchProgress()
    }

    func uqrPersistBatchState() {
        persistBatchState()
    }

    func uqrReconcileAssetDetails(assetIds: [String]) {
        reconcileAssetDetailsAfterUploadQueueRehydrate(assetIds)
    }
}

// MARK: AssetDetailSyncHost

extension ChatViewModel: AssetDetailSyncHost {
    func adsFetchAssetDetail(assetId: String) async throws -> AssetDetailFetchResult {
        try await assetDetailService.fetchAssetDetail(auth: auth, assetId: assetId)
    }

    func adsHasDetailLoadFailureMessage(assetId: String) -> Bool {
        hasWorkflowMessage(
            code: "IOS_ASSET_DETAILS_LOAD_FAILED",
            assetId: assetId,
            mediasourceId: nil
        )
    }

    func adsAppendDetailLoadFailureBubble(assetId: String) {
        appendErrorBubble(
            "Could not load video details.",
            assetId: assetId,
            code: "IOS_ASSET_DETAILS_LOAD_FAILED"
        )
    }

    func adsCacheAsset(_ asset: Asset) {
        lastAsset = asset
        lastClip = asset.clips?.first
        assetDetailCache[asset.id] = asset
    }

    func adsClearBlockingConnectivityIssue(assetId: String) {
        clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
    }

    func adsReconcileWorkflowState(asset: Asset) {
        reconcileWorkflowState(from: asset, source: .workflow)
    }

    func adsIsConnectivityIssue(_ error: Error) -> Bool {
        connectivityIssues.isConnectivityIssue(error)
    }

    func adsNoteBlockingConnectivityIssue(operation: String, assetId: String?) {
        noteBlockingConnectivityIssue(operation: operation, assetId: assetId)
    }
}
