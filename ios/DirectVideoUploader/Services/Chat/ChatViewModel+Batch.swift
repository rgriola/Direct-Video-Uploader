// May 14, 2026 - 5:30pm - GitHub Copilot (Claude Opus 4.7)
//
// Extension extracted from ChatViewModel.swift during P8 file decomposition.
// Added server-side batch reconciliation on restore to clear stale cards
// when server-side asset records are gone (e.g., admin DB nuke).

import Foundation
import UIKit
import Observation

extension ChatViewModel {

    // MARK: - Video Staging (iOS 26.3 Flow)

    /// Stage a video for preview in chat — called after user confirms in the library picker.
    func stageVideo(
        fileURL: URL, fileName: String, metadata: VideoMetadata, phAssetIdentifier: String? = nil
    ) async {
        // If a conversation is archived, start fresh
        if isArchived {
            startNewConversation()
        }

        isProcessingVideo = true
        defer { isProcessingVideo = false }

        // Store PHAsset identifier for re-upload recovery
        self.pendingPHAssetIdentifier = phAssetIdentifier

        // Generate thumbnail from video
        let thumbnail = await StagedVideo.generateThumbnail(from: fileURL)

        // Format creation date for display
        let createdDate: String? = {
            guard let capturedAt = metadata.capturedAt else { return nil }
            return DVUDateFormatting.longDate(capturedAt)
        }()

        stagedVideo = StagedVideo(
            tempFileURL: fileURL,
            fileName: fileName,
            createdDate: createdDate,
            thumbnail: thumbnail,
            metadata: metadata
        )
    }

    /// Stage one or more selected videos. Single-item selection keeps the existing flow.
    func stageVideoBatch(selectedVideos: [SelectedVideo]) async {
        guard !selectedVideos.isEmpty else { return }

        if selectedVideos.count == 1, let single = selectedVideos.first {
            resetBatchState(clearDisk: true)
            await stageVideo(
                fileURL: single.fileURL,
                fileName: single.fileName,
                metadata: single.metadata,
                phAssetIdentifier: single.phAssetIdentifier
            )
            return
        }

        if isArchived || currentAssetId != nil {
            startNewConversation()
        }

        cancelStagedVideo()
        resetBatchState(clearDisk: true)

        let stagedSession = batchStateTransitionService.makeStagedBatchSession(
            selectedVideos: selectedVideos,
            anchorMessageId: messages.last?.id
        )
        applyBatchSessionState(
            batchStateTransitionService.makeBatchSessionAssignmentState(from: stagedSession)
        )

        form.originalFileName = "\(selectedVideos.count) videos"
        form.capturedAt = selectedVideos.first?.metadata.capturedAt
        form.clipCount = selectedVideos.count
        form.duration = selectedVideos.reduce(0) { $0 + $1.metadata.duration }
        form.submitError = nil
        if let first = selectedVideos.first {
            form.thumbnail = await StagedVideo.generateThumbnail(from: first.fileURL)
        }

        persistBatchState()
    }

    /// Open the grouped context form for a staged batch.
    func confirmBatchUpload() async {
        guard !stagedBatchVideos.isEmpty else { return }
        guard !isBatchUploading else { return }
        applyGroupedBatchFormPromptState(
            batchStateTransitionService.makeGroupedBatchFormPromptState()
        )
    }

    /// Retry only failed batch items.
    func retryFailedBatchItems() async {
        guard canRetryFailedBatchItems else { return }
        await runBatchUpload(retryFailedOnly: true)
    }

    /// Entry-point for ContextFormView submits; routes to batch or single-asset flow.
    func submitCurrentForm(formData: [String: String]) async {
        if awaitingGroupedFormForBatch {
            applyGroupedBatchFormSubmissionState(
                batchStateTransitionService.makeGroupedBatchFormSubmissionState(formData: formData)
            )
            await uploadBatchItemsSequentialOrBoundedConcurrency()
            return
        }

        guard let assetId = currentAssetId else { return }
        await submitForm(assetId: assetId, formData: formData)
    }

    /// Run the staged batch upload queue.
    func uploadBatchItemsSequentialOrBoundedConcurrency() async {
        await runBatchUpload(retryFailedOnly: false)
    }

