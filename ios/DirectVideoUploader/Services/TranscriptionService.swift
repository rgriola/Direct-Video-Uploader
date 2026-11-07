import Speech
import Synchronization
import AVFoundation
import Foundation

/// Timestamped word segment from speech recognition.
nonisolated struct TranscriptSegment: Codable, Sendable, Equatable {
    let word: String
    let start: Double    // seconds from video start
    let end: Double      // start + duration
    let confidence: Float
}

/// Result from transcription — plain text + per-word timestamps.
nonisolated struct TranscriptionResult: Sendable {
    let text: String
    let segments: [TranscriptSegment]
}

nonisolated enum TranscriptDeliveryError: Error {
    case invalidResponse
    case httpStatus(Int)
}

nonisolated enum TranscriptDelivery {
    private struct Payload: Encodable {
        let transcript: String
        let segments: [TranscriptSegment]
        let clipId: String
    }

    private struct Receipt: Decodable {
        let ok: Bool
        let clipId: String
    }

    static func send(
        _ result: TranscriptionResult,
        clipId: String,
        request: URLRequest,
        transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RedirectSafeTransport.data(for: $0)
        }
    ) async throws {
        var request = request
        request.httpBody = try JSONEncoder().encode(
            Payload(transcript: result.text, segments: result.segments, clipId: clipId))
        try Task.checkCancellation()
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptDeliveryError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriptDeliveryError.httpStatus(http.statusCode)
        }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.ok, receipt.clipId == clipId else {
            throw TranscriptDeliveryError.invalidResponse
        }
    }
}

/// Video transcription using the Apple Speech framework.
/// Recognition may use Apple's servers before trying an on-device fallback.
@MainActor
@Observable
final class TranscriptionService {

    enum TranscriptionState: Sendable {
        case idle
        case requesting      // Awaiting user permission
        case transcribing    // SFSpeechRecognizer running
        case completed(TranscriptionResult)
        case failed(String)
        case noSpeech        // Audio exists but no words detected
    }

    var state: TranscriptionState = .idle
    var progress: Double = 0  // 0.0–1.0 estimate

    private let authorizer: any PermissionAuthorizing

    init(authorizer: any PermissionAuthorizing = SystemPermissionAuthorizer()) {
        self.authorizer = authorizer
    }

    // MARK: - Public API

    /// Transcribe the audio track of a video file.
    /// Returns text + timestamped segments, or nil if no speech.
    func transcribe(
        videoURL: URL, isCurrent: @MainActor () -> Bool = { true }
    ) async -> TranscriptionResult? {
        guard isCurrent(), !Task.isCancelled else { return nil }
        state = .requesting

        // 0. Verify the file actually exists and is readable
        guard FileManager.default.isReadableFile(atPath: videoURL.path) else {
            state = .failed("Video file not accessible")
            return nil
        }

        // 1. Check / request authorization
        let authorized = await requestAuthorization()
        guard isCurrent(), !Task.isCancelled else { return nil }
        guard authorized else {
            state = .failed("Speech recognition permission denied")
            return nil
        }
        guard isCurrent(), !Task.isCancelled else { return nil }

        // 2. Run recognition (nonisolated — handles SFSpeechRecognizer internally)
        state = .transcribing
        progress = 0.1
        Log.debug("🎙️ [Transcribe] Starting recognition for \(videoURL.lastPathComponent)...", logger: Log.transcription)

        let result = await runRecognitionPipeline(videoURL: videoURL)
        guard isCurrent(), !Task.isCancelled else { return nil }

        if let result {
            state = .completed(result)
            progress = 1.0
            return result
        }

        state = .noSpeech
        progress = 1.0
        return nil
    }

    // MARK: - Recognition Pipeline (nonisolated)

    /// Runs the full recognition pipeline off the main actor.
    /// Creates SFSpeechRecognizer internally to avoid sending non-Sendable types across actors.
    /// Strategy: server-based first (more accurate), then on-device fallback.
    @concurrent private nonisolated func runRecognitionPipeline(videoURL: URL) async -> TranscriptionResult? {
        guard !Task.isCancelled else { return nil }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            Log.error("❌ [Transcribe] Speech recognizer unavailable for this locale", logger: Log.transcription)
            return nil
        }
        let callbackQueue = OperationQueue()
        callbackQueue.maxConcurrentOperationCount = 1
        recognizer.queue = callbackQueue

        // Attempt 1: Server-based (Apple's cloud — more accurate)
        if let serverResult = await attemptRecognition(
            recognizer: recognizer, callbackQueue: callbackQueue, videoURL: videoURL, onDevice: false
        ) {
            return serverResult
        }
        guard !Task.isCancelled else { return nil }

        // Attempt 2: On-device fallback (works offline, different model)
        if recognizer.supportsOnDeviceRecognition {
            Log.debug("🎙️ [Transcribe] Server-based found no speech, trying on-device model...", logger: Log.transcription)
            if let onDeviceResult = await attemptRecognition(
                recognizer: recognizer, callbackQueue: callbackQueue, videoURL: videoURL, onDevice: true
            ) {
                return onDeviceResult
            }
        }

