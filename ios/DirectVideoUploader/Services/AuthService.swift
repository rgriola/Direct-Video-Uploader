// May 12, 2026 - 3:52pm - GitHub Copilot (GPT-5.3-Codex)
import AuthenticationServices
import Foundation
import Observation
import UIKit

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
    private var ssoSession: ASWebAuthenticationSession?
    private let ssoContextProvider = SSOAuthenticationContextProvider()

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
        print(
            "🔐 [Auth] Response received: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "nil")"
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            print("🔐 [Auth] ❌ Invalid response (not HTTP)")
            throw AuthError.invalidResponse
        }

        print("🔐 [Auth] HTTP status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.loginFailed(
                errorBody?.error ?? "Login failed (HTTP \(httpResponse.statusCode))")
        }

        let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)

        token = loginResponse.token
        currentUser = loginResponse.user

        // Persist token securely in Keychain
        if let t = token { KeychainHelper.save(t, forKey: tokenKey) }
    }

    // MARK: - Fetch Current User

    func fetchSSOConfig(companyCode: String) async throws -> SSOConfigResponse {
        let normalizedCode =
            companyCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard normalizedCode.count >= 3 else {
            return SSOConfigResponse(
                companyCode: normalizedCode,
                companyName: nil,
                ssoEnabled: false,
                samlEntityId: nil,
                samlMetadataUrl: nil,
                samlAttributeMapping: nil,
                startUrl: nil
            )
        }

        let request = URLRequest(url: ServerConfig.ssoConfigURL(normalizedCode))
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            return SSOConfigResponse(
                companyCode: normalizedCode,
                companyName: nil,
                ssoEnabled: false,
                samlEntityId: nil,
                samlMetadataUrl: nil,
                samlAttributeMapping: nil,
                startUrl: nil
            )
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.loginFailed(
                errorBody?.error ?? "SSO config check failed (HTTP \(httpResponse.statusCode))")
        }

        return try JSONDecoder().decode(SSOConfigResponse.self, from: data)
    }

    func loginWithSSO(companyCode: String) async throws {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            ssoSession = nil
        }

        let normalizedCode =
            companyCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let config = try await fetchSSOConfig(companyCode: normalizedCode)

        guard config.ssoEnabled else {
            throw AuthError.loginFailed("SSO is not enabled for \(normalizedCode)")
        }

        let startURL = ServerConfig.ssoStartURL(
            normalizedCode,
            redirectURI: ServerConfig.ssoCallbackURLString
        )

        let callbackURL = try await beginSSOSession(startURL: startURL)
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        else {
            throw AuthError.invalidResponse
        }

        if let callbackError = components.queryItems?.first(where: { $0.name == "error" })?.value,
            !callbackError.isEmpty
        {
            throw AuthError.loginFailed(callbackError)
        }

        guard let tokenValue = components.queryItems?.first(where: { $0.name == "token" })?.value,
            !tokenValue.isEmpty
        else {
            throw AuthError.loginFailed("SSO callback did not include a token")
        }

        token = tokenValue
        KeychainHelper.save(tokenValue, forKey: tokenKey)
        try await fetchMe()
    }

    private func beginSSOSession(startURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: startURL,
                callbackURLScheme: ServerConfig.ssoCallbackScheme
            ) { callbackURL, error in
                if let error {
                    if let authError = error as? ASWebAuthenticationSessionError,
                        authError.code == .canceledLogin
                    {
                        continuation.resume(throwing: AuthError.ssoCancelled)
                        return
                    }
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: AuthError.invalidResponse)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = ssoContextProvider
            session.prefersEphemeralWebBrowserSession = true
            ssoSession = session

            if !session.start() {
                continuation.resume(throwing: AuthError.loginFailed("Unable to start SSO login"))
            }
        }
    }

    func fetchMe() async throws {
        guard let token else { throw AuthError.notAuthenticated }

        var request = URLRequest(url: ServerConfig.meURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            // Token expired — force logout
            logout()
            throw AuthError.tokenExpired
        }

        let meResponse = try JSONDecoder().decode(MeResponse.self, from: data)
        currentUser = meResponse.user
    }

    // MARK: - Logout

    func logoutFromServer() async {
        let authToken = token
        defer { logout() }

        guard let authToken else { return }

        var request = URLRequest(url: ServerConfig.logoutURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            print("⚠️ [Auth] Logout request failed: \(error.localizedDescription)")
        }
    }

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

enum AuthError: LocalizedError {
    case invalidResponse
    case loginFailed(String)
    case notAuthenticated
    case tokenExpired
    case ssoCancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .loginFailed(let msg): return msg
        case .notAuthenticated: return "Not authenticated"
        case .tokenExpired: return "Session expired — please log in again"
        case .ssoCancelled: return "SSO login canceled"
        }
    }
}

struct ErrorResponse: Codable {
    let error: String?
    let message: String?
    let code: String?
    let ssoStartUrl: String?
}

private final class SSOAuthenticationContextProvider: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let foregroundScene = scenes.first(where: { $0.activationState == .foregroundActive })
        return foregroundScene?.windows.first(where: { $0.isKeyWindow })
            ?? foregroundScene?.windows.first
            ?? ASPresentationAnchor()
    }
}
