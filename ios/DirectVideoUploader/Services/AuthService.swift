import Foundation
import Observation

/// Manages authentication state — login, token storage, current user.
@MainActor
@Observable
final class AuthService {
    // MARK: - State
    
    var currentUser: User?
    var token: String?
    var isAuthenticated: Bool { token != nil }
    var isLoading = false
    var errorMessage: String?
    
    // MARK: - Keychain key
    
    private let tokenKey = UserDefaultsKeys.authToken
    
    init() {
        // Restore token from Keychain; migrate from UserDefaults if present.
        if let keychainToken = KeychainHelper.load(forKey: tokenKey) {
            token = keychainToken
        } else if let legacyToken = UserDefaults.standard.string(forKey: tokenKey) {
            // One-time migration: move old token into Keychain and remove from UserDefaults.
            token = legacyToken
            KeychainHelper.save(legacyToken, forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: tokenKey)
        }
    }
    
    // MARK: - Login
    
    func login(phoneNumber: String, pin: String, companyCode: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        let url = ServerConfig.loginURL
        print("🔐 [Auth] Attempting login to: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = LoginRequest(phoneNumber: phoneNumber, pin: pin, companyCode: companyCode)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        print("🔐 [Auth] Response received: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "nil")")
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("🔐 [Auth] ❌ Invalid response (not HTTP)")
            throw AuthError.invalidResponse
        }
        
        print("🔐 [Auth] HTTP status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.loginFailed(errorBody?.error ?? "Login failed (HTTP \(httpResponse.statusCode))")
        }
        
        let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
        
        token = loginResponse.token
        currentUser = loginResponse.user
        
        // Persist token securely in Keychain
        if let t = token { KeychainHelper.save(t, forKey: tokenKey) }
    }
    
    // MARK: - Fetch Current User
    
    func fetchMe() async throws {
        guard let token else { throw AuthError.notAuthenticated }
        
        var request = URLRequest(url: ServerConfig.meURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // Token expired — force logout
            logout()
            throw AuthError.tokenExpired
        }
        
        let meResponse = try JSONDecoder().decode(MeResponse.self, from: data)
        currentUser = meResponse.user
    }
    
    // MARK: - Logout
    
    func logout() {
        token = nil
        currentUser = nil
        KeychainHelper.delete(forKey: tokenKey)
    }
    
    // MARK: - Authenticated Request Helper
    
    func authenticatedRequest(for url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

// MARK: - Errors

nonisolated enum AuthError: LocalizedError {
    case invalidResponse
    case loginFailed(String)
    case notAuthenticated
    case tokenExpired
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .loginFailed(let msg): return msg
        case .notAuthenticated: return "Not authenticated"
        case .tokenExpired: return "Session expired — please log in again"
        }
    }
}

nonisolated struct ErrorResponse: Codable {
    let error: String?
    let message: String?
}
