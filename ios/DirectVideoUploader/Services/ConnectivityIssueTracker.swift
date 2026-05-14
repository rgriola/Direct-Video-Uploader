// May 13, 2026 - 4:39pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class ConnectivityIssueTracker {
    private var hasBlockingIssue = false
    private var blockingAssetId: String?

    func reset() {
        hasBlockingIssue = false
        blockingAssetId = nil
    }

    func isConnectivityIssue(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .notConnectedToInternet,
                .networkConnectionLost,
                .timedOut,
                .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed,
                .resourceUnavailable,
                .internationalRoamingOff,
                .callIsActive,
                .dataNotAllowed,
                .secureConnectionFailed:
                return true
            default:
                break
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                .networkConnectionLost,
                .timedOut,
                .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed,
                .resourceUnavailable,
                .internationalRoamingOff,
                .callIsActive,
                .dataNotAllowed,
                .secureConnectionFailed:
                return true
            default:
                break
            }
        }

        return false
    }

    func noteBlockingIssue(operation: String, assetId: String?) -> ChatMessage? {
        guard !hasBlockingIssue else { return nil }

        hasBlockingIssue = true
        blockingAssetId = assetId

        return ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text:
                    "Connection interrupted while \(operation). Upload and metadata sync are paused until reconnection.",
                code: "IOS_CONNECTIVITY_BLOCKING",
                params: ["operation": operation],
                fallbackText:
                    "Connection interrupted while \(operation). Upload and metadata sync are paused until reconnection.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
    }

    func clearBlockingIssueIfNeeded(assetId: String?) -> ChatMessage? {
        guard hasBlockingIssue else { return nil }

        hasBlockingIssue = false
        let recoveredAssetId = assetId ?? blockingAssetId
        blockingAssetId = nil

        return ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: recoveredAssetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: "Connection restored. Upload and metadata sync resumed.",
                code: "IOS_CONNECTIVITY_RECOVERED",
                fallbackText: "Connection restored. Upload and metadata sync resumed.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
    }
}
