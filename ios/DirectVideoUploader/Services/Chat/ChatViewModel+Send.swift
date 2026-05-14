// May 14, 2026 - 11:00am - GitHub Copilot (Claude Opus 4.7)
//
// Extension extracted from ChatViewModel.swift during P8 file decomposition.

import Foundation
import UIKit
import Observation

extension ChatViewModel {

    // MARK: - Send Text Message

    // Matches #channel or @mention anywhere in the text (mirrors server-side regex)
    static let slackCommandPattern = try? NSRegularExpression(pattern: "[#@][\\w.-]+")

    func sendTextMessage(_ text: String) {
        let slackTargetAssetId = activeSlackTargetAssetId()
        let slackTargetAssetIds = activeSlackTargetAssetIds()

        guard
            let sendPlan = textMessageFlowService.makePlan(
                text: text,
                slackCommandPattern: Self.slackCommandPattern,
                currentAssetId: currentAssetId,
                slackTargetAssetId: slackTargetAssetId,
                slackTargetAssetIds: slackTargetAssetIds
            )
        else {
            return
        }

        if sendPlan.shouldWarnNoUploadContext {
            appendMessage(
                textMessageFlowService.makeOutgoingMessage(
                    text: text,
                    userId: auth.currentUser?.id,
                    messageType: .slackPost
                ),
                source: .outgoing
            )
            appendMessage(textMessageFlowService.makeSlackRequiresUploadReply(), source: .workflow)
            return
        }

        appendMessage(
            textMessageFlowService.makeOutgoingMessage(
                text: text,
                userId: auth.currentUser?.id,
                messageType: sendPlan.outgoingMessageType
            ),
            source: .outgoing
        )

        // Send via WebSocket — always pass explicit assetId so the server
        // doesn't fall back to "most recent READY asset" (wrong metadata bug).
        ws.sendMessage(
            text: text,
            assetId: sendPlan.messageAssetId,
            assetIds: sendPlan.messageAssetIds
        )
    }
    // MARK: - Create Asset (Video Upload Flow)

    func createAsset(fileName: String, fileURL: URL) async -> Asset? {
        await singleUploadFlowService.createAsset(
            fileName: fileName,
            fileURL: fileURL,
            thumbnail: form.thumbnail,
            createdDate: lastStagedCreatedDate,
            hasLocation: lastStagedHasLocation,
            transcribeEnabled: transcribeOnUpload,
            auth: auth,
            transport: batchUploadTransportService,
            presentation: batchAssetPresentationService,
            host: self
        )
    }

    // MARK: - Upload Video

    func uploadVideo(assetId: String, fileURL: URL, metadata: VideoMetadata? = nil) async {
        await singleUploadFlowService.uploadVideo(
            assetId: assetId,
            fileURL: fileURL,
            metadata: metadata,
            token: auth.token,
            uploader: uploader,
            host: self
        )
    }

    // MARK: - Send Transcript

    /// Send transcript text + timestamped segments to the server (non-fatal).
    func sendTranscript(assetId: String, result: TranscriptionResult) async {
        await transcriptSubmissionService.sendTranscript(assetId: assetId, result: result, auth: auth)
    }
}
