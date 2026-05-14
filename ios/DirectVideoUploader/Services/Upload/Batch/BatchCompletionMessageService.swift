// May 14, 2026 - 3:02am - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class BatchCompletionMessageService {
    func makeCompletionMessages(
        batchItems: [VideoBatchItem],
        firstName: String,
        batchClipDisplayByAssetId: [String: BatchClipDisplayState]
    ) -> [ChatMessage] {
        guard !batchItems.isEmpty else { return [] }

        let confirmedItems = batchItems.filter { $0.status == .complete }
        let unconfirmedItems = batchItems.filter { $0.status != .complete }

        let summaryText = buildSummaryText(
            confirmedItems: confirmedItems,
            unconfirmedItems: unconfirmedItems,
            mediasourceToken: { item in
                guard let assetId = item.assetId,
                    let state = batchClipDisplayByAssetId[assetId],
                    let msId = state.mediasourceId,
                    !msId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    return "MS# pending"
                }
                return "MS# \(msId)"
            }
        )

        return makeCompletionMessages(
            confirmedItems: confirmedItems,
            unconfirmedItems: unconfirmedItems,
            firstName: firstName,
            summaryText: summaryText
        )
    }

    func buildSummaryText(
        confirmedItems: [VideoBatchItem],
        unconfirmedItems: [VideoBatchItem],
        mediasourceToken: (VideoBatchItem) -> String
    ) -> String {
        var lines: [String] = []
        lines.append("Batch Summary")

        for item in confirmedItems {
            let msToken = mediasourceToken(item)
            let msColumn = msToken.padding(toLength: 14, withPad: " ", startingAt: 0)
            lines.append("🔗 \(msColumn) \(item.fileName)")
        }

        if !unconfirmedItems.isEmpty {
            lines.append("")
            lines.append("Unverified (\(unconfirmedItems.count))")

            for item in unconfirmedItems {
                let reason =
                    (item.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? item.error! : "Needs retry"
                lines.append("⚠️ \(item.fileName) • \(reason)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func makeCompletionMessages(
        confirmedItems: [VideoBatchItem],
        unconfirmedItems: [VideoBatchItem],
        firstName: String,
        summaryText: String
    ) -> [ChatMessage] {
        let summaryMessage = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: nil,
            direction: .incoming,
            messageType: .systemNote,
            content: MessageContent(
                text: summaryText,
                code: "IOS_BATCH_SUMMARY",
                fallbackText: summaryText,
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )

        let highFiveText = makeHighFiveText(
            confirmedCount: confirmedItems.count,
            unconfirmedCount: unconfirmedItems.count
        )

        let highFiveMessage = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: nil,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: highFiveText,
                code: "IOS_BATCH_HIGH_FIVE",
                params: [
                    "confirmedCount": "\(confirmedItems.count)",
                    "failedCount": "\(unconfirmedItems.count)",
                ],
                fallbackText: highFiveText,
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )

        let closingFallback =
            "\(firstName), you can Slack updates from this chat with #channel or @person, and I am ready for your next upload."
        let closingMessage = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: nil,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: closingFallback,
                code: "IOS_BATCH_CLOSING",
                params: [
                    "firstName": firstName,
                    "confirmedCount": "\(confirmedItems.count)",
                    "failedCount": "\(unconfirmedItems.count)",
                ],
                fallbackText: closingFallback,
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )

        return [summaryMessage, highFiveMessage, closingMessage]
    }

    private func makeHighFiveText(confirmedCount: Int, unconfirmedCount: Int) -> String {
        if unconfirmedCount == 0 {
            return "High five. Batch upload complete."
        }
        if confirmedCount > 0 {
            return "High five. Most clips landed, and I flagged what needs attention."
        }
        return "High five for sticking with it. This batch needs a retry pass."
    }
}
