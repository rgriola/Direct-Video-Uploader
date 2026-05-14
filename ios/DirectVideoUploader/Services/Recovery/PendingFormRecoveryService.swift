// May 13, 2026 - 5:25pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

enum PendingFormRecoveryDecision {
    case clear
    case restore
}

@MainActor
final class PendingFormRecoveryService {
    private let assetDetailService = AssetDetailService()

    func evaluate(auth: AuthService, pendingForm: PendingForm) async throws -> PendingFormRecoveryDecision {
        let result = try await assetDetailService.fetchAssetDetail(
            auth: auth,
            assetId: pendingForm.assetId
        )

        guard result.statusCode == 200, let asset = result.asset else {
            return .clear
        }

        return asset.formResponse != nil ? .clear : .restore
    }
}
