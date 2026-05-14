// May 13, 2026 - 11:59pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
protocol WebSocketFormConfirmedEventRuntime: AnyObject {
    func wsShouldSuppressMutation(assetId: String?, event: String) -> Bool
    func wsClearBlockingConnectivityIssue(assetId: String?)
    func wsRegisterActiveAsset(assetId: String?)
    func wsParseStringParams(_ value: Any?) -> [String: String]?
    func wsPromoteFormConfirmedStage(assetId: String?) -> WorkflowStage
    func wsIsBatchAssetId(assetId: String?) -> Bool
    func wsUpdateBatchClipMetadata(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        formSlug: String?
    )
    func wsSetBatchClipPhase(assetId: String?, phase: VideoBubblePhase)
    func wsHasWorkflowMessage(code: String, assetId: String?, mediasourceId: String?) -> Bool
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
    )
}

@MainActor
final class WebSocketFormConfirmedEventService {
    func handle(data: [String: Any], runtime: WebSocketFormConfirmedEventRuntime) {
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
