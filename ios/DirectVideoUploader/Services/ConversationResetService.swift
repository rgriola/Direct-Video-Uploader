// May 13, 2026 - 11:59pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation
import UIKit

struct ConversationResetScalars {
    let currentAssetId: String?
    let isArchived: Bool
    let archive: ArchiveState
    let form: FormContext
    let lastAsset: Asset?
    let lastClip: Clip?
    let stagedVideo: StagedVideo?
    let isUploading: Bool
    let uploadProgress: Double
    let showFormSheet: Bool
    let showMetadataSheet: Bool
    let metadataSheetThumbnail: UIImage?
    let showSlackShareSheet: Bool
    let lastStagedCreatedDate: String?
    let lastStagedHasLocation: Bool
}

struct ConversationResetCollections {
    let sentUploads: [String: SentUploadInfo]
    let batchClipDisplayByAssetId: [String: BatchClipDisplayState]
    let sentUploadsByAssetId: [String: SentUploadInfo]
    let slackThumbnails: [String: UIImage]
    let slackConfirmedIds: Set<String>
    let assetDetailCache: [String: Asset]
}

@MainActor
final class ConversationResetService {
    func makeScalarReset() -> ConversationResetScalars {
        ConversationResetScalars(
            currentAssetId: nil,
            isArchived: false,
            archive: ArchiveState(),
            form: FormContext(),
            lastAsset: nil,
            lastClip: nil,
            stagedVideo: nil,
            isUploading: false,
            uploadProgress: 0,
            showFormSheet: false,
            showMetadataSheet: false,
            metadataSheetThumbnail: nil,
            showSlackShareSheet: false,
            lastStagedCreatedDate: nil,
            lastStagedHasLocation: false
        )
    }

    func makeCollectionReset() -> ConversationResetCollections {
        ConversationResetCollections(
            sentUploads: [:],
            batchClipDisplayByAssetId: [:],
            sentUploadsByAssetId: [:],
            slackThumbnails: [:],
            slackConfirmedIds: [],
            assetDetailCache: [:]
        )
    }

    func makeNewConversationGreeting(firstName: String) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: nil,
            direction: .incoming,
            messageType: .greeting,
            content: MessageContent(
                text: "Hey \(firstName). Upload away.",
                code: "IOS_GREETING_NEW_CONVERSATION",
                params: ["firstName": firstName],
                fallbackText: "Hiya \(firstName). Its time... to upload.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
    }
}
