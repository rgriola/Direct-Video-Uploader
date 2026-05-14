// May 14, 2026 - 2:50pm - GitHub Copilot (Claude Opus 4.7)
// Extracted from VideoUploadService.swift (Priority 4: persistence isolation).
import Foundation

// MARK: - PHAsset Identifier Store

/// Persists a mapping of server assetId → PHAsset.localIdentifier so re-upload can find the original video.
enum PHAssetIdentifierStore {
    private static let storageURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("phasset-identifiers.json")
    }()

    static func save(assetId: String, phAssetIdentifier: String) {
        var map = loadAll()
        map[assetId] = phAssetIdentifier
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    static func identifier(for assetId: String) -> String? {
        loadAll()[assetId]
    }

    static func remove(assetId: String) {
        var map = loadAll()
        map.removeValue(forKey: assetId)
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    /// Wipe the entire assetId → PHAsset map from disk. Used by logout so a
    /// new session doesn't inherit the prior user's re-upload bindings.
    static func clearAll() {
        try? FileManager.default.removeItem(at: storageURL)
        AppLog.persistence.info("[PHAssetIdentifierStore] Cleared all PHAsset mappings")
    }

    private static func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: storageURL),
            let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }
}
