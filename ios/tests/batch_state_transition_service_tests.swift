// May 14, 2026 - 2:52am - GitHub Copilot (GPT-5.3-Codex)
import Foundation

// Minimal stub so VideoBatch.swift can compile in this test runner context.
struct VideoMetadata: Codable {
    let duration: Int
    let resolution: String
    let codec: String
    let orientation: String
    let deviceModel: String
    let osVersion: String
    let capturedAt: String?
    let gpsLat: Double?
    let gpsLon: Double?
    let gpsAltitude: Double?
}

// Minimal stub used by BatchStateTransitionService.makeRestoredBatchSession.
struct PendingBatchRestoreSnapshot {
    let batchId: String
    let batchItems: [VideoBatchItem]
    let batchContext: VideoBatchContext?
    let stagedBatchVideos: [SelectedVideo]
    let pendingBatchFormData: [String: String]?
    let batchState: VideoBatchState
    let shouldClearAfterRestore: Bool
}

private func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { return }
    fputs("Assertion failed: \(message)\n", stderr)
    exit(1)
}

private func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    assertTrue(lhs == rhs, "\(message) | left=\(lhs) right=\(rhs)")
}

@MainActor
private func runStagedSessionTests() {
    let service = BatchStateTransitionService()

    let videoA = SelectedVideo(
        id: "local-a",
        fileURL: URL(fileURLWithPath: "/tmp/a.mov"),
        fileName: "a.mov",
        metadata: VideoMetadata(
            duration: 10,
            resolution: "1920x1080",
            codec: "h264",
            orientation: "landscape",
            deviceModel: "iPhone",
            osVersion: "iOS",
            capturedAt: nil,
            gpsLat: nil,
            gpsLon: nil,
            gpsAltitude: nil
        )
    )
    let videoB = SelectedVideo(
        id: "local-b",
        fileURL: URL(fileURLWithPath: "/tmp/b.mov"),
        fileName: "b.mov",
        metadata: VideoMetadata(
            duration: 12,
            resolution: "1920x1080",
            codec: "h264",
            orientation: "landscape",
            deviceModel: "iPhone",
            osVersion: "iOS",
            capturedAt: nil,
            gpsLat: nil,
            gpsLon: nil,
            gpsAltitude: nil
        )
    )

    let staged = service.makeStagedBatchSession(
        selectedVideos: [videoA, videoB],
        anchorMessageId: "anchor-1"
    )

    assertTrue(!staged.currentBatchId.isEmpty, "Staged session should generate a batch id")
    assertEqual(staged.stagedBatchVideos.count, 2, "Staged session should keep selected videos")
    assertEqual(staged.batchItems.count, 2, "Staged session should create one item per selected video")
    assertEqual(staged.batchItems[0].localId, "local-a", "First item local id should map from selection")
    assertEqual(staged.batchItems[1].localId, "local-b", "Second item local id should map from selection")
    assertEqual(staged.batchProgress, 0, "Staged session should start at zero progress")
    assertEqual(staged.isBatchUploading, false, "Staged session should not be uploading")
    assertEqual(
        staged.suppressPerAssetFormSheet,
        false,
        "Staged session should not suppress per-asset form sheet"
    )
    assertEqual(
        staged.awaitingGroupedFormForBatch,
        false,
        "Staged session should not wait for grouped form by default"
    )
    assertEqual(staged.batchBubbleAnchorMessageId, "anchor-1", "Anchor message id should be preserved")
    assertEqual(staged.batchState, .queued, "Staged session state should be queued")

    print("batch_state_transition_staged_session_tests: PASS")
}

