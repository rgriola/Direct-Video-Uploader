// May 10, 2026 - 3:19pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation
import Network
import Observation
import UIKit

/// WebSocket service using native URLSessionWebSocketTask.
/// Communicates with the Socket.IO server using the Socket.IO protocol.
///
/// Note: Socket.IO uses a custom protocol on top of WebSocket.
/// This implementation handles the Socket.IO handshake and message framing.
@MainActor
@Observable
final class WebSocketService {
    // MARK: - State

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    var state: ConnectionState = .disconnected
    var isConnected: Bool { state == .connected }
    var isDisconnected: Bool { state == .disconnected }
    var hasActiveSocket: Bool { webSocket != nil }

    /// True when messages are buffered waiting for reconnect
    var hasPendingMessages: Bool { !pendingQueue.isEmpty }

    // MARK: - Callbacks

    var onMessage: (@MainActor (ChatMessage) -> Void)?
    var onUploadComplete: (@MainActor ([String: Any]) -> Void)?
    var onFormRequest: (@MainActor ([String: Any]) -> Void)?
    var onFormConfirmed: (@MainActor ([String: Any]) -> Void)?
    var onMuxReady: (@MainActor ([String: Any]) -> Void)?
    var onConnected: (@MainActor () -> Void)?  // socket connected/reconnected
    var onReconnecting: (@MainActor (Int, Int) -> Void)?  // (attempt, maxAttempts)
    var onConnectionLost: (@MainActor () -> Void)?  // max retries exhausted

    // MARK: - Private

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var token: String?
    private var tokenServerURL: URL?
    private var sid: String?
    private var isUpgraded = false
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 10
    private var isReconnecting = false  // Guard against parallel connect attempts (1.6)
    private static let socketIOPath = "/socket.io"

    // Message queue — buffers sends when disconnected, flushes on reconnect (A2)
    private var pendingQueue: [String] = []
    private let maxQueueSize = 20

    // Network path monitor — recovers after max retries exhausted (1.3)
    private var pathMonitor: NWPathMonitor?
    private var monitorQueue: DispatchQueue?

    // Ping watchdog — detects zombie connections when server pings stop (C1)
    // Server sends Engine.IO pings every 20s with 25s timeout. If we don't
    // receive a ping within 45s, the connection is zombie.
    private var pingWatchdog: Task<Void, Never>?
    private let pingWatchdogInterval: TimeInterval = 45

