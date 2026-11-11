import Foundation
import Testing
@testable import DirectVideoUploader

@MainActor
private final class InMemoryCredentialStore: AuthCredentialStorage {
    var session: BoundAuthSession?
    var hasLegacy = false
    var loadError: CredentialStoreError?
    var saveError: CredentialStoreError?
    var removeError: CredentialStoreError?
    var legacyError: CredentialStoreError?
    var operations: [String] = []

    func load() throws -> BoundAuthSession? {
        operations.append("load")
        if let loadError { throw loadError }
        return session
    }

    func save(_ session: BoundAuthSession) throws {
        operations.append("save")
        if let saveError { throw saveError }
        self.session = session
    }

    func remove() throws {
        operations.append("remove")
        if let removeError { throw removeError }
        session = nil
    }

    func removeLegacy() throws -> Bool {
        operations.append("removeLegacy")
        if let legacyError { throw legacyError }
        let existed = hasLegacy
        hasLegacy = false
        return existed
    }
}

@MainActor
private final class InMemoryRestoreBarrier: AuthRestoreBarrier {
    var active = false
    var activationError: CredentialStoreError?
    var clearErrorAfterRemoval: CredentialStoreError?
    var failActivationAfterFailedClear = false
    var operations: [String] = []

    func isActive() throws -> Bool {
        operations.append("isActive")
        return active
    }

    func activate() throws {
        operations.append("activate")
        if let activationError { throw activationError }
        active = true
    }

    func clear() throws {
        operations.append("clear")
        active = false
        if let clearErrorAfterRemoval {
            if failActivationAfterFailedClear { activationError = .unavailable }
            throw clearErrorAfterRemoval
        }
    }
}

@MainActor
private final class AuthServerBox {
    var url = URL(string: "https://one.example.test")!
}

private actor AuthRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func respond(_ request: URLRequest, data: Data, status: Int = 200) -> (Data, URLResponse) {
        requests.append(request)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }

    func count() -> Int { requests.count }
}

@MainActor
struct AuthSessionTests {
    private let user = User(
        id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
        status: "ACTIVE", companyCode: nil, companyName: nil)

    private func session(server: String = "https://one.example.test") -> BoundAuthSession {
        BoundAuthSession(version: 1, token: "saved-token", server: server, userId: user.id)
    }

