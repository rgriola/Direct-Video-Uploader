// May 14, 2026 - 2:52am - GitHub Copilot (GPT-5.3-Codex)
import Foundation

struct StagedBatchSessionState {
    let currentBatchId: String
    let stagedBatchVideos: [SelectedVideo]
    let batchItems: [VideoBatchItem]
    let batchContext: VideoBatchContext?
    let batchProgress: Double
    let isBatchUploading: Bool
    let suppressPerAssetFormSheet: Bool
    let awaitingGroupedFormForBatch: Bool
    let pendingBatchFormData: [String: String]?
    let batchBubbleAnchorMessageId: String?
    let batchState: VideoBatchState
}

struct RestoredBatchSessionState {
    let currentBatchId: String
    let stagedBatchVideos: [SelectedVideo]
    let batchItems: [VideoBatchItem]
    let batchContext: VideoBatchContext?
    let batchProgress: Double
    let pendingBatchFormData: [String: String]?
    let batchState: VideoBatchState
    let isBatchUploading: Bool
    let suppressPerAssetFormSheet: Bool
    let awaitingGroupedFormForBatch: Bool
    let batchBubbleAnchorMessageId: String?
}

struct BatchRunToggleState {
    let isBatchUploading: Bool
    let suppressPerAssetFormSheet: Bool
    let batchProgress: Double?
}

struct BatchRunStartState {
    let isBatchUploading: Bool
    let suppressPerAssetFormSheet: Bool
    let batchState: VideoBatchState
    let submitError: String?
    let shouldPersistBatchState: Bool
}

struct BatchRunCompletionState {
    let batchState: VideoBatchState
    let shouldPersistBatchState: Bool
    let shouldClearStagedBatchVideos: Bool
    let shouldClearPendingBatchFormData: Bool
    let batchIdToClear: String?
}

struct BatchCompletionMessageTriggerState {
    let shouldAppendCompletionMessages: Bool
    let firstName: String
}

struct BatchRunFinalizationState {
    let completionState: BatchRunCompletionState
    let completionMessageTriggerState: BatchCompletionMessageTriggerState
}

struct BatchRunFinishState {
    let toggleState: BatchRunToggleState
    let finalizationState: BatchRunFinalizationState
}

struct BatchResetState {
    let currentBatchId: String?
    let stagedBatchVideos: [SelectedVideo]
    let batchItems: [VideoBatchItem]
    let batchContext: VideoBatchContext?
    let batchProgress: Double
    let isBatchUploading: Bool
    let suppressPerAssetFormSheet: Bool
    let batchState: VideoBatchState
    let pendingBatchFormData: [String: String]?
    let awaitingGroupedFormForBatch: Bool
    let batchBubbleAnchorMessageId: String?
}

struct GroupedBatchFormSubmissionState {
    let awaitingGroupedFormForBatch: Bool
    let pendingBatchFormData: [String: String]
    let batchContext: VideoBatchContext
    let showFormSheet: Bool
}

struct GroupedBatchFormPromptState {
    let awaitingGroupedFormForBatch: Bool
    let shouldRebuildFormFields: Bool
    let submitError: String?
    let showFormSheet: Bool
}

struct BatchSessionAssignmentState {
    let currentBatchId: String?
    let stagedBatchVideos: [SelectedVideo]
    let batchItems: [VideoBatchItem]
    let batchContext: VideoBatchContext?
    let pendingBatchFormData: [String: String]?
    let batchState: VideoBatchState
    let isBatchUploading: Bool
    let suppressPerAssetFormSheet: Bool
    let awaitingGroupedFormForBatch: Bool
    let batchBubbleAnchorMessageId: String?
    let batchProgress: Double?
}

@MainActor
final class BatchStateTransitionService {
    func makeStagedBatchSession(
        selectedVideos: [SelectedVideo],
        anchorMessageId: String?
    ) -> StagedBatchSessionState {
        StagedBatchSessionState(
            currentBatchId: UUID().uuidString,
            stagedBatchVideos: selectedVideos,
            batchItems: makeStagedBatchItems(selectedVideos: selectedVideos),
            batchContext: nil,
            batchProgress: 0,
            isBatchUploading: false,
            suppressPerAssetFormSheet: false,
            awaitingGroupedFormForBatch: false,
            pendingBatchFormData: nil,
            batchBubbleAnchorMessageId: anchorMessageId,
            batchState: .queued
        )
    }

    func makeRunStartState() -> BatchRunStartState {
        BatchRunStartState(
            isBatchUploading: true,
            suppressPerAssetFormSheet: true,
            batchState: .uploading,
            submitError: nil,
            shouldPersistBatchState: true
        )
    }

    func makeRunCompletedState(batchItems: [VideoBatchItem]) -> BatchRunToggleState {
        BatchRunToggleState(
            isBatchUploading: false,
            suppressPerAssetFormSheet: false,
            batchProgress: computeProgress(items: batchItems)
        )
    }

