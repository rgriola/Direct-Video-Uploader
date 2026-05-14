// May 14, 2026 - 11:00am - GitHub Copilot (Claude Opus 4.7)
//
// Extension extracted from ChatViewModel.swift during P8 file decomposition.

import Foundation
import UIKit
import Observation

extension ChatViewModel {

    // MARK: - Error Helpers

    func noteBlockingConnectivityIssue(operation: String, assetId: String?) {
        guard
            let connectivityMessage = connectivityIssues.noteBlockingIssue(
                operation: operation,
                assetId: assetId
            )
        else { return }

        appendMessage(connectivityMessage, source: .workflow)
    }

    func clearBlockingConnectivityIssueIfNeeded(assetId: String?) {
        guard
            let recoveredMessage = connectivityIssues.clearBlockingIssueIfNeeded(assetId: assetId)
        else { return }

        appendMessage(recoveredMessage, source: .workflow)
    }

    func debugLogChatOwnership(_ message: String) {
        #if DEBUG
            AppLog.chat.debug("\(message)")
        #endif
    }

    func promoteWorkflowStage(for assetId: String?, to stage: WorkflowStage) -> WorkflowStage {
        let previous = workflowStageTracker.promote(assetId: assetId, to: stage)

        if stage == .failed,
            previous != .failed,
            let assetId,
            !assetId.isEmpty
        {
            messagePolicy.resetAssetScope(assetId: assetId)
        }

        return previous
    }

    func wsShouldSuppressMutation(assetId: String?, event: String) -> Bool {
        shouldSuppressMutation(assetId: assetId, event: event)
    }

    func wsShouldWarnReconnectAttempt(attempt: Int, threshold: Int) -> Bool {
        attempt >= threshold
    }

    func wsReconcileActiveWorkflowStateAfterReconnect() async {
        await reconcileActiveWorkflowStateAfterReconnect()
    }

    func wsReportWebSocketReconnecting(attempt: Int, maxAttempts: Int) async {
        await reportError(
            category: "websocket",
            message: "WebSocket reconnecting (attempt \(attempt)/\(maxAttempts))",
            severity: "WARNING"
        )
    }

    func wsReportWebSocketConnectionLost() async {
        await reportError(
            category: "websocket",
            message: "WebSocket max reconnect attempts exhausted — connection lost",
            severity: "CRITICAL"
        )
    }

    func wsClearBlockingConnectivityIssue(assetId: String?) {
        clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
    }

    func wsRegisterActiveAsset(assetId: String?) {
        chatOwnership.registerActiveAsset(assetId)
    }

    func wsSetCurrentAssetId(_ assetId: String?) {
        currentAssetId = assetId
    }

    func wsPromoteFormRequestedStage(assetId: String) {
        _ = promoteWorkflowStage(for: assetId, to: .formRequested)
    }

    func wsSetFormContext(
        originalFileName: String?,
        clipCount: Int?,
        duration: Int?,
        capturedAt: String?
    ) {
        form.originalFileName = originalFileName
        form.clipCount = clipCount
        form.duration = duration
        form.capturedAt = capturedAt
    }

    func wsLogSuppressedFormRequest(assetId: String) {
        groupedFormService.logSubmitDebug(assetId: assetId, event: .suppressedFormRequest)
    }

    func wsHideFormSheet() {
        showFormSheet = false
    }

    func wsShowFormSheet() {
        formFields = buildFormFields()
        showFormSheet = true
    }

    func wsSavePendingForm(_ pendingForm: PendingForm) {
        PendingForm.save(pendingForm)
    }

    func wsMakeFormThumbnailJPEGData() -> Data? {
        form.thumbnail?.jpegData(compressionQuality: 0.5)
    }

    func wsParseStringParams(_ value: Any?) -> [String: String]? {
        parseStringParams(value)
    }

    func wsPromoteFormConfirmedStage(assetId: String?) -> WorkflowStage {
        promoteWorkflowStage(for: assetId, to: .formConfirmed)
    }

    func wsIsBatchAssetId(assetId: String?) -> Bool {
        isBatchAssetId(assetId)
    }

    func wsUpdateBatchClipMetadata(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    ) {
        updateBatchClipMetadata(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            formSlug: formSlug
        )
    }

    func wsSetBatchClipPhase(assetId: String?, phase: VideoBubblePhase) {
        setBatchClipPhase(assetId: assetId, phase: phase)
    }

    func wsMarkLatestOutgoingSlackAsConfirmed() {
        if let outId = messages.last(where: {
            $0.messageType == .slackPost && $0.direction == .outgoing
                && !slackConfirmedIds.contains($0.id)
        })?.id {
            slackConfirmedIds.insert(outId)
        }
    }

