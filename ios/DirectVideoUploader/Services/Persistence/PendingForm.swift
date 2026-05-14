// May 14, 2026 - 2:50pm - GitHub Copilot (Claude Opus 4.7)
// Extracted from VideoUploadService.swift (Priority 4: persistence isolation).
import Foundation

// MARK: - Persisted Form State

/// Saved to disk so the app can restore the context form after crash/kill.
struct PendingForm: Codable {
    let assetId: String
    let originalFileName: String?
    let capturedAt: String?
    let clipCount: Int?
    let duration: Int?
    let thumbnailJPEG: Data?  // JPEG-encoded thumbnail
    let savedAt: Date

    static let storageURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("pending-form.json")
    }()

    static func save(_ form: PendingForm) {
        do {
            let data = try JSONEncoder().encode(form)
            try data.write(to: storageURL, options: .atomic)
            print("💾 [Form] Saved pending form state for asset: \(form.assetId)")
        } catch {
            print("⚠️ [Form] Failed to save pending form state: \(error)")
        }
    }

    static func load() -> PendingForm? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: storageURL)
            return try JSONDecoder().decode(PendingForm.self, from: data)
        } catch {
            print("⚠️ [Form] Failed to load pending form state: \(error)")
            clear()
            return nil
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: storageURL)
        print("🗑️ [Form] Cleared pending form state")
    }
}
