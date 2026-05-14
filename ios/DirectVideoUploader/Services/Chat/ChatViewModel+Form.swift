// May 14, 2026 - 11:00am - GitHub Copilot (Claude Opus 4.7)
//
// Extension extracted from ChatViewModel.swift during P8 file decomposition.

import Foundation
import UIKit
import Observation

extension ChatViewModel {

    // MARK: - Private Helpers

    /// Save thumbnail + metadata from staged video, clear the preview.
    func prepareStagedContext(_ staged: StagedVideo) {
        form.thumbnail = staged.thumbnail
        lastStagedCreatedDate = staged.createdDate
        lastStagedHasLocation = staged.metadata.gpsLat != nil
        stagedVideo = nil  // Clear immediately — VideoBubble (.uploading) takes over
    }

    /// Parse dynamic payload params into a string-only dictionary for template rendering.
    func parseStringParams(_ value: Any?) -> [String: String]? {
        guard let dict = value as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (key, raw) in dict {
            switch raw {
            case let s as String:
                out[key] = s
            case let b as Bool:
                out[key] = b ? "true" : "false"
            case let n as NSNumber:
                out[key] = n.stringValue
            default:
                continue
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Persist PHAsset identifier so re-upload can find the original video.
    func savePHAssetIdentifier(for assetId: String) {
        if let phId = pendingPHAssetIdentifier {
            PHAssetIdentifierStore.save(assetId: assetId, phAssetIdentifier: phId)
        }
        pendingPHAssetIdentifier = nil
    }

    /// Transcribe audio and update the status bubble in-place.
    func transcribeAndReport(assetId: String, fileURL: URL) async {
        let transcribingMsg = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: "Transcribing audio...",
                code: "IOS_TRANSCRIBE_START",
                fallbackText: "Transcribing audio...",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(transcribingMsg, source: .workflow)

        if let result = await transcriber.transcribe(videoURL: fileURL) {
            await sendTranscript(assetId: assetId, result: result)
            updateTranscriptionBubble(
                id: transcribingMsg.id, assetId: assetId,
                text:
                    "Transcript sent to Mediasource. (\(result.segments.count) words.) Transcript is available in Archive.",
                code: "IOS_TRANSCRIBE_SUCCESS",
                params: ["wordCount": "\(result.segments.count)"],
                createdAt: transcribingMsg.createdAt)
        } else {
            let statusText: String
            let statusCode: String
            var statusParams: [String: String]? = nil
            switch transcriber.state {
            case .noSpeech:
                statusText = "No clear audio detected in video."
                statusCode = "IOS_TRANSCRIBE_NO_SPEECH"
            case .failed(let reason):
                statusText = "Transcription failed: \(reason)"
                statusCode = "IOS_TRANSCRIBE_FAILED"
                statusParams = ["reason": reason]
            default:
                statusText = "Transcription did not produce results."
                statusCode = "IOS_TRANSCRIBE_EMPTY"
            }
            updateTranscriptionBubble(
                id: transcribingMsg.id, assetId: assetId,
                text: statusText,
                code: statusCode,
                params: statusParams,
                createdAt: transcribingMsg.createdAt)
        }
    }

    /// Replace the content of a transcription status bubble.
    func updateTranscriptionBubble(
        id: String,
        assetId: String,
        text: String,
        code: String? = nil,
        params: [String: String]? = nil,
        createdAt: String?
    ) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx] = ChatMessage(
                id: id, userId: nil, assetId: assetId,
                direction: .incoming, messageType: .text,
                content: MessageContent(
                    text: text,
                    code: code,
                    params: params,
                    fallbackText: code == nil ? nil : text,
                    schemaVersion: code == nil ? nil : MessageCatalog.schemaVersion
                ),
                createdAt: createdAt
            )
        }
    }

    /// Clean up the temporary video file after upload + transcription.
    func cleanupTempFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Cancel Form (skip details → archive)

    /// User chose to skip the form. Archive the conversation immediately.
    /// PendingForm stays on disk so the form can be reopened later from Archive.
    /// Video continues uploading in background.
    func cancelForm() {
        if awaitingGroupedFormForBatch {
            showFormSheet = false
            form.submitError = nil
            resetBatchState(clearDisk: true)
            return
        }

        showFormSheet = false
        isArchived = true

        // Add a chat bubble confirming the skip
        let msg = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: currentAssetId,
            direction: .incoming,
            messageType: .systemNote,
            content: MessageContent(
                text:
                    "No worries. Your video is still uploading. You can add details from your Archive anytime.",
                code: "IOS_FORM_SKIPPED",
                fallbackText:
                    "No worries. Your video is still uploading. You can add details from your Archive anytime.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(msg, source: .workflow)
    }

    // MARK: - Submit Form

    func submitForm(assetId: String, formData: [String: String]) async {
        do {
            try await formSubmissionService.submitForm(assetId: assetId, formData: formData, auth: auth)

            // Form sheet closes — server will push form:confirmed via WS
            // with the "High Five!" confirmation bubble + metadata
            form.submitError = nil
            showFormSheet = false
            PendingForm.clear()
            clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
        } catch {
            AppLog.chat.error("Failed to submit form: \(error.localizedDescription)")
            // Keep form open so user can retry — show error in chat too
            form.submitError = "Failed to send form. Please try again."
            if connectivityIssues.isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(
                    operation: "submitting form details", assetId: assetId)
            } else {
                appendErrorBubble(
                    "Form submission failed. The form is still open. Please retry.",
                    assetId: assetId,
                    code: "IOS_FORM_SUBMIT_FAILED"
                )
            }
            Task {
                await reportError(
                    category: "form",
                    message: "Form submission failed: \(error.localizedDescription)",
                    severity: "ERROR",
                    assetId: assetId
                )
            }
        }
    }
}
