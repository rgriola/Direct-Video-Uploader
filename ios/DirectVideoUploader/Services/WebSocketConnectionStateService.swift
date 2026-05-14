// May 13, 2026 - 11:59pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

@MainActor
protocol WebSocketConnectionStateRuntime: AnyObject {
    func wsShouldWarnReconnectAttempt(attempt: Int, threshold: Int) -> Bool
    func wsReconcileActiveWorkflowStateAfterReconnect() async
    func wsReportWebSocketReconnecting(attempt: Int, maxAttempts: Int) async
    func wsReportWebSocketConnectionLost() async
}

@MainActor
final class WebSocketConnectionStateService {
    func handleConnected(runtime: WebSocketConnectionStateRuntime) {
        Task { @MainActor in
            await runtime.wsReconcileActiveWorkflowStateAfterReconnect()
        }
    }

    func handleReconnecting(
        attempt: Int,
        maxAttempts: Int,
        warningThreshold: Int,
        runtime: WebSocketConnectionStateRuntime
    ) {
        guard runtime.wsShouldWarnReconnectAttempt(attempt: attempt, threshold: warningThreshold)
        else {
            return
        }

        Task { @MainActor in
            await runtime.wsReportWebSocketReconnecting(
                attempt: attempt,
                maxAttempts: maxAttempts
            )
        }
    }

    func handleConnectionLost(runtime: WebSocketConnectionStateRuntime) {
        Task { @MainActor in
            await runtime.wsReportWebSocketConnectionLost()
        }
    }
}