@MainActor
private func runRunToggleTests() {
    let service = BatchStateTransitionService()

    let start = service.makeRunStartState()
    assertEqual(start.isBatchUploading, true, "Run start should set uploading to true")
    assertEqual(
        start.suppressPerAssetFormSheet,
        true,
        "Run start should suppress per-asset form sheet"
    )
    assertEqual(start.batchState, .uploading, "Run start should set batch state to uploading")
    assertEqual(start.submitError, nil, "Run start should clear form submit error")
    assertEqual(start.shouldPersistBatchState, true, "Run start should persist batch state")

    let completed = service.makeRunCompletedState(
        batchItems: [
            VideoBatchItem(localId: "local-a", fileName: "a.mov", progress: 0.25),
            VideoBatchItem(localId: "local-b", fileName: "b.mov", progress: 0.75),
        ]
    )
    assertEqual(completed.isBatchUploading, false, "Run complete should set uploading to false")
    assertEqual(
        completed.suppressPerAssetFormSheet,
        false,
        "Run complete should unsuppress per-asset form sheet"
    )
    assertEqual(
        completed.batchProgress,
        0.5,
        "Run complete should include computed batch progress"
    )

    let clamped = service.makeRunCompletedState(
        batchItems: [
            VideoBatchItem(localId: "local-c", fileName: "c.mov", progress: -0.5),
            VideoBatchItem(localId: "local-d", fileName: "d.mov", progress: 1.5),
        ]
    )
    assertEqual(
        clamped.batchProgress,
        0.5,
        "Run complete should clamp per-item progress into the 0...1 range before averaging"
    )

    print("batch_state_transition_run_toggle_tests: PASS")
}

@MainActor
private func runRunCompletionStateTests() {
    let service = BatchStateTransitionService()

    let partialFailure = service.makeRunCompletionState(
        nextState: .partialFailed,
        shouldClearDraftState: false,
        batchIdToClear: "batch-1"
    )
    assertEqual(
        partialFailure.batchState,
        .partialFailed,
        "Run completion state should preserve next batch state"
    )
    assertEqual(
        partialFailure.shouldPersistBatchState,
        true,
        "Run completion should persist state when draft should not clear"
    )
    assertEqual(
        partialFailure.shouldClearStagedBatchVideos,
        false,
        "Run completion should keep staged videos when draft should not clear"
    )
    assertEqual(
        partialFailure.shouldClearPendingBatchFormData,
        false,
        "Run completion should keep pending grouped form data when draft should not clear"
    )
    assertEqual(
        partialFailure.batchIdToClear,
        nil,
        "Run completion should not clear persisted batch id when draft should not clear"
    )

    let completed = service.makeRunCompletionState(
        nextState: .complete,
        shouldClearDraftState: true,
        batchIdToClear: "batch-2"
    )
    assertEqual(completed.batchState, .complete, "Completed run should map complete state")
    assertEqual(
        completed.shouldPersistBatchState,
        false,
        "Completed run should skip persist when draft should clear"
    )
    assertEqual(
        completed.shouldClearStagedBatchVideos,
        true,
        "Completed run should clear staged videos"
    )
    assertEqual(
        completed.shouldClearPendingBatchFormData,
        true,
        "Completed run should clear pending grouped form data"
    )
    assertEqual(
        completed.batchIdToClear,
        "batch-2",
        "Completed run should carry batch id to clear"
    )

    let completedWithoutBatchId = service.makeRunCompletionState(
        nextState: .complete,
        shouldClearDraftState: true,
        batchIdToClear: nil
    )
    assertEqual(
        completedWithoutBatchId.batchIdToClear,
        nil,
        "Completed run should keep batch id clear target nil when no id is provided"
    )

    print("batch_state_transition_run_completion_state_tests: PASS")
}

