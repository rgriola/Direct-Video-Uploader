import Foundation

/// Central configuration for server connection.
///
/// Priority order for resolving the server URL:
///   1. User-saved override (UserDefaults) — set via the login screen
///   2. Environment variable DVU_SERVER_URL — for CI / Xcode schemes
///   3. Simulator default → http://127.0.0.1:3000
///   4. Physical device default → production URL (or last-known dev IP)
enum ServerConfig {
    
    // MARK: - Production URL (update when deployed to Render)
    
    /// The production server URL. Used as the default for physical devices in Release builds.
    private static let productionURL = "https://dvu-server.onrender.com"
    
    /// UserDefaults key for the user-saved server URL override
    private static let serverURLKey = "dvu_server_url"
    
    // MARK: - Server URLs
    
    /// Base URL for HTTP API calls — resolved dynamically on every access
    static var baseURL: URL {
        // 1. User-saved override (from settings on login screen)
        if let saved = UserDefaults.standard.string(forKey: serverURLKey),
           let url = URL(string: saved) {
            return url
        }
        
        // 2. Environment variable (Xcode scheme or CI)
        if let envURL = ProcessInfo.processInfo.environment["DVU_SERVER_URL"],
           let url = URL(string: envURL) {
            return url
        }
        
        // 3. Simulator → always 127.0.0.1
        #if targetEnvironment(simulator)
        return URL(string: "http://127.0.0.1:3000")!
        #else
        // 4. Physical device → production in Release, dev-friendly in Debug
        #if DEBUG
        // In Debug builds on a physical device, default to the LAN IP.
        // The user can change this via the server URL editor on the login screen.
        return URL(string: "http://192.168.1.89:3000")!
        #else
        return URL(string: productionURL)!
        #endif
        #endif
    }
    
    /// The currently displayed server URL string (for the settings UI)
    static var currentURLString: String {
        baseURL.absoluteString
    }
    
    /// Save a custom server URL (persists across launches)
    static func setServerURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: serverURLKey)
        } else {
            // Ensure it has a scheme
            let normalized = trimmed.hasPrefix("http") ? trimmed : "http://\(trimmed)"
            UserDefaults.standard.set(normalized, forKey: serverURLKey)
        }
    }
    
    /// Clear the saved URL override (reverts to default)
    static func resetServerURL() {
        UserDefaults.standard.removeObject(forKey: serverURLKey)
    }
    
    /// Whether a custom URL is currently saved
    static var hasCustomURL: Bool {
        UserDefaults.standard.string(forKey: serverURLKey) != nil
    }
    
    /// WebSocket URL (Socket.IO)
    static var wsURL: URL {
        baseURL
    }
    
    // MARK: - API Endpoints
    
    static func url(for path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }
    
    // Auth
    static var loginURL: URL { url(for: "/api/auth/login") }
    static var meURL: URL { url(for: "/api/auth/me") }
    
    // Assets
    static var assetsURL: URL { url(for: "/api/assets") }
    static func assetURL(_ id: String) -> URL { url(for: "/api/assets/\(id)") }
    static func uploadURL(_ id: String) -> URL { url(for: "/api/assets/\(id)/upload") }
    static func formURL(_ id: String) -> URL { url(for: "/api/assets/\(id)/form") }
    
    // Messages
    static var messagesURL: URL { url(for: "/api/messages") }
    
    // Health
    static var healthURL: URL { url(for: "/api/health") }
}