    func makeRunCompletionState(
        nextState: VideoBatchState,
        shouldClearDraftState: Bool,
        batchIdToClear: String?
    ) -> BatchRunCompletionState {
        BatchRunCompletionState(
            batchState: nextState,
            shouldPersistBatchState: !shouldClearDraftState,
            shouldClearStagedBatchVideos: shouldClearDraftState,
            shouldClearPendingBatchFormData: shouldClearDraftState,
            batchIdToClear: makeRunCompletionBatchIdToClear(
                shouldClearDraftState: shouldClearDraftState,
                batchIdToClear: batchIdToClear
            )
        )
    }

    func makeCompletionMessageTriggerState(
        batchItems: [VideoBatchItem],
        fullName: String?
    ) -> BatchCompletionMessageTriggerState {
        let firstName = makeFirstName(fullName: fullName)

        return BatchCompletionMessageTriggerState(
            shouldAppendCompletionMessages: shouldAppendCompletionMessages(batchItems: batchItems),
            firstName: firstName
        )
    }

    func makeRunFinalizationState(
        nextState: VideoBatchState,
        shouldClearDraftState: Bool,
        batchIdToClear: String?,
        batchItems: [VideoBatchItem],
        fullName: String?
    ) -> BatchRunFinalizationState {
        let completionState = makeRunCompletionState(
            nextState: nextState,
            shouldClearDraftState: shouldClearDraftState,
            batchIdToClear: batchIdToClear
        )
        let completionMessageTriggerState = makeCompletionMessageTriggerState(
            batchItems: batchItems,
            fullName: fullName
        )

        return BatchRunFinalizationState(
            completionState: completionState,
            completionMessageTriggerState: completionMessageTriggerState
        )
    }

    func makeRunFinishState(
        batchItems: [VideoBatchItem],
        nextState: VideoBatchState,
        shouldClearDraftState: Bool,
        batchIdToClear: String?,
        fullName: String?
    ) -> BatchRunFinishState {
        let toggleState = makeRunCompletedState(batchItems: batchItems)
        let finalizationState = makeRunFinalizationState(
            nextState: nextState,
            shouldClearDraftState: shouldClearDraftState,
            batchIdToClear: batchIdToClear,
            batchItems: batchItems,
            fullName: fullName
        )

        return BatchRunFinishState(
            toggleState: toggleState,
            finalizationState: finalizationState
        )
    }

    func makeRestoredBatchSession(
        snapshot: PendingBatchRestoreSnapshot,
        existingAnchorMessageId: String?,
        fallbackAnchorMessageId: String?
    ) -> RestoredBatchSessionState {
        let anchorMessageId = makeRestoredBatchAnchorMessageId(
            existingAnchorMessageId: existingAnchorMessageId,
            fallbackAnchorMessageId: fallbackAnchorMessageId
        )

        return RestoredBatchSessionState(
            currentBatchId: snapshot.batchId,
            stagedBatchVideos: snapshot.stagedBatchVideos,
            batchItems: snapshot.batchItems,
            batchContext: snapshot.batchContext,
            batchProgress: computeProgress(items: snapshot.batchItems),
            pendingBatchFormData: snapshot.pendingBatchFormData,
            batchState: snapshot.batchState,
            isBatchUploading: false,
            suppressPerAssetFormSheet: false,
            awaitingGroupedFormForBatch: false,
            batchBubbleAnchorMessageId: anchorMessageId
        )
    }

    func makeResetState() -> BatchResetState {
        BatchResetState(
            currentBatchId: nil,
            stagedBatchVideos: [],
            batchItems: [],
            batchContext: nil,
            batchProgress: 0,
            isBatchUploading: false,
            suppressPerAssetFormSheet: false,
            batchState: .queued,
            pendingBatchFormData: nil,
            awaitingGroupedFormForBatch: false,
            batchBubbleAnchorMessageId: nil
        )
    }

    func makeGroupedBatchFormSubmissionState(
        formData: [String: String]
    ) -> GroupedBatchFormSubmissionState {
        GroupedBatchFormSubmissionState(
            awaitingGroupedFormForBatch: false,
            pendingBatchFormData: formData,
            batchContext: makeGroupedBatchContext(formData: formData),
            showFormSheet: false
        )
    }

    func makeGroupedBatchFormPromptState() -> GroupedBatchFormPromptState {
        GroupedBatchFormPromptState(
            awaitingGroupedFormForBatch: true,
            shouldRebuildFormFields: true,
            submitError: nil,
            showFormSheet: true
        )
    }

    func makeBatchSessionAssignmentState(
        from stagedSession: StagedBatchSessionState
    ) -> BatchSessionAssignmentState {
        makeBatchSessionAssignmentState(
            currentBatchId: stagedSession.currentBatchId,
            stagedBatchVideos: stagedSession.stagedBatchVideos,
            batchItems: stagedSession.batchItems,
            batchContext: stagedSession.batchContext,
            pendingBatchFormData: stagedSession.pendingBatchFormData,
            batchState: stagedSession.batchState,
            isBatchUploading: stagedSession.isBatchUploading,
            suppressPerAssetFormSheet: stagedSession.suppressPerAssetFormSheet,
            awaitingGroupedFormForBatch: stagedSession.awaitingGroupedFormForBatch,
            batchBubbleAnchorMessageId: stagedSession.batchBubbleAnchorMessageId,
            batchProgress: stagedSession.batchProgress
        )
    }

