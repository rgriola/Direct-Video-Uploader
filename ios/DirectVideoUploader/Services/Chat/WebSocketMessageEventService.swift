// May 14, 2026 - 3:10pm - GitHub Copilot (Claude Opus 4.7)
// Runtime protocol consolidated into Services/Chat/WebSocketEventRuntime.swift (Priority 5).
import Foundation

@MainActor
final class WebSocketMessageEventService {
    private let suppressedBatchCodes: Set<String> = [
        "IOS_MUX_READY_FOLLOWUP",
        "IOS_MUX_READY_SUMMARY",
        "WS_FORM_CONFIRMED",
    ]

    func handle(message: ChatMessage, runtime: WebSocketEventRuntime) {
        runtime.wsClearBlockingConnectivityIssue(assetId: message.assetId)

        if runtime.wsShouldSuppressMutation(assetId: message.assetId, event: "message:new") {
            return
        }

        if runtime.wsIsBatchAssetId(assetId: message.assetId) {
            if message.messageType == .confirmation {
                runtime.wsUpdateBatchClipMetadata(
                    assetId: message.assetId,
                    mediasourceId: message.content.mediasourceId,
                    mediasourceUrl: message.content.mediasourceUrl,
                    formSlug: message.content.slug
                )
                runtime.wsSetBatchClipPhase(assetId: message.assetId, phase: .processing)
                return
            }

            if message.messageType == .streamReady {
                runtime.wsMarkBatchClipReady(
                    assetId: message.assetId,
                    mediasourceId: message.content.mediasourceId,
                    mediasourceUrl: message.content.mediasourceUrl,
                    formSlug: message.content.slug
                )
                return
            }

            if let code = message.content.code,
                suppressedBatchCodes.contains(code)
            {
                return
            }
        }

        if message.messageType == .slackPost,
            message.direction == .incoming
        {
            runtime.wsMarkLatestOutgoingSlackAsConfirmed()
        }

        runtime.wsAppendWebSocketMessage(message)

        if message.messageType == .slackPost,
            message.direction == .incoming,
            let urlString = message.content.thumbnailUrl,
            let url = URL(string: urlString)
        {
            runtime.wsDownloadSlackThumbnail(url: url, messageId: message.id)
        }
    }
}