@MainActor
private func runRunFinalizationStateTests() {
    let service = BatchStateTransitionService()

    let partialFailure = service.makeRunFinalizationState(
        nextState: .partialFailed,
        shouldClearDraftState: false,
        batchIdToClear: "batch-1",
        batchItems: [VideoBatchItem(localId: "local-1", fileName: "a.mov")],
        fullName: "David Burgess"
    )
    assertEqual(
        partialFailure.completionState.batchState,
        .partialFailed,
        "Run finalization should include mapped completion state"
    )
    assertEqual(
        partialFailure.completionState.shouldPersistBatchState,
        true,
        "Run finalization should preserve completion persist behavior"
    )
    assertEqual(
        partialFailure.completionMessageTriggerState.shouldAppendCompletionMessages,
        true,
        "Run finalization should include trigger append decision"
    )
    assertEqual(
        partialFailure.completionMessageTriggerState.firstName,
        "David",
        "Run finalization should include parsed first name"
    )

    let completed = service.makeRunFinalizationState(
        nextState: .complete,
        shouldClearDraftState: true,
        batchIdToClear: "batch-2",
        batchItems: [],
        fullName: nil
    )
    assertEqual(
        completed.completionState.batchIdToClear,
        "batch-2",
        "Run finalization should include batch id clear mapping"
    )
    assertEqual(
        completed.completionMessageTriggerState.shouldAppendCompletionMessages,
        false,
        "Run finalization should include empty-batch trigger decision"
    )
    assertEqual(
        completed.completionMessageTriggerState.firstName,
        "there",
        "Run finalization should include fallback first name"
    )

    print("batch_state_transition_run_finalization_state_tests: PASS")
}

@MainActor
private func runRunFinishStateTests() {
    let service = BatchStateTransitionService()

    let partialFailure = service.makeRunFinishState(
        batchItems: [
            VideoBatchItem(localId: "local-1", fileName: "a.mov", progress: 0.25),
            VideoBatchItem(localId: "local-2", fileName: "b.mov", progress: 0.75),
        ],
        nextState: .partialFailed,
        shouldClearDraftState: false,
        batchIdToClear: "batch-1",
        fullName: "David Burgess"
    )
    assertEqual(
        partialFailure.toggleState.batchProgress,
        0.5,
        "Run finish state should include computed run-completed progress"
    )
    assertEqual(
        partialFailure.finalizationState.completionState.batchState,
        .partialFailed,
        "Run finish state should include mapped finalization completion state"
    )
    assertEqual(
        partialFailure.finalizationState.completionMessageTriggerState.firstName,
        "David",
        "Run finish state should include parsed first name"
    )

    let completed = service.makeRunFinishState(
        batchItems: [],
        nextState: .complete,
        shouldClearDraftState: true,
        batchIdToClear: "batch-2",
        fullName: nil
    )
    assertEqual(
        completed.toggleState.batchProgress,
        0,
        "Run finish state should include zero progress for empty items"
    )
    assertEqual(
        completed.finalizationState.completionState.batchIdToClear,
        "batch-2",
        "Run finish state should include completion clear id"
    )
    assertEqual(
        completed.finalizationState.completionMessageTriggerState.shouldAppendCompletionMessages,
        false,
        "Run finish state should skip completion messages for empty items"
    )

    print("batch_state_transition_run_finish_state_tests: PASS")
}

