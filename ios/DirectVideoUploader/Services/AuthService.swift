import Foundation
import Observation

enum AuthSessionStorage {
    case keychain
    case memory
}

/// Manages authentication state — login, token storage, current user.
@MainActor
@Observable
final class AuthService {
    // MARK: - State
    
    var currentUser: User? {
        didSet {
            if oldValue?.id != currentUser?.id { sessionGeneration = UUID() }
        }
    }
    var token: String? {
        didSet {
            if oldValue != token { sessionGeneration = UUID() }
        }
    }
    private(set) var sessionGeneration = UUID()
    var isAuthenticated: Bool { token != nil }
    var isLoading = false
    var errorMessage: String?
    
    // MARK: - Keychain key
    
    private let tokenKey = UserDefaultsKeys.authToken
    private let storage: AuthSessionStorage
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    
    init(
        storage: AuthSessionStorage = .keychain,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RedirectSafeTransport.data(for: $0)
        }
    ) {
        self.storage = storage
        self.transport = transport
        guard storage == .keychain else { return }
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
        guard !isLoading else { throw AuthError.loginInProgress }
        let generation = sessionGeneration
        let serverURL = ServerConfig.baseURL
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        let url = ServerConfig.loginURL
        Log.debug("🔐 [Auth] Attempting login", logger: Log.auth)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = LoginRequest(phoneNumber: phoneNumber, pin: pin, companyCode: companyCode)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await transport(request)
        guard sessionGeneration == generation, ServerConfig.baseURL == serverURL else {
            throw AuthError.sessionChanged
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            Log.error("🔐 [Auth] ❌ Invalid response (not HTTP)", logger: Log.auth)
            throw AuthError.invalidResponse
        }
        
        Log.debug("🔐 [Auth] HTTP status: \(httpResponse.statusCode)", logger: Log.auth)
        
        guard httpResponse.statusCode == 200 else {
            let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.loginFailed(errorBody?.error ?? "Login failed (HTTP \(httpResponse.statusCode))")
        }
        
        let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
        
        token = loginResponse.token
        currentUser = loginResponse.user
        
        // Persist token securely in Keychain
        if storage == .keychain, let t = token { KeychainHelper.save(t, forKey: tokenKey) }
    }
    
    // MARK: - Fetch Current User
    
    func fetchMe() async throws {
        guard let token else { throw AuthError.notAuthenticated }
        let generation = sessionGeneration
        let serverURL = ServerConfig.baseURL
        
        var request = URLRequest(url: ServerConfig.meURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await transport(request)
        guard sessionGeneration == generation, self.token == token,
              ServerConfig.baseURL == serverURL else {
            throw AuthError.sessionChanged
        }
        
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
        sessionGeneration = UUID()
        token = nil
        currentUser = nil
        if storage == .keychain { KeychainHelper.delete(forKey: tokenKey) }
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
    case sessionChanged
    case loginInProgress
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .loginFailed(let msg): return msg
        case .notAuthenticated: return "Not authenticated"
        case .tokenExpired: return "Session expired — please log in again"
        case .sessionChanged: return "Your session changed. Please try again."
        case .loginInProgress: return "Sign-in is already in progress."
        }
    }
}

nonisolated struct ErrorResponse: Codable {
    let error: String?
    let message: String?
}