    private func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://one.example.test")!, statusCode: status,
            httpVersion: nil, headerFields: nil)!
    }

    @Test
    func removesUnboundLegacyCredentialWithoutSendingIt() async {
        let store = InMemoryCredentialStore()
        store.hasLegacy = true
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        let requests = AuthRequestRecorder()
        let auth = AuthService(
            transport: { request in await requests.respond(request, data: Data()) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)

        #expect(!store.hasLegacy)
        #expect(auth.token == nil)
        #expect(auth.errorMessage?.contains("sign in again") == true)
        await auth.restoreSavedSession()
        #expect(await requests.count() == 0)
    }

    @Test
    func defersLockedKeychainAndRestoresAfterUnlock() async throws {
        let store = InMemoryCredentialStore()
        store.session = session()
        store.loadError = .unavailable
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        let requests = AuthRequestRecorder()
        let payload = try JSONEncoder().encode(MeResponse(user: user))
        let auth = AuthService(
            transport: { request in await requests.respond(request, data: payload) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)

        #expect(auth.canRetrySavedSession)
        #expect(auth.token == nil)
        #expect(store.session != nil)
        #expect(!store.operations.contains("remove"))
        await auth.restoreSavedSession()
        #expect(await requests.count() == 0)

        store.loadError = nil
        await auth.restoreSavedSession()
        #expect(auth.currentUser?.id == user.id)
        #expect(try auth.authenticatedSnapshot().server == "https://one.example.test")
        #expect(await requests.count() == 1)
    }

    @Test
    func neverSendsAStoredTokenToAnotherServer() async throws {
        let store = InMemoryCredentialStore()
        store.session = session()
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        server.url = URL(string: "https://other.example.test")!
        let requests = AuthRequestRecorder()
        let payload = try JSONEncoder().encode(MeResponse(user: user))
        let auth = AuthService(
            transport: { request in await requests.respond(request, data: payload) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)

        await auth.restoreSavedSession()
        #expect(auth.token == nil)
        #expect(auth.errorMessage?.contains("server changed") == true)
        #expect(await requests.count() == 0)
        #expect(store.session != nil)

        server.url = URL(string: "https://one.example.test")!
        await auth.restoreSavedSession()
        #expect(auth.currentUser?.id == user.id)
        #expect(await requests.count() == 1)
    }

    @Test
    func rejectsHTTPBeforeSendingCredentials() async {
        let server = AuthServerBox()
        server.url = URL(string: "http://127.0.0.1:3000")!
        let requests = AuthRequestRecorder()
        let auth = AuthService(
            storage: .memory,
            transport: { request in await requests.respond(request, data: Data()) },
            serverURL: { server.url })

        await #expect(throws: AuthError.invalidServer) {
            try await auth.login(phoneNumber: "5550100", pin: "1111", companyCode: "TEST")
        }
        #expect(await requests.count() == 0)
        #expect(AuthServerIdentity.canonical(server.url) == nil)
    }

    @Test
    func authenticatedRequestsStayWithinTheValidatedServer() async throws {
        let store = InMemoryCredentialStore()
        store.session = session(server: "https://one.example.test/proxy")
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        server.url = URL(string: "https://one.example.test/proxy/")!
        let payload = try JSONEncoder().encode(MeResponse(user: user))
        let requests = AuthRequestRecorder()
        let auth = AuthService(
            transport: { request in await requests.respond(request, data: payload) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)

        #expect(throws: AuthError.sessionChanged) {
            try auth.authenticatedRequest(for: URL(string: "https://one.example.test/proxy/api/assets")!)
        }
        await auth.restoreSavedSession()
        let request = try auth.authenticatedRequest(
            for: URL(string: "https://one.example.test:443/proxy/api/assets?limit=1")!)
        #expect(request.url?.host == "one.example.test")
        for unsafe in [
            "http://one.example.test/proxy/api/assets",
            "https://other.example.test/proxy/api/assets",
            "https://one.example.test/proxy-other/api/assets",
            "https://one.example.test/proxy/%2e%2e/api/assets",
            "https://one.example.test/proxy/api/assets#fragment",
        ] {
            #expect(throws: AuthError.sessionChanged) {
                try auth.authenticatedRequest(for: URL(string: unsafe)!)
            }
        }
        let snapshot = try auth.authenticatedSnapshot()
        server.url = URL(string: "https://other.example.test/proxy")!
        #expect(!auth.isCurrent(snapshot))
        #expect(throws: AuthError.sessionChanged) {
            try auth.authenticatedRequest(for: URL(string: "https://other.example.test/proxy/api/assets")!)
        }
    }

    @Test
    func wrongRestoredAccountRequiresANewSignIn() async throws {
        let store = InMemoryCredentialStore()
        store.session = session()
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        let other = User(
            id: "different-user", phoneNumber: "5550100", name: "Other", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let payload = try JSONEncoder().encode(MeResponse(user: other))
        let requests = AuthRequestRecorder()
        let auth = AuthService(
            transport: { request in await requests.respond(request, data: payload) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)

        await auth.restoreSavedSession()
        #expect(auth.token == nil)
        #expect(auth.currentUser == nil)
        #expect(store.session == nil)
        #expect(!barrier.active)
        #expect(!auth.signOutRequiresRetry)
        #expect(auth.errorMessage == AuthError.identityMismatch.errorDescription)
        await auth.restoreSavedSession()
        #expect(await requests.count() == 1)
    }

    @Test
    func failedSaveDoesNotInstallSessionAndRequiresCleanup() async throws {
        let store = InMemoryCredentialStore()
        store.saveError = .unavailable
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        let payload = try JSONEncoder().encode(LoginResponse(token: "new-token", user: user))
        let requests = AuthRequestRecorder()
        let auth = AuthService(
            transport: { request in await requests.respond(request, data: payload) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)

        await #expect(throws: AuthError.secureStorageFailed) {
            try await auth.login(phoneNumber: "5550100", pin: "1111", companyCode: "TEST")
        }
        #expect(auth.token == nil)
        #expect(auth.currentUser == nil)
        #expect(auth.signOutRequiresRetry)
        #expect(barrier.active)
        await #expect(throws: AuthError.secureSignOutIncomplete) {
            try await auth.login(phoneNumber: "5550100", pin: "1111", companyCode: "TEST")
        }
        store.saveError = nil
        auth.logout()
        #expect(!auth.signOutRequiresRetry)
        #expect(!barrier.active)
        try await auth.login(phoneNumber: "5550100", pin: "1111", companyCode: "TEST")
        #expect(store.session?.userId == user.id)
        #expect(store.session?.server == "https://one.example.test")
        #expect(auth.currentUser?.id == user.id)
    }

    @Test
    func failedBarrierClearReestablishesProtectionBeforeRelaunch() async throws {
        let store = InMemoryCredentialStore()
        let barrier = InMemoryRestoreBarrier()
        barrier.clearErrorAfterRemoval = .unavailable
        let server = AuthServerBox()
        let payload = try JSONEncoder().encode(LoginResponse(token: "new-token", user: user))
        let requests = AuthRequestRecorder()
        let auth = AuthService(
            transport: { request in await requests.respond(request, data: payload) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)

        await #expect(throws: AuthError.secureStorageFailed) {
            try await auth.login(phoneNumber: "5550100", pin: "1111", companyCode: "TEST")
        }
        #expect(auth.token == nil)
        #expect(auth.signOutRequiresRetry)
        #expect(store.session != nil)
        #expect(barrier.active)
        barrier.clearErrorAfterRemoval = nil
        let relaunched = AuthService(
            transport: { request in await requests.respond(request, data: payload) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)
        #expect(relaunched.token == nil)
        #expect(store.session == nil)
        #expect(!barrier.active)
        #expect(await requests.count() == 1)
    }

    @Test
    func warnsIfFailedSignInCannotBeBlockedOrRemoved() async throws {
        let store = InMemoryCredentialStore()
        store.removeError = .unavailable
        let barrier = InMemoryRestoreBarrier()
        barrier.clearErrorAfterRemoval = .unavailable
        barrier.failActivationAfterFailedClear = true
        let server = AuthServerBox()
        let payload = try JSONEncoder().encode(LoginResponse(token: "new-token", user: user))
        let requests = AuthRequestRecorder()
        let auth = AuthService(
            transport: { request in await requests.respond(request, data: payload) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)

        await #expect(throws: AuthError.secureStorageCleanupIncomplete) {
            try await auth.login(phoneNumber: "5550100", pin: "1111", companyCode: "TEST")
        }
        #expect(auth.signOutRequiresRetry)
        #expect(!barrier.active)
        #expect(store.session != nil)
        #expect(AuthError.secureStorageCleanupIncomplete.errorDescription?.contains("may return") == true)
    }

    @Test
    func failedDeletionKeepsDurableBarrierUntilRelaunchCleanup() async {
        let store = InMemoryCredentialStore()
        store.session = session()
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        let requests = AuthRequestRecorder()
        let auth = AuthService(
            transport: { request in await requests.respond(request, data: Data()) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)
        store.removeError = .unavailable
        auth.logout()

        #expect(auth.signOutRequiresRetry)
        #expect(auth.token == nil)
        #expect(barrier.active)
        await auth.restoreSavedSession()
        #expect(await requests.count() == 0)

        let lockedRelaunch = AuthService(
            transport: { request in await requests.respond(request, data: Data()) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)
        #expect(lockedRelaunch.signOutRequiresRetry)
        #expect(lockedRelaunch.token == nil)
        #expect(barrier.active)
        store.removeError = nil
        lockedRelaunch.logout()
        #expect(!lockedRelaunch.signOutRequiresRetry)
        #expect(!barrier.active)
        #expect(store.session == nil)
        #expect(await requests.count() == 0)
    }

    @Test
    func warnsWhenNeitherSignOutBarrierNorDeletionCanBeSaved() async {
        let store = InMemoryCredentialStore()
        store.session = session()
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        let requests = AuthRequestRecorder()
        let auth = AuthService(
            transport: { request in await requests.respond(request, data: Data()) },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)
        barrier.activationError = .unavailable
        store.removeError = .unavailable
        auth.logout()

        #expect(auth.signOutRequiresRetry)
        #expect(auth.errorMessage?.contains("may return") == true)
        #expect(store.operations.contains("remove"))
        await auth.restoreSavedSession()
        #expect(auth.token == nil)
        #expect(await requests.count() == 0)
        barrier.activationError = nil
        store.removeError = nil
        auth.logout()
        #expect(store.session == nil)
        #expect(!barrier.active)
    }

    @Test
    func cancellationAfterLoginResponseDoesNotSaveOrInstallSession() async throws {
        let store = InMemoryCredentialStore()
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        let payload = try JSONEncoder().encode(LoginResponse(token: "new-token", user: user))
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let response = response()
        let auth = AuthService(
            transport: { _ in
                started.continuation.yield(())
                for await _ in release.stream { break }
                return (payload, response)
            },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)
        let task = Task {
            try await auth.login(phoneNumber: "5550100", pin: "1111", companyCode: "TEST")
        }
        defer { release.continuation.finish(); task.cancel() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        release.continuation.yield(())
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.session == nil)
        #expect(!store.operations.contains("save"))
        #expect(!barrier.active)
        #expect(auth.currentUser == nil)
    }

    @Test(arguments: [200, 401])
    func cancelledRestoreDoesNotApplyUserOrDeleteCredential(status: Int) async throws {
        let store = InMemoryCredentialStore()
        store.session = session()
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        let payload = try JSONEncoder().encode(MeResponse(user: user))
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let response = response(status)
        let auth = AuthService(
            transport: { _ in
                started.continuation.yield(())
                for await _ in release.stream { break }
                return (payload, response)
            },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)
        let task = Task { await auth.restoreSavedSession() }
        defer { release.continuation.finish(); task.cancel() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        release.continuation.yield(())
        await task.value
        #expect(auth.currentUser == nil)
        #expect(auth.token == "saved-token")
        #expect(store.session != nil)
        #expect(!store.operations.contains("remove"))
    }

    @Test
    func cancelledRestoreSuppressesTransportCancellationError() async {
        let store = InMemoryCredentialStore()
        store.session = session()
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let auth = AuthService(
            transport: { _ in
                started.continuation.yield(())
                for await _ in release.stream { break }
                throw URLError(.cancelled)
            },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)
        let task = Task { await auth.restoreSavedSession() }
        defer { release.continuation.finish(); task.cancel() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        release.continuation.yield(())
        await task.value
        #expect(auth.errorMessage == nil)
        #expect(auth.currentUser == nil)
        #expect(store.session != nil)
    }

    @Test
    func staleRestoreFailureCannotReplaceSignOutWarning() async {
        let store = InMemoryCredentialStore()
        store.session = session()
        let barrier = InMemoryRestoreBarrier()
        let server = AuthServerBox()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let auth = AuthService(
            transport: { _ in
                started.continuation.yield(())
                for await _ in release.stream { break }
                throw URLError(.notConnectedToInternet)
            },
            serverURL: { server.url }, credentialStore: store, restoreBarrier: barrier)
        let task = Task { await auth.restoreSavedSession() }
        defer { release.continuation.finish(); task.cancel() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        barrier.activationError = .unavailable
        store.removeError = .unavailable
        auth.logout()
        let warning = auth.errorMessage
        release.continuation.yield(())
        await task.value
        #expect(auth.signOutRequiresRetry)
        #expect(auth.errorMessage == warning)
    }

    @Test
    func fileBarrierPersistsAndClearsItsMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-barrier-test-\(UUID().uuidString)", isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Could not remove the authentication test directory: \(Log.describe(error))")
            }
        }
        let barrier = FileAuthRestoreBarrier(directory: directory.appendingPathComponent("nested"))
        #expect(try !barrier.isActive())
        try barrier.activate()
        #expect(try barrier.isActive())
        try barrier.activate()
        try barrier.clear()
        #expect(try !barrier.isActive())
        try barrier.clear()
    }
}
