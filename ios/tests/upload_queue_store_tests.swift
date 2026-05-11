// May 11, 2026 - 5:21pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

// Minimal stubs so VideoUploadService.swift can compile in this test runner context.
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

enum ServerConfig {
     static func muxUploadURL(_ assetId: String) -> URL {
          URL(string: "https://example.com/api/assets/\(assetId)/mux-upload")!
     }
}

private func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String) {
     if condition() { return }
     fputs("Assertion failed: \(message)\n", stderr)
     exit(1)
}

private func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
     assertTrue(lhs == rhs, "\(message) | left=\(lhs) right=\(rhs)")
}

private func assertApprox(_ actual: Int?, expected: Int, tolerance: Int, _ message: String) {
     guard let actual else {
          fputs("Assertion failed: \(message). Expected around \(expected), got nil\n", stderr)
          exit(1)
     }

     if abs(actual - expected) > tolerance {
          fputs(
               "Assertion failed: \(message). Expected around \(expected) +/- \(tolerance), got \(actual)\n",
               stderr
          )
          exit(1)
     }
}

private func assertAlmostEqual(
     _ lhs: Double,
     _ rhs: Double,
     epsilon: Double = 0.0001,
     _ message: String
) {
     assertTrue(abs(lhs - rhs) <= epsilon, "\(message) | left=\(lhs) right=\(rhs)")
}

private func runUploadQueueStoreTests() {
     let tempDir = FileManager.default.temporaryDirectory
          .appendingPathComponent("upload-queue-tests", isDirectory: true)
     try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
     let storageURL = tempDir.appendingPathComponent("queue-state.json")

     UploadQueueStore.setStorageURLForTesting(storageURL)
     UploadQueueStore.clearAllForTesting()

     let now = Date()
     let runningA = PersistedUploadTask(
          localUploadId: "local-a",
          assetId: "asset-a",
          fileURL: URL(fileURLWithPath: "/tmp/a.mov"),
          remoteUploadURL: URL(string: "https://uploads.example.com/a")!,
          taskIdentifier: 101,
          state: .running,
          errorMessage: nil,
          retries: 0,
          createdAt: now,
          updatedAt: now
     )

     UploadQueueStore.upsert(runningA)
     assertEqual(UploadQueueStore.all().count, 1, "Store should persist first record")

     var updatedA = runningA
     updatedA.retries = 1
     updatedA.updatedAt = now.addingTimeInterval(5)
     UploadQueueStore.upsert(updatedA)

     let tasksAfterUpdate = UploadQueueStore.all()
     assertEqual(tasksAfterUpdate.count, 1, "Upsert should replace existing localUploadId")
     assertEqual(tasksAfterUpdate[0].retries, 1, "Upsert should retain latest retry value")

     UploadQueueStore.markState(localUploadId: "local-a", state: .failed, errorMessage: "network")
     let failedA = UploadQueueStore.all().first { $0.localUploadId == "local-a" }
     assertEqual(failedA?.state, .failed, "markState should update lifecycle state")
     assertEqual(failedA?.errorMessage, "network", "markState should persist error message")

     UploadQueueStore.markTelemetry(
          localUploadId: "local-a",
          queueWaitMs: 450,
          transferDurationMs: 1200,
          retries: 2,
          correlationId: "corr-a",
          serverUploadCreatedAtMs: 1_715_000_000_000,
          taskMetrics: UploadTaskMetricsSummary(
               transactionCount: 1,
               totalDurationMs: 1400,
               requestDurationMs: 100,
               responseDurationMs: 1200,
               networkProtocolName: "h2",
               isCellular: false
          )
     )

     let telemetryA = UploadQueueStore.all().first { $0.localUploadId == "local-a" }
     assertEqual(telemetryA?.queueWaitMs, 450, "markTelemetry should persist queue wait")
     assertEqual(
          telemetryA?.transferDurationMs,
          1200,
          "markTelemetry should persist transfer duration")
     assertEqual(
          telemetryA?.telemetryCorrelationId,
          "corr-a",
          "markTelemetry should persist correlation id")
     assertEqual(
          telemetryA?.serverUploadCreatedAtMs,
          1_715_000_000_000,
          "markTelemetry should persist server upload timestamp")
     assertEqual(
          telemetryA?.metricsTotalDurationMs,
          1400,
          "markTelemetry should persist metrics total duration")
     assertEqual(
          telemetryA?.metricsNetworkProtocol,
          "h2",
          "markTelemetry should persist protocol")
     assertEqual(
          telemetryA?.metricsIsCellular,
          false,
          "markTelemetry should persist cellular hint")

     let runningB = PersistedUploadTask(
          localUploadId: "local-b",
          assetId: "asset-b",
          fileURL: URL(fileURLWithPath: "/tmp/b.mov"),
          remoteUploadURL: URL(string: "https://uploads.example.com/b")!,
          taskIdentifier: 202,
          state: .running,
          errorMessage: nil,
          retries: 0,
          createdAt: now,
          updatedAt: now
     )
     UploadQueueStore.upsert(runningB)

     _ = UploadQueueStore.reconcile(activeTaskIdentifiers: [202])
     let taskBStillRunning = UploadQueueStore.all().first { $0.localUploadId == "local-b" }
     assertEqual(
          taskBStillRunning?.state, .running, "Active task should remain running after reconcile")

     _ = UploadQueueStore.reconcile(activeTaskIdentifiers: [])
     let taskBFailed = UploadQueueStore.all().first { $0.localUploadId == "local-b" }
     assertEqual(taskBFailed?.state, .failed, "Missing active task should fail during reconcile")

     UploadQueueStore.remove(localUploadId: "local-a")
     let remaining = UploadQueueStore.all()
     assertEqual(remaining.count, 1, "remove should delete one record")
     assertEqual(remaining[0].localUploadId, "local-b", "remove should keep other records")

     UploadQueueStore.clearAllForTesting()
     assertEqual(UploadQueueStore.all().count, 0, "clearAllForTesting should reset store")

     UploadQueueStore.setStorageURLForTesting(nil)
     print("upload_queue_store_tests: PASS")
}

