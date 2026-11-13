import CryptoKit
import Darwin
import Foundation

nonisolated enum OriginalUploadStorageError: LocalizedError, Equatable {
    case invalidScope
    case invalidRecord
    case invalidFile
    case emptyFile
    case fileTooLarge
    case fileChanged
    case invalidPart
    case jobNotFound
    case jobAlreadyExists
    case immutableJobChanged
    case staleJob
    case busy
    case cancellationRequested
    case scopeStopped
    case cleanupFailed
    case durabilityUncertain
    case preparationDiscarded

    var errorDescription: String? {
        switch self {
        case .invalidScope: "The upload account or server changed."
        case .invalidRecord: "Saved upload information is invalid."
        case .invalidFile: "The selected video is not a regular file."
        case .emptyFile: "The selected video is empty."
        case .fileTooLarge: "The video exceeds the 500 MiB original upload limit."
        case .fileChanged: "The staged video changed. Select the video again."
        case .invalidPart: "The requested upload part is invalid."
        case .jobNotFound: "The saved upload could not be found."
        case .jobAlreadyExists: "This upload has already been prepared."
        case .immutableJobChanged: "The saved upload identity cannot be changed."
        case .staleJob: "The saved upload changed. Refresh its state and try again."
        case .busy: "Another operation is using this upload."
        case .cancellationRequested: "Cancellation was requested for this upload."
        case .scopeStopped: "Original uploads are stopped for this account and server."
        case .cleanupFailed: "An upload file could not be removed. Reopen the app to retry cleanup."
        case .durabilityUncertain: "The upload state could not be confirmed. Reopen the app to recover it."
        case .preparationDiscarded: "The upload could not be prepared. Select the video and try again."
        }
    }
}

nonisolated enum OriginalUploadMode: String, Codable, Sendable {
    case original = "ORIGINAL"
}

nonisolated enum OriginalUploadState: String, Codable, Sendable {
    case pending
    case reserving
    case uploading
    case stored
}

nonisolated enum OriginalUploadAttemptState: String, Codable, Sendable {
    case preparing
    case ready
    case scheduled
    case retiring
}

nonisolated struct OriginalUploadAttempt: Codable, Equatable, Sendable {
    let id: UUID
    let number: Int
    var state: OriginalUploadAttemptState
    var taskIdentifier: Int? = nil
}

nonisolated struct OriginalUploadTaskInventory: Sendable {
    fileprivate let fenceID: UUID
    fileprivate let generation: UUID
    let taskIdentifiers: Set<Int>
    let jobIDs: Set<UUID>
    let attemptIDs: Set<UUID>
    let hasUnidentifiedTasks: Bool
}

@MainActor
final class OriginalUploadTaskFence {
    static let shared = OriginalUploadTaskFence()

    struct StopPermit {
        fileprivate let fenceID: UUID
        fileprivate let scope: String
        fileprivate init(fenceID: UUID, scope: String) {
            self.fenceID = fenceID
            self.scope = scope
        }
    }

    private struct JobKey: Hashable {
        let scope: String
        let id: UUID
        let incarnation: UUID
    }

    private let id = UUID()
    private var generation = UUID()
    private var scheduling = false
    private var blockedJobs: Set<JobKey> = []
    private var stoppedScopes: Set<String> = []

    func beginSnapshot() -> UUID { generation }

    // Must be called while the old authenticated access is still current. The
    // permit carries only the scope digest and issuing fence identity.
    func stopScope(access: OriginalUploadAccess) throws -> StopPermit {
        try access.require(access.scope)
        let scope = try OriginalUploadJournal.scopeIdentifier(access.scope)
        if stoppedScopes.insert(scope).inserted { generation = UUID() }
        return StopPermit(fenceID: id, scope: scope)
    }

    func stoppedScope(for permit: StopPermit) throws -> String {
        guard permit.fenceID == id, stoppedScopes.contains(permit.scope) else {
            throw OriginalUploadStorageError.invalidScope
        }
        return permit.scope
    }

    func requireActive(scope: PendingFormScope, access: OriginalUploadAccess) throws {
        try access.require(scope)
        guard try !stoppedScopes.contains(OriginalUploadJournal.scopeIdentifier(scope)) else {
            throw OriginalUploadStorageError.scopeStopped
        }
    }

    func isSnapshotCurrent(_ snapshot: UUID) -> Bool {
        !scheduling && snapshot == generation
    }

    func inventory(
        snapshot: UUID, taskIdentifiers: Set<Int>, jobIDs: Set<UUID>,
        attemptIDs: Set<UUID>, hasUnidentifiedTasks: Bool
    ) throws -> OriginalUploadTaskInventory {
        guard !scheduling, snapshot == generation else { throw OriginalUploadStorageError.busy }
        return OriginalUploadTaskInventory(
            fenceID: id, generation: generation, taskIdentifiers: taskIdentifiers,
            jobIDs: jobIDs, attemptIDs: attemptIDs, hasUnidentifiedTasks: hasUnidentifiedTasks)
    }

    func blockCancellation(for job: OriginalUploadJob) throws {
        let key = JobKey(
            scope: try OriginalUploadJournal.scopeIdentifier(job.scope), id: job.id, incarnation: job.incarnation)
        if blockedJobs.insert(key).inserted { generation = UUID() }
    }

    func isCancellationBlocked(for job: OriginalUploadJob) throws -> Bool {
        let key = JobKey(
            scope: try OriginalUploadJournal.scopeIdentifier(job.scope), id: job.id, incarnation: job.incarnation)
        return blockedJobs.contains(key)
    }

    fileprivate func withScheduling<T>(
        job: OriginalUploadJob, access: OriginalUploadAccess, _ body: () throws -> T
    ) throws -> T {
        try requireActive(scope: job.scope, access: access)
        guard try !isCancellationBlocked(for: job) else { throw OriginalUploadStorageError.cancellationRequested }
        guard !scheduling else { throw OriginalUploadStorageError.busy }
        scheduling = true
        generation = UUID()
        defer { scheduling = false; generation = UUID() }
        return try body()
    }

