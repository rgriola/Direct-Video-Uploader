// May 13, 2026 - 5:58pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

enum WorkflowStage: Int {
    case unknown = 0
    case uploading = 10
    case formRequested = 20
    case formConfirmed = 30
    case processing = 40
    case ready = 50
    case failed = 60
}

@MainActor
final class WorkflowStageTracker {
    private var stagesByAssetId: [String: WorkflowStage] = [:]

    func reset() {
        stagesByAssetId.removeAll()
    }

    func promote(assetId: String?, to stage: WorkflowStage) -> WorkflowStage {
        guard let assetId, !assetId.isEmpty else { return .unknown }

        let previous = stagesByAssetId[assetId] ?? .unknown

        if stage == .failed {
            if previous != .failed {
                stagesByAssetId[assetId] = .failed
            }
            return previous
        }

        if previous == .failed {
            stagesByAssetId[assetId] = stage
            return previous
        }

        if stage.rawValue > previous.rawValue {
            stagesByAssetId[assetId] = stage
        }
        return previous
    }

    static func inferredStage(from asset: Asset) -> WorkflowStage {
        switch asset.status {
        case .error:
            return .failed
        case .ready:
            return .ready
        case .processing:
            return .processing
        case .uploading:
            if asset.formResponse != nil {
                return .formConfirmed
            }
            return .uploading
        }
    }
}
