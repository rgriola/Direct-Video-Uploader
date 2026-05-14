// May 13, 2026 - 6:14pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class BatchClipDisplayService {
    func displayState(
        for assetId: String?,
        states: [String: BatchClipDisplayState],
        batchItems: [VideoBatchItem]
    ) -> BatchClipDisplayState? {
        guard let assetId, !assetId.isEmpty else { return nil }

        if let stored = states[assetId] {
            return stored
        }

        guard let item = batchItems.first(where: { $0.assetId == assetId }) else {
            return nil
        }

        return BatchClipDisplayState(
            phase: phase(for: item.status),
            progress: min(max(item.progress, 0), 1),
            mediasourceId: nil,
            mediasourceUrl: nil,
            formSlug: nil,
            errorText: item.error
        )
    }

    func isBatchAssetId(
        _ assetId: String?,
        states: [String: BatchClipDisplayState],
        batchItems: [VideoBatchItem]
    ) -> Bool {
        guard let assetId, !assetId.isEmpty else { return false }
        if states[assetId] != nil {
            return true
        }
        return batchItems.contains(where: { $0.assetId == assetId })
    }

    func phase(for status: VideoBatchItemStatus) -> VideoBubblePhase {
        switch status {
        case .failed:
            return .failed
        case .queued, .creatingAsset, .uploading:
            return .uploading
        case .applyingForm, .complete:
            return .processing
        }
    }

    func setPhase(
        assetId: String?,
        phase: VideoBubblePhase,
        states: inout [String: BatchClipDisplayState],
        batchItems: [VideoBatchItem]
    ) {
        guard let assetId, !assetId.isEmpty else { return }

        var state =
            displayState(for: assetId, states: states, batchItems: batchItems)
            ?? BatchClipDisplayState(
                phase: .uploading,
                progress: 0,
                mediasourceId: nil,
                mediasourceUrl: nil,
                formSlug: nil,
                errorText: nil
            )
        state.phase = phase

        if phase == .sent {
            state.progress = 1
            state.errorText = nil
        }

        states[assetId] = state
    }

    func updateProgress(
        assetId: String?,
        progress: Double,
        states: inout [String: BatchClipDisplayState],
        batchItems: [VideoBatchItem]
    ) {
        guard let assetId, !assetId.isEmpty else { return }

        var state =
            displayState(for: assetId, states: states, batchItems: batchItems)
            ?? BatchClipDisplayState(
                phase: .uploading,
                progress: 0,
                mediasourceId: nil,
                mediasourceUrl: nil,
                formSlug: nil,
                errorText: nil
            )
        state.progress = min(max(progress, 0), 1)
        states[assetId] = state
    }

    func updateMetadata(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?,
        states: inout [String: BatchClipDisplayState],
        batchItems: [VideoBatchItem]
    ) {
        guard let assetId, !assetId.isEmpty else { return }

        var state =
            displayState(for: assetId, states: states, batchItems: batchItems)
            ?? BatchClipDisplayState(
                phase: .processing,
                progress: 1,
                mediasourceId: nil,
                mediasourceUrl: nil,
                formSlug: nil,
                errorText: nil
            )

        if let mediasourceId,
            !mediasourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            state.mediasourceId = mediasourceId
        }

        if let mediasourceUrl,
            !mediasourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            state.mediasourceUrl = mediasourceUrl
        }

        if let formSlug,
            !formSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            state.formSlug = formSlug
        }

        states[assetId] = state
    }

    func markReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?,
        states: inout [String: BatchClipDisplayState],
        batchItems: [VideoBatchItem]
    ) {
        updateMetadata(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            formSlug: formSlug,
            states: &states,
            batchItems: batchItems
        )
        setPhase(
            assetId: assetId,
            phase: .sent,
            states: &states,
            batchItems: batchItems
        )
        updateProgress(
            assetId: assetId,
            progress: 1,
            states: &states,
            batchItems: batchItems
        )
    }

    func markFailedDisplay(
        assetId: String,
        reason: String,
        states: inout [String: BatchClipDisplayState],
        batchItems: [VideoBatchItem]
    ) {
        var state =
            displayState(for: assetId, states: states, batchItems: batchItems)
            ?? BatchClipDisplayState(
                phase: .failed,
                progress: 1,
                mediasourceId: nil,
                mediasourceUrl: nil,
                formSlug: nil,
                errorText: nil
            )
        state.phase = .failed
        state.errorText = reason
        states[assetId] = state
    }
}
