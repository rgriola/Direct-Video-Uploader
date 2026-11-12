import Darwin
import Foundation

nonisolated struct OriginalBackgroundTaskTag: Codable, Equatable, Sendable {
    let scope: String
    let jobId: UUID
    let jobIncarnation: UUID
    let attemptId: UUID

    var taskDescription: String {
        "original-v2:\(scope):\(jobId.uuidString):\(jobIncarnation.uuidString):\(attemptId.uuidString)"
    }

    var isValid: Bool {
        scope.count == 64 && scope.allSatisfy { "0123456789abcdef".contains($0) }
    }

    init(scope: String, jobId: UUID, jobIncarnation: UUID, attemptId: UUID) {
        self.scope = scope
        self.jobId = jobId
        self.jobIncarnation = jobIncarnation
        self.attemptId = attemptId
    }

    init?(taskDescription: String?) {
        guard let taskDescription, taskDescription.utf8.count <= 220 else { return nil }
        let fields = taskDescription.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0] == "original-v2",
              let job = UUID(uuidString: String(fields[2])),
              let incarnation = UUID(uuidString: String(fields[3])),
              let attempt = UUID(uuidString: String(fields[4])) else { return nil }
        self.init(scope: String(fields[1]), jobId: job, jobIncarnation: incarnation, attemptId: attempt)
        guard isValid else { return nil }
    }
}

nonisolated struct OriginalBackgroundCompletion: Codable, Equatable, Sendable {
    let id: UUID
    let taskIdentifier: Int
    let tag: OriginalBackgroundTaskTag?
    let httpStatus: Int?
    let transportErrorCode: Int?

    var isValid: Bool {
        taskIdentifier > 0
            && (tag?.isValid ?? true)
            && (httpStatus.map { (100...599).contains($0) } ?? true)
    }
}

@MainActor
final class OriginalUploadEventInbox {
    private struct StoredEvent: Codable, Equatable {
        let sequence: UInt64
        let event: OriginalBackgroundCompletion
    }

    private struct ReadEvent {
        let record: StoredEvent
        let status: stat
    }

