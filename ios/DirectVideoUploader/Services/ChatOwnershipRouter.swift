// May 13, 2026 - 4:16pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class ChatOwnershipRouter {
    private let maxArchivedAssetOwnership: Int
    private var activeAssetIds: Set<String> = []
    private var archivedAssetIds: Set<String> = []

    init(maxArchivedAssetOwnership: Int = 250) {
        self.maxArchivedAssetOwnership = max(1, maxArchivedAssetOwnership)
    }

    func registerActiveAsset(_ assetId: String?) {
        guard let normalized = normalizedAssetId(assetId) else { return }
        activeAssetIds.insert(normalized)
        archivedAssetIds.remove(normalized)
    }

    func archiveCurrentOwnership(currentAssetId: String?, batchAssetIds: [String?]) {
        var assetsToArchive = activeAssetIds

        if let normalizedCurrentAssetId = normalizedAssetId(currentAssetId) {
            assetsToArchive.insert(normalizedCurrentAssetId)
        }

        for batchAssetId in batchAssetIds {
            if let normalizedBatchAssetId = normalizedAssetId(batchAssetId) {
                assetsToArchive.insert(normalizedBatchAssetId)
            }
        }

        guard !assetsToArchive.isEmpty else { return }

        archivedAssetIds.formUnion(assetsToArchive)
        activeAssetIds.subtract(assetsToArchive)
        trimArchivedOwnershipIfNeeded()
    }

    func shouldSuppressChatMutation(
        for assetId: String?,
        currentAssetId: String?,
        hasActiveBatch: Bool,
        isBatchAssetId: (String) -> Bool,
        event: String,
        log: (String) -> Void
    ) -> Bool {
        guard let normalized = normalizedAssetId(assetId) else { return false }

        if activeAssetIds.contains(normalized) {
            return false
        }

        let normalizedCurrentAssetId = normalizedAssetId(currentAssetId)
        if normalizedCurrentAssetId == normalized || isBatchAssetId(normalized) {
            registerActiveAsset(normalized)
            return false
        }

        if archivedAssetIds.contains(normalized) {
            log("🗂️ [ChatOwnership] Suppressed \(event) for archived asset \(normalized)")
            return true
        }

        let hasActiveWorkflowContext =
            !activeAssetIds.isEmpty || normalizedCurrentAssetId != nil || hasActiveBatch

        if hasActiveWorkflowContext {
            archivedAssetIds.insert(normalized)
            trimArchivedOwnershipIfNeeded()
            log("🗂️ [ChatOwnership] Routed \(event) to archive-only for asset \(normalized)")
            return true
        }

        return false
    }

    private func normalizedAssetId(_ assetId: String?) -> String? {
        guard let assetId else { return nil }
        let trimmed = assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func trimArchivedOwnershipIfNeeded() {
        guard archivedAssetIds.count > maxArchivedAssetOwnership else { return }

        let overflow = archivedAssetIds.count - maxArchivedAssetOwnership
        let idsToRemove = archivedAssetIds.sorted().prefix(overflow)
        for id in idsToRemove {
            archivedAssetIds.remove(id)
        }
    }
}
