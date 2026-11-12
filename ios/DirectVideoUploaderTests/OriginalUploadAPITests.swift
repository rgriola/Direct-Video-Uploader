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
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"), taskFence: OriginalUploadTaskFence())
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

    private func nonUTF8JSON(_ json: String) throws -> [Data] {
        let encodings: [(String.Encoding, [UInt8])] = [
            (.utf16BigEndian, [0xFE, 0xFF]),
            (.utf16LittleEndian, [0xFF, 0xFE]),
            (.utf32BigEndian, [0x00, 0x00, 0xFE, 0xFF]),
            (.utf32LittleEndian, [0xFF, 0xFE, 0x00, 0x00]),
        ]
        return try encodings.flatMap { encoding, bom in
            let data = try #require(json.data(using: encoding))
            return [data, Data(bom) + data]
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
        let responseString = try #require(String(data: response, encoding: .utf8))
        let duplicate = Data((String(responseString.dropLast()) + #", "\u0070artNumber":1}"#).utf8)
        let ambiguous = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            (duplicate, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await ambiguous.sign(for: job, session: session, partNumber: 1)
        }
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
    func reservationRejectsAmbiguousJSONAndAcceptsUniqueNestedKeys() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let (journal, job) = try await prepareJob(access: access, directory: directory)
        let assetId = UUID().uuidString
        let asset = #"{"id":"\#(assetId)","status":"UPLOADING","uploadMode":"ORIGINAL"}"#

        func api(_ data: Data) throws -> OriginalUploadAPI {
            try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
            })
        }

        let valid = #"{"asset":\#(asset),"future":[{"name":"one"},{"name":"two"}],"literal":"comma, braces{} and quote: \""}"#
        #expect(try await api(Data(valid.utf8)).reserve(job).id == assetId)
        #expect(try await api(Data([0xEF, 0xBB, 0xBF]) + Data(valid.utf8)).reserve(job).id == assetId)
        let ambiguous = [
            #"{"asset":\#(asset),"asset":\#(asset)}"#,
            #"{"asset":{"id":"\#(assetId)","status":"UPLOADING","uploadMode":"ORIGINAL","\u0075ploadMode":"ORIGINAL"}}"#,
            #"{"asset":\#(asset),"future":[{"name":"one","n\u0061me":"two"}]}"#,
            #"{"asset":\#(asset),"future":{"\uD83D\uDE80":1,"\ud83d\ude80":2}}"#,
            #"{"asset":\#(asset),"future":{"\u00e9":1,"e\u0301":2}}"#,
            #"{"asset":\#(asset),"future":{"\uD800":1}}"#,
        ]
        for value in ambiguous {
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await api(Data(value.utf8)).reserve(job)
            }
        }
        for data in try nonUTF8JSON(valid) {
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await api(data).reserve(job)
            }
        }
        let fields = (0..<5_000).map { #""key\#($0)":0"# }.joined(separator: ",")
        let wide = Data(#"{"asset":\#(asset),"future":{\#(fields)}}"#.utf8)
        try #require(wide.count < 64 * 1024)
        #expect(try await api(wide).reserve(job).id == assetId)
        func nested(_ depth: Int) -> Data {
            let arrays = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
            return Data(#"{"asset":\#(asset),"future":\#(arrays)}"#.utf8)
        }
        #expect(try await api(nested(63)).reserve(job).id == assetId)
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api(nested(64)).reserve(job)
        }
    }

    @Test
    @MainActor
    func sessionRejectsDuplicateStateAndPartFields() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let assetId = UUID().uuidString
        let (journal, job) = try await prepareJob(
            access: access, directory: directory, assetId: assetId, sessionId: sessionId)
        let expiry = DVUDateFormatting.isoString(from: Date().addingTimeInterval(60))
        let digest = job.fingerprint.sha256
        let valid = """
            {"uploadSession":{"id":"\(sessionId)","assetId":"\(assetId)","clipId":"\(UUID().uuidString)",\
            "status":"OPEN","expectedSizeBytes":"15","expectedSha256":"\(digest)",\
            "partSizeBytes":\(OriginalUploadFiles.maximumPartSize),"partCount":1,"expiresAt":"\(expiry)",\
            "parts":[{"partNumber":1,"sizeBytes":"15","sha256":"\(digest)"}]}}
            """

        func api(_ body: String) throws -> OriginalUploadAPI {
            let data = Data(body.utf8)
            return try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        }

        #expect(try await api(valid).session(for: job).status == .open)
        let duplicateStatus = valid.replacingOccurrences(
            of: #""status":"OPEN""#, with: #""status":"OPEN","\u0073tatus":"OPEN""#)
        let duplicatePart = valid.replacingOccurrences(
            of: #""partNumber":1"#, with: #""partNumber":1,"partNumber":1"#)
        for value in [duplicateStatus, duplicatePart] {
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await api(value).session(for: job)
            }
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
    func cancellationFenceRequiresSavedCancellationAndRejectsLateResponses() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        let user = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        auth.currentUser = user
        let access = try OriginalUploadAccess(
            auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let (journal, job) = try await prepareJob(access: access, directory: directory)
        let recorded = Mutex<URLRequest?>(nil)
        let response = Data(#"{"assetId":null,"sessionIds":[]}"#.utf8)
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            recorded.withLock { $0 = request }
            return (response, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api.cancelIntent(for: job)
        }
        var unsaved = job
        unsaved.cancellationRequested = true
        await #expect(throws: OriginalUploadStorageError.staleJob) {
            try await api.cancelIntent(for: unsaved)
        }
        #expect(recorded.withLock { $0 == nil })
        let cancelled = try journal.requestCancellation(for: job, access: access)
        let receipt = try await api.cancelIntent(for: cancelled)
        #expect(receipt.assetId == nil)
        #expect(receipt.sessionIds.isEmpty)
        let request = try #require(recorded.withLock { $0 })
        #expect(request.httpMethod == "POST")
        #expect(request.url?.host == server.host)
        #expect(request.url?.path == "/api/assets/original-uploads/\(job.id.uuidString.lowercased())/cancel")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.httpBody == nil)

        let padded = response + Data(repeating: 0x20, count: 65_536 - response.count)
        let maximum = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            (padded, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await maximum.cancelIntent(for: cancelled) == receipt)
        let oversized = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            (padded + Data([0x20]), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await oversized.cancelIntent(for: cancelled)
        }
        let interrupted = try OriginalUploadAPI(access: access, journal: journal, transport: { _ in
            throw URLError(.dataLengthExceedsMaximum)
        })
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await interrupted.cancelIntent(for: cancelled)
        }
        let unexpectedStatus = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            (response, HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await unexpectedStatus.cancelIntent(for: cancelled)
        }
        for status in [401, 403, 404, 409, 410, 429, 503] {
            let rejected = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                (response, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            await #expect(throws: OriginalUploadAPIError.httpStatus(status)) {
                try await rejected.cancelIntent(for: cancelled)
            }
        }
        let malformed = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            (Data("{".utf8), HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: OriginalUploadAPIError.httpStatus(429)) {
            try await malformed.cancelIntent(for: cancelled)
        }
        let quota = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            (Data(#"{"code":"INTENT_CANCELLATION_QUOTA","error":"ignored"}"#.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60"])!)
        })
        await #expect(throws: OriginalUploadAPIError.cancellationQuota(retryAfterSeconds: 60)) {
            try await quota.cancelIntent(for: cancelled)
        }
        for header in ["", "0", "86401", "1.5", "-1"] {
            let invalidQuota = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                (Data(#"{"code":"INTENT_CANCELLATION_QUOTA"}"#.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": header])!)
            })
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await invalidQuota.cancelIntent(for: cancelled)
            }
        }
        let overflow = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            (Data(#"{"code":"INTENT_SESSION_LIMIT","error":"ignored"}"#.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: OriginalUploadAPIError.cancellationSessionLimit) {
            try await overflow.cancelIntent(for: cancelled)
        }
        for (status, code) in [
            (429, "INTENT_CANCELLATION_QUOTA"), (503, "INTENT_SESSION_LIMIT"),
        ] {
            let body = Data(#"{"code":"\#(code)","\u0063ode":"\#(code)"}"#.utf8)
            let ambiguous = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                (body, HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "60"])!)
            })
            await #expect(throws: OriginalUploadAPIError.httpStatus(status)) {
                try await ambiguous.cancelIntent(for: cancelled)
            }
        }
        #expect(try journal.read(id: job.id, access: access).cancellationRequested)

        let staleAPI = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            await MainActor.run {
                auth.logout()
                auth.token = "test-token"
                auth.currentUser = user
            }
            return (response, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: OriginalUploadAPIError.sessionChanged) {
            try await staleAPI.cancelIntent(for: cancelled)
        }
        let freshAccess = try OriginalUploadAccess(
            auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let saved = try journal.read(id: job.id, access: freshAccess)
        #expect(saved.cancellationRequested)
        let retry = try OriginalUploadAPI(access: freshAccess, journal: journal, transport: { request in
            (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await retry.cancelIntent(for: saved) == receipt)
    }

    @Test
    @MainActor
    func cancellationPagesPreserveIdentifiersAndBindContinuations() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        let user = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        auth.token = "test-token"
        auth.currentUser = user
        let access = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
        let (journal, job) = try await prepareJob(
            access: access, directory: directory, assetId: assetId, sessionId: sessionId)
        let ids = (1...100).map { String(format: "A1234567-0000-4000-8000-%012x", $0) }
        let cursor = try #require(ids.last)
        let first = try JSONSerialization.data(withJSONObject: [
            "assetId": assetId, "sessionIds": ids, "nextCursor": cursor,
        ])
        let secondIds = [cursor.lowercased(), sessionId]
        let second = try JSONSerialization.data(withJSONObject: [
            "assetId": assetId, "sessionIds": secondIds, "nextCursor": NSNull(),
        ])
        let requests = Mutex<[URLRequest]>([])
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            requests.withLock { $0.append(request) }
            return (request.url?.query == nil ? first : second, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: transport)

        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api.cancellationSessions(for: job)
        }
        var unsaved = job
        unsaved.cancellationRequested = true
        await #expect(throws: OriginalUploadStorageError.staleJob) {
            try await api.cancellationSessions(for: unsaved)
        }
        #expect(requests.withLock { $0.isEmpty })

        let cancelled = try journal.requestCancellation(for: job, access: access)
        let page = try await api.cancellationSessions(for: cancelled)
        #expect(page.assetId == assetId)
        #expect(page.sessionIds == ids)
        let continuation = try #require(page.continuation)
        let last = try await api.cancellationSessions(for: cancelled, continuation: continuation)
        #expect(last.sessionIds == secondIds)
        #expect(last.continuation == nil)
        let sent = requests.withLock { $0 }
        try #require(sent.count == 2)
        #expect(sent.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        #expect(sent[0].url?.path == "/api/assets/original-uploads/\(job.id.uuidString.lowercased())/sessions")
        #expect(sent[0].url?.query == nil)
        #expect(sent[1].url?.query == "after=\(cursor)")

        let (_, otherJob) = try await prepareJob(access: access, directory: directory)
        let otherCancelled = try journal.requestCancellation(for: otherJob, access: access)
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api.cancellationSessions(for: otherCancelled, continuation: continuation)
        }
        let updated = try journal.update(cancelled, access: access)
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api.cancellationSessions(for: updated, continuation: continuation)
        }
        #expect(requests.withLock { $0.count } == 2)

        let newPage = try await api.cancellationSessions(for: updated)
        let newContinuation = try #require(newPage.continuation)
        auth.logout()
        auth.token = "other-token"
        auth.currentUser = User(
            id: "user-2", phoneNumber: "5550101", name: "Other", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let otherAccess = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let otherAPI = try OriginalUploadAPI(access: otherAccess, journal: journal, transport: transport)
        await #expect(throws: OriginalUploadAPIError.sessionChanged) {
            try await otherAPI.cancellationSessions(for: updated, continuation: newContinuation)
        }
        auth.logout()
        auth.token = "test-token"
        auth.currentUser = user
        let freshAccess = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let freshJob = try journal.read(id: job.id, access: freshAccess)
        let freshAPI = try OriginalUploadAPI(access: freshAccess, journal: journal, transport: transport)
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await freshAPI.cancellationSessions(for: freshJob, continuation: newContinuation)
        }
        #expect(requests.withLock { $0.count } == 3)
        #expect(try journal.read(id: job.id, access: freshAccess).cancellationRequested)
    }

    @Test
    @MainActor
    func cancellationPagesRejectAmbiguousOrInconsistentResponses() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
        let (journal, job) = try await prepareJob(
            access: access, directory: directory, assetId: assetId, sessionId: sessionId)
        let cancelled = try journal.requestCancellation(for: job, access: access)
        let ids = (1...101).map { String(format: "A1234567-0000-4000-8000-%012x", $0) }

        func api(_ data: Data, status: Int = 200) throws -> OriginalUploadAPI {
            try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
        }
        func body(_ value: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: value)
        }
        let empty = try body(["assetId": NSNull(), "sessionIds": [], "nextCursor": NSNull()])
        let emptyPage = try await api(empty).cancellationSessions(for: cancelled)
        #expect(emptyPage.assetId == nil)
        #expect(emptyPage.sessionIds.isEmpty)
        #expect(emptyPage.continuation == nil)
        let boundaryIds = [
            "A1234567-0000-1000-9000-000000000001",
            "A1234567-0000-8000-a000-000000000002",
            "A1234567-0000-8000-B000-000000000003",
        ]
        let boundaryPage = try await api(body([
            "assetId": assetId, "sessionIds": boundaryIds, "nextCursor": NSNull(),
        ])).cancellationSessions(for: cancelled)
        #expect(boundaryPage.sessionIds == boundaryIds)
        let fullPage = try await api(body([
            "assetId": assetId, "sessionIds": Array(ids.prefix(100)), "nextCursor": NSNull(),
        ])).cancellationSessions(for: cancelled)
        #expect(fullPage.sessionIds.count == 100)
        #expect(fullPage.continuation == nil)

        let invalid: [Data] = try [
            body(["sessionIds": [], "nextCursor": NSNull()]),
            body(["assetId": assetId, "sessionIds": []]),
            body(["assetId": assetId, "sessionIds": [], "nextCursor": NSNull(), "extra": true]),
            body(["assetId": "invalid", "sessionIds": [], "nextCursor": NSNull()]),
            body(["assetId": assetId.uppercased(), "sessionIds": [], "nextCursor": NSNull()]),
            body(["assetId": NSNull(), "sessionIds": [sessionId], "nextCursor": NSNull()]),
            body(["assetId": assetId, "sessionIds": ["invalid"], "nextCursor": NSNull()]),
            body(["assetId": assetId, "sessionIds": ["A1234567-0000-0000-8000-000000000001"], "nextCursor": NSNull()]),
            body(["assetId": assetId, "sessionIds": ["A1234567-0000-4000-c000-000000000001"], "nextCursor": NSNull()]),
            body(["assetId": assetId, "sessionIds": [sessionId + "\0&after=invalid"], "nextCursor": NSNull()]),
            body(["assetId": assetId, "sessionIds": [sessionId, sessionId], "nextCursor": NSNull()]),
            body(["assetId": assetId, "sessionIds": ids, "nextCursor": NSNull()]),
            body(["assetId": assetId, "sessionIds": [], "nextCursor": sessionId]),
            body(["assetId": assetId, "sessionIds": [sessionId], "nextCursor": sessionId]),
            body(["assetId": assetId, "sessionIds": [sessionId], "nextCursor": ids[0]]),
            body(["assetId": assetId, "sessionIds": Array(ids.prefix(100)), "nextCursor": ids[98]]),
            body(["assetId": assetId, "sessionIds": Array(ids.prefix(100)), "nextCursor": "invalid"]),
        ] + [
            Data(#"{"assetId":"\#(assetId)","sessionIds":[],"nextCursor":null,"\u006eextCursor":null}"#.utf8),
            Data(repeating: 0x20, count: 65_537),
        ]
        for data in invalid {
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await api(data).cancellationSessions(for: cancelled)
            }
        }
        let (_, unassigned) = try await prepareJob(access: access, directory: directory)
        let unassignedCancelled = try journal.requestCancellation(for: unassigned, access: access)
        let embeddedNull = try body([
            "assetId": assetId + "\0invalid", "sessionIds": [], "nextCursor": NSNull(),
        ])
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api(embeddedNull).cancellationSessions(for: unassignedCancelled)
        }
        #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try OriginalUploadCancellationReceipt(
                assetId: assetId + "\0invalid", sessionIds: []).validate(for: unassignedCancelled)
        }
        for status in [401, 404, 429, 503] {
            await #expect(throws: OriginalUploadAPIError.httpStatus(status)) {
                try await api(empty, status: status).cancellationSessions(for: cancelled)
            }
        }
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api(empty, status: 201).cancellationSessions(for: cancelled)
        }

        let cursor = ids[99]
        let first = try body(["assetId": assetId, "sessionIds": Array(ids.prefix(100)), "nextCursor": cursor])
        let continuation = try #require(try await api(first).cancellationSessions(for: cancelled).continuation)
        let unassignedContinuation = try #require(
            try await api(first).cancellationSessions(for: unassignedCancelled).continuation)
        for data in try [
            body(["assetId": UUID().uuidString, "sessionIds": [], "nextCursor": NSNull()]),
            body(["assetId": NSNull(), "sessionIds": [], "nextCursor": NSNull()]),
        ] {
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await api(data).cancellationSessions(
                    for: unassignedCancelled, continuation: unassignedContinuation)
            }
        }
        let repeated = try body(["assetId": assetId, "sessionIds": [cursor], "nextCursor": NSNull()])
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api(repeated).cancellationSessions(for: cancelled, continuation: continuation)
        }
        #expect(try journal.read(id: job.id, access: access).cancellationRequested)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationPagesRejectCancelledOrStaleRequests() async throws {
        enum Change { case cancelTask, journal, signOut }
        for change in [Change.cancelTask, .journal, .signOut] {
            let directory = try fixture()
            defer { cleanup(directory) }
            let server = URL(string: "https://isolated.example.test")!
            let auth = AuthService(storage: .memory, serverURL: { server })
            auth.token = "test-token"
            auth.currentUser = User(
                id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
                status: "ACTIVE", companyCode: nil, companyName: nil)
            let access = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
            let (journal, job) = try await prepareJob(access: access, directory: directory)
            let cancelled = try journal.requestCancellation(for: job, access: access)
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            defer { entered.continuation.finish(); release.continuation.finish() }
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                entered.continuation.yield()
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
                return (Data(#"{"assetId":null,"sessionIds":[],"nextCursor":null}"#.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let request = Task { try await api.cancellationSessions(for: cancelled) }
            var iterator = entered.stream.makeAsyncIterator()
            try #require(await iterator.next() != nil)
            switch change {
            case .cancelTask: request.cancel()
            case .journal: _ = try journal.update(cancelled, access: access)
            case .signOut: auth.logout()
            }
            release.continuation.yield()
            switch change {
            case .cancelTask:
                await #expect(throws: CancellationError.self) { try await request.value }
            case .journal:
                await #expect(throws: OriginalUploadStorageError.staleJob) { try await request.value }
            case .signOut:
                await #expect(throws: OriginalUploadAPIError.sessionChanged) { try await request.value }
            }
        }
    }

    @Test
    @MainActor
    func uploadRequestsDeclareJSONOnlyWhenTheyHaveABody() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let (journal, job) = try await prepareJob(access: access, directory: directory)
        let requests = Mutex<[URLRequest]>([])
        let assetId = UUID().uuidString
        let asset = Data(
            #"{"asset":{"id":"\#(assetId)","status":"UPLOADING","uploadMode":"ORIGINAL"}}"#.utf8)
        let cancellation = Data(#"{"assetId":null,"sessionIds":[]}"#.utf8)
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            requests.withLock { $0.append(request) }
            let hasBody = request.httpBody != nil
            return (hasBody ? asset : cancellation, HTTPURLResponse(
                url: request.url!, statusCode: hasBody ? 201 : 200, httpVersion: nil, headerFields: nil)!)
        })

        _ = try await api.reserve(job)
        let cancelled = try journal.requestCancellation(for: job, access: access)
        _ = try await api.cancelIntent(for: cancelled)
        let recorded = requests.withLock { $0 }
        #expect(recorded.count == 2)
        #expect(recorded.first?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(recorded.last?.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationFenceRejectsAReceiptAfterTheJournalChanges() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let (journal, job) = try await prepareJob(access: access, directory: directory)
        let cancelled = try journal.requestCancellation(for: job, access: access)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish() }
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            entered.continuation.yield()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            return (Data(#"{"assetId":null,"sessionIds":[]}"#.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let request = Task { try await api.cancelIntent(for: cancelled) }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        var changed = cancelled
        let assetId = UUID().uuidString
        changed.assetId = assetId
        let saved = try journal.update(changed, access: access)
        release.continuation.yield()
        await #expect(throws: OriginalUploadStorageError.staleJob) { try await request.value }
        #expect(try journal.read(id: job.id, access: access) == saved)

        let data = try JSONSerialization.data(withJSONObject: ["assetId": assetId, "sessionIds": []])
        let retry = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await retry.cancelIntent(for: saved).assetId == assetId)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationFenceCanRetryAfterTaskCancellation() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let (journal, job) = try await prepareJob(access: access, directory: directory)
        let cancelled = try journal.requestCancellation(for: job, access: access)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish() }
        let response = Data(#"{"assetId":null,"sessionIds":[]}"#.utf8)
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            entered.continuation.yield()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            return (response, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let request = Task { try await api.cancelIntent(for: cancelled) }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        request.cancel()
        release.continuation.yield()
        await #expect(throws: CancellationError.self) { try await request.value }
        let saved = try journal.read(id: job.id, access: access)
        #expect(saved.cancellationRequested)

        let retry = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await retry.cancelIntent(for: saved).sessionIds.isEmpty)
    }

    @Test
    @MainActor
    func cancellationFenceValidatesAssetAndAllKnownSessions() async throws {
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
        let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
        let (journal, job) = try await prepareJob(
            access: access, directory: directory, assetId: assetId, sessionId: sessionId)
        let cancelled = try journal.requestCancellation(for: job, access: access)
        let otherSession = UUID().uuidString
        let valid = try JSONSerialization.data(withJSONObject: [
            "assetId": assetId, "sessionIds": [sessionId, otherSession],
        ])
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            (valid, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let receipt = try await api.cancelIntent(for: cancelled)
        #expect(receipt.assetId == assetId)
        #expect(receipt.sessionIds == [sessionId, otherSession])
        let reordered = Data(
            #" { "sessionIds": ["\#(sessionId)"], "\u0061ssetId": "\#(assetId)" } "#.utf8)
        let reorderedReceipt = try OriginalUploadCancellationReceipt.decode(reordered)
        try reorderedReceipt.validate(for: cancelled)
        try OriginalUploadCancellationReceipt(assetId: nil, sessionIds: []).validate(for: cancelled)
        try OriginalUploadCancellationReceipt(
            assetId: assetId, sessionIds: [sessionId, sessionId.uppercased()]).validate(for: cancelled)
        let historical = (1...100).map { String(format: "00000000-0000-4000-8000-%012x", $0) }
        try OriginalUploadCancellationReceipt(
            assetId: assetId, sessionIds: [sessionId] + Array(historical.prefix(99))).validate(for: cancelled)

        let invalid: [[String: Any]] = [
            ["sessionIds": []],
            ["assetId": NSNull(), "sessionIds": [sessionId]],
            ["assetId": "invalid", "sessionIds": [sessionId]],
            ["assetId": UUID().uuidString, "sessionIds": [sessionId]],
            ["assetId": assetId.uppercased(), "sessionIds": [sessionId]],
            ["assetId": assetId, "sessionIds": [sessionId.uppercased()]],
            ["assetId": assetId, "sessionIds": [sessionId, sessionId]],
            ["assetId": assetId, "sessionIds": []],
            ["assetId": assetId, "sessionIds": ["invalid"]],
            ["assetId": assetId, "sessionIds": [sessionId, sessionId + "\0&after=invalid"]],
            ["assetId": assetId, "sessionIds": [sessionId, "A1234567-0000-0000-8000-000000000001"]],
            ["assetId": assetId, "sessionIds": [sessionId, "A1234567-0000-4000-c000-000000000001"]],
            ["assetId": assetId, "sessionIds": [sessionId] + historical],
            ["assetId": assetId, "sessionIds": [sessionId], "nextCursor": sessionId],
        ]
        for value in invalid {
            let data = try JSONSerialization.data(withJSONObject: value)
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                (data, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await api.cancelIntent(for: cancelled)
            }
        }
        for value in [
            #"{"assetId":null,"assetId":"\#(assetId)","sessionIds":["\#(sessionId)"]}"#,
            #"{"assetId":"\#(assetId)","\u0061ssetId":null,"sessionIds":["\#(sessionId)"]}"#,
            #"{"assetId":"\#(assetId)","sessionIds":[],"sessionIds":["\#(sessionId)"]}"#,
            #"{"assetId":null,"sessionIds":[[["unexpected"]]]}"#,
            #"{"assetId":false,"sessionIds":[]}"#,
            #"{"assetId":null,"sessionIds":[]} trailing"#,
        ] {
            #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try OriginalUploadCancellationReceipt.decode(Data(value.utf8))
            }
        }
        let cancellationJSON = #"{"assetId":null,"sessionIds":[]}"#
        for data in try nonUTF8JSON(cancellationJSON) {
            #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try OriginalUploadCancellationReceipt.decode(data)
            }
        }
        // These UTF-16 bytes mimic the expected keys when scanned as UTF-8.
        let a = "\u{6173}\u{7365}\u{7449}\u{6422}"
        let b = "\u{612C}\u{6122}\u{7365}\u{7373}\u{696F}\u{6E49}\u{6473}\u{2261}"
        let end = "\u{2261}"
        let ambiguous = #"{"\#(a)":null,"\#(b)":null,"sessionIds":[],"sessionIds":[],"z":"\#(end)"}"#
        let ambiguousBytes = try #require(ambiguous.data(using: .utf16BigEndian))
        #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try OriginalUploadCancellationReceipt.decode(ambiguousBytes)
        }
    }

    @Test
    func cancellationReceiptValidationRespectsTaskCancellation() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); release.continuation.finish() }
        let task = Task {
            started.continuation.yield()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            return try OriginalUploadCancellationReceipt.decode(
                Data(#"{"assetId":null,"sessionIds":[]}"#.utf8))
        }
        var iterator = started.stream.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        task.cancel()
        release.continuation.yield()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    @MainActor
    func abortRequiresTheExactSessionAndATerminalReceipt() async throws {
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
        let (journal, job) = try await prepareJob(
            access: access, directory: directory, assetId: UUID().uuidString, sessionId: sessionId)
        let cancelled = try journal.requestCancellation(for: job, access: access)
        func api(status: Int, body: Data) throws -> OriginalUploadAPI {
            try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                (body, HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
        }
        func api(status: Int, body: String) throws -> OriginalUploadAPI {
            try api(status: status, body: Data(body.utf8))
        }

        for status in ["ABORTED", "EXPIRED"] {
            try await api(status: 200, body:
                #"{"uploadSession":{"id":"\#(sessionId)","status":"\#(status)"}}"#).abort(cancelled)
        }
        for (status, body) in [
            (204, ""),
            (201, #"{"uploadSession":{"id":"\#(sessionId)","status":"ABORTED"}}"#),
            (200, #"{"uploadSession":{"id":"\#(sessionId.uppercased())","status":"ABORTED"}}"#),
            (200, #"{"uploadSession":{"id":"\#(UUID().uuidString)","status":"ABORTED"}}"#),
            (200, #"{"uploadSession":{"id":"\#(sessionId)","status":"OPEN"}}"#),
            (200, #"{"uploadSession":{"id":"\#(sessionId)","status":"COMPLETED"}}"#),
            (200, #"{"uploadSession":{"id":"\#(sessionId)"}}"#),
            (200, #"{"uploadSession":{"id":"\#(sessionId)","status":"ABORTED","status":"OPEN"}}"#),
            (200, #"{"uploadSession":{"id":"\#(sessionId)","\u0069d":"other","status":"ABORTED"}}"#),
            (200, #"{"uploadSession":{"id":"\#(sessionId)","status":"ABORTED"},"uploadSession":null}"#),
        ] {
            let rejected = try api(status: status, body: body)
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await rejected.abort(cancelled)
            }
        }
        let abortJSON = #"{"uploadSession":{"id":"\#(sessionId)","status":"ABORTED"}}"#
        for data in try nonUTF8JSON(abortJSON) {
            let rejected = try api(status: 200, body: data)
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await rejected.abort(cancelled)
            }
        }
        let throttled = try api(status: 429, body: #"{"code":"INTENT_CANCELLATION_QUOTA"}"#)
        await #expect(throws: OriginalUploadAPIError.httpStatus(429)) {
            try await throttled.abort(cancelled)
        }
        #expect(try journal.read(id: job.id, access: access).cancellationRequested)
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
        let abortResponse = Data(
            #"{"uploadSession":{"id":"\#(sessionId)","status":"ABORTED"}}"#.utf8)
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            sent.withLock { $0 += 1 }
            return (abortResponse, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
        await #expect(throws: OriginalUploadStorageError.cancellationRequested) {
            try await api.createSession(for: cancelled)
        }
        await #expect(throws: OriginalUploadStorageError.cancellationRequested) {
            try await api.sign(for: cancelled, session: session, partNumber: 1)
        }
        await #expect(throws: OriginalUploadStorageError.cancellationRequested) {
            try await api.complete(cancelled)
        }
        #expect(sent.withLock { $0 } == 0)
        try await api.abort(cancelled)
        #expect(sent.withLock { $0 } == 1)
    }
}
