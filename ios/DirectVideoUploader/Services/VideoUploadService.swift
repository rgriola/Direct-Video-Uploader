import CryptoKit
import Darwin
import Foundation
import Synchronization
import Observation
import Photos

nonisolated private func isMissingStoredFile(_ error: Error) -> Bool {
    let nsError = error as NSError
    return (nsError.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code))
        || (nsError.domain == NSPOSIXErrorDomain
            && nsError.code == Int(POSIXErrorCode.ENOENT.rawValue))
}

nonisolated func removeTemporaryVideoItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch where isMissingStoredFile(error) {
        return
    } catch {
        Log.error("⚠️ [Video] Could not remove a temporary file: \(Log.describe(error))", logger: Log.media)
    }
}

nonisolated private final class RejectRedirectsDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

nonisolated enum RedirectSafeTransport {
    static let resourceTimeout: TimeInterval = 60
    static let formRequestTimeout: TimeInterval = 30

    private static func cookieFreeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = cookieFreeConfiguration()
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    static func boundedConfiguration() -> URLSessionConfiguration {
        let configuration = configuration()
        configuration.urlCredentialStorage = nil
        return configuration
    }

    private static let session = URLSession(
        configuration: configuration(), delegate: RejectRedirectsDelegate(), delegateQueue: nil)

    private static let boundedSession = URLSession(
        configuration: boundedConfiguration(), delegate: RejectRedirectsDelegate(), delegateQueue: nil)

    static func webSocketSession() -> URLSession {
        URLSession(
            configuration: cookieFreeConfiguration(),
            delegate: RejectRedirectsDelegate(), delegateQueue: nil)
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    @concurrent
    static func boundedData(
        for request: URLRequest, maximumBytes: Int,
        onStart: (@Sendable () -> Void)? = nil,
        onResponse: (@Sendable () -> Void)? = nil,
        onBody: (@Sendable (Int) -> Void)? = nil
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes >= 0 else { throw URLError(.badServerResponse) }
        try Task.checkCancellation()
        onStart?()
        let (bytes, response) = try await boundedSession.bytes(for: request)
        let task = bytes.task
        return try await withTaskCancellationHandler {
            var completed = false
            defer { if !completed { task.cancel() } }
            onResponse?()
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
                if data.count == 1 || data.count == maximumBytes { onBody?(data.count) }
            }
            try Task.checkCancellation()
            completed = true
            return (data, response)
        } onCancel: {
            task.cancel()
        }
    }
}

nonisolated struct VideoContentFingerprint: Codable, Equatable, Sendable {
    let sha256: String
    let byteCount: Int64

    var isValid: Bool {
        byteCount > 0 && sha256.count == 64
            && sha256.allSatisfy { "0123456789abcdef".contains($0) }
    }

    @concurrent
    static func calculate(for url: URL) async throws -> VideoContentFingerprint {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
            byteCount += Int64(chunk.count)
        }
        try Task.checkCancellation()
        guard byteCount > 0 else { throw PhotoAssociationError.invalidFingerprint }
        return VideoContentFingerprint(
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount: byteCount)
    }
}

nonisolated struct ScopedPhotoAssociation: Codable, Equatable, Sendable {
    let photoIdentifier: String
    let fingerprint: VideoContentFingerprint
    let metadata: VideoMetadata
}

nonisolated struct ScopedPhotoAssociationSnapshot: Sendable {
    let assetId: String
    let scope: PendingFormScope
    fileprivate let storeURL: URL
    fileprivate let association: ScopedPhotoAssociation?
    fileprivate let assetRevision: UUID?
    fileprivate let scopeRevision: UUID?

    func matches(assetId: String, scope: PendingFormScope) -> Bool {
        self.assetId == assetId && self.scope == scope
    }
}

nonisolated enum PhotoAssociationError: Error {
    case invalidScope
    case invalidRecord
    case invalidFingerprint
    case durationMismatch
    case previousAssociationNotCleared
}

