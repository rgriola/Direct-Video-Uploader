// May 14, 2026 - 9:49am - GitHub Copilot (Claude Opus 4.7)
import Foundation

enum PendingBatchStore {
     private static let directoryName = "pending-batches"
     private static let latestPointerName = "latest-batch-id.txt"

     private static var storageDirectoryURL: URL {
          let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          return docs.appendingPathComponent(directoryName, isDirectory: true)
     }

     private static var latestPointerURL: URL {
          storageDirectoryURL.appendingPathComponent(latestPointerName)
     }

     private static let encoder: JSONEncoder = {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          encoder.dateEncodingStrategy = .iso8601
          return encoder
     }()

     private static let decoder: JSONDecoder = {
          let decoder = JSONDecoder()
          decoder.dateDecodingStrategy = .iso8601
          return decoder
     }()

     static func save(_ batch: VideoBatch) {
          do {
               try ensureStorageDirectoryExists()
               let url = batchURL(batchId: batch.id)
               let data = try encoder.encode(batch)
               try data.write(to: url, options: .atomic)
               try batch.id.data(using: .utf8)?.write(to: latestPointerURL, options: .atomic)
               AppLog.persistence.info("[Batch] Saved pending batch state: \(batch.id)")
          } catch {
               AppLog.persistence.warning("[Batch] Failed to save pending batch: \(error.localizedDescription)")
          }
     }

     static func load(batchId: String) -> VideoBatch? {
          let url = batchURL(batchId: batchId)
          guard FileManager.default.fileExists(atPath: url.path) else { return nil }

          do {
               let data = try Data(contentsOf: url)
               return try decoder.decode(VideoBatch.self, from: data)
          } catch {
               AppLog.persistence.warning("[Batch] Failed to load batch \(batchId): \(error.localizedDescription)")
               return nil
          }
     }

     static func loadLatest() -> VideoBatch? {
          if let latestId = try? String(contentsOf: latestPointerURL).trimmingCharacters(
               in: .whitespacesAndNewlines),
               !latestId.isEmpty,
               let batch = load(batchId: latestId)
          {
               return batch
          }

          guard
               let fileURLs = try? FileManager.default.contentsOfDirectory(
                    at: storageDirectoryURL,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
               )
          else {
               return nil
          }

          let latestFile =
               fileURLs
               .filter { $0.pathExtension == "json" }
               .max {
                    let leftDate =
                         (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                         .contentModificationDate ?? .distantPast
                    let rightDate =
                         (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                         .contentModificationDate ?? .distantPast
                    return leftDate < rightDate
               }

          guard let latestFile else { return nil }
          guard let data = try? Data(contentsOf: latestFile) else { return nil }
          return try? decoder.decode(VideoBatch.self, from: data)
     }

     static func clear(batchId: String) {
          do {
               let url = batchURL(batchId: batchId)
               if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
               }

               let latestId =
                    (try? String(contentsOf: latestPointerURL).trimmingCharacters(
                         in: .whitespacesAndNewlines)) ?? ""
               if latestId == batchId, FileManager.default.fileExists(atPath: latestPointerURL.path)
               {
                    try FileManager.default.removeItem(at: latestPointerURL)
               }

               AppLog.persistence.info("[Batch] Cleared pending batch state: \(batchId)")
          } catch {
               AppLog.persistence.warning("[Batch] Failed to clear batch \(batchId): \(error.localizedDescription)")
          }
     }

     /// Wipe every persisted batch + the latest pointer. Used by logout so a
     /// new session doesn't inherit the prior user's restored batch state.
     static func clearAll() {
          do {
               if FileManager.default.fileExists(atPath: storageDirectoryURL.path) {
                    try FileManager.default.removeItem(at: storageDirectoryURL)
               }
               AppLog.persistence.info("[Batch] Cleared all pending batch state")
          } catch {
               AppLog.persistence.warning("[Batch] Failed to clear all batches: \(error.localizedDescription)")
          }
     }

     private static func batchURL(batchId: String) -> URL {
          storageDirectoryURL.appendingPathComponent("\(batchId).json")
     }

     private static func ensureStorageDirectoryExists() throws {
          if !FileManager.default.fileExists(atPath: storageDirectoryURL.path) {
               try FileManager.default.createDirectory(
                    at: storageDirectoryURL,
                    withIntermediateDirectories: true
               )
          }
     }
}
