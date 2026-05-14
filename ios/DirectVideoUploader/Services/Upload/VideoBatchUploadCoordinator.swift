// May 10, 2026 - 6:09pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

final class VideoBatchUploadCoordinator {
     let maxConcurrentUploads: Int

     init(maxConcurrentUploads: Int = 2) {
          self.maxConcurrentUploads = min(max(maxConcurrentUploads, 1), 3)
     }

     func executionOrder(for items: [VideoBatchItem], retryFailedOnly: Bool = false) -> [String] {
          let candidates =
               retryFailedOnly
               ? items.filter { $0.status == .failed }
               : items.filter { $0.status == .queued || $0.status == .failed }
          return candidates.map(\.localId)
     }

     func chunked(_ localIds: [String]) -> [[String]] {
          guard !localIds.isEmpty else { return [] }

          var chunks: [[String]] = []
          var current: [String] = []

          for localId in localIds {
               current.append(localId)
               if current.count == maxConcurrentUploads {
                    chunks.append(current)
                    current.removeAll(keepingCapacity: true)
               }
          }

          if !current.isEmpty {
               chunks.append(current)
          }

          return chunks
     }
}
