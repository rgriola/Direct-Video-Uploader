import Foundation

nonisolated private enum OriginalUploadResponseLimit {
    // Server limits include 100 UUIDs per cancellation receipt/page and at most
    // 10 50-MiB parts per 500-MiB upload; other response text can vary.
    static let maximumBytes = 64 * 1024
}

nonisolated enum OriginalUploadAPIError: LocalizedError, Equatable {
    case unavailable
    case invalidOrigin
    case invalidCapability
    case invalidResponse
    case partMismatch
    case sessionChanged
    case cancellationQuota(retryAfterSeconds: Int)
    case cancellationSessionLimit
    case cancellationPageRateLimited(retryAfterSeconds: Int)
    case cancellationPageRetryAfterInvalid
    case cancellationPageResponseUnknown
    case cancellationTraversalLimit
    case cancellationTraversalInProgress
    case cancellationNeedsReconciliation
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Original uploads are available only for isolated testing."
        case .invalidOrigin: "Original uploads require an isolated HTTPS server."
        case .invalidCapability: "The server returned an invalid upload address."
        case .invalidResponse: "The server returned invalid upload information."
        case .partMismatch: "The server has different bytes for this upload part."
        case .sessionChanged: "The account or server changed. Reopen this upload under its original account."
        case .cancellationQuota(let seconds): "Too many cancellation requests. Try again in \(seconds) seconds."
        case .cancellationSessionLimit: "This cancellation needs server reconciliation before it can finish."
        case .cancellationPageRateLimited(let seconds):
            "Too many cancellation history requests. Try again in \(seconds) seconds."
        case .cancellationPageRetryAfterInvalid:
            "The cancellation history retry delay could not be verified."
        case .cancellationPageResponseUnknown:
            "The cancellation history response was not received. A safely scheduled restart is required."
        case .cancellationTraversalLimit: "This cancellation history needs server reconciliation before it can finish."
        case .cancellationTraversalInProgress: "A cancellation history request is already in progress."
        case .cancellationNeedsReconciliation:
            "The cancellation's known upload information needs server reconciliation."
        case .httpStatus(let status): "The original upload service returned HTTP \(status)."
        }
    }
}

nonisolated struct OriginalUploadServerPart: Decodable, Equatable, Sendable {
    let partNumber: Int
    let sizeBytes: String
    let sha256: String
}

nonisolated private enum OriginalUploadResponseJSON {
    private static let maximumDepth = 64

    private struct Container {
        let close: UInt8
        let objectIndex: Int?
        var expectsKey: Bool
    }

    static func objectKeys(in data: Data) throws -> [Set<String>] {
        try Task.checkCancellation()
        do {
            let keys = try scanObjectKeys(in: data)
            try Task.checkCancellation()
            return keys
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private static func scanObjectKeys(in data: Data) throws -> [Set<String>] {
        // The byte scanner and Foundation must interpret the same UTF-8 input.
        guard data.count <= OriginalUploadResponseLimit.maximumBytes,
              !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw OriginalUploadAPIError.invalidResponse
        }
        // Foundation validates syntax but collapses duplicate object keys.
        var keys: [Set<String>] = []
        var stack: [Container] = []
        var index = data.startIndex
        while index < data.endIndex {
            switch data[index] {
            case 0x7B:
                guard stack.count < maximumDepth else { throw OriginalUploadAPIError.invalidResponse }
                keys.append([])
                stack.append(Container(close: 0x7D, objectIndex: keys.count - 1, expectsKey: true))
            case 0x5B:
                guard stack.count < maximumDepth else { throw OriginalUploadAPIError.invalidResponse }
                stack.append(Container(close: 0x5D, objectIndex: nil, expectsKey: false))
            case 0x7D, 0x5D:
                guard stack.last?.close == data[index] else { throw OriginalUploadAPIError.invalidResponse }
                stack.removeLast()
            case 0x2C:
                if !stack.isEmpty, stack[stack.count - 1].objectIndex != nil {
                    stack[stack.count - 1].expectsKey = true
                }
            case 0x22:
                let start = index
                index = data.index(after: index)
                var escaped = false
                while index < data.endIndex {
                    let byte = data[index]
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        break
                    }
                    index = data.index(after: index)
                }
                guard index < data.endIndex else { throw OriginalUploadAPIError.invalidResponse }
                if let objectIndex = stack.last?.objectIndex, stack.last?.expectsKey == true {
                    let end = data.index(after: index)
                    let key = try JSONDecoder().decode(String.self, from: data.subdata(in: start..<end))
                    guard keys[objectIndex].insert(key).inserted else {
                        throw OriginalUploadAPIError.invalidResponse
                    }
                    stack[stack.count - 1].expectsKey = false
                }
            default:
                break
            }
            index = data.index(after: index)
        }
        guard stack.isEmpty else { throw OriginalUploadAPIError.invalidResponse }
        return keys
    }
}

nonisolated private enum OriginalUploadCancellationIdentifier {
    static func isUUID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }

    static func isSession(_ value: String) -> Bool {
        guard isUUID(value) else { return false }
        let bytes = Array(value.utf8)
        // The server requires UUID versions 1-8 and the RFC variant.
        return "12345678".utf8.contains(bytes[14]) && "89AaBb".utf8.contains(bytes[19])
    }
}

