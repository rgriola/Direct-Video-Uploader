// May 13, 2026 - 10:20pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class ReadyWorkflowStateService {
    struct ArchiveSnapshot {
        let assetId: String?
        let mediasourceId: String?
        let mediasourceUrl: String?
        let originalFileName: String?
        let formSlug: String?
        let duration: Int?
        let resolution: String?
        let fileSize: String?
    }

    struct ReadyPlan {
        let archiveSnapshot: ArchiveSnapshot
        let summaryMessage: ChatMessage?
        let shouldScheduleFollowup: Bool
    }

    func makePlan(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        formSlug: String?,
        duration: Int?,
        resolution: String?,
        fileSize: String?,
        hasSummary: Bool,
        hasFollowup: Bool
    ) -> ReadyPlan {
        let snapshot = ArchiveSnapshot(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            originalFileName: originalFileName,
            formSlug: formSlug,
            duration: duration,
            resolution: resolution,
            fileSize: fileSize
        )

        let summaryMessage: ChatMessage?
        if hasSummary {
            summaryMessage = nil
        } else {
            summaryMessage = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: assetId,
                direction: .incoming,
                messageType: .streamReady,
                content: MessageContent(
                    text: "Mediasource confirmed.",
                    code: "IOS_MUX_READY_SUMMARY",
                    params: mediasourceId.map { ["mediasourceId": $0] },
                    fallbackText: "Mediasource confirmed.",
                    schemaVersion: MessageCatalog.schemaVersion,
                    slug: formSlug,
                    mediasourceId: mediasourceId,
                    mediasourceUrl: mediasourceUrl,
                    originalFileName: originalFileName,
                    duration: duration,
                    resolution: resolution,
                    fileSize: fileSize
                ),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
        }

        return ReadyPlan(
            archiveSnapshot: snapshot,
            summaryMessage: summaryMessage,
            shouldScheduleFollowup: !hasFollowup
        )
    }

    func makeFollowupMessage(assetId: String?, firstName: String) -> ChatMessage {
        let message = "You're a rock star. Send another video when ready."

        return ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .greeting,
            content: MessageContent(
                text: message,
                code: "IOS_MUX_READY_FOLLOWUP",
                params: ["firstName": firstName],
                fallbackText: message,
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
    }
}