@MainActor
private func runCompletionMessageTriggerStateTests() {
    let service = BatchStateTransitionService()

    let emptyTrigger = service.makeCompletionMessageTriggerState(
        batchItems: [],
        fullName: "Taylor Briggs"
    )
    assertEqual(
        emptyTrigger.shouldAppendCompletionMessages,
        false,
        "Completion message trigger should skip append when there are no batch items"
    )
    assertEqual(
        emptyTrigger.firstName,
        "Taylor",
        "Completion message trigger should derive first name from full name"
    )

    let nonEmptyTrigger = service.makeCompletionMessageTriggerState(
        batchItems: [VideoBatchItem(localId: "local-1", fileName: "a.mov")],
        fullName: "Carrie Smith"
    )
    assertEqual(
        nonEmptyTrigger.shouldAppendCompletionMessages,
        true,
        "Completion message trigger should append when batch items exist"
    )
    assertEqual(
        nonEmptyTrigger.firstName,
        "Carrie",
        "Completion message trigger should carry parsed first name"
    )

    let fallbackNameTrigger = service.makeCompletionMessageTriggerState(
        batchItems: [VideoBatchItem(localId: "local-2", fileName: "b.mov")],
        fullName: nil
    )
    assertEqual(
        fallbackNameTrigger.firstName,
        "there",
        "Completion message trigger should fallback first name when full name is missing"
    )

    let whitespaceNameTrigger = service.makeCompletionMessageTriggerState(
        batchItems: [VideoBatchItem(localId: "local-3", fileName: "c.mov")],
        fullName: "  Carrie\tSmith\n"
    )
    assertEqual(
        whitespaceNameTrigger.firstName,
        "Carrie",
        "Completion message trigger should split first name on any whitespace"
    )

    let whitespaceOnlyNameTrigger = service.makeCompletionMessageTriggerState(
        batchItems: [VideoBatchItem(localId: "local-4", fileName: "d.mov")],
        fullName: "\t\n   "
    )
    assertEqual(
        whitespaceOnlyNameTrigger.firstName,
        "there",
        "Completion message trigger should fallback when full name is only whitespace"
    )

    print("batch_state_transition_completion_message_trigger_state_tests: PASS")
}

@MainActor
private func runRestoredSessionTests() {
    let service = BatchStateTransitionService()

    let snapshot = PendingBatchRestoreSnapshot(
        batchId: "batch-restore",
        batchItems: [
            VideoBatchItem(localId: "local-1", fileName: "one.mov", progress: 0.25),
            VideoBatchItem(localId: "local-2", fileName: "two.mov", progress: 0.75),
        ],
        batchContext: VideoBatchContext(
            slug: "desk",
            type: "Raw",
            description: "desc",
            priority: "Low",
            destination: nil,
            org: nil
        ),
        stagedBatchVideos: [],
        pendingBatchFormData: ["slug": "desk"],
        batchState: .uploading,
        shouldClearAfterRestore: false
    )

    let restoredUsingExistingAnchor = service.makeRestoredBatchSession(
        snapshot: snapshot,
        existingAnchorMessageId: "existing-anchor",
        fallbackAnchorMessageId: "fallback-anchor"
    )

    assertEqual(
        restoredUsingExistingAnchor.batchBubbleAnchorMessageId,
        "existing-anchor",
        "Existing anchor should be preferred over fallback"
    )
    assertEqual(restoredUsingExistingAnchor.currentBatchId, "batch-restore", "Batch id should roundtrip")
    assertEqual(restoredUsingExistingAnchor.batchState, .uploading, "Batch state should roundtrip")
    assertEqual(
        restoredUsingExistingAnchor.batchProgress,
        0.5,
        "Restored session should compute progress from snapshot items"
    )
    assertEqual(
        restoredUsingExistingAnchor.pendingBatchFormData?["slug"],
        "desk",
        "Grouped form data should roundtrip"
    )
    assertEqual(
        restoredUsingExistingAnchor.isBatchUploading,
        false,
        "Restored session should start with uploading false"
    )

    let restoredUsingFallbackAnchor = service.makeRestoredBatchSession(
        snapshot: snapshot,
        existingAnchorMessageId: nil,
        fallbackAnchorMessageId: "fallback-anchor"
    )
    assertEqual(
        restoredUsingFallbackAnchor.batchBubbleAnchorMessageId,
        "fallback-anchor",
        "Fallback anchor should be used when existing anchor is nil"
    )

    let restoredWithoutAnchors = service.makeRestoredBatchSession(
        snapshot: snapshot,
        existingAnchorMessageId: nil,
        fallbackAnchorMessageId: nil
    )
    assertEqual(
        restoredWithoutAnchors.batchBubbleAnchorMessageId,
        nil,
        "Anchor should remain nil when both existing and fallback anchors are missing"
    )

    print("batch_state_transition_restored_session_tests: PASS")
}

