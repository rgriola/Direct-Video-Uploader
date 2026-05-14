// May 14, 2026 - 10:10am - GitHub Copilot (Claude Opus 4.7)
import Foundation

struct VideoBatchItem: Identifiable, Codable {
    var id: String { localId }
    var localId: String
    var fileName: String
    var status: VideoBatchItemStatus
    var progress: Double
    var assetId: String?
    var error: String?
    var org: String?

    init(
        localId: String,
        fileName: String,
        status: VideoBatchItemStatus = .queued,
        progress: Double = 0,
        assetId: String? = nil,
        error: String? = nil,
        org: String? = nil
    ) {
        self.localId = localId
        self.fileName = fileName
        self.status = status
        self.progress = progress
        self.assetId = assetId
        self.error = error
        self.org = org
    }
}
