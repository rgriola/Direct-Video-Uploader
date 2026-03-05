import Foundation
import Observation

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
    
    // MARK: - Callbacks
    
    var onMessage: (@MainActor (ChatMessage) -> Void)?
    var onUploadComplete: (@MainActor ([String: Any]) -> Void)?
    var onFormRequest: (@MainActor ([String: Any]) -> Void)?
    var onFormConfirmed: (@MainActor ([String: Any]) -> Void)?
    var onReconnecting: (@MainActor (Int, Int) -> Void)?       // (attempt, maxAttempts)
    var onConnectionLost: (@MainActor () -> Void)?              // max retries exhausted
    
    // MARK: - Private
    
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var token: String?
    private var sid: String?
    private var isUpgraded = false
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 10
    
    // MARK: - Connect
    
    func connect(token: String) {
        guard state == .disconnected else {
            print("🔌 [WS] Already \(state), skipping connect")
            return
        }
        
        self.token = token
        state = .connecting
        print("🔌 [WS] Connecting to: \(ServerConfig.wsURL.absoluteString)")
        
        // Step 1: Socket.IO handshake via HTTP polling to get session ID
        Task { @MainActor in
            do {
                try await performHandshake(token: token)
            } catch {
                print("❌ [WS] Handshake failed:", error)
                state = .disconnected
                // Attempt reconnect on handshake failure too
                reconnectAttempt += 1
                guard reconnectAttempt <= maxReconnectAttempts else {
                    onConnectionLost?()
                    return
                }
                let delay = min(3.0 * pow(2.0, Double(reconnectAttempt - 1)), 60.0)
                print("🔄 [WS] Reconnect attempt \(reconnectAttempt)/\(maxReconnectAttempts) in \(delay)s")
                onReconnecting?(reconnectAttempt, maxReconnectAttempts)
                try? await Task.sleep(for: .seconds(delay))
                connect(token: token)
            }
        }
    }
    
    // MARK: - Socket.IO Handshake
    
    private func performHandshake(token: String) async throws {
        // Socket.IO first does a polling request to get the session ID
        var components = URLComponents(url: ServerConfig.wsURL, resolvingAgainstBaseURL: false)!
        components.path = "/socket.io/"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "polling"),
        ]
        
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        // Socket.IO polling response starts with a length prefix like "0{...}"
        guard let body = String(data: data, encoding: .utf8) else {
            throw WebSocketError.handshakeFailed
        }
        
        // Parse out the JSON (skip the Engine.IO packet type prefix)
        let jsonStart = body.firstIndex(of: "{") ?? body.startIndex
        let jsonString = String(body[jsonStart...])
        
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let sid = json["sid"] as? String else {
            throw WebSocketError.handshakeFailed
        }
        
        self.sid = sid
        
        // Step 2: Upgrade to WebSocket
        upgradeToWebSocket(sid: sid, token: token)
    }
    
    // MARK: - WebSocket Upgrade
    
    private func upgradeToWebSocket(sid: String, token: String) {
        var components = URLComponents(url: ServerConfig.wsURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/socket.io/"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
            URLQueryItem(name: "sid", value: sid),
        ]
        
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        // Invalidate previous session to prevent leak (#3)
        session?.invalidateAndCancel()
        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: request)
        webSocket?.resume()
        
        // Send Engine.IO upgrade probe
        sendRaw("2probe")
        
        // Listen for messages
        listenForMessages()
    }
    
    // MARK: - Listen
    
    private func listenForMessages() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                
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
                    self.listenForMessages()
                    
                case .failure(let error):
                    print("❌ WebSocket receive error:", error)
                    self.cleanupConnection()
                    
                    // Exponential backoff reconnect (3s → 6s → 12s … max 60s)
                    self.reconnectAttempt += 1
                    guard self.reconnectAttempt <= self.maxReconnectAttempts else {
                        print("🛑 [WS] Max reconnect attempts (\(self.maxReconnectAttempts)) reached — giving up")
                        self.onConnectionLost?()
                        return
                    }
                    let delay = min(3.0 * pow(2.0, Double(self.reconnectAttempt - 1)), 60.0)
                    print("🔄 [WS] Reconnect attempt \(self.reconnectAttempt)/\(self.maxReconnectAttempts) in \(delay)s")
                    self.onReconnecting?(self.reconnectAttempt, self.maxReconnectAttempts)
                    try? await Task.sleep(for: .seconds(delay))
                    if let token = self.token {
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
        case "0": // Open
            break
        case "2": // Ping
            sendRaw("3") // Pong
        case "3": // Pong
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
                    let auth = "{\"token\":\"\(token)\",\"clientType\":\"ios\"}"
                    sendRaw("40\(auth)")
                } else {
                    sendRaw("40")
                }
            }
            // Regular pong ("3" without "probe") — no action needed.
            // state = .connected is set when we receive the Socket.IO CONNECT ACK (40{...})
        case "4": // Message (Socket.IO packet)
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
        case "0": // Connect
            state = .connected
            reconnectAttempt = 0  // Reset backoff on successful connect
            let rest = String(raw.dropFirst())
            if let data = rest.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = json["sid"] as? String {
                print("✅ Socket.IO connected (sid: \(sid))")
            }
            
        case "2": // Event
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
              let eventName = array.first as? String else {
            return
        }
        
        let payload = array.count > 1 ? array[1] : nil
        
        switch eventName {
        case "message:new":
            if let dict = payload as? [String: Any],
               let jsonData = try? JSONSerialization.data(withJSONObject: dict) {
                do {
                    let message = try JSONDecoder().decode(ChatMessage.self, from: jsonData)
                    onMessage?(message)
                } catch {
                    print("❌ [WS] Failed to decode message:new — \(error)")
                    print("   Payload keys: \(dict.keys.sorted())")
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
            
        default:
            print("📨 Unhandled WS event: \(eventName)")
        }
    }
    
    // MARK: - Send
    
    func sendMessage(text: String) {
        // Use JSONSerialization to safely escape user text (quotes, backslashes, emoji, etc.)
        let payload: [String: Any] = ["text": text]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        sendRaw("42[\"message:send\",\(jsonString)]")
    }
    
    func sendVideoUpload(assetId: String, fileName: String, fileSize: Int64) {
        // Use JSONSerialization for safe escaping (#16)
        let payload: [String: Any] = ["assetId": assetId, "fileName": fileName, "fileSize": fileSize]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        sendRaw("42[\"video:upload\",\(jsonString)]")
    }
    
    // MARK: - Raw Send
    
    private func sendRaw(_ text: String) {
        webSocket?.send(.string(text)) { error in
            if let error {
                print("❌ WS send error:", error)
            }
        }
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
        state = .disconnected
    }
    
    // MARK: - Disconnect
    
    func disconnect() {
        reconnectAttempt = maxReconnectAttempts + 1  // Prevent auto-reconnect
        cleanupConnection()
        token = nil
        reconnectAttempt = 0
    }
}

// MARK: - Errors

enum WebSocketError: LocalizedError {
    case handshakeFailed
    case notConnected
    
    var errorDescription: String? {
        switch self {
        case .handshakeFailed: return "WebSocket handshake failed"
        case .notConnected: return "WebSocket not connected"
        }
    }
}