@MainActor
private func runResetStateTests() {
    let service = BatchStateTransitionService()
    let reset = service.makeResetState()

    assertEqual(reset.currentBatchId, nil, "Reset should clear current batch id")
    assertEqual(reset.stagedBatchVideos.count, 0, "Reset should clear staged videos")
    assertEqual(reset.batchItems.count, 0, "Reset should clear batch items")
    assertTrue(reset.batchContext == nil, "Reset should clear batch context")
    assertEqual(reset.batchProgress, 0, "Reset should clear batch progress")
    assertEqual(reset.isBatchUploading, false, "Reset should clear uploading flag")
    assertEqual(
        reset.suppressPerAssetFormSheet,
        false,
        "Reset should clear suppress-per-asset-form flag"
    )
    assertEqual(reset.batchState, .queued, "Reset should return to queued state")
    assertEqual(reset.pendingBatchFormData, nil, "Reset should clear pending grouped form data")
    assertEqual(
        reset.awaitingGroupedFormForBatch,
        false,
        "Reset should clear grouped form await flag"
    )
    assertEqual(reset.batchBubbleAnchorMessageId, nil, "Reset should clear batch bubble anchor")

    print("batch_state_transition_reset_state_tests: PASS")
}

@MainActor
private func runGroupedFormSubmissionStateTests() {
    let service = BatchStateTransitionService()
    let submission = service.makeGroupedBatchFormSubmissionState(
        formData: [
            "slug": "night desk",
            "type": "Raw",
            "description": "Two clip package",
            "priority": "High",
            "destination": "Slack",
            "org": "sea-lion",
        ]
    )

    assertEqual(
        submission.awaitingGroupedFormForBatch,
        false,
        "Grouped-form submission should clear awaiting flag"
    )
    assertEqual(
        submission.pendingBatchFormData["slug"],
        "night desk",
        "Grouped-form submission should retain form data"
    )
    assertEqual(
        submission.batchContext.slug,
        "night desk",
        "Grouped-form submission should map slug into batch context"
    )
    assertEqual(
        submission.batchContext.priority,
        "High",
        "Grouped-form submission should map priority into batch context"
    )
    assertEqual(
        submission.showFormSheet,
        false,
        "Grouped-form submission should close form sheet"
    )

    let defaults = service.makeGroupedBatchFormSubmissionState(formData: [:])
    assertEqual(defaults.batchContext.slug, "", "Empty form should default slug to empty string")
    assertEqual(defaults.batchContext.type, "Raw", "Empty form should default type to Raw")
    assertEqual(
        defaults.batchContext.description,
        "",
        "Empty form should default description to empty string"
    )
    assertEqual(
        defaults.batchContext.priority,
        "Low",
        "Empty form should default priority to Low"
    )

    print("batch_state_transition_grouped_form_submission_tests: PASS")
}

@MainActor
private func runGroupedFormPromptStateTests() {
    let service = BatchStateTransitionService()
    let prompt = service.makeGroupedBatchFormPromptState()

    assertEqual(
        prompt.awaitingGroupedFormForBatch,
        true,
        "Grouped-form prompt should enable await flag"
    )
    assertEqual(
        prompt.showFormSheet,
        true,
        "Grouped-form prompt should show form sheet"
    )
    assertEqual(
        prompt.shouldRebuildFormFields,
        true,
        "Grouped-form prompt should request form field rebuild"
    )
    assertEqual(
        prompt.submitError,
        nil,
        "Grouped-form prompt should clear any existing submit error"
    )

    print("batch_state_transition_grouped_form_prompt_tests: PASS")
}

