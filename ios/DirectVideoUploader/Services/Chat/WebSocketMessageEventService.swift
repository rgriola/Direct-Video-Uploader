// May 14, 2026 - 12:15am - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
protocol WebSocketMessageEventRuntime: AnyObject {
    func wsShouldSuppressMutation(assetId: String?, event: String) -> Bool
    func wsClearBlockingConnectivityIssue(assetId: String?)
    func wsIsBatchAssetId(assetId: String?) -> Bool
    func wsUpdateBatchClipMetadata(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    )
    func wsSetBatchClipPhase(assetId: String?, phase: VideoBubblePhase)
    func wsMarkBatchClipReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    )
    func wsMarkLatestOutgoingSlackAsConfirmed()
    func wsAppendWebSocketMessage(_ message: ChatMessage)
    func wsDownloadSlackThumbnail(url: URL, messageId: String)
}

@MainActor
final class WebSocketMessageEventService {
    private let suppressedBatchCodes: Set<String> = [
        "IOS_MUX_READY_FOLLOWUP",
        "IOS_MUX_READY_SUMMARY",
        "WS_FORM_CONFIRMED",
    ]

    func handle(message: ChatMessage, runtime: WebSocketMessageEventRuntime) {
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

            if message.messageType == .muxReady {
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
