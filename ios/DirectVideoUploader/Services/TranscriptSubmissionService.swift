// May 14, 2026 - 1:35pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

@MainActor
final class TranscriptSubmissionService {
    private let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func sendTranscript(assetId: String, result: TranscriptionResult, auth: AuthService) async {
        let request = auth.authenticatedRequest(
            for: ServerConfig.transcriptURL(assetId),
            method: "PATCH"
        )

        let segmentsData = try? JSONEncoder().encode(result.segments)
        let segmentsJSON = segmentsData.flatMap { try? JSONSerialization.jsonObject(with: $0) }

        let body: [String: Any] = [
            "transcript": result.text,
            "segments": segmentsJSON ?? [],
        ]

        do {
            _ = try await api.sendJSONObject(request, body: body)
            print("✅ Transcript saved for asset \(assetId) (\(result.segments.count) segments)")
        } catch {
            print("⚠️ Failed to save transcript: \(error)")
        }
    }
}
