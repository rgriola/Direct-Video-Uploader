// May 14, 2026 - GitHub Copilot (Claude Opus 4.7)
//
// Centralized location for files staged for upload.
//
// Why not `tmp/`?
//   iOS aggressively wipes the temporary directory across launches and under
//   storage pressure. Background tus uploads that get suspended overnight (or
//   batches restored after a crash) routinely find their source files gone.
//
// Why `Library/Caches/uploads/`?
//   The system can still purge it under storage pressure but does so far less
//   eagerly than `tmp/`, and never just because the app relaunched. That gives
//   our restore + retry pipeline a fighting chance. iCloud is not backing up
//   Caches, which is exactly what we want for transient upload bytes.
//
// Lifecycle:
//   - `stagingDirectory()` lazily creates the folder on first use.
//   - Callers move/copy the source video into a per-upload UUID subfolder.
//   - On successful upload (or explicit cancel), the caller removes the file
//     via `cleanupTempFile(_:)` paths in the chat view models.
//   - If a file is missing on restore, `UploadQueueRecoveryService` marks the
//     batch item `.failed` so the user can re-select.
import Foundation

enum UploadStorage {
    /// `<App>/Library/Caches/uploads/` — created on demand. Survives app
    /// relaunches, may be purged by the OS only under real storage pressure.
    static func stagingDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("uploads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
        return dir
    }

    /// Returns true if `url` lives inside any directory we treat as upload
    /// scratch space — the new Caches location and the legacy `tmp/` for
    /// in-flight files staged before this change shipped.
    static func isStagedUploadURL(_ url: URL) -> Bool {
        let stagingPath = stagingDirectory().path
        let tmpPath = FileManager.default.temporaryDirectory.path
        return url.path.hasPrefix(stagingPath) || url.path.hasPrefix(tmpPath)
    }
}
