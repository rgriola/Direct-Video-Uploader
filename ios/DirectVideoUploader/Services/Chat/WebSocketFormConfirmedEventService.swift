// May 14, 2026 - 3:10pm - GitHub Copilot (Claude Opus 4.7)
// Runtime protocol consolidated into Services/Chat/WebSocketEventRuntime.swift (Priority 5).
import Foundation

@MainActor
final class WebSocketFormConfirmedEventService {
    func handle(data: [String: Any], runtime: WebSocketEventRuntime) {
        let assetId = data["assetId"] as? String

        runtime.wsClearBlockingConnectivityIssue(assetId: assetId)

        if runtime.wsShouldSuppressMutation(assetId: assetId, event: "form:confirmed") {
            return
        }

        runtime.wsRegisterActiveAsset(assetId: assetId)

        let fallbackText =
            data["messageFallbackText"] as? String
            ?? data["message"] as? String
            ?? "High five. Form received."
        let messageCode = data["messageCode"] as? String ?? "WS_FORM_CONFIRMED"
        let messageParams = runtime.wsParseStringParams(data["messageParams"])
        let messageSchemaVersion =
            data["messageSchemaVersion"] as? Int ?? MessageCatalog.schemaVersion
        let mediasourceId = data["mediasourceId"] as? String
        let mediasourceUrl = data["mediasourceUrl"] as? String
        let originalFileName = data["originalFileName"] as? String
        let capturedAt = data["capturedAt"] as? String
        let formSlug = (data["formSlug"] as? String) ?? (data["slug"] as? String)

        let previousStage = runtime.wsPromoteFormConfirmedStage(assetId: assetId)

        if runtime.wsIsBatchAssetId(assetId: assetId) {
            runtime.wsUpdateBatchClipMetadata(
                assetId: assetId,
                mediasourceId: mediasourceId,
                mediasourceUrl: mediasourceUrl,
                formSlug: formSlug
            )
            runtime.wsSetBatchClipPhase(assetId: assetId, phase: .processing)
            return
        }

        let hasExistingFormConfirmation = runtime.wsHasWorkflowMessage(
            code: messageCode,
            assetId: assetId,
            mediasourceId: mediasourceId
        )

        if previousStage != .failed,
            previousStage.rawValue >= WorkflowStage.formConfirmed.rawValue,
            hasExistingFormConfirmation
        {
            return
        }

        runtime.wsEnsureFormConfirmedMessage(
            assetId: assetId,
            mediasourceId: mediasourceId,
            mediasourceUrl: mediasourceUrl,
            originalFileName: originalFileName,
            capturedAt: capturedAt,
            fallbackText: fallbackText,
            code: messageCode,
            params: messageParams,
            schemaVersion: messageSchemaVersion
        )
    }
}