    fileprivate func isCurrent(_ inventory: OriginalUploadTaskInventory) -> Bool {
        !scheduling && inventory.fenceID == id && inventory.generation == generation
    }
}

nonisolated struct OriginalUploadManifest: Codable, Equatable, Sendable {
    let fingerprint: VideoContentFingerprint
    let partSize: Int64
    let parts: [VideoContentFingerprint]

    var isValid: Bool {
        guard fingerprint.isValid, fingerprint.byteCount <= OriginalUploadFiles.maximumSize,
              partSize > 0, partSize <= OriginalUploadFiles.maximumPartSize,
              parts.count == Int((fingerprint.byteCount + partSize - 1) / partSize) else {
            return false
        }
        return parts.enumerated().allSatisfy { index, part in
            part.isValid && part.byteCount == min(
                partSize, fingerprint.byteCount - Int64(index) * partSize)
        }
    }
}

nonisolated struct OriginalUploadJob: Codable, Equatable, Sendable {
    let id: UUID
    let incarnation: UUID
    let scope: PendingFormScope
    let mode: OriginalUploadMode
    let fileName: String?
    let manifest: OriginalUploadManifest
    let metadata: VideoMetadata
    let photoIdentifier: String?
    let transcribe: Bool
    let createdAt: Date
    var revision: UInt64
    var assetId: String?
    var sessionId: String?
    var state: OriginalUploadState
    var attempts: [OriginalUploadAttempt]
    var cancellationRequested = false

    var fingerprint: VideoContentFingerprint { manifest.fingerprint }

    fileprivate func hasSameIdentity(as other: OriginalUploadJob) -> Bool {
        id == other.id && incarnation == other.incarnation && scope == other.scope && mode == other.mode
            && fileName == other.fileName && manifest == other.manifest
            && metadata == other.metadata && photoIdentifier == other.photoIdentifier
            && transcribe == other.transcribe && createdAt == other.createdAt
    }

    fileprivate var isValid: Bool {
        guard !scope.userId.isEmpty, PendingFormScope.isValidDigest(scope.server),
              mode == .original, manifest.isValid,
              manifest.partSize == OriginalUploadFiles.maximumPartSize,
              fileName.map(Self.isSafeFilename) ?? true,
              photoIdentifier.map(Self.isSafeIdentifier) ?? true,
              assetId.map({ UUID(uuidString: $0) != nil }) ?? true,
              sessionId.map({ UUID(uuidString: $0) != nil }) ?? true,
              sessionId == nil || assetId != nil,
              [.pending, .reserving].contains(state) ? sessionId == nil : sessionId != nil,
              state == .pending ? assetId == nil : true,
              [.pending, .reserving].contains(state) ? attempts.isEmpty : true,
              state == .stored ? attempts.isEmpty : true,
              Self.isValidMetadata(metadata) else { return false }
        let taskIdentifiers = attempts.compactMap(\.taskIdentifier)
        return Set(attempts.map(\.id)).count == attempts.count
            && Set(attempts.map(\.number)).count == attempts.count
            && Set(taskIdentifiers).count == taskIdentifiers.count
            && attempts.allSatisfy {
                (1...manifest.parts.count).contains($0.number)
                    && ($0.state == .scheduled ? ($0.taskIdentifier.map { $0 > 0 } ?? false)
                        : $0.state == .retiring ? ($0.taskIdentifier.map { $0 > 0 } ?? true)
                        : $0.taskIdentifier == nil)
            }
    }

    private static func isSafeFilename(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255
            && value != "." && value != ".." && !value.contains("/")
            && !value.contains("\\") && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.contains("://")
            && !value.contains("?") && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isValidMetadata(_ metadata: VideoMetadata) -> Bool {
        let strings = [
            metadata.resolution, metadata.codec, metadata.orientation,
            metadata.deviceModel, metadata.osVersion,
        ]
        return (0...Int(Int32.max)).contains(metadata.duration)
            && strings.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= 256
                    && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }
            && (metadata.capturedAt.map { DVUDateFormatting.parseISO($0) != nil } ?? true)
            && (metadata.gpsLat.map { $0.isFinite && abs($0) <= 90 } ?? true)
            && (metadata.gpsLon.map { $0.isFinite && abs($0) <= 180 } ?? true)
            && (metadata.gpsAltitude.map(\.isFinite) ?? true)
    }
}

@MainActor
struct OriginalUploadAccess {
    let scope: PendingFormScope
    let origin: URL
    let snapshot: AuthenticatedSessionSnapshot
    private let auth: AuthService

    init(
        auth: AuthService,
        allowedOrigins: Set<String> = ServerConfig.isolatedOriginalUploadOrigins
    ) throws {
        let snapshot = try auth.authenticatedSnapshot()
        guard let serverURL = URL(string: snapshot.server) else {
            throw OriginalUploadStorageError.invalidScope
        }
        let origin = try OriginalUploadURL.origin(
            serverURL, forbiddenHosts: ServerConfig.sharedServerHosts, allowedOrigins: allowedOrigins)
        guard let scope = PendingFormScope(userId: snapshot.userId, serverURL: origin),
              AuthServerIdentity.canonical(origin) == snapshot.server,
              auth.isCurrent(snapshot) else {
            throw OriginalUploadStorageError.invalidScope
        }
        self.scope = scope
        self.origin = origin
        self.snapshot = snapshot
        self.auth = auth
    }

    var isCurrent: Bool { auth.isCurrent(snapshot) }

    func require(_ scope: PendingFormScope) throws {
        guard self.scope == scope, isCurrent else { throw OriginalUploadStorageError.invalidScope }
    }
}

nonisolated struct OriginalUploadPart: Sendable {
    let url: URL
    let number: Int
    let fingerprint: VideoContentFingerprint
}

