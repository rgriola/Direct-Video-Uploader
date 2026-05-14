// May 13, 2026 - 11:46pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class AssetDetailSyncService {
    struct Dependencies {
        let fetchAssetDetail: (String) async throws -> AssetDetailFetchResult
        let hasDetailLoadFailureMessage: (String) -> Bool
        let appendDetailLoadFailureBubble: (String) -> Void
        let cacheAsset: (Asset) -> Void
        let clearBlockingConnectivityIssue: (String) -> Void
        let reconcileWorkflowState: (Asset) -> Void
        let isConnectivityIssue: (Error) -> Bool
        let noteBlockingConnectivityIssue: (String, String?) -> Void
    }

    func sync(
        assetId: String,
        presentErrorsInChat: Bool,
        reason: String,
        dependencies: Dependencies
    ) async {
        do {
            let result = try await dependencies.fetchAssetDetail(assetId)
            let statusCode = result.statusCode

            guard statusCode == 200 else {
                #if DEBUG
                    print(
                        "⚠️ [AssetDetail] Skipped detail sync (status=\(statusCode), asset=\(assetId), reason=\(reason), presentErrorsInChat=\(presentErrorsInChat))"
                    )
                #endif

                guard presentErrorsInChat else { return }

                if !dependencies.hasDetailLoadFailureMessage(assetId) {
                    dependencies.appendDetailLoadFailureBubble(assetId)
                }
                return
            }

            guard let asset = result.asset else { return }
            dependencies.cacheAsset(asset)
            dependencies.clearBlockingConnectivityIssue(assetId)
            dependencies.reconcileWorkflowState(asset)
        } catch {
            print("❌ Failed to fetch asset detail:", error)
            if dependencies.isConnectivityIssue(error) {
                dependencies.noteBlockingConnectivityIssue("syncing metadata", assetId)
            } else if presentErrorsInChat {
                if !dependencies.hasDetailLoadFailureMessage(assetId) {
                    dependencies.appendDetailLoadFailureBubble(assetId)
                }
            } else {
                #if DEBUG
                    print(
                        "⚠️ [AssetDetail] Suppressed error bubble for asset \(assetId) during \(reason): \(error.localizedDescription)"
                    )
                #endif
            }
        }
    }
}
