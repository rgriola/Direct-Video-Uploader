import Foundation
import Synchronization
import Testing
@testable import DirectVideoUploader

struct OriginalUploadAPITests {
    private let sessionId = "e406c53a-577f-4bb0-a985-b8d119984d8e"
    private let signature = String(repeating: "a", count: 64)
    private let expires: Int64 = 2_000_000_000

    private func signed(_ url: String, number: Int = 1, size: Int64 = 15) -> OriginalUploadSignedPart {
        OriginalUploadSignedPart(
            url: url, partNumber: number, sizeBytes: size,
            expiresAt: DVUDateFormatting.isoString(from: Date(timeIntervalSince1970: TimeInterval(expires))))
    }

    private var path: String { "/api/upload-sessions/\(sessionId)/parts/1" }
    private var query: String { "expires=\(expires)&signature=\(signature)" }
    private var now: Date { Date(timeIntervalSince1970: TimeInterval(expires - 60)) }
    private var sessionExpiry: Date { Date(timeIntervalSince1970: TimeInterval(expires + 60)) }

    @MainActor
    private func prepareJob(
        access: OriginalUploadAccess, directory: URL, assetId: String? = nil, sessionId: String? = nil
    ) async throws -> (OriginalUploadJournal, OriginalUploadJob) {
        let source = directory.appendingPathComponent("video.mov")
        try Data("native original".utf8).write(to: source)
        let journal = OriginalUploadJournal(directory: directory.appendingPathComponent("journal"))
        var job = try await journal.prepare(
            id: UUID(), source: source, fileName: "video.mov",
            metadata: VideoMetadata(
                duration: 1, resolution: "1920x1080", codec: "HEVC", orientation: "landscape",
                deviceModel: "iPhone", osVersion: "iOS", capturedAt: nil,
                gpsLat: nil, gpsLon: nil, gpsAltitude: nil),
            photoIdentifier: nil, transcribe: false, access: access)
        job.state = .reserving
        job = try journal.update(job, access: access)
        if let assetId {
            job.assetId = assetId
            job = try journal.update(job, access: access)
        }
        if let sessionId {
            job.sessionId = sessionId
            job.state = .uploading
            job = try journal.update(job, access: access)
        }
        return (journal, job)
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("original-api-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanup(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove the upload API test directory: \(Log.describe(error))")
        }
    }

    @Test
    func acceptsOnlyAValidatedIsolatedHTTPSOrigin() throws {
        let valid = try OriginalUploadURL.origin(
            URL(string: "https://isolated.example.test:8443/")!,
            forbiddenHosts: ["dev.ms-fixer.com", "ms-fixer.com"],
            allowedOrigins: ["https://isolated.example.test:8443"])
        #expect(valid.absoluteString == "https://isolated.example.test:8443")
        for value in [
            "http://isolated.example.test",
            "https://dev.ms-fixer.com",
            "https://dev.ms-fixer.com.",
            "https://isolated.example.test",
            "https://isolated.example.test:9443",
            "https://user:password@isolated.example.test",
            "https://isolated.example.test/api",
            "https://isolated.example.test/?token=secret",
            "https://isolated.example.test/#fragment",
        ] {
            #expect(throws: OriginalUploadAPIError.invalidOrigin) {
                try OriginalUploadURL.origin(
                    URL(string: value)!, forbiddenHosts: ["dev.ms-fixer.com", "ms-fixer.com"],
                    allowedOrigins: ["https://isolated.example.test:8443"])
            }
        }
    }

    @Test
    func resolvesOnlyTheExpectedRelativeSignedPartRoute() throws {
        let origin = URL(string: "https://isolated.example.test:8443")!
        let result = try OriginalUploadURL.signedPart(
            signed("\(path)?\(query)"), origin: origin, sessionId: sessionId,
            partNumber: 1, expectedSize: 15, sessionExpiry: sessionExpiry, now: now)
        #expect(result.host == "isolated.example.test")
        #expect(result.port == 8443)
        #expect(result.path == path)

        for value in [
            "https://other.example.test\(path)?\(query)",
            "//other.example.test\(path)?\(query)",
            "\(path)/../2?\(query)",
            "/api/upload-sessions/\(sessionId)/parts/2?\(query)",
            "\(path)?\(query)&signature=\(signature)",
            "\(path)?expires=\(expires)&signature=bad",
            "\(path)?\(query)#fragment",
        ] {
            #expect(throws: OriginalUploadAPIError.invalidCapability) {
                try OriginalUploadURL.signedPart(
                    signed(value), origin: origin, sessionId: sessionId,
                    partNumber: 1, expectedSize: 15, sessionExpiry: sessionExpiry, now: now)
            }
        }
        #expect(throws: OriginalUploadAPIError.invalidCapability) {
            try OriginalUploadURL.signedPart(
                signed("\(path)?\(query)", size: 14), origin: origin,
                sessionId: sessionId, partNumber: 1, expectedSize: 15,
                sessionExpiry: sessionExpiry, now: now)
        }
        for (clock, expiry) in [
            (Date(timeIntervalSince1970: TimeInterval(expires)), sessionExpiry),
            (Date(timeIntervalSince1970: TimeInterval(expires - 331)), sessionExpiry),
            (now, Date(timeIntervalSince1970: TimeInterval(expires - 1))),
        ] {
            #expect(throws: OriginalUploadAPIError.invalidCapability) {
                try OriginalUploadURL.signedPart(
                    signed("\(path)?\(query)"), origin: origin, sessionId: sessionId,
                    partNumber: 1, expectedSize: 15, sessionExpiry: expiry, now: clock)
            }
        }
    }

    @Test
    func assetUploadModeFailsClosedForUnexpectedValues() throws {
        let decoder = JSONDecoder()
        let original = try decoder.decode(
            Asset.self, from: Data(#"{"id":"asset","status":"UPLOADING","uploadMode":"ORIGINAL"}"#.utf8))
        let unexpected = try decoder.decode(
            Asset.self, from: Data(#"{"id":"asset","status":"UPLOADING","uploadMode":"future"}"#.utf8))
        let missing = try decoder.decode(
            Asset.self, from: Data(#"{"id":"asset","status":"UPLOADING"}"#.utf8))
        let mux = try decoder.decode(
            Asset.self, from: Data(#"{"id":"asset","status":"UPLOADING","uploadMode":"MUX"}"#.utf8))
        #expect(original.uploadMode == .original)
        #expect(unexpected.uploadMode == .unknown)
        #expect(missing.uploadMode == nil)
        #expect(!original.permitsDirectMuxRetry)
        #expect(!unexpected.permitsDirectMuxRetry)
        #expect(!missing.permitsDirectMuxRetry)
        #expect(mux.permitsDirectMuxRetry)
    }

    @Test
    func rejectsServerPartWithDifferentBytesEvenWhenSizeMatches() throws {
        let scope = try #require(PendingFormScope(
            userId: "user-1", serverURL: URL(string: "https://isolated.example.test")!))
        let fingerprint = VideoContentFingerprint(sha256: String(repeating: "a", count: 64), byteCount: 15)
        let manifest = OriginalUploadManifest(
            fingerprint: fingerprint, partSize: OriginalUploadFiles.maximumPartSize, parts: [fingerprint])
        let assetId = UUID().uuidString
        let job = OriginalUploadJob(
            id: UUID(), incarnation: UUID(), scope: scope, mode: .original, fileName: "video.mov", manifest: manifest,
            metadata: VideoMetadata(
                duration: 1, resolution: "1920x1080", codec: "HEVC", orientation: "landscape",
                deviceModel: "iPhone", osVersion: "iOS", capturedAt: nil,
                gpsLat: nil, gpsLon: nil, gpsAltitude: nil),
            photoIdentifier: nil, transcribe: false, createdAt: Date(), revision: 1,
            assetId: assetId, sessionId: sessionId, state: .uploading, attempts: [])
        let session = OriginalUploadServerSession(
            id: sessionId, assetId: assetId, clipId: UUID().uuidString, status: .open,
            expectedSizeBytes: "15", expectedSha256: fingerprint.sha256,
            partSizeBytes: OriginalUploadFiles.maximumPartSize, partCount: 1,
            expiresAt: DVUDateFormatting.isoString(from: Date()), completedAt: nil,
            parts: [OriginalUploadServerPart(
                partNumber: 1, sizeBytes: "15", sha256: String(repeating: "b", count: 64))])
        #expect(throws: OriginalUploadAPIError.partMismatch) {
            try session.validate(for: job)
        }
        #expect(throws: OriginalUploadAPIError.partMismatch) {
            try session.validateForRecovery(for: job)
        }
        for status in [OriginalUploadServerSession.Status.aborted, .expired] {
            let ended = OriginalUploadServerSession(
                id: session.id, assetId: session.assetId, clipId: session.clipId, status: status,
                expectedSizeBytes: session.expectedSizeBytes, expectedSha256: session.expectedSha256,
                partSizeBytes: session.partSizeBytes, partCount: session.partCount,
                expiresAt: session.expiresAt, completedAt: nil, parts: session.parts)
            try ended.validateForRecovery(for: job)
            #expect(throws: OriginalUploadAPIError.partMismatch) { try ended.validate(for: job) }
        }
    }

    @Test
    @MainActor
    func signedCapabilityRemainsBoundToTheSigningSessionAndOrigin() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let otherServer = URL(string: "https://other.example.test")!
        func makeAuth(userId: String, server: URL) -> AuthService {
            let auth = AuthService(storage: .memory, serverURL: { server })
            auth.token = "test-token"
            auth.currentUser = User(
                id: userId, phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
                status: "ACTIVE", companyCode: nil, companyName: nil)
            return auth
        }
        func makeAccess(_ auth: AuthService) throws -> OriginalUploadAccess {
            try OriginalUploadAccess(
                auth: auth, allowedOrigins: ["https://isolated.example.test", "https://other.example.test"])
        }
        let auth = makeAuth(userId: "user-1", server: server)
        let access = try makeAccess(auth)
        let assetId = UUID().uuidString
        let (journal, job) = try await prepareJob(
            access: access, directory: directory, assetId: assetId, sessionId: sessionId)
        let fingerprint = job.fingerprint
        let now = Date()
        let expiry = Int64(now.timeIntervalSince1970) + 60
        let session = OriginalUploadServerSession(
            id: sessionId, assetId: assetId, clipId: UUID().uuidString, status: .open,
            expectedSizeBytes: "15", expectedSha256: fingerprint.sha256,
            partSizeBytes: OriginalUploadFiles.maximumPartSize, partCount: 1,
            expiresAt: DVUDateFormatting.isoString(from: Date(timeIntervalSince1970: TimeInterval(expiry + 60))),
            completedAt: nil, parts: [])
        let response = try JSONSerialization.data(withJSONObject: [
            "url": "\(path)?expires=\(expiry)&signature=\(signature)",
            "partNumber": 1,
            "sizeBytes": 15,
            "expiresAt": DVUDateFormatting.isoString(from: Date(timeIntervalSince1970: TimeInterval(expiry))),
        ])
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let capability = try await api.sign(for: job, session: session, partNumber: 1)
        let part = OriginalUploadPart(
            url: URL(fileURLWithPath: "/nonexistent-test-part"), number: 1, fingerprint: fingerprint)
        try capability.require(job: job, part: part, access: access, now: now)

        for replacement in [
            try makeAccess(makeAuth(userId: "user-1", server: server)),
            try makeAccess(makeAuth(userId: "user-2", server: server)),
            try makeAccess(makeAuth(userId: "user-1", server: otherServer)),
        ] {
            #expect(throws: OriginalUploadAPIError.invalidCapability) {
                try capability.require(job: job, part: part, access: replacement, now: now)
            }
        }
        let replacementJob = OriginalUploadJob(
            id: job.id, incarnation: UUID(), scope: job.scope, mode: job.mode,
            fileName: job.fileName, manifest: job.manifest, metadata: job.metadata,
            photoIdentifier: job.photoIdentifier, transcribe: job.transcribe,
            createdAt: job.createdAt, revision: job.revision, assetId: job.assetId,
            sessionId: job.sessionId, state: job.state, attempts: job.attempts)
        #expect(throws: OriginalUploadAPIError.invalidCapability) {
            try capability.require(job: replacementJob, part: part, access: access, now: now)
        }
        #expect(throws: OriginalUploadAPIError.invalidCapability) {
            try capability.require(
                job: job, part: part, access: access,
                now: Date(timeIntervalSince1970: TimeInterval(expiry)))
        }
    }

    @Test
    @MainActor
    func rejectsResponseAfterTheAuthenticatedSessionChanges() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(
            auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let (journal, job) = try await prepareJob(access: access, directory: directory)
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            await MainActor.run { auth.logout() }
            return (
                Data(),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        })

        await #expect(throws: OriginalUploadAPIError.sessionChanged) {
            try await api.reserve(job)
        }
        #expect(!access.isCurrent)
    }

    @Test
    @MainActor
    func transportFailureAfterSessionChangeReportsTheSessionChange() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(
            auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let (journal, job) = try await prepareJob(access: access, directory: directory)
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { _ in
            await MainActor.run { auth.logout() }
            throw URLError(.timedOut)
        })
        await #expect(throws: OriginalUploadAPIError.sessionChanged) {
            try await api.reserve(job)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func transportFailureAfterCancellationReportsTheChangedJob() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(
            auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let (journal, job) = try await prepareJob(access: access, directory: directory)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish() }
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { _ in
            entered.continuation.yield()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            throw URLError(.timedOut)
        })
        let request = Task { try await api.reserve(job) }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        _ = try journal.requestCancellation(for: job, access: access)
        release.continuation.yield()
        await #expect(throws: OriginalUploadStorageError.staleJob) { try await request.value }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func transportFailureAfterTaskCancellationRemainsCancellation() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(
            auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let (journal, job) = try await prepareJob(access: access, directory: directory)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish() }
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { _ in
            entered.continuation.yield()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            throw URLError(.timedOut)
        })
        let request = Task { try await api.reserve(job) }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        request.cancel()
        release.continuation.yield()
        await #expect(throws: CancellationError.self) { try await request.value }
    }

    @Test
    @MainActor
    func staleJobCannotStartRequestsAfterCancellation() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(
            auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let assetId = UUID().uuidString
        let (journal, job) = try await prepareJob(
            access: access, directory: directory, assetId: assetId, sessionId: sessionId)
        let session = OriginalUploadServerSession(
            id: sessionId, assetId: assetId, clipId: UUID().uuidString, status: .open,
            expectedSizeBytes: String(job.fingerprint.byteCount),
            expectedSha256: job.fingerprint.sha256, partSizeBytes: OriginalUploadFiles.maximumPartSize,
            partCount: 1, expiresAt: DVUDateFormatting.isoString(from: Date().addingTimeInterval(60)),
            completedAt: nil, parts: [])
        let sent = Mutex(0)
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            sent.withLock { $0 += 1 }
            return (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        })
        let cancelled = try journal.requestCancellation(for: job, access: access)
        await #expect(throws: OriginalUploadStorageError.staleJob) {
            try await api.createSession(for: job)
        }
        await #expect(throws: OriginalUploadStorageError.staleJob) {
            try await api.sign(for: job, session: session, partNumber: 1)
        }
        await #expect(throws: OriginalUploadStorageError.staleJob) {
            try await api.complete(job)
        }
        #expect(sent.withLock { $0 } == 0)
        try await api.abort(cancelled)
        #expect(sent.withLock { $0 } == 1)
    }
}
