// May 14, 2026 - 2:50pm - GitHub Copilot (Claude Opus 4.7)
import Foundation
import Observation
import Photos

// Persistence types (PHAssetIdentifierStore, PendingForm, UploadQueueStore +
// PersistedUploadTask + UploadTaskLifecycleState) live in Services/Persistence/
// as of Priority 4. UploadTaskMetricsSummary stays here — it's upload-engine
// output, not persistence schema.

enum UploadRetryStage {
    case requestUploadURL
    case uploadBytes
}

enum UploadRetryDisposition: Equatable {
    case retryTransient
    case refreshUploadURL
    case failPermanent
}

enum UploadRetryPolicy {
    static let maxTransientAttempts = 3
    static let maxRefreshAttempts = 2

    private static let baseDelaySeconds: Double = 1
    private static let maxDelaySeconds: Double = 8
    private static let jitterScale: Double = 0.35

    static func delaySeconds(
        forAttempt attempt: Int, randomValue: Double = Double.random(in: 0...1)
    )
        -> Double
    {
        let sanitizedAttempt = max(attempt, 1)
        let exponential = baseDelaySeconds * pow(2, Double(sanitizedAttempt - 1))
        let base = min(exponential, maxDelaySeconds)
        let boundedRandom = min(max(randomValue, 0), 1)
        let centeredRandom = (boundedRandom * 2) - 1
        let jitter = base * jitterScale * centeredRandom
        return max(0.1, base + jitter)
    }

    static func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        UInt64(delaySeconds(forAttempt: attempt) * 1_000_000_000)
    }
}

enum UploadRetryClassifier {
    private static let transientNetworkErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .notConnectedToInternet,
        .networkConnectionLost,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .resourceUnavailable,
        .internationalRoamingOff,
        .callIsActive,
        .dataNotAllowed,
        .backgroundSessionWasDisconnected,
        .backgroundSessionInUseByAnotherProcess,
    ]

    static func classify(stage: UploadRetryStage, statusCode: Int?, error: Error?)
        -> UploadRetryDisposition
    {
        if let statusCode {
            return classifyStatusCode(stage: stage, statusCode: statusCode)
        }

        if let uploadError = error as? UploadError,
            case .serverError(let code, _) = uploadError
        {
            return classifyStatusCode(stage: stage, statusCode: code)
        }

        if let urlError = error as? URLError {
            return classifyURLErrorCode(stage: stage, code: urlError.code)
        }

        if let nsError = error as NSError?,
            nsError.domain == NSURLErrorDomain
        {
            let code = URLError.Code(rawValue: nsError.code)
            return classifyURLErrorCode(stage: stage, code: code)
        }

        return .failPermanent
    }

    private static func classifyStatusCode(stage: UploadRetryStage, statusCode: Int)
        -> UploadRetryDisposition
    {
        switch statusCode {
        case 401, 403:
            return .refreshUploadURL
        case 404 where stage == .uploadBytes:
            return .refreshUploadURL
        case 410 where stage == .uploadBytes:
            return .refreshUploadURL
        case 408, 425, 429:
            return .retryTransient
        case 500...599:
            return .retryTransient
        default:
            return .failPermanent
        }
    }

    private static func classifyURLErrorCode(stage: UploadRetryStage, code: URLError.Code)
        -> UploadRetryDisposition
    {
        if transientNetworkErrorCodes.contains(code) {
            return .retryTransient
        }

        if code == .userAuthenticationRequired, stage == .uploadBytes {
            return .refreshUploadURL
        }

        return .failPermanent
    }
}

struct UploadTaskMetricsSummary: Equatable, Sendable {
    let transactionCount: Int
    let totalDurationMs: Int?
    let requestDurationMs: Int?
    let responseDurationMs: Int?
    let networkProtocolName: String?
    let isCellular: Bool?
}

enum UploadTelemetryOutcome: String {
    case success
    case failed
}

struct UploadTelemetrySnapshot {
    let localUploadId: String
    let assetId: String
    let correlationId: String
    let serverUploadCreatedAtMs: Int?
    let taskMetrics: UploadTaskMetricsSummary?
    let queueWaitMs: Int?
    let transferDurationMs: Int?
    let retries: Int
    let outcome: UploadTelemetryOutcome
    let errorMessage: String?
}