nonisolated enum OriginalUploadFiles {
    static let maximumSize: Int64 = 500 * 1_024 * 1_024
    static let maximumPartSize: Int64 = 50 * 1_024 * 1_024
    private static let bufferSize: Int64 = 1_048_576

    @concurrent
    static func stage(
        source: URL, destination: URL, maximumSize: Int64 = maximumSize,
        partSize: Int64 = maximumPartSize
    ) async throws -> OriginalUploadManifest {
        guard maximumSize > 0, maximumSize <= Self.maximumSize,
              partSize > 0, partSize <= maximumPartSize else {
            throw OriginalUploadStorageError.invalidFile
        }
        let input = try openRegularFile(source)
        defer { closeLogged(input) }
        let before = try fileInfo(input)
        guard before.st_size > 0 else { throw OriginalUploadStorageError.emptyFile }
        guard before.st_size <= maximumSize else { throw OriginalUploadStorageError.fileTooLarge }
        return try withProtectedOutput(destination) { output in
            var fullDigest = SHA256()
            var partDigest = SHA256()
            var count: Int64 = 0
            var partCount: Int64 = 0
            var parts: [VideoContentFingerprint] = []
            while true {
                try Task.checkCancellation()
                let amount = Int(min(bufferSize, partSize - partCount))
                guard let chunk = try input.read(upToCount: amount), !chunk.isEmpty else { break }
                count += Int64(chunk.count)
                guard count <= maximumSize else { throw OriginalUploadStorageError.fileTooLarge }
                fullDigest.update(data: chunk)
                partDigest.update(data: chunk)
                try output.write(contentsOf: chunk)
                partCount += Int64(chunk.count)
                if partCount == partSize {
                    parts.append(fingerprint(partDigest, size: partCount))
                    partDigest = SHA256()
                    partCount = 0
                }
            }
            if partCount > 0 { parts.append(fingerprint(partDigest, size: partCount)) }
            try Task.checkCancellation()
            guard count == before.st_size, try unchanged(input, at: source, since: before) else {
                throw OriginalUploadStorageError.fileChanged
            }
            return OriginalUploadManifest(
                fingerprint: fingerprint(fullDigest, size: count), partSize: partSize, parts: parts)
        }
    }

    @concurrent
    static func part(
        source: URL, destination: URL, manifest: OriginalUploadManifest, number: Int
    ) async throws -> OriginalUploadPart {
        guard manifest.isValid, (1...manifest.parts.count).contains(number) else {
            throw OriginalUploadStorageError.invalidPart
        }
        let input = try openRegularFile(source)
        defer { closeLogged(input) }
        let before = try fileInfo(input)
        guard before.st_size == manifest.fingerprint.byteCount else {
            throw OriginalUploadStorageError.fileChanged
        }
        let expected = manifest.parts[number - 1]
        let offset = Int64(number - 1) * manifest.partSize
        return try withProtectedOutput(destination) { output in
            try input.seek(toOffset: UInt64(offset))
            var digest = SHA256()
            var count: Int64 = 0
            while count < expected.byteCount {
                try Task.checkCancellation()
                let amount = Int(min(bufferSize, expected.byteCount - count))
                guard let chunk = try input.read(upToCount: amount), !chunk.isEmpty else {
                    throw OriginalUploadStorageError.fileChanged
                }
                digest.update(data: chunk)
                try output.write(contentsOf: chunk)
                count += Int64(chunk.count)
            }
            try Task.checkCancellation()
            let actual = fingerprint(digest, size: count)
            guard actual == expected, try unchanged(input, at: source, since: before) else {
                throw OriginalUploadStorageError.fileChanged
            }
            return OriginalUploadPart(url: destination, number: number, fingerprint: actual)
        }
    }

    @concurrent
    static func verifyPart(
        at url: URL, number: Int, expected: VideoContentFingerprint
    ) async throws -> OriginalUploadPart {
        let input = try openRegularFile(url)
        defer { closeLogged(input) }
        let before = try fileInfo(input)
        guard before.st_size == expected.byteCount else { throw OriginalUploadStorageError.fileChanged }
        var digest = SHA256()
        var count: Int64 = 0
        while let chunk = try input.read(upToCount: Int(bufferSize)), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            guard count <= expected.byteCount else { throw OriginalUploadStorageError.fileChanged }
            digest.update(data: chunk)
        }
        try Task.checkCancellation()
        let actual = fingerprint(digest, size: count)
        guard actual == expected, try unchanged(input, at: url, since: before) else {
            throw OriginalUploadStorageError.fileChanged
        }
        return OriginalUploadPart(url: url, number: number, fingerprint: actual)
    }

    static func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        guard try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw OriginalUploadStorageError.invalidFile
        }
    }

    static func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw OriginalUploadStorageError.invalidFile
        }
    }

    static func createProtectedDirectory(
        _ url: URL,
        synchronizeDirectory: (URL) throws -> Void = { try DurableFile.synchronize($0, directory: true) }
    ) throws {
        let boundary = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        var parent = url.standardizedFileURL.resolvingSymlinksInPath()
        guard parent == boundary || parent.path.hasPrefix(boundary.path + "/") else {
            throw OriginalUploadStorageError.invalidScope
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try validateDirectory(url)
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: TemporaryVideoStorage.protection])
        try validateDirectory(url)
        try TemporaryVideoStorage.applyProtection(to: url)
        try excludeFromBackup(url)
        while true {
            try synchronizeDirectory(parent)
            if parent == boundary { break }
            parent = parent.deletingLastPathComponent()
        }
    }

    static func writeProtected(_ data: Data, to destination: URL) throws {
        try withProtectedOutput(destination) { output in
            try output.write(contentsOf: data)
        }
    }

    static func readJournal(_ url: URL) throws -> Data {
        let input = try openRegularFile(url)
        defer { closeLogged(input) }
        let before = try fileInfo(input)
        guard before.st_size > 0, before.st_size <= 1_048_576 else {
            throw OriginalUploadStorageError.invalidRecord
        }
        var data = Data()
        while true {
            let remaining = 1_048_577 - data.count
            guard remaining > 0 else { throw OriginalUploadStorageError.invalidRecord }
            guard let chunk = try input.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard Int64(data.count) == before.st_size, try unchanged(input, at: url, since: before) else {
            throw OriginalUploadStorageError.invalidRecord
        }
        return data
    }

    static func removeOwnedItem(
        _ url: URL,
        synchronizeDirectory: (URL) throws -> Void = { try DurableFile.synchronize($0, directory: true) }
    ) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
        } catch let error as POSIXError where error.code == .ENOENT {
        } catch {
            Log.error("Could not remove an original upload file: \(Log.describe(error))", logger: Log.upload)
            throw OriginalUploadStorageError.cleanupFailed
        }
        do {
            var parent = url.deletingLastPathComponent()
            while true {
                var info = stat()
                let result = parent.path.withCString { Darwin.lstat($0, &info) }
                if result == 0 {
                    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                        throw OriginalUploadStorageError.invalidFile
                    }
                    try synchronizeDirectory(parent)
                    return
                }
                guard errno == ENOENT else { throw posixError() }
                let next = parent.deletingLastPathComponent()
                guard next != parent else { throw OriginalUploadStorageError.invalidFile }
                parent = next
            }
        } catch {
            Log.error("Could not synchronize upload cleanup: \(Log.describe(error))", logger: Log.upload)
            throw OriginalUploadStorageError.cleanupFailed
        }
    }

    private static func withProtectedOutput<T>(_ destination: URL, body: (FileHandle) throws -> T) throws -> T {
        guard destination.isFileURL else { throw OriginalUploadStorageError.invalidFile }
        let descriptor = destination.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixError() }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var closed = false
        defer { if !closed { closeLogged(output) } }
        do {
            try TemporaryVideoStorage.applyProtection(to: destination)
            try excludeFromBackup(destination)
            let result = try body(output)
            guard Darwin.fchmod(descriptor, mode_t(0o400)) == 0 else { throw posixError() }
            try output.synchronize()
            try output.close()
            closed = true
            try DurableFile.synchronize(destination.deletingLastPathComponent(), directory: true)
            return result
        } catch {
            let operationError = error
            try removeOwnedItem(destination)
            throw operationError
        }
    }

    private static func openRegularFile(_ url: URL) throws -> FileHandle {
        guard url.isFileURL else { throw OriginalUploadStorageError.invalidFile }
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw OriginalUploadStorageError.invalidFile }
            throw posixError()
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let info = try fileInfo(file)
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw OriginalUploadStorageError.invalidFile
            }
            return file
        } catch {
            closeLogged(file)
            throw error
        }
    }

    private static func fileInfo(_ file: FileHandle) throws -> stat {
        var info = stat()
        guard Darwin.fstat(file.fileDescriptor, &info) == 0 else { throw posixError() }
        return info
    }

    private static func unchanged(_ file: FileHandle, at url: URL, since before: stat) throws -> Bool {
        let after = try fileInfo(file)
        var path = stat()
        guard url.path.withCString({ Darwin.lstat($0, &path) }) == 0 else { return false }
        return after.st_dev == before.st_dev && after.st_ino == before.st_ino
            && after.st_size == before.st_size
            && after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
            && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
            && after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec
            && after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
            && path.st_dev == before.st_dev && path.st_ino == before.st_ino
            && path.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func fingerprint(_ digest: SHA256, size: Int64) -> VideoContentFingerprint {
        return VideoContentFingerprint(
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), byteCount: size)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func closeLogged(_ file: FileHandle) {
        do {
            try file.close()
        } catch {
            Log.error("Could not close an original upload file: \(Log.describe(error))", logger: Log.upload)
        }
    }
}

