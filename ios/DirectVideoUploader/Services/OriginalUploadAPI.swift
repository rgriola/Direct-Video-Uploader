import Foundation

nonisolated enum OriginalUploadAPIError: LocalizedError, Equatable {
    case unavailable
    case invalidOrigin
    case invalidCapability
    case invalidResponse
    case partMismatch
    case sessionChanged
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Original uploads are available only for isolated testing."
        case .invalidOrigin: "Original uploads require an isolated HTTPS server."
        case .invalidCapability: "The server returned an invalid upload address."
        case .invalidResponse: "The server returned invalid upload information."
        case .partMismatch: "The server has different bytes for this upload part."
        case .sessionChanged: "The account or server changed. Reopen this upload under its original account."
        case .httpStatus(let status): "The original upload service returned HTTP \(status)."
        }
    }
}

nonisolated struct OriginalUploadServerPart: Decodable, Equatable, Sendable {
    let partNumber: Int
    let sizeBytes: String
    let sha256: String
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
        try validateStructure(for: job)
        try validatePartDigests(for: job)
    }

    func validateForRecovery(for job: OriginalUploadJob) throws {
        try validateStructure(for: job)
        if status != .aborted && status != .expired {
            try validatePartDigests(for: job)
        }
    }

    private func validateStructure(for job: OriginalUploadJob) throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: assetId) != nil,
              UUID(uuidString: clipId) != nil, assetId == job.assetId,
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

    private let access: OriginalUploadAccess
    private let journal: OriginalUploadJournal
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var token: String { access.snapshot.token }

    init(
        access: OriginalUploadAccess,
        journal: OriginalUploadJournal = .shared,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RedirectSafeTransport.data(for: $0)
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
        try ensureCurrent(job, allowsCancellation: true)
        guard [.uploading, .stored].contains(job.state), let sessionId = job.sessionId else {
            throw OriginalUploadAPIError.invalidResponse
        }
        let data = try await request(
            job: job, path: "/api/upload-sessions/\(sessionId)", method: "GET", allowsCancellation: true)
        try ensureCurrent(job, allowsCancellation: true)
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

    func abort(_ job: OriginalUploadJob) async throws {
        try ensureCurrent(job, allowsCancellation: true)
        guard job.state == .uploading, let sessionId = job.sessionId else {
            throw OriginalUploadAPIError.invalidResponse
        }
        _ = try await request(
            job: job, path: "/api/upload-sessions/\(sessionId)", method: "DELETE", allowsCancellation: true)
        try ensureCurrent(job, allowsCancellation: true)
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

    private func request<Body: Encodable>(
        job: OriginalUploadJob, path: String, method: String, body: Body
    ) async throws -> Data {
        var request = try makeRequest(path: path, method: method)
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request, job: job)
    }

    private func request(
        job: OriginalUploadJob, path: String, method: String, allowsCancellation: Bool = false
    ) async throws -> Data {
        try await perform(
            makeRequest(path: path, method: method), job: job, allowsCancellation: allowsCancellation)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard access.isCurrent, let url = URL(string: path, relativeTo: access.origin)?.absoluteURL else {
            throw OriginalUploadAPIError.sessionChanged
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func perform(
        _ request: URLRequest, job: OriginalUploadJob, allowsCancellation: Bool = false
    ) async throws -> Data {
        try Task.checkCancellation()
        try ensureCurrent(job, allowsCancellation: allowsCancellation)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            try Task.checkCancellation()
            try ensureCurrent(job, allowsCancellation: allowsCancellation)
            throw error
        }
        try Task.checkCancellation()
        try ensureCurrent(job, allowsCancellation: allowsCancellation)
        guard let http = response as? HTTPURLResponse else { throw OriginalUploadAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw OriginalUploadAPIError.httpStatus(http.statusCode)
        }
        return data
    }
}
