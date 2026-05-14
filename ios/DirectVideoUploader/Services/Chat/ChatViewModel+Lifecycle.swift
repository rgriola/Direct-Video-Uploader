// May 14, 2026 - 11:00am - GitHub Copilot (Claude Opus 4.7)
//
// Extension extracted from ChatViewModel.swift during P8 file decomposition.

import Foundation
import UIKit
import Observation

extension ChatViewModel {

    // MARK: - Connect

    func connectWebSocket() {
        guard let token = auth.token else { return }
        workflowStageTracker.reset()
        messagePolicy.resetForFreshConnection()
        connectivityIssues.reset()
        // Fresh conversation — clear old messages
        messages.removeAll()
        batchBubbleAnchorMessageId = nil
        batchClipDisplayByAssetId.removeAll()
        // Tear down any existing connection/reconnect loop before connecting with fresh token
        ws.disconnect()
        ws.connect(token: token)
    }

    func disconnectWebSocket() {
        ws.disconnect()
    }

    // MARK: - Fetch Asset Detail

    func fetchAssetDetail(
        assetId: String,
        presentErrorsInChat: Bool = true,
        reason: String = "manual"
    ) async {
        await assetDetailSyncService.sync(
            assetId: assetId,
            presentErrorsInChat: presentErrorsInChat,
            reason: reason,
            host: self
        )
    }

    func metadataThumbnail(for assetId: String?) -> UIImage? {
        guard let assetId, !assetId.isEmpty else {
            return form.thumbnail
        }
        return sentUploadsByAssetId[assetId]?.thumbnail ?? form.thumbnail
    }

    func showMetadata(for assetId: String? = nil) {
        let targetAssetId = assetId ?? currentAssetId ?? archive.assetId

        if let targetAssetId,
            let cachedAsset = assetDetailCache[targetAssetId]
        {
            lastAsset = cachedAsset
            lastClip = cachedAsset.clips?.first
            metadataSheetThumbnail = metadataThumbnail(for: targetAssetId)
            guard lastClip != nil else { return }
            showMetadataSheet = true
            return
        }

        if let targetAssetId {
            metadataSheetThumbnail = metadataThumbnail(for: targetAssetId)
            Task { @MainActor in
                await fetchAssetDetail(assetId: targetAssetId)
                metadataSheetThumbnail = metadataThumbnail(for: targetAssetId)
                showMetadataSheet = lastClip != nil
            }
            return
        }

        guard lastClip != nil else { return }
        metadataSheetThumbnail = form.thumbnail
        showMetadataSheet = true
    }

    // MARK: - Pending Form Recovery

    /// Check for a form that was pending when app was killed.
    func checkPendingForm() {
        guard let pendingForm = PendingForm.load() else { return }

        AppLog.chat.info("[Recovery] Found pending form for asset: \(pendingForm.assetId)")

        Task {
            do {
                let recoveryDecision = try await pendingFormRecovery.evaluate(
                    auth: auth,
                    pendingForm: pendingForm
                )

                switch recoveryDecision {
                case .clear:
                    AppLog.chat.info(
                        "[Recovery] Form already submitted for \(pendingForm.assetId) — clearing"
                    )
                    PendingForm.clear()

                case .restore:
                    AppLog.chat.info("[Recovery] Restoring pending form for \(pendingForm.assetId)")
                    restoreFormFromPending(pendingForm)
                }
            } catch {
                AppLog.chat.warning("[Recovery] Could not check pending form: \(error.localizedDescription)")
            }
        }
    }

    /// Restore form UI from persisted PendingForm state.
    func restoreFormFromPending(_ pendingForm: PendingForm) {
        currentAssetId = pendingForm.assetId
        chatOwnership.registerActiveAsset(pendingForm.assetId)
        form.originalFileName = pendingForm.originalFileName
        form.capturedAt = pendingForm.capturedAt
        form.clipCount = pendingForm.clipCount
        form.duration = pendingForm.duration
        if let jpegData = pendingForm.thumbnailJPEG {
            form.thumbnail = UIImage(data: jpegData)
        }
        formFields = buildFormFields()
        showFormSheet = true

        // Reconcile immediately after restoring pending form so relaunches after
        // force-quit can catch up missed state changes without waiting for another reconnect.
        Task { @MainActor in
            await reconcileActiveWorkflowStateAfterReconnect()
        }
    }

