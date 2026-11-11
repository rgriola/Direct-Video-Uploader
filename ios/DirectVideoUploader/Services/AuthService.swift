import Foundation
import Observation

enum AuthSessionStorage {
    case keychain
    case memory
}

nonisolated enum AuthServerIdentity {
    static func canonical(_ url: URL) -> String? {
        guard let source = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = source.scheme?.lowercased(), scheme == "https",
              let rawHost = source.host?.lowercased(), !rawHost.isEmpty,
              source.user == nil, source.password == nil, source.query == nil, source.fragment == nil,
              source.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        let host = String(rawHost.reversed().drop(while: { $0 == "." }).reversed())
        guard !host.isEmpty else { return nil }
        var path = source.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        var identity = URLComponents()
        identity.scheme = scheme
        identity.host = host
        if source.port != (scheme == "https" ? 443 : 80) { identity.port = source.port }
        identity.percentEncodedPath = path
        return identity.string
    }

    static func endpoint(_ path: String, on server: URL) -> URL? {
        guard let base = canonical(server), path.hasPrefix("/") else { return nil }
        return URL(string: "\(base)\(path)")
    }

    static func contains(_ url: URL, server: String) -> Bool {
        guard let base = URLComponents(string: server),
              var target = URLComponents(url: url, resolvingAgainstBaseURL: false),
              target.user == nil, target.password == nil, target.fragment == nil,
              let path = target.percentEncodedPath.removingPercentEncoding,
              let basePath = base.percentEncodedPath.removingPercentEncoding,
              !path.contains("\\"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              basePath.isEmpty || path == basePath || path.hasPrefix(basePath + "/") else {
            return false
        }
        target.percentEncodedPath = base.percentEncodedPath
        target.query = nil
        return target.url.flatMap(canonical) == server
    }
}

nonisolated struct AuthenticatedSessionSnapshot: Equatable, Sendable {
    let generation: UUID
    let token: String
    let userId: String
    let server: String
}

@MainActor
@Observable
final class AuthService {
    var currentUser: User? {
        didSet {
            if oldValue?.id != currentUser?.id { sessionGeneration = UUID() }
            updateMemoryBinding()
        }
    }
    var token: String? {
        didSet {
            if oldValue != token { sessionGeneration = UUID() }
            updateMemoryBinding()
        }
    }
    private(set) var sessionGeneration = UUID()
    var isAuthenticated: Bool { token != nil }
    var isLoading = false
    private(set) var isRestoringSession = false
    var errorMessage: String?
    var canRetrySavedSession: Bool {
        storage == .keychain && !signOutRequiresRetry && currentUser == nil
            && (token != nil || credentialsUnavailable)
    }
    private(set) var signOutRequiresRetry = false

    private let storage: AuthSessionStorage
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let serverURL: @MainActor () -> URL
    private let credentialStore: any AuthCredentialStorage
    private let restoreBarrier: any AuthRestoreBarrier
    private var boundSession: BoundAuthSession?
    private var credentialsUnavailable = false
    private var sessionRequiresSignIn = false

    init(
        storage: AuthSessionStorage = .keychain,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RedirectSafeTransport.data(for: $0)
        },
        serverURL: @escaping @MainActor () -> URL = { ServerConfig.baseURL },
        credentialStore: (any AuthCredentialStorage)? = nil,
        restoreBarrier: (any AuthRestoreBarrier)? = nil
    ) {
        self.storage = storage
        self.transport = transport
        self.serverURL = serverURL
        self.credentialStore = credentialStore ?? KeychainAuthCredentialStorage()
        self.restoreBarrier = restoreBarrier ?? FileAuthRestoreBarrier()
        guard storage == .keychain else { return }
        do {
            try loadSavedSession()
        } catch {
            reportRestoreFailure(error)
        }
    }

    func login(phoneNumber: String, pin: String, companyCode: String) async throws {
        guard !isLoading else { throw AuthError.loginInProgress }
        guard !isRestoringSession else { throw AuthError.restoreInProgress }
        guard !signOutRequiresRetry else { throw AuthError.secureSignOutIncomplete }
        let generation = sessionGeneration
        let server = serverURL()
        guard let identity = AuthServerIdentity.canonical(server),
              let url = AuthServerIdentity.endpoint("/api/auth/login", on: server) else {
            throw AuthError.invalidServer
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LoginRequest(phoneNumber: phoneNumber, pin: pin, companyCode: companyCode))

        try Task.checkCancellation()
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard sessionGeneration == generation, AuthServerIdentity.canonical(serverURL()) == identity else {
            throw AuthError.sessionChanged
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard http.statusCode == 200 else {
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.loginFailed(body?.error ?? "Login failed (HTTP \(http.statusCode))")
        }
        let responseBody = try JSONDecoder().decode(LoginResponse.self, from: data)
        let session = BoundAuthSession(
            version: 1, token: responseBody.token, server: identity, userId: responseBody.user.id)
        guard Self.isValid(session) else { throw AuthError.invalidResponse }

        if storage == .keychain {
            do {
                try restoreBarrier.activate()
                try credentialStore.save(session)
                _ = try credentialStore.removeLegacy()
                try restoreBarrier.clear()
            } catch {
                Log.error("Could not save the secure session: \(Log.describe(error))", logger: Log.auth)
                var barrierDurable = false
                do {
                    try restoreBarrier.activate()
                    barrierDurable = true
                } catch {
                    Log.error("Could not protect the failed sign-in: \(Log.describe(error))", logger: Log.auth)
                }
                var credentialRemoved = false
                if !barrierDurable {
                    do {
                        try credentialStore.remove()
                        _ = try credentialStore.removeLegacy()
                        credentialRemoved = true
                    } catch {
                        Log.error("Could not remove the failed sign-in: \(Log.describe(error))", logger: Log.auth)
                    }
                }
                signOutRequiresRetry = true
                guard barrierDurable || credentialRemoved else {
                    throw AuthError.secureStorageCleanupIncomplete
                }
                throw AuthError.secureStorageFailed
            }
        }
        boundSession = session
        token = session.token
        currentUser = responseBody.user
        credentialsUnavailable = false
        sessionRequiresSignIn = false
    }

    func fetchMe() async throws {
        guard let token else { throw AuthError.notAuthenticated }
        let generation = sessionGeneration
        let server = serverURL()
        guard let identity = AuthServerIdentity.canonical(server),
              let url = AuthServerIdentity.endpoint("/api/auth/me", on: server) else {
            throw AuthError.invalidServer
        }
        if storage == .keychain || boundSession != nil {
            guard let boundSession, boundSession.token == token, boundSession.server == identity else {
                throw AuthError.sessionChanged
            }
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        try Task.checkCancellation()
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard sessionGeneration == generation, self.token == token,
              AuthServerIdentity.canonical(serverURL()) == identity else {
            throw AuthError.sessionChanged
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            logout()
            throw AuthError.tokenExpired
        }
        guard http.statusCode == 200 else { throw AuthError.restoreUnavailable }
        let user = try JSONDecoder().decode(MeResponse.self, from: data).user
        if let boundSession, boundSession.userId != user.id { throw AuthError.identityMismatch }
        currentUser = user
    }

    func restoreSavedSession() async {
        guard storage == .keychain, !isRestoringSession, !isLoading, currentUser == nil,
              !signOutRequiresRetry, !sessionRequiresSignIn else { return }
        isRestoringSession = true
        defer { isRestoringSession = false }
        var restorationGeneration = sessionGeneration
        let restorationServer = AuthServerIdentity.canonical(serverURL())
        do {
            try Task.checkCancellation()
            if token == nil { try loadSavedSession() }
            guard token != nil else { return }
            restorationGeneration = sessionGeneration
            try await fetchMe()
            errorMessage = nil
        } catch AuthError.tokenExpired {
            if errorMessage == nil { errorMessage = AuthError.tokenExpired.errorDescription }
        } catch is CancellationError {
            Log.debug("Saved session restoration was cancelled", logger: Log.auth)
        } catch {
            guard !Task.isCancelled else {
                Log.debug("Saved session restoration was cancelled", logger: Log.auth)
                return
            }
            guard sessionGeneration == restorationGeneration,
                  AuthServerIdentity.canonical(serverURL()) == restorationServer else {
                Log.error("Saved session changed during restoration", logger: Log.auth)
                return
            }
            if case AuthError.identityMismatch = error {
                Log.error("The restored account did not match its saved identity", logger: Log.auth)
                logout()
                if !signOutRequiresRetry {
                    sessionRequiresSignIn = true
                    errorMessage = AuthError.identityMismatch.errorDescription
                }
            } else {
                reportRestoreFailure(error)
            }
        }
    }

    func logout() {
        sessionGeneration = UUID()
        token = nil
        currentUser = nil
        boundSession = nil
        credentialsUnavailable = false
        sessionRequiresSignIn = false
        guard storage == .keychain else { return }
        var barrierDurable = false
        do {
            try restoreBarrier.activate()
            barrierDurable = true
        } catch {
            Log.error("Could not protect sign-out recovery: \(Log.describe(error))", logger: Log.auth)
        }
        do {
            try credentialStore.remove()
            _ = try credentialStore.removeLegacy()
            try restoreBarrier.clear()
            signOutRequiresRetry = false
            errorMessage = nil
        } catch {
            Log.error("Could not finish secure sign-out: \(Log.describe(error))", logger: Log.auth)
            signOutRequiresRetry = true
            errorMessage = barrierDurable
                ? "Secure sign-out needs a retry. The saved session is blocked until cleanup succeeds."
                : "Sign-out could not be saved. Your session may return if you close the app. Retry now."
        }
    }

    func authenticatedRequest(for url: URL, method: String = "GET") throws -> URLRequest {
        let snapshot = try authenticatedSnapshot()
        guard AuthServerIdentity.contains(url, server: snapshot.server) else {
            throw AuthError.sessionChanged
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func authenticatedSnapshot() throws -> AuthenticatedSessionSnapshot {
        guard let token, let currentUser, let boundSession,
              let server = AuthServerIdentity.canonical(serverURL()),
              boundSession.token == token, boundSession.userId == currentUser.id,
              boundSession.server == server else { throw AuthError.sessionChanged }
        return AuthenticatedSessionSnapshot(
            generation: sessionGeneration, token: token, userId: currentUser.id, server: server)
    }

    func isCurrent(_ snapshot: AuthenticatedSessionSnapshot) -> Bool {
        sessionGeneration == snapshot.generation && token == snapshot.token
            && currentUser?.id == snapshot.userId
            && boundSession?.token == snapshot.token && boundSession?.userId == snapshot.userId
            && boundSession?.server == snapshot.server
            && AuthServerIdentity.canonical(serverURL()) == snapshot.server
    }

    private func updateMemoryBinding() {
        guard storage == .memory else { return }
        guard let token, let currentUser, let server = AuthServerIdentity.canonical(serverURL()) else {
            boundSession = nil
            return
        }
        boundSession = BoundAuthSession(version: 1, token: token, server: server, userId: currentUser.id)
    }

    private func loadSavedSession() throws {
        if try restoreBarrier.isActive() {
            signOutRequiresRetry = true
            try credentialStore.remove()
            _ = try credentialStore.removeLegacy()
            try restoreBarrier.clear()
            signOutRequiresRetry = false
            credentialsUnavailable = false
            errorMessage = "Your previous sign-out is complete. Please sign in."
            return
        }
        guard let session = try credentialStore.load() else {
            if try credentialStore.removeLegacy() {
                errorMessage = "For security, please sign in again."
            }
            credentialsUnavailable = false
            return
        }
        guard Self.isValid(session) else { throw CredentialStoreError.invalidRecord }
        guard AuthServerIdentity.canonical(serverURL()) == session.server else {
            errorMessage = "The server changed. Sign in again before continuing."
            credentialsUnavailable = false
            return
        }
        boundSession = session
        token = session.token
        credentialsUnavailable = false
    }

    private func reportRestoreFailure(_ error: any Error) {
        Log.error("Could not restore the secure session: \(Log.describe(error))", logger: Log.auth)
        if signOutRequiresRetry {
            errorMessage = "Secure sign-out needs a retry. Unlock this device and retry sign-out."
        } else if error as? CredentialStoreError == .unavailable {
            credentialsUnavailable = true
            errorMessage = "Unlock this device to restore your saved session."
        } else if error is AuthError || error is URLError {
            errorMessage = "The saved session couldn't be verified. Check your connection and retry."
        } else {
            errorMessage = "The saved session couldn't be read securely. Sign in again."
        }
    }

    private static func isValid(_ session: BoundAuthSession) -> Bool {
        guard session.version == 1, !session.token.isEmpty, !session.userId.isEmpty,
              !session.token.contains("\r"), !session.token.contains("\n"),
              let server = URL(string: session.server),
              AuthServerIdentity.canonical(server) == session.server else { return false }
        return true
    }
}

nonisolated enum AuthError: LocalizedError, Equatable {
    case invalidResponse
    case loginFailed(String)
    case notAuthenticated
    case tokenExpired
    case sessionChanged
    case loginInProgress
    case restoreInProgress
    case invalidServer
    case secureStorageFailed
    case secureStorageCleanupIncomplete
    case secureSignOutIncomplete
    case restoreUnavailable
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid server response"
        case .loginFailed(let message): message
        case .notAuthenticated: "Not authenticated"
        case .tokenExpired: "Session expired — please log in again"
        case .sessionChanged: "Your session changed. Please try again."
        case .loginInProgress: "Sign-in is already in progress."
        case .restoreInProgress: "Your saved session is being checked."
        case .invalidServer: "Use a valid HTTPS server address."
        case .secureStorageFailed: "The session couldn't be stored securely. Please try again."
        case .secureStorageCleanupIncomplete:
            "Sign-in didn't finish, but its saved session may return. Retry secure sign-out before closing the app."
        case .secureSignOutIncomplete: "Finish secure sign-out before signing in again."
        case .restoreUnavailable: "The saved session couldn't be verified. Check your connection and retry."
        case .identityMismatch: "The saved account no longer matches the server. Sign in again."
        }
    }
}

nonisolated struct ErrorResponse: Codable {
    let error: String?
    let message: String?
}
