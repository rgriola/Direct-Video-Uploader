import Speech
import Synchronization
import AVFoundation

/// Timestamped word segment from speech recognition.
struct TranscriptSegment: Codable, Sendable {
    let word: String
    let start: Double    // seconds from video start
    let end: Double      // start + duration
    let confidence: Float
}

/// Result from transcription — plain text + per-word timestamps.
struct TranscriptionResult: Sendable {
    let text: String
    let segments: [TranscriptSegment]
}

/// On-device video transcription using Apple Speech framework.
/// Requires iOS 17+ for guaranteed on-device recognition.
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
    func transcribe(videoURL: URL) async -> TranscriptionResult? {
        state = .requesting

        // 0. Verify the file actually exists and is readable
        guard FileManager.default.isReadableFile(atPath: videoURL.path) else {
            state = .failed("Video file not accessible")
            return nil
        }

        // 1. Check / request authorization
        let authorized = await requestAuthorization()
        guard authorized else {
            state = .failed("Speech recognition permission denied")
            return nil
        }

        // 2. Run recognition (nonisolated — handles SFSpeechRecognizer internally)
        state = .transcribing
        progress = 0.1
        print("🎙️ [Transcribe] Starting recognition for \(videoURL.lastPathComponent)...")

        let result = await runRecognitionPipeline(videoURL: videoURL)

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
    private nonisolated func runRecognitionPipeline(videoURL: URL) async -> TranscriptionResult? {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            print("❌ [Transcribe] Speech recognizer unavailable for this locale")
            return nil
        }

        // Attempt 1: Server-based (Apple's cloud — more accurate)
        if let serverResult = await attemptRecognition(recognizer: recognizer, videoURL: videoURL, onDevice: false) {
            return serverResult
        }

        // Attempt 2: On-device fallback (works offline, different model)
        if #available(iOS 16, *), recognizer.supportsOnDeviceRecognition {
            print("🎙️ [Transcribe] Server-based found no speech, trying on-device model...")
            if let onDeviceResult = await attemptRecognition(recognizer: recognizer, videoURL: videoURL, onDevice: true) {
                return onDeviceResult
            }
        }

        print("🎙️ [Transcribe] No speech detected after both attempts")
        return nil
    }

    /// Single recognition attempt — returns nil if no speech found.
    /// Runs entirely nonisolated to avoid sending non-Sendable Speech types across actors.
    private nonisolated func attemptRecognition(
        recognizer: SFSpeechRecognizer,
        videoURL: URL,
        onDevice: Bool
    ) async -> TranscriptionResult? {
        let request = SFSpeechURLRecognitionRequest(url: videoURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = ["mediasource", "Mediasource", "b-roll", "B-roll", "slug", "standup", "Fixer", "breaking"]

        if onDevice {
            if #available(iOS 16, *) {
                request.requiresOnDeviceRecognition = true
            }
            print("🎙️ [Transcribe] Using on-device recognition")
        } else {
            print("🎙️ [Transcribe] Using server-based recognition")
        }

        do {
            let result = try await performRecognition(recognizer: recognizer, request: request)
            if let result {
                print("✅ [Transcribe] Got \(result.segments.count) segments (\(onDevice ? "on-device" : "server")), text: \"\(result.text.prefix(80))...\"")
            }
            return result
        } catch {
            let nsError = error as NSError
            // Error 203 = no speech — not a real error
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 203 {
                print("🎙️ [Transcribe] No speech detected (\(onDevice ? "on-device" : "server"), error 203)")
                return nil
            }
            print("⚠️ [Transcribe] \(onDevice ? "On-device" : "Server") failed: \(error.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))")
            return nil
        }
    }

    // MARK: - Recognition (nonisolated to avoid actor hop in callback)

    /// Runs the speech recognition task in a nonisolated context so the
    /// callback closure doesn't cross actor boundaries.
    private nonisolated func performRecognition(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> TranscriptionResult? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscriptionResult?, Error>) in
            let gate = ResumeGate()

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                    return
                }
                if let result, result.isFinal {
                    guard gate.claim() else { return }
                    let text = result.bestTranscription.formattedString
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.resume(returning: nil)
                        return
                    }
                    let segments = result.bestTranscription.segments.map { seg in
                        TranscriptSegment(
                            word: seg.substring,
                            start: seg.timestamp,
                            end: seg.timestamp + seg.duration,
                            confidence: seg.confidence
                        )
                    }
                    continuation.resume(returning: TranscriptionResult(text: text, segments: segments))
                }
            }
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

/// Lets exactly one recognition callback resume the continuation.
private final class ResumeGate: Sendable {
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
