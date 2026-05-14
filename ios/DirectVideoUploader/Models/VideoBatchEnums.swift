// May 14, 2026 - 10:10am - GitHub Copilot (Claude Opus 4.7)
import Foundation

enum VideoBatchState: String, Codable {
    case queued
    case indexing
    case uploading
    case paused
    case complete
    case partialFailed
}

enum VideoBatchItemStatus: String, Codable {
    case queued
    case creatingAsset
    case uploading
    case applyingForm
    case complete
    case failed
}
