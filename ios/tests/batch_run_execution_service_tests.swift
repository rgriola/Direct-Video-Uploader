// May 13, 2026 - 12:41pm - GitHub Copilot (GPT-5.3-Codex)
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

private func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { return }
    fputs("Assertion failed: \(message)\n", stderr)
    exit(1)
}

private func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    assertTrue(lhs == rhs, "\(message) | left=\(lhs) right=\(rhs)")
}

@MainActor
private func runShouldStartRunTests() {
    let service = BatchRunExecutionService()
    let items = [VideoBatchItem(localId: "local-1", fileName: "clip-1.mov")]

    assertTrue(
        !service.shouldStartRun(
            isBatchUploading: true,
            batchItems: items,
            pendingBatchFormData: ["slug": "desk"]
        ),
        "Run should not start while upload is already in progress"
    )

    assertTrue(
        !service.shouldStartRun(
            isBatchUploading: false,
            batchItems: [],
            pendingBatchFormData: ["slug": "desk"]
        ),
        "Run should not start when there are no batch items"
    )

    assertTrue(
        !service.shouldStartRun(
            isBatchUploading: false,
            batchItems: items,
            pendingBatchFormData: nil
        ),
        "Run should not start without grouped form payload"
    )

    assertTrue(
        service.shouldStartRun(
            isBatchUploading: false,
            batchItems: items,
            pendingBatchFormData: ["slug": "desk"]
        ),
        "Run should start when idle, with items and grouped form payload"
    )

    print("batch_run_execution_should_start_tests: PASS")
}

@MainActor
private func runCompletionStateTests() {
    let service = BatchRunExecutionService()

    let completeItems = [
        VideoBatchItem(localId: "a", fileName: "a.mov", status: .complete, progress: 1),
        VideoBatchItem(localId: "b", fileName: "b.mov", status: .complete, progress: 1),
    ]

    let completeState = service.completionState(
        batchItems: completeItems,
        currentBatchId: "batch-1"
    )

    assertEqual(completeState.failedCount, 0, "All-complete run should report zero failures")
    assertEqual(completeState.nextState, .complete, "All-complete run should transition to complete")
    assertEqual(
        completeState.shouldClearDraftState,
        true,
        "All-complete run should clear draft state"
    )
    assertEqual(
        completeState.batchIdToClear,
        "batch-1",
        "All-complete run should return batch id for disk clear"
    )

    let partialItems = [
        VideoBatchItem(localId: "a", fileName: "a.mov", status: .complete, progress: 1),
        VideoBatchItem(localId: "b", fileName: "b.mov", status: .failed, progress: 1),
        VideoBatchItem(localId: "c", fileName: "c.mov", status: .failed, progress: 1),
    ]

    let partialState = service.completionState(
        batchItems: partialItems,
        currentBatchId: "batch-2"
    )

    assertEqual(partialState.failedCount, 2, "Failed item count should match failed statuses")
    assertEqual(
        partialState.nextState,
        .partialFailed,
        "Any failed item should transition to partialFailed"
    )
    assertEqual(
        partialState.shouldClearDraftState,
        false,
        "partialFailed run should keep draft state"
    )
    assertEqual(
        partialState.batchIdToClear,
        nil,
        "partialFailed run should not clear persisted batch id"
    )

    print("batch_run_execution_completion_tests: PASS")
}

@main
struct BatchRunExecutionServiceTestsRunner {
    @MainActor
    static func main() {
        runShouldStartRunTests()
        runCompletionStateTests()
    }
}
