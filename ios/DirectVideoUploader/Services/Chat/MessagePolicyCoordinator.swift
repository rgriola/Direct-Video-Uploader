// May 10, 2026 - 11:27am - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
final class MessagePolicyCoordinator {
     enum Source {
          case websocket
          case workflow
          case error
          case outgoing
     }

     private let sessionSingletonCodes: Set<String> = [
          "WS_GREETING_CONNECTED",
          "WS_SYSTEM_TIP_GUIDE",
     ]

     private let assetSingletonCodes: Set<String> = [
          "WS_FORM_CONFIRMED",
          "IOS_MUX_READY_SUMMARY",
          "IOS_MUX_READY_FOLLOWUP",
     ]

     private var seenMessageIds: Set<String> = []
     private var seenSessionKeys: Set<String> = []
     private var seenAssetKeys: Set<String> = []
     private var seenErrorKeys: Set<String> = []

     func shouldPresent(_ message: ChatMessage, source: Source) -> Bool {
          if !message.id.isEmpty {
               if seenMessageIds.contains(message.id) {
                    return false
               }
               seenMessageIds.insert(message.id)
          }

          switch source {
          case .outgoing:
               return true

          case .error:
               let key = errorKey(for: message)
               if seenErrorKeys.contains(key) {
                    return false
               }
               seenErrorKeys.insert(key)
               return true

          case .websocket, .workflow:
               guard let code = message.content.code, !code.isEmpty else {
                    return true
               }

               if sessionSingletonCodes.contains(code) {
                    if seenSessionKeys.contains(code) {
                         return false
                    }
                    seenSessionKeys.insert(code)
                    return true
               }

               if assetSingletonCodes.contains(code) {
                    let key = assetKey(code: code, message: message)
                    if seenAssetKeys.contains(key) {
                         return false
                    }
                    seenAssetKeys.insert(key)
                    return true
               }

               return true
          }
     }

     func resetForFreshConnection() {
          seenMessageIds.removeAll()
          seenSessionKeys.removeAll()
          seenAssetKeys.removeAll()
          seenErrorKeys.removeAll()
     }

     func resetForNewConversation() {
          seenMessageIds.removeAll()
          seenAssetKeys.removeAll()
          seenErrorKeys.removeAll()
     }

     func resetAssetScope(assetId: String?) {
          guard let assetId, !assetId.isEmpty else { return }

          seenAssetKeys = Set(seenAssetKeys.filter { !$0.hasSuffix("|\(assetId)") })
          seenErrorKeys = Set(
               seenErrorKeys.filter { key in
                    let parts = key.split(
                         separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
                    guard parts.count >= 2 else { return true }
                    return String(parts[1]) != assetId
               })
     }

     private func assetKey(code: String, message: ChatMessage) -> String {
          let assetScope = message.assetId ?? message.content.mediasourceId ?? "global"
          return "\(code)|\(assetScope)"
     }

     private func errorKey(for message: ChatMessage) -> String {
          let code = message.content.code ?? "NO_CODE"
          let asset = message.assetId ?? "global"
          let params = normalizedParams(message.content.params)
          let text = message.content.fallbackText ?? message.content.text ?? ""
          return "\(code)|\(asset)|\(params)|\(text)"
     }

     private func normalizedParams(_ params: [String: String]?) -> String {
          guard let params, !params.isEmpty else {
               return ""
          }

          return params.keys.sorted().map { key in
               let value = params[key] ?? ""
               return "\(key)=\(value)"
          }.joined(separator: "&")
     }
}