    func makeBatchSessionAssignmentState(
        from restoredSession: RestoredBatchSessionState
    ) -> BatchSessionAssignmentState {
        makeBatchSessionAssignmentState(
            currentBatchId: restoredSession.currentBatchId,
            stagedBatchVideos: restoredSession.stagedBatchVideos,
            batchItems: restoredSession.batchItems,
            batchContext: restoredSession.batchContext,
            pendingBatchFormData: restoredSession.pendingBatchFormData,
            batchState: restoredSession.batchState,
            isBatchUploading: restoredSession.isBatchUploading,
            suppressPerAssetFormSheet: restoredSession.suppressPerAssetFormSheet,
            awaitingGroupedFormForBatch: restoredSession.awaitingGroupedFormForBatch,
            batchBubbleAnchorMessageId: restoredSession.batchBubbleAnchorMessageId,
            batchProgress: restoredSession.batchProgress
        )
    }

    func makeBatchSessionAssignmentState(
        from resetState: BatchResetState
    ) -> BatchSessionAssignmentState {
        makeBatchSessionAssignmentState(
            currentBatchId: resetState.currentBatchId,
            stagedBatchVideos: resetState.stagedBatchVideos,
            batchItems: resetState.batchItems,
            batchContext: resetState.batchContext,
            pendingBatchFormData: resetState.pendingBatchFormData,
            batchState: resetState.batchState,
            isBatchUploading: resetState.isBatchUploading,
            suppressPerAssetFormSheet: resetState.suppressPerAssetFormSheet,
            awaitingGroupedFormForBatch: resetState.awaitingGroupedFormForBatch,
            batchBubbleAnchorMessageId: resetState.batchBubbleAnchorMessageId,
            batchProgress: resetState.batchProgress
        )
    }

    private func makeBatchSessionAssignmentState(
        currentBatchId: String?,
        stagedBatchVideos: [SelectedVideo],
        batchItems: [VideoBatchItem],
        batchContext: VideoBatchContext?,
        pendingBatchFormData: [String: String]?,
        batchState: VideoBatchState,
        isBatchUploading: Bool,
        suppressPerAssetFormSheet: Bool,
        awaitingGroupedFormForBatch: Bool,
        batchBubbleAnchorMessageId: String?,
        batchProgress: Double?
    ) -> BatchSessionAssignmentState {
        BatchSessionAssignmentState(
            currentBatchId: currentBatchId,
            stagedBatchVideos: stagedBatchVideos,
            batchItems: batchItems,
            batchContext: batchContext,
            pendingBatchFormData: pendingBatchFormData,
            batchState: batchState,
            isBatchUploading: isBatchUploading,
            suppressPerAssetFormSheet: suppressPerAssetFormSheet,
            awaitingGroupedFormForBatch: awaitingGroupedFormForBatch,
            batchBubbleAnchorMessageId: batchBubbleAnchorMessageId,
            batchProgress: batchProgress
        )
    }

    func makeRestoredActiveAssetIds(batchItems: [VideoBatchItem]) -> [String] {
        var seen = Set<String>()

        return batchItems.compactMap(\.assetId).filter { assetId in
            guard isRestoredActiveAssetIdValid(assetId) else { return false }
            return seen.insert(assetId).inserted
        }
    }

    private func computeProgress(items: [VideoBatchItem]) -> Double {
        guard !items.isEmpty else { return 0 }

        let total = items.reduce(0.0) { partial, item in
            partial + clampProgress(item.progress)
        }

        return total / Double(items.count)
    }

    private func clampProgress(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }

    private func makeRestoredBatchAnchorMessageId(
        existingAnchorMessageId: String?,
        fallbackAnchorMessageId: String?
    ) -> String? {
        existingAnchorMessageId ?? fallbackAnchorMessageId
    }

    private func shouldAppendCompletionMessages(batchItems: [VideoBatchItem]) -> Bool {
        !batchItems.isEmpty
    }

    private func makeRunCompletionBatchIdToClear(
        shouldClearDraftState: Bool,
        batchIdToClear: String?
    ) -> String? {
        guard shouldClearDraftState else { return nil }
        return batchIdToClear
    }

    private func isRestoredActiveAssetIdValid(_ assetId: String) -> Bool {
        !assetId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func makeFirstName(fullName: String?) -> String {
        fullName?
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
            ?? "there"
    }

    private func makeStagedBatchItems(selectedVideos: [SelectedVideo]) -> [VideoBatchItem] {
        selectedVideos.map {
            VideoBatchItem(localId: $0.id, fileName: $0.fileName, org: nil)
        }
    }

    private func makeGroupedBatchContext(formData: [String: String]) -> VideoBatchContext {
        VideoBatchContext(
            slug: formData["slug"] ?? "",
            type: formData["type"] ?? "Raw",
            description: formData["description"] ?? "",
            priority: formData["priority"] ?? "Low",
            destination: formData["destination"],
            org: formData["org"]
        )
    }
}