        Log.debug("🎙️ [Transcribe] No speech detected after both attempts", logger: Log.transcription)
        return nil
    }

    /// Single recognition attempt — returns nil if no speech found.
    /// Runs entirely nonisolated to avoid sending non-Sendable Speech types across actors.
    @concurrent private nonisolated func attemptRecognition(
        recognizer: SFSpeechRecognizer,
        callbackQueue: OperationQueue,
        videoURL: URL,
        onDevice: Bool
    ) async -> TranscriptionResult? {
        let request = SFSpeechURLRecognitionRequest(url: videoURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = ["mediasource", "Mediasource", "b-roll", "B-roll", "slug", "standup", "Fixer", "breaking"]

        if onDevice {
            request.requiresOnDeviceRecognition = true
            Log.debug("🎙️ [Transcribe] Using on-device recognition", logger: Log.transcription)
        } else {
            Log.debug("🎙️ [Transcribe] Using server-based recognition", logger: Log.transcription)
        }

        do {
            let result = try await performRecognition(
                recognizer: recognizer, callbackQueue: callbackQueue, request: request)
            if let result {
                Log.debug("✅ [Transcribe] Got \(result.segments.count) segments (\(onDevice ? "on-device" : "server"))", logger: Log.transcription)
            }
            return result
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            let nsError = error as NSError
            // Error 203 = no speech — not a real error
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 203 {
                Log.debug("🎙️ [Transcribe] No speech detected (\(onDevice ? "on-device" : "server"), error 203)", logger: Log.transcription)
                return nil
            }
            Log.error("⚠️ [Transcribe] \(onDevice ? "On-device" : "Server") failed: \(Log.describe(error))", logger: Log.transcription)
            return nil
        }
    }

    // MARK: - Recognition (nonisolated to avoid actor hop in callback)

    /// Runs the speech recognition task in a nonisolated context so the
    /// callback closure doesn't cross actor boundaries.
    @concurrent private nonisolated func performRecognition(
        recognizer: SFSpeechRecognizer,
        callbackQueue: OperationQueue,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> TranscriptionResult? {
        let cancellation = TaskCancellationBridge()
        defer { withExtendedLifetime(cancellation) {} }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<TranscriptionResult?, Error>) in
                let delegate = SpeechRecognitionDelegate(continuation: continuation)
                let task = recognizer.recognitionTask(with: request, delegate: delegate)
                let handle = SpeechTaskHandle(task: task, delegate: delegate, queue: callbackQueue)
                cancellation.register { handle.cancel() }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        switch authorizer.speechStatus() {
        case .authorized: return true
        case .notDetermined: return await authorizer.requestSpeech() == .authorized
        default: return false
        }
    }
}

/// Confines the non-Sendable Speech task to its serial delegate queue and retains its delegate.
private nonisolated final class SpeechTaskHandle: @unchecked Sendable {
    private let task: SFSpeechRecognitionTask
    private let delegate: SpeechRecognitionDelegate
    private let queue: OperationQueue

    init(task: SFSpeechRecognitionTask, delegate: SpeechRecognitionDelegate, queue: OperationQueue) {
        self.task = task
        self.delegate = delegate
        self.queue = queue
    }

    func cancel() {
        queue.addOperation { [self] in
            withExtendedLifetime(delegate) { task.cancel() }
        }
    }
}

private nonisolated final class SpeechRecognitionDelegate: NSObject,
    SFSpeechRecognitionTaskDelegate, Sendable
{
    private let continuation: CheckedContinuation<TranscriptionResult?, Error>
    private let result = Mutex<TranscriptionResult?>(nil)
    private let gate = ResumeGate()

    init(continuation: CheckedContinuation<TranscriptionResult?, Error>) {
        self.continuation = continuation
    }

    func speechRecognitionTask(
        _ task: SFSpeechRecognitionTask, didFinishRecognition recognitionResult: SFSpeechRecognitionResult
    ) {
        let transcription = recognitionResult.bestTranscription
        let text = transcription.formattedString
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let segments = transcription.segments.map {
            TranscriptSegment(
                word: $0.substring, start: $0.timestamp,
                end: $0.timestamp + $0.duration, confidence: $0.confidence)
        }
        result.withLock { current in
            if let currentResult = current {
                current = TranscriptionResult(
                    text: "\(currentResult.text) \(text)",
                    segments: currentResult.segments + segments)
            } else {
                current = TranscriptionResult(text: text, segments: segments)
            }
        }
    }

    func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        guard gate.claim() else { return }
        continuation.resume(throwing: CancellationError())
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully success: Bool) {
        guard gate.claim() else { return }
        if success {
            continuation.resume(returning: result.withLock { $0 })
        } else {
            continuation.resume(throwing: task.error ?? SpeechRecognitionFailure.unknown)
        }
    }
}

private nonisolated enum SpeechRecognitionFailure: Error {
    case unknown
}

/// Lets exactly one recognition callback resume the continuation.
private nonisolated final class ResumeGate: Sendable {
    private let resumed = Mutex(false)

    /// Returns true the first time only.
    func claim() -> Bool {
        resumed.withLock { resumed in
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }
}