nonisolated enum OriginalUploadCancellationValidation {
    static func preservingCancellation<T>(_ validate: () throws -> T) throws -> T {
        do {
            let result = try validate()
            try Task.checkCancellation()
            return result
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    static func requireDisjoint(_ seen: Set<String>, _ page: [String]) throws {
        try preservingCancellation {
            guard seen.isDisjoint(with: page) else {
                throw OriginalUploadAPIError.invalidResponse
            }
        }
    }
}

nonisolated struct OriginalUploadCancellationReceipt: Decodable, Equatable, Sendable {
    static let maximumSessions = 100
    let assetId: String?
    let sessionIds: [String]

    static func decode(_ data: Data) throws -> Self {
        try decode(data, using: { try JSONDecoder().decode(Self.self, from: $0) })
    }

    #if DEBUG
    static func decodeForTesting(_ data: Data, using decoder: (Data) throws -> Self) throws -> Self {
        try decode(data, using: decoder)
    }
    #endif

    private static func decode(_ data: Data, using decoder: (Data) throws -> Self) throws -> Self {
        try OriginalUploadCancellationValidation.preservingCancellation {
            do {
                let keys = try OriginalUploadResponseJSON.objectKeys(in: data)
                guard keys.count == 1, keys[0] == Set(["assetId", "sessionIds"]) else {
                    throw OriginalUploadAPIError.invalidResponse
                }
                return try decoder(data)
            } catch is DecodingError {
                throw OriginalUploadAPIError.invalidResponse
            }
        }
    }

    func validate(for job: OriginalUploadJob) throws {
        try OriginalUploadCancellationValidation.preservingCancellation {
            guard sessionIds.count <= Self.maximumSessions, assetId != nil || sessionIds.isEmpty else {
                throw OriginalUploadAPIError.invalidResponse
            }
            guard sessionIds.allSatisfy(OriginalUploadCancellationIdentifier.isSession),
                  Set(sessionIds).count == sessionIds.count else {
                throw OriginalUploadAPIError.invalidResponse
            }
            if let assetId {
                guard OriginalUploadCancellationIdentifier.isUUID(assetId) else {
                    throw OriginalUploadAPIError.invalidResponse
                }
                if let expected = job.assetId {
                    guard expected == assetId else { throw OriginalUploadAPIError.invalidResponse }
                }
                if let expected = job.sessionId {
                    guard sessionIds.contains(expected) else {
                        throw OriginalUploadAPIError.invalidResponse
                    }
                }
            }
        }
    }
}

nonisolated struct OriginalUploadCancellationPage: Sendable {
    struct Continuation: Sendable {
        fileprivate let jobId: UUID
        fileprivate let incarnation: UUID
        fileprivate let revision: UInt64
        fileprivate let scope: PendingFormScope
        fileprivate let sessionGeneration: UUID
        fileprivate let assetId: String
        fileprivate let after: String
    }

    let assetId: String?
    let sessionIds: [String]
    let continuation: Continuation?
}

nonisolated struct OriginalUploadCancellationEnumeration: Sendable {
    let assetId: String?
    let sessionIds: Set<String>
    fileprivate let jobId: UUID
    fileprivate let incarnation: UUID
    fileprivate let revision: UInt64
    fileprivate let scope: PendingFormScope
    fileprivate let server: String
    fileprivate let sessionGeneration: UUID
    fileprivate let issuer: UUID
}

nonisolated struct OriginalUploadCancellationInspection: Sendable {
    let session: OriginalUploadServerSession
    fileprivate let enumeration: OriginalUploadCancellationEnumeration

    fileprivate init(
        session: OriginalUploadServerSession, enumeration: OriginalUploadCancellationEnumeration
    ) {
        self.session = session
        self.enumeration = enumeration
    }
}

@MainActor
fileprivate final class OriginalUploadTransportHandoff {
    var invoked = false
}

@MainActor
final class OriginalUploadCancellationTraversal {
    private static let maximumPages = 100

    private let api: OriginalUploadAPI
    private let job: OriginalUploadJob
    private let now: @Sendable () -> ContinuousClock.Instant
    private var continuation: OriginalUploadCancellationPage.Continuation?
    private var assetId: String?
    private var seenSessionIds: Set<String> = []
    private var pageCount = 0
    private var finished = false
    private var inFlight = false
    private var retryNotBefore: ContinuousClock.Instant?
    private var invalidRetryAfter = false
    private var responseUnknown = false

    init(
        api: OriginalUploadAPI, job: OriginalUploadJob,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) throws {
        try api.ensureCancellationCurrent(job)
        self.api = api
        self.job = job
        self.now = now
    }

    func nextPage(
        onResponse: (@MainActor (Int, Int?) -> Void)? = nil,
        onDispatch: (@MainActor () -> Void)? = nil
    ) async throws -> OriginalUploadCancellationPage? {
        try Task.checkCancellation()
        try api.ensureCancellationCurrent(job)
        guard !inFlight else { throw OriginalUploadAPIError.cancellationTraversalInProgress }
        if finished { return nil }
        guard pageCount < Self.maximumPages else { throw OriginalUploadAPIError.cancellationTraversalLimit }
        guard !invalidRetryAfter else { throw OriginalUploadAPIError.cancellationPageRetryAfterInvalid }
        guard !responseUnknown else { throw OriginalUploadAPIError.cancellationPageResponseUnknown }
        if let retryNotBefore {
            let current = now()
            if current < retryNotBefore {
                let remaining = current.duration(to: retryNotBefore).components
                let seconds = Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0)
                throw OriginalUploadAPIError.cancellationPageRateLimited(retryAfterSeconds: seconds)
            }
            self.retryNotBefore = nil
        }

        inFlight = true
        var observedResponse = false
        let handoff = OriginalUploadTransportHandoff()
        defer {
            if handoff.invoked && !observedResponse { responseUnknown = true }
            inFlight = false
        }
        let page = try await api.cancellationSessions(
            for: job, continuation: continuation, onResponse: { status, seconds in
                observedResponse = true
                onResponse?(status, seconds)
                guard status == 429 else { return }
                if let seconds {
                    self.retryNotBefore = self.now().advanced(by: .seconds(seconds))
                } else {
                    self.invalidRetryAfter = true
                }
            }, onDispatch: onDispatch, handoff: handoff)
        try Task.checkCancellation()
        try api.ensureCancellationCurrent(job)
        try OriginalUploadCancellationValidation.requireDisjoint(seenSessionIds, page.sessionIds)
        assetId = page.assetId
        seenSessionIds.formUnion(page.sessionIds)
        pageCount += 1
        continuation = page.continuation
        finished = continuation == nil
        return page
    }

    func completedEnumeration() throws -> OriginalUploadCancellationEnumeration? {
        try Task.checkCancellation()
        try api.ensureCancellationCurrent(job)
        guard finished else { return nil }
        // Enumerating server pages does not prove remote or local cleanup.
        return api.cancellationEnumeration(for: job, assetId: assetId, sessionIds: seenSessionIds)
    }
}

nonisolated struct OriginalUploadServerSession: Decodable, Sendable {
    enum Status: String, Decodable, Sendable {
        case open = "OPEN"
        case completing = "COMPLETING"
        case completed = "COMPLETED"
        case aborted = "ABORTED"
        case expired = "EXPIRED"
    }

    let id: String
    let assetId: String
    let clipId: String
    let status: Status
    let expectedSizeBytes: String
    let expectedSha256: String
    let partSizeBytes: Int64
    let partCount: Int
    let expiresAt: String
    let completedAt: String?
    let parts: [OriginalUploadServerPart]

    func validate(for job: OriginalUploadJob) throws {
        try validateStructure(for: job, expectedAssetId: job.assetId)
        try validatePartDigests(for: job)
    }

    func validateForRecovery(for job: OriginalUploadJob) throws {
        try validateForRecovery(for: job, expectedAssetId: job.assetId)
    }

    fileprivate func validateForRecovery(for job: OriginalUploadJob, expectedAssetId: String?) throws {
        try validateStructure(for: job, expectedAssetId: expectedAssetId)
        if status != .aborted && status != .expired {
            try validatePartDigests(for: job)
        }
    }

    private func validateStructure(for job: OriginalUploadJob, expectedAssetId: String?) throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: assetId) != nil,
              UUID(uuidString: clipId) != nil, assetId == expectedAssetId,
              expectedSizeBytes == String(job.fingerprint.byteCount),
              expectedSha256 == job.fingerprint.sha256,
              partSizeBytes == OriginalUploadFiles.maximumPartSize,
              partCount == Int((job.fingerprint.byteCount + partSizeBytes - 1) / partSizeBytes),
              DVUDateFormatting.parseISO(expiresAt) != nil else {
            throw OriginalUploadAPIError.invalidResponse
        }
        var seen: Set<Int> = []
        for part in parts {
            guard part.partNumber > 0, part.partNumber <= partCount,
                  seen.insert(part.partNumber).inserted,
                  let size = Int64(part.sizeBytes),
                  size == min(partSizeBytes, job.fingerprint.byteCount
                    - Int64(part.partNumber - 1) * partSizeBytes),
                  part.sha256.count == 64,
                  part.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw OriginalUploadAPIError.invalidResponse
            }
        }
    }

    private func validatePartDigests(for job: OriginalUploadJob) throws {
        for part in parts {
            guard part.sha256 == job.manifest.parts[part.partNumber - 1].sha256 else {
                throw OriginalUploadAPIError.partMismatch
            }
        }
    }
}

