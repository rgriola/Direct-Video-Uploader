// May 13, 2026 - 8:22pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation
import UIKit

struct BatchAssetPresentation {
    let messageId: String
    let message: ChatMessage
    let uploadInfo: SentUploadInfo
}

@MainActor
final class BatchAssetPresentationService {
    func makePresentation(
        userId: String?,
        assetId: String,
        fileName: String,
        thumbnail: UIImage?,
        createdDate: String?,
        hasLocation: Bool,
        transcribeEnabled: Bool = false
    ) -> BatchAssetPresentation {
        let messageId = UUID().uuidString
        let message = ChatMessage(
            id: messageId,
            userId: userId,
            assetId: assetId,
            direction: .outgoing,
            messageType: .video,
            content: MessageContent(text: "📹 \(fileName)", fileName: fileName),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )

        let uploadInfo = SentUploadInfo(
            thumbnail: thumbnail,
            fileName: fileName,
            createdDate: createdDate ?? DVUDateFormatting.longDate(from: Date()),
            hasLocation: hasLocation,
            transcribeEnabled: transcribeEnabled
        )

        return BatchAssetPresentation(
            messageId: messageId,
            message: message,
            uploadInfo: uploadInfo
        )
    }
}