nonisolated enum ManualPhotoRecovery {
    static func association(
        identifier: String, selected: VideoContentFingerprint, original: VideoContentFingerprint,
        metadata: VideoMetadata
    ) -> ScopedPhotoAssociation? {
        guard !identifier.isEmpty, selected.isValid, selected == original else { return nil }
        return ScopedPhotoAssociation(photoIdentifier: identifier, fingerprint: selected, metadata: metadata)
    }
}

nonisolated func isDamagedPhotoAssociationStore(_ error: any Error) -> Bool {
    if error is DecodingError { return true }
    guard let associationError = error as? PhotoAssociationError else { return false }
    if case .invalidRecord = associationError { return true }
    return false
}

@MainActor
struct ScopedPHAssetIdentifierStore {
    static let shared = ScopedPHAssetIdentifierStore(
        directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])

    nonisolated private struct AssociationKey: Hashable {
        let storeURL: URL
        let assetId: String
    }

    // App-owned store operations are MainActor-isolated. Revisions distinguish
    // same-value writes and reversions across instances while a retry holds a snapshot.
    // This is process-local; raw external writers are not serialized with the commit.
    private static var assetRevisions: [AssociationKey: UUID] = [:]
    private static var scopeRevisions: [URL: UUID] = [:]

    private struct StoreFile: Codable {
        let scope: PendingFormScope
        var associations: [String: ScopedPhotoAssociation]
    }

    private let directory: URL
    private let prepareStagedFile: (URL) throws -> Void
    private let commitStagedFile: (URL, URL) throws -> Void

    init(
        directory: URL,
        prepareStagedFile: @escaping (URL) throws -> Void = {
            try ScopedPHAssetIdentifierStore.protect($0)
        },
        commitStagedFile: @escaping (URL, URL) throws -> Void = {
            try ScopedPHAssetIdentifierStore.atomicReplace(staged: $0, destination: $1)
        }
    ) {
        self.directory = directory
        self.prepareStagedFile = prepareStagedFile
        self.commitStagedFile = commitStagedFile
    }

    func storageURL(for scope: PendingFormScope) throws -> URL {
        guard !scope.userId.isEmpty, PendingFormScope.isValidDigest(scope.server) else {
            throw PhotoAssociationError.invalidScope
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encodedScope = try encoder.encode(scope)
        let digest = SHA256.hash(data: encodedScope)
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("phasset-identifiers-v3-\(digest).json")
    }

    func protectLegacyFile() throws {
        let url = directory.appendingPathComponent("phasset-identifiers.json")
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        } catch where isMissingStoredFile(error) {
            return
        }
    }

    func association(assetId: String, for scope: PendingFormScope) throws -> ScopedPhotoAssociation? {
        guard !assetId.isEmpty else { throw PhotoAssociationError.invalidRecord }
        return try load(for: scope).associations[assetId]
    }

    func snapshot(assetId: String, for scope: PendingFormScope) throws -> ScopedPhotoAssociationSnapshot {
        guard !assetId.isEmpty else { throw PhotoAssociationError.invalidRecord }
        let key = try associationKey(assetId: assetId, for: scope)
        let association = try load(for: scope).associations[assetId]
        return ScopedPhotoAssociationSnapshot(
            assetId: assetId, scope: scope, storeURL: key.storeURL, association: association,
            assetRevision: Self.assetRevisions[key], scopeRevision: Self.scopeRevisions[key.storeURL])
    }

    @discardableResult
    func replaceIfUnchanged(
        assetId: String, association: ScopedPhotoAssociation?, for scope: PendingFormScope,
        expected: ScopedPhotoAssociationSnapshot
    ) throws -> Bool {
        guard !assetId.isEmpty else { throw PhotoAssociationError.invalidRecord }
        if let association {
            guard !association.photoIdentifier.isEmpty, association.fingerprint.isValid else {
                throw PhotoAssociationError.invalidRecord
            }
        }
        guard expected.matches(assetId: assetId, scope: scope) else { return false }
        let key = try associationKey(assetId: assetId, for: scope)
        guard expected.storeURL == key.storeURL else { return false }
        var file = try load(for: scope)
        guard file.associations[assetId] == expected.association,
              Self.assetRevisions[key] == expected.assetRevision,
              Self.scopeRevisions[key.storeURL] == expected.scopeRevision else { return false }

        // Even a same-value commit supersedes older snapshots; failed writes fail closed.
        Self.assetRevisions[key] = UUID()
        guard file.associations[assetId] != association else { return true }
        file.associations[assetId] = association
        try write(file, for: scope)
        return true
    }

    func save(
        assetId: String, association: ScopedPhotoAssociation, for scope: PendingFormScope
    ) throws {
        guard !assetId.isEmpty, !association.photoIdentifier.isEmpty,
              association.fingerprint.isValid else { throw PhotoAssociationError.invalidRecord }
        var file = try load(for: scope)
        let key = try associationKey(assetId: assetId, for: scope)
        Self.assetRevisions[key] = UUID()
        file.associations[assetId] = association
        try write(file, for: scope)
    }

    func remove(assetId: String, for scope: PendingFormScope) throws {
        guard !assetId.isEmpty else { throw PhotoAssociationError.invalidRecord }
        var file = try load(for: scope)
        let key = try associationKey(assetId: assetId, for: scope)
        Self.assetRevisions[key] = UUID()
        guard file.associations.removeValue(forKey: assetId) != nil else { return }
        try write(file, for: scope)
    }

    @discardableResult
    func quarantineDamagedAssociations(for scope: PendingFormScope) throws -> Bool {
        let url = try storageURL(for: scope)
        do {
            _ = try load(for: scope)
            return false
        } catch is DecodingError {
        } catch PhotoAssociationError.invalidRecord {
        }
        Self.scopeRevisions[canonicalStoreURL(url)] = UUID()
        let quarantine = directory.appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent)-damaged-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: url, to: quarantine)
        return true
    }

    private func associationKey(assetId: String, for scope: PendingFormScope) throws -> AssociationKey {
        AssociationKey(storeURL: canonicalStoreURL(try storageURL(for: scope)), assetId: assetId)
    }

    private func canonicalStoreURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
    }

    private func write(_ file: StoreFile, for scope: PendingFormScope) throws {
        let destination = try storageURL(for: scope)
        let stagingDirectory = try prepareStagingDirectory()
        let staged = stagingDirectory.appendingPathComponent(
            "phasset-identifiers-\(UUID().uuidString).tmp")
        defer { removeTemporaryVideoItem(staged) }
        try JSONEncoder().encode(file).write(
            to: staged, options: [.atomic, .completeFileProtection])
        try prepareStagedFile(staged)
        try commitStagedFile(staged, destination)
    }

    private func prepareStagingDirectory() throws -> URL {
        let stagingDirectory = directory.appendingPathComponent(
            ".photo-association-staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        try Self.protect(stagingDirectory)
        let files = try FileManager.default.contentsOfDirectory(
            at: stagingDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for file in files {
            let name = file.lastPathComponent
            let prefix = "phasset-identifiers-"
            guard name.hasPrefix(prefix), name.hasSuffix(".tmp"),
                  UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil else {
                continue
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true {
                removeTemporaryVideoItem(file)
            }
        }
        return stagingDirectory
    }

    private static func atomicReplace(staged: URL, destination: URL) throws {
        let result = staged.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target -> Int32 in
                guard let source, let target else { return EINVAL }
                return Darwin.rename(source, target) == 0 ? 0 : errno
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }

    private func load(for scope: PendingFormScope) throws -> StoreFile {
        let url = try storageURL(for: scope)
        let data: Data
        do {
            try Self.protect(url)
            data = try Data(contentsOf: url)
        } catch where isMissingStoredFile(error) {
            return StoreFile(scope: scope, associations: [:])
        }
        let file = try JSONDecoder().decode(StoreFile.self, from: data)
        guard file.scope == scope, file.associations.allSatisfy({
            !$0.key.isEmpty && !$0.value.photoIdentifier.isEmpty && $0.value.fingerprint.isValid
        }) else { throw PhotoAssociationError.invalidRecord }
        return file
    }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }

}

// MARK: - Persisted Form State

/// Saved to disk so the app can restore the context form after crash/kill.
nonisolated struct PendingForm: Codable, Sendable {
    let assetId: String
    let originalFileName: String?
    let capturedAt: String?
    let clipCount: Int?
    let duration: Int?
    let thumbnailJPEG: Data?  // JPEG-encoded thumbnail
    let savedAt: Date
}

nonisolated struct PendingFormScope: Codable, Hashable, Sendable {
    private static let digestPrefix = "sha256-v1:"
    let userId: String
    let server: String

    init?(userId: String, serverURL: URL) {
        guard !userId.isEmpty,
              let source = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
              let scheme = source.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = source.host?.lowercased(), !host.isEmpty
        else { return nil }

        var identity = URLComponents()
        identity.scheme = scheme
        identity.host = host
        identity.port = source.port
        identity.percentEncodedPath = source.percentEncodedPath
        guard let server = identity.string else { return nil }

        self.userId = userId
        let digest = SHA256.hash(data: Data(server.utf8))
        self.server = Self.digestPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hasDigestPrefix(_ server: String) -> Bool {
        server.hasPrefix(digestPrefix)
    }

    static func isValidDigest(_ server: String) -> Bool {
        guard hasDigestPrefix(server) else { return false }
        let digest = server.dropFirst(digestPrefix.count)
        return digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

nonisolated struct PendingFormRecord: Codable, Sendable {
    let id: UUID
    let scope: PendingFormScope
    let form: PendingForm
    var autoRecover: Bool? = nil
}

nonisolated enum PendingFormStorageError: Error {
    case invalidScope
    case recordChanged
}

@MainActor
struct PendingFormStore {
    static let shared = PendingFormStore(
        directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])

    private let storageURL: URL
    private let legacyURL: URL

    init(directory: URL) {
        storageURL = directory.appendingPathComponent("pending-forms-v2.json")
        legacyURL = directory.appendingPathComponent("pending-form.json")
    }

    var hasLegacyForm: Bool {
        get throws {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
                return true
            } catch where isMissingStoredFile(error) {
                return false
            }
        }
    }

    func protectLegacyForm() throws {
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: legacyURL.path)
        } catch where isMissingStoredFile(error) {
            return
        }
    }

    func prepareExistingFiles() throws {
        var firstError: Error?
        for url in [storageURL, legacyURL] {
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            } catch where isMissingStoredFile(error) {
                continue
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        do {
            _ = try load()
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    func discardLegacyForm() throws {
        do {
            try FileManager.default.removeItem(at: legacyURL)
        } catch where isMissingStoredFile(error) {
            return
        }
    }

    func save(_ form: PendingForm, for scope: PendingFormScope) throws -> PendingFormRecord {
        var records = try load()
        let autoRecover = records.first {
            $0.scope == scope && $0.form.assetId == form.assetId
        }?.autoRecover
        records.removeAll { $0.scope == scope && $0.form.assetId == form.assetId }
        let record = PendingFormRecord(id: UUID(), scope: scope, form: form, autoRecover: autoRecover)
        records.append(record)
        try write(records)
        return record
    }

    func record(assetId: String, for scope: PendingFormScope) throws -> PendingFormRecord? {
        try load().first { $0.scope == scope && $0.form.assetId == assetId }
    }

    func next(
        for scope: PendingFormScope, assetId: String? = nil, excluding: Set<UUID> = []
    ) throws -> PendingFormRecord? {
        try load().filter {
            $0.scope == scope && !excluding.contains($0.id)
                && $0.autoRecover != false
                && (assetId == nil || $0.form.assetId == assetId)
        }.min {
            if $0.form.savedAt != $1.form.savedAt {
                return $0.form.savedAt < $1.form.savedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func contains(_ record: PendingFormRecord) throws -> Bool {
        try load().contains { $0.id == record.id && $0.scope == record.scope }
    }

    func recoverable(_ record: PendingFormRecord) throws -> PendingFormRecord? {
        try load().first {
            $0.id == record.id && $0.scope == record.scope && $0.autoRecover != false
        }
    }

    func remove(_ record: PendingFormRecord) throws {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == record.id && $0.scope == record.scope })
        else { return }
        records.remove(at: index)
        try write(records)
    }

    func deferToArchive(_ record: PendingFormRecord) throws {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == record.id && $0.scope == record.scope })
        else { throw PendingFormStorageError.recordChanged }
        records[index].autoRecover = false
        try write(records)
    }

    private func load() throws -> [PendingFormRecord] {
        let data: Data
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: storageURL.path)
            data = try Data(contentsOf: storageURL)
        } catch where isMissingStoredFile(error) {
            return []
        }
        let records = try JSONDecoder().decode(
            [PendingFormRecord].self, from: data)
        var needsMigration = false
        let migrated = try records.map { record in
            let server = record.scope.server
            if PendingFormScope.hasDigestPrefix(server) {
                guard PendingFormScope.isValidDigest(server), !record.scope.userId.isEmpty else {
                    throw PendingFormStorageError.invalidScope
                }
                return record
            }
            guard let url = URL(string: server),
                  let scope = PendingFormScope(userId: record.scope.userId, serverURL: url)
            else { throw PendingFormStorageError.invalidScope }
            needsMigration = true
            return PendingFormRecord(
                id: record.id, scope: scope, form: record.form, autoRecover: record.autoRecover)
        }
        if needsMigration { try write(migrated) }
        return migrated
    }

    private func write(_ records: [PendingFormRecord]) throws {
        try JSONEncoder().encode(records).write(
            to: storageURL, options: [.atomic, .completeFileProtection])
    }

}