    private struct StagedEvent {
        let url: URL
        let snapshot: ReadEvent
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
        }
    }

    private struct InodeExpectation {
        var snapshot: ReadEvent
        var linkCount: Int
        var pendingNamespaceChange = false
    }

    // Keep this allowlist in sync with the on-disk event schema.
    private static let recordKeys: [Set<String>] = [
        ["sequence", "event"],
        ["id", "taskIdentifier", "tag", "httpStatus", "transportErrorCode"],
        ["scope", "jobId", "jobIncarnation", "attemptId"],
    ]

    // Cooperating writers must serialize access and keep the namespace coherent.
    // FD-relative scans do not secure prepare, recovery writes/metadata, deletion, or URLSession.
    private let directory: URL
    // Preserve the supplied spelling for lexical validation before it can be standardized.
    private let configuredDirectory: URL
    // Synchronous main-actor test observations; no descriptor is exposed.
    private let inventoryDidOpen: (() throws -> Void)?
    private let initialInventoryDidScan: (() throws -> Void)?
    private let recoveryPreflightDidComplete: (() throws -> Void)?
    private let stageDidRevalidate: (() throws -> Void)?
    private let synchronizeDirectory: (URL) throws -> Void

    init(
        directory: URL,
        synchronizeDirectory: @escaping (URL) throws -> Void = {
            try DurableFile.synchronize($0, directory: true)
        },
        inventoryDidOpen: (() throws -> Void)? = nil,
        initialInventoryDidScan: (() throws -> Void)? = nil,
        recoveryPreflightDidComplete: (() throws -> Void)? = nil,
        stageDidRevalidate: (() throws -> Void)? = nil
    ) {
        self.directory = directory.standardizedFileURL
        self.configuredDirectory = directory
        self.inventoryDidOpen = inventoryDidOpen
        self.initialInventoryDidScan = initialInventoryDidScan
        self.recoveryPreflightDidComplete = recoveryPreflightDidComplete
        self.stageDidRevalidate = stageDidRevalidate
        self.synchronizeDirectory = synchronizeDirectory
    }

    func persist(_ event: OriginalBackgroundCompletion) throws {
        guard event.isValid else { throw OriginalUploadStorageError.invalidRecord }
        try prepare()
        let records = try readRecords(matching: event)
        if records.contains(where: { $0.event.id == event.id }) {
            try synchronizeDirectory(directory)
            return
        }
        let (sequence, overflow) = (records.last?.sequence ?? 0).addingReportingOverflow(1)
        guard !overflow else { throw OriginalUploadStorageError.invalidRecord }
        let staged = directory.appendingPathComponent("event-update-\(UUID().uuidString).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let record = StoredEvent(sequence: sequence, event: event)
        try writeStage(encoder.encode(record), to: staged)
        let recovered = try readRecords(matching: event)
        guard recovered.contains(record) else { throw OriginalUploadStorageError.invalidRecord }
    }

    func events() throws -> [OriginalBackgroundCompletion] {
        try prepare()
        return try readRecords().map(\.event)
    }

    func events(scope: String) throws -> [OriginalBackgroundCompletion] {
        try events().filter { $0.tag?.scope == scope }
    }

    func unidentifiedEvents() throws -> [OriginalBackgroundCompletion] {
        try events().filter { $0.tag == nil }
    }

    func remove(_ event: OriginalBackgroundCompletion) throws {
        guard event.isValid else { throw OriginalUploadStorageError.invalidRecord }
        try prepare()
        let records = try readRecords(matching: event)
        guard let record = records.first(where: { $0.event.id == event.id }) else {
            try synchronizeCleanup()
            return
        }
        let destination = eventURL(event.id)
        let current = try read(destination)
        guard current.record == record else { throw OriginalUploadStorageError.invalidRecord }
        try unlinkFile(destination, expected: current.status)
    }

    private func readRecords(matching event: OriginalBackgroundCompletion? = nil) throws -> [StoredEvent] {
        // Keep the first inode pinned through recovery and every identity observation.
        try withInventoryDirectory { original in
            let snapshot = try scanRecords(matching: event, in: original)
            try initialInventoryDidScan?()

            // These are observations, not namespace ownership: path-based operations can
            // still race between checks or afterward, including ABA and prior substitutions.
            try withInventoryDirectory { current in
                try requireSameInventoryDirectory(original, current)
            }
            try recoveryPreflightDidComplete?()

            var canonical = snapshot.canonical
            var inodes = snapshot.inodes
            let stages = snapshot.stages.sorted {
                let left = $0.snapshot.record.sequence
                let right = $1.snapshot.record.sequence
                return left == right ? $0.url.lastPathComponent < $1.url.lastPathComponent : left < right
            }
            for stage in stages {
                let identity = FileIdentity(stage.snapshot.status)
                let current = try read(stage.url.lastPathComponent, in: original)
                guard var expected = inodes[identity] else { throw POSIXError(.ESTALE) }
                try requireExpected(current, expected: &expected)
                inodes[identity] = expected
                try stageDidRevalidate?()
                let refreshed = StagedEvent(url: stage.url, snapshot: current)
                let id = current.record.event.id
                if let canonicalIdentity = canonical[id] {
                    try discardDuplicate(
                        refreshed, canonicalIdentity: canonicalIdentity, in: original, inodes: &inodes)
                } else {
                    let synced = try protectAndSynchronize(stage.url, snapshot: current)
                    try publish(refreshed, expected: synced.status)
                    expected.snapshot = synced
                    expected.pendingNamespaceChange = true
                    inodes[identity] = expected
                    canonical[id] = identity
                }
            }

            return try withInventoryDirectory { second in
                try requireSameInventoryDirectory(original, second)
                let recovered = try scanRecords(matching: event, in: second)
                try withInventoryDirectory { current in
                    try requireSameInventoryDirectory(original, current)
                    try requireSameInventoryDirectory(second, current)
                }
                // Recovery succeeds only if the logical inbox is unchanged and no stages remain.
                guard recovered.records == snapshot.records, recovered.stages.isEmpty else {
                    throw POSIXError(.ESTALE)
                }
                return recovered.records
            }
        }
    }

    private func scanRecords(matching event: OriginalBackgroundCompletion?, in descriptor: Int32) throws -> (
        records: [StoredEvent], canonical: [UUID: FileIdentity], stages: [StagedEvent],
        inodes: [FileIdentity: InodeExpectation]
    ) {
        // The caller owns the descriptor for the whole scan.
        // Synchronous main-actor observation only; all scan I/O still uses the real descriptors.
        try inventoryDidOpen?()
        let names = try inventoryNames(in: descriptor)
        var records: [UUID: StoredEvent] = [:]
        var sequences: [UInt64: UUID] = [:]
        var canonical: [UUID: FileIdentity] = [:]
        var stages: [StagedEvent] = []
        var links: [FileIdentity: (found: Int, total: Int, snapshot: ReadEvent)] = [:]

        // Inspect the entire inbox before changing any staged file.
        for name in names {
            let canonicalID: UUID?
            if name.hasPrefix("event-update-"), name.hasSuffix(".tmp"),
               UUID(uuidString: String(name.dropFirst("event-update-".count).dropLast(4))) != nil {
                canonicalID = nil
            } else {
                // Only the generated spelling is canonical, including UUID letter case.
                guard name.hasPrefix("event-"), name.hasSuffix(".json"),
                      let id = UUID(uuidString: String(name.dropFirst("event-".count).dropLast(5))),
                      name == "event-\(id.uuidString).json" else {
                    throw OriginalUploadStorageError.invalidRecord
                }
                canonicalID = id
            }

            let snapshot = try read(name, in: descriptor)
            let record = snapshot.record
            let id = record.event.id
            let identity = FileIdentity(snapshot.status)
            if let canonicalID {
                guard canonicalID == id, canonical[canonicalID] == nil else {
                    throw OriginalUploadStorageError.invalidRecord
                }
                canonical[canonicalID] = identity
            } else {
                // This URL is for the existing path-based recovery, never for scan I/O.
                let url = directory.appendingPathComponent(name, isDirectory: false)
                stages.append(StagedEvent(url: url, snapshot: snapshot))
            }
            if let existing = records[id], existing != record {
                throw OriginalUploadStorageError.invalidRecord
            }
            if let existingID = sequences[record.sequence], existingID != id {
                throw OriginalUploadStorageError.invalidRecord
            }
            records[id] = record
            sequences[record.sequence] = id

            let total = Int(snapshot.status.st_nlink)
            if let existing = links[identity] {
                guard existing.total == total, sameVersion(existing.snapshot.status, snapshot.status),
                      existing.snapshot.record == snapshot.record else { throw POSIXError(.ESTALE) }
                links[identity] = (existing.found + 1, total, existing.snapshot)
            } else {
                links[identity] = (1, total, snapshot)
            }
        }

        // An unseen hard link could change an event outside this serialized inbox.
        guard links.values.allSatisfy({ $0.found == $0.total }) else {
            throw OriginalUploadStorageError.invalidRecord
        }
        if let event, let existing = records[event.id], existing.event != event {
            throw OriginalUploadStorageError.invalidRecord
        }
        let inodes = links.mapValues { InodeExpectation(snapshot: $0.snapshot, linkCount: $0.found) }
        return (records.values.sorted { $0.sequence < $1.sequence }, canonical, stages, inodes)
    }

    private func withInventoryDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        // The synchronous, nonescaping body borrows this descriptor.
        let descriptor = try openInventoryDirectory()
        var closed = false
        defer { if !closed { closeDirectoryDescriptorLogged(descriptor) } }
        let result = try body(descriptor)
        let closeResult = Darwin.close(descriptor)
        let closeError = errno
        closed = true
        guard closeResult == 0 else { throw posixError(closeError) }
        return result
    }

    private func requireSameInventoryDirectory(_ first: Int32, _ second: Int32) throws {
        let left = try directoryStatus(first)
        let right = try directoryStatus(second)
        // Recovery can legitimately change directory timestamps.
        guard left.st_dev == right.st_dev, left.st_ino == right.st_ino else {
            throw POSIXError(.ESTALE)
        }
    }

    private func openInventoryDirectory() throws -> Int32 {
        let homePath = NSHomeDirectory()
        // Only the OS-provided home and its OS-managed ancestors are trusted.
        let (homeDescriptor, homeError) = homePath.withCString { path in
            let result = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            return (result, result < 0 ? errno : 0)
        }
        guard homeDescriptor >= 0 else { throw posixError(homeError) }
        var descriptor = homeDescriptor
        do {
            let homeStatus = try directoryStatus(descriptor)
            let components = try inventoryComponents(under: homePath, matching: homeStatus)
            for component in components {
                // Open one component at a time; O_NOFOLLOW works on iOS 18.
                let (next, openError) = component.withCString { name in
                    let result = Darwin.openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    return (result, result < 0 ? errno : 0)
                }
                guard next >= 0 else { throw posixError(openError) }
                do {
                    _ = try directoryStatus(next)
                } catch {
                    closeDirectoryDescriptorLogged(next)
                    throw error
                }
                let previous = descriptor
                descriptor = next
                guard Darwin.close(previous) == 0 else { throw posixError() }
            }
            return descriptor
        } catch {
            closeDirectoryDescriptorLogged(descriptor)
            throw error
        }
    }

    func inventoryComponents(under homePath: String, matching homeStatus: stat) throws -> [String] {
        guard configuredDirectory.isFileURL, (configuredDirectory.host?.isEmpty ?? true),
              configuredDirectory.user == nil, configuredDirectory.password == nil,
              configuredDirectory.port == nil, configuredDirectory.query == nil,
              configuredDirectory.fragment == nil else {
            throw OriginalUploadStorageError.invalidScope
        }
        // Resolve only the OS-provided home; inbox descendants remain lexical.
        let (resolved, resolveError) = homePath.withCString { path in
            let result = Darwin.realpath(path, nil)
            return (result, result == nil ? errno : 0)
        }
        guard let resolved else { throw posixError(resolveError) }
        defer { free(resolved) }

        let home = try absoluteComponents(homePath)
        let canonicalHome = try absoluteComponents(String(cString: resolved))
        guard !home.isEmpty, !canonicalHome.isEmpty else { throw OriginalUploadStorageError.invalidScope }
        var aliases = [home, canonicalHome]
        for path in [home, canonicalHome] {
            if let alias = systemVarAlias(path) { aliases.append(alias) }
        }
        return try inventoryComponents(matching: aliases, homeStatus: homeStatus)
    }

    func inventoryComponents(matching aliases: [[String]], homeStatus: stat) throws -> [String] {
        let inbox = try absoluteComponents(configuredDirectory.path)
        let matching = aliases.filter {
            !$0.isEmpty && inbox.count >= $0.count
                && zip($0, inbox).allSatisfy { $0.0.utf8.elementsEqual($0.1.utf8) }
        }
        guard let alias = matching.max(by: { $0.count < $1.count }) else {
            throw OriginalUploadStorageError.invalidScope
        }
        try verifyHomeAlias(alias, matches: homeStatus)
        return Array(inbox.dropFirst(alias.count))
    }

    private func absoluteComponents(_ path: String) throws -> [String] {
        guard path.first == "/" else { throw OriginalUploadStorageError.invalidScope }
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
        guard components.first == "" else { throw OriginalUploadStorageError.invalidScope }
        components.removeFirst()
        if components.last == "" { components.removeLast() }
        guard components.allSatisfy({ isSafeComponent($0) }) else {
            throw OriginalUploadStorageError.invalidScope
        }
        return components
    }

    private func systemVarAlias(_ components: [String]) -> [String]? {
        if components.first?.utf8.elementsEqual("var".utf8) == true {
            return ["private"] + components
        }
        if components.count >= 2, components[0].utf8.elementsEqual("private".utf8),
           components[1].utf8.elementsEqual("var".utf8) {
            return Array(components.dropFirst())
        }
        return nil
    }

    private func verifyHomeAlias(_ components: [String], matches homeStatus: stat) throws {
        let path = "/" + components.joined(separator: "/")
        let (descriptor, openError) = path.withCString { name in
            let result = Darwin.open(name, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            return (result, result < 0 ? errno : 0)
        }
        guard descriptor >= 0 else { throw posixError(openError) }
        var closed = false
        defer { if !closed { closeDirectoryDescriptorLogged(descriptor) } }
        let status = try directoryStatus(descriptor)
        guard FileIdentity(status) == FileIdentity(homeStatus) else { throw POSIXError(.ESTALE) }
        let result = Darwin.close(descriptor)
        let closeError = errno
        closed = true
        guard result == 0 else { throw posixError(closeError) }
    }

    private func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.utf8.contains(0) && !name.utf8.contains(0x2F)
    }

    private func directoryStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw OriginalUploadStorageError.invalidFile
        }
        return status
    }

    private func inventoryNames(in descriptor: Int32) throws -> [String] {
        // dup() would share the directory offset; opening "." creates a fresh description.
        let (enumerationDescriptor, openError) = ".".withCString { name in
            let result = Darwin.openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            return (result, result < 0 ? errno : 0)
        }
        guard enumerationDescriptor >= 0 else { throw posixError(openError) }
        do {
            let parent = try directoryStatus(descriptor)
            let reopened = try directoryStatus(enumerationDescriptor)
            guard parent.st_dev == reopened.st_dev, parent.st_ino == reopened.st_ino else {
                throw POSIXError(.ESTALE)
            }
        } catch {
            closeDirectoryDescriptorLogged(enumerationDescriptor)
            throw error
        }

        guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
            let error = posixError()
            closeDirectoryDescriptorLogged(enumerationDescriptor)
            throw error
        }
        // fdopendir owns enumerationDescriptor on success.
        var closed = false
        defer {
            if !closed && Darwin.closedir(stream) != 0 {
                Log.error("Could not close the background event inventory", logger: Log.upload)
            }
        }
        var names: [String] = []
        var seen: Set<String> = []
        guard let nameOffset = MemoryLayout<dirent>.offset(of: \.d_name) else {
            throw POSIXError(.EIO)
        }
        while true {
            errno = 0
            let next = Darwin.readdir(stream)
            let readError = errno
            guard let entry = next else {
                guard readError == 0 else { throw posixError(readError) }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let recordLength = Int(entry.pointee.d_reclen)
            guard length > 0, recordLength > nameOffset, length < recordLength - nameOffset else {
                throw OriginalUploadStorageError.invalidRecord
            }
            let bytes = UnsafeRawBufferPointer(
                start: UnsafeRawPointer(entry).advanced(by: nameOffset), count: length + 1)
            guard bytes[length] == 0, let name = String(bytes: bytes.prefix(length), encoding: .utf8) else {
                throw OriginalUploadStorageError.invalidRecord
            }
            if name == "." || name == ".." { continue }
            guard isSafeComponent(name) else { throw OriginalUploadStorageError.invalidRecord }
            guard seen.insert(name).inserted else { throw POSIXError(.ESTALE) }
            names.append(name)
        }
        let closeResult = Darwin.closedir(stream)
        closed = true
        guard closeResult == 0 else { throw posixError() }
        return names
    }

    private func closeDirectoryDescriptorLogged(_ descriptor: Int32) {
        if Darwin.close(descriptor) != 0 {
            Log.error("Could not close the background event directory", logger: Log.upload)
        }
    }

    private func writeStage(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixError() }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var closed = false
        defer { if !closed { closeLogged(output) } }

        // The shared writer removes its destination on error; an event stage must instead remain in place.
        let created = try fileStatus(output)
        guard created.st_nlink == 1, sameVersion(created, try pathStatus(url)) else {
            throw POSIXError(.ESTALE)
        }
        try TemporaryVideoStorage.applyProtection(to: url)
        try OriginalUploadFiles.excludeFromBackup(url)
        try output.write(contentsOf: data)
        guard Darwin.fchmod(descriptor, mode_t(0o400)) == 0 else { throw posixError() }
        let written = try fileStatus(output)
        guard written.st_size == Int64(data.count) else { throw POSIXError(.EIO) }
        guard written.st_nlink == 1, sameVersion(written, try pathStatus(url)) else {
            throw POSIXError(.ESTALE)
        }
        try output.synchronize()
        try output.close()
        closed = true
        try synchronizeDirectory(directory)
    }

    private func protectAndSynchronize(_ url: URL, snapshot: ReadEvent) throws -> ReadEvent {
        let (file, before) = try openRegular(url)
        var closed = false
        defer { if !closed { closeLogged(file) } }
        guard sameVersion(before, snapshot.status) else { throw POSIXError(.ESTALE) }

        // A crash remnant may predate the final chmod or file synchronization.
        var needsSeal = false
        defer {
            if needsSeal && Darwin.fchmod(file.fileDescriptor, mode_t(0o400)) != 0 {
                Log.error("Could not seal a background upload event", logger: Log.upload)
            }
        }
        guard Darwin.fchmod(file.fileDescriptor, mode_t(0o600)) == 0 else { throw posixError() }
        needsSeal = true
        let writable = try fileStatus(file)
        guard sameIdentity(before, writable), before.st_nlink == writable.st_nlink,
              sameVersion(writable, try pathStatus(url)) else {
            throw POSIXError(.ESTALE)
        }
        try TemporaryVideoStorage.applyProtection(to: url)
        try OriginalUploadFiles.excludeFromBackup(url)
        guard Darwin.fchmod(file.fileDescriptor, mode_t(0o400)) == 0 else { throw posixError() }
        needsSeal = false

        let protected = try fileStatus(file)
        guard sameIdentity(before, protected), before.st_nlink == protected.st_nlink,
              sameVersion(protected, try pathStatus(url)) else {
            throw POSIXError(.ESTALE)
        }
        try file.close()
        closed = true

        let synced = try read(url, synchronizing: true)
        guard sameVersion(protected, synced.status) else { throw POSIXError(.ESTALE) }
        guard synced.record == snapshot.record else { throw OriginalUploadStorageError.invalidRecord }
        return synced
    }

    private func publish(_ stage: StagedEvent, expected: stat) throws {
        let destination = eventURL(stage.snapshot.record.event.id)
        var published = false
        do {
            try withDirectoryDescriptor { descriptor in
                try requireVersion(stage.url, expected: expected, in: descriptor)
                let result = stage.url.lastPathComponent.withCString { source in
                    destination.lastPathComponent.withCString { target in
                        Darwin.renameatx_np(
                            descriptor, source, descriptor, target, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY))
                    }
                }
                guard result == 0 else { throw posixError() }
                published = true
                try synchronizeDirectory(directory)
            }
        } catch {
            guard published else { throw error }
            Log.error("Could not confirm background event publication: \(Log.describe(error))", logger: Log.upload)
            throw OriginalUploadStorageError.durabilityUncertain
        }
    }

    private func discardDuplicate(
        _ stage: StagedEvent, canonicalIdentity: FileIdentity, in descriptor: Int32,
        inodes: inout [FileIdentity: InodeExpectation]
    ) throws {
        let beforeProtection = try read(stage.url.lastPathComponent, in: descriptor)
        guard sameVersion(stage.snapshot.status, beforeProtection.status),
              stage.snapshot.record == beforeProtection.record else { throw POSIXError(.ESTALE) }
        let destination = eventURL(stage.snapshot.record.event.id)
        let existing = try read(destination)
        guard existing.record == stage.snapshot.record else { throw OriginalUploadStorageError.invalidRecord }
        guard var canonicalExpected = inodes[canonicalIdentity] else { throw POSIXError(.ESTALE) }
        try requireExpected(existing, expected: &canonicalExpected)
        // Do not unlink the stage until the matching canonical copy and its directory entry are durable.
        let durable = try protectAndSynchronize(destination, snapshot: existing)
        canonicalExpected.snapshot = durable
        inodes[canonicalIdentity] = canonicalExpected
        try synchronizeDirectory(directory)
        let current = try read(destination)
        guard sameVersion(durable.status, current.status) else { throw POSIXError(.ESTALE) }
        let staged = try read(stage.url)
        guard sameIdentity(stage.snapshot.status, staged.status) else { throw POSIXError(.ESTALE) }
        guard current.record == stage.snapshot.record, staged.record == stage.snapshot.record else {
            throw OriginalUploadStorageError.invalidRecord
        }
        let stageIdentity = FileIdentity(stage.snapshot.status)
        guard var stageExpected = inodes[stageIdentity] else { throw POSIXError(.ESTALE) }
        // A shared inode now has the durable canonical version; an independent stage
        // must still have its exact pre-hook version.
        try requireExpected(staged, expected: &stageExpected)
        guard stageExpected.linkCount > 0 else { throw POSIXError(.ESTALE) }
        try unlinkFile(stage.url, expected: staged.status)
        stageExpected.linkCount -= 1
        stageExpected.pendingNamespaceChange = true
        inodes[stageIdentity] = stageExpected
    }

    private func unlinkFile(_ url: URL, expected: stat) throws {
        do {
            try withDirectoryDescriptor { descriptor in
                // The identity/version check and unlink are non-atomic; a replacement could be removed.
                try requireVersion(url, expected: expected, in: descriptor)
                let result = url.lastPathComponent.withCString { Darwin.unlinkat(descriptor, $0, 0) }
                guard result == 0 else { throw posixError() }
                try synchronizeDirectory(directory)
            }
        } catch {
            Log.error("Could not remove a background upload event: \(Log.describe(error))", logger: Log.upload)
            throw OriginalUploadStorageError.cleanupFailed
        }
    }

    private func requireVersion(_ url: URL, expected: stat, in descriptor: Int32) throws {
        var current = stat()
        let result = url.lastPathComponent.withCString {
            Darwin.fstatat(descriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { throw posixError() }
        guard sameVersion(expected, current) else { throw POSIXError(.ESTALE) }
    }

    private func synchronizeCleanup() throws {
        do {
            try synchronizeDirectory(directory)
        } catch {
            Log.error("Could not synchronize background event cleanup: \(Log.describe(error))", logger: Log.upload)
            throw OriginalUploadStorageError.cleanupFailed
        }
    }

    private func withDirectoryDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError() }
        var closed = false
        defer {
            if !closed && Darwin.close(descriptor) != 0 {
                Log.error("Could not close the background event directory", logger: Log.upload)
            }
        }
        let result = try body(descriptor)
        let closeResult = Darwin.close(descriptor)
        closed = true
        guard closeResult == 0 else { throw posixError() }
        return result
    }

    private func prepare() throws {
        try OriginalUploadFiles.createProtectedDirectory(directory, synchronizeDirectory: synchronizeDirectory)
    }

    private func eventURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("event-\(id.uuidString).json")
    }

    private func read(_ url: URL, synchronizing: Bool = false) throws -> ReadEvent {
        let (input, before) = try openRegular(url)
        return try read(input, before: before, synchronizing: synchronizing) {
            try pathStatus(url)
        }
    }

    private func read(_ name: String, in descriptor: Int32) throws -> ReadEvent {
        let (input, before) = try openRegular(name, in: descriptor)
        return try read(input, before: before, synchronizing: false) {
            try entryStatus(name, in: descriptor)
        }
    }

    private func read(
        _ input: FileHandle, before: stat, synchronizing: Bool, currentStatus: () throws -> stat
    ) throws -> ReadEvent {
        var closed = false
        defer { if !closed { closeLogged(input) } }
        guard before.st_size > 0, before.st_size <= 1_048_576 else {
            throw OriginalUploadStorageError.invalidRecord
        }
        let count = Int(before.st_size)
        var data = Data()
        while data.count < count {
            guard let chunk = try input.read(upToCount: min(65_536, count - data.count)), !chunk.isEmpty else {
                throw POSIXError(.EIO)
            }
            data.append(chunk)
        }
        var after = try fileStatus(input)
        guard sameVersion(before, after), sameVersion(after, try currentStatus()) else {
            throw POSIXError(.ESTALE)
        }

        let record: StoredEvent
        do {
            record = try JSONDecoder().decode(StoredEvent.self, from: data)
        } catch {
            throw OriginalUploadStorageError.invalidRecord
        }
        guard record.sequence > 0, record.event.isValid else { throw OriginalUploadStorageError.invalidRecord }
        try validateRecordKeys(data)
        if synchronizing {
            guard Darwin.fsync(input.fileDescriptor) == 0 else { throw posixError() }
            let synced = try fileStatus(input)
            guard sameVersion(after, synced), sameVersion(synced, try currentStatus()) else {
                throw POSIXError(.ESTALE)
            }
            after = synced
        }
        try input.close()
        closed = true
        return ReadEvent(record: record, status: after)
    }

    private func validateRecordKeys(_ data: Data) throws {
        // Codable ignores unknown and duplicate keys, either of which could hide a disagreement.
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw OriginalUploadStorageError.invalidRecord
        }
        let bytes = [UInt8](data)
        var scopes: [Set<String>] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                let start = index
                index += 1
                var terminated = false
                while index < bytes.count {
                    if bytes[index] == 0x5C {
                        guard index + 1 < bytes.count else { throw OriginalUploadStorageError.invalidRecord }
                        index += 2
                    } else if bytes[index] == 0x22 {
                        index += 1
                        terminated = true
                        break
                    } else {
                        index += 1
                    }
                }
                guard terminated else { throw OriginalUploadStorageError.invalidRecord }
                var next = index
                while next < bytes.count && (bytes[next] == 0x20 || bytes[next] == 0x09
                    || bytes[next] == 0x0A || bytes[next] == 0x0D) {
                    next += 1
                }
                if next < bytes.count && bytes[next] == 0x3A {
                    let depth = scopes.count
                    guard depth > 0, depth <= Self.recordKeys.count,
                          let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])),
                          Self.recordKeys[depth - 1].contains(key) else {
                        throw OriginalUploadStorageError.invalidRecord
                    }
                    guard scopes[depth - 1].insert(key).inserted else {
                        throw OriginalUploadStorageError.invalidRecord
                    }
                }
                continue
            case 0x7B:
                scopes.append([])
            case 0x7D:
                guard scopes.popLast() != nil else { throw OriginalUploadStorageError.invalidRecord }
            case 0x5B, 0x5D:
                throw OriginalUploadStorageError.invalidRecord
            default:
                break
            }
            index += 1
        }
        guard scopes.isEmpty else { throw OriginalUploadStorageError.invalidRecord }
    }

    private func openRegular(_ name: String, in directoryDescriptor: Int32) throws -> (FileHandle, stat) {
        let entry = try entryStatus(name, in: directoryDescriptor)
        guard isRegular(entry) else { throw OriginalUploadStorageError.invalidRecord }
        let (descriptor, openError) = name.withCString { component in
            let result = Darwin.openat(directoryDescriptor, component, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            return (result, result < 0 ? errno : 0)
        }
        guard descriptor >= 0 else { throw posixError(openError) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let opened = try fileStatus(file)
            guard sameVersion(entry, opened) else { throw POSIXError(.ESTALE) }
            return (file, opened)
        } catch {
            closeLogged(file)
            throw error
        }
    }

    private func entryStatus(_ name: String, in directoryDescriptor: Int32) throws -> stat {
        guard isSafeComponent(name) else { throw OriginalUploadStorageError.invalidRecord }
        var status = stat()
        let (result, statusError) = name.withCString { component in
            let result = Darwin.fstatat(directoryDescriptor, component, &status, AT_SYMLINK_NOFOLLOW)
            return (result, result == 0 ? 0 : errno)
        }
        guard result == 0 else { throw posixError(statusError) }
        return status
    }

    private func openRegular(_ url: URL) throws -> (FileHandle, stat) {
        let path = try pathStatus(url)
        guard isRegular(path) else { throw OriginalUploadStorageError.invalidRecord }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let opened = try fileStatus(file)
            guard sameVersion(path, opened) else { throw POSIXError(.ESTALE) }
            return (file, opened)
        } catch {
            closeLogged(file)
            throw error
        }
    }

    private func fileStatus(_ file: FileHandle) throws -> stat {
        var status = stat()
        guard Darwin.fstat(file.fileDescriptor, &status) == 0 else { throw posixError() }
        return status
    }

    private func pathStatus(_ url: URL) throws -> stat {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { throw posixError() }
        return status
    }

    private func isRegular(_ status: stat) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private func sameIdentity(_ left: stat, _ right: stat) -> Bool {
        isRegular(left) && isRegular(right) && left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    private func sameVersion(_ left: stat, _ right: stat) -> Bool {
        sameIdentity(left, right) && left.st_mode == right.st_mode
            && left.st_uid == right.st_uid && left.st_gid == right.st_gid && left.st_nlink == right.st_nlink
            && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }

    private func requireExpected(_ current: ReadEvent, expected: inout InodeExpectation) throws {
        guard Int(current.status.st_nlink) == expected.linkCount else { throw POSIXError(.ESTALE) }
        var previous = expected.snapshot.status
        if expected.pendingNamespaceChange {
            // After our rename or unlink, only the predicted count and change time may differ.
            previous.st_nlink = current.status.st_nlink
            previous.st_ctimespec = current.status.st_ctimespec
        }
        guard sameVersion(previous, current.status), expected.snapshot.record == current.record else {
            throw POSIXError(.ESTALE)
        }
        expected.snapshot = current
        expected.pendingNamespaceChange = false
    }

    private func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private func closeLogged(_ file: FileHandle) {
        do {
            try file.close()
        } catch {
            Log.error("Could not close a background upload event: \(Log.describe(error))", logger: Log.upload)
        }
    }
}