    func wsAppendWebSocketMessage(_ message: ChatMessage) {
        appendMessage(message, source: .websocket)
    }

    func wsDownloadSlackThumbnail(url: URL, messageId: String) {
        downloadSlackThumbnail(url: url, messageId: messageId)
    }

    func wsPromoteProcessingStage(assetId: String) {
        _ = promoteWorkflowStage(for: assetId, to: .processing)
    }

    func wsFetchAssetDetail(assetId: String) {
        // Fetch the full asset (with clips) so MetadataView can display it.
        Task { @MainActor in
            await fetchAssetDetail(assetId: assetId)
        }
    }

    func wsPromoteFailedStage(assetId: String?) {
        _ = promoteWorkflowStage(for: assetId, to: .failed)
    }

    func wsMarkBatchClipFailed(assetId: String?, reason: String) {
        markBatchClipFailed(assetId: assetId, reason: reason)
    }

    func wsAppendUploadFailedBubble(assetId: String?, reason: String) {
        appendErrorBubble(
            "Upload failed: \(reason)",
            assetId: assetId,
            code: "IOS_UPLOAD_FAILED",
            params: ["reason": reason]
        )
    }

    func wsHasWorkflowMessage(code: String, assetId: String?, mediasourceId: String?) -> Bool {
        hasWorkflowMessage(code: code, assetId: assetId, mediasourceId: mediasourceId)
    }

    func wsEnsureFormConfirmedMessage(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        capturedAt: String?,
        fallbackText: String?,
        code: String,
        params: [String: String]?,
        schemaVersion: Int?
    ) {
        ensureFormConfirmedMessage(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            originalFileName: originalFileName,
            capturedAt: capturedAt,
            fallbackText: fallbackText,
            code: code,
            params: params,
            schemaVersion: schemaVersion,
            source: .workflow
        )
    }