nonisolated enum PendingFormRecoveryError: Error {
    case invalidResponse
    case httpStatus(Int)
    case wrongOwner
}

@MainActor
struct PendingFormRecovery {
    enum Outcome {
        case none
        case ready(PendingFormRecord, skippedFailures: Bool)
        case sessionChanged
    }

    private let store: PendingFormStore
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        store: PendingFormStore,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RedirectSafeTransport.data(for: $0)
        }
    ) {
        self.store = store
        self.fetch = fetch
    }

    func next(
        for scope: PendingFormScope,
        assetId: String? = nil,
        isCurrent: @MainActor () -> Bool,
        requestForAsset: @MainActor (String) throws -> URLRequest
    ) async throws -> Outcome {
        var skippedRecords: Set<UUID> = []
        var firstFailure: (any Error)?
        while isCurrent() {
            guard let record = try store.next(
                for: scope, assetId: assetId, excluding: skippedRecords) else {
                if let firstFailure { throw firstFailure }
                return .none
            }
            do {
                let request = try requestForAsset(record.form.assetId)
                let (data, response) = try await fetch(request)
                guard isCurrent() else { return .sessionChanged }
                guard let currentRecord = try store.recoverable(record) else { continue }
                guard let http = response as? HTTPURLResponse else {
                    throw PendingFormRecoveryError.invalidResponse
                }
                guard http.statusCode == 200 else {
                    throw PendingFormRecoveryError.httpStatus(http.statusCode)
                }
                let asset = try JSONDecoder().decode(AssetDetailResponse.self, from: data).asset
                guard asset.id == record.form.assetId, asset.user?.id == scope.userId else {
                    throw PendingFormRecoveryError.wrongOwner
                }
                if asset.formResponse != nil {
                    try store.remove(record)
                    continue
                }
                return .ready(currentRecord, skippedFailures: firstFailure != nil)
            } catch {
                guard isCurrent() else { return .sessionChanged }
                guard try store.recoverable(record) != nil else { continue }
                skippedRecords.insert(record.id)
                if firstFailure == nil { firstFailure = error }
                continue
            }
        }
        return .sessionChanged
    }
}