    // Active connect/reconnect task — cancelled on disconnect to stop stale loops
    private var connectTask: Task<Void, Never>?
    private let serverURLProvider: @MainActor () -> URL
    private let handshakeTransport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        serverURL: @escaping @MainActor () -> URL = { ServerConfig.wsURL },
        handshakeTransport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RedirectSafeTransport.data(for: $0)
        }
    ) {
        self.serverURLProvider = serverURL
        self.handshakeTransport = handshakeTransport
    }

    // MARK: - Connect

    @discardableResult
    func connect(token: String) -> Task<Void, Never>? {
        guard state == .disconnected, !isReconnecting else {
            Log.debug("🔌 [WS] Already \(state)\(isReconnecting ? " (reconnecting)" : ""), skipping connect", logger: Log.network)
            return nil
        }

        let serverURL = serverURLProvider()
        guard tokenServerURL == nil || tokenServerURL == serverURL else {
            Log.error("⚠️ [WS] Server changed during the authenticated session", logger: Log.network)
            disconnect()
            onConnectionLost?()
            return nil
        }
        self.token = token
        tokenServerURL = serverURL
        state = .connecting
        isReconnecting = true
        stopNetworkMonitor()
        Log.debug("🔌 [WS] Connecting", logger: Log.network)

        // Step 1: Socket.IO handshake via HTTP polling to get session ID
        let task = Task { @MainActor in
            do {
                try await performHandshake(token: token, serverURL: serverURL)
            } catch {
                guard !Task.isCancelled else { return }
                guard self.token == token, serverURLProvider() == serverURL else {
                    disconnect()
                    onConnectionLost?()
                    return
                }
                Log.error("❌ [WS] Handshake failed: \(Log.describe(error))", logger: Log.network)
                state = .disconnected
                // Attempt reconnect on handshake failure too
                reconnectAttempt += 1
                guard reconnectAttempt <= maxReconnectAttempts else {
                    isReconnecting = false
                    startNetworkMonitor()  // Watch for network return (1.3)
                    onConnectionLost?()
                    return
                }
                let delay = min(3.0 * pow(2.0, Double(reconnectAttempt - 1)), 60.0)
                Log.debug("🔄 [WS] Reconnect attempt \(reconnectAttempt)/\(maxReconnectAttempts) in \(delay)s", logger: Log.network)
                onReconnecting?(reconnectAttempt, maxReconnectAttempts)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                guard self.token == token, serverURLProvider() == serverURL else {
                    disconnect()
                    onConnectionLost?()
                    return
                }
                isReconnecting = false
                connect(token: token)
            }
        }
        connectTask = task
        return task
    }

    // MARK: - Socket.IO Handshake

    private func performHandshake(token: String, serverURL: URL) async throws {
        guard let pollingURL = Self.socketURL(baseURL: serverURL, isWebSocket: false) else {
            throw WebSocketError.handshakeFailed
        }
        var request = URLRequest(url: pollingURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await handshakeTransport(request)
        guard !Task.isCancelled, self.token == token, serverURLProvider() == serverURL else {
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WebSocketError.handshakeFailed
        }

        // Socket.IO polling response starts with a length prefix like "0{...}"
        guard let body = String(data: data, encoding: .utf8) else {
            throw WebSocketError.handshakeFailed
        }

        // Parse out the JSON (skip the Engine.IO packet type prefix)
        let jsonStart = body.firstIndex(of: "{") ?? body.startIndex
        let jsonString = String(body[jsonStart...])

        guard let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let sid = json["sid"] as? String
        else {
            throw WebSocketError.handshakeFailed
        }

        self.sid = sid

        // Step 2: Upgrade to WebSocket
        try upgradeToWebSocket(sid: sid, token: token, serverURL: serverURL)
    }

    // MARK: - WebSocket Upgrade

    private func upgradeToWebSocket(sid: String, token: String, serverURL: URL) throws {
        guard let socketURL = Self.socketURL(
            baseURL: serverURL, isWebSocket: true, sid: sid) else {
            throw WebSocketError.handshakeFailed
        }
        var request = URLRequest(url: socketURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // Invalidate previous session to prevent leak (#3)
        session?.invalidateAndCancel()
        let nextSession = RedirectSafeTransport.webSocketSession()
        let socket = nextSession.webSocketTask(with: request)
        session = nextSession
        webSocket = socket
        socket.resume()

        // Send Engine.IO upgrade probe
        sendRaw("2probe", on: socket)

        // Listen for messages
        listenForMessages(on: socket)
    }

    static func socketURL(baseURL: URL, isWebSocket: Bool, sid: String? = nil) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        if isWebSocket { components.scheme = scheme == "https" ? "wss" : "ws" }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + socketIOPath
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: isWebSocket ? "websocket" : "polling"),
        ]
        if let sid { components.queryItems?.append(URLQueryItem(name: "sid", value: sid)) }
        components.fragment = nil
        return components.url
    }

    // MARK: - Listen

    private func listenForMessages(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Ignore callbacks from stale sockets that were already replaced.
                guard self.webSocket === socket else { return }

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleEngineIOMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleEngineIOMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    // Continue listening
                    self.listenForMessages(on: socket)

                case .failure(let error):
                    Log.error("❌ [WS] Receive error: \(Log.describe(error))", logger: Log.network)
                    self.cleanupConnection()

                    // Exponential backoff reconnect (3s → 6s → 12s … max 60s)
                    self.reconnectAttempt += 1
                    guard self.reconnectAttempt <= self.maxReconnectAttempts else {
                        Log.error("🛑 [WS] Max reconnect attempts (\(self.maxReconnectAttempts)) reached — giving up", logger: Log.network)
                        self.isReconnecting = false
                        self.startNetworkMonitor()  // Watch for network return (1.3)
                        self.onConnectionLost?()
                        return
                    }
                    let delay = min(3.0 * pow(2.0, Double(self.reconnectAttempt - 1)), 60.0)
                    Log.debug("🔄 [WS] Reconnect attempt \(self.reconnectAttempt)/\(self.maxReconnectAttempts) in \(delay)s", logger: Log.network)
                    self.onReconnecting?(self.reconnectAttempt, self.maxReconnectAttempts)
                    try? await Task.sleep(for: .seconds(delay))
                    guard self.webSocket == nil else { return }
                    if let token = self.token {
                        self.isReconnecting = false
                        self.connect(token: token)
                    }
                }
            }
        }
    }

    // MARK: - Engine.IO Message Handling

    private func handleEngineIOMessage(_ raw: String) {
        guard !raw.isEmpty else { return }

        let firstChar = raw.first!

        switch firstChar {
        case "0":  // Open
            break
        case "2":  // Ping
            sendRaw("3")  // Pong
            resetPingWatchdog()  // C1: Server is alive, reset watchdog
        case "3":  // Pong
            // Only upgrade on the probe response "3probe", not regular pongs.
            // In Engine.IO 4 the SERVER sends keep-alive pings ("2") and the
            // client responds ("3"). If we treat every "3" as a probe, we
            // re-send the upgrade+connect packets and the server disconnects us.
            if raw == "3probe" && !isUpgraded {
                isUpgraded = true
                // Upgrade confirmed — send Engine.IO upgrade packet
                sendRaw("5")

                // Send Socket.IO CONNECT with auth (clientType + token).
                // Without this packet the server never fires io.on('connection')
                // and all Socket.IO events (message:send, etc.) are silently dropped.
                if let token = self.token {
                    let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
                    let deviceName = UIDevice.current.name
                    let deviceModel = UIDevice.current.model
                    let auth = [
                        "token": token,
                        "clientType": "ios",
                        "deviceId": deviceId,
                        "deviceName": deviceName,
                        "deviceModel": deviceModel,
                    ]
                    if let jsonData = try? JSONSerialization.data(withJSONObject: auth),
                        let jsonString = String(data: jsonData, encoding: .utf8)
                    {
                        sendRaw("40\(jsonString)")
                    } else {
                        sendRaw("40{\"token\":\"\(token)\",\"clientType\":\"ios\"}")
                    }
                } else {
                    sendRaw("40")
                }
            }
        // Regular pong ("3" without "probe") — no action needed.
        // state = .connected is set when we receive the Socket.IO CONNECT ACK (40{...})
        case "4":  // Message (Socket.IO packet)
            handleSocketIOMessage(String(raw.dropFirst()))
        default:
            break
        }
    }

    // MARK: - Socket.IO Message Handling

    private func handleSocketIOMessage(_ raw: String) {
        guard !raw.isEmpty else { return }

        let firstChar = raw.first!

        switch firstChar {
        case "0":  // Connect
            state = .connected
            reconnectAttempt = 0  // Reset backoff on successful connect
            isReconnecting = false
            stopNetworkMonitor()
            let rest = String(raw.dropFirst())
            if let data = rest.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                json["sid"] is String
            {
                Log.debug("✅ [WS] Socket.IO connected", logger: Log.network)
            }
            // Flush any queued messages
            flushPendingQueue()
            resetPingWatchdog()  // C1: Start watchdog on successful connect
            onConnected?()

        case "2":  // Event
            let rest = String(raw.dropFirst())
            parseEvent(rest)

        default:
            break
        }
    }

    // MARK: - Parse Socket.IO Event

    private func parseEvent(_ raw: String) {
        guard let data = raw.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
            let eventName = array.first as? String
        else {
            return
        }

        let payload = array.count > 1 ? array[1] : nil

        switch eventName {
        case "message:new":
            if let dict = payload as? [String: Any],
                let jsonData = try? JSONSerialization.data(withJSONObject: dict)
            {
                do {
                    let message = try JSONDecoder().decode(ChatMessage.self, from: jsonData)
                    onMessage?(message)
                } catch {
                    Log.error("❌ [WS] Failed to decode message:new — \(Log.describe(error))", logger: Log.network)
                    Log.debug("🔎 [WS] Payload keys: \(dict.keys.sorted())", logger: Log.network)
                }
            }

        case "upload:complete":
            if let dict = payload as? [String: Any] {
                onUploadComplete?(dict)
            }

        case "form:request":
            if let dict = payload as? [String: Any] {
                onFormRequest?(dict)
            }

        case "form:confirmed":
            if let dict = payload as? [String: Any] {
                onFormConfirmed?(dict)
            }

        case "mux:ready":
            if let dict = payload as? [String: Any] {
                onMuxReady?(dict)
            }

        default:
            Log.debug("📨 [WS] Unhandled event: \(eventName)", logger: Log.network)
        }
    }

    // MARK: - Send

    func sendMessage(text: String, assetId: String? = nil) {
        var payload: [String: Any] = ["text": text]
        if let assetId { payload["assetId"] = assetId }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }
        enqueueOrSend("42[\"message:send\",\(jsonString)]")
    }

    func sendVideoUpload(assetId: String, fileName: String, fileSize: Int64) {
        let payload: [String: Any] = [
            "assetId": assetId, "fileName": fileName, "fileSize": fileSize,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }
        enqueueOrSend("42[\"video:upload\",\(jsonString)]")
    }

    // MARK: - Message Queue (A2)

    /// Send immediately if connected, otherwise buffer for later delivery.
    private func enqueueOrSend(_ frame: String) {
        if state == .connected {
            sendRaw(frame)
        } else {
            // Drop oldest if queue is full (keep user's latest intent)
            if pendingQueue.count >= maxQueueSize {
                pendingQueue.removeFirst()
                Log.error("⚠️ [WS] Queue full — dropped oldest message", logger: Log.network)
            }
            pendingQueue.append(frame)
            Log.debug("📦 [WS] Queued message (\(pendingQueue.count)/\(maxQueueSize))", logger: Log.network)
        }
    }

    /// Flush all queued messages in FIFO order after reconnect.
    private func flushPendingQueue() {
        guard !pendingQueue.isEmpty else { return }
        let count = pendingQueue.count
        Log.debug("📤 [WS] Flushing \(count) queued message(s)", logger: Log.network)
        for frame in pendingQueue {
            sendRaw(frame)
        }
        pendingQueue.removeAll()
    }

    // MARK: - Raw Send

    private func sendRaw(_ text: String, on socket: URLSessionWebSocketTask? = nil) {
        guard let targetSocket = socket ?? webSocket else { return }

        targetSocket.send(.string(text)) { [weak self] error in
            if let error {
                Log.error("❌ [WS] Send error: \(Log.describe(error))", logger: Log.network)
                // Send failure means connection is dead — trigger reconnect (1.4)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Ignore send failures from stale sockets already replaced.
                    guard self.webSocket === targetSocket else { return }
                    guard self.state == .connected else { return }

                    Log.debug("🔌 [WS] Send failure detected — triggering reconnect", logger: Log.network)
                    self.cleanupConnection()
                    self.reconnectAttempt += 1
                    guard self.reconnectAttempt <= self.maxReconnectAttempts else {
                        self.startNetworkMonitor()
                        self.onConnectionLost?()
                        return
                    }
                    self.onReconnecting?(self.reconnectAttempt, self.maxReconnectAttempts)
                    let delay = min(3.0 * pow(2.0, Double(self.reconnectAttempt - 1)), 60.0)
                    try? await Task.sleep(for: .seconds(delay))
                    if let token = self.token {
                        self.connect(token: token)
                    }
                }
            }
        }
    }

    // MARK: - Foreground / Background (A1)

    /// Called when app returns to foreground — reset retries and reconnect immediately.
    func reconnectFromForeground(token: String) {
        connectTask?.cancel()
        connectTask = nil
        reconnectAttempt = 0
        isReconnecting = false
        stopNetworkMonitor()
        if state != .disconnected {
            cleanupConnection()
        }
        connect(token: token)
    }

    /// Called when app enters background — graceful close without preventing reconnect.
    func backgroundDisconnect() {
        cleanupConnection()
    }

    // MARK: - Network Path Monitor (1.3)

    /// Start watching for network restoration after max retries exhausted.
    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "ws.network.monitor")
        monitorQueue = queue
        pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, path.status == .satisfied, let token = self.token else { return }
                Log.debug("🌐 [WS] Network restored — attempting reconnect", logger: Log.network)
                self.reconnectAttempt = 0
                self.isReconnecting = false
                self.stopNetworkMonitor()
                self.connect(token: token)
            }
        }
        monitor.start(queue: queue)
        Log.debug("👁️ [WS] Network monitor started — waiting for connectivity", logger: Log.network)
    }

    private func stopNetworkMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        monitorQueue = nil
    }

    // MARK: - Ping Watchdog (C1)

    /// Start (or restart) the watchdog that detects zombie connections.
    /// Called when we first connect and on every server ping.
    private func resetPingWatchdog() {
        pingWatchdog?.cancel()
        pingWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.pingWatchdogInterval ?? 45))
            guard !Task.isCancelled else { return }
            guard let self, self.state == .connected else { return }
            Log.debug("⏰ [WS] Ping watchdog fired — no server ping in \(Int(self.pingWatchdogInterval))s, connection is zombie", logger: Log.network)
            self.cleanupConnection()
            self.reconnectAttempt += 1
            if self.reconnectAttempt <= self.maxReconnectAttempts, let token = self.token {
                self.onReconnecting?(self.reconnectAttempt, self.maxReconnectAttempts)
                self.connect(token: token)
            } else {
                self.startNetworkMonitor()
                self.onConnectionLost?()
            }
        }
    }

    private func stopPingWatchdog() {
        pingWatchdog?.cancel()
        pingWatchdog = nil
    }

    // MARK: - Connection Cleanup

    /// Reset connection state without clearing token (for reconnect).
    private func cleanupConnection() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()  // Prevent URLSession leak (#3)
        session = nil
        sid = nil
        isUpgraded = false
        stopPingWatchdog()  // C1: Stop watchdog on disconnect
        state = .disconnected
    }

    // MARK: - Disconnect

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        reconnectAttempt = maxReconnectAttempts + 1  // Prevent auto-reconnect
        isReconnecting = false
        stopNetworkMonitor()
        stopPingWatchdog()  // C1
        cleanupConnection()
        pendingQueue.removeAll()
        token = nil
        tokenServerURL = nil
        reconnectAttempt = 0
    }
}

// MARK: - Errors

nonisolated enum WebSocketError: LocalizedError {
    case handshakeFailed
    case notConnected

    var errorDescription: String? {
        switch self {
        case .handshakeFailed: return "WebSocket handshake failed"
        case .notConnected: return "WebSocket not connected"
        }
    }
}
