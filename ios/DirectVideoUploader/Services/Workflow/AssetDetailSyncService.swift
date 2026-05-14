// May 14, 2026 - 3:35pm - GitHub Copilot (Claude Opus 4.7)
// Priority 5b: Dependencies closure-bag replaced with AssetDetailSyncHost protocol.
import Foundation

@MainActor
protocol AssetDetailSyncHost: AnyObject {
    func adsFetchAssetDetail(assetId: String) async throws -> AssetDetailFetchResult
    func adsHasDetailLoadFailureMessage(assetId: String) -> Bool
    func adsAppendDetailLoadFailureBubble(assetId: String)
    func adsCacheAsset(_ asset: Asset)
    func adsClearBlockingConnectivityIssue(assetId: String)
    func adsReconcileWorkflowState(asset: Asset)
    func adsIsConnectivityIssue(_ error: Error) -> Bool
    func adsNoteBlockingConnectivityIssue(operation: String, assetId: String?)
}

@MainActor
final class AssetDetailSyncService {
    func sync(
        assetId: String,
        presentErrorsInChat: Bool,
        reason: String,
        host: AssetDetailSyncHost
    ) async {
        do {
            let result = try await host.adsFetchAssetDetail(assetId: assetId)
            let statusCode = result.statusCode

            guard statusCode == 200 else {
                #if DEBUG
                    print(
                        "⚠️ [AssetDetail] Skipped detail sync (status=\(statusCode), asset=\(assetId), reason=\(reason), presentErrorsInChat=\(presentErrorsInChat))"
                    )
                #endif

                guard presentErrorsInChat else { return }

                if !host.adsHasDetailLoadFailureMessage(assetId: assetId) {
                    host.adsAppendDetailLoadFailureBubble(assetId: assetId)
                }
                return
            }

            guard let asset = result.asset else { return }
            host.adsCacheAsset(asset)
            host.adsClearBlockingConnectivityIssue(assetId: assetId)
            host.adsReconcileWorkflowState(asset: asset)
        } catch {
            print("❌ Failed to fetch asset detail:", error)
            if host.adsIsConnectivityIssue(error) {
                host.adsNoteBlockingConnectivityIssue(
                    operation: "syncing metadata",
                    assetId: assetId
                )
            } else if presentErrorsInChat {
                if !host.adsHasDetailLoadFailureMessage(assetId: assetId) {
                    host.adsAppendDetailLoadFailureBubble(assetId: assetId)
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
