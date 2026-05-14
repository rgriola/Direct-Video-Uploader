// May 14, 2026 - 3:02am - GitHub Copilot (GPT-5.3-Codex)
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

// Minimal stub used by BatchCompletionMessageService.makeCompletionMessages.
struct BatchClipDisplayState {
    var mediasourceId: String?
}

private func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { return }
    fputs("Assertion failed: \(message)\n", stderr)
    exit(1)
}

private func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    assertTrue(lhs == rhs, "\(message) | left=\(lhs) right=\(rhs)")
}

private func assertContains(_ haystack: String, _ needle: String, _ message: String) {
    assertTrue(haystack.contains(needle), "\(message) | missing=\(needle) in=\(haystack)")
}

@MainActor
private func runEmptyBatchTests() {
    let service = BatchCompletionMessageService()

    let messages = service.makeCompletionMessages(
        batchItems: [],
        firstName: "Carrie",
        batchClipDisplayByAssetId: [:]
    )

    assertEqual(messages.count, 0, "Empty batch should not emit completion messages")

    print("batch_completion_message_empty_tests: PASS")
}

@MainActor
private func runSummaryAndFallbackTests() {
    let service = BatchCompletionMessageService()

    let batchItems: [VideoBatchItem] = [
        VideoBatchItem(
            localId: "local-1",
            fileName: "alpha.mov",
            status: .complete,
            progress: 1.0,
            assetId: "asset-1"
        ),
        VideoBatchItem(
            localId: "local-2",
            fileName: "beta.mov",
            status: .failed,
            progress: 0.2,
            assetId: "asset-2",
            error: nil
        ),
        VideoBatchItem(
            localId: "local-3",
            fileName: "charlie.mov",
            status: .complete,
            progress: 1.0,
            assetId: "asset-3"
        ),
    ]

    let messages = service.makeCompletionMessages(
        batchItems: batchItems,
        firstName: "Carrie",
        batchClipDisplayByAssetId: [
            "asset-1": BatchClipDisplayState(mediasourceId: "1234"),
            "asset-3": BatchClipDisplayState(mediasourceId: "   "),
        ]
    )

    assertEqual(messages.count, 3, "Non-empty batch should emit summary + two follow-up messages")

    let summaryText = messages[0].content.text ?? ""
    assertContains(summaryText, "Batch Summary", "Summary message should include heading")
    assertContains(summaryText, "MS# 1234", "Summary should include mediasource id when available")
    assertContains(summaryText, "MS# pending", "Summary should include pending token when id is missing")
    assertContains(summaryText, "alpha.mov", "Summary should list confirmed item file names")
    assertContains(summaryText, "charlie.mov", "Summary should list all confirmed item file names")
    assertContains(summaryText, "Unverified (1)", "Summary should include unverified section count")
    assertContains(summaryText, "beta.mov", "Summary should list unverified item file names")
    assertContains(summaryText, "Needs retry", "Summary should fallback unverified reason when error is missing")

    print("batch_completion_message_summary_fallback_tests: PASS")
}

@MainActor
private func runHighFiveVariantTests() {
    let service = BatchCompletionMessageService()

    let allConfirmed = service.makeCompletionMessages(
        confirmedItems: [VideoBatchItem(localId: "local-1", fileName: "a.mov", status: .complete)],
        unconfirmedItems: [],
        firstName: "Carrie",
        summaryText: "summary"
    )
    assertEqual(
        allConfirmed[1].content.text,
        "High five. Batch upload complete.",
        "High-five copy should reflect all confirmed items"
    )

    let partial = service.makeCompletionMessages(
        confirmedItems: [VideoBatchItem(localId: "local-2", fileName: "b.mov", status: .complete)],
        unconfirmedItems: [VideoBatchItem(localId: "local-3", fileName: "c.mov", status: .failed)],
        firstName: "Carrie",
        summaryText: "summary"
    )
    assertEqual(
        partial[1].content.text,
        "High five. Most clips landed, and I flagged what needs attention.",
        "High-five copy should reflect mixed confirmed/unconfirmed items"
    )

    let allFailed = service.makeCompletionMessages(
        confirmedItems: [],
        unconfirmedItems: [VideoBatchItem(localId: "local-4", fileName: "d.mov", status: .failed)],
        firstName: "Carrie",
        summaryText: "summary"
    )
    assertEqual(
        allFailed[1].content.text,
        "High five for sticking with it. This batch needs a retry pass.",
        "High-five copy should reflect all unconfirmed items"
    )

    let closingText = allConfirmed[2].content.text ?? ""
    assertContains(closingText, "Carrie", "Closing message should interpolate first name")

    print("batch_completion_message_high_five_variant_tests: PASS")
}

@main
struct BatchCompletionMessageServiceTestsRunner {
    @MainActor
    static func main() {
        runEmptyBatchTests()
        runSummaryAndFallbackTests()
        runHighFiveVariantTests()
    }
}