    /// Build the standard form fields (used for both live and recovery).
    func buildFormFields() -> [FormField] {
        FormField.defaultVideoFields()
    }

    func applyConversationResetScalars(_ scalarReset: ConversationResetScalars) {
        currentAssetId = scalarReset.currentAssetId
        isArchived = scalarReset.isArchived
        archive = scalarReset.archive
        form = scalarReset.form
        lastAsset = scalarReset.lastAsset
        lastClip = scalarReset.lastClip
        stagedVideo = scalarReset.stagedVideo
        isUploading = scalarReset.isUploading
        uploadProgress = scalarReset.uploadProgress
        showFormSheet = scalarReset.showFormSheet
        showMetadataSheet = scalarReset.showMetadataSheet
        metadataSheetThumbnail = scalarReset.metadataSheetThumbnail
        showSlackShareSheet = scalarReset.showSlackShareSheet
        lastStagedCreatedDate = scalarReset.lastStagedCreatedDate
        lastStagedHasLocation = scalarReset.lastStagedHasLocation
    }

    func applyConversationResetCollections(_ collectionReset: ConversationResetCollections) {
        sentUploads = collectionReset.sentUploads
        batchClipDisplayByAssetId = collectionReset.batchClipDisplayByAssetId
        sentUploadsByAssetId = collectionReset.sentUploadsByAssetId
        slackThumbnails = collectionReset.slackThumbnails
        slackConfirmedIds = collectionReset.slackConfirmedIds
        assetDetailCache = collectionReset.assetDetailCache
    }

    // MARK: - Archive / New Conversation

    /// Clear current conversation and start fresh for a new upload.
    func startNewConversation() {
        chatOwnership.archiveCurrentOwnership(
            currentAssetId: currentAssetId,
            batchAssetIds: batchItems.map(\.assetId)
        )
        resetBatchState(clearDisk: true)
        workflowStageTracker.reset()
        messagePolicy.resetForNewConversation()
        connectivityIssues.reset()
        messages.removeAll()

        let scalarReset = conversationResetService.makeScalarReset()
        applyConversationResetScalars(scalarReset)

        let collectionReset = conversationResetService.makeCollectionReset()
        applyConversationResetCollections(collectionReset)

        // Re-send greeting for the fresh conversation
        let firstName = auth.currentUser?.name.components(separatedBy: " ").first ?? "there"
        let greeting = conversationResetService.makeNewConversationGreeting(firstName: firstName)
        appendMessage(greeting, source: .workflow)
    }

    /// Send a Slack share for the archived asset.
    func shareToSlack(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let archiveAssetId = archive.assetId, !archiveAssetId.isEmpty else {
            appendErrorBubble(
                "Upload a video first and I can grab the metadata so you can Slack it. Previous uploads are in your Archive, and you can Slack from there.",
                code: "IOS_SLACK_REQUIRES_UPLOAD"
            )
            return
        }

        // Optimistic UI — add Slack post message locally
        let localMessage = ChatMessage(
            id: UUID().uuidString,
            userId: auth.currentUser?.id,
            assetId: archiveAssetId,
            direction: .outgoing,
            messageType: .slackPost,
            content: MessageContent(text: text),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(localMessage, source: .outgoing)
        showSlackShareSheet = false

        // Send via WebSocket — server detects #channel/@mention pattern
        ws.sendMessage(text: text, assetId: archiveAssetId, assetIds: activeSlackTargetAssetIds())
    }

    /// Download a thumbnail image and cache it for the Slack bubble.
    func downloadSlackThumbnail(url: URL, messageId: String) {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    self.slackThumbnails[messageId] = image
                }
            } catch {
                AppLog.chat.warning("Failed to download Slack thumbnail: \(error.localizedDescription)")
            }
        }
    }
}