nonisolated struct OriginalBackgroundCancellationResult: Sendable {
    let job: OriginalUploadJob
    let requestedTaskIdentifiers: Set<Int>
    let hasUnidentifiedTasks: Bool
}

nonisolated struct OriginalBackgroundTaskSnapshot: Sendable {
    let identifier: Int
    let tag: OriginalBackgroundTaskTag?
}

nonisolated struct OriginalBackgroundTaskIndex: Sendable {
    let taskIdentifiers: Set<Int>
    let jobIDs: Set<UUID>
    let attemptIDs: Set<UUID>
    let hasUnidentifiedTasks: Bool
    private let tags: [Int: OriginalBackgroundTaskTag]

    init(_ tasks: [OriginalBackgroundTaskSnapshot]) {
        var identifiers: Set<Int> = []
        var jobs: Set<UUID> = []
        var attempts: Set<UUID> = []
        var known: [Int: OriginalBackgroundTaskTag] = [:]
        var unidentified = false
        for task in tasks {
            guard task.identifier > 0, identifiers.insert(task.identifier).inserted else {
                unidentified = true
                known.removeValue(forKey: task.identifier)
                continue
            }
            guard let tag = task.tag, tag.isValid else {
                unidentified = true
                continue
            }
            if !attempts.insert(tag.attemptId).inserted { unidentified = true }
            jobs.insert(tag.jobId)
            known[task.identifier] = tag
        }
        self.taskIdentifiers = identifiers
        self.jobIDs = jobs
        self.attemptIDs = attempts
        self.hasUnidentifiedTasks = unidentified
        self.tags = known
    }

    func cancellationTargets(scope: String, jobId: UUID, incarnation: UUID) -> Set<Int> {
        Set(tags.compactMap { identifier, tag in
            tag.scope == scope && tag.jobId == jobId && tag.jobIncarnation == incarnation ? identifier : nil
        })
    }
}