private struct UploadTelemetryState {
    var localUploadId: String
    var assetId: String
    var correlationId: String
    var startedAt: Date
    var firstTaskCreatedAt: Date?
    var firstByteAt: Date?
    var lastTaskCompletionAt: Date?
    var retries: Int
    var serverUploadCreatedAtMs: Int?
    var taskMetrics: UploadTaskMetricsSummary?
}

actor UploadTelemetryRecorder {
    static let shared = UploadTelemetryRecorder()

    private var statesByUploadId: [String: UploadTelemetryState] = [:]
    private var uploadIdByTaskIdentifier: [Int: String] = [:]

    func begin(localUploadId: String, assetId: String, correlationId: String, at: Date = Date()) {
        statesByUploadId[localUploadId] = UploadTelemetryState(
            localUploadId: localUploadId,
            assetId: assetId,
            correlationId: correlationId,
            startedAt: at,
            firstTaskCreatedAt: nil,
            firstByteAt: nil,
            lastTaskCompletionAt: nil,
            retries: 0,
            serverUploadCreatedAtMs: nil,
            taskMetrics: nil
        )
    }

    func updateRetries(localUploadId: String, retries: Int) {
        guard var state = statesByUploadId[localUploadId] else { return }
        state.retries = max(state.retries, retries)
        statesByUploadId[localUploadId] = state
    }

    func markTaskCreated(localUploadId: String, taskIdentifier: Int, at: Date = Date()) {
        guard var state = statesByUploadId[localUploadId] else { return }
        if state.firstTaskCreatedAt == nil {
            state.firstTaskCreatedAt = at
        }
        statesByUploadId[localUploadId] = state
        uploadIdByTaskIdentifier[taskIdentifier] = localUploadId
    }

    func markFirstByte(taskIdentifier: Int, at: Date = Date()) {
        guard let localUploadId = uploadIdByTaskIdentifier[taskIdentifier],
            var state = statesByUploadId[localUploadId]
        else {
            return
        }

        if state.firstByteAt == nil {
            state.firstByteAt = at
            statesByUploadId[localUploadId] = state
        }
    }

    func markTaskCompleted(taskIdentifier: Int, at: Date = Date()) {
        guard let localUploadId = uploadIdByTaskIdentifier[taskIdentifier],
            var state = statesByUploadId[localUploadId]
        else {
            return
        }

        state.lastTaskCompletionAt = at
        statesByUploadId[localUploadId] = state
        uploadIdByTaskIdentifier.removeValue(forKey: taskIdentifier)
    }

    func markTaskMetrics(taskIdentifier: Int, summary: UploadTaskMetricsSummary) {
        guard let localUploadId = uploadIdByTaskIdentifier[taskIdentifier],
            var state = statesByUploadId[localUploadId]
        else {
            return
        }

        state.taskMetrics = summary
        statesByUploadId[localUploadId] = state
    }

    func markServerCorrelation(
        localUploadId: String,
        serverCorrelationId: String?,
        serverUploadCreatedAtMs: Int?
    ) {
        guard var state = statesByUploadId[localUploadId] else { return }

        if let serverCorrelationId, !serverCorrelationId.isEmpty {
            state.correlationId = serverCorrelationId
        }

        if let serverUploadCreatedAtMs {
            state.serverUploadCreatedAtMs = serverUploadCreatedAtMs
        }

        statesByUploadId[localUploadId] = state
    }

    func finalize(
        localUploadId: String,
        outcome: UploadTelemetryOutcome,
        errorMessage: String? = nil,
        at: Date = Date()
    ) -> UploadTelemetrySnapshot? {
        guard let state = statesByUploadId.removeValue(forKey: localUploadId) else { return nil }

        for (taskIdentifier, mappedUploadId) in uploadIdByTaskIdentifier
        where mappedUploadId == localUploadId {
            uploadIdByTaskIdentifier.removeValue(forKey: taskIdentifier)
        }

        let completedAt = state.lastTaskCompletionAt ?? at
        let durations = Self.computeDurations(
            startedAt: state.startedAt,
            firstByteAt: state.firstByteAt,
            completedAt: completedAt
        )

        return UploadTelemetrySnapshot(
            localUploadId: state.localUploadId,
            assetId: state.assetId,
            correlationId: state.correlationId,
            serverUploadCreatedAtMs: state.serverUploadCreatedAtMs,
            taskMetrics: state.taskMetrics,
            queueWaitMs: durations.queueWaitMs,
            transferDurationMs: durations.transferDurationMs,
            retries: state.retries,
            outcome: outcome,
            errorMessage: errorMessage
        )
    }

    static func summarizeTaskMetrics(_ metrics: URLSessionTaskMetrics) -> UploadTaskMetricsSummary {
        let lastTransaction = metrics.transactionMetrics.last

        return UploadTaskMetricsSummary(
            transactionCount: metrics.transactionMetrics.count,
            totalDurationMs: max(0, Int(metrics.taskInterval.duration * 1000)),
            requestDurationMs: intervalDurationMs(
                start: lastTransaction?.requestStartDate,
                end: lastTransaction?.requestEndDate
            ),
            responseDurationMs: intervalDurationMs(
                start: lastTransaction?.responseStartDate,
                end: lastTransaction?.responseEndDate
            ),
            networkProtocolName: lastTransaction?.networkProtocolName,
            isCellular: lastTransaction?.isCellular
        )
    }

    private static func intervalDurationMs(start: Date?, end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(end.timeIntervalSince(start) * 1000))
    }

    static func computeDurations(startedAt: Date, firstByteAt: Date?, completedAt: Date?)
        -> (queueWaitMs: Int?, transferDurationMs: Int?)
    {
        let queueWaitMs: Int? = {
            guard let firstByteAt else { return nil }
            return max(0, Int(firstByteAt.timeIntervalSince(startedAt) * 1000))
        }()

        let transferDurationMs: Int? = {
            guard let firstByteAt, let completedAt else { return nil }
            return max(0, Int(completedAt.timeIntervalSince(firstByteAt) * 1000))
        }()

        return (queueWaitMs, transferDurationMs)
    }
}

