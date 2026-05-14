// May 14, 2026 - 10:10am - GitHub Copilot (Claude Opus 4.7)
import Foundation

struct VideoBatch: Identifiable, Codable {
    var id: String
    var createdAt: Date
    var state: VideoBatchState
    var items: [VideoBatchItem]
    var context: VideoBatchContext?
    var stagedVideos: [SelectedVideo]?
    var groupedFormData: [String: String]?

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
