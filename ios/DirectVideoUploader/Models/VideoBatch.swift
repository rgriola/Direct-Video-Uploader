// May 10, 2026 - 6:09pm - GitHub Copilot (GPT-5.3-Codex)
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

struct VideoBatchContext: Codable {
     var slug: String
     var type: String
     var description: String
     var priority: String
     var destination: String?
     var org: String?
}

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

struct VideoBatch: Identifiable, Codable {
     var id: String
     var createdAt: Date
     var state: VideoBatchState
     var items: [VideoBatchItem]
     var context: VideoBatchContext?

     var completedCount: Int {
          items.filter { $0.status == .complete }.count
     }

     var failedCount: Int {
          items.filter { $0.status == .failed }.count
     }

     var overallProgress: Double {
          guard !items.isEmpty else { return 0 }
          let total = items.reduce(0) { partial, item in
               partial + min(max(item.progress, 0), 1)
          }
          return total / Double(items.count)
     }
}
