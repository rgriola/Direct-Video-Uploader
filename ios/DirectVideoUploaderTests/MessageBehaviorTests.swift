import Testing
@testable import DirectVideoUploader

struct MessageCatalogTests {
    @Test
    func knownCodesRenderParametersBeforeFallbackText() {
        let content = MessageContent(
            text: "Text", code: "IOS_UPLOAD_FAILED", params: ["reason": "Offline"],
            fallbackText: "Fallback")

        #expect(MessageCatalog.resolve(content: content) == "Upload failed: Offline")
        #expect(MessageCatalog.resolve(code: "UNKNOWN", params: [:]) == nil)
    }

    @Test
    func unknownCodesUseFallbackThenTextThenFileName() {
        #expect(
            MessageCatalog.resolve(
                content: MessageContent(
                    text: "Text", code: "UNKNOWN", fallbackText: "Fallback",
                    fileName: "clip.mov")) == "Fallback"
        )
        #expect(
            MessageCatalog.resolve(
                content: MessageContent(text: "Text", code: "UNKNOWN", fileName: "clip.mov"))
                == "Text"
        )
        #expect(MessageCatalog.resolve(content: MessageContent(fileName: "clip.mov")) == "clip.mov")
        #expect(MessageCatalog.resolve(content: MessageContent()) == "...")
    }

    @Test
    func followupCopyIsStableForTheSameMessage() {
        let message = ChatMessage(
            id: "message-1",
            userId: "user-1",
            assetId: "asset-1",
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                code: "IOS_MUX_READY_FOLLOWUP", params: ["firstName": "Reporter"]),
            createdAt: "2026-05-10T01:02:03.000Z")

        let initial = message.displayText
        #expect(initial.contains("Reporter"))
        for _ in 0..<20 {
            #expect(message.displayText == initial)
        }
    }
}

@MainActor
struct MessagePolicyTests {
    private func message(
        id: String,
        code: String? = nil,
        assetId: String? = nil,
        params: [String: String]? = nil,
        fallbackText: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            userId: "user-1",
            assetId: assetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(code: code, params: params, fallbackText: fallbackText),
            createdAt: nil)
    }

    @Test
    func messageIdsAreDeduplicatedAcrossSources() {
        let policy = MessagePolicyCoordinator()
        let first = message(id: "message-1")

        #expect(policy.shouldPresent(first, source: .workflow))
        #expect(!policy.shouldPresent(first, source: .websocket))
        #expect(policy.shouldPresent(message(id: "message-2"), source: .websocket))
    }

    @Test
    func sessionSingletonSurvivesNewConversationButResetsOnReconnect() {
        let policy = MessagePolicyCoordinator()

        #expect(
            policy.shouldPresent(
                message(id: "message-1", code: "WS_GREETING_CONNECTED"), source: .websocket)
        )
        policy.resetForNewConversation()
        #expect(
            !policy.shouldPresent(
                message(id: "message-2", code: "WS_GREETING_CONNECTED"), source: .websocket)
        )
        policy.resetForFreshConnection()
        #expect(
            policy.shouldPresent(
                message(id: "message-3", code: "WS_GREETING_CONNECTED"), source: .websocket)
        )
    }

    @Test
    func assetSingletonsAreScopedAndResetIndependently() {
        let policy = MessagePolicyCoordinator()
        let code = "WS_FORM_CONFIRMED"

        #expect(
            policy.shouldPresent(
                message(id: "message-1", code: code, assetId: "asset-1"), source: .workflow)
        )
        #expect(
            !policy.shouldPresent(
                message(id: "message-2", code: code, assetId: "asset-1"), source: .websocket)
        )
        #expect(
            policy.shouldPresent(
                message(id: "message-3", code: code, assetId: "asset-2"), source: .websocket)
        )

        policy.resetAssetScope(assetId: "asset-1")
        #expect(
            policy.shouldPresent(
                message(id: "message-4", code: code, assetId: "asset-1"), source: .workflow)
        )
        #expect(
            !policy.shouldPresent(
                message(id: "message-5", code: code, assetId: "asset-2"), source: .workflow)
        )
    }

    @Test
    func errorsDeduplicateParametersAndResetPerAsset() {
        let policy = MessagePolicyCoordinator()
        let first = message(
            id: "error-1", code: "IOS_UPLOAD_FAILED", assetId: "asset-1",
            params: ["reason": "Offline", "operation": "upload"], fallbackText: "Failed")
        let reordered = message(
            id: "error-2", code: "IOS_UPLOAD_FAILED", assetId: "asset-1",
            params: ["operation": "upload", "reason": "Offline"], fallbackText: "Failed")
        let otherAsset = message(
            id: "error-3", code: "IOS_UPLOAD_FAILED", assetId: "asset-2",
            params: ["reason": "Offline", "operation": "upload"], fallbackText: "Failed")

        #expect(policy.shouldPresent(first, source: .error))
        #expect(!policy.shouldPresent(reordered, source: .error))
        #expect(policy.shouldPresent(otherAsset, source: .error))

        policy.resetAssetScope(assetId: "asset-1")
        #expect(
            policy.shouldPresent(
                message(
                    id: "error-4", code: "IOS_UPLOAD_FAILED", assetId: "asset-1",
                    params: ["reason": "Offline", "operation": "upload"], fallbackText: "Failed"),
                source: .error)
        )
        #expect(
            !policy.shouldPresent(
                message(
                    id: "error-5", code: "IOS_UPLOAD_FAILED", assetId: "asset-2",
                    params: ["reason": "Offline", "operation": "upload"], fallbackText: "Failed"),
                source: .error)
        )
    }
}
