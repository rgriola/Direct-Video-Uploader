// May 13, 2026 - 11:59pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class TranscriptSubmissionService {
    func sendTranscript(assetId: String, result: TranscriptionResult, auth: AuthService) async {
        var request = auth.authenticatedRequest(
            for: ServerConfig.transcriptURL(assetId),
            method: "PATCH"
        )

        let segmentsData = try? JSONEncoder().encode(result.segments)
        let segmentsJSON = segmentsData.flatMap { try? JSONSerialization.jsonObject(with: $0) }

        let body: [String: Any] = [
            "transcript": result.text,
            "segments": segmentsJSON ?? [],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                print("✅ Transcript saved for asset \(assetId) (\(result.segments.count) segments)")
            }
        } catch {
            print("⚠️ Failed to save transcript: \(error)")
        }
    }
}
