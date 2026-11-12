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
        access: OriginalUploadAccess, directory: URL, assetId: String? = nil, sessionId: String? = nil,
        taskFence: OriginalUploadTaskFence? = nil
    ) async throws -> (OriginalUploadJournal, OriginalUploadJob) {
        let source = directory.appendingPathComponent("video.mov")
        try Data("native original".utf8).write(to: source)
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"), taskFence: taskFence ?? OriginalUploadTaskFence())
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

    @MainActor
    private func prepareCancelledJob(
        directory: URL, assetId: String? = nil, sessionId: String? = nil
    ) async throws -> (AuthService, OriginalUploadAccess, OriginalUploadJournal, OriginalUploadJob) {
        let server = URL(string: "https://isolated.example.test")!
        let auth = AuthService(storage: .memory, serverURL: { server })
        auth.token = "test-token"
        auth.currentUser = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let access = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let (journal, job) = try await prepareJob(
            access: access, directory: directory, assetId: assetId, sessionId: sessionId)
        return (auth, access, journal, try journal.requestCancellation(for: job, access: access))
    }

    private func cancellationPage(
        assetId: String, sessionIds: [String], nextCursor: String? = nil
    ) throws -> Data {
        var body: [String: Any] = ["assetId": assetId, "sessionIds": sessionIds, "nextCursor": NSNull()]
        if let nextCursor { body["nextCursor"] = nextCursor }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func cancellationSessionResponse(
        job: OriginalUploadJob, assetId: String, sessionId: String,
        status: String = "OPEN", overrides: [String: Any] = [:]
    ) throws -> Data {
        let part = job.manifest.parts[0]
        var session: [String: Any] = [
            "id": sessionId, "assetId": assetId, "clipId": "ab123456-789a-4bcd-8abc-0123456789ab",
            "status": status, "expectedSizeBytes": String(job.fingerprint.byteCount),
            "expectedSha256": job.fingerprint.sha256, "partSizeBytes": OriginalUploadFiles.maximumPartSize,
            "partCount": job.manifest.parts.count, "expiresAt": "2033-05-18T03:33:20Z",
            "completedAt": status == "COMPLETED" ? "2033-05-18T03:30:00Z" : NSNull(),
            "parts": [["partNumber": 1, "sizeBytes": String(part.byteCount), "sha256": part.sha256]],
        ]
        session.merge(overrides) { _, value in value }
        return try JSONSerialization.data(withJSONObject: ["uploadSession": session])
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
        let user = User(
            id: "user-1", phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        auth.currentUser = user
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
    func sessionRecoveryStopsWhenCancellationIsBlockedOrSaved() async throws {
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
        let fence = OriginalUploadTaskFence()
        let (journal, job) = try await prepareJob(
            access: access, directory: directory, assetId: assetId, sessionId: sessionId, taskFence: fence)
        let body = try cancellationSessionResponse(job: job, assetId: assetId, sessionId: sessionId)
        let requests = Mutex<[URLRequest]>([])
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            requests.withLock { $0.append(request) }
            return (body, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: transport)
        #expect(try await api.session(for: job).status == .open)
        try fence.blockCancellation(for: job)
        #expect(try !journal.read(id: job.id, access: access).cancellationRequested)
        await #expect(throws: OriginalUploadStorageError.cancellationRequested) {
            try await api.session(for: job)
        }
        let cancelled = try journal.requestCancellation(for: job, access: access)
        let recoveredJournal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"), taskFence: OriginalUploadTaskFence())
        #expect(try !recoveredJournal.isCancellationBlocked(for: cancelled))
        let recoveredAPI = try OriginalUploadAPI(access: access, journal: recoveredJournal, transport: transport)
        await #expect(throws: OriginalUploadStorageError.cancellationRequested) {
            try await recoveredAPI.session(for: cancelled)
        }
        #expect(requests.withLock { $0.map(\.httpMethod) } == ["GET"])
        #expect(try journal.read(id: job.id, access: access) == cancelled)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func sessionRecoveryDiscardsAResponseAfterCancellation() async throws {
        enum Change { case block, save }
        for change in [Change.block, .save] {
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
            let fence = OriginalUploadTaskFence()
            let (journal, job) = try await prepareJob(
                access: access, directory: directory, assetId: assetId, sessionId: sessionId, taskFence: fence)
            let body = try cancellationSessionResponse(job: job, assetId: assetId, sessionId: sessionId)
            let original = try journal.originalURL(for: job, access: access)
            let originalBytes = try Data(contentsOf: original)
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let requests = Mutex<[URLRequest]>([])
            defer { entered.continuation.finish(); release.continuation.finish() }
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                entered.continuation.yield()
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
                requests.withLock { $0.append(request) }
                return (body, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let request = Task { try await api.session(for: job) }
            var iterator = entered.stream.makeAsyncIterator()
            try #require(await iterator.next() != nil)
            let saved: OriginalUploadJob
            switch change {
            case .block:
                try fence.blockCancellation(for: job)
                saved = job
            case .save:
                saved = try journal.requestCancellation(for: job, access: access)
            }
            release.continuation.yield()
            switch change {
            case .block:
                await #expect(throws: OriginalUploadStorageError.cancellationRequested) { try await request.value }
            case .save:
                await #expect(throws: OriginalUploadStorageError.staleJob) { try await request.value }
            }
            #expect(requests.withLock { $0.map(\.httpMethod) } == ["GET"])
            #expect(try journal.read(id: job.id, access: access) == saved)
            #expect(try Data(contentsOf: original) == originalBytes)
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
        for status in [401, 404, 503] {
            await #expect(throws: OriginalUploadAPIError.httpStatus(status)) {
                try await api(empty, status: status).cancellationSessions(for: cancelled)
            }
        }
        await #expect(throws: OriginalUploadAPIError.cancellationPageRetryAfterInvalid) {
            try await api(empty, status: 429).cancellationSessions(for: cancelled)
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
    func cancellationTraversalRejectsCrossPageDuplicatesAndCycles() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
        let (_, access, journal, cancelled) = try await prepareCancelledJob(directory: directory, assetId: assetId)
        let firstIds = (1...100).map { String(format: "A1234567-0000-4000-8000-%012x", $0) }
        let secondIds = (1...100).map { String(format: "B1234567-0000-4000-8000-%012x", $0) }
        let first = try cancellationPage(assetId: assetId, sessionIds: firstIds, nextCursor: firstIds.last)
        let second = try cancellationPage(assetId: assetId, sessionIds: secondIds, nextCursor: secondIds.last)
        let distinctCase = firstIds[0].lowercased()
        let corrected = try cancellationPage(assetId: assetId, sessionIds: [distinctCase])
        let duplicate = try cancellationPage(assetId: assetId, sessionIds: [firstIds[0], distinctCase])

        for invalid in [duplicate, first] {
            let responses = [first, second, invalid, corrected]
            let requests = Mutex<[URLRequest]>([])
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                let index = requests.withLock { requests in
                    requests.append(request)
                    return requests.count - 1
                }
                guard responses.indices.contains(index) else { throw URLError(.badServerResponse) }
                return (responses[index], HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let traversal = try OriginalUploadCancellationTraversal(api: api, job: cancelled)
            #expect(try await traversal.nextPage()?.sessionIds == firstIds)
            #expect(try traversal.completedEnumeration() == nil)
            #expect(try await traversal.nextPage()?.sessionIds == secondIds)
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await traversal.nextPage()
            }
            #expect(try await traversal.nextPage()?.sessionIds == [distinctCase])
            #expect(try await traversal.nextPage() == nil)
            let enumeration = try #require(try traversal.completedEnumeration())
            #expect(enumeration.assetId == assetId)
            #expect(enumeration.sessionIds == Set(firstIds + secondIds + [distinctCase]))
            let sent = requests.withLock { $0 }
            #expect(sent.count == 4)
            #expect(sent[2].url?.query == "after=\(secondIds[99])")
            #expect(sent[3].url?.query == sent[2].url?.query)
            #expect(try journal.read(id: cancelled.id, access: access).cancellationRequested)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationTraversalStopsAtOneHundredPages() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
        let (_, access, journal, cancelled) = try await prepareCancelledJob(directory: directory, assetId: assetId)

        for hasMore in [false, true] {
            let requests = Mutex(0)
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                let index = requests.withLock { count in
                    defer { count += 1 }
                    return count
                }
                let ids = (0..<100).map {
                    String(format: "A1234567-0000-4000-8000-%012llx", UInt64(index * 100 + $0))
                }
                var body: [String: Any] = [
                    "assetId": assetId, "sessionIds": ids, "nextCursor": NSNull(),
                ]
                if index < 99 || hasMore { body["nextCursor"] = ids.last }
                return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let traversal = try OriginalUploadCancellationTraversal(api: api, job: cancelled)
            for index in 0..<100 {
                let page = try #require(try await traversal.nextPage())
                #expect(page.sessionIds.count == 100)
                #expect((page.continuation != nil) == (index < 99 || hasMore))
            }
            if hasMore {
                await #expect(throws: OriginalUploadAPIError.cancellationTraversalLimit) {
                    try await traversal.nextPage()
                }
                #expect(try traversal.completedEnumeration() == nil)
            } else {
                #expect(try await traversal.nextPage() == nil)
                let enumeration = try #require(try traversal.completedEnumeration())
                #expect(enumeration.assetId == assetId)
                #expect(enumeration.sessionIds.count == 10_000)
            }
            #expect(requests.withLock { $0 } == 100)
            #expect(try journal.read(id: cancelled.id, access: access).cancellationRequested)
        }
    }

    @Test
    @MainActor
    func cancellationTraversalResumesTheSameCursorAfterRetryDelay() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
        let (_, access, journal, cancelled) = try await prepareCancelledJob(directory: directory, assetId: assetId)
        let ids = (1...100).map { String(format: "A1234567-0000-4000-8000-%012x", $0) }
        let first = try cancellationPage(assetId: assetId, sessionIds: ids, nextCursor: ids.last)
        let last = try cancellationPage(assetId: assetId, sessionIds: [sessionId])
        let requests = Mutex<[URLRequest]>([])
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            let index = requests.withLock { requests in
                requests.append(request)
                return requests.count - 1
            }
            let status = index == 1 ? 429 : (index == 2 ? 503 : 200)
            let headers = status == 429 ? ["Retry-After": "2"] : [:]
            return (index == 0 ? first : last, HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        })
        let clock = Mutex(ContinuousClock.now)
        let traversal = try OriginalUploadCancellationTraversal(
            api: api, job: cancelled, now: { clock.withLock { $0 } })
        #expect(try await traversal.nextPage()?.sessionIds == ids)
        #expect(try traversal.completedEnumeration() == nil)
        await #expect(throws: OriginalUploadAPIError.cancellationPageRateLimited(retryAfterSeconds: 2)) {
            try await traversal.nextPage()
        }
        clock.withLock { $0 = $0.advanced(by: .milliseconds(1_500)) }
        await #expect(throws: OriginalUploadAPIError.cancellationPageRateLimited(retryAfterSeconds: 1)) {
            try await traversal.nextPage()
        }
        #expect(requests.withLock { $0.count } == 2)
        clock.withLock { $0 = $0.advanced(by: .milliseconds(500)) }
        await #expect(throws: OriginalUploadAPIError.httpStatus(503)) {
            try await traversal.nextPage()
        }
        #expect(try await traversal.nextPage()?.sessionIds == [sessionId])
        #expect(try await traversal.nextPage() == nil)
        let enumeration = try #require(try traversal.completedEnumeration())
        #expect(enumeration.assetId == assetId)
        #expect(enumeration.sessionIds == Set(ids + [sessionId]))
        let sent = requests.withLock { $0 }
        #expect(sent.count == 4)
        #expect(sent[1].url?.query == "after=\(ids[99])")
        #expect(sent[2].url?.query == sent[1].url?.query)
        #expect(sent[3].url?.query == sent[1].url?.query)
        #expect(try journal.read(id: cancelled.id, access: access).cancellationRequested)
    }

    @Test
    @MainActor
    func cancellationTraversalStopsOnAnInvalidRetryDelay() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
        let (_, access, journal, cancelled) = try await prepareCancelledJob(directory: directory, assetId: assetId)
        let ids = (1...100).map { String(format: "A1234567-0000-4000-8000-%012x", $0) }
        let first = try cancellationPage(assetId: assetId, sessionIds: ids, nextCursor: ids.last)

        for seconds in [1, 86_400] {
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                (first, HTTPURLResponse(
                    url: request.url!, statusCode: 429, httpVersion: nil,
                    headerFields: ["Retry-After": String(seconds)])!)
            })
            await #expect(throws: OriginalUploadAPIError.cancellationPageRateLimited(retryAfterSeconds: seconds)) {
                try await api.cancellationSessions(for: cancelled)
            }
        }
        for header: String? in [nil, "", "0", "-1", "1.5", "86401", "999999999999999999999"] {
            let requests = Mutex<[URLRequest]>([])
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                let index = requests.withLock { requests in
                    requests.append(request)
                    return requests.count - 1
                }
                var headers: [String: String] = [:]
                if let header { headers["Retry-After"] = header }
                return (first, HTTPURLResponse(
                    url: request.url!, statusCode: index == 0 ? 200 : 429,
                    httpVersion: nil, headerFields: headers)!)
            })
            let traversal = try OriginalUploadCancellationTraversal(api: api, job: cancelled)
            #expect(try await traversal.nextPage()?.sessionIds == ids)
            for _ in 0..<2 {
                await #expect(throws: OriginalUploadAPIError.cancellationPageRetryAfterInvalid) {
                    try await traversal.nextPage()
                }
            }
            let sent = requests.withLock { $0 }
            #expect(sent.count == 2)
            #expect(sent[1].url?.query == "after=\(ids[99])")
            #expect(try journal.read(id: cancelled.id, access: access).cancellationRequested)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationTraversalRetainsObservedRateLimitsWhenCancelled() async throws {
        for header: String? in ["2", nil] {
            let directory = try fixture()
            defer { cleanup(directory) }
            let (_, access, journal, cancelled) = try await prepareCancelledJob(directory: directory)
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            defer { entered.continuation.finish(); release.continuation.finish() }
            let requests = Mutex(0)
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                let count = requests.withLock { count in
                    count += 1
                    return count
                }
                if count == 1 {
                    entered.continuation.yield()
                    var iterator = release.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    var headers: [String: String] = [:]
                    if let header { headers["Retry-After"] = header }
                    return (Data(), HTTPURLResponse(
                        url: request.url!, statusCode: 429, httpVersion: nil, headerFields: headers)!)
                }
                return (Data(#"{"assetId":null,"sessionIds":[],"nextCursor":null}"#.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let clock = Mutex(ContinuousClock.now)
            let traversal = try OriginalUploadCancellationTraversal(
                api: api, job: cancelled, now: { clock.withLock { $0 } })
            let request = Task { try await traversal.nextPage() }
            var iterator = entered.stream.makeAsyncIterator()
            try #require(await iterator.next() != nil)
            request.cancel()
            release.continuation.yield()
            await #expect(throws: CancellationError.self) { try await request.value }
            if header != nil {
                await #expect(throws: OriginalUploadAPIError.cancellationPageRateLimited(retryAfterSeconds: 2)) {
                    try await traversal.nextPage()
                }
                #expect(requests.withLock { $0 } == 1)
                clock.withLock { $0 = $0.advanced(by: .seconds(2)) }
                #expect(try await traversal.nextPage()?.sessionIds == [])
                #expect(requests.withLock { $0 } == 2)
            } else {
                await #expect(throws: OriginalUploadAPIError.cancellationPageRetryAfterInvalid) {
                    try await traversal.nextPage()
                }
                #expect(requests.withLock { $0 } == 1)
            }
            #expect(try journal.read(id: cancelled.id, access: access).cancellationRequested)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationTraversalStopsWhenTheResponseIsUnknown() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let (_, access, journal, cancelled) = try await prepareCancelledJob(directory: directory)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish() }
        let requests = Mutex(0)
        let interrupted = try OriginalUploadAPI(access: access, journal: journal, transport: { _ in
            requests.withLock { $0 += 1 }
            entered.continuation.yield()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            try Task.checkCancellation()
            throw URLError(.timedOut)
        })
        let traversal = try OriginalUploadCancellationTraversal(api: interrupted, job: cancelled)
        let request = Task { try await traversal.nextPage() }
        var iterator = entered.stream.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        request.cancel()
        release.continuation.yield()
        await #expect(throws: CancellationError.self) { try await request.value }
        await #expect(throws: OriginalUploadAPIError.cancellationPageResponseUnknown) {
            try await traversal.nextPage()
        }
        #expect(try traversal.completedEnumeration() == nil)
        #expect(requests.withLock { $0 } == 1)

        for code in [URLError.timedOut, .dataLengthExceedsMaximum] {
            let attempts = Mutex(0)
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { _ in
                attempts.withLock { $0 += 1 }
                throw URLError(code)
            })
            let traversal = try OriginalUploadCancellationTraversal(api: api, job: cancelled)
            if code == .dataLengthExceedsMaximum {
                await #expect(throws: OriginalUploadAPIError.invalidResponse) { try await traversal.nextPage() }
            } else {
                await #expect(throws: URLError.self) { try await traversal.nextPage() }
            }
            await #expect(throws: OriginalUploadAPIError.cancellationPageResponseUnknown) {
                try await traversal.nextPage()
            }
            #expect(attempts.withLock { $0 } == 1)
        }
        #expect(try journal.read(id: cancelled.id, access: access).cancellationRequested)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationTraversalStopsWhenBoundedTransportHidesARateLimit() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let (_, access, journal, cancelled) = try await prepareCancelledJob(directory: directory)
        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let baseURL = try await server.start()
        let path = "bounded-stall-rate-limit"
        let bodyStarted = AsyncStream<Void>.makeStream()
        defer { bodyStarted.continuation.finish() }
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { _ in
            try await RedirectSafeTransport.boundedData(
                for: URLRequest(url: baseURL.appendingPathComponent(path)), maximumBytes: 64 * 1024,
                onBody: { _ in _ = bodyStarted.continuation.yield() })
        })
        let traversal = try OriginalUploadCancellationTraversal(api: api, job: cancelled)
        let request = Task { try await traversal.nextPage() }
        defer { request.cancel() }
        #expect(try await server.waitForStalledResponse() == path)
        let observedBody = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = bodyStarted.stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        try #require(observedBody)
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try await server.waitForResponseCancellation() == path)
        await #expect(throws: OriginalUploadAPIError.cancellationPageResponseUnknown) {
            try await traversal.nextPage()
        }
        #expect(server.requestCount == 1)
        #expect(try journal.read(id: cancelled.id, access: access).cancellationRequested)
    }

    @Test
    @MainActor
    func completedCancellationEnumerationRejectsStaleOrCancelledCallers() async throws {
        enum Change { case cancelTask, journal, signOut }
        for change in [Change.cancelTask, .journal, .signOut] {
            let directory = try fixture()
            defer { cleanup(directory) }
            let (auth, access, journal, cancelled) = try await prepareCancelledJob(directory: directory)
            let user = try #require(auth.currentUser)
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                (Data(#"{"assetId":null,"sessionIds":[],"nextCursor":null}"#.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let traversal = try OriginalUploadCancellationTraversal(api: api, job: cancelled)
            _ = try await traversal.nextPage()
            let enumeration = try #require(try traversal.completedEnumeration())
            #expect(enumeration.assetId == nil)
            #expect(enumeration.sessionIds.isEmpty)

            switch change {
            case .cancelTask:
                let request = Task { try traversal.completedEnumeration() }
                request.cancel()
                await #expect(throws: CancellationError.self) { try await request.value }
            case .journal:
                _ = try journal.update(cancelled, access: access)
                #expect(throws: OriginalUploadStorageError.staleJob) { try traversal.completedEnumeration() }
            case .signOut:
                auth.logout()
                #expect(throws: OriginalUploadAPIError.sessionChanged) { try traversal.completedEnumeration() }
                auth.token = "test-token"
                auth.currentUser = user
            }
            let freshAccess = try OriginalUploadAccess(
                auth: auth, allowedOrigins: ["https://isolated.example.test"])
            #expect(try journal.read(id: cancelled.id, access: freshAccess).cancellationRequested)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationTraversalSerializesRequestsAndRejectsLateResponses() async throws {
        enum Change { case cancelTask, journal, signOut }
        for change in [Change.cancelTask, .journal, .signOut] {
            let directory = try fixture()
            defer { cleanup(directory) }
            let (auth, access, journal, cancelled) = try await prepareCancelledJob(directory: directory)
            let user = try #require(auth.currentUser)
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            defer { entered.continuation.finish(); release.continuation.finish() }
            let requests = Mutex(0)
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                let count = requests.withLock { count in
                    count += 1
                    return count
                }
                if count == 1 {
                    entered.continuation.yield()
                    var iterator = release.stream.makeAsyncIterator()
                    _ = await iterator.next()
                }
                return (Data(#"{"assetId":null,"sessionIds":[],"nextCursor":null}"#.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let traversal = try OriginalUploadCancellationTraversal(api: api, job: cancelled)
            let request = Task { try await traversal.nextPage() }
            var iterator = entered.stream.makeAsyncIterator()
            try #require(await iterator.next() != nil)
            await #expect(throws: OriginalUploadAPIError.cancellationTraversalInProgress) {
                try await traversal.nextPage()
            }
            #expect(try traversal.completedEnumeration() == nil)
            switch change {
            case .cancelTask: request.cancel()
            case .journal: _ = try journal.update(cancelled, access: access)
            case .signOut: auth.logout()
            }
            release.continuation.yield()
            switch change {
            case .cancelTask:
                await #expect(throws: CancellationError.self) { try await request.value }
                #expect(try await traversal.nextPage()?.sessionIds == [])
                #expect(requests.withLock { $0 } == 2)
            case .journal:
                await #expect(throws: OriginalUploadStorageError.staleJob) { try await request.value }
                await #expect(throws: OriginalUploadStorageError.staleJob) { try await traversal.nextPage() }
                #expect(requests.withLock { $0 } == 1)
            case .signOut:
                await #expect(throws: OriginalUploadAPIError.sessionChanged) { try await request.value }
                await #expect(throws: OriginalUploadAPIError.sessionChanged) { try await traversal.nextPage() }
                #expect(requests.withLock { $0 } == 1)
                auth.token = "test-token"
                auth.currentUser = user
            }
            let freshAccess = try OriginalUploadAccess(
                auth: auth, allowedOrigins: ["https://isolated.example.test"])
            #expect(try journal.read(id: cancelled.id, access: freshAccess).cancellationRequested)
        }

        let directory = try fixture()
        defer { cleanup(directory) }
        let (_, access, journal, cancelled) = try await prepareCancelledJob(directory: directory)
        let requests = Mutex(0)
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            requests.withLock { $0 += 1 }
            return (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60"])!)
        })
        let traversal = try OriginalUploadCancellationTraversal(api: api, job: cancelled)
        await #expect(throws: OriginalUploadAPIError.cancellationPageRateLimited(retryAfterSeconds: 60)) {
            try await traversal.nextPage()
        }
        _ = try journal.update(cancelled, access: access)
        await #expect(throws: OriginalUploadStorageError.staleJob) { try await traversal.nextPage() }
        #expect(throws: OriginalUploadStorageError.staleJob) { try traversal.completedEnumeration() }
        #expect(requests.withLock { $0 } == 1)
        #expect(try journal.read(id: cancelled.id, access: access).cancellationRequested)
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
    @MainActor
    func cancellationInspectionUsesFenceForKnownAndDiscoveredSessions() async throws {
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
        let discoveredId = "A1234567-0000-4000-8000-000000000001"
        let (journal, job) = try await prepareJob(
            access: access, directory: directory, assetId: assetId, sessionId: sessionId)
        let cancelled = try journal.requestCancellation(for: job, access: access)
        let original = try journal.originalURL(for: cancelled, access: access)
        let originalBytes = try Data(contentsOf: original)
        let fence = try JSONSerialization.data(withJSONObject: [
            "assetId": assetId, "sessionIds": [sessionId, discoveredId],
        ])
        let statuses: [OriginalUploadServerSession.Status] = [.open, .completing, .completed, .aborted, .expired]
        let responses = try statuses.map {
            try cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId, status: $0.rawValue)
        } + [cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: discoveredId)]
        let requests = Mutex<[URLRequest]>([])
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            let index = requests.withLock { requests in
                requests.append(request)
                return requests.count - 1
            }
            guard index <= responses.count else { throw URLError(.badServerResponse) }
            let data = index == 0 ? fence : responses[index - 1]
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        await #expect(throws: OriginalUploadStorageError.staleJob) {
            try await api.fenceCancellation(for: job)
        }
        let enumeration = try await api.fenceCancellation(for: cancelled)
        #expect(enumeration.assetId == assetId)
        #expect(enumeration.sessionIds == Set([sessionId, discoveredId]))
        for (index, status) in statuses.enumerated() {
            let inspection = try await api.inspectCancelledSession(sessionId, for: cancelled, using: enumeration)
            #expect(inspection.session.id == sessionId)
            #expect(inspection.session.status == status)
            #expect(requests.withLock { $0.count } == index + 2)
        }
        let discovered = try await api.inspectCancelledSession(discoveredId, for: cancelled, using: enumeration)
        #expect(discovered.session.id == discoveredId)
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api.inspectCancelledSession(sessionId.uppercased(), for: cancelled, using: enumeration)
        }
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api.inspectCancelledSession(sessionId + "\0suffix", for: cancelled, using: enumeration)
        }
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api.inspectCancelledSession(
                "B1234567-0000-4000-8000-000000000002", for: cancelled, using: enumeration)
        }

        let sent = requests.withLock { $0 }
        #expect(sent.count == statuses.count + 2)
        #expect(sent[0].httpMethod == "POST")
        #expect(sent.dropFirst().allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        #expect(sent[1].url?.path == "/api/upload-sessions/\(sessionId)")
        #expect(sent.last?.url?.path == "/api/upload-sessions/\(discoveredId)")
        #expect(try journal.read(id: job.id, access: access) == cancelled)
        #expect(try Data(contentsOf: original) == originalBytes)
    }

    @Test
    @MainActor
    func cancellationInspectionUsesOnlyCompletedTraversalForUnassignedJobs() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let (_, access, journal, cancelled) = try await prepareCancelledJob(directory: directory)
        let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
        let ids = (1...100).map { String(format: "A1234567-0000-4000-8000-%012x", $0) }
        let first = try cancellationPage(assetId: assetId, sessionIds: ids, nextCursor: ids.last)
        let last = try cancellationPage(assetId: assetId, sessionIds: [sessionId])
        let session = try cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId)
        let requests = Mutex<[URLRequest]>([])
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            let index = requests.withLock { requests in
                requests.append(request)
                return requests.count - 1
            }
            let response: Data
            switch index {
            case 0: response = first
            case 1: response = last
            case 2: response = session
            default: throw URLError(.badServerResponse)
            }
            return (response, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let traversal = try OriginalUploadCancellationTraversal(api: api, job: cancelled)
        #expect(try traversal.completedEnumeration() == nil)
        #expect(try await traversal.nextPage()?.sessionIds == ids)
        #expect(try traversal.completedEnumeration() == nil)
        #expect(try await traversal.nextPage()?.sessionIds == [sessionId])
        let enumeration = try #require(try traversal.completedEnumeration())
        let inspected = try await api.inspectCancelledSession(sessionId, for: cancelled, using: enumeration)
        #expect(inspected.session.id == sessionId)
        #expect(inspected.session.assetId == assetId)
        #expect(cancelled.assetId == nil)
        #expect(cancelled.sessionId == nil)
        let sent = requests.withLock { $0 }
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { $0.httpMethod == "GET" })
        #expect(sent[2].url?.path == "/api/upload-sessions/\(sessionId)")
        #expect(try journal.read(id: cancelled.id, access: access) == cancelled)
    }

    @Test
    @MainActor
    func cancellationAbortRequiresACompletedTraversalAndTargetsOnlyItsInspectedSession() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let (_, access, journal, cancelled) = try await prepareCancelledJob(directory: directory)
        let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
        let ids = (1...100).map { String(format: "A1234567-0000-4000-8000-%012x", $0) }
        let page1 = try cancellationPage(assetId: assetId, sessionIds: ids, nextCursor: ids.last)
        let page2 = try cancellationPage(assetId: assetId, sessionIds: [sessionId])
        let inspected = try cancellationSessionResponse(
            job: cancelled, assetId: assetId, sessionId: sessionId)
        let aborted = Data(#"{"uploadSession":{"id":"\#(sessionId)","status":"ABORTED"}}"#.utf8)
        let requests = Mutex<[URLRequest]>([])
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            let index = requests.withLock { requests in
                requests.append(request)
                return requests.count - 1
            }
            let data: Data
            switch index {
            case 0: data = page1
            case 1: data = page2
            case 2: data = inspected
            default: data = aborted
            }
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let traversal = try OriginalUploadCancellationTraversal(api: api, job: cancelled)
        #expect(try traversal.completedEnumeration() == nil)
        #expect(try await traversal.nextPage()?.continuation != nil)
        #expect(try traversal.completedEnumeration() == nil)
        #expect(try await traversal.nextPage()?.continuation == nil)
        let enumeration = try #require(try traversal.completedEnumeration())
        #expect(cancelled.assetId == nil)
        #expect(cancelled.sessionId == nil)
        let inspection = try await api.inspectCancelledSession(sessionId, for: cancelled, using: enumeration)
        try await api.abort(cancelled, using: inspection)
        let sent = requests.withLock { $0 }
        #expect(sent.map(\.httpMethod) == ["GET", "GET", "GET", "DELETE"])
        #expect(sent[2].url?.path == "/api/upload-sessions/\(sessionId)")
        #expect(sent[3].url?.path == "/api/upload-sessions/\(sessionId)")
        #expect(try journal.read(id: cancelled.id, access: access) == cancelled)
    }

    @Test
    @MainActor
    func cancellationAbortTargetsDiscoveredSessionWhenAnotherSessionIsJournaled() async throws {
        for useTraversal in [false, true] {
            let directory = try fixture()
            defer { cleanup(directory) }
            let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
            let discoveredId = "A1234567-0000-4000-8000-000000000001"
            let (_, access, journal, cancelled) = try await prepareCancelledJob(
                directory: directory, assetId: assetId, sessionId: sessionId)
            let original = try journal.originalURL(for: cancelled, access: access)
            let originalBytes = try Data(contentsOf: original)
            let fence = try JSONSerialization.data(withJSONObject: [
                "assetId": assetId, "sessionIds": [sessionId, discoveredId],
            ])
            let page = try cancellationPage(assetId: assetId, sessionIds: [sessionId, discoveredId])
            let inspected = try cancellationSessionResponse(
                job: cancelled, assetId: assetId, sessionId: discoveredId)
            let aborted = Data(#"{"uploadSession":{"id":"\#(discoveredId)","status":"ABORTED"}}"#.utf8)
            let requests = Mutex<[URLRequest]>([])
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                requests.withLock { $0.append(request) }
                let data: Data
                switch request.httpMethod {
                case "POST": data = fence
                case "GET":
                    data = request.url?.path.hasSuffix("/sessions") == true ? page : inspected
                case "DELETE": data = aborted
                default: throw URLError(.badServerResponse)
                }
                return (data, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let enumeration: OriginalUploadCancellationEnumeration
            if useTraversal {
                let traversal = try OriginalUploadCancellationTraversal(api: api, job: cancelled)
                _ = try await traversal.nextPage()
                enumeration = try #require(try traversal.completedEnumeration())
            } else {
                enumeration = try await api.fenceCancellation(for: cancelled)
            }
            let inspection = try await api.inspectCancelledSession(
                discoveredId, for: cancelled, using: enumeration)
            try await api.abort(cancelled, using: inspection)

            let sent = requests.withLock { $0 }
            try #require(sent.count == 3)
            #expect(sent.map(\.httpMethod) == [useTraversal ? "GET" : "POST", "GET", "DELETE"])
            #expect(sent[1].url?.path == "/api/upload-sessions/\(discoveredId)")
            #expect(sent[2].url?.path == "/api/upload-sessions/\(discoveredId)")
            #expect(try journal.read(id: cancelled.id, access: access) == cancelled)
            #expect(try Data(contentsOf: original) == originalBytes)

            let updated = try journal.update(cancelled, access: access)
            await #expect(throws: OriginalUploadStorageError.staleJob) {
                try await api.abort(cancelled, using: inspection)
            }
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await api.abort(updated, using: inspection)
            }
            #expect(requests.withLock { $0.count } == 3)
            #expect(try journal.read(id: cancelled.id, access: access) == updated)
            #expect(try Data(contentsOf: original) == originalBytes)
        }
    }

    @Test
    @MainActor
    func cancellationAbortRejectsCompletedDiscoveredSessionAndReceiptForJournaledSession() async throws {
        for completed in [false, true] {
            let directory = try fixture()
            defer { cleanup(directory) }
            let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
            let discoveredId = "A1234567-0000-4000-8000-000000000001"
            let (_, access, journal, cancelled) = try await prepareCancelledJob(
                directory: directory, assetId: assetId, sessionId: sessionId)
            let original = try journal.originalURL(for: cancelled, access: access)
            let originalBytes = try Data(contentsOf: original)
            let fence = try JSONSerialization.data(withJSONObject: [
                "assetId": assetId, "sessionIds": [sessionId, discoveredId],
            ])
            let inspected = try cancellationSessionResponse(
                job: cancelled, assetId: assetId, sessionId: discoveredId,
                status: completed ? "COMPLETED" : "OPEN")
            let wrongReceipt = Data(#"{"uploadSession":{"id":"\#(sessionId)","status":"ABORTED"}}"#.utf8)
            let requests = Mutex<[URLRequest]>([])
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                requests.withLock { $0.append(request) }
                let data: Data
                switch request.httpMethod {
                case "POST": data = fence
                case "GET": data = inspected
                case "DELETE": data = wrongReceipt
                default: throw URLError(.badServerResponse)
                }
                return (data, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let enumeration = try await api.fenceCancellation(for: cancelled)
            let inspection = try await api.inspectCancelledSession(
                discoveredId, for: cancelled, using: enumeration)
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await api.abort(cancelled, using: inspection)
            }

            let sent = requests.withLock { $0 }
            #expect(sent.map(\.httpMethod) == (completed ? ["POST", "GET"] : ["POST", "GET", "DELETE"]))
            if !completed { #expect(sent.last?.url?.path == "/api/upload-sessions/\(discoveredId)") }
            #expect(try journal.read(id: cancelled.id, access: access) == cancelled)
            #expect(try Data(contentsOf: original) == originalBytes)
        }
    }

    @Test
    @MainActor
    func cancellationInspectionKeepsUnreconciledKnownIdentifiersPending() async throws {
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
        let otherId = "A1234567-0000-4000-8000-000000000001"
        let (journal, job) = try await prepareJob(
            access: access, directory: directory, assetId: assetId, sessionId: sessionId)
        let cancelled = try journal.requestCancellation(for: job, access: access)
        let original = try journal.originalURL(for: cancelled, access: access)
        let originalBytes = try Data(contentsOf: original)
        let requests = Mutex<[URLRequest]>([])
        let nullFence = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            requests.withLock { $0.append(request) }
            return (Data(#"{"assetId":null,"sessionIds":[]}"#.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let missingAsset = try await nullFence.fenceCancellation(for: cancelled)
        await #expect(throws: OriginalUploadAPIError.cancellationNeedsReconciliation) {
            try await nullFence.inspectCancelledSession(sessionId, for: cancelled, using: missingAsset)
        }
        let (_, assetOnlyAccess, assetOnlyJournal, assetOnly) = try await prepareCancelledJob(
            directory: directory, assetId: assetId)
        let assetOnlyOriginal = try assetOnlyJournal.originalURL(for: assetOnly, access: assetOnlyAccess)
        let assetOnlyOriginalBytes = try Data(contentsOf: assetOnlyOriginal)
        let assetOnlyAPI = try OriginalUploadAPI(access: assetOnlyAccess, journal: assetOnlyJournal, transport: { request in
            requests.withLock { $0.append(request) }
            return (Data(#"{"assetId":null,"sessionIds":[]}"#.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let missingKnownAsset = try await assetOnlyAPI.fenceCancellation(for: assetOnly)
        await #expect(throws: OriginalUploadAPIError.cancellationNeedsReconciliation) {
            try await assetOnlyAPI.inspectCancelledSession(sessionId, for: assetOnly, using: missingKnownAsset)
        }

        let page = try cancellationPage(assetId: assetId, sessionIds: [otherId])
        let missingSessionAPI = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            requests.withLock { $0.append(request) }
            return (page, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let traversal = try OriginalUploadCancellationTraversal(api: missingSessionAPI, job: cancelled)
        _ = try await traversal.nextPage()
        let missingSession = try #require(try traversal.completedEnumeration())
        await #expect(throws: OriginalUploadAPIError.cancellationNeedsReconciliation) {
            try await missingSessionAPI.inspectCancelledSession(otherId, for: cancelled, using: missingSession)
        }
        let overflow = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            requests.withLock { $0.append(request) }
            return (Data(#"{"code":"INTENT_SESSION_LIMIT"}"#.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: OriginalUploadAPIError.cancellationSessionLimit) {
            try await overflow.fenceCancellation(for: cancelled)
        }
        let sent = requests.withLock { $0 }
        #expect(sent.count == 4)
        #expect(sent.map(\.httpMethod) == ["POST", "POST", "GET", "POST"])
        #expect(try journal.read(id: job.id, access: access) == cancelled)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try assetOnlyJournal.read(id: assetOnly.id, access: assetOnlyAccess) == assetOnly)
        #expect(try Data(contentsOf: assetOnlyOriginal) == assetOnlyOriginalBytes)
    }

    @Test
    @MainActor
    func cancellationInspectionValidatesSessionResponsesAndBounds() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let (_, access, journal, cancelled) = try await prepareCancelledJob(directory: directory)
        let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
        let fence = try JSONSerialization.data(withJSONObject: ["assetId": assetId, "sessionIds": [sessionId]])
        let response = Mutex((data: fence, status: 200, tooLarge: false))
        let requests = Mutex<[URLRequest]>([])
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            requests.withLock { $0.append(request) }
            let current = response.withLock { $0 }
            if current.tooLarge { throw URLError(.dataLengthExceedsMaximum) }
            return (current.data, HTTPURLResponse(
                url: request.url!, statusCode: current.status, httpVersion: nil, headerFields: nil)!)
        })
        let enumeration = try await api.fenceCancellation(for: cancelled)
        func inspect(data: Data, status: Int = 200) async throws -> OriginalUploadServerSession {
            response.withLock { $0 = (data, status, false) }
            return try await api.inspectCancelledSession(sessionId, for: cancelled, using: enumeration).session
        }
        let part = cancelled.manifest.parts[0]
        let wrongDigest = String(repeating: part.sha256.first == "a" ? "b" : "a", count: 64)
        let recordedPart: [String: Any] = [
            "partNumber": 1, "sizeBytes": String(part.byteCount), "sha256": part.sha256,
        ]
        let valid = try cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId)
        let validJSON = try #require(String(data: valid, encoding: .utf8))
        let statusField = #""status":"OPEN""#
        try #require(validJSON.contains(statusField))
        let duplicateStatus = Data(validJSON.replacingOccurrences(
            of: statusField, with: #""status":"OPEN","\u0073tatus":"ABORTED""#).utf8)
        let invalid = try [
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["id": sessionId.uppercased()]),
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["id": sessionId + "\0suffix"]),
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["assetId": assetId.uppercased()]),
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["assetId": assetId + "\0suffix"]),
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["clipId": assetId + "\0suffix"]),
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["expectedSizeBytes": "999"]),
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["expectedSha256": wrongDigest]),
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["partSizeBytes": 0]),
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["partCount": 2]),
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["expiresAt": "invalid"]),
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["status": "UNKNOWN"]),
            cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId,
                                        overrides: ["parts": [recordedPart, recordedPart]]),
            Data(#"{"uploadSession":{}}"#.utf8),
            duplicateStatus,
            Data(repeating: 0x20, count: 65_537),
        ]
        for data in invalid {
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await inspect(data: data)
            }
        }
        let mismatchedPart: [String: Any] = [
            "partNumber": 1, "sizeBytes": String(part.byteCount), "sha256": wrongDigest,
        ]
        for status in ["OPEN", "COMPLETING", "COMPLETED"] {
            let body = try cancellationSessionResponse(
                job: cancelled, assetId: assetId, sessionId: sessionId,
                status: status, overrides: ["parts": [mismatchedPart]])
            await #expect(throws: OriginalUploadAPIError.partMismatch) {
                try await inspect(data: body)
            }
        }
        for status in ["ABORTED", "EXPIRED"] {
            let body = try cancellationSessionResponse(
                job: cancelled, assetId: assetId, sessionId: sessionId,
                status: status, overrides: ["parts": [mismatchedPart]])
            #expect(try await inspect(data: body).status.rawValue == status)
            for overrides in [["expectedSizeBytes": "999"], ["expectedSha256": wrongDigest]] {
                let wrongFingerprint = try cancellationSessionResponse(
                    job: cancelled, assetId: assetId, sessionId: sessionId, status: status, overrides: overrides)
                await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                    try await inspect(data: wrongFingerprint)
                }
            }
        }
        try #require(valid.count < 65_536)
        let maximum = valid + Data(repeating: 0x20, count: 65_536 - valid.count)
        #expect(try await inspect(data: maximum).status == .open)
        for data in try nonUTF8JSON(String(decoding: valid, as: UTF8.self)) {
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await inspect(data: data)
            }
        }
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await inspect(data: valid, status: 201)
        }
        for status in [401, 404, 429, 503] {
            let count = requests.withLock { $0.count }
            await #expect(throws: OriginalUploadAPIError.httpStatus(status)) {
                try await inspect(data: valid, status: status)
            }
            #expect(requests.withLock { $0.count } == count + 1)
        }
        response.withLock { $0.tooLarge = true }
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api.inspectCancelledSession(sessionId, for: cancelled, using: enumeration)
        }
        #expect(requests.withLock { $0.dropFirst().allSatisfy { $0.httpMethod == "GET" } })
        #expect(try journal.read(id: cancelled.id, access: access) == cancelled)
    }

    @Test
    @MainActor
    func cancellationInspectionBindsEvidenceToJobAndAuthentication() async throws {
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
        let cancelled = try journal.requestCancellation(for: job, access: access)
        let fence = try JSONSerialization.data(withJSONObject: ["assetId": assetId, "sessionIds": [sessionId]])
        let requests = Mutex<[URLRequest]>([])
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            requests.withLock { $0.append(request) }
            return (fence, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: transport)
        let enumeration = try await api.fenceCancellation(for: cancelled)
        let session = try cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId)
        let otherIssuer = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            requests.withLock { $0.append(request) }
            return (session, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await otherIssuer.inspectCancelledSession(sessionId, for: cancelled, using: enumeration)
        }
        let (_, otherJob) = try await prepareJob(access: access, directory: directory)
        let otherCancelled = try journal.requestCancellation(for: otherJob, access: access)
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api.inspectCancelledSession(sessionId, for: otherCancelled, using: enumeration)
        }
        let otherEnumeration = try await api.fenceCancellation(for: otherCancelled)
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await otherIssuer.inspectCancelledSession(sessionId, for: otherCancelled, using: otherEnumeration)
        }
        #expect(requests.withLock { $0.count } == 2)
        let updated = try journal.update(cancelled, access: access)
        await #expect(throws: OriginalUploadStorageError.staleJob) {
            try await api.inspectCancelledSession(sessionId, for: cancelled, using: enumeration)
        }
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await api.inspectCancelledSession(sessionId, for: updated, using: enumeration)
        }
        let updatedEnumeration = try await api.fenceCancellation(for: updated)

        auth.logout()
        auth.token = "test-token"
        auth.currentUser = user
        await #expect(throws: OriginalUploadAPIError.sessionChanged) {
            try await api.inspectCancelledSession(sessionId, for: updated, using: updatedEnumeration)
        }
        let freshAccess = try OriginalUploadAccess(auth: auth, allowedOrigins: ["https://isolated.example.test"])
        let freshAPI = try OriginalUploadAPI(access: freshAccess, journal: journal, transport: transport)
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await freshAPI.inspectCancelledSession(sessionId, for: updated, using: updatedEnumeration)
        }
        let otherUser = User(
            id: "user-2", phoneNumber: "5550101", name: "Other", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let otherAuth = AuthService(storage: .memory, serverURL: { server })
        otherAuth.token = "test-token"
        otherAuth.currentUser = otherUser
        let otherUserAccess = try OriginalUploadAccess(
            auth: otherAuth, allowedOrigins: ["https://isolated.example.test"])
        let otherUserAPI = try OriginalUploadAPI(access: otherUserAccess, journal: journal, transport: transport)
        await #expect(throws: OriginalUploadAPIError.sessionChanged) {
            try await otherUserAPI.inspectCancelledSession(sessionId, for: updated, using: updatedEnumeration)
        }
        let otherServer = URL(string: "https://other.example.test")!
        let otherServerAuth = AuthService(storage: .memory, serverURL: { otherServer })
        otherServerAuth.token = "test-token"
        otherServerAuth.currentUser = user
        let otherAccess = try OriginalUploadAccess(
            auth: otherServerAuth, allowedOrigins: ["https://other.example.test"])
        let otherAPI = try OriginalUploadAPI(access: otherAccess, journal: journal, transport: transport)
        await #expect(throws: OriginalUploadAPIError.sessionChanged) {
            try await otherAPI.inspectCancelledSession(sessionId, for: updated, using: updatedEnumeration)
        }
        #expect(requests.withLock { $0.count } == 3)
        #expect(try journal.read(id: job.id, access: freshAccess).cancellationRequested)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationInspectionRejectsInflightCancellationAndIdentityChanges() async throws {
        enum Change { case cancelTask, journal, signOut }
        for change in [Change.cancelTask, .journal, .signOut] {
            let directory = try fixture()
            defer { cleanup(directory) }
            let (auth, access, journal, cancelled) = try await prepareCancelledJob(directory: directory)
            let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
            let fence = try JSONSerialization.data(withJSONObject: [
                "assetId": assetId, "sessionIds": [sessionId],
            ])
            let session = try cancellationSessionResponse(job: cancelled, assetId: assetId, sessionId: sessionId)
            let original = try journal.originalURL(for: cancelled, access: access)
            let originalBytes = try Data(contentsOf: original)
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let requests = Mutex<[URLRequest]>([])
            defer { entered.continuation.finish(); release.continuation.finish() }
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                requests.withLock { $0.append(request) }
                if request.httpMethod == "POST" {
                    return (fence, HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                entered.continuation.yield()
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
                return (session, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let enumeration = try await api.fenceCancellation(for: cancelled)
            let request = Task {
                try await api.inspectCancelledSession(sessionId, for: cancelled, using: enumeration)
            }
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
            #expect(requests.withLock { $0.map(\.httpMethod) } == ["POST", "GET"])
            #expect(try Data(contentsOf: original) == originalBytes)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancellationAbortDiscardsLateResponsesAfterCancellationChanges() async throws {
        enum Change { case cancelTask, journal, signOut }
        let cases: [(Bool, Change)] = [
            (false, .cancelTask), (false, .journal), (false, .signOut),
            (true, .cancelTask), (true, .journal), (true, .signOut),
        ]
        for (hasKnownSession, change) in cases {
            let directory = try fixture()
            defer { cleanup(directory) }
            let assetId = "ab123456-789a-4bcd-8abc-0123456789ab"
            let targetId = hasKnownSession ? "A1234567-0000-4000-8000-000000000001" : sessionId
            let (auth, access, journal, cancelled) = try await prepareCancelledJob(
                directory: directory, assetId: hasKnownSession ? assetId : nil,
                sessionId: hasKnownSession ? sessionId : nil)
            let user = try #require(auth.currentUser)
            let fence = try JSONSerialization.data(withJSONObject: [
                "assetId": assetId, "sessionIds": hasKnownSession ? [sessionId, targetId] : [targetId],
            ])
            let inspected = try cancellationSessionResponse(
                job: cancelled, assetId: assetId, sessionId: targetId)
            let aborted = Data(#"{"uploadSession":{"id":"\#(targetId)","status":"ABORTED"}}"#.utf8)
            let original = try journal.originalURL(for: cancelled, access: access)
            let originalBytes = try Data(contentsOf: original)
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let requests = Mutex<[URLRequest]>([])
            defer { entered.continuation.finish(); release.continuation.finish() }
            let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                requests.withLock { $0.append(request) }
                if request.httpMethod == "POST" {
                    return (fence, HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                if request.httpMethod == "GET" {
                    return (inspected, HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                entered.continuation.yield()
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
                return (aborted, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let enumeration = try await api.fenceCancellation(for: cancelled)
            let inspection = try await api.inspectCancelledSession(
                targetId, for: cancelled, using: enumeration)
            let request = Task { try await api.abort(cancelled, using: inspection) }
            var iterator = entered.stream.makeAsyncIterator()
            try #require(await iterator.next() != nil)
            let expected: OriginalUploadJob
            switch change {
            case .cancelTask:
                request.cancel()
                expected = cancelled
            case .journal:
                expected = try journal.update(cancelled, access: access)
            case .signOut:
                auth.logout()
                expected = cancelled
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
            #expect(requests.withLock { $0.map(\.httpMethod) } == ["POST", "GET", "DELETE"])
            #expect(requests.withLock { $0.last?.url?.path } == "/api/upload-sessions/\(targetId)")
            let verificationAccess: OriginalUploadAccess
            if case .signOut = change {
                auth.token = "test-token"
                auth.currentUser = user
                verificationAccess = try OriginalUploadAccess(
                    auth: auth, allowedOrigins: ["https://isolated.example.test"])
            } else {
                verificationAccess = access
            }
            #expect(try journal.read(id: cancelled.id, access: verificationAccess) == expected)
            #expect(try Data(contentsOf: original) == originalBytes)
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
        let assetId = try #require(job.assetId)
        let fence = try JSONSerialization.data(withJSONObject: [
            "assetId": assetId, "sessionIds": [sessionId],
        ])
        let requests = Mutex<[URLRequest]>([])
        func api(
            status: Int = 200, body: Data,
            inspectionStatus: OriginalUploadServerSession.Status = .open
        ) throws -> OriginalUploadAPI {
            requests.withLock { $0.removeAll() }
            let inspection = try cancellationSessionResponse(
                job: cancelled, assetId: assetId, sessionId: sessionId, status: inspectionStatus.rawValue)
            let client = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
                requests.withLock { $0.append(request) }
                let response: Data
                let responseStatus: Int
                switch request.httpMethod {
                case "POST":
                    response = fence
                    responseStatus = 200
                case "GET":
                    response = inspection
                    responseStatus = 200
                default:
                    response = body
                    responseStatus = status
                }
                return (response, HTTPURLResponse(
                    url: request.url!, statusCode: responseStatus, httpVersion: nil, headerFields: nil)!)
            })
            return client
        }

        func inspected(_ client: OriginalUploadAPI) async throws -> OriginalUploadCancellationInspection {
            let enumeration = try await client.fenceCancellation(for: cancelled)
            return try await client.inspectCancelledSession(sessionId, for: cancelled, using: enumeration)
        }

        for status in ["ABORTED", "EXPIRED"] {
            let body = Data(#"{"uploadSession":{"id":"\#(sessionId)","status":"\#(status)"}}"#.utf8)
            let client = try api(body: body)
            try await client.abort(cancelled, using: inspected(client))
            #expect(requests.withLock { $0.map(\.httpMethod) } == ["POST", "GET", "DELETE"])
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
            let rejected = try api(status: status, body: Data(body.utf8))
            let inspection = try await inspected(rejected)
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await rejected.abort(cancelled, using: inspection)
            }
            #expect(requests.withLock { $0.map(\.httpMethod) } == ["POST", "GET", "DELETE"])
        }
        let abortJSON = #"{"uploadSession":{"id":"\#(sessionId)","status":"ABORTED"}}"#
        for data in try nonUTF8JSON(abortJSON) {
            let rejected = try api(body: data)
            let inspection = try await inspected(rejected)
            await #expect(throws: OriginalUploadAPIError.invalidResponse) {
                try await rejected.abort(cancelled, using: inspection)
            }
            #expect(requests.withLock { $0.map(\.httpMethod) } == ["POST", "GET", "DELETE"])
        }
        let throttled = try api(status: 429, body: Data(#"{"error":"ignored"}"#.utf8))
        let inspection = try await inspected(throttled)
        await #expect(throws: OriginalUploadAPIError.httpStatus(429)) {
            try await throttled.abort(cancelled, using: inspection)
        }
        #expect(requests.withLock { $0.map(\.httpMethod) } == ["POST", "GET", "DELETE"])

        let completedAPI = try api(
            body: Data(#"{"uploadSession":{"id":"\#(sessionId)","status":"ABORTED"}}"#.utf8),
            inspectionStatus: .completed)
        let completedInspection = try await inspected(completedAPI)
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await completedAPI.abort(cancelled, using: completedInspection)
        }
        #expect(requests.withLock { $0.map(\.httpMethod) } == ["POST", "GET"])

        let sourceAPI = try api(
            body: Data(#"{"uploadSession":{"id":"\#(sessionId)","status":"ABORTED"}}"#.utf8))
        let sourceInspection = try await inspected(sourceAPI)
        let foreignRequests = Mutex<[URLRequest]>([])
        let foreignAPI = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            foreignRequests.withLock { $0.append(request) }
            return (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: OriginalUploadAPIError.invalidResponse) {
            try await foreignAPI.abort(cancelled, using: sourceInspection)
        }
        #expect(foreignRequests.withLock { $0.isEmpty })
        #expect(requests.withLock { $0.map(\.httpMethod) } == ["POST", "GET"])
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
        let sent = Mutex<[URLRequest]>([])
        let fenceResponse = try JSONSerialization.data(withJSONObject: [
            "assetId": assetId, "sessionIds": [sessionId],
        ])
        let inspectionResponse = try cancellationSessionResponse(
            job: job, assetId: assetId, sessionId: sessionId)
        let abortResponse = Data(
            #"{"uploadSession":{"id":"\#(sessionId)","status":"ABORTED"}}"#.utf8)
        let api = try OriginalUploadAPI(access: access, journal: journal, transport: { request in
            sent.withLock { $0.append(request) }
            let data = switch request.httpMethod {
            case "POST": fenceResponse
            case "GET": inspectionResponse
            default: abortResponse
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
        #expect(sent.withLock { $0.isEmpty })
        let enumeration = try await api.fenceCancellation(for: cancelled)
        let inspection = try await api.inspectCancelledSession(
            sessionId, for: cancelled, using: enumeration)
        try await api.abort(cancelled, using: inspection)
        #expect(sent.withLock { $0.map(\.httpMethod) } == ["POST", "GET", "DELETE"])
    }
}