final class BackgroundUploadSessionCoordinator: NSObject, URLSessionTaskDelegate,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    static let shared = BackgroundUploadSessionCoordinator()
    static let sessionIdentifier = "com.directvideo.upload.background"

    private let lock = NSLock()
    private var progressHandlers: [Int: @Sendable (Double) -> Void] = [:]
    private var completionHandlers: [Int: @Sendable (Data?, URLResponse?, (any Error)?) -> Void] =
        [:]
    private var responseBuffers: [Int: Data] = [:]
    private var localUploadIdsByTask: [Int: String] = [:]
    private var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    @discardableResult
    func enqueueUpload(
        localUploadId: String,
        assetId: String,
        remoteUploadURL: URL,
        retries: Int = 0,
        request: URLRequest,
        fileURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> Int {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        let taskIdentifier = task.taskIdentifier

        lock.withLock {
            progressHandlers[taskIdentifier] = onProgress
            completionHandlers[taskIdentifier] = onComplete
            responseBuffers[taskIdentifier] = Data()
            localUploadIdsByTask[taskIdentifier] = localUploadId
        }

        let now = Date()
        UploadQueueStore.upsert(
            PersistedUploadTask(
                localUploadId: localUploadId,
                assetId: assetId,
                fileURL: fileURL,
                remoteUploadURL: remoteUploadURL,
                taskIdentifier: taskIdentifier,
                state: .running,
                errorMessage: nil,
                retries: retries,
                createdAt: now,
                updatedAt: now
            )
        )

        Task {
            await UploadTelemetryRecorder.shared.markTaskCreated(
                localUploadId: localUploadId,
                taskIdentifier: taskIdentifier
            )
        }

        task.resume()
        return taskIdentifier
    }

    /// Returns the set of task identifiers currently known to the background
    /// URLSession. Used at restore time to detect "phantom" persisted tasks
    /// whose underlying URLSession task died with the prior process.
    func liveUploadTaskIdentifiers() async -> Set<Int> {
        let tasks = await session.allTasks
        return Set(tasks.map(\.taskIdentifier))
    }

    func handleBackgroundEvents(for identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }

        lock.withLock {
            backgroundCompletionHandler = completionHandler
        }

        reconcileOutstandingTasks()
    }

    func reconcileOutstandingTasks() {
        session.getAllTasks { tasks in
            let activeTaskIdentifiers = Set(tasks.map(\.taskIdentifier))
            _ = UploadQueueStore.reconcile(activeTaskIdentifiers: activeTaskIdentifiers)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }

        Task {
            await UploadTelemetryRecorder.shared.markFirstByte(taskIdentifier: task.taskIdentifier)
        }

        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let handler = lock.withLock { progressHandlers[task.taskIdentifier] }
        handler?(progress)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            var existing = responseBuffers[dataTask.taskIdentifier] ?? Data()
            existing.append(data)
            responseBuffers[dataTask.taskIdentifier] = existing
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        Task {
            await UploadTelemetryRecorder.shared.markTaskCompleted(
                taskIdentifier: task.taskIdentifier)
        }

        let result = lock.withLock {
            let completion = completionHandlers.removeValue(forKey: task.taskIdentifier)
            let responseData = responseBuffers.removeValue(forKey: task.taskIdentifier)
            _ = progressHandlers.removeValue(forKey: task.taskIdentifier)
            let localUploadId = localUploadIdsByTask.removeValue(forKey: task.taskIdentifier)
            return (completion, responseData, localUploadId)
        }

        if let localUploadId = result.2 {
            if let error {
                UploadQueueStore.markState(
                    localUploadId: localUploadId,
                    state: .failed,
                    errorMessage: error.localizedDescription,
                    taskIdentifier: task.taskIdentifier
                )
            } else {
                UploadQueueStore.markState(
                    localUploadId: localUploadId,
                    state: .completed,
                    errorMessage: nil,
                    taskIdentifier: task.taskIdentifier
                )
            }
        }

        result.0?(result.1, task.response, error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let summary = UploadTelemetryRecorder.summarizeTaskMetrics(metrics)
        Task {
            await UploadTelemetryRecorder.shared.markTaskMetrics(
                taskIdentifier: task.taskIdentifier,
                summary: summary
            )
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        AppLog.upload.info("[Upload] Waiting for connectivity - upload will resume when network returns")
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completionHandler = lock.withLock { () -> (() -> Void)? in
            let handler = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            return handler
        }
        guard let completionHandler else { return }
        DispatchQueue.main.async {
            completionHandler()
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

actor UploadInFlightRegistry {
    static let shared = UploadInFlightRegistry()

    private var activeAssetIds: Set<String> = []

    func begin(assetId: String) -> Bool {
        if activeAssetIds.contains(assetId) {
            return false
        }
        activeAssetIds.insert(assetId)
        return true
    }

    func end(assetId: String) {
        activeAssetIds.remove(assetId)
    }

    func isActive(assetId: String) -> Bool {
        activeAssetIds.contains(assetId)
    }
}

private struct DirectUploadDescriptor {
    let clipId: String
    let muxUploadId: String
    let uploadURL: URL
    let serverCorrelationId: String?
    let serverUploadCreatedAtMs: Int?
}

/// Handles multipart video file uploads with progress tracking.
@MainActor
@Observable
final class VideoUploadService: NSObject {
    // MARK: - State

    var uploadProgress: Double = 0
    var isUploading = false
    var error: String?

    private static let didBootstrapBackgroundSession: Void = {
        BackgroundUploadSessionCoordinator.shared.reconcileOutstandingTasks()
    }()

    override init() {
        super.init()
        Self.didBootstrapBackgroundSession
    }

    // MARK: - Private

    // MARK: - Mux Direct Upload

    /// Upload via Mux direct upload: ask server for a Mux upload URL, then PUT file directly to Mux CDN.
    /// This bypasses the server for the large file transfer — only metadata goes through the server.
    func uploadViaMux(assetId: String, fileURL: URL, token: String, metadata: VideoMetadata? = nil)
        async throws -> MuxUploadResponse
    {
        guard await UploadInFlightRegistry.shared.begin(assetId: assetId) else {
            throw UploadError.duplicateUploadInFlight(assetId)
        }

        let uploadStartedAt = Date()
        let uploadStartedAtMs = Int(uploadStartedAt.timeIntervalSince1970 * 1000)
        let telemetryCorrelationId = "ios-\(UUID().uuidString)"

        await UploadTelemetryRecorder.shared.begin(
            localUploadId: assetId,
            assetId: assetId,
            correlationId: telemetryCorrelationId,
            at: uploadStartedAt
        )

        defer {
            Task {
                await UploadInFlightRegistry.shared.end(assetId: assetId)
            }
        }

        isUploading = true
        uploadProgress = 0
        error = nil
        defer { isUploading = false }

        let fileSize = resolvedFileSize(for: fileURL)
        let metadataBody = try buildMetadataPayload(
            fileURL: fileURL,
            metadata: metadata,
            fileSize: fileSize,
            telemetryCorrelationId: telemetryCorrelationId,
            uploadStartedAtMs: uploadStartedAtMs
        )

        let now = Date()
        UploadQueueStore.upsert(
            PersistedUploadTask(
                localUploadId: assetId,
                assetId: assetId,
                fileURL: fileURL,
                remoteUploadURL: ServerConfig.muxUploadURL(assetId),
                taskIdentifier: nil,
                state: .pending,
                errorMessage: nil,
                retries: 0,
                createdAt: now,
                updatedAt: now
            )
        )

        var transientAttempt = 0
        var refreshAttempt = 0
        var descriptor: DirectUploadDescriptor?

        do {
            while true {
                if descriptor == nil {
                    AppLog.upload.info("[Mux] Requesting direct upload URL for asset: \(assetId)")

                    do {
                        descriptor = try await requestDirectUploadDescriptor(
                            assetId: assetId,
                            token: token,
                            metadataBody: metadataBody,
                            telemetryCorrelationId: telemetryCorrelationId,
                            uploadStartedAtMs: uploadStartedAtMs
                        )
                        if let descriptor {
                            await UploadTelemetryRecorder.shared.markServerCorrelation(
                                localUploadId: assetId,
                                serverCorrelationId: descriptor.serverCorrelationId,
                                serverUploadCreatedAtMs: descriptor.serverUploadCreatedAtMs
                            )
                        }
                    } catch {
                        let disposition = UploadRetryClassifier.classify(
                            stage: .requestUploadURL,
                            statusCode: nil,
                            error: error
                        )

                        switch disposition {
                        case .retryTransient:
                            guard transientAttempt < UploadRetryPolicy.maxTransientAttempts else {
                                let message =
                                    "Could not request upload URL after \(UploadRetryPolicy.maxTransientAttempts) retries."
                                UploadQueueStore.markState(
                                    localUploadId: assetId,
                                    state: .failed,
                                    errorMessage: message,
                                    retries: transientAttempt
                                )
                                throw UploadError.retryLimitExceeded(message)
                            }

                            transientAttempt += 1
                            await UploadTelemetryRecorder.shared.updateRetries(
                                localUploadId: assetId,
                                retries: transientAttempt + refreshAttempt
                            )
                            UploadQueueStore.markState(
                                localUploadId: assetId,
                                state: .pending,
                                errorMessage:
                                    "Retrying upload setup (\(transientAttempt)/\(UploadRetryPolicy.maxTransientAttempts))",
                                retries: transientAttempt
                            )
                            try await Task.sleep(
                                nanoseconds: UploadRetryPolicy.delayNanoseconds(
                                    forAttempt: transientAttempt)
                            )
                            continue

                        case .refreshUploadURL:
                            let message = "Authentication failed while requesting upload URL."
                            UploadQueueStore.markState(
                                localUploadId: assetId,
                                state: .failed,
                                errorMessage: message
                            )
                            throw UploadError.retryLimitExceeded(message)

                        case .failPermanent:
                            UploadQueueStore.markState(
                                localUploadId: assetId,
                                state: .failed,
                                errorMessage: error.localizedDescription
                            )
                            throw error
                        }
                    }
                }

                guard let activeDescriptor = descriptor else {
                    UploadQueueStore.markState(
                        localUploadId: assetId,
                        state: .failed,
                        errorMessage: UploadError.invalidResponse.localizedDescription
                    )
                    throw UploadError.invalidResponse
                }

                do {
                    try await putFileToMux(
                        localUploadId: assetId,
                        assetId: assetId,
                        fileURL: fileURL,
                        fileSize: fileSize,
                        uploadURL: activeDescriptor.uploadURL,
                        retries: transientAttempt + refreshAttempt
                    )

                    let retriesUsed = transientAttempt + refreshAttempt
                    await UploadTelemetryRecorder.shared.updateRetries(
                        localUploadId: assetId,
                        retries: retriesUsed
                    )
                    if let snapshot = await UploadTelemetryRecorder.shared.finalize(
                        localUploadId: assetId,
                        outcome: .success
                    ) {
                        persistAndLogTelemetry(snapshot)
                    }

                    uploadProgress = 1.0
                    AppLog.upload.info(
                        "[Mux] Direct upload complete! Mux will process and notify via webhook."
                    )
                    return MuxUploadResponse(
                        clipId: activeDescriptor.clipId,
                        muxUploadId: activeDescriptor.muxUploadId
                    )
                } catch {
                    let disposition = UploadRetryClassifier.classify(
                        stage: .uploadBytes,
                        statusCode: nil,
                        error: error
                    )

                    switch disposition {
                    case .retryTransient:
                        guard transientAttempt < UploadRetryPolicy.maxTransientAttempts else {
                            let message =
                                "Upload failed after \(UploadRetryPolicy.maxTransientAttempts) retries."
                            UploadQueueStore.markState(
                                localUploadId: assetId,
                                state: .failed,
                                errorMessage: message,
                                retries: transientAttempt + refreshAttempt
                            )
                            throw UploadError.retryLimitExceeded(message)
                        }

                        transientAttempt += 1
                        await UploadTelemetryRecorder.shared.updateRetries(
                            localUploadId: assetId,
                            retries: transientAttempt + refreshAttempt
                        )
                        UploadQueueStore.markState(
                            localUploadId: assetId,
                            state: .running,
                            errorMessage:
                                "Retrying upload bytes (\(transientAttempt)/\(UploadRetryPolicy.maxTransientAttempts))",
                            retries: transientAttempt + refreshAttempt
                        )
                        try await Task.sleep(
                            nanoseconds: UploadRetryPolicy.delayNanoseconds(
                                forAttempt: transientAttempt)
                        )
                        continue

                    case .refreshUploadURL:
                        guard refreshAttempt < UploadRetryPolicy.maxRefreshAttempts else {
                            let message = "Upload URL refresh limit reached."
                            UploadQueueStore.markState(
                                localUploadId: assetId,
                                state: .failed,
                                errorMessage: message,
                                retries: transientAttempt + refreshAttempt
                            )
                            throw UploadError.retryLimitExceeded(message)
                        }

                        refreshAttempt += 1
                        transientAttempt = 0
                        await UploadTelemetryRecorder.shared.updateRetries(
                            localUploadId: assetId,
                            retries: refreshAttempt
                        )
                        descriptor = nil
                        UploadQueueStore.markState(
                            localUploadId: assetId,
                            state: .pending,
                            errorMessage:
                                "Refreshing expired upload URL (\(refreshAttempt)/\(UploadRetryPolicy.maxRefreshAttempts))",
                            retries: refreshAttempt
                        )
                        try await Task.sleep(
                            nanoseconds: UploadRetryPolicy.delayNanoseconds(
                                forAttempt: refreshAttempt)
                        )
                        continue

                    case .failPermanent:
                        UploadQueueStore.markState(
                            localUploadId: assetId,
                            state: .failed,
                            errorMessage: error.localizedDescription,
                            retries: transientAttempt + refreshAttempt
                        )
                        throw error
                    }
                }
            }
        } catch {
            if let snapshot = await UploadTelemetryRecorder.shared.finalize(
                localUploadId: assetId,
                outcome: .failed,
                errorMessage: error.localizedDescription
            ) {
                persistAndLogTelemetry(snapshot)
            }
            throw error
        }
    }

    private func persistAndLogTelemetry(_ snapshot: UploadTelemetrySnapshot) {
        UploadQueueStore.markTelemetry(
            localUploadId: snapshot.localUploadId,
            queueWaitMs: snapshot.queueWaitMs,
            transferDurationMs: snapshot.transferDurationMs,
            retries: snapshot.retries,
            correlationId: snapshot.correlationId,
            serverUploadCreatedAtMs: snapshot.serverUploadCreatedAtMs,
            taskMetrics: snapshot.taskMetrics
        )

        let queueWaitText = snapshot.queueWaitMs.map { "\($0)ms" } ?? "n/a"
        let transferText = snapshot.transferDurationMs.map { "\($0)ms" } ?? "n/a"
        let serverUploadText = snapshot.serverUploadCreatedAtMs.map { "\($0)" } ?? "n/a"
        let metricsText: String = {
            guard let taskMetrics = snapshot.taskMetrics else { return "n/a" }
            let total = taskMetrics.totalDurationMs.map { "\($0)ms" } ?? "n/a"
            let request = taskMetrics.requestDurationMs.map { "\($0)ms" } ?? "n/a"
            let response = taskMetrics.responseDurationMs.map { "\($0)ms" } ?? "n/a"
            let protocolName = taskMetrics.networkProtocolName ?? "n/a"
            let cellular = taskMetrics.isCellular.map { String($0) } ?? "n/a"
            return
                "tx=\(taskMetrics.transactionCount) total=\(total) request=\(request) response=\(response) proto=\(protocolName) cellular=\(cellular)"
        }()
        let errorSuffix = snapshot.errorMessage.map { " reason=\($0)" } ?? ""
        AppLog.upload.info(
            "[UploadTelemetry] asset=\(snapshot.assetId) correlation=\(snapshot.correlationId) outcome=\(snapshot.outcome.rawValue) queueWait=\(queueWaitText) transfer=\(transferText) retries=\(snapshot.retries) serverUploadCreatedAtMs=\(serverUploadText) metrics={\(metricsText)}\(errorSuffix)"
        )
    }

    private func resolvedFileSize(for fileURL: URL) -> Int64 {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attrs[.size] as? Int64
        {
            return size
        }
        return 0
    }

    private func buildMetadataPayload(
        fileURL: URL,
        metadata: VideoMetadata?,
        fileSize: Int64,
        telemetryCorrelationId: String,
        uploadStartedAtMs: Int
    )
        throws
        -> Data
    {
        var metaDict: [String: Any] = [:]
        if let metadata {
            metaDict = [
                "fileName": fileURL.lastPathComponent,
                "duration": metadata.duration,
                "resolution": metadata.resolution,
                "codec": metadata.codec,
                "orientation": metadata.orientation,
                "deviceModel": metadata.deviceModel,
                "osVersion": metadata.osVersion,
            ]
            if let capturedAt = metadata.capturedAt { metaDict["capturedAt"] = capturedAt }
            if let lat = metadata.gpsLat { metaDict["gpsLat"] = lat }
            if let lon = metadata.gpsLon { metaDict["gpsLon"] = lon }
            if let alt = metadata.gpsAltitude { metaDict["gpsAltitude"] = alt }
            if fileSize > 0 { metaDict["fileSize"] = fileSize }
        }

        metaDict["uploadCorrelationId"] = telemetryCorrelationId
        metaDict["uploadStartedAtMs"] = uploadStartedAtMs

        return try JSONSerialization.data(withJSONObject: ["metadata": metaDict])
    }

    private func requestDirectUploadDescriptor(
        assetId: String,
        token: String,
        metadataBody: Data,
        telemetryCorrelationId: String,
        uploadStartedAtMs: Int
    ) async throws -> DirectUploadDescriptor {
        let muxURL = ServerConfig.muxUploadURL(assetId)
        var request = URLRequest(url: muxURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(telemetryCorrelationId, forHTTPHeaderField: "X-Upload-Correlation-Id")
        request.setValue("\(uploadStartedAtMs)", forHTTPHeaderField: "X-Upload-Started-At-Ms")
        request.httpBody = metadataBody

        let (createData, createResponse) = try await URLSession.shared.data(for: request)

        guard let httpResponse = createResponse as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            let statusCode = (createResponse as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: createData, encoding: .utf8) ?? "Unknown"
            AppLog.upload.error("[Mux] Failed to get upload URL: \(body)")
            throw UploadError.serverError(statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: createData) as? [String: Any],
            let uploadUrlString = json["uploadUrl"] as? String,
            let uploadURL = URL(string: uploadUrlString),
            let clipId = json["clipId"] as? String
        else {
            throw UploadError.invalidResponse
        }

        let telemetry = json["telemetry"] as? [String: Any]
        let serverCorrelationId = telemetry?["correlationId"] as? String
        let serverUploadCreatedAtMs = Self.intValue(from: telemetry?["serverUploadCreatedAtMs"])

        return DirectUploadDescriptor(
            clipId: clipId,
            muxUploadId: json["muxUploadId"] as? String ?? "",
            uploadURL: uploadURL,
            serverCorrelationId: serverCorrelationId,
            serverUploadCreatedAtMs: serverUploadCreatedAtMs
        )
    }

    private static func intValue(from value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.intValue
        }
        if let stringValue = value as? String {
            return Int(stringValue)
        }
        return nil
    }

    private func putFileToMux(
        localUploadId: String,
        assetId: String,
        fileURL: URL,
        fileSize: Int64,
        uploadURL: URL,
        retries: Int
    ) async throws {
        AppLog.upload.info("[Mux] Got upload URL, uploading directly to Mux CDN...")

        // Guard: URLSession.uploadTask(fromFile:) raises an uncatchable
        // NSInvalidArgumentException if the file is missing. This happens with
        // tmp/ files staged in a previous app session — iOS wipes tmp/ between
        // launches. Convert it into a normal upload failure instead of crashing.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            AppLog.upload.error(
                "[Mux] Source file missing for asset \(assetId, privacy: .public) at \(fileURL.path, privacy: .public)"
            )
            throw UploadError.fileNotFound
        }

        var putRequest = URLRequest(url: uploadURL)
        putRequest.httpMethod = "PUT"
        putRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if fileSize > 0 {
            putRequest.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        }

        let (_, putResponse) = try await uploadWithProgress(
            localUploadId: localUploadId,
            assetId: assetId,
            remoteUploadURL: uploadURL,
            retries: retries,
            request: putRequest,
            fileURL: fileURL
        )

        guard let putHttp = putResponse as? HTTPURLResponse,
            (200...204).contains(putHttp.statusCode)
        else {
            let code = (putResponse as? HTTPURLResponse)?.statusCode ?? 0
            AppLog.upload.error("[Mux] PUT to Mux failed with status \(code)")
            throw UploadError.serverError(code, "Mux upload failed")
        }
    }

    // MARK: - Upload with Progress (Shared Background Session)

    private func uploadWithProgress(
        localUploadId: String,
        assetId: String,
        remoteUploadURL: URL,
        retries: Int,
        request: URLRequest,
        fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            _ = BackgroundUploadSessionCoordinator.shared.enqueueUpload(
                localUploadId: localUploadId,
                assetId: assetId,
                remoteUploadURL: remoteUploadURL,
                retries: retries,
                request: request,
                fileURL: fileURL,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.uploadProgress = progress
                    }
                },
                onComplete: { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: UploadError.invalidResponse)
                    }
                }
            )
        }
    }
}

// MARK: - Mux Upload Response

struct MuxUploadResponse {
    let clipId: String
    let muxUploadId: String
}

// MARK: - Errors

enum UploadError: LocalizedError {
    case invalidResponse
    case serverError(Int, String)
    case fileNotFound
    case duplicateUploadInFlight(String)
    case retryLimitExceeded(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .serverError(let code, let msg): return "Upload failed (HTTP \(code)): \(msg)"
        case .fileNotFound: return "Video file not found"
        case .duplicateUploadInFlight(let assetId):
            return "Upload already in progress for asset \(assetId)."
        case .retryLimitExceeded(let reason):
            return reason
        }
    }
}
