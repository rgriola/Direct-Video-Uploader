// May 14, 2026 - 11:00am - GitHub Copilot (Claude Opus 4.7)
//
// Extension extracted from ChatViewModel.swift during P8 file decomposition.

import Foundation
import UIKit
import Observation

extension ChatViewModel {

    // MARK: - WebSocket Handlers

    func setupWebSocketHandlers() {
        registerOnMessageHandler()
        registerOnUploadCompleteHandler()
        registerOnFormRequestHandler()
        registerOnFormConfirmedHandler()
        registerOnStreamReadyHandler()
        registerOnStreamErroredHandler()
    }

    func shouldSuppressMutation(assetId: String?, event: String) -> Bool {
        chatOwnership.shouldSuppressChatMutation(
            for: assetId,
            currentAssetId: currentAssetId,
            hasActiveBatch: hasActiveBatch,
            isBatchAssetId: { self.isBatchAssetId($0) },
            event: event,
            log: { self.debugLogChatOwnership($0) }
        )
    }

    func registerOnMessageHandler() {
        ws.onMessage = { [weak self] message in
            guard let self else { return }

            self.webSocketMessageEventService.handle(message: message, runtime: self)
        }
    }

    func registerOnUploadCompleteHandler() {
        ws.onUploadComplete = { [weak self] data in
            guard let self else { return }
            self.webSocketUploadLifecycleEventService.handleUploadComplete(data: data, runtime: self)
        }
    }

    func registerOnFormRequestHandler() {
        ws.onFormRequest = { [weak self] data in
            guard let self else { return }

            self.webSocketFormRequestEventService.handle(
                data: data,
                suppressPerAssetFormSheet: self.suppressPerAssetFormSheet,
                runtime: self
            )
        }
    }

    func registerOnFormConfirmedHandler() {
        ws.onFormConfirmed = { [weak self] data in
            guard let self else { return }
            self.webSocketFormConfirmedEventService.handle(data: data, runtime: self)
        }
    }

    func registerOnStreamReadyHandler() {
        ws.onStreamReady = { [weak self] data in
            guard let self else { return }

            self.webSocketStreamReadyEventService.handle(data: data, runtime: self)
        }
    }

    func registerOnStreamErroredHandler() {
        ws.onStreamErrored = { [weak self] data in
            guard let self else { return }

            self.webSocketUploadLifecycleEventService.handleStreamErrored(data: data, runtime: self)
        }
    }

    // MARK: - Connection State Handlers

    func setupConnectionHandlers() {
        ws.onConnected = { [weak self] in
            guard let self else { return }
            self.webSocketConnectionStateService.handleConnected(runtime: self)
        }

        ws.onReconnecting = { [weak self] attempt, maxAttempts in
            guard let self else { return }
            self.webSocketConnectionStateService.handleReconnecting(
                attempt: attempt,
                maxAttempts: maxAttempts,
                warningThreshold: self.reconnectWarningThreshold,
                runtime: self
            )
        }

        ws.onConnectionLost = { [weak self] in
            guard let self else { return }
            self.webSocketConnectionStateService.handleConnectionLost(runtime: self)
        }
    }
}