    func applyGroupedBatchFormSubmissionState(
        _ submissionState: GroupedBatchFormSubmissionState
    ) {
        awaitingGroupedFormForBatch = submissionState.awaitingGroupedFormForBatch
        pendingBatchFormData = submissionState.pendingBatchFormData
        batchContext = submissionState.batchContext
        persistBatchState()
        showFormSheet = submissionState.showFormSheet
    }

    func applyGroupedBatchFormPromptState(_ promptState: GroupedBatchFormPromptState) {
        awaitingGroupedFormForBatch = promptState.awaitingGroupedFormForBatch
        if promptState.shouldRebuildFormFields {
            formFields = buildFormFields()
        }
        form.submitError = promptState.submitError
        showFormSheet = promptState.showFormSheet
    }

    /// Apply one grouped form payload to a specific asset.
    func applyGroupedFormToAsset(assetId: String) async -> Bool {
        guard
            let formData = groupedFormService.buildSequencedFormData(
                for: assetId,
                pendingBatchFormData: pendingBatchFormData,
                batchItems: batchItems
            )
        else { return false }
        return await groupedFormService.submitPayload(
            assetId: assetId,
            formData: formData,
            auth: auth,
            isConnectivityIssue: { self.connectivityIssues.isConnectivityIssue($0) },
            clearBlockingConnectivityIssue: { self.clearBlockingConnectivityIssueIfNeeded(assetId: $0) },
            noteBlockingConnectivityIssue: { operation, assetId in
                self.noteBlockingConnectivityIssue(operation: operation, assetId: assetId)
            },
            reportFailure: { [weak self] errorDescription in
                guard let self else { return }
                await self.reportError(
                    category: "form",
                    message: "Grouped form apply failed: \(errorDescription)",
                    severity: "ERROR",
                    assetId: assetId
                )
            }
        )
    }

    /// Cancel a staged batch before upload starts.
    func cancelStagedBatch() {
        resetBatchState(clearDisk: true)
        showFormSheet = false
    }

    func runBatchUpload(retryFailedOnly: Bool) async {
        guard shouldStartBatchRun() else { return }

        applyBatchRunStartState(batchStateTransitionService.makeRunStartState())
        await processBatchRunChunks(retryFailedOnly: retryFailedOnly)

        let runFinishState = makeBatchRunFinishState()
        applyBatchRunFinishState(runFinishState)
    }

    func shouldStartBatchRun() -> Bool {
        batchRunExecutionService.shouldStartRun(
            isBatchUploading: isBatchUploading,
            batchItems: batchItems,
            pendingBatchFormData: pendingBatchFormData
        )
    }