@MainActor
enum OriginalBackgroundCancellation {
    static func request<TaskHandle>(
        for supplied: OriginalUploadJob, journal: OriginalUploadJournal,
        fence: OriginalUploadTaskFence, access: OriginalUploadAccess,
        tasks: @MainActor () async -> [TaskHandle],
        snapshot: @MainActor (TaskHandle) -> OriginalBackgroundTaskSnapshot,
        cancel: @MainActor (TaskHandle) -> Void
    ) async throws -> OriginalBackgroundCancellationResult {
        try access.require(supplied.scope)
        try fence.blockCancellation(for: supplied)
        let scope = try OriginalUploadJournal.scopeIdentifier(supplied.scope)
        var savedJob: OriginalUploadJob?
        var failure: (any Error)?
        do {
            guard journal.usesTaskFence(fence) else { throw OriginalUploadStorageError.invalidRecord }
            savedJob = try journal.requestCancellation(for: supplied, access: access)
        } catch {
            failure = error
        }

        let revision = fence.beginSnapshot()
        let handles = await tasks()
        let entries = handles.map { (handle: $0, snapshot: snapshot($0)) }
        let index = OriginalBackgroundTaskIndex(entries.map(\.snapshot))
        let targets = index.cancellationTargets(
            scope: scope, jobId: supplied.id, incarnation: supplied.incarnation)
        for entry in entries where targets.contains(entry.snapshot.identifier) {
            cancel(entry.handle)
        }
        do {
            _ = try fence.inventory(
                snapshot: revision, taskIdentifiers: index.taskIdentifiers, jobIDs: index.jobIDs,
                attemptIDs: index.attemptIDs, hasUnidentifiedTasks: index.hasUnidentifiedTasks)
        } catch {
            if failure == nil {
                failure = error
            } else {
                Log.error("Could not confirm upload task inventory: \(Log.describe(error))", logger: Log.upload)
            }
        }
        if let failure { throw failure }
        guard let savedJob else { throw OriginalUploadStorageError.invalidRecord }
        return OriginalBackgroundCancellationResult(
            job: savedJob, requestedTaskIdentifiers: targets,
            hasUnidentifiedTasks: index.hasUnidentifiedTasks)
    }
}