private func runRetryPolicyTests() {
     let attemptOneNoJitter = UploadRetryPolicy.delaySeconds(forAttempt: 1, randomValue: 0.5)
     assertAlmostEqual(attemptOneNoJitter, 1.0, "Attempt 1 with neutral jitter should be 1 second")

     let attemptTwoNoJitter = UploadRetryPolicy.delaySeconds(forAttempt: 2, randomValue: 0.5)
     assertAlmostEqual(attemptTwoNoJitter, 2.0, "Attempt 2 with neutral jitter should be 2 seconds")

     let attemptThreeLow = UploadRetryPolicy.delaySeconds(forAttempt: 3, randomValue: 0.0)
     let attemptThreeHigh = UploadRetryPolicy.delaySeconds(forAttempt: 3, randomValue: 1.0)
     assertTrue(attemptThreeLow > 0.0, "Jittered delay should stay positive")
     assertTrue(
          attemptThreeLow < attemptThreeHigh,
          "Higher jitter seed should produce a longer delay than lower seed")

     print("retry_policy_tests: PASS")
}

private func runRetryClassifierTests() {
     let transientStatus = UploadRetryClassifier.classify(
          stage: .requestUploadURL,
          statusCode: 503,
          error: nil
     )
     assertEqual(transientStatus, .retryTransient, "503 should classify as transient retry")

     let authStatus = UploadRetryClassifier.classify(
          stage: .uploadBytes,
          statusCode: 403,
          error: nil
     )
     assertEqual(authStatus, .refreshUploadURL, "403 should classify as refresh upload URL")

     let transientNetwork = UploadRetryClassifier.classify(
          stage: .uploadBytes,
          statusCode: nil,
          error: URLError(.networkConnectionLost)
     )
     assertEqual(
          transientNetwork,
          .retryTransient,
          "networkConnectionLost should classify as transient retry")

     let permanentStatus = UploadRetryClassifier.classify(
          stage: .requestUploadURL,
          statusCode: 422,
          error: nil
     )
     assertEqual(permanentStatus, .failPermanent, "422 should classify as permanent failure")

     print("retry_classifier_tests: PASS")
}

private func runInFlightRegistryTests() async {
     let registry = UploadInFlightRegistry.shared
     await registry.end(assetId: "asset-z")

     let firstStart = await registry.begin(assetId: "asset-z")
     assertTrue(firstStart, "First begin call should acquire the in-flight lock")

     let secondStart = await registry.begin(assetId: "asset-z")
     assertTrue(!secondStart, "Second begin call should be rejected for same asset")

     let stillActive = await registry.isActive(assetId: "asset-z")
     assertTrue(stillActive, "Asset should remain active until end() is called")

     await registry.end(assetId: "asset-z")

     let activeAfterEnd = await registry.isActive(assetId: "asset-z")
     assertTrue(!activeAfterEnd, "Asset should be released after end()")

     print("in_flight_registry_tests: PASS")
}