    func processBatchRunChunks(retryFailedOnly: Bool) async {
        for chunk in batchCoordinator.chunked(
            batchCoordinator.executionOrder(
                for: batchItems,
                retryFailedOnly: retryFailedOnly
            )
        ) {
            await withTaskGroup(of: Void.self) { group in
                for localId in chunk {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.processBatchItem(localId: localId)
                    }
                }
            }
        }
    }

    func applyBatchRunFinishState(_ runFinishState: BatchRunFinishState) {
        isBatchUploading = runFinishState.toggleState.isBatchUploading
        suppressPerAssetFormSheet = runFinishState.toggleState.suppressPerAssetFormSheet
        applyBatchProgressIfPresent(runFinishState.toggleState.batchProgress)
        applyBatchRunCompletionState(runFinishState.finalizationState.completionState)
        applyBatchCompletionMessageTrigger(
            runFinishState.finalizationState.completionMessageTriggerState
        )
    }

    func applyBatchRunStartState(_ startState: BatchRunStartState) {
        isBatchUploading = startState.isBatchUploading
        suppressPerAssetFormSheet = startState.suppressPerAssetFormSheet
        batchState = startState.batchState
        form.submitError = startState.submitError

        if startState.shouldPersistBatchState {
            persistBatchState()
        }
    }

    func makeBatchRunFinishState() -> BatchRunFinishState {
        let completion = batchRunExecutionService.completionState(
            batchItems: batchItems,
            currentBatchId: currentBatchId
        )

        return batchStateTransitionService.makeRunFinishState(
            batchItems: batchItems,
            nextState: completion.nextState,
            shouldClearDraftState: completion.shouldClearDraftState,
            batchIdToClear: completion.batchIdToClear,
            fullName: auth.currentUser?.name
        )
    }

    func applyBatchCompletionMessageTrigger(
        _ triggerState: BatchCompletionMessageTriggerState
    ) {
        guard triggerState.shouldAppendCompletionMessages else { return }
        appendBatchCompletionMessages(firstName: triggerState.firstName)
    }

    func applyBatchRunCompletionState(_ completionState: BatchRunCompletionState) {
        batchState = completionState.batchState

        if completionState.shouldPersistBatchState {
            persistBatchState()
            return
        }

        if completionState.shouldClearStagedBatchVideos {
            stagedBatchVideos.removeAll()
        }
        if completionState.shouldClearPendingBatchFormData {
            pendingBatchFormData = nil
        }
        if let batchIdToClear = completionState.batchIdToClear {
            PendingBatchStore.clear(batchId: batchIdToClear)
        }
    }

    func applyBatchSessionState(_ state: BatchSessionAssignmentState) {
        currentBatchId = state.currentBatchId
        stagedBatchVideos = state.stagedBatchVideos
        batchItems = state.batchItems
        batchContext = state.batchContext
        pendingBatchFormData = state.pendingBatchFormData
        batchState = state.batchState
        isBatchUploading = state.isBatchUploading
        suppressPerAssetFormSheet = state.suppressPerAssetFormSheet
        awaitingGroupedFormForBatch = state.awaitingGroupedFormForBatch
        batchBubbleAnchorMessageId = state.batchBubbleAnchorMessageId
        applyBatchProgressIfPresent(state.batchProgress)
    }

    func applyBatchProgressIfPresent(_ nextBatchProgress: Double?) {
        if let nextBatchProgress {
            batchProgress = nextBatchProgress
        }
    }

    func appendBatchCompletionMessages(firstName: String) {
        guard !batchItems.isEmpty else { return }

        let completionMessages = batchCompletionMessageService.makeCompletionMessages(
            batchItems: batchItems,
            firstName: firstName,
            batchClipDisplayByAssetId: batchClipDisplayByAssetId
        )

        for message in completionMessages {
            appendMessage(message, source: .workflow)
        }
    }

    func processBatchItem(localId: String) async {
        await batchItemProcessingService.process(
            localId: localId,
            host: self
        )
    }

    func noteBatchItemPreparedForCreation() {
        batchProgress = computeBatchProgress()
        persistBatchState()
    }

    func noteBatchItemPreparedForUpload(assetId: String) {
        setBatchClipPhase(assetId: assetId, phase: .uploading)
        updateBatchClipProgress(assetId: assetId, progress: 0)
        batchProgress = computeBatchProgress()
        persistBatchState()
    }

    func updateBatchUploadProgress(localId: String, progress: Double) {
        guard
            let update = batchItemLifecycleService.updateUploadProgress(
                localId: localId,
                progress: progress,
                batchItems: &batchItems
            )
        else {
            return
        }

        // Reserve final progress for grouped-form apply so the UI has clear phase transitions.
        updateBatchClipProgress(assetId: update.assetId, progress: update.progress)
        batchProgress = computeBatchProgress()
    }

    func noteBatchItemPreparedForApplyingForm(
        assetId: String,
        applyingUpdate: BatchItemProgressUpdate
    ) {
        setBatchClipPhase(assetId: assetId, phase: .processing)
        updateBatchClipProgress(
            assetId: applyingUpdate.assetId,
            progress: applyingUpdate.progress
        )
        batchProgress = computeBatchProgress()
        persistBatchState()
    }

    func noteBatchItemCompleted(completedUpdate: BatchItemProgressUpdate, fileURL: URL) {
        updateBatchClipProgress(
            assetId: completedUpdate.assetId,
            progress: completedUpdate.progress
        )
        cleanupTempFileIfNeeded(fileURL)
        batchProgress = computeBatchProgress()
        persistBatchState()
    }

    func createBatchAsset(
        fileName: String,
        fileURL: URL,
        thumbnail: UIImage?,
        createdDate: String?,
        hasLocation: Bool,
        phAssetIdentifier: String?
    ) async -> Asset? {
        await batchAssetFlowService.createBatchAsset(
            fileName: fileName,
            fileURL: fileURL,
            thumbnail: thumbnail,
            createdDate: createdDate,
            hasLocation: hasLocation,
            phAssetIdentifier: phAssetIdentifier,
            auth: auth,
            transport: batchUploadTransportService,
            presentation: batchAssetPresentationService,
            host: self
        )
    }

    func uploadBatchVideo(
        assetId: String,
        fileURL: URL,
        metadata: VideoMetadata,
        onProgress: @escaping (Double) -> Void
    ) async -> Bool {
        await batchAssetFlowService.uploadBatchVideo(
            assetId: assetId,
            fileURL: fileURL,
            metadata: metadata,
            authToken: auth.token,
            transport: batchUploadTransportService,
            onProgress: onProgress,
            host: self
        )
    }

    func markBatchItemFailedAtIndex(index: Int, message: String) {
        batchItemStateService.markFailedAtIndex(
            index: index,
            message: message,
            batchItems: &batchItems,
            batchState: &batchState,
            batchProgress: &batchProgress,
            batchClipDisplayByAssetId: &batchClipDisplayByAssetId,
            batchClipDisplayService: batchClipDisplayService
        )

        persistBatchState()
    }

    func computeBatchProgress() -> Double {
        batchItemStateService.computeProgress(items: batchItems)
    }

    func persistBatchState() {
        guard let currentBatchId else { return }
        let snapshot = VideoBatch(
            id: currentBatchId,
            createdAt: Date(),
            state: batchState,
            items: batchItems,
            context: batchContext,
            stagedVideos: stagedBatchVideos.isEmpty ? nil : stagedBatchVideos,
            groupedFormData: pendingBatchFormData
        )
        PendingBatchStore.save(snapshot)
    }

    func restorePendingBatchState() {
        guard let pending = PendingBatchStore.loadLatest() else { return }
        if pending.state == .complete {
            PendingBatchStore.clear(batchId: pending.id)
            return
        }

        let restoredSnapshot = pendingBatchRestoreService.makeSnapshot(
            pending: pending,
            uploadQueueRecovery: uploadQueueRecovery
        )

        let restoredSession = batchStateTransitionService.makeRestoredBatchSession(
            snapshot: restoredSnapshot,
            existingAnchorMessageId: batchBubbleAnchorMessageId,
            fallbackAnchorMessageId: messages.last?.id
        )
        applyBatchSessionState(
            batchStateTransitionService.makeBatchSessionAssignmentState(from: restoredSession)
        )

        applyRestoredBatchAssetOwnership(
            batchStateTransitionService.makeRestoredActiveAssetIds(batchItems: batchItems)
        )

        if restoredSnapshot.shouldClearAfterRestore {
            PendingBatchStore.clear(batchId: restoredSnapshot.batchId)
            return
        }

        persistBatchState()

        // Server reconciliation: if the server has none of this batch's assets
        // (e.g., DB nuke / account reset), drop the stale card. Runs in the
        // background so it doesn't delay UI restoration.
        Task { [weak self] in
            await self?.reconcileBatchAgainstServer()
        }

        // Phantom-task sweep: any item still marked .uploading / .creatingAsset
        // whose persisted URLSession task didn't survive the prior process
        // would otherwise hang the run loop forever. Mark them failed so the
        // batch can finish or the user can retry. Always followed by a
        // finalize pass — restore may already have left items in terminal
        // states while batchState lingered at .uploading.
        Task { [weak self] in
            await self?.sweepPhantomUploadingItems()
            await self?.finalizeBatchIfQuiescent()
        }
    }

    /// Verify a restored batch still has at least one corresponding asset on
    /// the server. If every assetId returns 404, the batch is stale (server
    /// state was wiped) and we clear it. Network errors are treated as
    /// "unknown" and leave the batch untouched.
    func reconcileBatchAgainstServer() async {
        guard let batchId = currentBatchId else { return }
        let assetIds = batchItems.compactMap { $0.assetId }.filter { !$0.isEmpty }
        guard !assetIds.isEmpty else { return }

        let detailService = AssetDetailService()
        var sawNotFound = false
        for assetId in assetIds {
            do {
                let result = try await detailService.fetchAssetDetail(
                    auth: auth, assetId: assetId
                )
                if result.statusCode == 200 {
                    // At least one asset still exists — batch is real.
                    return
                }
                if result.statusCode == 404 {
                    sawNotFound = true
                    continue
                }
                // 401/403/5xx → don't trust this signal; bail.
                return
            } catch {
                // Network failure — be safe, keep the batch.
                return
            }
        }

        guard sawNotFound else { return }
        // Confirm batch hasn't changed during async work.
        guard currentBatchId == batchId else { return }

        AppLog.chat.info(
            "Batch reconciliation: all \(assetIds.count, privacy: .public) asset(s) returned 404 — clearing stale batch \(batchId, privacy: .public)"
        )

        // Capture identifiers we need to purge BEFORE resetBatchState wipes them.
        let staleAssetIds = Set(assetIds)
        let staleAnchorId = batchBubbleAnchorMessageId

        resetBatchState(clearDisk: true)

        // Also purge the stale chat messages tied to this batch — the anchor
        // bubble and any per-clip messages — so the timeline doesn't visually
        // "stack" the dead batch above a freshly staged one.
        messages.removeAll { message in
            if let anchorId = staleAnchorId, message.id == anchorId { return true }
            if let assetId = message.assetId, staleAssetIds.contains(assetId) { return true }
            return false
        }
    }

    func applyRestoredBatchAssetOwnership(_ assetIds: [String]) {
        for assetId in assetIds {
            chatOwnership.registerActiveAsset(assetId)
        }
    }

    /// Sweep batch items left in `.uploading` / `.creatingAsset` after restore
    /// whose backing URLSession task is no longer alive in this process. Those
    /// items will never report progress or completion, so the batch run loop
    /// hangs ("Uploading queue…" with no actual upload). Demote them to
    /// `.failed` with a clear reason so the user can retry or the run finishes.
    func sweepPhantomUploadingItems() async {
        guard let batchId = currentBatchId else { return }

        // Snapshot the items we need to check up front so we don't observe
        // mutations from concurrent legitimate progress callbacks.
        let candidateIds: [String] = batchItems.compactMap { item in
            switch item.status {
            case .uploading, .creatingAsset: return item.assetId
            default: return nil
            }
        }
        guard !candidateIds.isEmpty else { return }

        let liveTaskIds = await BackgroundUploadSessionCoordinator.shared
            .liveUploadTaskIdentifiers()
        let persistedTasksByAssetId = uploadQueueRecovery.latestTasksByAssetId()

        // Confirm the batch hasn't been swapped out while we awaited.
        guard currentBatchId == batchId else { return }

        var didChange = false
        for assetId in candidateIds {
            guard let index = batchItems.firstIndex(where: { $0.assetId == assetId }) else {
                continue
            }
            // Re-check status — a real progress event may have moved the item.
            switch batchItems[index].status {
            case .uploading, .creatingAsset: break
            default: continue
            }

            let persisted = persistedTasksByAssetId[assetId]
            let hasLiveTask: Bool = {
                guard let persisted, persisted.state == .running || persisted.state == .pending
                else { return false }
                guard let identifier = persisted.taskIdentifier else { return false }
                return liveTaskIds.contains(identifier)
            }()
            if hasLiveTask { continue }

            batchItems[index].status = .failed
            batchItems[index].progress = 0
            batchItems[index].error =
                "Upload interrupted by app restart. Tap Retry Failed."
            didChange = true
            AppLog.chat.info(
                "Phantom upload swept: asset \(assetId, privacy: .public) marked failed (no live URLSession task)"
            )
        }

        if didChange {
            persistBatchState()
        }
    }

    /// If the batch has no items in an active phase but `batchState` is still
    /// `.uploading` (or `.queued`/`.indexing`), drive it through the same
    /// completion pipeline the live run loop uses so the bubble flips to
    /// `.partialFailed` / `.complete` and the spinner stops. Safe no-op when
    /// the run loop is actively processing.
    func finalizeBatchIfQuiescent() async {
        guard currentBatchId != nil else { return }
        guard !isBatchUploading else { return }

        let stillActive = batchItems.contains { item in
            switch item.status {
            case .queued, .creatingAsset, .uploading, .applyingForm: return true
            default: return false
            }
        }
        guard !stillActive else { return }

        switch batchState {
        case .uploading, .queued, .indexing:
            break
        default:
            return
        }

        let priorState = batchState
        AppLog.chat.info(
            "Finalizing quiescent batch — no active items, transitioning out of \(String(describing: priorState), privacy: .public)"
        )
        let runFinishState = makeBatchRunFinishState()
        applyBatchRunFinishState(runFinishState)
    }

    func rehydratePersistedUploadQueueState() {
        guard let rehydratePlan = uploadQueueRehydratePlanService.makePlan(
            existingMessages: messages,
            batchItems: batchItems,
            uploadQueueRecovery: uploadQueueRecovery
        ) else { return }

        uploadQueueRehydrateExecutionService.execute(
            plan: rehydratePlan,
            host: self
        )
    }

    func reconcileAssetDetailsAfterUploadQueueRehydrate(_ assetIds: [String]) {
        Task { @MainActor in
            for assetId in assetIds {
                await fetchAssetDetail(
                    assetId: assetId,
                    presentErrorsInChat: false,
                    reason: "upload-queue-rehydrate"
                )
            }
        }
    }

    func syncBatchDisplayStateForRehydratedAsset(assetId: String) {
        guard let index = batchItems.firstIndex(where: { $0.assetId == assetId }) else {
            return
        }

        guard batchItems[index].status != .complete else {
            return
        }

        setBatchClipPhase(assetId: assetId, phase: phaseForBatchItemStatus(batchItems[index].status))
        updateBatchClipProgress(assetId: assetId, progress: batchItems[index].progress)
    }

    func resetBatchState(clearDisk: Bool) {
        let batchIdToClear = currentBatchId
        let videosToCleanup = stagedBatchVideos

        for video in videosToCleanup {
            cleanupTempFileIfNeeded(video.fileURL)
        }

        let resetState = batchStateTransitionService.makeResetState()
        applyBatchSessionState(
            batchStateTransitionService.makeBatchSessionAssignmentState(from: resetState)
        )
        groupedFormService.resetSubmitAttempts()

        if clearDisk, let batchIdToClear {
            PendingBatchStore.clear(batchId: batchIdToClear)
        }
    }

    func cleanupTempFileIfNeeded(_ url: URL) {
        let tempDir = FileManager.default.temporaryDirectory.path
        if url.path.hasPrefix(tempDir) {
            cleanupTempFile(url)
        }
    }

    /// User confirmed upload — proceed with create asset + upload.
    func confirmStagedUpload() async {
        guard let staged = stagedVideo else { return }

        // Auto-archive previous upload so state doesn't leak between uploads
        if isArchived || currentAssetId != nil {
            startNewConversation()
        }

        let fileURL = staged.tempFileURL
        let fileName = staged.fileName
        let metadata = staged.metadata

        prepareStagedContext(staged)

        uploadTask = Task {
            guard let asset = await createAsset(fileName: fileName, fileURL: fileURL) else {
                return
            }
            AppLog.upload.info("Asset created: \(asset.mediasourceId ?? asset.id)")

            savePHAssetIdentifier(for: asset.id)
            await uploadVideo(assetId: asset.id, fileURL: fileURL, metadata: metadata)

            guard !Task.isCancelled else { return }

            if transcribeOnUpload {
                await transcribeAndReport(assetId: asset.id, fileURL: fileURL)
                transcribeOnUpload = false
            }

            cleanupTempFile(fileURL)
        }
        await uploadTask?.value
        uploadTask = nil
    }

    /// Cancel an in-progress upload.
    func cancelUpload() {
        uploadTask?.cancel()
        uploadTask = nil
        isUploading = false
        uploadProgress = 0
        if let assetId = currentAssetId {
            _ = promoteWorkflowStage(for: assetId, to: .failed)
        }
        appendErrorBubble("Upload cancelled.", code: "IOS_UPLOAD_CANCELLED")
    }

    /// User cancelled staged video — discard and clean up.
    func cancelStagedVideo() {
        if let staged = stagedVideo {
            try? FileManager.default.removeItem(at: staged.tempFileURL)
        }
        stagedVideo = nil
    }

}