@MainActor
final class OriginalBackgroundEventPump {
    private let inbox: OriginalUploadEventInbox
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pending: [OriginalBackgroundCompletion] = []
    private var processing = false
    private var retryCount = 0
    private var retryTask: Task<Void, Never>?
    private var retryID: UUID?
    private(set) var hasPersistenceError = false
    var onPendingEvents: (@MainActor () -> Void)?

    init(
        inbox: OriginalUploadEventInbox,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.inbox = inbox
        self.sleep = sleep
    }

    func accept(_ event: OriginalBackgroundCompletion) {
        pending.append(event)
        process()
    }

    func acknowledgeReconciledEvent(_ event: OriginalBackgroundCompletion) throws {
        // A failed publication sync can leave an event visible while it is still pending.
        guard !pending.contains(where: { $0.id == event.id }) else {
            throw OriginalUploadStorageError.busy
        }
        try inbox.remove(event)
    }

    func retry() {
        retryTask?.cancel()
        retryTask = nil
        retryID = nil
        retryCount = 0
        process()
    }

    private func process() {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        while let event = pending.first {
            do {
                try inbox.persist(event)
            } catch {
                hasPersistenceError = true
                Log.error("Could not persist background upload completion: \(Log.describe(error))", logger: Log.upload)
                scheduleRetry()
                return
            }
            pending.removeFirst()
            hasPersistenceError = false
            retryCount = 0
            onPendingEvents?()
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil, retryCount < 5 else { return }
        let delay = 1 << retryCount
        retryCount += 1
        let id = UUID()
        retryID = id
        let sleep = sleep
        retryTask = Task { @MainActor [weak self] in
            do {
                try await sleep(.seconds(delay))
            } catch {
                guard !Task.isCancelled, let self, self.retryID == id else { return }
                self.retryID = nil
                self.retryTask = nil
                Log.error("Could not schedule a background upload retry: \(Log.describe(error))", logger: Log.upload)
                return
            }
            guard !Task.isCancelled, let self, self.retryID == id else { return }
            self.retryID = nil
            self.retryTask = nil
            self.process()
        }
    }
}

nonisolated final class OriginalBackgroundSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let continuation: AsyncStream<OriginalBackgroundCompletion>.Continuation