nonisolated enum FormSubmissionError: Error {
    case invalidResponse
    case httpStatus(Int)
    case inProgress
    case recordMismatch
}

@MainActor
final class PendingFormSubmissionCoordinator {
    static let shared = PendingFormSubmissionCoordinator()

    private struct Key: Hashable {
        let scope: PendingFormScope
        let assetId: String
    }

    private var active: Set<Key> = []

    func begin(scope: PendingFormScope, assetId: String) -> Bool {
        active.insert(Key(scope: scope, assetId: assetId)).inserted
    }

    func end(scope: PendingFormScope, assetId: String) {
        active.remove(Key(scope: scope, assetId: assetId))
    }
}

@MainActor
struct PendingFormSubmission {
    private struct Receipt: Decodable {
        let formResponse: FormResponse
    }

    enum Outcome {
        case submitted
        case submittedRecoveryNotCleared(any Error)
        case sessionChanged
    }

    private let store: PendingFormStore
    private let coordinator: PendingFormSubmissionCoordinator
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        store: PendingFormStore,
        coordinator: PendingFormSubmissionCoordinator = .shared,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RedirectSafeTransport.data(for: $0)
        }
    ) {
        self.store = store
        self.coordinator = coordinator
        self.transport = transport
    }

    func submit(
        formData: [String: String],
        request: URLRequest,
        pendingRecord: PendingFormRecord?,
        scope: PendingFormScope,
        assetId: String,
        isCurrent: @MainActor () -> Bool
    ) async throws -> Outcome {
        guard isCurrent() else { return .sessionChanged }
        if let pendingRecord,
           (pendingRecord.scope != scope || pendingRecord.form.assetId != assetId) {
            throw FormSubmissionError.recordMismatch
        }
        guard coordinator.begin(scope: scope, assetId: assetId) else {
            throw FormSubmissionError.inProgress
        }
        defer { coordinator.end(scope: scope, assetId: assetId) }
        var request = request
        request.timeoutInterval = RedirectSafeTransport.formRequestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: formData)
        let (data, response) = try await transport(request)
        guard isCurrent() else { return .sessionChanged }
        guard let http = response as? HTTPURLResponse else {
            throw FormSubmissionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FormSubmissionError.httpStatus(http.statusCode)
        }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.formResponse.assetId == assetId else {
            throw FormSubmissionError.invalidResponse
        }
        if let pendingRecord {
            do {
                try store.remove(pendingRecord)
            } catch {
                return .submittedRecoveryNotCleared(error)
            }
        }
        return .submitted
    }
}