nonisolated struct OriginalUploadSignedPart: Decodable, Sendable {
    let url: String
    let partNumber: Int
    let sizeBytes: Int64
    let expiresAt: String
}

nonisolated struct OriginalUploadPartCapability: Sendable {
    let url: URL
    let jobId: UUID
    let jobIncarnation: UUID
    let sessionId: String
    let partNumber: Int
    let sizeBytes: Int64
    let expiresAt: Date
    let scope: PendingFormScope
    let origin: String
    let sessionGeneration: UUID

    fileprivate init(
        url: URL, jobId: UUID, jobIncarnation: UUID, sessionId: String,
        partNumber: Int, sizeBytes: Int64, expiresAt: Date,
        scope: PendingFormScope, origin: String, sessionGeneration: UUID
    ) {
        self.url = url
        self.jobId = jobId
        self.jobIncarnation = jobIncarnation
        self.sessionId = sessionId
        self.partNumber = partNumber
        self.sizeBytes = sizeBytes
        self.expiresAt = expiresAt
        self.scope = scope
        self.origin = origin
        self.sessionGeneration = sessionGeneration
    }

    @MainActor
    func require(
        job: OriginalUploadJob, part: OriginalUploadPart, access: OriginalUploadAccess, now: Date
    ) throws {
        guard access.isCurrent, job.scope == access.scope, scope == access.scope,
              origin == access.snapshot.server, sessionGeneration == access.snapshot.generation,
              jobId == job.id, jobIncarnation == job.incarnation, sessionId == job.sessionId,
              partNumber == part.number,
              sizeBytes == part.fingerprint.byteCount, expiresAt > now else {
            throw OriginalUploadAPIError.invalidCapability
        }
    }
}

nonisolated enum OriginalUploadURL {
    static func origin(
        _ url: URL, forbiddenHosts: Set<String>, allowedOrigins: Set<String>
    ) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty else { throw OriginalUploadAPIError.invalidOrigin }
        let host = String(rawHost.reversed().drop(while: { $0 == "." }).reversed())
        guard !host.isEmpty,
              !forbiddenHosts.contains(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw OriginalUploadAPIError.invalidOrigin
        }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = components.port
        guard let result = origin.url, allowedOrigins.contains(result.absoluteString) else {
            throw OriginalUploadAPIError.invalidOrigin
        }
        return result
    }

    static func signedPart(
        _ signed: OriginalUploadSignedPart, origin: URL, sessionId: String,
        partNumber: Int, expectedSize: Int64, sessionExpiry: Date, now: Date
    ) throws -> URL {
        guard UUID(uuidString: sessionId) != nil, partNumber > 0, expectedSize > 0,
              signed.partNumber == partNumber, signed.sizeBytes == expectedSize,
              !signed.url.hasPrefix("//"),
              let relative = URLComponents(string: signed.url),
              relative.scheme == nil, relative.host == nil,
              relative.user == nil, relative.password == nil, relative.fragment == nil,
              relative.percentEncodedPath == "/api/upload-sessions/\(sessionId)/parts/\(partNumber)",
              let query = relative.queryItems, query.count == 2,
              let expires = query.first(where: { $0.name == "expires" })?.value,
              expires.allSatisfy({ ("0"..."9").contains($0) }),
              let expiration = Int64(expires), expiration > 0,
              let signature = query.first(where: { $0.name == "signature" })?.value,
              signature.count == 64,
              signature.allSatisfy({ "0123456789abcdef".contains($0) }),
              let date = DVUDateFormatting.parseISO(signed.expiresAt),
              date.timeIntervalSince1970 == TimeInterval(expiration),
              date > now, date <= now.addingTimeInterval(330), date <= sessionExpiry,
              let result = URL(string: signed.url, relativeTo: origin)?.absoluteURL,
              let target = URLComponents(url: result, resolvingAgainstBaseURL: false),
              let base = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              target.scheme == base.scheme, target.host == base.host, target.port == base.port else {
            throw OriginalUploadAPIError.invalidCapability
        }
        return result
    }
}

@MainActor
final class OriginalUploadCancellationGate {
    fileprivate static let shared = OriginalUploadCancellationGate()

    private let now: @Sendable () -> ContinuousClock.Instant
    private var inFlight = false
    private var blocked: Bool
    private var retryNotBefore: ContinuousClock.Instant?
    private var localChecks: Set<UUID> = []

    private init() {
        now = { ContinuousClock.now }
        // A restart cannot establish whether an earlier request left an unknown retry delay.
        blocked = true
    }

    #if DEBUG
    init(testingNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        now = testingNow
        blocked = false
    }
    #endif