@MainActor
private func runBatchSessionAssignmentStateTests() {
    let service = BatchStateTransitionService()

    let stagedSession = StagedBatchSessionState(
        currentBatchId: "batch-staged",
        stagedBatchVideos: [],
        batchItems: [VideoBatchItem(localId: "local-1", fileName: "a.mov")],
        batchContext: VideoBatchContext(
            slug: "desk",
            type: "Raw",
            description: "desc",
            priority: "Low",
            destination: nil,
            org: nil
        ),
        batchProgress: 0.4,
        isBatchUploading: true,
        suppressPerAssetFormSheet: true,
        awaitingGroupedFormForBatch: true,
        pendingBatchFormData: ["slug": "desk"],
        batchBubbleAnchorMessageId: "anchor-1",
        batchState: .uploading
    )

    let stagedAssignment = service.makeBatchSessionAssignmentState(from: stagedSession)
    assertEqual(stagedAssignment.currentBatchId, "batch-staged", "Staged assignment should map batch id")
    assertEqual(stagedAssignment.batchState, .uploading, "Staged assignment should map batch state")
    assertEqual(stagedAssignment.batchProgress, 0.4, "Staged assignment should map batch progress")
    assertEqual(
        stagedAssignment.awaitingGroupedFormForBatch,
        true,
        "Staged assignment should map grouped form await flag"
    )

    let restoredSession = RestoredBatchSessionState(
        currentBatchId: "batch-restored",
        stagedBatchVideos: [],
        batchItems: [VideoBatchItem(localId: "local-2", fileName: "b.mov")],
        batchContext: nil,
        batchProgress: 0.35,
        pendingBatchFormData: ["slug": "restored"],
        batchState: .queued,
        isBatchUploading: false,
        suppressPerAssetFormSheet: false,
        awaitingGroupedFormForBatch: false,
        batchBubbleAnchorMessageId: "anchor-2"
    )

    let restoredAssignment = service.makeBatchSessionAssignmentState(from: restoredSession)
    assertEqual(restoredAssignment.currentBatchId, "batch-restored", "Restored assignment should map batch id")
    assertEqual(restoredAssignment.batchState, .queued, "Restored assignment should map batch state")
    assertEqual(
        restoredAssignment.batchProgress,
        0.35,
        "Restored assignment should map restored progress"
    )

    let resetState = service.makeResetState()
    let resetAssignment = service.makeBatchSessionAssignmentState(from: resetState)
    assertEqual(resetAssignment.currentBatchId, nil, "Reset assignment should clear batch id")
    assertEqual(resetAssignment.batchState, .queued, "Reset assignment should map queued state")
    assertEqual(resetAssignment.batchProgress, 0, "Reset assignment should map reset progress")

    print("batch_state_transition_assignment_state_tests: PASS")
}

@MainActor
private func runRestoredActiveAssetIdsTests() {
    let service = BatchStateTransitionService()
    let ids = service.makeRestoredActiveAssetIds(
        batchItems: [
            VideoBatchItem(localId: "local-1", fileName: "a.mov", assetId: "asset-a"),
            VideoBatchItem(localId: "local-2", fileName: "b.mov", assetId: nil),
            VideoBatchItem(localId: "local-3", fileName: "c.mov", assetId: ""),
            VideoBatchItem(localId: "local-6", fileName: "f.mov", assetId: "  \n\t"),
            VideoBatchItem(localId: "local-4", fileName: "d.mov", assetId: "asset-a"),
            VideoBatchItem(localId: "local-5", fileName: "e.mov", assetId: "asset-b"),
        ]
    )

    assertEqual(
        ids,
        ["asset-a", "asset-b"],
        "Restored active asset ids should drop nil/empty/whitespace values and dedupe while preserving order"
    )

    print("batch_state_transition_restored_active_asset_ids_tests: PASS")
}

@main
struct BatchStateTransitionServiceTestsRunner {
    @MainActor
    static func main() {
        runStagedSessionTests()
        runRunToggleTests()
        runRunCompletionStateTests()
        runRunFinalizationStateTests()
        runRunFinishStateTests()
        runCompletionMessageTriggerStateTests()
        runRestoredSessionTests()
        runResetStateTests()
        runGroupedFormSubmissionStateTests()
        runGroupedFormPromptStateTests()
        runBatchSessionAssignmentStateTests()
        runRestoredActiveAssetIdsTests()
    }
}
