// May 13, 2026 - 4:31pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

struct AssetDetailFetchResult {
    let statusCode: Int
    let asset: Asset?
}

@MainActor
final class AssetDetailService {
    func fetchAssetDetail(auth: AuthService, assetId: String) async throws -> AssetDetailFetchResult {
        let request = auth.authenticatedRequest(for: ServerConfig.assetURL(assetId))
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            return AssetDetailFetchResult(statusCode: statusCode, asset: nil)
        }

        let detail = try JSONDecoder().decode(AssetDetailResponse.self, from: data)
        return AssetDetailFetchResult(statusCode: statusCode, asset: detail.asset)
    }
}