    fileprivate func acquire() throws {
        guard !blocked else { throw OriginalUploadCancellationCoordinatorError.reconciliationRequired }
        guard localChecks.isEmpty else { throw OriginalUploadCancellationCoordinatorError.busy }
        guard !inFlight else { throw OriginalUploadCancellationCoordinatorError.busy }
        if let retryNotBefore {
            let current = now()
            if current < retryNotBefore {
                let remaining = current.duration(to: retryNotBefore).components
                let seconds = Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0)
                throw OriginalUploadCancellationCoordinatorError.rateLimited(retryAfterSeconds: seconds)
            }
            self.retryNotBefore = nil
        }
        inFlight = true
    }

    fileprivate func park() { blocked = true }

    fileprivate func beginLocalCheck() -> UUID {
        let token = UUID()
        localChecks.insert(token)
        return token
    }

    fileprivate func endLocalCheck(_ token: UUID) {
        localChecks.remove(token)
    }

    fileprivate func validateHeld() throws {
        guard inFlight, !blocked else {
            throw OriginalUploadCancellationCoordinatorError.reconciliationRequired
        }
        guard localChecks.isEmpty else { throw OriginalUploadCancellationCoordinatorError.busy }
    }

    fileprivate func releaseUndispatched() { inFlight = false }

    fileprivate func complete(status: Int?, retryAfter: Int?) {
        inFlight = false
        guard let status, (200...599).contains(status) else {
            blocked = true
            return
        }
        if status == 429 {
            guard let retryAfter else {
                blocked = true
                return
            }
            retryNotBefore = now().advanced(by: .seconds(retryAfter))
        } else {
            retryNotBefore = nil
        }
    }
}

@MainActor
final class OriginalUploadAPI {
    private struct Reservation: Encodable {
        let clientRequestId: String
        let fileName: String?
        let expectedSizeBytes: String
        let expectedSha256: String
    }

    private struct SessionRequest: Encodable {
        let expectedSizeBytes: String
        let expectedSha256: String
        let metadata: VideoMetadata
    }

    private struct SessionResponse: Decodable {
        let uploadSession: OriginalUploadServerSession
    }

    private struct ErrorResponse: Decodable {
        let code: String?
    }

    private struct CancellationPageResponse: Decodable {
        let assetId: String?
        let sessionIds: [String]
        let nextCursor: String?
    }

    private struct AbortResponse: Decodable {
        struct Session: Decodable {
            let id: String
            let status: OriginalUploadServerSession.Status
        }

        let uploadSession: Session
    }

    private let access: OriginalUploadAccess
    private let journal: OriginalUploadJournal
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var cancellationGate = OriginalUploadCancellationGate.shared
    private let evidenceIssuer = UUID()
    private var token: String { access.snapshot.token }