@MainActor
final class OriginalUploadJournal {
    static let shared = OriginalUploadJournal(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OriginalUploads", isDirectory: true))

    private static var activePreparations: Set<String> = []
    private static var activeParts: Set<String> = []
    private let directory: URL
    private let synchronizeDirectory: (URL) throws -> Void
    private let stageOriginal: @Sendable (URL, URL) async throws -> OriginalUploadManifest
    private let verifyPart: @Sendable (URL, Int, VideoContentFingerprint) async throws -> OriginalUploadPart
    private let taskFence: OriginalUploadTaskFence

    init(
        directory: URL,
        synchronizeDirectory: @escaping (URL) throws -> Void = {
            try DurableFile.synchronize($0, directory: true)
        },
        stageOriginal: @escaping @Sendable (URL, URL) async throws -> OriginalUploadManifest = {
            try await OriginalUploadFiles.stage(source: $0, destination: $1)
        },
        verifyPart: @escaping @Sendable (URL, Int, VideoContentFingerprint) async throws -> OriginalUploadPart = {
            try await OriginalUploadFiles.verifyPart(at: $0, number: $1, expected: $2)
        },
        taskFence: OriginalUploadTaskFence = .shared
    ) {
        self.directory = directory.standardizedFileURL
        self.synchronizeDirectory = synchronizeDirectory
        self.stageOriginal = stageOriginal
        self.verifyPart = verifyPart
        self.taskFence = taskFence
    }

    func usesTaskFence(_ fence: OriginalUploadTaskFence) -> Bool {
        taskFence === fence
    }

    func isCancellationBlocked(for job: OriginalUploadJob) throws -> Bool {
        try taskFence.isCancellationBlocked(for: job)
    }

    func requireActiveScope(for job: OriginalUploadJob, access: OriginalUploadAccess) throws {
        try taskFence.requireActive(scope: job.scope, access: access)
    }

    func prepare(
        id: UUID, source: URL, fileName: String?, metadata: VideoMetadata, photoIdentifier: String?,
        transcribe: Bool, access: OriginalUploadAccess
    ) async throws -> OriginalUploadJob {
        try access.require(access.scope)
        let scopeDirectory = try prepareScope(access.scope)
        let temporary = preparationDirectory(id, in: scopeDirectory)
        let destination = jobDirectory(id, in: scopeDirectory)
        let key = temporary.resolvingSymlinksInPath().path
        guard !Self.activePreparations.contains(key),
              !FileManager.default.fileExists(atPath: temporary.path),
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw OriginalUploadStorageError.jobAlreadyExists
        }
        Self.activePreparations.insert(key)
        defer { Self.activePreparations.remove(key) }
        let result = temporary.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
        guard result == 0 else {
            if errno == EEXIST { throw OriginalUploadStorageError.jobAlreadyExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var published = false
        do {
            try synchronizeDirectory(scopeDirectory)
            try createProtectedDirectory(temporary)
            let manifest = try await stageOriginal(source, temporary.appendingPathComponent("original"))
            try Task.checkCancellation()
            try access.require(access.scope)
            let job = OriginalUploadJob(
                id: id, incarnation: UUID(), scope: access.scope, mode: .original, fileName: fileName,
                manifest: manifest, metadata: metadata, photoIdentifier: photoIdentifier,
                transcribe: transcribe, createdAt: Date(), revision: 0,
                assetId: nil, sessionId: nil, state: .pending, attempts: [])
            guard job.isValid else { throw OriginalUploadStorageError.invalidRecord }
            try write(job, in: temporary)
            try Task.checkCancellation()
            try access.require(job.scope)
            try FileManager.default.moveItem(at: temporary, to: destination)
            published = true
            do {
                try synchronizeDirectory(scopeDirectory)
            } catch {
                Log.error("Could not synchronize a published upload: \(Log.describe(error))", logger: Log.upload)
                throw OriginalUploadStorageError.durabilityUncertain
            }
            return job
        } catch {
            let operationError = error
            if !published {
                try OriginalUploadFiles.removeOwnedItem(temporary)
                if (error as? OriginalUploadStorageError) == .durabilityUncertain {
                    throw OriginalUploadStorageError.preparationDiscarded
                }
            }
            throw operationError
        }
    }

    func jobs(access: OriginalUploadAccess) throws -> [OriginalUploadJob] {
        try access.require(access.scope)
        let scopeDirectory = try prepareScope(access.scope)
        let entries = try FileManager.default.contentsOfDirectory(
            at: scopeDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var result: [OriginalUploadJob] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix("preparing-"),
               UUID(uuidString: String(name.dropFirst("preparing-".count))) != nil {
                guard !Self.activePreparations.contains(entry.resolvingSymlinksInPath().path) else { continue }
                try OriginalUploadFiles.validateDirectory(entry)
                try OriginalUploadFiles.removeOwnedItem(entry)
                continue
            }
            guard name.hasPrefix("job-"),
                  let id = UUID(uuidString: String(name.dropFirst("job-".count))) else {
                throw OriginalUploadStorageError.invalidRecord
            }
            try OriginalUploadFiles.validateDirectory(entry)
            var job = try read(id: id, access: access)
            for attempt in job.attempts where attempt.state == .preparing {
                let part = partURL(attempt, in: entry)
                guard !Self.activeParts.contains(part.resolvingSymlinksInPath().path) else { continue }
                try OriginalUploadFiles.removeOwnedItem(part)
                job.attempts.removeAll { $0.id == attempt.id }
                job = try commit(job, access: access, allowAttemptChanges: true)
            }
            result.append(job)
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    func read(id: UUID, access: OriginalUploadAccess) throws -> OriginalUploadJob {
        try access.require(access.scope)
        let scopeDirectory = try prepareScope(access.scope)
        let directory = jobDirectory(id, in: scopeDirectory)
        try OriginalUploadFiles.validateDirectory(directory)
        try synchronizeDirectory(directory)
        try cleanupJournalStaging(in: directory)
        let url = directory.appendingPathComponent("job.json")
        let job = try JSONDecoder().decode(OriginalUploadJob.self, from: OriginalUploadFiles.readJournal(url))
        guard job.id == id, job.isValid else { throw OriginalUploadStorageError.invalidRecord }
        try access.require(job.scope)
        return job
    }

    func readCurrentJob(id: UUID, access: OriginalUploadAccess) throws -> OriginalUploadJob {
        try access.require(access.scope)
        let scope = try Self.scopeIdentifier(access.scope)
        let scopeDirectory = directory.appendingPathComponent("scope-\(scope)", isDirectory: true)
        let targetDirectory = jobDirectory(id, in: scopeDirectory)
        let directories = [directory, scopeDirectory, targetDirectory]
        let identities = try directories.map(Self.readOnlyDirectoryIdentity)
        let data = try OriginalUploadFiles.readJournal(targetDirectory.appendingPathComponent("job.json"))
        let job = try JSONDecoder().decode(OriginalUploadJob.self, from: data)
        guard job.id == id, job.scope == access.scope, job.isValid,
              try Self.scopeIdentifier(job.scope) == scope else {
            throw OriginalUploadStorageError.invalidRecord
        }
        try access.require(job.scope)
        guard try directories.map(Self.readOnlyDirectoryIdentity) == identities else {
            throw OriginalUploadStorageError.invalidRecord
        }
        try access.require(access.scope)
        return job
    }

    @discardableResult
    func update(_ job: OriginalUploadJob, access: OriginalUploadAccess) throws -> OriginalUploadJob {
        try commit(job, access: access, allowAttemptChanges: false)
    }

    func requestCancellation(
        for supplied: OriginalUploadJob, access: OriginalUploadAccess
    ) throws -> OriginalUploadJob {
        try access.require(supplied.scope)
        try taskFence.blockCancellation(for: supplied)
        var job = try read(id: supplied.id, access: access)
        guard job.hasSameIdentity(as: supplied), job.revision == supplied.revision else {
            throw OriginalUploadStorageError.staleJob
        }
        guard job.state != .stored else { throw OriginalUploadStorageError.invalidRecord }
        if job.cancellationRequested { return job }
        job.cancellationRequested = true
        return try commit(job, access: access, allowAttemptChanges: false)
    }

    func originalURL(for job: OriginalUploadJob, access: OriginalUploadAccess) throws -> URL {
        let current = try read(id: job.id, access: access)
        guard current.hasSameIdentity(as: job), current.revision == job.revision else {
            throw OriginalUploadStorageError.staleJob
        }
        let scopeDirectory = try prepareScope(access.scope)
        return jobDirectory(job.id, in: scopeDirectory).appendingPathComponent("original")
    }

    func preparePart(
        for supplied: OriginalUploadJob, number: Int, access: OriginalUploadAccess
    ) async throws -> (job: OriginalUploadJob, part: OriginalUploadPart) {
        var job = try read(id: supplied.id, access: access)
        guard job.hasSameIdentity(as: supplied), job.revision == supplied.revision else {
            throw OriginalUploadStorageError.staleJob
        }
        guard (1...job.manifest.parts.count).contains(number) else {
            throw OriginalUploadStorageError.invalidPart
        }
        guard job.state == .uploading, !job.cancellationRequested else {
            throw OriginalUploadStorageError.invalidRecord
        }
        guard !job.attempts.contains(where: { $0.number == number || $0.state == .preparing }) else {
            throw OriginalUploadStorageError.busy
        }
        let attempt = OriginalUploadAttempt(id: UUID(), number: number, state: .preparing)
        job.attempts.append(attempt)
        job = try commit(job, access: access, allowAttemptChanges: true)
        let scopeDirectory = try prepareScope(access.scope)
        let directory = jobDirectory(job.id, in: scopeDirectory)
        let destination = partURL(attempt, in: directory)
        let activeKey = destination.resolvingSymlinksInPath().path
        Self.activeParts.insert(activeKey)
        defer { Self.activeParts.remove(activeKey) }
        var created = false
        do {
            let part = try await OriginalUploadFiles.part(
                source: directory.appendingPathComponent("original"),
                destination: destination, manifest: job.manifest, number: number)
            created = true
            try Task.checkCancellation()
            try access.require(job.scope)
            let current = try read(id: job.id, access: access)
            guard current.revision == job.revision else { throw OriginalUploadStorageError.staleJob }
            guard let index = job.attempts.firstIndex(where: { $0.id == attempt.id }) else {
                throw OriginalUploadStorageError.invalidRecord
            }
            job.attempts[index].state = .ready
            job = try commit(job, access: access, allowAttemptChanges: true)
            return (job, part)
        } catch {
            let operationError = error
            if created && (error as? OriginalUploadStorageError) != .durabilityUncertain {
                try OriginalUploadFiles.removeOwnedItem(destination)
            }
            throw operationError
        }
    }

    func readyPart(
        for supplied: OriginalUploadJob, attemptId: UUID, access: OriginalUploadAccess
    ) async throws -> OriginalUploadPart {
        let job = try read(id: supplied.id, access: access)
        guard job.hasSameIdentity(as: supplied), job.revision == supplied.revision else {
            throw OriginalUploadStorageError.staleJob
        }
        guard !job.cancellationRequested,
              let attempt = job.attempts.first(where: { $0.id == attemptId && $0.state == .ready }) else {
            throw OriginalUploadStorageError.invalidPart
        }
        let scopeDirectory = try prepareScope(access.scope)
        let directory = jobDirectory(job.id, in: scopeDirectory)
        let url = partURL(attempt, in: directory)
        let activeKey = url.resolvingSymlinksInPath().path
        guard Self.activeParts.insert(activeKey).inserted else { throw OriginalUploadStorageError.busy }
        defer { Self.activeParts.remove(activeKey) }
        let part = try await verifyPart(url, attempt.number, job.manifest.parts[attempt.number - 1])
        try Task.checkCancellation()
        try access.require(job.scope)
        let current = try read(id: job.id, access: access)
        guard current.revision == job.revision else { throw OriginalUploadStorageError.staleJob }
        return part
    }

    private func recordScheduledTask(
        for supplied: OriginalUploadJob, attemptId: UUID, taskIdentifier: Int,
        access: OriginalUploadAccess
    ) throws -> OriginalUploadJob {
        var job = try read(id: supplied.id, access: access)
        guard job.hasSameIdentity(as: supplied), job.revision == supplied.revision else {
            throw OriginalUploadStorageError.staleJob
        }
        guard job.state == .uploading, !job.cancellationRequested, taskIdentifier > 0,
              !job.attempts.contains(where: { $0.taskIdentifier == taskIdentifier }),
              let index = job.attempts.firstIndex(where: { $0.id == attemptId && $0.state == .ready }) else {
            throw OriginalUploadStorageError.invalidRecord
        }
        job.attempts[index].state = .scheduled
        job.attempts[index].taskIdentifier = taskIdentifier
        return try commit(job, access: access, allowAttemptChanges: true)
    }

    func scheduleReadyPart<TaskHandle>(
        for supplied: OriginalUploadJob, attemptId: UUID, verifiedPart: OriginalUploadPart,
        access: OriginalUploadAccess, createTask: (URL) throws -> (handle: TaskHandle, identifier: Int),
        startTask: (TaskHandle) -> Void, cancelTask: (TaskHandle) -> Void
    ) throws -> OriginalUploadJob {
        try taskFence.withScheduling(job: supplied, access: access) {
            try Task.checkCancellation()
            let job = try read(id: supplied.id, access: access)
            guard job.hasSameIdentity(as: supplied), job.revision == supplied.revision else {
                throw OriginalUploadStorageError.staleJob
            }
            guard job.state == .uploading, !job.cancellationRequested,
                  let attempt = job.attempts.first(where: { $0.id == attemptId && $0.state == .ready }) else {
                throw OriginalUploadStorageError.invalidPart
            }
            let scopeDirectory = try prepareScope(access.scope)
            let url = partURL(attempt, in: jobDirectory(job.id, in: scopeDirectory))
            guard verifiedPart.url.standardizedFileURL == url.standardizedFileURL,
                  verifiedPart.number == attempt.number,
                  verifiedPart.fingerprint == job.manifest.parts[attempt.number - 1],
                  !Self.activeParts.contains(url.resolvingSymlinksInPath().path) else {
                throw OriginalUploadStorageError.invalidPart
            }
            var info = stat()
            guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_size == verifiedPart.fingerprint.byteCount else {
                throw OriginalUploadStorageError.fileChanged
            }
            try Task.checkCancellation()
            let task = try createTask(url)
            do {
                try taskFence.requireActive(scope: job.scope, access: access)
                guard try !taskFence.isCancellationBlocked(for: job) else {
                    throw OriginalUploadStorageError.cancellationRequested
                }
                try Task.checkCancellation()
                let scheduled = try recordScheduledTask(
                    for: job, attemptId: attemptId, taskIdentifier: task.identifier, access: access)
                try Task.checkCancellation()
                try taskFence.requireActive(scope: job.scope, access: access)
                guard try !taskFence.isCancellationBlocked(for: job) else {
                    throw OriginalUploadStorageError.cancellationRequested
                }
                startTask(task.handle)
                return scheduled
            } catch {
                cancelTask(task.handle)
                throw error
            }
        }
    }

    func retireAttempt(
        for supplied: OriginalUploadJob, attemptId: UUID, session: OriginalUploadServerSession,
        tasks: OriginalUploadTaskInventory, access: OriginalUploadAccess
    ) throws -> OriginalUploadJob {
        var job = try read(id: supplied.id, access: access)
        guard job.hasSameIdentity(as: supplied), job.revision == supplied.revision else {
            throw OriginalUploadStorageError.staleJob
        }
        guard job.state == .uploading, session.id == job.sessionId,
              let index = job.attempts.firstIndex(where: { $0.id == attemptId }) else {
            throw OriginalUploadStorageError.invalidRecord
        }
        let attempt = job.attempts[index]
        guard attempt.state != .preparing else { throw OriginalUploadStorageError.invalidRecord }
        try session.validateForRecovery(for: job)
        guard taskFence.isCurrent(tasks), !tasks.hasUnidentifiedTasks, !tasks.attemptIDs.contains(attemptId),
              attempt.taskIdentifier.map({ !tasks.taskIdentifiers.contains($0) }) ?? true else {
            throw OriginalUploadStorageError.busy
        }
        let scopeDirectory = try prepareScope(access.scope)
        let directory = jobDirectory(job.id, in: scopeDirectory)
        let part = partURL(attempt, in: directory)
        guard !Self.activeParts.contains(part.resolvingSymlinksInPath().path) else {
            throw OriginalUploadStorageError.busy
        }
        if attempt.state != .retiring {
            job.attempts[index].state = .retiring
            job = try commit(job, access: access, allowAttemptChanges: true)
        }
        try OriginalUploadFiles.removeOwnedItem(part, synchronizeDirectory: synchronizeDirectory)
        job.attempts.removeAll { $0.id == attemptId }
        return try commit(job, access: access, allowAttemptChanges: true)
    }

    func replaceEndedSession(
        for supplied: OriginalUploadJob, previous: OriginalUploadServerSession,
        replacement: OriginalUploadServerSession, tasks: OriginalUploadTaskInventory,
        access: OriginalUploadAccess
    ) throws -> OriginalUploadJob {
        var job = try read(id: supplied.id, access: access)
        guard job.hasSameIdentity(as: supplied), job.revision == supplied.revision else {
            throw OriginalUploadStorageError.staleJob
        }
        guard job.state == .uploading, !job.cancellationRequested, previous.id == job.sessionId,
              [.aborted, .expired].contains(previous.status),
              replacement.id != previous.id, replacement.clipId == previous.clipId,
              [.open, .completed].contains(replacement.status) else {
            throw OriginalUploadStorageError.invalidRecord
        }
        try previous.validateForRecovery(for: job)
        try replacement.validate(for: job)
        guard taskFence.isCurrent(tasks), job.attempts.isEmpty, !tasks.hasUnidentifiedTasks,
              !tasks.jobIDs.contains(job.id) else {
            throw OriginalUploadStorageError.busy
        }
        job.sessionId = replacement.id
        return try commit(job, access: access, allowAttemptChanges: false, allowSessionReplacement: true)
    }

    func removeUnstarted(_ job: OriginalUploadJob, access: OriginalUploadAccess) throws {
        try access.require(job.scope)
        guard job.isValid, job.state == .pending, job.assetId == nil, job.sessionId == nil,
              job.attempts.isEmpty else { throw OriginalUploadStorageError.busy }
        let scopeDirectory = try prepareScope(access.scope)
        let directory = jobDirectory(job.id, in: scopeDirectory)
        let preparation = preparationDirectory(job.id, in: scopeDirectory)
        guard !Self.activePreparations.contains(preparation.resolvingSymlinksInPath().path) else {
            throw OriginalUploadStorageError.busy
        }
        var preparationInfo = stat()
        if preparation.path.withCString({ Darwin.lstat($0, &preparationInfo) }) == 0 {
            try OriginalUploadFiles.validateDirectory(preparation)
            try OriginalUploadFiles.removeOwnedItem(preparation, synchronizeDirectory: synchronizeDirectory)
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        if directory.path.withCString({ Darwin.lstat($0, &info) }) != 0, errno == ENOENT {
            try OriginalUploadFiles.removeOwnedItem(directory, synchronizeDirectory: synchronizeDirectory)
            return
        }
        let current = try read(id: job.id, access: access)
        guard current.hasSameIdentity(as: job), current.revision == job.revision else {
            throw OriginalUploadStorageError.staleJob
        }
        guard current.state == .pending, current.assetId == nil, current.sessionId == nil,
              current.attempts.isEmpty else { throw OriginalUploadStorageError.busy }
        try OriginalUploadFiles.removeOwnedItem(directory, synchronizeDirectory: synchronizeDirectory)
    }

    private func commit(
        _ job: OriginalUploadJob, access: OriginalUploadAccess, allowAttemptChanges: Bool,
        allowSessionReplacement: Bool = false
    ) throws -> OriginalUploadJob {
        try access.require(job.scope)
        guard job.isValid else { throw OriginalUploadStorageError.invalidRecord }
        let existing = try read(id: job.id, access: access)
        guard existing.hasSameIdentity(as: job) else { throw OriginalUploadStorageError.immutableJobChanged }
        guard existing.revision == job.revision else { throw OriginalUploadStorageError.staleJob }
        guard existing.assetId == nil || existing.assetId == job.assetId,
              allowSessionReplacement || existing.sessionId == nil || existing.sessionId == job.sessionId,
              !existing.cancellationRequested || job.cancellationRequested,
              Self.allowsTransition(from: existing.state, to: job.state),
              allowAttemptChanges || existing.attempts == job.attempts else {
            throw OriginalUploadStorageError.immutableJobChanged
        }
        var next = job
        let (revision, overflow) = job.revision.addingReportingOverflow(1)
        guard !overflow else { throw OriginalUploadStorageError.invalidRecord }
        next.revision = revision
        let scopeDirectory = try prepareScope(access.scope)
        try write(next, in: jobDirectory(job.id, in: scopeDirectory))
        return next
    }

    private static func allowsTransition(from: OriginalUploadState, to: OriginalUploadState) -> Bool {
        switch (from, to) {
        case (.pending, .pending), (.pending, .reserving),
             (.reserving, .reserving), (.reserving, .uploading),
             (.uploading, .uploading), (.uploading, .stored), (.stored, .stored):
            true
        default:
            false
        }
    }

    private func write(_ job: OriginalUploadJob, in directory: URL) throws {
        let destination = directory.appendingPathComponent("job.json")
        let staged = directory.appendingPathComponent("job-update-\(UUID().uuidString).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var created = false
        var published = false
        do {
            try OriginalUploadFiles.writeProtected(encoder.encode(job), to: staged)
            created = true
            let result = staged.path.withCString { source in
                destination.path.withCString { target in Darwin.rename(source, target) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            published = true
            try synchronizeDirectory(directory)
        } catch {
            let operationError = error
            if published {
                Log.error("Could not synchronize an upload journal: \(Log.describe(error))", logger: Log.upload)
                throw OriginalUploadStorageError.durabilityUncertain
            }
            if created { try OriginalUploadFiles.removeOwnedItem(staged) }
            throw operationError
        }
    }

    private func cleanupJournalStaging(in directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for file in files {
            let name = file.lastPathComponent
            let prefix = "job-update-"
            guard name.hasPrefix(prefix), name.hasSuffix(".tmp"),
                  UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil else {
                continue
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw OriginalUploadStorageError.invalidRecord
            }
            try OriginalUploadFiles.removeOwnedItem(file)
        }
    }

    private func prepareScope(_ scope: PendingFormScope) throws -> URL {
        try createProtectedDirectory(directory)
        let digest = try Self.scopeIdentifier(scope)
        let result = directory.appendingPathComponent("scope-\(digest)", isDirectory: true)
        try createProtectedDirectory(result)
        return result
    }

    static func scopeIdentifier(_ scope: PendingFormScope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(scope))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func createProtectedDirectory(_ url: URL) throws {
        try OriginalUploadFiles.createProtectedDirectory(url, synchronizeDirectory: synchronizeDirectory)
    }

    private func preparationDirectory(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("preparing-\(id.uuidString)", isDirectory: true)
    }

    private func jobDirectory(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("job-\(id.uuidString)", isDirectory: true)
    }

    private func partURL(_ attempt: OriginalUploadAttempt, in directory: URL) -> URL {
        directory.appendingPathComponent("part-\(attempt.number)-\(attempt.id.uuidString)")
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func readOnlyDirectoryIdentity(_ url: URL) throws -> DirectoryIdentity {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw OriginalUploadStorageError.invalidFile
        }
        return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
    }
}

nonisolated struct OriginalBackgroundCompletionEvidence: Equatable, Sendable {
    let eventID: UUID
    let scopeDigest: String
    let jobID: UUID
    let jobIncarnation: UUID
    let attemptID: UUID
    let taskIdentifier: Int
}

@MainActor
enum OriginalBackgroundCompletionMatcher {
    // Correlates only this event with the current authorized journal job; callers must ensure
    // it is already durable when required (the inbox is not inspected), and nil does not rule out
    // another completion.
    static func match(
        _ event: OriginalBackgroundCompletion,
        journal: OriginalUploadJournal,
        access: OriginalUploadAccess
    ) throws -> OriginalBackgroundCompletionEvidence? {
        guard event.isValid else { throw OriginalUploadStorageError.invalidRecord }
        guard let tag = event.tag else { return nil }
        guard tag.isValid else { throw OriginalUploadStorageError.invalidRecord }

        try access.require(access.scope)
        let scope = try OriginalUploadJournal.scopeIdentifier(access.scope)
        guard tag.scope == scope else { return nil }
        let job = try journal.readCurrentJob(id: tag.jobId, access: access)
        guard job.scope == access.scope, job.id == tag.jobId,
              job.incarnation == tag.jobIncarnation,
              try OriginalUploadJournal.scopeIdentifier(job.scope) == tag.scope else {
            return nil
        }
        let candidates = job.attempts.filter { $0.id == tag.attemptId }
        guard candidates.count == 1, let attempt = candidates.first,
              [.scheduled, .retiring].contains(attempt.state),
              let taskIdentifier = attempt.taskIdentifier,
              taskIdentifier > 0, taskIdentifier == event.taskIdentifier else {
            return nil
        }
        return OriginalBackgroundCompletionEvidence(
            eventID: event.id, scopeDigest: tag.scope, jobID: job.id,
            jobIncarnation: job.incarnation, attemptID: attempt.id,
            taskIdentifier: taskIdentifier)
    }
}
