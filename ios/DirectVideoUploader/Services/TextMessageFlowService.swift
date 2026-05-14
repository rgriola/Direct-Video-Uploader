// May 13, 2026 - 11:53pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

struct TextMessageSendPlan {
    let isSlackCommand: Bool
    let shouldWarnNoUploadContext: Bool
    let outgoingMessageType: MessageType
    let messageAssetId: String?
    let messageAssetIds: [String]?
}

@MainActor
final class TextMessageFlowService {
    private let slackRequiresUploadText =
        "Upload a video first and I can grab the metadata so you can Slack it. Previous uploads are in your Archive, and you can Slack from there."

    func makePlan(
        text: String,
        slackCommandPattern: NSRegularExpression?,
        currentAssetId: String?,
        slackTargetAssetId: String?,
        slackTargetAssetIds: [String]?
    ) -> TextMessageSendPlan? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let isSlackCommand = slackCommandPattern?.firstMatch(in: trimmed, range: range) != nil
        let hasBatchSlackTargets = !(slackTargetAssetIds?.isEmpty ?? true)
        let shouldWarnNoUploadContext =
            isSlackCommand
            && slackTargetAssetId == nil
            && !hasBatchSlackTargets

        let messageAssetId: String? = {
            if let currentAssetId, !currentAssetId.isEmpty {
                return currentAssetId
            }
            if let firstBatchAssetId = slackTargetAssetIds?.first {
                return firstBatchAssetId
            }
            if isSlackCommand {
                return slackTargetAssetId
            }
            return nil
        }()

        return TextMessageSendPlan(
            isSlackCommand: isSlackCommand,
            shouldWarnNoUploadContext: shouldWarnNoUploadContext,
            outgoingMessageType: isSlackCommand ? .slackPost : .text,
            messageAssetId: messageAssetId,
            messageAssetIds: isSlackCommand ? slackTargetAssetIds : nil
        )
    }

    func makeOutgoingMessage(text: String, userId: String?, messageType: MessageType) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            userId: userId,
            assetId: nil,
            direction: .outgoing,
            messageType: messageType,
            content: MessageContent(text: text),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
    }

    func makeSlackRequiresUploadReply() -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: nil,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: slackRequiresUploadText,
                code: "IOS_SLACK_REQUIRES_UPLOAD",
                fallbackText: slackRequiresUploadText,
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
    }
}