    init(continuation: AsyncStream<OriginalBackgroundCompletion>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let event = OriginalBackgroundCompletion(
            id: UUID(), taskIdentifier: task.taskIdentifier,
            tag: OriginalBackgroundTaskTag(taskDescription: task.taskDescription),
            httpStatus: status, transportErrorCode: error.map { ($0 as NSError).code })
        continuation.yield(event)
    }
}

@MainActor
final class OriginalUploadBackgroundTransport {
    static let identifier = "com.directvideo.uploader.original-uploads"
    private static var instance: OriginalUploadBackgroundTransport?
    @available(*, unavailable, message: "Background upload reattachment and reconciliation are not yet integrated.")
    static var shared: OriginalUploadBackgroundTransport {
        if let instance { return instance }
        let transport = OriginalUploadBackgroundTransport()
        instance = transport
        return transport
    }

    private let session: URLSession
    private let pump: OriginalBackgroundEventPump
    private let inbox: OriginalUploadEventInbox
    private let taskFence: OriginalUploadTaskFence
    private var eventTask: Task<Void, Never>?

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OriginalUploads", isDirectory: true)
        let inbox = OriginalUploadEventInbox(
            directory: root.appendingPathComponent("BackgroundEvents", isDirectory: true))
        let pump = OriginalBackgroundEventPump(inbox: inbox)
        let events = AsyncStream<OriginalBackgroundCompletion>.makeStream()
        let delegate = OriginalBackgroundSessionDelegate(continuation: events.continuation)
        let queue = OperationQueue()
        queue.name = "com.directvideo.uploader.original-events"
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        self.pump = pump
        self.inbox = inbox
        self.taskFence = .shared
        self.eventTask = Task { @MainActor in
            for await event in events.stream {
                pump.accept(event)
            }
        }
    }

    var hasPersistenceError: Bool { pump.hasPersistenceError }

    func retryPendingEvents() {
        pump.retry()
    }

    func observePendingEvents(_ handler: @escaping @MainActor () -> Void) throws {
        pump.onPendingEvents = handler
        if try !inbox.events().isEmpty { handler() }
    }

    func pendingEvents(for access: OriginalUploadAccess) throws -> [OriginalBackgroundCompletion] {
        try access.require(access.scope)
        let scope = try OriginalUploadJournal.scopeIdentifier(access.scope)
        return try inbox.events(scope: scope)
    }

    func unidentifiedEvents() throws -> [OriginalBackgroundCompletion] {
        try inbox.unidentifiedEvents()
    }

    func acknowledgeReconciledEvent(
        _ event: OriginalBackgroundCompletion, access: OriginalUploadAccess
    ) throws {
        try access.require(access.scope)
        guard event.tag?.scope == (try OriginalUploadJournal.scopeIdentifier(access.scope)) else {
            throw OriginalUploadStorageError.invalidScope
        }
        try pump.acknowledgeReconciledEvent(event)
    }

    func taskInventory() async throws -> OriginalUploadTaskInventory {
        let snapshot = taskFence.beginSnapshot()
        let tasks = await session.allTasks
        try Task.checkCancellation()
        let index = OriginalBackgroundTaskIndex(tasks.map {
            OriginalBackgroundTaskSnapshot(
                identifier: $0.taskIdentifier,
                tag: OriginalBackgroundTaskTag(taskDescription: $0.taskDescription))
        })
        return try taskFence.inventory(
            snapshot: snapshot, taskIdentifiers: index.taskIdentifiers, jobIDs: index.jobIDs,
            attemptIDs: index.attemptIDs, hasUnidentifiedTasks: index.hasUnidentifiedTasks)
    }

    func requestCancellation(
        for supplied: OriginalUploadJob, journal: OriginalUploadJournal, access: OriginalUploadAccess
    ) async throws -> OriginalBackgroundCancellationResult {
        try await OriginalBackgroundCancellation.request(
            for: supplied, journal: journal, fence: taskFence, access: access,
            tasks: { await self.session.allTasks },
            snapshot: {
                OriginalBackgroundTaskSnapshot(
                    identifier: $0.taskIdentifier,
                    tag: OriginalBackgroundTaskTag(taskDescription: $0.taskDescription))
            },
            cancel: { $0.cancel() })
    }

    func schedule(
        for job: OriginalUploadJob, attemptId: UUID, part: OriginalUploadPart,
        capability: OriginalUploadPartCapability, journal: OriginalUploadJournal,
        access: OriginalUploadAccess
    ) throws -> OriginalUploadJob {
        try access.require(job.scope)
        guard journal.usesTaskFence(taskFence) else { throw OriginalUploadStorageError.invalidRecord }
        try capability.require(job: job, part: part, access: access, now: Date())
        let tag = OriginalBackgroundTaskTag(
            scope: try OriginalUploadJournal.scopeIdentifier(job.scope),
            jobId: job.id, jobIncarnation: job.incarnation, attemptId: attemptId)
        var request = URLRequest(url: capability.url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(part.fingerprint.byteCount), forHTTPHeaderField: "Content-Length")
        return try journal.scheduleReadyPart(
            for: job, attemptId: attemptId, verifiedPart: part, access: access,
            createTask: { url in
                let task = session.uploadTask(with: request, fromFile: url)
                task.taskDescription = tag.taskDescription
                return (handle: task, identifier: task.taskIdentifier)
            },
            startTask: { $0.resume() }, cancelTask: { $0.cancel() })
    }
}
