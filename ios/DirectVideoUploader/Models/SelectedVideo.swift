// May 14, 2026 - 10:10am - GitHub Copilot (Claude Opus 4.7)
import Foundation

struct SelectedVideo: Identifiable, Codable {
    var id: String
    var fileURL: URL
    var fileName: String
    var metadata: VideoMetadata
    var phAssetIdentifier: String?

    init(
        id: String = UUID().uuidString,
        fileURL: URL,
        fileName: String,
        metadata: VideoMetadata,
        phAssetIdentifier: String? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.metadata = metadata
        self.phAssetIdentifier = phAssetIdentifier
    }
}