    init(
        access: OriginalUploadAccess,
        journal: OriginalUploadJournal = .shared,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RedirectSafeTransport.boundedData(
                for: $0, maximumBytes: OriginalUploadResponseLimit.maximumBytes)
        }
    ) throws {
        #if !DEBUG
        throw OriginalUploadAPIError.unavailable
        #else
        guard access.isCurrent else {
            throw OriginalUploadAPIError.sessionChanged
        }
        self.access = access
        self.journal = journal
        self.transport = transport
        #endif
    }

    #if DEBUG
    var testingUsesSharedGate: Bool { cancellationGate === OriginalUploadCancellationGate.shared }

    convenience init(
        access: OriginalUploadAccess, journal: OriginalUploadJournal = .shared,
        testingGate: OriginalUploadCancellationGate,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) throws {
        try self.init(access: access, journal: journal, transport: transport)
        cancellationGate = testingGate
    }
    #endif

    func reserve(_ job: OriginalUploadJob) async throws -> Asset {
        try ensureCurrent(job)
        guard job.state == .reserving, !job.cancellationRequested else {
            throw OriginalUploadAPIError.invalidResponse
        }
        let body = Reservation(
            clientRequestId: job.id.uuidString.lowercased(), fileName: job.fileName,
            expectedSizeBytes: String(job.fingerprint.byteCount),
            expectedSha256: job.fingerprint.sha256)
        let data = try await request(
            job: job, path: "/api/assets/original-uploads", method: "POST", body: body)
        try ensureCurrent(job)
        let asset = try JSONDecoder().decode(CreateAssetResponse.self, from: data).asset
        guard UUID(uuidString: asset.id) != nil, asset.uploadMode == .original else {
            throw OriginalUploadAPIError.invalidResponse
        }
        return asset
    }

    func createSession(for job: OriginalUploadJob) async throws -> OriginalUploadServerSession {
        try ensureCurrent(job)
        guard [.reserving, .uploading].contains(job.state), !job.cancellationRequested,
              let assetId = job.assetId else {
            throw OriginalUploadAPIError.invalidResponse
        }
        let body = SessionRequest(
            expectedSizeBytes: String(job.fingerprint.byteCount),
            expectedSha256: job.fingerprint.sha256, metadata: job.metadata)
        let data = try await request(
            job: job, path: "/api/assets/\(assetId)/upload-sessions", method: "POST", body: body)
        try ensureCurrent(job)
        return try decodeSession(data, job: job)
    }

    func session(for job: OriginalUploadJob) async throws -> OriginalUploadServerSession {
        try ensureCurrent(job)
        guard [.uploading, .stored].contains(job.state), let sessionId = job.sessionId else {
            throw OriginalUploadAPIError.invalidResponse
        }
        let data = try await request(
            job: job, path: "/api/upload-sessions/\(sessionId)", method: "GET")
        try ensureCurrent(job)
        let session = try decodeSession(data, job: job, forRecovery: true)
        guard session.id == sessionId else { throw OriginalUploadAPIError.invalidResponse }
        return session
    }

    func sign(
        for job: OriginalUploadJob, session: OriginalUploadServerSession, partNumber: Int
    ) async throws -> OriginalUploadPartCapability {
        try ensureCurrent(job)
        guard job.state == .uploading, !job.cancellationRequested, let sessionId = job.sessionId,
              (1...job.manifest.parts.count).contains(partNumber),
              session.id == sessionId, session.status == .open,
              let sessionExpiry = DVUDateFormatting.parseISO(session.expiresAt) else {
            throw OriginalUploadAPIError.invalidResponse
        }
        try session.validate(for: job)
        let expectedSize = job.manifest.parts[partNumber - 1].byteCount
        let data = try await request(
            job: job, path: "/api/upload-sessions/\(sessionId)/parts/\(partNumber)/sign", method: "POST")
        try ensureCurrent(job)
        let signed = try JSONDecoder().decode(OriginalUploadSignedPart.self, from: data)
        let url = try OriginalUploadURL.signedPart(
            signed, origin: access.origin, sessionId: sessionId,
            partNumber: partNumber, expectedSize: expectedSize,
            sessionExpiry: sessionExpiry, now: Date())
        guard let expiresAt = DVUDateFormatting.parseISO(signed.expiresAt) else {
            throw OriginalUploadAPIError.invalidCapability
        }
        return OriginalUploadPartCapability(
            url: url, jobId: job.id, jobIncarnation: job.incarnation,
            sessionId: sessionId, partNumber: partNumber,
            sizeBytes: expectedSize, expiresAt: expiresAt, scope: access.scope,
            origin: access.snapshot.server, sessionGeneration: access.snapshot.generation)
    }

    func complete(_ job: OriginalUploadJob) async throws -> OriginalUploadServerSession {
        try ensureCurrent(job)
        guard job.state == .uploading, !job.cancellationRequested, let sessionId = job.sessionId else {
            throw OriginalUploadAPIError.invalidResponse
        }
        let data = try await request(
            job: job, path: "/api/upload-sessions/\(sessionId)/complete", method: "POST")
        try ensureCurrent(job)
        let session = try decodeSession(data, job: job)
        guard session.id == sessionId, session.status == .completed else {
            throw OriginalUploadAPIError.invalidResponse
        }
        return session
    }

    func cancelIntent(
        for job: OriginalUploadJob, onResponse: (@MainActor (Int, Int?) -> Void)? = nil,
        onDispatch: (@MainActor () -> Void)? = nil
    ) async throws -> OriginalUploadCancellationReceipt {
        try ensureCurrent(job, allowsCancellation: true)
        guard job.cancellationRequested else { throw OriginalUploadAPIError.invalidResponse }
        let data = try await request(
            job: job, path: "/api/assets/original-uploads/\(job.id.uuidString.lowercased())/cancel",
            method: "POST", allowsCancellation: true, expectedStatus: 200, cancellationFence: true,
            onResponse: onResponse, onDispatch: onDispatch)
        try ensureCurrent(job, allowsCancellation: true)
        let receipt = try OriginalUploadCancellationReceipt.decode(data)
        try receipt.validate(for: job)
        return receipt
    }

    func fenceCancellation(
        for job: OriginalUploadJob, onResponse: (@MainActor (Int, Int?) -> Void)? = nil,
        onDispatch: (@MainActor () -> Void)? = nil
    ) async throws -> OriginalUploadCancellationEnumeration {
        let receipt = try await cancelIntent(for: job, onResponse: onResponse, onDispatch: onDispatch)
        try Task.checkCancellation()
        try ensureCancellationCurrent(job)
        return cancellationEnumeration(for: job, assetId: receipt.assetId, sessionIds: Set(receipt.sessionIds))
    }

    func inspectCancelledSession(
        _ sessionId: String, for job: OriginalUploadJob, using enumeration: OriginalUploadCancellationEnumeration
    ) async throws -> OriginalUploadCancellationInspection {
        try Task.checkCancellation()
        try ensureCancellationCurrent(job)
        guard enumeration.jobId == job.id, enumeration.incarnation == job.incarnation,
              enumeration.revision == job.revision, enumeration.scope == job.scope,
              enumeration.server == access.snapshot.server,
              enumeration.sessionGeneration == access.snapshot.generation,
              enumeration.issuer == evidenceIssuer else {
            throw OriginalUploadAPIError.invalidResponse
        }
        guard job.assetId.map({ $0 == enumeration.assetId }) ?? true,
              job.sessionId.map({ enumeration.sessionIds.contains($0) }) ?? true else {
            throw OriginalUploadAPIError.cancellationNeedsReconciliation
        }
        guard let assetId = enumeration.assetId,
              OriginalUploadCancellationIdentifier.isSession(sessionId),
              enumeration.sessionIds.contains(sessionId) else {
            throw OriginalUploadAPIError.invalidResponse
        }
        let data = try await request(
            job: job, path: "/api/upload-sessions/\(sessionId)", method: "GET",
            allowsCancellation: true, expectedStatus: 200)
        try ensureCancellationCurrent(job)
        let session: OriginalUploadServerSession
        do {
            session = try JSONDecoder().decode(SessionResponse.self, from: data).uploadSession
        } catch is DecodingError {
            throw OriginalUploadAPIError.invalidResponse
        }
        guard session.id == sessionId, OriginalUploadCancellationIdentifier.isUUID(session.clipId) else {
            throw OriginalUploadAPIError.invalidResponse
        }
        try session.validateForRecovery(for: job, expectedAssetId: assetId)
        try Task.checkCancellation()
        return OriginalUploadCancellationInspection(session: session, enumeration: enumeration)
    }

    func cancellationSessions(
        for job: OriginalUploadJob, continuation: OriginalUploadCancellationPage.Continuation? = nil,
        onResponse: (@MainActor (Int, Int?) -> Void)? = nil,
        onDispatch: (@MainActor () -> Void)? = nil
    ) async throws -> OriginalUploadCancellationPage {
        try await cancellationSessions(
            for: job, continuation: continuation, onResponse: onResponse, onDispatch: onDispatch, handoff: nil)
    }

    fileprivate func cancellationSessions(
        for job: OriginalUploadJob, continuation: OriginalUploadCancellationPage.Continuation?,
        onResponse: (@MainActor (Int, Int?) -> Void)?,
        onDispatch: (@MainActor () -> Void)?, handoff: OriginalUploadTransportHandoff?
    ) async throws -> OriginalUploadCancellationPage {
        try Task.checkCancellation()
        try ensureCancellationCurrent(job)
        if let continuation {
            try OriginalUploadCancellationValidation.preservingCancellation {
                guard continuation.jobId == job.id, continuation.incarnation == job.incarnation,
                      continuation.revision == job.revision, continuation.scope == job.scope,
                      continuation.sessionGeneration == access.snapshot.generation,
                      job.assetId.map({ $0 == continuation.assetId }) ?? true else {
                    throw OriginalUploadAPIError.invalidResponse
                }
            }
        }
        let query = continuation.map { "?after=\($0.after)" } ?? ""
        let data = try await request(
            job: job, path: "/api/assets/original-uploads/\(job.id.uuidString.lowercased())/sessions\(query)",
            method: "GET", allowsCancellation: true, expectedStatus: 200, cancellationPage: true,
            onResponse: onResponse, onDispatch: onDispatch, handoff: handoff)
        try ensureCurrent(job, allowsCancellation: true)
        return try OriginalUploadCancellationValidation.preservingCancellation {
            let response: CancellationPageResponse
            do {
                let keys = try OriginalUploadResponseJSON.objectKeys(in: data)
                guard keys.count == 1, keys[0] == Set(["assetId", "sessionIds", "nextCursor"]) else {
                    throw OriginalUploadAPIError.invalidResponse
                }
                response = try JSONDecoder().decode(CancellationPageResponse.self, from: data)
            } catch is DecodingError {
                throw OriginalUploadAPIError.invalidResponse
            }
            guard response.sessionIds.count <= OriginalUploadCancellationReceipt.maximumSessions,
                  response.sessionIds.allSatisfy(OriginalUploadCancellationIdentifier.isSession),
                  Set(response.sessionIds).count == response.sessionIds.count else {
                throw OriginalUploadAPIError.invalidResponse
            }
            if let assetId = response.assetId {
                guard OriginalUploadCancellationIdentifier.isUUID(assetId),
                      job.assetId.map({ $0 == assetId }) ?? true else {
                    throw OriginalUploadAPIError.invalidResponse
                }
            } else {
                guard response.sessionIds.isEmpty, response.nextCursor == nil else {
                    throw OriginalUploadAPIError.invalidResponse
                }
            }
            if let continuation {
                guard response.assetId == continuation.assetId,
                      !response.sessionIds.contains(continuation.after) else {
                    throw OriginalUploadAPIError.invalidResponse
                }
            }
            let next: OriginalUploadCancellationPage.Continuation?
            if let cursor = response.nextCursor {
                guard response.sessionIds.count == OriginalUploadCancellationReceipt.maximumSessions,
                      let assetId = response.assetId, cursor == response.sessionIds.last else {
                    throw OriginalUploadAPIError.invalidResponse
                }
                next = OriginalUploadCancellationPage.Continuation(
                    jobId: job.id, incarnation: job.incarnation, revision: job.revision,
                    scope: job.scope, sessionGeneration: access.snapshot.generation,
                    assetId: assetId, after: cursor)
            } else {
                next = nil
            }
            // A server page is not proof that local or remote cleanup has finished.
            return OriginalUploadCancellationPage(
                assetId: response.assetId, sessionIds: response.sessionIds, continuation: next)
        }
    }

    func abort(
        _ job: OriginalUploadJob, using inspection: OriginalUploadCancellationInspection
    ) async throws {
        try Task.checkCancellation()
        try ensureCancellationCurrent(job)
        let session = inspection.session
        let enumeration = inspection.enumeration
        guard enumeration.jobId == job.id, enumeration.incarnation == job.incarnation,
              enumeration.revision == job.revision, enumeration.scope == job.scope,
              enumeration.server == access.snapshot.server,
              enumeration.sessionGeneration == access.snapshot.generation,
              enumeration.issuer == evidenceIssuer,
              [.reserving, .uploading].contains(job.state),
              job.sessionId.map({ enumeration.sessionIds.contains($0) }) ?? true,
              enumeration.sessionIds.contains(session.id),
              enumeration.assetId == session.assetId,
              job.assetId.map({ $0 == session.assetId }) ?? true,
              session.status != .completed else {
            throw OriginalUploadAPIError.invalidResponse
        }
        let sessionId = session.id
        let data = try await request(
            job: job, path: "/api/upload-sessions/\(sessionId)", method: "DELETE",
            allowsCancellation: true, expectedStatus: 200)
        try ensureCancellationCurrent(job)
        let response: AbortResponse
        do {
            let keys = try OriginalUploadResponseJSON.objectKeys(in: data)
            guard keys.count == 2, keys[0] == ["uploadSession"],
                  keys[1] == Set(["id", "status"]) else {
                throw OriginalUploadAPIError.invalidResponse
            }
            response = try JSONDecoder().decode(AbortResponse.self, from: data)
        } catch is DecodingError {
            throw OriginalUploadAPIError.invalidResponse
        }
        guard response.uploadSession.id == sessionId,
              [.aborted, .expired].contains(response.uploadSession.status) else {
            throw OriginalUploadAPIError.invalidResponse
        }
    }

    private func decodeSession(
        _ data: Data, job: OriginalUploadJob, forRecovery: Bool = false
    ) throws -> OriginalUploadServerSession {
        let session = try JSONDecoder().decode(SessionResponse.self, from: data).uploadSession
        if forRecovery {
            try session.validateForRecovery(for: job)
        } else {
            try session.validate(for: job)
        }
        return session
    }

    private func ensureCurrent(_ job: OriginalUploadJob, allowsCancellation: Bool = false) throws {
        guard access.isCurrent, job.scope == access.scope else { throw OriginalUploadAPIError.sessionChanged }
        let current = try journal.read(id: job.id, access: access)
        guard current == job else { throw OriginalUploadStorageError.staleJob }
        if !allowsCancellation {
            guard !current.cancellationRequested, try !journal.isCancellationBlocked(for: job) else {
                throw OriginalUploadStorageError.cancellationRequested
            }
        }
    }

    fileprivate func ensureCancellationCurrent(_ job: OriginalUploadJob) throws {
        try ensureCurrent(job, allowsCancellation: true)
        guard job.cancellationRequested else { throw OriginalUploadAPIError.invalidResponse }
    }

    fileprivate func cancellationEnumeration(
        for job: OriginalUploadJob, assetId: String?, sessionIds: Set<String>
    ) -> OriginalUploadCancellationEnumeration {
        OriginalUploadCancellationEnumeration(
            assetId: assetId, sessionIds: sessionIds, jobId: job.id, incarnation: job.incarnation,
            revision: job.revision, scope: job.scope, server: access.snapshot.server,
            sessionGeneration: access.snapshot.generation, issuer: evidenceIssuer)
    }

    private func request<Body: Encodable>(
        job: OriginalUploadJob, path: String, method: String, body: Body
    ) async throws -> Data {
        var request = try makeRequest(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request, job: job)
    }

    private func request(
        job: OriginalUploadJob, path: String, method: String, allowsCancellation: Bool = false,
        expectedStatus: Int? = nil, cancellationFence: Bool = false, cancellationPage: Bool = false,
        onResponse: (@MainActor (Int, Int?) -> Void)? = nil,
        onDispatch: (@MainActor () -> Void)? = nil, handoff: OriginalUploadTransportHandoff? = nil
    ) async throws -> Data {
        try await perform(
            makeRequest(path: path, method: method), job: job, allowsCancellation: allowsCancellation,
            expectedStatus: expectedStatus, cancellationFence: cancellationFence, cancellationPage: cancellationPage,
            onResponse: onResponse, onDispatch: onDispatch, handoff: handoff)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard access.isCurrent, let url = URL(string: path, relativeTo: access.origin)?.absoluteURL else {
            throw OriginalUploadAPIError.sessionChanged
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(
        _ request: URLRequest, job: OriginalUploadJob, allowsCancellation: Bool = false,
        expectedStatus: Int? = nil, cancellationFence: Bool = false, cancellationPage: Bool = false,
        onResponse: (@MainActor (Int, Int?) -> Void)? = nil,
        onDispatch: (@MainActor () -> Void)? = nil, handoff: OriginalUploadTransportHandoff? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        try ensureCurrent(job, allowsCancellation: allowsCancellation)
        let gated = cancellationPage || cancellationFence
        if gated { try cancellationGate.acquire() }
        let data: Data
        let response: URLResponse
        onDispatch?()
        if gated {
            do {
                try Task.checkCancellation()
                try ensureCurrent(job, allowsCancellation: allowsCancellation)
                try cancellationGate.validateHeld()
            } catch {
                cancellationGate.releaseUndispatched()
                throw error
            }
        }
        // No caller code or suspension may intervene between this marker and transport handoff.
        handoff?.invoked = true
        do {
            (data, response) = try await transport(request)
        } catch {
            if gated { cancellationGate.complete(status: nil, retryAfter: nil) }
            try Task.checkCancellation()
            try ensureCurrent(job, allowsCancellation: allowsCancellation)
            if (error as? URLError)?.code == .dataLengthExceedsMaximum {
                throw OriginalUploadAPIError.invalidResponse
            }
            throw error
        }
        if gated {
            let http = response as? HTTPURLResponse
            let seconds = http.flatMap { $0.statusCode == 429 ? Self.retryAfterSeconds(from: $0) : nil }
            // Commit the outcome before cancellation, authentication checks, or observer callbacks.
            cancellationGate.complete(status: http?.statusCode, retryAfter: seconds)
            if let http { onResponse?(http.statusCode, seconds) }
        }
        try Task.checkCancellation()
        try ensureCurrent(job, allowsCancellation: allowsCancellation)
        guard data.count <= OriginalUploadResponseLimit.maximumBytes else {
            throw OriginalUploadAPIError.invalidResponse
        }
        guard let http = response as? HTTPURLResponse else { throw OriginalUploadAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if cancellationPage, http.statusCode == 429 {
                guard let seconds = Self.retryAfterSeconds(from: http) else {
                    throw OriginalUploadAPIError.cancellationPageRetryAfterInvalid
                }
                throw OriginalUploadAPIError.cancellationPageRateLimited(retryAfterSeconds: seconds)
            }
            if cancellationFence, [429, 503].contains(http.statusCode) {
                let error: ErrorResponse
                do {
                    _ = try OriginalUploadResponseJSON.objectKeys(in: data)
                    error = try JSONDecoder().decode(ErrorResponse.self, from: data)
                } catch is DecodingError {
                    throw OriginalUploadAPIError.httpStatus(http.statusCode)
                } catch OriginalUploadAPIError.invalidResponse {
                    throw OriginalUploadAPIError.httpStatus(http.statusCode)
                }
                if http.statusCode == 429, error.code == "INTENT_CANCELLATION_QUOTA" {
                    guard let seconds = Self.retryAfterSeconds(from: http) else {
                        throw OriginalUploadAPIError.invalidResponse
                    }
                    throw OriginalUploadAPIError.cancellationQuota(retryAfterSeconds: seconds)
                }
                if http.statusCode == 503, error.code == "INTENT_SESSION_LIMIT" {
                    throw OriginalUploadAPIError.cancellationSessionLimit
                }
            }

            throw OriginalUploadAPIError.httpStatus(http.statusCode)
        }
        if let expectedStatus, http.statusCode != expectedStatus {
            throw OriginalUploadAPIError.invalidResponse
        }
        do {
            _ = try OriginalUploadResponseJSON.objectKeys(in: data)
        } catch is DecodingError {
            throw OriginalUploadAPIError.invalidResponse
        }
        return data
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> Int? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After"),
              !header.isEmpty, header.allSatisfy({ ("0"..."9").contains($0) }),
              let seconds = Int(header), (1...86_400).contains(seconds) else {
            return nil
        }
        return seconds
    }
}

nonisolated enum OriginalUploadCancellationCoordinatorError: LocalizedError, Equatable {
    case alreadyStarted
    case busy
    case reconciliationRequired
    case rateLimited(retryAfterSeconds: Int)

    var errorDescription: String? {
        switch self {
        case .alreadyStarted: "This cancellation has already been started in this app session."
        case .busy: "Another cancellation request is in progress."
        case .reconciliationRequired: "This cancellation needs reconciliation before it can continue."
        case .rateLimited(let seconds): "Try cancellation reconciliation again in \(seconds) seconds."
        }
    }
}

nonisolated struct OriginalUploadCancellationObservation: Sendable {
    let job: OriginalUploadJob
    let requestedTaskIdentifiers: Set<Int>
    let hasUnidentifiedTasks: Bool
    let abortAcknowledgedSessionIds: Set<String>
    let completedSessionIds: Set<String>
    let terminalSessionIds: Set<String>
}

@MainActor
final class OriginalUploadCancellationCoordinator {
    fileprivate struct Key: Hashable {
        let scope: PendingFormScope
        let jobId: UUID
    }

    private enum Phase {
        case ready
        case running
        case parked
        case finished
    }

    final class State {
        fileprivate var owners: Set<Key> = []
        fileprivate let gate: OriginalUploadCancellationGate

        fileprivate init(gate: OriginalUploadCancellationGate) {
            self.gate = gate
        }

        #if DEBUG
        convenience init(
            testingGate: OriginalUploadCancellationGate = OriginalUploadCancellationGate(testingNow: { ContinuousClock.now })
        ) {
            self.init(gate: testingGate)
        }
        #endif
    }

    private static let sharedState = State(gate: .shared)

    private let key: Key
    private let job: OriginalUploadJob
    private var access: OriginalUploadAccess?
    private let journal: OriginalUploadJournal
    private let taskFence: OriginalUploadTaskFence
    private var api: OriginalUploadAPI?
    private var phase: Phase = .ready
    private var state = sharedState

    #if DEBUG
    var testingUsesSharedGate: Bool {
        state.gate === OriginalUploadCancellationGate.shared && api?.testingUsesSharedGate == true
    }
    #endif

    init(
        job: OriginalUploadJob, access: OriginalUploadAccess, journal: OriginalUploadJournal,
        taskFence: OriginalUploadTaskFence,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RedirectSafeTransport.boundedData(
                for: $0, maximumBytes: OriginalUploadResponseLimit.maximumBytes)
        }
    ) throws {
        try access.require(job.scope)
        guard journal.usesTaskFence(taskFence) else { throw OriginalUploadStorageError.invalidRecord }
        self.key = Key(scope: job.scope, jobId: job.id)
        self.job = job
        self.access = access
        self.journal = journal
        self.taskFence = taskFence
        self.api = try OriginalUploadAPI(access: access, journal: journal, transport: transport)
    }

    #if DEBUG
    convenience init(
        job: OriginalUploadJob, access: OriginalUploadAccess, journal: OriginalUploadJournal,
        taskFence: OriginalUploadTaskFence, testingState: State,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) throws {
        try self.init(job: job, access: access, journal: journal, taskFence: taskFence, transport: transport)
        self.state = testingState
        self.api = try OriginalUploadAPI(
            access: access, journal: journal, testingGate: testingState.gate, transport: transport)
    }
    #endif

    func start<TaskHandle>(
        tasks: @MainActor () async -> [TaskHandle],
        snapshot: @MainActor (TaskHandle) -> OriginalBackgroundTaskSnapshot,
        cancel: @MainActor (TaskHandle) -> Void
    ) async throws -> OriginalUploadCancellationObservation {
        guard case .ready = phase else { throw OriginalUploadCancellationCoordinatorError.alreadyStarted }
        do {
            try Task.checkCancellation()
        } catch {
            park()
            throw error
        }
        guard let access, let api else { throw OriginalUploadCancellationCoordinatorError.reconciliationRequired }
        guard state.owners.insert(key).inserted else {
            park()
            throw OriginalUploadCancellationCoordinatorError.alreadyStarted
        }
        phase = .running
        let local: OriginalBackgroundCancellationResult
        do {
            let localCheck = state.gate.beginLocalCheck()
            defer { state.gate.endLocalCheck(localCheck) }
            do {
                local = try await OriginalBackgroundCancellation.request(
                    for: job, journal: journal, fence: taskFence, access: access,
                    tasks: tasks, snapshot: snapshot, cancel: cancel, requireFreshCancellation: true)
                try requireActive(local.job, api: api)
            } catch OriginalUploadStorageError.cancellationRequested {
                state.gate.park()
                park()
                throw OriginalUploadCancellationCoordinatorError.reconciliationRequired
            } catch {
                park()
                throw error
            }
        }
        do {
            let observation = try await fence(local, api: api)
            try requireActive(local.job, api: api)
            phase = .finished
            self.access = nil
            self.api = nil
            return observation
        } catch {
            park()
            throw error
        }
    }

    func invalidate() {
        park()
    }

    private func park() {
        phase = .parked
        access = nil
        api = nil
    }

    private func requireActive(_ job: OriginalUploadJob, api: OriginalUploadAPI) throws {
        try Task.checkCancellation()
        guard self.api === api, let access, access.isCurrent else { throw OriginalUploadAPIError.sessionChanged }
        try api.ensureCancellationCurrent(job)
    }

    private func fence(
        _ local: OriginalBackgroundCancellationResult, api: OriginalUploadAPI
    ) async throws -> OriginalUploadCancellationObservation {
        let enumeration: OriginalUploadCancellationEnumeration
        do {
            try requireActive(local.job, api: api)
            enumeration = try await api.fenceCancellation(for: local.job)
        } catch OriginalUploadAPIError.cancellationSessionLimit {
            try requireActive(local.job, api: api)
            let traversal = try OriginalUploadCancellationTraversal(api: api, job: local.job)
            return try await traverse(local, traversal: traversal, api: api)
        }
        try requireActive(local.job, api: api)
        return try await inspect(local, enumeration: enumeration, api: api)
    }

    private func traverse(
        _ local: OriginalBackgroundCancellationResult, traversal: OriginalUploadCancellationTraversal,
        api: OriginalUploadAPI
    ) async throws -> OriginalUploadCancellationObservation {
        while try traversal.completedEnumeration() == nil {
            try requireActive(local.job, api: api)
            _ = try await traversal.nextPage()
            try requireActive(local.job, api: api)
        }
        guard let enumeration = try traversal.completedEnumeration() else {
            throw OriginalUploadAPIError.cancellationNeedsReconciliation
        }
        return try await inspect(local, enumeration: enumeration, api: api)
    }

    private func inspect(
        _ local: OriginalBackgroundCancellationResult, enumeration: OriginalUploadCancellationEnumeration,
        api: OriginalUploadAPI
    ) async throws -> OriginalUploadCancellationObservation {
        let job = local.job
        try requireActive(job, api: api)
        guard job.assetId.map({ $0 == enumeration.assetId }) ?? true,
              job.sessionId.map({ enumeration.sessionIds.contains($0) }) ?? true else {
            throw OriginalUploadAPIError.cancellationNeedsReconciliation
        }
        var aborted: Set<String> = []
        var completed: Set<String> = []
        var terminal: Set<String> = []
        for id in enumeration.sessionIds.sorted() {
            let inspection = try await api.inspectCancelledSession(id, for: job, using: enumeration)
            try requireActive(job, api: api)
            switch inspection.session.status {
            case .open, .completing:
                try await api.abort(job, using: inspection)
                try requireActive(job, api: api)
                aborted.insert(id)
            case .completed:
                completed.insert(id)
            case .aborted, .expired:
                terminal.insert(id)
            }
        }
        try requireActive(job, api: api)
        return OriginalUploadCancellationObservation(
            job: job, requestedTaskIdentifiers: local.requestedTaskIdentifiers,
            hasUnidentifiedTasks: local.hasUnidentifiedTasks, abortAcknowledgedSessionIds: aborted,
            completedSessionIds: completed, terminalSessionIds: terminal)
    }
}