@MainActor
protocol VideoUploadTransfer {
    func upload(
        request: URLRequest, fileURL: URL, isCurrent: @MainActor () -> Bool,
        validateBeforeTransfer: (@MainActor () throws -> Void)?,
        onProgress: @escaping @MainActor (Double) -> Void,
        onStart: @MainActor () -> Void
    ) async throws -> (Data, URLResponse)
}

/// Handles multipart video file uploads with progress tracking.
@MainActor
@Observable
final class VideoUploadService: NSObject {
    // MARK: - State
    
    var uploadProgress: Double = 0
    var isUploading = false
    var error: String?
    private(set) var backgroundTransferStartCount = 0

    private let createTransport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transfer: (any VideoUploadTransfer)?

    init(
        createTransport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RedirectSafeTransport.data(for: $0)
        },
        transfer: (any VideoUploadTransfer)? = nil
    ) {
        self.createTransport = createTransport
        self.transfer = transfer
        super.init()
    }
    
    // MARK: - Mux Direct Upload
    
    /// Upload via Mux direct upload: ask server for a Mux upload URL, then PUT file directly to Mux CDN.
    /// This bypasses the server for the large file transfer — only metadata goes through the server.
    func uploadViaMux(
        assetId: String, fileURL: URL, token: String, serverURL: URL,
        metadata: VideoMetadata? = nil,
        isCurrent: @MainActor () -> Bool,
        validateBeforeTransfer: (@MainActor () throws -> Void)? = nil
    ) async throws -> MuxUploadResponse {
        try Task.checkCancellation()
        guard isCurrent() else { throw UploadError.sessionChanged }
        isUploading = true
        uploadProgress = 0
        error = nil
        defer { isUploading = false }
        
        Log.debug("📤 [Mux] Requesting direct upload URL for asset: \(assetId)", logger: Log.upload)
        
        // Step 1: Ask server for a Mux direct upload URL (fast — just metadata)
        guard let identity = AuthServerIdentity.canonical(serverURL),
              let muxURL = AuthServerIdentity.endpoint(
                "/api/assets/\(assetId)/mux-upload", on: serverURL),
              AuthServerIdentity.contains(muxURL, server: identity) else {
            throw UploadError.sessionChanged
        }
        var createRequest = URLRequest(url: muxURL)
        createRequest.httpMethod = "POST"
        createRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Send metadata + file info as JSON
        // Get file size once — used for both metadata payload and Content-Length header
        let fileSize: Int64 = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 { return size }
            return 0
        }()

        var metaDict: [String: Any] = [:]
        if let meta = metadata {
            metaDict = [
                "fileName": fileURL.lastPathComponent,
                "duration": meta.duration,
                "resolution": meta.resolution,
                "codec": meta.codec,
                "orientation": meta.orientation,
                "deviceModel": meta.deviceModel,
                "osVersion": meta.osVersion,
            ]
            if let capturedAt = meta.capturedAt { metaDict["capturedAt"] = capturedAt }
            if let lat = meta.gpsLat { metaDict["gpsLat"] = lat }
            if let lon = meta.gpsLon { metaDict["gpsLon"] = lon }
            if let alt = meta.gpsAltitude { metaDict["gpsAltitude"] = alt }
            if fileSize > 0 { metaDict["fileSize"] = fileSize }
        }
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: ["metadata": metaDict])
        
        let (createData, createResponse) = try await createTransport(createRequest)
        try Task.checkCancellation()
        guard isCurrent() else { throw UploadError.sessionChanged }
        
        guard let httpResp = createResponse as? HTTPURLResponse, httpResp.statusCode == 200 else {
            let code = (createResponse as? HTTPURLResponse)?.statusCode ?? 0
            Log.error("📤 [Mux] ❌ Failed to get upload URL: HTTP \(code)", logger: Log.upload)
            let message = code == 409
                ? "An existing upload may already be processing. Check Archive for updates."
                : "The server could not start the upload."
            throw UploadError.serverError(code, message)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: createData) as? [String: Any],
              let uploadUrlString = json["uploadUrl"] as? String,
              let uploadUrl = URL(string: uploadUrlString),
              let uploadComponents = URLComponents(url: uploadUrl, resolvingAgainstBaseURL: false),
              uploadComponents.scheme?.lowercased() == "https",
              let uploadHost = uploadComponents.host, !uploadHost.isEmpty,
              uploadComponents.user == nil, uploadComponents.password == nil,
              uploadComponents.fragment == nil,
              uploadComponents.port.map({ (1...65535).contains($0) }) ?? true,
              let clipId = json["clipId"] as? String else {
            throw UploadError.invalidResponse
        }
        Log.debug("📤 [Mux] Got upload URL, uploading directly to Mux CDN...", logger: Log.upload)
        
        // Simple PUT to Mux direct upload URL (no tus headers needed)
        var putRequest = URLRequest(url: uploadUrl)
        putRequest.httpMethod = "PUT"
        putRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if fileSize > 0 {
            putRequest.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        }
        
        let putResponse: URLResponse
        if let transfer {
            (_, putResponse) = try await transfer.upload(
                request: putRequest, fileURL: fileURL, isCurrent: isCurrent,
                validateBeforeTransfer: validateBeforeTransfer,
                onProgress: { [weak self] in self?.uploadProgress = $0 },
                onStart: { self.backgroundTransferStartCount += 1 })
        } else {
            (_, putResponse) = try await uploadWithProgress(
                request: putRequest, fileURL: fileURL, isCurrent: isCurrent,
                validateBeforeTransfer: validateBeforeTransfer)
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw UploadError.sessionChanged }
        
        guard let putHttp = putResponse as? HTTPURLResponse,
              (200...204).contains(putHttp.statusCode) else {
            let code = (putResponse as? HTTPURLResponse)?.statusCode ?? 0
            Log.error("📤 [Mux] ❌ PUT to Mux failed with status \(code)", logger: Log.upload)
            throw UploadError.serverError(code, "Mux upload failed")
        }
        
        uploadProgress = 1.0
        Log.debug("📤 [Mux] ✅ Direct upload complete! Mux will process and notify via webhook.", logger: Log.upload)
        
        return MuxUploadResponse(clipId: clipId, muxUploadId: json["muxUploadId"] as? String ?? "")
    }
    
    // MARK: - Upload with Progress (Background session + waitsForConnectivity)
    
    private func uploadWithProgress(
        request: URLRequest, fileURL: URL, isCurrent: @MainActor () -> Bool,
        validateBeforeTransfer: (@MainActor () throws -> Void)?
    ) async throws -> (Data, URLResponse) {
        let cancellation = TaskCancellationBridge()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try Task.checkCancellation()
                    guard isCurrent() else { throw UploadError.sessionChanged }
                    try validateBeforeTransfer?()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let delegate = UploadDelegate(
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.uploadProgress = progress
                        }
                    },
                    onComplete: { data, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, let response {
                            continuation.resume(returning: (data, response))
                        } else {
                            continuation.resume(throwing: UploadError.invalidResponse)
                        }
                    }
                )

                // Background session — upload continues when app is suspended by iOS.
                // waitsForConnectivity — pauses on network blip instead of failing (A4).
                let config = URLSessionConfiguration.background(
                    withIdentifier: "com.directvideo.upload.\(UUID().uuidString)"
                )
                config.isDiscretionary = false
                config.sessionSendsLaunchEvents = true
                config.waitsForConnectivity = true
                config.timeoutIntervalForResource = 600

                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                let task = session.uploadTask(with: request, fromFile: fileURL)
                cancellation.register { task.cancel() }
                task.resume()
                backgroundTransferStartCount += 1
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
    
}