    func wsMarkBatchClipReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    ) {
        markBatchClipReady(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            formSlug: formSlug
        )
    }

    func wsEnsureFormConfirmedForReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?
    ) {
        ensureFormConfirmedMessage(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            originalFileName: originalFileName,
            capturedAt: nil,
            fallbackText: nil,
            source: .workflow
        )
    }

    func wsPromoteReadyStage(assetId: String?) -> WorkflowStage {
        promoteWorkflowStage(for: assetId, to: .ready)
    }

    func wsResetMessagePolicyAssetScope(assetId: String?) {
        messagePolicy.resetAssetScope(assetId: assetId)
    }

    func wsApplyReadyWorkflowState(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        formSlug: String?,
        duration: Int?,
        resolution: String?,
        fileSize: String?
    ) {
        applyReadyWorkflowState(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            originalFileName: originalFileName,
            formSlug: formSlug,
            duration: duration,
            resolution: resolution,
            fileSize: fileSize,
            source: .workflow
        )
    }

    func applyReadyWorkflowState(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        formSlug: String?,
        duration: Int?,
        resolution: String?,
        fileSize: String?,
        source: MessagePolicyCoordinator.Source
    ) {
        let hasSummary = hasWorkflowMessage(
            code: "IOS_MUX_READY_SUMMARY",
            assetId: assetId,
            mediasourceId: mediasourceId
        )
        let hasFollowup = hasWorkflowMessage(
            code: "IOS_MUX_READY_FOLLOWUP",
            assetId: assetId,
            mediasourceId: mediasourceId
        )

        let plan = readyWorkflowStateService.makePlan(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            originalFileName: originalFileName,
            formSlug: formSlug,
            duration: duration,
            resolution: resolution,
            fileSize: fileSize,
            hasSummary: hasSummary,
            hasFollowup: hasFollowup
        )

        archive.assetId = plan.archiveSnapshot.assetId
        archive.mediasourceId = plan.archiveSnapshot.mediasourceId
        archive.mediasourceUrl = plan.archiveSnapshot.mediasourceUrl
        archive.originalFileName = plan.archiveSnapshot.originalFileName
        archive.formSlug = plan.archiveSnapshot.formSlug
        archive.duration = plan.archiveSnapshot.duration
        archive.resolution = plan.archiveSnapshot.resolution
        archive.fileSize = plan.archiveSnapshot.fileSize
        isArchived = true

        if let summaryMessage = plan.summaryMessage {
            appendMessage(summaryMessage, source: source)
        }

        guard plan.shouldScheduleFollowup else { return }

        let firstName = auth.currentUser?.name.components(separatedBy: " ").first ?? "there"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))

            guard
                !self.hasWorkflowMessage(
                    code: "IOS_MUX_READY_FOLLOWUP",
                    assetId: assetId,
                    mediasourceId: mediasourceId
                )
            else {
                return
            }

            let followUp = self.readyWorkflowStateService.makeFollowupMessage(
                assetId: assetId,
                firstName: firstName
            )
            self.appendMessage(followUp, source: source)
        }
    }

    func activeSlackTargetAssetId() -> String? {
        if let currentAssetId, !currentAssetId.isEmpty {
            return currentAssetId
        }

        if isArchived,
            let archivedAssetId = archive.assetId,
            !archivedAssetId.isEmpty
        {
            return archivedAssetId
        }

        return nil
    }

    func activeSlackTargetAssetIds() -> [String]? {
        let ids =
            batchItems
            .filter { $0.status == .complete }
            .compactMap(\.assetId)

        guard ids.count > 1 else { return nil }

        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    func ensureFormConfirmedMessage(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        capturedAt: String?,
        fallbackText: String?,
        code: String = "WS_FORM_CONFIRMED",
        params: [String: String]? = nil,
        schemaVersion: Int? = nil,
        source: MessagePolicyCoordinator.Source
    ) {
        guard
            !hasWorkflowMessage(
                code: code,
                assetId: assetId,
                mediasourceId: mediasourceId
            )
        else {
            return
        }

        let resolvedFallback =
            fallbackText
            ?? MessageCatalog.resolve(code: code, params: params ?? [:])
            ?? "High five. I will text when the video is done. Metadata is ready, and you can Slack your team below."

        let confirmation = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .confirmation,
            content: MessageContent(
                text: resolvedFallback,
                code: code,
                params: params,
                fallbackText: resolvedFallback,
                schemaVersion: schemaVersion ?? MessageCatalog.schemaVersion,
                slug: nil,
                mediasourceId: mediasourceId,
                mediasourceUrl: mediasourceUrl,
                originalFileName: originalFileName,
                capturedAt: capturedAt
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(confirmation, source: source)
    }

    func appendReconciledFormConfirmed(
        asset: Asset,
        source: MessagePolicyCoordinator.Source = .workflow
    ) {
        guard asset.formResponse != nil else { return }

        let fallback =
            MessageCatalog.resolve(code: "WS_FORM_CONFIRMED", params: [:])
            ?? "High five. I will text when the video is done. Metadata is ready, and you can Slack your team below."

        ensureFormConfirmedMessage(
            assetId: asset.id,
            mediasourceId: asset.mediasourceId,
            mediasourceUrl: asset.mediasourceUrl,
            originalFileName: asset.originalFileName ?? asset.clips?.first?.originalFileName,
            capturedAt: asset.clips?.first?.capturedAt,
            fallbackText: fallback,
            source: source
        )
    }

    func reconcileWorkflowState(
        from asset: Asset,
        source: MessagePolicyCoordinator.Source = .workflow
    ) {
        let reconciledStage = WorkflowStageTracker.inferredStage(from: asset)
        let previousStage = promoteWorkflowStage(for: asset.id, to: reconciledStage)
        let isBatchAsset = isBatchAssetId(asset.id)

        var hasReadySummary = false
        var hasReadyFollowup = false
        let shouldCheckReadyMessages =
            !isBatchAsset
            && reconciledStage == .ready
            && previousStage != .failed
            && previousStage.rawValue >= WorkflowStage.ready.rawValue

        if shouldCheckReadyMessages {
            hasReadySummary = hasWorkflowMessage(
                code: "IOS_MUX_READY_SUMMARY",
                assetId: asset.id,
                mediasourceId: asset.mediasourceId
            )
            hasReadyFollowup = hasWorkflowMessage(
                code: "IOS_MUX_READY_FOLLOWUP",
                assetId: asset.id,
                mediasourceId: asset.mediasourceId
            )
        }

        let plan = workflowReconcilePlanService.makePlan(
            asset: asset,
            reconciledStage: reconciledStage,
            previousStage: previousStage,
            isBatchAsset: isBatchAsset,
            hasReadySummary: hasReadySummary,
            hasReadyFollowup: hasReadyFollowup
        )

        workflowReconcileExecutionService.execute(
            asset: asset,
            plan: plan,
            isBatchAsset: isBatchAsset,
            source: source,
            host: self
        )
    }

    func hasWorkflowMessage(
        code: String,
        assetId: String?,
        mediasourceId: String?
    ) -> Bool {
        messages.contains { message in
            guard message.content.code == code else { return false }

            if let assetId, !assetId.isEmpty,
                message.assetId == assetId
            {
                return true
            }

            if let mediasourceId, !mediasourceId.isEmpty,
                message.content.mediasourceId == mediasourceId
            {
                return true
            }

            return false
        }
    }

    func batchClipDisplayState(for assetId: String?) -> BatchClipDisplayState? {
        batchClipDisplayService.displayState(
            for: assetId,
            states: batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    func isBatchAssetId(_ assetId: String?) -> Bool {
        batchClipDisplayService.isBatchAssetId(
            assetId,
            states: batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    func phaseForBatchItemStatus(_ status: VideoBatchItemStatus) -> VideoBubblePhase {
        batchClipDisplayService.phase(for: status)
    }

    func setBatchClipPhase(assetId: String?, phase: VideoBubblePhase) {
        batchClipDisplayService.setPhase(
            assetId: assetId,
            phase: phase,
            states: &batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    func updateBatchClipProgress(assetId: String?, progress: Double) {
        batchClipDisplayService.updateProgress(
            assetId: assetId,
            progress: progress,
            states: &batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    func updateBatchClipMetadata(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    ) {
        batchClipDisplayService.updateMetadata(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            formSlug: formSlug,
            states: &batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    func markBatchClipReady(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    ) {
        batchClipDisplayService.markReady(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            formSlug: formSlug,
            states: &batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    func markBatchClipFailed(assetId: String?, reason: String) {
        guard let assetId, !assetId.isEmpty else { return }

        markBatchItemFailedByAssetId(assetId: assetId, message: reason)
        batchClipDisplayService.markFailedDisplay(
            assetId: assetId,
            reason: reason,
            states: &batchClipDisplayByAssetId,
            batchItems: batchItems
        )
    }

    func markBatchItemFailedByAssetId(assetId: String, message: String) {
        guard let index = batchItems.firstIndex(where: { $0.assetId == assetId }) else {
            return
        }

        markBatchItemFailedAtIndex(index: index, message: message)

        if batchState != .partialFailed {
            batchState = .partialFailed
            persistBatchState()
        }
    }

    func reconcileActiveWorkflowStateAfterReconnect() async {
        guard auth.isAuthenticated else { return }
        guard let assetId = currentAssetId ?? archive.assetId else { return }

        do {
            let result = try await assetDetailService.fetchAssetDetail(auth: auth, assetId: assetId)
            guard result.statusCode == 200, let asset = result.asset else { return }
            lastAsset = asset
            lastClip = asset.clips?.first
            assetDetailCache[asset.id] = asset

            clearBlockingConnectivityIssueIfNeeded(assetId: asset.id)
            reconcileWorkflowState(from: asset, source: .workflow)
        } catch {
            if connectivityIssues.isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(operation: "syncing workflow state", assetId: assetId)
            }
            AppLog.workflow.warning("[Reconnect] State reconcile skipped: \(error.localizedDescription)")
        }
    }

    /// Central append gate for progressive messaging and dedupe policy.
    func appendMessage(_ message: ChatMessage, source: MessagePolicyCoordinator.Source) {
        let shouldDebugCode = {
            guard let code = message.content.code else { return false }
            return code == "WS_FORM_CONFIRMED"
                || code == "IOS_MUX_READY_SUMMARY"
                || code == "IOS_MUX_READY_FOLLOWUP"
        }()

        guard messagePolicy.shouldPresent(message, source: source) else {
            if shouldDebugCode {
                let identity = message.assetId ?? message.content.mediasourceId ?? "n/a"
                AppLog.chat.warning(
                    "[Chat] Dropped message by policy: code=\(message.content.code ?? "n/a") source=\(String(describing: source)) target=\(identity)"
                )
            }
            return
        }

        messages.append(message)

        if hasActiveBatch && batchBubbleAnchorMessageId == nil {
            batchBubbleAnchorMessageId = message.id
        }

        if shouldDebugCode {
            let identity = message.assetId ?? message.content.mediasourceId ?? "n/a"
            AppLog.chat.debug(
                "[Chat] Appended message: code=\(message.content.code ?? "n/a") source=\(String(describing: source)) target=\(identity) total=\(self.messages.count)"
            )
        }
    }

    /// Show an error message to the user as a chat bubble.
    func appendErrorBubble(
        _ text: String,
        assetId: String? = nil,
        code: String? = nil,
        params: [String: String]? = nil
    ) {
        let errorMsg = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: text,
                code: code,
                params: params,
                fallbackText: code == nil ? nil : text,
                schemaVersion: code == nil ? nil : MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(errorMsg, source: .error)
    }

    /// Report an error to the server's error_logs table (best-effort, fire-and-forget).
    /// Future: server will send text/email for CRITICAL errors.
    func reportError(
        category: String,
        message: String,
        severity: String = "WARNING",
        assetId: String? = nil,
        details: [String: String]? = nil
    ) async {
        await serverErrorReporter.report(
            auth: auth,
            category: category,
            message: message,
            severity: severity,
            assetId: assetId,
            details: details
        )
    }
}
