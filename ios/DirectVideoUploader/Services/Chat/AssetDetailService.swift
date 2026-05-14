// May 14, 2026 - 1:35pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

struct AssetDetailFetchResult {
    let statusCode: Int
    let asset: Asset?
}

@MainActor
final class AssetDetailService {
    private let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func fetchAssetDetail(auth: AuthService, assetId: String) async throws -> AssetDetailFetchResult {
        let request = auth.authenticatedRequest(for: ServerConfig.assetURL(assetId))
        do {
            let detail = try await api.send(request, expecting: AssetDetailResponse.self)
            return AssetDetailFetchResult(statusCode: 200, asset: detail.asset)
        } catch let apiError as APIError {
            if let status = apiError.statusCode {
                return AssetDetailFetchResult(statusCode: status, asset: nil)
            }
            throw apiError
        }
    }
}