private func runTelemetryDurationTests() {
     let started = Date(timeIntervalSince1970: 100)
     let firstByte = started.addingTimeInterval(1.25)
     let completed = firstByte.addingTimeInterval(3.5)

     let durations = UploadTelemetryRecorder.computeDurations(
          startedAt: started,
          firstByteAt: firstByte,
          completedAt: completed
     )

     assertApprox(
          durations.queueWaitMs, expected: 1250, tolerance: 1, "Queue wait should be ~1250ms")
     assertApprox(
          durations.transferDurationMs,
          expected: 3500,
          tolerance: 1,
          "Transfer duration should be ~3500ms")

     let missingFirstByte = UploadTelemetryRecorder.computeDurations(
          startedAt: started,
          firstByteAt: nil,
          completedAt: completed
     )
     assertTrue(missingFirstByte.queueWaitMs == nil, "Queue wait should be nil without first byte")
     assertTrue(
          missingFirstByte.transferDurationMs == nil,
          "Transfer duration should be nil without first byte")

     print("telemetry_duration_tests: PASS")
}

private func runTelemetryRecorderLifecycleTests() async {
     let localUploadId = "telemetry-local"
     let assetId = "telemetry-asset"
     let correlationId = "ios-corr-1"
     let serverCorrelationId = "srv-corr-1"
     let taskIdentifier = 9001

     let started = Date(timeIntervalSince1970: 1000)
     let firstByte = started.addingTimeInterval(0.8)
     let completed = firstByte.addingTimeInterval(2.2)

     await UploadTelemetryRecorder.shared.begin(
          localUploadId: localUploadId,
          assetId: assetId,
          correlationId: correlationId,
          at: started
     )
     await UploadTelemetryRecorder.shared.markServerCorrelation(
          localUploadId: localUploadId,
          serverCorrelationId: serverCorrelationId,
          serverUploadCreatedAtMs: 1_715_000_123_456
     )
     await UploadTelemetryRecorder.shared.updateRetries(localUploadId: localUploadId, retries: 2)
     await UploadTelemetryRecorder.shared.markTaskCreated(
          localUploadId: localUploadId,
          taskIdentifier: taskIdentifier,
          at: started.addingTimeInterval(0.2)
     )
     await UploadTelemetryRecorder.shared.markTaskMetrics(
          taskIdentifier: taskIdentifier,
          summary: UploadTaskMetricsSummary(
               transactionCount: 1,
               totalDurationMs: 3000,
               requestDurationMs: 200,
               responseDurationMs: 2500,
               networkProtocolName: "h3",
               isCellular: true
          )
     )
     await UploadTelemetryRecorder.shared.markFirstByte(
          taskIdentifier: taskIdentifier,
          at: firstByte
     )
     await UploadTelemetryRecorder.shared.markTaskCompleted(
          taskIdentifier: taskIdentifier,
          at: completed
     )

     let snapshot = await UploadTelemetryRecorder.shared.finalize(
          localUploadId: localUploadId,
          outcome: .success
     )
     assertTrue(snapshot != nil, "Finalize should return a telemetry snapshot")

     guard let snapshot else {
          fputs("Telemetry snapshot was unexpectedly nil\n", stderr)
          exit(1)
     }

     assertEqual(snapshot.localUploadId, localUploadId, "Snapshot should keep local upload id")
     assertEqual(snapshot.assetId, assetId, "Snapshot should keep asset id")
     assertEqual(
          snapshot.correlationId, serverCorrelationId,
          "Server correlation id should override local id when provided")
     assertEqual(
          snapshot.serverUploadCreatedAtMs,
          1_715_000_123_456,
          "Snapshot should retain server upload timestamp")
     assertEqual(snapshot.retries, 2, "Snapshot should retain retry count")
     assertEqual(
          snapshot.taskMetrics,
          UploadTaskMetricsSummary(
               transactionCount: 1,
               totalDurationMs: 3000,
               requestDurationMs: 200,
               responseDurationMs: 2500,
               networkProtocolName: "h3",
               isCellular: true
          ),
          "Snapshot should retain task metrics summary")
     assertApprox(
          snapshot.queueWaitMs, expected: 800, tolerance: 5, "Snapshot queue wait should be ~800ms")
     assertApprox(
          snapshot.transferDurationMs, expected: 2200, tolerance: 5,
          "Snapshot transfer should be ~2200ms")

     let secondFinalize = await UploadTelemetryRecorder.shared.finalize(
          localUploadId: localUploadId,
          outcome: .success
     )
     assertTrue(secondFinalize == nil, "Second finalize should return nil after cleanup")

     print("telemetry_recorder_lifecycle_tests: PASS")
}

@main
struct UploadQueueStoreTestsRunner {
     static func main() async {
          runUploadQueueStoreTests()
          runRetryPolicyTests()
          runRetryClassifierTests()
          await runInFlightRegistryTests()
          runTelemetryDurationTests()
          await runTelemetryRecorderLifecycleTests()
     }
}