nonisolated final class TaskCancellationBridge: Sendable {
    private struct State {
        var cancelled = false
        var cancelTask: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    func register(_ cancelTask: @escaping @Sendable () -> Void) {
        let cancelNow = state.withLock { state in
            state.cancelTask = cancelTask
            return state.cancelled
        }
        if cancelNow { cancelTask() }
    }

    func cancel() {
        let action = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.cancelled else { return nil }
            state.cancelled = true
            return state.cancelTask
        }
        action?()
    }
}

// MARK: - Upload Delegate (Progress Tracking)

/// URLSession calls the delegate on its own serial queue; the response buffer is still
/// behind a `Mutex` so the class is checked `Sendable`.
nonisolated final class UploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onComplete: @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    
    private let responseData = Mutex(Data())
    
    init(onProgress: @escaping @Sendable (Double) -> Void, onComplete: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(progress)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.withLock { $0.append(data) }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error {
            onComplete(nil, nil, error)
        } else {
            onComplete(responseData.withLock { $0 }, task.response, nil)
        }
    }
    
    // Background session requires handling this to allow the session to reconnect
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        Log.debug("⏳ [Upload] Waiting for connectivity — upload will resume when network returns", logger: Log.upload)
    }
}

// MARK: - Mux Upload Response

nonisolated struct MuxUploadResponse {
    let clipId: String
    let muxUploadId: String
}

// MARK: - Errors

nonisolated enum UploadError: LocalizedError {
    case invalidResponse
    case unverifiedMode
    case serverError(Int, String)
    case fileNotFound
    case sessionChanged
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .unverifiedMode: return "The server couldn't verify the upload type."
        case .serverError(let code, let msg): return "Upload failed (HTTP \(code)): \(msg)"
        case .fileNotFound: return "Video file not found"
        case .sessionChanged: return "Your session changed. Sign in again before uploading."
        }
    }
}
