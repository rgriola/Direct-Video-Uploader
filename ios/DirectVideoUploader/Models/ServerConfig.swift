// May 11, 2026 - 2:02pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

/// Centralized UserDefaults keys.
enum UserDefaultsKeys {
    static let serverURL = "dvu_server_url"
    static let authToken = "dvu_auth_token"
    static let appearanceMode = "dvu_appearance_mode"
    static let debugGroupedFormSubmits = "dvu_debug_grouped_form_submits"
}

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
    private static let productionURL = "https://ms-fixer.com"

    /// UserDefaults key for the user-saved server URL override
    private static let serverURLKey = UserDefaultsKeys.serverURL

    // MARK: - Server URLs

    /// Base URL for HTTP API calls — resolved dynamically on every access
    static var baseURL: URL {
        #if DEBUG
            // 1. User-saved override (from settings on login screen) — Debug only
            if let saved = UserDefaults.standard.string(forKey: serverURLKey),
                let url = URL(string: saved)
            {
                return url
            }

            // 2. Environment variable (Xcode scheme or CI)
            if let envURL = ProcessInfo.processInfo.environment["DVU_SERVER_URL"],
                let url = URL(string: envURL)
            {
                return url
            }

            // 3. Simulator → always 127.0.0.1
            #if targetEnvironment(simulator)
                return URL(string: "http://127.0.0.1:3000")!
            #else
                // 4. Physical device in Debug → Mac's current tethering/LAN IP
                //    Update this if your IP changes (check `npm run dev` output under "iOS (LAN)")
                return URL(string: "http://172.20.10.2:3000")!
            #endif

        #else
            // Release builds always use production
            return URL(string: productionURL)!
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

    /// Build a full URL from a path. Uses string interpolation (not appendingPathComponent)
    /// to avoid percent-encoding issues with slashes.
    static func url(for path: String) -> URL {
        URL(string: "\(baseURL.absoluteString)\(path)")!
    }

    // Auth
    static var loginURL: URL { url(for: "/api/auth/login") }
    static var meURL: URL { url(for: "/api/auth/me") }

    // Assets
    static var assetsURL: URL { url(for: "/api/assets") }
    static var myAssetsURL: URL { url(for: "/api/assets/mine") }
    static func assetURL(_ id: String) -> URL { url(for: "/api/assets/\(id)") }
    static func muxUploadURL(_ id: String) -> URL { url(for: "/api/assets/\(id)/mux-upload") }
    static func formURL(_ id: String) -> URL { url(for: "/api/assets/\(id)/form") }
    static func transcriptURL(_ id: String) -> URL { url(for: "/api/assets/\(id)/transcript") }

    // Messages
    static var messagesURL: URL { url(for: "/api/messages") }

    // Error logging
    static var errorsURL: URL { url(for: "/api/errors") }

    // Health
    static var healthURL: URL { url(for: "/api/health") }

    // Clip viewer (public)
    static func clipURL(_ mediasourceId: String) -> URL? {
        let trimmed = mediasourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "\(baseURL.absoluteString)/clips/\(trimmed)")
    }
}
