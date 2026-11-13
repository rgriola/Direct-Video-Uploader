import Darwin
import Foundation
import Synchronization
import Testing
@testable import DirectVideoUploader

@MainActor
struct OriginalUploadBackgroundTransportTests {
    nonisolated private struct StoredEventFixture: Codable {
        let sequence: UInt64
        let event: OriginalBackgroundCompletion
    }

    nonisolated enum EventLocation: String, Sendable {
        case staged, canonical
    }

    nonisolated enum EventDamage: String, Sendable {
        case empty, partial, corrupt, invalidSequence, invalidCompletion, wrongCanonicalID
    }

    nonisolated enum StagedProblem: String, Sendable {
        case corrupt, conflicting
    }

    nonisolated enum DuplicateKeyForm: String, Sendable {
        case sequence, escapedSequence, taskIdentifier, escapedTaskIdentifier, scope, escapedScope
    }

    nonisolated enum IdentityDifference: String, Sendable {
        case completion, sequence
    }

    nonisolated enum IdentityLayout: String, Sendable {
        case canonicalAndStaged, twoStaged
    }

    nonisolated enum SequenceLayout: String, Sendable {
        case canonicalAndStaged, twoStaged, twoCanonical
    }

    nonisolated enum InboxOperation: String, Sendable {
        case events, persist, remove
    }

    nonisolated enum ExternalLinkRecoveryLayout: String, Sendable {
        case publication, stagedDuplicate, stagedDuplicateWritableCanonical
        case canonicalDuplicate, writableCanonicalDuplicate
    }

    nonisolated enum ExternalLinkInjectionPoint: String, Sendable {
        case afterInventory, afterStageRevalidation
    }

    private enum AncestorReplacement {
        case symbolicLink, directory
    }

    private struct FixtureFileSnapshot {
        let url: URL
        let bytes: Data
        let status: stat
    }

    private struct FixtureFileObservations {
        let file: FixtureFileSnapshot
        let protection: String?
        let excludedFromBackup: Bool?
    }

    private struct InboxDirectorySwap {
        let active: URL
        let parked: URL
        let decoy: URL
        let originalStatus: stat
        let decoyStatus: stat
        let originalSentinel: FixtureFileSnapshot
        let decoySentinel: FixtureFileSnapshot
    }

    private struct InboxFilesFixture {
        let canonicalEvent: OriginalBackgroundCompletion
        let stagedEvent: OriginalBackgroundCompletion
        let canonical: URL
        let canonicalBytes: Data
        let canonicalStatus: stat
        let stage: URL
        let stageBytes: Data
        let stageStatus: stat
        let sentinelBytes: Data
        let sentinelStatus: stat
    }

    nonisolated private static func varAliasPaths(for path: String) -> (varPath: String, privatePath: String)? {
        if path == "/var" || path.hasPrefix("/var/") {
            return (path, "/private" + path)
        }
        if path == "/private/var" || path.hasPrefix("/private/var/") {
            return (String(path.dropFirst("/private".count)), path)
        }
        return nil
    }

    nonisolated private static func sameDirectoryFollowingLinks(_ first: String, _ second: String) -> Bool {
        var left = stat()
        var right = stat()
        guard first.withCString({ Darwin.fstatat(AT_FDCWD, $0, &left, 0) }) == 0,
              second.withCString({ Darwin.fstatat(AT_FDCWD, $0, &right, 0) }) == 0 else {
            return false
        }
        return left.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && right.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    nonisolated fileprivate static func hasRealVarAliasInAppHome() -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        guard let homePaths = varAliasPaths(for: home.path),
              let temporaryPaths = varAliasPaths(for: temporary.path) else { return false }
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedTemporary = temporary.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedTemporary == resolvedHome || resolvedTemporary.hasPrefix(resolvedHome + "/") else {
            return false
        }
        var link = stat()
        guard "/var".withCString({ Darwin.lstat($0, &link) }) == 0,
              link.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else { return false }
        return sameDirectoryFollowingLinks("/var", "/private/var")
            && sameDirectoryFollowingLinks(homePaths.varPath, homePaths.privatePath)
            && sameDirectoryFollowingLinks(temporaryPaths.varPath, temporaryPaths.privatePath)
    }

    private func fixture() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let parent = temporary.standardizedFileURL.resolvingSymlinksInPath().path
        try #require(parent == home || parent.hasPrefix(home + "/"))
        let directory = temporary
            .appendingPathComponent("original-events-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanup(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove the event test directory: \(Log.describe(error))")
        }
    }

    private func event(id: UUID = UUID(), taskIdentifier: Int = 17) -> OriginalBackgroundCompletion {
        OriginalBackgroundCompletion(
            id: id, taskIdentifier: taskIdentifier,
            tag: OriginalBackgroundTaskTag(
                scope: String(repeating: "a", count: 64), jobId: UUID(),
                jobIncarnation: UUID(), attemptId: UUID()),
            httpStatus: 200, transportErrorCode: nil)
    }

    private func unidentifiedEvent(
        id: UUID = UUID(), taskIdentifier: Int = 17
    ) -> OriginalBackgroundCompletion {
        OriginalBackgroundCompletion(
            id: id, taskIdentifier: taskIdentifier, tag: nil,
            httpStatus: nil, transportErrorCode: -1)
    }

    private func canonicalURL(for event: OriginalBackgroundCompletion, in directory: URL) -> URL {
        directory.appendingPathComponent("event-\(event.id.uuidString).json")
    }

    private func stagedURL(in directory: URL, nonce: UUID = UUID()) -> URL {
        directory.appendingPathComponent("event-update-\(nonce.uuidString).tmp")
    }

    private func orderedSiblingStages(in directory: URL) throws -> (first: URL, second: URL) {
        let first = stagedURL(
            in: directory, nonce: try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001")))
        let second = stagedURL(
            in: directory, nonce: try #require(UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")))
        try #require(first.lastPathComponent < second.lastPathComponent)
        return (first, second)
    }

    private func recordBytes(_ event: OriginalBackgroundCompletion, sequence: UInt64) throws -> Data {
        try JSONEncoder().encode(StoredEventFixture(sequence: sequence, event: event))
    }

    private func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func fileStatus(at url: URL) throws -> stat {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    private func expectFileVersionUnchanged(_ original: stat, at url: URL) throws {
        let current = try fileStatus(at: url)
        #expect(current.st_dev == original.st_dev && current.st_ino == original.st_ino)
        #expect(current.st_mode == original.st_mode)
        #expect(current.st_uid == original.st_uid && current.st_gid == original.st_gid)
        #expect(current.st_nlink == original.st_nlink)
        #expect(current.st_size == original.st_size)
        #expect(current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec
            && current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)
        #expect(current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec
            && current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec)
    }

    private func expectFixtureFileUnchanged(_ bytes: Data, status: stat, at url: URL) {
        #expect((try? Data(contentsOf: url)) == bytes)
        do {
            try expectFileVersionUnchanged(status, at: url)
        } catch {
            Issue.record("Could not inspect an event fixture file: \(Log.describe(error))")
        }
    }

    private func requireFixtureInsideHome(_ directory: URL) throws {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let owned = directory.standardizedFileURL.resolvingSymlinksInPath().path
        try #require(owned.hasPrefix(home + "/"))
    }

    private func snapshotFixtureFile(at url: URL) throws -> FixtureFileSnapshot {
        let bytes = try Data(contentsOf: url)
        return FixtureFileSnapshot(url: url, bytes: bytes, status: try fileStatus(at: url))
    }

    private func snapshotFixtureFileObservations(at url: URL) throws -> FixtureFileObservations {
        let file = try snapshotFixtureFile(at: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let freshURL = URL(fileURLWithPath: url.path, isDirectory: false)
        let excluded = try freshURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        return FixtureFileObservations(
            file: file, protection: attributes[.protectionKey] as? String, excludedFromBackup: excluded)
    }

    private func expectFixtureFileObservationsUnchanged(_ original: FixtureFileObservations) throws {
        let url = original.file.url
        expectFixtureFileUnchanged(original.file.bytes, status: original.file.status, at: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.protectionKey] as? String == original.protection)
        // Avoid reusing a URL that may have cached resource values.
        let freshURL = URL(fileURLWithPath: url.path, isDirectory: false)
        #expect(try freshURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            == original.excludedFromBackup)
    }

    private func createFixtureFile(_ bytes: Data, at url: URL) throws -> FixtureFileSnapshot {
        try #require(!itemExists(at: url))
        try #require(FileManager.default.createFile(
            atPath: url.path, contents: bytes, attributes: [.posixPermissions: 0o600]))
        return try snapshotFixtureFile(at: url)
    }

    private func createHardLinkedSiblingStages(
        _ bytes: Data, in directory: URL
    ) throws -> (first: FixtureFileSnapshot, second: FixtureFileSnapshot) {
        let (first, second) = try orderedSiblingStages(in: directory)
        let created = try createFixtureFile(bytes, at: first)
        try TemporaryVideoStorage.applyProtection(to: first)
        try OriginalUploadFiles.excludeFromBackup(first)
        let beforeLink = try snapshotFixtureFile(at: first)
        try #require(beforeLink.status.st_dev == created.status.st_dev
            && beforeLink.status.st_ino == created.status.st_ino)
        try #require(beforeLink.status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        try #require(beforeLink.status.st_mode & mode_t(0o7777) == mode_t(0o600))
        try #require(beforeLink.status.st_nlink == 1 && beforeLink.bytes == bytes)
        try #require(!itemExists(at: second))
        try FileManager.default.linkItem(at: first, to: second)
        let linkedFirst = try snapshotFixtureFile(at: first)
        let linkedSecond = try snapshotFixtureFile(at: second)
        try #require(linkedFirst.status.st_dev == beforeLink.status.st_dev
            && linkedFirst.status.st_ino == beforeLink.status.st_ino)
        try #require(linkedSecond.status.st_dev == linkedFirst.status.st_dev
            && linkedSecond.status.st_ino == linkedFirst.status.st_ino)
        try #require(linkedFirst.status.st_nlink == 2 && linkedSecond.status.st_nlink == 2)
        try #require(linkedFirst.bytes == bytes && linkedSecond.bytes == bytes)
        return (linkedFirst, linkedSecond)
    }

    private func makeInboxDirectorySwap(in directory: URL) throws -> InboxDirectorySwap {
        try requireFixtureInsideHome(directory)
        let active = directory.appendingPathComponent("active", isDirectory: true)
        let parked = directory.appendingPathComponent("parked", isDirectory: true)
        let decoy = directory.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: false)
        try #require(!itemExists(at: parked))
        let originalStatus = try fileStatus(at: active)
        let decoyStatus = try fileStatus(at: decoy)
        try #require(originalStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
        try #require(decoyStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
        try #require(originalStatus.st_dev != decoyStatus.st_dev || originalStatus.st_ino != decoyStatus.st_ino)
        let originalSentinel = try createFixtureFile(
            Data("original sentinel".utf8), at: directory.appendingPathComponent("original-sentinel"))
        let decoySentinel = try createFixtureFile(
            Data("decoy sentinel".utf8), at: directory.appendingPathComponent("decoy-sentinel"))
        return InboxDirectorySwap(
            active: active, parked: parked, decoy: decoy,
            originalStatus: originalStatus, decoyStatus: decoyStatus,
            originalSentinel: originalSentinel, decoySentinel: decoySentinel)
    }

    private func swapInboxDirectories(_ swap: InboxDirectorySwap) throws {
        try FileManager.default.moveItem(at: swap.active, to: swap.parked)
        try FileManager.default.moveItem(at: swap.decoy, to: swap.active)
    }

    private func expectSwappedDirectoriesAndSentinelsUnchanged(_ swap: InboxDirectorySwap) throws {
        let parked = try fileStatus(at: swap.parked)
        let active = try fileStatus(at: swap.active)
        #expect(parked.st_dev == swap.originalStatus.st_dev && parked.st_ino == swap.originalStatus.st_ino)
        #expect(active.st_dev == swap.decoyStatus.st_dev && active.st_ino == swap.decoyStatus.st_ino)
        #expect(!itemExists(at: swap.decoy))
        for sentinel in [swap.originalSentinel, swap.decoySentinel] {
            expectFixtureFileUnchanged(sentinel.bytes, status: sentinel.status, at: sentinel.url)
        }
    }

    private func expectInboxNames(_ names: [String], in directory: URL) throws {
        let actual = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(actual) == Set(names))
    }

    private func seedIdenticalCanonicalCopies(
        _ completion: OriginalBackgroundCompletion, in swap: InboxDirectorySwap
    ) throws -> (original: FixtureFileSnapshot, decoy: FixtureFileSnapshot) {
        let bytes = try recordBytes(completion, sequence: 1)
        let original = canonicalURL(for: completion, in: swap.active)
        let decoy = canonicalURL(for: completion, in: swap.decoy)
        try OriginalUploadFiles.writeProtected(bytes, to: original)
        try OriginalUploadFiles.writeProtected(bytes, to: decoy)
        let originalFile = try snapshotFixtureFile(at: original)
        let decoyFile = try snapshotFixtureFile(at: decoy)
        try #require(originalFile.url.lastPathComponent == decoyFile.url.lastPathComponent)
        try #require(originalFile.bytes == bytes && decoyFile.bytes == bytes)
        try #require(originalFile.status.st_dev != decoyFile.status.st_dev
            || originalFile.status.st_ino != decoyFile.status.st_ino)
        try #require(originalFile.status.st_nlink == 1 && decoyFile.status.st_nlink == 1)
        return (originalFile, decoyFile)
    }

    private func nestedInbox(under ancestor: URL) -> URL {
        ancestor.appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("inbox", isDirectory: true)
    }

    private func seedInboxWithStage(
        under ancestor: URL, canonical canonicalEvent: OriginalBackgroundCompletion
    ) throws -> InboxFilesFixture {
        let inbox = nestedInbox(under: ancestor)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stagedEvent = event(taskIdentifier: 92)
        try #require(canonicalEvent.isValid && stagedEvent.isValid)
        try #require(canonicalEvent.id != stagedEvent.id)
        let canonical = canonicalURL(for: canonicalEvent, in: inbox)
        let canonicalBytes = try recordBytes(canonicalEvent, sequence: 1)
        try OriginalUploadFiles.writeProtected(canonicalBytes, to: canonical)

        let stage = stagedURL(in: inbox)
        let stageBytes = try recordBytes(stagedEvent, sequence: 2)
        try #require(!itemExists(at: stage))
        let created = FileManager.default.createFile(
            atPath: stage.path, contents: stageBytes, attributes: [.posixPermissions: 0o600])
        try #require(created)
        try TemporaryVideoStorage.applyProtection(to: stage)
        try OriginalUploadFiles.excludeFromBackup(stage)
        let stageStatus = try fileStatus(at: stage)
        try #require(stageStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        try #require(stageStatus.st_mode & mode_t(0o7777) == mode_t(0o600))
        try #require(stageStatus.st_nlink == 1)
        try #require(try Data(contentsOf: stage) == stageBytes)
        try #require(!itemExists(at: canonicalURL(for: stagedEvent, in: inbox)))

        let sentinel = inbox.deletingLastPathComponent().appendingPathComponent("sibling-sentinel.txt")
        let sentinelBytes = Data("untouched sibling sentinel".utf8)
        let sentinelCreated = FileManager.default.createFile(
            atPath: sentinel.path, contents: sentinelBytes, attributes: [.posixPermissions: 0o600])
        try #require(sentinelCreated)
        return InboxFilesFixture(
            canonicalEvent: canonicalEvent, stagedEvent: stagedEvent,
            canonical: canonical, canonicalBytes: canonicalBytes, canonicalStatus: try fileStatus(at: canonical),
            stage: stage, stageBytes: stageBytes, stageStatus: stageStatus,
            sentinelBytes: sentinelBytes, sentinelStatus: try fileStatus(at: sentinel))
    }

    private func expectInboxFixtureUnchanged(_ files: InboxFilesFixture, under ancestor: URL) {
        let inbox = nestedInbox(under: ancestor)
        let canonical = inbox.appendingPathComponent(files.canonical.lastPathComponent)
        let stage = inbox.appendingPathComponent(files.stage.lastPathComponent)
        let sentinel = inbox.deletingLastPathComponent().appendingPathComponent("sibling-sentinel.txt")
        expectFixtureFileUnchanged(files.canonicalBytes, status: files.canonicalStatus, at: canonical)
        expectFixtureFileUnchanged(files.stageBytes, status: files.stageStatus, at: stage)
        expectFixtureFileUnchanged(files.sentinelBytes, status: files.sentinelStatus, at: sentinel)
        #expect(!itemExists(at: canonicalURL(for: files.stagedEvent, in: inbox)))
    }

    private func removeFixtureLink(_ url: URL) throws {
        let status = try fileStatus(at: url)
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else { throw POSIXError(.EINVAL) }
        guard url.path.withCString({ Darwin.unlink($0) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func isUnsafeAncestorRejection(_ error: any Error) -> Bool {
        if let error = error as? POSIXError {
            return error.code == .ELOOP || error.code == .ENOTDIR
        }
        return false
    }

    private func exerciseAncestorSwap(
        _ replacement: AncestorReplacement, sameNameConflict: Bool = false
    ) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        try requireFixtureInsideHome(directory)
        let active = directory.appendingPathComponent("active", isDirectory: false)
        let parked = directory.appendingPathComponent("parked", isDirectory: false)
        let decoy = directory.appendingPathComponent("decoy", isDirectory: false)
        let originalInbox = nestedInbox(under: active)
        try FileManager.default.createDirectory(at: originalInbox, withIntermediateDirectories: true)
        let original = event(taskIdentifier: 11)
        let originalURL = canonicalURL(for: original, in: originalInbox)
        let originalBytes = try recordBytes(original, sequence: 1)
        try OriginalUploadFiles.writeProtected(originalBytes, to: originalURL)
        let originalStatus = try fileStatus(at: originalURL)
        let originalAncestorStatus = try fileStatus(at: active)
        let decoyEvent = sameNameConflict
            ? event(id: original.id, taskIdentifier: 91) : event(taskIdentifier: 91)
        let decoyFiles = try seedInboxWithStage(under: decoy, canonical: decoyEvent)
        let decoyAncestorStatus = try fileStatus(at: decoy)
        let ownedPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let decoyPath = decoy.resolvingSymlinksInPath().standardizedFileURL.path
        try #require(decoyPath.hasPrefix(ownedPath + "/"))
        try #require(!itemExists(at: parked))
        try #require(original != decoyEvent)
        try #require(originalBytes != decoyFiles.canonicalBytes)
        try #require(original.id != decoyFiles.stagedEvent.id)
        try #require(try FileManager.default.contentsOfDirectory(atPath: originalInbox.path)
            == [originalURL.lastPathComponent])
        if sameNameConflict {
            try #require(originalURL.lastPathComponent == decoyFiles.canonical.lastPathComponent)
        } else {
            let originalNameInDecoy = nestedInbox(under: decoy).appendingPathComponent(originalURL.lastPathComponent)
            try #require(!itemExists(at: originalNameInDecoy))
        }

        var originalParked = false
        var replacementInstalled = false
        defer {
            if replacementInstalled {
                do {
                    switch replacement {
                    case .symbolicLink:
                        try removeFixtureLink(active)
                    case .directory:
                        try FileManager.default.moveItem(at: active, to: decoy)
                    }
                } catch {
                    Issue.record("Could not restore the substituted event ancestor: \(Log.describe(error))")
                }
            }
            if originalParked {
                do {
                    try FileManager.default.moveItem(at: parked, to: active)
                } catch {
                    Issue.record("Could not restore the original event ancestor: \(Log.describe(error))")
                }
            }
        }

        var inventoryOpens = 0
        let inbox = OriginalUploadEventInbox(directory: originalInbox, inventoryDidOpen: {
            inventoryOpens += 1
            guard inventoryOpens == 1 else { return }
            try FileManager.default.moveItem(at: active, to: parked)
            originalParked = true
            switch replacement {
            case .symbolicLink:
                try FileManager.default.createSymbolicLink(atPath: active.path, withDestinationPath: decoy.path)
            case .directory:
                try FileManager.default.moveItem(at: decoy, to: active)
            }
            replacementInstalled = true
        })

        // Only inventory reads are descriptor-rooted. Prepare, staged recovery,
        // writes, and removal still use path-based operations. The original has
        // no stages, and the pre-recovery checkpoint rejects the replacement.
        let failure = #expect(throws: (any Error).self) {
            if sameNameConflict {
                // This matching-record check fails in the first scan, before persist can write.
                try inbox.persist(decoyEvent)
            } else {
                _ = try inbox.events()
            }
        }
        try #require(originalParked && replacementInstalled)
        if sameNameConflict {
            #expect(inventoryOpens == 1)
            if let failure {
                #expect((failure as? OriginalUploadStorageError) == .invalidRecord)
            }
        } else {
            switch replacement {
            case .symbolicLink:
                // The checkpoint cannot open the substituted symlink ancestor.
                #expect(inventoryOpens == 1)
                if let failure { #expect(isUnsafeAncestorRejection(failure)) }
            case .directory:
                // The checkpoint rejects the replacement before a second scan.
                #expect(inventoryOpens == 1)
                if let failure { #expect((failure as? POSIXError)?.code == .ESTALE) }
            }
        }

        let parkedStatus = try? fileStatus(at: parked)
        #expect(parkedStatus?.st_dev == originalAncestorStatus.st_dev)
        #expect(parkedStatus?.st_ino == originalAncestorStatus.st_ino)
        let parkedOriginal = nestedInbox(under: parked).appendingPathComponent(originalURL.lastPathComponent)
        expectFixtureFileUnchanged(originalBytes, status: originalStatus, at: parkedOriginal)
        let currentDecoy: URL
        switch replacement {
        case .symbolicLink:
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: active.path)) == decoy.path)
            currentDecoy = decoy
        case .directory:
            currentDecoy = active
        }
        let currentDecoyStatus = try? fileStatus(at: currentDecoy)
        #expect(currentDecoyStatus?.st_dev == decoyAncestorStatus.st_dev)
        #expect(currentDecoyStatus?.st_ino == decoyAncestorStatus.st_ino)
        expectInboxFixtureUnchanged(decoyFiles, under: currentDecoy)
    }

    private func seedHealthyInbox(at directory: URL) throws -> OriginalBackgroundCompletion {
        let existing = event()
        let inbox = OriginalUploadEventInbox(directory: directory)
        try inbox.persist(existing)
        let saved = try inbox.events()
        try #require(saved == [existing])
        return existing
    }

    private func expectQuarantinedInboxIsBlocked(
        at directory: URL,
        existing: OriginalBackgroundCompletion,
        preserving files: [(URL, Data)],
        links: [(URL, String)] = [],
        absent: [URL] = [],
        targeting: OriginalBackgroundCompletion? = nil
    ) throws {
        let knownURL = canonicalURL(for: existing, in: directory)
        let knownBytes = try Data(contentsOf: knownURL)
        let scope = try #require(existing.tag?.scope)
        let newEvent = event(taskIdentifier: 99)
        let newURL = canonicalURL(for: newEvent, in: directory)

        func checkPreserved() {
            for (url, bytes) in [(knownURL, knownBytes)] + files {
                #expect((try? Data(contentsOf: url)) == bytes)
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                #expect(values?.isRegularFile == true)
                #expect(values?.isSymbolicLink != true)
            }
            for (url, destination) in links {
                #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == destination)
            }
            for url in absent + [newURL] {
                #expect(!itemExists(at: url))
            }
        }

        // Each call starts cold so a quarantine cached by a previous call cannot mask a bypass.
        checkPreserved()
        #expect(throws: (any Error).self) {
            _ = try OriginalUploadEventInbox(directory: directory).events()
        }
        checkPreserved()
        #expect(throws: (any Error).self) {
            _ = try OriginalUploadEventInbox(directory: directory).events(scope: scope)
        }
        checkPreserved()
        #expect(throws: (any Error).self) {
            _ = try OriginalUploadEventInbox(directory: directory)
                .events(scope: String(repeating: "b", count: 64))
        }
        checkPreserved()
        #expect(throws: (any Error).self) {
            _ = try OriginalUploadEventInbox(directory: directory).unidentifiedEvents()
        }
        checkPreserved()
        #expect(throws: (any Error).self) {
            try OriginalUploadEventInbox(directory: directory).persist(existing)
        }
        checkPreserved()
        #expect(throws: (any Error).self) {
            try OriginalUploadEventInbox(directory: directory).persist(newEvent)
        }
        checkPreserved()
        #expect(throws: (any Error).self) {
            try OriginalUploadEventInbox(directory: directory).remove(existing)
        }
        checkPreserved()
        #expect(throws: (any Error).self) {
            try OriginalUploadEventInbox(directory: directory).remove(newEvent)
        }
        checkPreserved()
        if let targeting {
            #expect(throws: (any Error).self) {
                try OriginalUploadEventInbox(directory: directory).persist(targeting)
            }
            checkPreserved()
            #expect(throws: (any Error).self) {
                try OriginalUploadEventInbox(directory: directory).remove(targeting)
            }
            checkPreserved()
        }
    }

    @Test
    func taskTagsContainOnlyValidatedNonsecretIdentity() throws {
        let tag = try #require(event().tag)
        #expect(OriginalBackgroundTaskTag(taskDescription: tag.taskDescription) == tag)
        for value in [
            "",
            "original-v3:\(tag.scope):\(tag.jobId):\(tag.jobIncarnation):\(tag.attemptId)",
            "original-v2:invalid:\(tag.jobId):\(tag.jobIncarnation):\(tag.attemptId)",
            "\(tag.taskDescription):extra",
            String(repeating: "x", count: 221),
        ] {
            #expect(OriginalBackgroundTaskTag(taskDescription: value) == nil)
        }
    }

    @Test
    func stableParseableNoncanonicalTaskAttachmentIsUnidentified() throws {
        let tag = try #require(event().tag)
        let rewritten = tag.taskDescription.lowercased()
        #expect(UUID(uuidString: tag.jobId.uuidString.lowercased()) == tag.jobId)
        #expect(OriginalBackgroundTaskTag(taskDescription: rewritten) == nil)

        let observations = [
            OriginalBackgroundTaskSnapshot(
                identifier: 17,
                tag: OriginalBackgroundTaskTag(taskDescription: rewritten),
                attachment: rewritten),
        ]
        try OriginalBackgroundTaskIndex.requireStableAttachments(observations, observations)
        let index = OriginalBackgroundTaskIndex(observations)
        #expect(index.hasUnidentifiedTasks)
        #expect(index.jobIDs.isEmpty && index.attemptIDs.isEmpty)
        #expect(index.cancellationTargets(
            scope: tag.scope, jobId: tag.jobId, incarnation: tag.jobIncarnation).isEmpty)

        // Even a caller-supplied parsed tag cannot override a non-canonical OS attachment.
        let mismatched = OriginalBackgroundTaskSnapshot(
            identifier: 18, tag: tag, attachment: rewritten)
        let mismatchedIndex = OriginalBackgroundTaskIndex([mismatched])
        #expect(mismatchedIndex.hasUnidentifiedTasks)
        #expect(mismatchedIndex.jobIDs.isEmpty && mismatchedIndex.attemptIDs.isEmpty)
    }

    @Test
    func inboxPersistsAndRemovesEventsIdempotently() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let inbox = OriginalUploadEventInbox(directory: inboxDirectory)
        let first = event()
        let second = event(taskIdentifier: 18)
        try inbox.persist(first)
        try inbox.persist(first)
        try inbox.persist(second)

        let recovered = OriginalUploadEventInbox(directory: inboxDirectory)
        #expect(try recovered.events() == [first, second])
        let data = try Data(contentsOf: inboxDirectory.appendingPathComponent("event-\(first.id).json"))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.lowercased().contains("token"))
        #expect(!text.lowercased().contains("signature"))
        #expect(!text.lowercased().contains("url"))

        try recovered.remove(first)
        try recovered.remove(first)
        #expect(try recovered.events() == [second])
    }

    @Test("An opened inventory ignores an ancestor replaced with an in-home symlink")
    func openedInventoryIgnoresSymlinkedAncestorSwap() throws {
        try exerciseAncestorSwap(.symbolicLink)
    }

    @Test("A different real ancestor is rejected at the pre-recovery checkpoint")
    func openedInventoryRejectsDifferentDirectoryAtRecoveryGate() throws {
        try exerciseAncestorSwap(.directory)
    }

    @Test("An opened inventory reads its original record despite a same-name decoy")
    func openedInventoryReadsOriginalBytesWithSameNameDecoy() throws {
        try exerciseAncestorSwap(.directory, sameNameConflict: true)
    }

    @Test("An opened inventory reads its original record after a same-name symlink swap")
    func openedInventoryReadsOriginalBytesWithSymlinkedSameNameDecoy() throws {
        try exerciseAncestorSwap(.symbolicLink, sameNameConflict: true)
    }

    @Test("Identical real inbox substitutions fail before later operations", arguments: [
        (InboxOperation.events, true), (.persist, true), (.remove, true),
        (.events, false), (.persist, false), (.remove, false),
    ])
    func identicalDirectorySwapRejectsEveryInboxOperation(
        operation: InboxOperation, hasCanonical: Bool
    ) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let swap = try makeInboxDirectorySwap(in: directory)
        let existing = event(taskIdentifier: 31)
        let newEvent = event(taskIdentifier: 32)
        try #require(existing.id != newEvent.id)
        let files: (original: FixtureFileSnapshot, decoy: FixtureFileSnapshot)?
        if hasCanonical {
            files = try seedIdenticalCanonicalCopies(existing, in: swap)
        } else {
            files = nil
        }

        var inventoryOpens = 0
        var swaps = 0
        var synchronizationsAfterSwap = 0
        let inbox = OriginalUploadEventInbox(
            directory: swap.active,
            synchronizeDirectory: { url in
                if swaps > 0 { synchronizationsAfterSwap += 1 }
                try DurableFile.synchronize(url, directory: true)
            },
            inventoryDidOpen: {
                inventoryOpens += 1
                guard inventoryOpens == 1 else { return }
                try self.swapInboxDirectories(swap)
                swaps += 1
            }
        )
        let failure = #expect(throws: (any Error).self) {
            switch operation {
            case .events:
                _ = try inbox.events()
            case .persist:
                try inbox.persist(newEvent)
            case .remove:
                try inbox.remove(existing)
            }
        }
        #expect((failure as? POSIXError)?.code == .ESTALE)
        try #require(swaps == 1)
        #expect(inventoryOpens == 1)
        #expect(synchronizationsAfterSwap == 0)
        try expectSwappedDirectoriesAndSentinelsUnchanged(swap)
        let names = files.map { [$0.original.url.lastPathComponent] } ?? []
        try expectInboxNames(names, in: swap.parked)
        try expectInboxNames(names, in: swap.active)
        if let files {
            expectFixtureFileUnchanged(
                files.original.bytes, status: files.original.status,
                at: swap.parked.appendingPathComponent(files.original.url.lastPathComponent))
            expectFixtureFileUnchanged(
                files.decoy.bytes, status: files.decoy.status,
                at: swap.active.appendingPathComponent(files.decoy.url.lastPathComponent))
        }
        #expect(!itemExists(at: canonicalURL(for: newEvent, in: swap.active)))
        #expect(!itemExists(at: canonicalURL(for: newEvent, in: swap.parked)))
    }

    @Test("Pre-recovery identity check prevents mutation through a newly external hard link")
    func preRecoveryGateRejectsExternalHardLinkDirectorySwap() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let swap = try makeInboxDirectorySwap(in: directory)
        let completion = event(taskIdentifier: 41)
        let stage = stagedURL(in: swap.active)
        let bytes = try recordBytes(completion, sequence: 1)
        _ = try createFixtureFile(bytes, at: stage)
        try TemporaryVideoStorage.applyProtection(to: stage)
        try OriginalUploadFiles.excludeFromBackup(stage)
        let initial = try snapshotFixtureFile(at: stage)
        try #require(initial.status.st_mode & mode_t(0o7777) == mode_t(0o600))
        try #require(initial.status.st_nlink == 1)
        let decoyStage = swap.decoy.appendingPathComponent(stage.lastPathComponent)

        var inventoryOpens = 0
        var completedScans = 0
        var revalidatedStages = 0
        var swaps = 0
        var synchronizationsAfterSwap = 0
        var afterLink: FixtureFileSnapshot?
        var protectionAfterLink: String?
        var backupExclusionAfterLink: Bool?
        let inbox = OriginalUploadEventInbox(
            directory: swap.active,
            synchronizeDirectory: { url in
                if swaps > 0 { synchronizationsAfterSwap += 1 }
                try DurableFile.synchronize(url, directory: true)
            },
            inventoryDidOpen: { inventoryOpens += 1 },
            initialInventoryDidScan: {
                completedScans += 1
                guard completedScans == 1 else { return }
                try FileManager.default.linkItem(at: stage, to: decoyStage)
                let linked = try self.snapshotFixtureFile(at: stage)
                try #require(linked.status.st_dev == initial.status.st_dev
                    && linked.status.st_ino == initial.status.st_ino)
                try #require(linked.status.st_nlink == 2)
                try #require(linked.bytes == bytes)
                let decoyLink = try self.fileStatus(at: decoyStage)
                try #require(decoyLink.st_dev == linked.status.st_dev && decoyLink.st_ino == linked.status.st_ino)
                try #require(decoyLink.st_nlink == 2)
                afterLink = linked
                let attributes = try FileManager.default.attributesOfItem(atPath: stage.path)
                protectionAfterLink = attributes[.protectionKey] as? String
                backupExclusionAfterLink = try stage.resourceValues(forKeys: [.isExcludedFromBackupKey])
                    .isExcludedFromBackup
                try self.swapInboxDirectories(swap)
                swaps += 1
            },
            stageDidRevalidate: { revalidatedStages += 1 }
        )
        let failure = #expect(throws: (any Error).self) { _ = try inbox.events() }
        #expect((failure as? POSIXError)?.code == .ESTALE)
        try #require(swaps == 1)
        #expect(inventoryOpens == 1 && completedScans == 1)
        #expect(revalidatedStages == 0 && synchronizationsAfterSwap == 0)
        let linked = try #require(afterLink)
        try expectSwappedDirectoriesAndSentinelsUnchanged(swap)
        try expectInboxNames([stage.lastPathComponent], in: swap.parked)
        try expectInboxNames([stage.lastPathComponent], in: swap.active)
        for parent in [swap.parked, swap.active] {
            let link = parent.appendingPathComponent(stage.lastPathComponent)
            expectFixtureFileUnchanged(linked.bytes, status: linked.status, at: link)
            let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
            #expect(attributes[.protectionKey] as? String == protectionAfterLink)
            #expect(try link.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
                == backupExclusionAfterLink)
        }
        #expect(!itemExists(at: canonicalURL(for: completion, in: swap.parked)))
        #expect(!itemExists(at: canonicalURL(for: completion, in: swap.active)))
    }

    @Test("Post-inventory external hard links cannot redirect staged recovery", arguments: [
        (ExternalLinkRecoveryLayout.publication, ExternalLinkInjectionPoint.afterInventory),
        (.publication, .afterStageRevalidation),
        (.stagedDuplicate, .afterInventory),
        (.stagedDuplicate, .afterStageRevalidation),
        (.stagedDuplicateWritableCanonical, .afterInventory),
        (.stagedDuplicateWritableCanonical, .afterStageRevalidation),
        (.canonicalDuplicate, .afterInventory),
        (.canonicalDuplicate, .afterStageRevalidation),
        (.writableCanonicalDuplicate, .afterInventory),
        (.writableCanonicalDuplicate, .afterStageRevalidation),
    ])
    func postInventoryExternalHardLinkFailsClosed(
        layout: ExternalLinkRecoveryLayout, injectionPoint: ExternalLinkInjectionPoint
    ) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        try requireFixtureInsideHome(directory)
        let inboxDirectory = directory.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: false)
        let directoryBefore = try fileStatus(at: inboxDirectory)
        try #require(directoryBefore.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))

        let completion = event(taskIdentifier: 42)
        let bytes = try recordBytes(completion, sequence: 1)
        let stage = stagedURL(in: inboxDirectory)
        let canonical = canonicalURL(for: completion, in: inboxDirectory)
        let sentinel = directory.appendingPathComponent("external-sentinel.json")
        try #require(sentinel.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        try #require(sentinel.deletingLastPathComponent().standardizedFileURL != inboxDirectory.standardizedFileURL)
        try #require(!itemExists(at: sentinel))

        let createdStage = try createFixtureFile(bytes, at: stage)
        try TemporaryVideoStorage.applyProtection(to: stage)
        try OriginalUploadFiles.excludeFromBackup(stage)
        let stageBefore = try snapshotFixtureFile(at: stage)
        try #require(stageBefore.status.st_dev == createdStage.status.st_dev
            && stageBefore.status.st_ino == createdStage.status.st_ino)
        try #require(stageBefore.status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        try #require(stageBefore.status.st_mode & mode_t(0o7777) == mode_t(0o600))
        try #require(stageBefore.status.st_nlink == 1 && stageBefore.bytes == bytes)

        let canonicalBefore: FixtureFileSnapshot?
        if layout == .publication {
            try #require(!itemExists(at: canonical))
            canonicalBefore = nil
        } else {
            try OriginalUploadFiles.writeProtected(bytes, to: canonical)
            let canonicalIsWritable = layout == .writableCanonicalDuplicate
                || layout == .stagedDuplicateWritableCanonical
            if canonicalIsWritable {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: canonical.path)
            }
            let saved = try snapshotFixtureFile(at: canonical)
            let expectedMode: mode_t = canonicalIsWritable ? 0o600 : 0o400
            try #require(saved.status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
            try #require(saved.status.st_mode & mode_t(0o7777) == expectedMode)
            try #require(saved.status.st_nlink == 1 && saved.bytes == bytes)
            try #require(saved.status.st_dev != stageBefore.status.st_dev
                || saved.status.st_ino != stageBefore.status.st_ino)
            canonicalBefore = saved
        }

        let target: FixtureFileSnapshot
        switch layout {
        case .publication, .stagedDuplicate, .stagedDuplicateWritableCanonical:
            target = stageBefore
        case .canonicalDuplicate, .writableCanonicalDuplicate:
            target = try #require(canonicalBefore)
        }

        var completedScans = 0
        var revalidatedStages = 0
        var injections = 0
        var afterLink: FixtureFileObservations?
        func addExternalLink() throws {
            try #require(injections == 0 && !self.itemExists(at: sentinel))
            let currentDirectory = try self.fileStatus(at: inboxDirectory)
            try #require(currentDirectory.st_dev == directoryBefore.st_dev
                && currentDirectory.st_ino == directoryBefore.st_ino)
            let current = try self.fileStatus(at: target.url)
            try #require(current.st_dev == target.status.st_dev && current.st_ino == target.status.st_ino)
            try #require(current.st_nlink == 1)
            try #require(current.st_mode == target.status.st_mode
                && current.st_uid == target.status.st_uid && current.st_gid == target.status.st_gid)
            try #require(current.st_size == target.status.st_size)
            try #require(current.st_mtimespec.tv_sec == target.status.st_mtimespec.tv_sec
                && current.st_mtimespec.tv_nsec == target.status.st_mtimespec.tv_nsec)
            try #require(current.st_ctimespec.tv_sec == target.status.st_ctimespec.tv_sec
                && current.st_ctimespec.tv_nsec == target.status.st_ctimespec.tv_nsec)
            try #require(try Data(contentsOf: target.url) == bytes)

            try FileManager.default.linkItem(at: target.url, to: sentinel)
            let linked = try self.snapshotFixtureFileObservations(at: sentinel)
            let targetAfterLink = try self.fileStatus(at: target.url)
            try #require(linked.file.status.st_dev == current.st_dev && linked.file.status.st_ino == current.st_ino)
            try #require(targetAfterLink.st_dev == current.st_dev && targetAfterLink.st_ino == current.st_ino)
            try #require(linked.file.status.st_nlink == 2 && targetAfterLink.st_nlink == 2)
            try #require(linked.file.bytes == bytes)
            afterLink = linked
            injections += 1
        }

        let inbox = OriginalUploadEventInbox(
            directory: inboxDirectory,
            initialInventoryDidScan: {
                completedScans += 1
                if injectionPoint == .afterInventory && completedScans == 1 {
                    try addExternalLink()
                }
            },
            stageDidRevalidate: {
                revalidatedStages += 1
                if injectionPoint == .afterStageRevalidation && revalidatedStages == 1 {
                    try addExternalLink()
                }
            }
        )
        let failure = #expect(throws: POSIXError.self) { _ = try inbox.events() }
        #expect(failure?.code == .ESTALE)
        try #require(injections == 1)
        #expect(completedScans == 1)
        if injectionPoint == .afterStageRevalidation {
            #expect(revalidatedStages == 1)
        }
        let linked = try #require(afterLink)

        #expect(itemExists(at: sentinel))
        if itemExists(at: sentinel) {
            try expectFixtureFileObservationsUnchanged(linked)
        }
        expectFixtureFileUnchanged(linked.file.bytes, status: linked.file.status, at: target.url)
        if target.url != stage {
            expectFixtureFileUnchanged(stageBefore.bytes, status: stageBefore.status, at: stage)
        }
        let directoryAfter = try fileStatus(at: inboxDirectory)
        #expect(directoryAfter.st_dev == directoryBefore.st_dev && directoryAfter.st_ino == directoryBefore.st_ino)
        let expectedNames = layout == .publication
            ? [stage.lastPathComponent] : [stage.lastPathComponent, canonical.lastPathComponent]
        try expectInboxNames(expectedNames, in: inboxDirectory)
        #expect(itemExists(at: stage))
        #expect(itemExists(at: canonical) == (layout != .publication))
        if target.url == stage, let saved = canonicalBefore {
            expectFixtureFileUnchanged(saved.bytes, status: saved.status, at: canonical)
        }
    }

    @Test("A substituted second inventory is rejected before scanning its malformed record")
    func secondInventoryRejectsReplacementBeforeScanningDecoy() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let swap = try makeInboxDirectorySwap(in: directory)
        let completion = event(taskIdentifier: 51)
        let originalURL = canonicalURL(for: completion, in: swap.active)
        let decoyURL = canonicalURL(for: completion, in: swap.decoy)
        let bytes = try recordBytes(completion, sequence: 1)
        try OriginalUploadFiles.writeProtected(bytes, to: originalURL)
        let original = try snapshotFixtureFile(at: originalURL)
        let decoy = try createFixtureFile(Data("{malformed".utf8), at: decoyURL)
        try #require(original.status.st_dev != decoy.status.st_dev || original.status.st_ino != decoy.status.st_ino)

        var inventoryOpens = 0
        var preflights = 0
        var swaps = 0
        let inbox = OriginalUploadEventInbox(
            directory: swap.active,
            inventoryDidOpen: { inventoryOpens += 1 },
            recoveryPreflightDidComplete: {
                preflights += 1
                guard preflights == 1 else { return }
                try self.swapInboxDirectories(swap)
                swaps += 1
            }
        )
        let failure = #expect(throws: (any Error).self) { _ = try inbox.events() }
        #expect((failure as? POSIXError)?.code == .ESTALE)
        try #require(swaps == 1)
        #expect(preflights == 1 && inventoryOpens == 1)
        try expectSwappedDirectoriesAndSentinelsUnchanged(swap)
        try expectInboxNames([originalURL.lastPathComponent], in: swap.parked)
        try expectInboxNames([decoyURL.lastPathComponent], in: swap.active)
        expectFixtureFileUnchanged(
            original.bytes, status: original.status,
            at: swap.parked.appendingPathComponent(originalURL.lastPathComponent))
        expectFixtureFileUnchanged(
            decoy.bytes, status: decoy.status,
            at: swap.active.appendingPathComponent(decoyURL.lastPathComponent))
    }

    @Test("A real identical inbox substituted after the second descriptor opens is rejected")
    func finalCheckpointRejectsSwapAfterSecondInventoryOpens() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let swap = try makeInboxDirectorySwap(in: directory)
        let completion = event(taskIdentifier: 61)
        let files = try seedIdenticalCanonicalCopies(completion, in: swap)
        var inventoryOpens = 0
        var swaps = 0
        let inbox = OriginalUploadEventInbox(directory: swap.active, inventoryDidOpen: {
            inventoryOpens += 1
            guard inventoryOpens == 2 else { return }
            try self.swapInboxDirectories(swap)
            swaps += 1
        })
        let failure = #expect(throws: (any Error).self) { _ = try inbox.events() }
        #expect((failure as? POSIXError)?.code == .ESTALE)
        try #require(swaps == 1)
        #expect(inventoryOpens == 2)
        try expectSwappedDirectoriesAndSentinelsUnchanged(swap)
        try expectInboxNames([files.original.url.lastPathComponent], in: swap.parked)
        try expectInboxNames([files.decoy.url.lastPathComponent], in: swap.active)
        expectFixtureFileUnchanged(
            files.original.bytes, status: files.original.status,
            at: swap.parked.appendingPathComponent(files.original.url.lastPathComponent))
        expectFixtureFileUnchanged(
            files.decoy.bytes, status: files.decoy.status,
            at: swap.active.appendingPathComponent(files.decoy.url.lastPathComponent))
    }

    @Test("Stage revalidation reads the pinned inbox rather than a malformed path decoy")
    func stageRereadUsesPinnedDirectoryAfterPreflightSwap() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let swap = try makeInboxDirectorySwap(in: directory)
        let completion = event(taskIdentifier: 71)
        let stage = stagedURL(in: swap.active)
        let bytes = try recordBytes(completion, sequence: 1)
        let original = try createFixtureFile(bytes, at: stage)
        let decoyURL = swap.decoy.appendingPathComponent(stage.lastPathComponent)
        let decoy = try createFixtureFile(Data("{malformed".utf8), at: decoyURL)
        try #require(original.url.lastPathComponent == decoy.url.lastPathComponent)
        try #require(original.bytes != decoy.bytes)
        try #require(original.status.st_dev != decoy.status.st_dev || original.status.st_ino != decoy.status.st_ino)
        try #require(original.status.st_nlink == 1 && decoy.status.st_nlink == 1)

        var inventoryOpens = 0
        var preflights = 0
        var revalidatedStages = 0
        var swaps = 0
        let inbox = OriginalUploadEventInbox(
            directory: swap.active,
            inventoryDidOpen: { inventoryOpens += 1 },
            recoveryPreflightDidComplete: {
                preflights += 1
                guard preflights == 1 else { return }
                try self.swapInboxDirectories(swap)
                swaps += 1
            },
            stageDidRevalidate: { revalidatedStages += 1 }
        )
        let failure = #expect(throws: (any Error).self) { _ = try inbox.events() }
        // A path-relative stage reread would decode the malformed decoy as invalidRecord.
        // The pinned reread succeeds; the subsequent path identity comparison fails.
        #expect((failure as? POSIXError)?.code == .ESTALE)
        try #require(swaps == 1)
        #expect(preflights == 1 && inventoryOpens == 1 && revalidatedStages == 1)
        try expectSwappedDirectoriesAndSentinelsUnchanged(swap)
        try expectInboxNames([stage.lastPathComponent], in: swap.parked)
        try expectInboxNames([stage.lastPathComponent], in: swap.active)
        expectFixtureFileUnchanged(
            original.bytes, status: original.status,
            at: swap.parked.appendingPathComponent(stage.lastPathComponent))
        expectFixtureFileUnchanged(
            decoy.bytes, status: decoy.status,
            at: swap.active.appendingPathComponent(stage.lastPathComponent))
        #expect(!itemExists(at: canonicalURL(for: completion, in: swap.parked)))
        #expect(!itemExists(at: canonicalURL(for: completion, in: swap.active)))
    }

    @Test("A pre-existing in-home symlink ancestor cannot open an inventory")
    func inventoryRejectsExistingInHomeSymlinkAncestor() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        try requireFixtureInsideHome(directory)
        let decoy = directory.appendingPathComponent("decoy", isDirectory: false)
        let files = try seedInboxWithStage(under: decoy, canonical: event(taskIdentifier: 91))
        let link = directory.appendingPathComponent("linked-ancestor", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: decoy.path)
        defer {
            do {
                try removeFixtureLink(link)
            } catch {
                Issue.record("Could not remove the fixture ancestor link: \(Log.describe(error))")
            }
        }
        let resolvedRoot = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedTarget = link.resolvingSymlinksInPath().standardizedFileURL.path
        try #require(resolvedTarget.hasPrefix(resolvedRoot + "/"))
        try #require(resolvedTarget == decoy.resolvingSymlinksInPath().standardizedFileURL.path)

        var inventoryOpens = 0
        let inbox = OriginalUploadEventInbox(directory: nestedInbox(under: link), inventoryDidOpen: {
            inventoryOpens += 1
        })
        // Preparation is still path-based and may touch the target directory;
        // this checks rejection and file preservation, not hardened preparation.
        let failure = #expect(throws: (any Error).self) { _ = try inbox.events() }
        #expect(inventoryOpens == 0)
        if let failure { #expect(isUnsafeAncestorRejection(failure)) }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == decoy.path)
        expectInboxFixtureUnchanged(files, under: decoy)
    }

    @Test("Trusted home aliases are verified and matched by whole components")
    func inventoryAcceptsVerifiedTrustedHomeAliases() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let alias = directory.appendingPathComponent("home-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: home.path)
        let status = try fileStatus(at: home)
        let canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL
        let canonicalInbox = canonicalHome.appendingPathComponent("nested/inbox", isDirectory: true)
        let aliasInbox = alias.appendingPathComponent("nested/inbox", isDirectory: true)

        #expect(try OriginalUploadEventInbox(directory: canonicalInbox)
            .inventoryComponents(under: alias.path, matching: status) == ["nested", "inbox"])
        #expect(try OriginalUploadEventInbox(directory: aliasInbox)
            .inventoryComponents(under: alias.path, matching: status) == ["nested", "inbox"])

        let sibling = directory.appendingPathComponent("home-alias-other/nested/inbox", isDirectory: true)
        #expect(throws: OriginalUploadStorageError.invalidScope) {
            try OriginalUploadEventInbox(directory: sibling)
                .inventoryComponents(under: alias.path, matching: status)
        }
    }

    @Test("The most specific matching trusted home alias is verified")
    func inventoryUsesLongestMatchingTrustedHomeAlias() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let alias = home.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: home.path)
        let homeStatus = try fileStatus(at: home)
        let homeComponents = home.path.split(separator: "/").map(String.init)
        let aliasComponents = alias.path.split(separator: "/").map(String.init)
        let inbox = OriginalUploadEventInbox(directory: alias.appendingPathComponent("inbox"))

        #expect(try inbox.inventoryComponents(
            matching: [homeComponents, aliasComponents], homeStatus: homeStatus) == ["inbox"])

        let decoy = home.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        let decoyComponents = decoy.path.split(separator: "/").map(String.init)
        let decoyInbox = OriginalUploadEventInbox(directory: decoy.appendingPathComponent("inbox"))
        let failure = #expect(throws: POSIXError.self) {
            try decoyInbox.inventoryComponents(
                matching: [homeComponents, decoyComponents], homeStatus: homeStatus)
        }
        #expect(failure?.code == .ESTALE)
    }

    @Test("A replaced trusted home alias cannot redirect an inventory")
    func inventoryRejectsReplacedTrustedHomeAlias() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let parked = directory.appendingPathComponent("parked", isDirectory: true)
        let decoy = directory.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        let sentinel = decoy.appendingPathComponent("sentinel")
        let bytes = Data("untouched home alias sentinel".utf8)
        try bytes.write(to: sentinel)
        let sentinelStatus = try fileStatus(at: sentinel)
        let descriptor = home.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        try #require(descriptor >= 0)
        defer { #expect(Darwin.close(descriptor) == 0) }
        var homeStatus = stat()
        try #require(Darwin.fstat(descriptor, &homeStatus) == 0)

        let inbox = OriginalUploadEventInbox(directory: home.appendingPathComponent("nested/inbox"))
        try FileManager.default.moveItem(at: home, to: parked)
        try FileManager.default.createSymbolicLink(atPath: home.path, withDestinationPath: decoy.path)
        defer {
            do {
                try removeFixtureLink(home)
                try FileManager.default.moveItem(at: parked, to: home)
            } catch {
                Issue.record("Could not restore the trusted home fixture: \(Log.describe(error))")
            }
        }
        let failure = #expect(throws: POSIXError.self) {
            try inbox.inventoryComponents(under: home.path, matching: homeStatus)
        }
        #expect(failure?.code == .ESTALE)
        expectFixtureFileUnchanged(bytes, status: sentinelStatus, at: sentinel)
    }

    @Test(
        "The real /var and /private/var app-home aliases share an inbox",
        .enabled(
            if: OriginalUploadBackgroundTransportTests.hasRealVarAliasInAppHome(),
            "Requires the real /var alias for app home and temp; otherwise device coverage is needed")
    )
    func realSystemVarAliasesReadAndRecoverSameInbox() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        try requireFixtureInsideHome(directory)
        let ancestor = directory.appendingPathComponent("alias-fixture", isDirectory: true)
        let files = try seedInboxWithStage(under: ancestor, canonical: event(taskIdentifier: 91))
        let paths = try #require(Self.varAliasPaths(for: nestedInbox(under: ancestor).standardizedFileURL.path))
        let viaVar = URL(fileURLWithPath: paths.varPath, isDirectory: true)
        let viaPrivateVar = URL(fileURLWithPath: paths.privatePath, isDirectory: true)
        try #require(viaVar.path.hasPrefix("/var/") && viaPrivateVar.path.hasPrefix("/private/var/"))
        let varInboxStatus = try fileStatus(at: viaVar)
        let privateInboxStatus = try fileStatus(at: viaPrivateVar)
        try #require(varInboxStatus.st_dev == privateInboxStatus.st_dev
            && varInboxStatus.st_ino == privateInboxStatus.st_ino)
        let varStage = viaVar.appendingPathComponent(files.stage.lastPathComponent)
        let privateStage = viaPrivateVar.appendingPathComponent(files.stage.lastPathComponent)
        let varStageStatus = try fileStatus(at: varStage)
        let privateStageStatus = try fileStatus(at: privateStage)
        try #require(varStageStatus.st_dev == files.stageStatus.st_dev
            && varStageStatus.st_ino == files.stageStatus.st_ino)
        try #require(privateStageStatus.st_dev == files.stageStatus.st_dev
            && privateStageStatus.st_ino == files.stageStatus.st_ino)

        // The namespace is stable: recovery remains path-based, and this checks
        // ordinary compatibility with the actual system aliases, not swap safety.
        var varOpens = 0
        let varEvents = try OriginalUploadEventInbox(directory: viaVar, inventoryDidOpen: {
            varOpens += 1
        }).events()
        #expect(varEvents == [files.canonicalEvent, files.stagedEvent])
        #expect(varOpens == 2)
        #expect(!itemExists(at: varStage))
        #expect(!itemExists(at: privateStage))
        let varPublished = canonicalURL(for: files.stagedEvent, in: viaVar)
        let privatePublished = canonicalURL(for: files.stagedEvent, in: viaPrivateVar)
        let varPublishedStatus = try fileStatus(at: varPublished)
        let privatePublishedStatus = try fileStatus(at: privatePublished)
        #expect(varPublishedStatus.st_dev == files.stageStatus.st_dev
            && varPublishedStatus.st_ino == files.stageStatus.st_ino)
        #expect(privatePublishedStatus.st_dev == varPublishedStatus.st_dev
            && privatePublishedStatus.st_ino == varPublishedStatus.st_ino)
        #expect(varPublishedStatus.st_mode & mode_t(0o7777) == mode_t(0o400))
        #expect((try? Data(contentsOf: varPublished)) == files.stageBytes)
        #expect((try? Data(contentsOf: privatePublished)) == files.stageBytes)

        var privateOpens = 0
        let privateEvents = try OriginalUploadEventInbox(directory: viaPrivateVar, inventoryDidOpen: {
            privateOpens += 1
        }).events()
        #expect(privateEvents == [files.canonicalEvent, files.stagedEvent])
        #expect(privateOpens == 2)
        expectFixtureFileUnchanged(
            files.canonicalBytes, status: files.canonicalStatus,
            at: viaPrivateVar.appendingPathComponent(files.canonical.lastPathComponent))
        let sentinel = nestedInbox(under: ancestor).deletingLastPathComponent()
            .appendingPathComponent("sibling-sentinel.txt")
        expectFixtureFileUnchanged(files.sentinelBytes, status: files.sentinelStatus, at: sentinel)
    }

    @Test("Staged crash remnants recover in sequence order and remain idempotent")
    func stagedEventsRecoverInOrderAcrossInboxInstances() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let first = event(id: try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111")))
        let second = event(
            id: try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222")), taskIdentifier: 18)
        let third = event(
            id: try #require(UUID(uuidString: "33333333-3333-4333-8333-333333333333")), taskIdentifier: 19)
        let original = OriginalUploadEventInbox(directory: inboxDirectory)
        try original.persist(first)
        try original.persist(second)
        try original.persist(third)

        // Both the staged names and their creation order oppose their event sequence.
        let firstStage = stagedURL(
            in: inboxDirectory, nonce: try #require(UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")))
        let thirdStage = stagedURL(
            in: inboxDirectory, nonce: try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000000")))
        try FileManager.default.moveItem(at: canonicalURL(for: third, in: inboxDirectory), to: thirdStage)
        try FileManager.default.moveItem(at: canonicalURL(for: first, in: inboxDirectory), to: firstStage)

        let recovered = OriginalUploadEventInbox(directory: inboxDirectory)
        #expect(try recovered.events() == [first, second, third])
        #expect(!itemExists(at: firstStage))
        #expect(!itemExists(at: thirdStage))
        #expect(itemExists(at: canonicalURL(for: first, in: inboxDirectory)))
        #expect(itemExists(at: canonicalURL(for: third, in: inboxDirectory)))
        try recovered.persist(first)
        #expect(try recovered.events() == [first, second, third])

        let reopened = OriginalUploadEventInbox(directory: inboxDirectory)
        #expect(try reopened.events() == [first, second, third])
        try reopened.remove(first)
        try reopened.remove(first)
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events() == [second, third])
    }

    @Test("A complete 0600 stage recovers unchanged and is sealed")
    func completeWritableStageRecoversAndSeals() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let earlier = try seedHealthyInbox(at: inboxDirectory)
        let completion = event(taskIdentifier: 18)
        let sequence: UInt64 = 37
        let bytes = try recordBytes(completion, sequence: sequence)
        let staged = stagedURL(in: inboxDirectory)
        let canonical = canonicalURL(for: completion, in: inboxDirectory)

        // Model a complete write interrupted before the writer's final chmod.
        let created = FileManager.default.createFile(
            atPath: staged.path, contents: bytes, attributes: [.posixPermissions: 0o600])
        try #require(created)
        try TemporaryVideoStorage.applyProtection(to: staged)
        try OriginalUploadFiles.excludeFromBackup(staged)
        let before = try fileStatus(at: staged)
        try #require(before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        try #require(before.st_mode & mode_t(0o7777) == mode_t(0o600))
        try #require(try Data(contentsOf: staged) == bytes)
        try #require(!itemExists(at: canonical))

        // With no namespace swap, existing path-based recovery runs between the scans.
        var inventoryOpens = 0
        let recovered = try OriginalUploadEventInbox(directory: inboxDirectory, inventoryDidOpen: {
            inventoryOpens += 1
        }).events()
        #expect(recovered == [earlier, completion])
        #expect(inventoryOpens == 2)
        #expect(!itemExists(at: staged))
        let after = try fileStatus(at: canonical)
        try #require(after.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        #expect(after.st_mode & mode_t(0o7777) == mode_t(0o400))
        let recoveredBytes = try Data(contentsOf: canonical)
        #expect(recoveredBytes == bytes)
        let record = try JSONDecoder().decode(StoredEventFixture.self, from: recoveredBytes)
        #expect(record.sequence == sequence)
        #expect(record.event == completion)
    }

    @Test("Removing a staged event cannot resurrect it on reopening")
    func removingAStagedEventConsumesItsCrashRemnant() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let first = event()
        let second = event(taskIdentifier: 18)
        let original = OriginalUploadEventInbox(directory: inboxDirectory)
        try original.persist(first)
        try original.persist(second)
        let canonical = canonicalURL(for: first, in: inboxDirectory)
        let staged = stagedURL(in: inboxDirectory)
        try FileManager.default.moveItem(at: canonical, to: staged)

        try OriginalUploadEventInbox(directory: inboxDirectory).remove(first)
        #expect(!itemExists(at: staged))
        #expect(!itemExists(at: canonical))
        let reopened = OriginalUploadEventInbox(directory: inboxDirectory)
        #expect(try reopened.events() == [second])
        try reopened.remove(first)
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events() == [second])
    }

    @Test("Identical canonical and staged records deduplicate")
    func identicalCrashRemnantsDeduplicate() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let first = event()
        let second = event(taskIdentifier: 18)
        let original = OriginalUploadEventInbox(directory: inboxDirectory)
        try original.persist(first)
        try original.persist(second)

        let firstCanonical = canonicalURL(for: first, in: inboxDirectory)
        let secondCanonical = canonicalURL(for: second, in: inboxDirectory)
        let firstStage = stagedURL(in: inboxDirectory)
        let firstDuplicate = stagedURL(in: inboxDirectory)
        let secondStage = stagedURL(in: inboxDirectory)
        let secondDuplicate = stagedURL(in: inboxDirectory)
        try FileManager.default.copyItem(at: firstCanonical, to: firstStage)
        try FileManager.default.copyItem(at: firstCanonical, to: firstDuplicate)
        try FileManager.default.moveItem(at: secondCanonical, to: secondStage)
        try FileManager.default.copyItem(at: secondStage, to: secondDuplicate)

        let recovered = OriginalUploadEventInbox(directory: inboxDirectory)
        #expect(try recovered.events() == [first, second])
        for stage in [firstStage, firstDuplicate, secondStage, secondDuplicate] {
            #expect(!itemExists(at: stage))
        }
        #expect(itemExists(at: firstCanonical))
        #expect(itemExists(at: secondCanonical))
        try recovered.persist(first)
        try recovered.persist(second)
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events() == [first, second])
    }

    @Test("A hard-linked stage deduplicates without losing its canonical event")
    func hardLinkedCanonicalAndStageDeduplicate() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let first = event()
        let second = event(taskIdentifier: 18)
        let inbox = OriginalUploadEventInbox(directory: inboxDirectory)
        try inbox.persist(first)
        try inbox.persist(second)

        let canonical = canonicalURL(for: first, in: inboxDirectory)
        let staged = stagedURL(in: inboxDirectory)
        let bytes = try Data(contentsOf: canonical)
        try FileManager.default.linkItem(at: canonical, to: staged)
        let canonicalBefore = try fileStatus(at: canonical)
        let stagedBefore = try fileStatus(at: staged)
        try #require(canonicalBefore.st_dev == stagedBefore.st_dev)
        try #require(canonicalBefore.st_ino == stagedBefore.st_ino)
        try #require(canonicalBefore.st_nlink == 2 && stagedBefore.st_nlink == 2)

        let recovered = OriginalUploadEventInbox(directory: inboxDirectory)
        #expect(try recovered.events() == [first, second])
        #expect(!itemExists(at: staged))
        #expect((try? Data(contentsOf: canonical)) == bytes)
        let canonicalAfter = try fileStatus(at: canonical)
        #expect(canonicalAfter.st_dev == canonicalBefore.st_dev)
        #expect(canonicalAfter.st_ino == canonicalBefore.st_ino)
        #expect(canonicalAfter.st_mode == canonicalBefore.st_mode)
        #expect(canonicalAfter.st_nlink == 1)
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events() == [first, second])

        try recovered.remove(first)
        #expect(!itemExists(at: canonical))
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events() == [second])
    }

    @Test("Hard-linked sibling stages refresh after the first duplicate is removed")
    func hardLinkedSiblingStagesRefreshAfterDeduplication() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        try requireFixtureInsideHome(directory)
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let completion = event(taskIdentifier: 81)
        try OriginalUploadEventInbox(directory: inboxDirectory).persist(completion)
        let canonical = canonicalURL(for: completion, in: inboxDirectory)
        let first = stagedURL(in: inboxDirectory)
        let second = stagedURL(in: inboxDirectory)
        try #require(first != second)
        try FileManager.default.linkItem(at: canonical, to: first)
        try FileManager.default.linkItem(at: canonical, to: second)
        let before = try snapshotFixtureFile(at: canonical)
        try #require(before.status.st_nlink == 3)
        let firstStatus = try fileStatus(at: first)
        let secondStatus = try fileStatus(at: second)
        try #require(firstStatus.st_dev == before.status.st_dev && firstStatus.st_ino == before.status.st_ino)
        try #require(secondStatus.st_dev == before.status.st_dev && secondStatus.st_ino == before.status.st_ino)

        var inventoryOpens = 0
        var revalidatedStages = 0
        let recovered = try OriginalUploadEventInbox(
            directory: inboxDirectory,
            inventoryDidOpen: { inventoryOpens += 1 },
            stageDidRevalidate: { revalidatedStages += 1 }
        ).events()
        #expect(recovered == [completion])
        #expect(inventoryOpens == 2 && revalidatedStages == 2)
        #expect(!itemExists(at: first) && !itemExists(at: second))
        let after = try fileStatus(at: canonical)
        #expect(after.st_dev == before.status.st_dev && after.st_ino == before.status.st_ino)
        #expect(after.st_mode & mode_t(0o7777) == mode_t(0o400))
        #expect(after.st_nlink == 1)
        #expect((try? Data(contentsOf: canonical)) == before.bytes)
    }

    @Test("Hard-linked staged siblings recover with or without a distinct canonical", arguments: [false, true])
    func hardLinkedStagedSiblingsRecover(canonicalExists: Bool) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        try requireFixtureInsideHome(directory)
        let inboxDirectory = directory.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: false)
        let completion = event(taskIdentifier: 82)
        let bytes = try recordBytes(completion, sequence: 1)
        let canonical = canonicalURL(for: completion, in: inboxDirectory)

        let canonicalBefore: FixtureFileSnapshot?
        if canonicalExists {
            try OriginalUploadFiles.writeProtected(bytes, to: canonical)
            let saved = try snapshotFixtureFile(at: canonical)
            try #require(saved.status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
            try #require(saved.status.st_mode & mode_t(0o7777) == mode_t(0o400))
            try #require(saved.status.st_nlink == 1 && saved.bytes == bytes)
            canonicalBefore = saved
        } else {
            try #require(!itemExists(at: canonical))
            canonicalBefore = nil
        }
        let stages = try createHardLinkedSiblingStages(bytes, in: inboxDirectory)
        if let saved = canonicalBefore {
            try #require(saved.status.st_dev != stages.first.status.st_dev
                || saved.status.st_ino != stages.first.status.st_ino)
        } else {
            try #require(!itemExists(at: canonical))
        }

        var inventoryOpens = 0
        var revalidatedStages = 0
        let recovered = try OriginalUploadEventInbox(
            directory: inboxDirectory,
            inventoryDidOpen: { inventoryOpens += 1 },
            stageDidRevalidate: { revalidatedStages += 1 }
        ).events()
        #expect(recovered == [completion])
        #expect(inventoryOpens == 2 && revalidatedStages == 2)
        #expect(!itemExists(at: stages.first.url) && !itemExists(at: stages.second.url))
        try expectInboxNames([canonical.lastPathComponent], in: inboxDirectory)

        let expectedIdentity = canonicalBefore?.status ?? stages.first.status
        let after = try fileStatus(at: canonical)
        #expect(after.st_dev == expectedIdentity.st_dev && after.st_ino == expectedIdentity.st_ino)
        #expect(after.st_mode & mode_t(0o7777) == mode_t(0o400))
        #expect(after.st_nlink == 1)
        #expect((try? Data(contentsOf: canonical)) == bytes)
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events() == [completion])
    }

    @Test("An external link after a sibling unlink is not an expected link-count refresh")
    func externalHardLinkAfterOwnSiblingUnlinkFailsClosed() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        try requireFixtureInsideHome(directory)
        let inboxDirectory = directory.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: false)
        let directoryBefore = try fileStatus(at: inboxDirectory)
        try #require(directoryBefore.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
        let resolvedInbox = inboxDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let completion = event(taskIdentifier: 83)
        let bytes = try recordBytes(completion, sequence: 1)
        let canonical = canonicalURL(for: completion, in: inboxDirectory)
        let sentinel = directory.appendingPathComponent("external-sentinel.json")
        try #require(sentinel.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        try #require(sentinel.deletingLastPathComponent().standardizedFileURL != inboxDirectory.standardizedFileURL)
        try #require(!itemExists(at: sentinel))

        try OriginalUploadFiles.writeProtected(bytes, to: canonical)
        let canonicalBefore = try snapshotFixtureFile(at: canonical)
        try #require(canonicalBefore.status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        try #require(canonicalBefore.status.st_mode & mode_t(0o7777) == mode_t(0o400))
        try #require(canonicalBefore.status.st_nlink == 1 && canonicalBefore.bytes == bytes)
        let stages = try createHardLinkedSiblingStages(bytes, in: inboxDirectory)
        let first = stages.first.url
        let second = stages.second.url
        try #require(canonicalBefore.status.st_dev != stages.first.status.st_dev
            || canonicalBefore.status.st_ino != stages.first.status.st_ino)

        var completedScans = 0
        var revalidatedStages = 0
        var injections = 0
        var afterOwnUnlink: FixtureFileSnapshot?
        var afterLink: FixtureFileObservations?
        let inbox = OriginalUploadEventInbox(
            directory: inboxDirectory,
            synchronizeDirectory: { url in
                try DurableFile.synchronize(url, directory: true)
                guard url.resolvingSymlinksInPath().standardizedFileURL.path == resolvedInbox,
                      injections == 0, !self.itemExists(at: first) else { return }

                // This hook runs only once the real first unlink is visible and synced.
                try #require(completedScans == 1 && revalidatedStages >= 1)
                try #require(self.itemExists(at: second) && !self.itemExists(at: sentinel))
                let currentDirectory = try self.fileStatus(at: inboxDirectory)
                try #require(currentDirectory.st_dev == directoryBefore.st_dev
                    && currentDirectory.st_ino == directoryBefore.st_ino)
                let currentCanonical = try self.fileStatus(at: canonical)
                try #require(currentCanonical.st_dev == canonicalBefore.status.st_dev
                    && currentCanonical.st_ino == canonicalBefore.status.st_ino
                    && currentCanonical.st_nlink == 1)
                let remaining = try self.snapshotFixtureFile(at: second)
                try #require(remaining.status.st_dev == stages.second.status.st_dev
                    && remaining.status.st_ino == stages.second.status.st_ino)
                try #require(remaining.status.st_nlink == 1)
                try #require(remaining.status.st_mode == stages.second.status.st_mode
                    && remaining.status.st_uid == stages.second.status.st_uid
                    && remaining.status.st_gid == stages.second.status.st_gid)
                try #require(remaining.status.st_size == stages.second.status.st_size)
                try #require(remaining.status.st_mtimespec.tv_sec == stages.second.status.st_mtimespec.tv_sec
                    && remaining.status.st_mtimespec.tv_nsec == stages.second.status.st_mtimespec.tv_nsec)
                try #require(remaining.bytes == bytes)

                try FileManager.default.linkItem(at: second, to: sentinel)
                let linked = try self.snapshotFixtureFileObservations(at: sentinel)
                let secondAfterLink = try self.fileStatus(at: second)
                try #require(linked.file.status.st_dev == remaining.status.st_dev
                    && linked.file.status.st_ino == remaining.status.st_ino)
                try #require(secondAfterLink.st_dev == remaining.status.st_dev
                    && secondAfterLink.st_ino == remaining.status.st_ino)
                // The attack restores the original inventory count, not the expected decremented count.
                try #require(linked.file.status.st_nlink == stages.second.status.st_nlink
                    && linked.file.status.st_nlink == 2 && secondAfterLink.st_nlink == 2)
                try #require(linked.file.bytes == bytes)
                afterOwnUnlink = remaining
                afterLink = linked
                injections += 1
            },
            initialInventoryDidScan: { completedScans += 1 },
            stageDidRevalidate: { revalidatedStages += 1 }
        )
        let failure = #expect(throws: POSIXError.self) { _ = try inbox.events() }
        #expect(failure?.code == .ESTALE)
        try #require(injections == 1)
        let afterUnlink = try #require(afterOwnUnlink)
        let linked = try #require(afterLink)
        #expect(afterUnlink.status.st_nlink == 1)
        #expect(linked.file.status.st_nlink == stages.second.status.st_nlink)
        #expect(completedScans == 1 && revalidatedStages >= 1)
        #expect(!itemExists(at: first))
        #expect(itemExists(at: second) && itemExists(at: canonical))
        #expect(itemExists(at: sentinel))

        if itemExists(at: sentinel) {
            try expectFixtureFileObservationsUnchanged(linked)
        }
        expectFixtureFileUnchanged(linked.file.bytes, status: linked.file.status, at: second)
        let directoryAfter = try fileStatus(at: inboxDirectory)
        #expect(directoryAfter.st_dev == directoryBefore.st_dev && directoryAfter.st_ino == directoryBefore.st_ino)
        try expectInboxNames([canonical.lastPathComponent, second.lastPathComponent], in: inboxDirectory)
        let canonicalAfter = try fileStatus(at: canonical)
        #expect(canonicalAfter.st_dev == canonicalBefore.status.st_dev
            && canonicalAfter.st_ino == canonicalBefore.status.st_ino)
        #expect(canonicalAfter.st_mode & mode_t(0o7777) == mode_t(0o400))
        #expect(canonicalAfter.st_nlink == 1)
        #expect((try? Data(contentsOf: canonical)) == bytes)
    }

    @Test("A recovered sequence participates in the next sequence assignment")
    func persistingWhileRecoveringUsesTheRecoveredSequence() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let first = event()
        try OriginalUploadEventInbox(directory: inboxDirectory).persist(first)
        let recovered = event(taskIdentifier: 18)
        let staged = stagedURL(in: inboxDirectory)
        let recoveredBytes = try recordBytes(recovered, sequence: 37)
        try OriginalUploadFiles.writeProtected(recoveredBytes, to: staged)

        let next = event(taskIdentifier: 19)
        try OriginalUploadEventInbox(directory: inboxDirectory).persist(next)
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events() == [first, recovered, next])
        #expect(!itemExists(at: staged))
        #expect(itemExists(at: canonicalURL(for: recovered, in: inboxDirectory)))
        let nextCanonical = canonicalURL(for: next, in: inboxDirectory)
        let nextBytes = try Data(contentsOf: nextCanonical)

        // A different event at 38 must collide with the newly assigned sequence.
        let probe = event(taskIdentifier: 20)
        let probeStage = stagedURL(in: inboxDirectory)
        let probeBytes = try recordBytes(probe, sequence: 38)
        try OriginalUploadFiles.writeProtected(probeBytes, to: probeStage)
        #expect(throws: (any Error).self) {
            _ = try OriginalUploadEventInbox(directory: inboxDirectory).events()
        }
        #expect((try? Data(contentsOf: probeStage)) == probeBytes)
        #expect(!itemExists(at: canonicalURL(for: probe, in: inboxDirectory)))
        #expect((try? Data(contentsOf: nextCanonical)) == nextBytes)
    }

    @Test("Damaged event records stay in place and block every inbox API", arguments: [
        (EventDamage.empty, EventLocation.staged),
        (.partial, .staged),
        (.corrupt, .staged),
        (.invalidSequence, .staged),
        (.invalidCompletion, .staged),
        (.partial, .canonical),
        (.corrupt, .canonical),
        (.invalidCompletion, .canonical),
        (.wrongCanonicalID, .canonical),
    ])
    func damagedEventRecordsRemainQuarantined(damage: EventDamage, location: EventLocation) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let existing = try seedHealthyInbox(at: inboxDirectory)
        let suspect = event(taskIdentifier: 18)
        let bytes: Data
        switch damage {
        case .empty:
            bytes = Data()
        case .partial:
            bytes = Data(try recordBytes(suspect, sequence: 10).dropLast())
        case .corrupt:
            bytes = Data("not a JSON event".utf8)
        case .invalidSequence:
            bytes = try recordBytes(suspect, sequence: 0)
        case .invalidCompletion:
            let invalid = OriginalBackgroundCompletion(
                id: suspect.id, taskIdentifier: 0, tag: suspect.tag,
                httpStatus: suspect.httpStatus, transportErrorCode: suspect.transportErrorCode)
            bytes = try recordBytes(invalid, sequence: 10)
        case .wrongCanonicalID:
            bytes = try recordBytes(event(taskIdentifier: 20), sequence: 10)
        }
        let canonical = canonicalURL(for: suspect, in: inboxDirectory)
        let damaged = location == .staged ? stagedURL(in: inboxDirectory) : canonical
        try OriginalUploadFiles.writeProtected(bytes, to: damaged)
        try expectQuarantinedInboxIsBlocked(
            at: inboxDirectory, existing: existing, preserving: [(damaged, bytes)],
            absent: location == .staged ? [canonical] : [], targeting: suspect)
    }

    @Test("An unresolved stage leaves an independent healthy stage untouched", arguments: [
        StagedProblem.corrupt, .conflicting,
    ])
    func unresolvedStageDoesNotChangeHealthyStage(problem: StagedProblem) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let existing = try seedHealthyInbox(at: inboxDirectory)
        let healthy = event(taskIdentifier: 18)
        let healthyStage = stagedURL(
            in: inboxDirectory, nonce: try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000000")))
        let problemStage = stagedURL(
            in: inboxDirectory, nonce: try #require(UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")))
        let healthyBytes = try recordBytes(healthy, sequence: 10)
        let problemBytes: Data
        switch problem {
        case .corrupt:
            problemBytes = Data("not a JSON event".utf8)
        case .conflicting:
            // This conflicts with the canonical event, not the earlier healthy stage.
            problemBytes = try recordBytes(existing, sequence: 11)
        }
        try OriginalUploadFiles.writeProtected(healthyBytes, to: healthyStage)
        try OriginalUploadFiles.writeProtected(problemBytes, to: problemStage)
        let healthyBefore = try fileStatus(at: healthyStage)

        try expectQuarantinedInboxIsBlocked(
            at: inboxDirectory, existing: existing,
            preserving: [(healthyStage, healthyBytes), (problemStage, problemBytes)],
            absent: [canonicalURL(for: healthy, in: inboxDirectory)], targeting: healthy)
        try expectFileVersionUnchanged(healthyBefore, at: healthyStage)
    }

    @Test("Duplicate keys, including escaped spellings, remain quarantined", arguments: [
        (DuplicateKeyForm.sequence, EventLocation.staged),
        (.escapedSequence, .canonical),
        (.taskIdentifier, .canonical),
        (.escapedTaskIdentifier, .staged),
        (.scope, .staged),
        (.escapedScope, .canonical),
    ])
    func duplicateEventKeysRemainQuarantined(key: DuplicateKeyForm, location: EventLocation) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let existing = try seedHealthyInbox(at: inboxDirectory)
        let suspect = event(taskIdentifier: 18)
        let originalBytes = try recordBytes(suspect, sequence: 10)
        let original = try #require(String(data: originalBytes, encoding: .utf8))
        let field: (name: String, escaped: String, value: String)
        switch key {
        case .sequence, .escapedSequence:
            field = ("sequence", #"\u0073equence"#, "10")
        case .taskIdentifier, .escapedTaskIdentifier:
            field = ("taskIdentifier", #"\u0074askIdentifier"#, "18")
        case .scope, .escapedScope:
            let scope = try #require(suspect.tag?.scope)
            field = ("scope", #"\u0073cope"#, "\"\(scope)\"")
        }
        let escaped = [DuplicateKeyForm.escapedSequence, .escapedTaskIdentifier, .escapedScope].contains(key)
        let marker = "\"\(field.name)\":"
        let parts = original.components(separatedBy: marker)
        try #require(parts.count == 2)
        let spelling = escaped ? field.escaped : field.name
        // Both values match, so the duplicate itself must cause quarantine.
        let bytes = Data((parts[0] + "\"\(spelling)\":\(field.value)," + marker + parts[1]).utf8)
        let canonical = canonicalURL(for: suspect, in: inboxDirectory)
        let duplicate = location == .staged ? stagedURL(in: inboxDirectory) : canonical
        try OriginalUploadFiles.writeProtected(bytes, to: duplicate)

        try expectQuarantinedInboxIsBlocked(
            at: inboxDirectory, existing: existing, preserving: [(duplicate, bytes)],
            absent: location == .staged ? [canonical] : [], targeting: suspect)
    }

    @Test("An already-open inbox cannot bypass a newly unresolved record")
    func openedInboxDoesNotBypassNewQuarantine() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let existing = event()
        let inbox = OriginalUploadEventInbox(directory: inboxDirectory)
        try inbox.persist(existing)
        let initial = try inbox.events()
        try #require(initial == [existing])
        let canonical = canonicalURL(for: existing, in: inboxDirectory)
        let knownBytes = try Data(contentsOf: canonical)
        let staged = stagedURL(in: inboxDirectory)
        let partial = Data(#"{"sequence":"#.utf8)
        try OriginalUploadFiles.writeProtected(partial, to: staged)

        #expect(throws: (any Error).self) { try inbox.persist(existing) }
        #expect(throws: (any Error).self) { try inbox.remove(existing) }
        #expect(throws: (any Error).self) { _ = try inbox.events() }
        #expect((try? Data(contentsOf: staged)) == partial)
        #expect((try? Data(contentsOf: canonical)) == knownBytes)
    }

    @Test("Symlinked records, including dangling links, stay quarantined", arguments: [
        (EventLocation.staged, true),
        (.staged, false),
        (.canonical, true),
        (.canonical, false),
    ])
    func symlinkedEventRecordsRemainQuarantined(location: EventLocation, targetExists: Bool) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let existing = try seedHealthyInbox(at: inboxDirectory)
        let suspect = event(taskIdentifier: 18)
        let target = directory.appendingPathComponent("synthetic-link-target.json")
        let targetBytes = try recordBytes(suspect, sequence: 10)
        if targetExists {
            try OriginalUploadFiles.writeProtected(targetBytes, to: target)
        }
        let canonical = canonicalURL(for: suspect, in: inboxDirectory)
        let link = location == .staged ? stagedURL(in: inboxDirectory) : canonical
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let files = targetExists ? [(target, targetBytes)] : []
        let absent = (location == .staged ? [canonical] : []) + (targetExists ? [] : [target])
        try expectQuarantinedInboxIsBlocked(
            at: inboxDirectory, existing: existing, preserving: files,
            links: [(link, target.path)], absent: absent, targeting: suspect)
    }

    @Test("Hard links to targets outside the inbox are rejected untouched", arguments: [
        EventLocation.staged, .canonical,
    ])
    func externalHardLinkedRecordsRemainQuarantined(location: EventLocation) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let existing = try seedHealthyInbox(at: inboxDirectory)
        let suspect = event(taskIdentifier: 18)
        let target = directory.appendingPathComponent("synthetic-external-event.json")
        let bytes = try recordBytes(suspect, sequence: 10)
        try OriginalUploadFiles.writeProtected(bytes, to: target)
        let canonical = canonicalURL(for: suspect, in: inboxDirectory)
        let link = location == .staged ? stagedURL(in: inboxDirectory) : canonical
        try FileManager.default.linkItem(at: target, to: link)
        let targetBefore = try fileStatus(at: target)
        let linkBefore = try fileStatus(at: link)
        try #require(targetBefore.st_dev == linkBefore.st_dev)
        try #require(targetBefore.st_ino == linkBefore.st_ino)
        try #require(targetBefore.st_nlink == 2 && linkBefore.st_nlink == 2)

        try expectQuarantinedInboxIsBlocked(
            at: inboxDirectory, existing: existing, preserving: [(target, bytes), (link, bytes)],
            absent: location == .staged ? [canonical] : [], targeting: suspect)
        try expectFileVersionUnchanged(targetBefore, at: target)
        try expectFileVersionUnchanged(linkBefore, at: link)
    }

    @Test("The same event ID with different data or sequence remains unresolved", arguments: [
        (IdentityDifference.completion, IdentityLayout.canonicalAndStaged),
        (.completion, .twoStaged),
        (.sequence, .canonicalAndStaged),
        (.sequence, .twoStaged),
    ])
    func conflictingEventIdentitiesRemainQuarantined(
        difference: IdentityDifference, layout: IdentityLayout
    ) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let existing = try seedHealthyInbox(at: inboxDirectory)
        let original = event(taskIdentifier: 18)
        let changed = OriginalBackgroundCompletion(
            id: original.id, taskIdentifier: 19, tag: original.tag,
            httpStatus: original.httpStatus, transportErrorCode: original.transportErrorCode)
        let conflicting = difference == .completion ? changed : original
        let firstBytes = try recordBytes(original, sequence: 10)
        let secondBytes = try recordBytes(conflicting, sequence: difference == .sequence ? 11 : 10)
        let canonical = canonicalURL(for: original, in: inboxDirectory)
        let first = layout == .canonicalAndStaged ? canonical : stagedURL(in: inboxDirectory)
        let second = stagedURL(in: inboxDirectory)
        try OriginalUploadFiles.writeProtected(firstBytes, to: first)
        try OriginalUploadFiles.writeProtected(secondBytes, to: second)
        try expectQuarantinedInboxIsBlocked(
            at: inboxDirectory, existing: existing, preserving: [(first, firstBytes), (second, secondBytes)],
            absent: layout == .twoStaged ? [canonical] : [], targeting: original)
    }

    @Test("Different events with the same sequence remain unresolved", arguments: [
        SequenceLayout.canonicalAndStaged, .twoStaged, .twoCanonical,
    ])
    func sequenceCollisionsRemainQuarantined(layout: SequenceLayout) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let existing = try seedHealthyInbox(at: inboxDirectory)
        let firstEvent = event(taskIdentifier: 18)
        let secondEvent = event(taskIdentifier: 19)
        let firstCanonical = canonicalURL(for: firstEvent, in: inboxDirectory)
        let secondCanonical = canonicalURL(for: secondEvent, in: inboxDirectory)
        let first: URL
        let second: URL
        switch layout {
        case .canonicalAndStaged:
            first = firstCanonical
            second = stagedURL(in: inboxDirectory)
        case .twoStaged:
            first = stagedURL(in: inboxDirectory)
            second = stagedURL(in: inboxDirectory)
        case .twoCanonical:
            first = firstCanonical
            second = secondCanonical
        }
        let firstBytes = try recordBytes(firstEvent, sequence: 10)
        let secondBytes = try recordBytes(secondEvent, sequence: 10)
        try OriginalUploadFiles.writeProtected(firstBytes, to: first)
        try OriginalUploadFiles.writeProtected(secondBytes, to: second)
        var absent: [URL] = []
        if first != firstCanonical { absent.append(firstCanonical) }
        if second != secondCanonical { absent.append(secondCanonical) }
        try expectQuarantinedInboxIsBlocked(
            at: inboxDirectory, existing: existing, preserving: [(first, firstBytes), (second, secondBytes)],
            absent: absent, targeting: firstEvent)
    }

    @Test("Recovery synchronization failure is retryable from a new inbox", arguments: [false, true])
    func failedRecoverySynchronizationDoesNotLoseEvents(canonicalAlreadyExists: Bool) throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let completion = event()
        try OriginalUploadEventInbox(directory: inboxDirectory).persist(completion)
        let canonical = canonicalURL(for: completion, in: inboxDirectory)
        let staged = stagedURL(in: inboxDirectory)
        if canonicalAlreadyExists {
            try FileManager.default.copyItem(at: canonical, to: staged)
        } else {
            try FileManager.default.moveItem(at: canonical, to: staged)
        }

        let resolvedInbox = inboxDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        var shouldFail = true
        var injectedFailure = false
        var synchronizedOnRetry = false
        let synchronize: (URL) throws -> Void = { url in
            let isInbox = url.resolvingSymlinksInPath().standardizedFileURL.path == resolvedInbox
            let mutationVisible = canonicalAlreadyExists
                ? !FileManager.default.fileExists(atPath: staged.path)
                : FileManager.default.fileExists(atPath: canonical.path)
            if shouldFail && isInbox && mutationVisible {
                injectedFailure = true
                throw POSIXError(.EIO)
            }
            try DurableFile.synchronize(url, directory: true)
            if !shouldFail && isInbox { synchronizedOnRetry = true }
        }
        let interrupted = OriginalUploadEventInbox(directory: inboxDirectory, synchronizeDirectory: synchronize)
        #expect(throws: (any Error).self) { _ = try interrupted.events() }
        try #require(injectedFailure)
        #expect(itemExists(at: canonical) || itemExists(at: staged))

        shouldFail = false
        let reopened = OriginalUploadEventInbox(directory: inboxDirectory, synchronizeDirectory: synchronize)
        #expect(try reopened.events() == [completion])
        #expect(synchronizedOnRetry)
        #expect(itemExists(at: canonical))
        #expect(!itemExists(at: staged))
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events() == [completion])
    }

    @Test
    func reusedEventIdentityCannotOverwriteDifferentCompletion() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inbox = OriginalUploadEventInbox(directory: directory.appendingPathComponent("inbox"))
        let first = event()
        let conflicting = event(id: first.id, taskIdentifier: 19)
        try inbox.persist(first)

        #expect(throws: OriginalUploadStorageError.invalidRecord) {
            try inbox.persist(conflicting)
        }
        #expect(throws: OriginalUploadStorageError.invalidRecord) {
            try inbox.remove(conflicting)
        }
        #expect(try inbox.events() == [first])
    }

    @Test
    func unidentifiedCompletionDoesNotHideKnownScopedEvents() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inbox = OriginalUploadEventInbox(directory: directory.appendingPathComponent("inbox"))
        let known = event()
        let unknown = OriginalBackgroundCompletion(
            id: UUID(), taskIdentifier: 18, tag: nil, httpStatus: nil, transportErrorCode: -1)
        try inbox.persist(unknown)
        try inbox.persist(known)
        let scope = try #require(known.tag?.scope)

        #expect(try inbox.events(scope: scope) == [known])
        #expect(try inbox.unidentifiedEvents() == [unknown])
        try inbox.remove(known)
        #expect(try inbox.events(scope: scope).isEmpty)
        #expect(try inbox.unidentifiedEvents() == [unknown])
    }

    @Test
    func quarantineRejectsTaggedAlteredAndUnknownCompletions() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let inbox = OriginalUploadEventInbox(directory: inboxDirectory)
        let pump = OriginalBackgroundEventPump(inbox: inbox)
        let unknown = unidentifiedEvent()
        let tagged = event()
        try inbox.persist(unknown)
        try inbox.persist(tagged)
        let originalUnknownBytes = try Data(contentsOf: canonicalURL(for: unknown, in: inboxDirectory))

        #expect(throws: OriginalUploadStorageError.invalidRecord) {
            try pump.quarantineUnidentifiedEvent(tagged)
        }
        let altered = unidentifiedEvent(id: unknown.id, taskIdentifier: unknown.taskIdentifier + 1)
        #expect(throws: OriginalUploadStorageError.invalidRecord) {
            try pump.quarantineUnidentifiedEvent(altered)
        }
        #expect(throws: OriginalUploadStorageError.invalidRecord) {
            try pump.quarantineUnidentifiedEvent(unidentifiedEvent())
        }

        #expect(try inbox.events() == [unknown, tagged])
        #expect(try Data(contentsOf: canonicalURL(for: unknown, in: inboxDirectory)) == originalUnknownBytes)
        #expect(try pump.quarantinedEvents().isEmpty)
    }

    @Test
    func quarantinePersistsExactEventSeparatelyAndIsIdempotentAfterRestart() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let inbox = OriginalUploadEventInbox(directory: inboxDirectory)
        let pump = OriginalBackgroundEventPump(inbox: inbox)
        let unknown = unidentifiedEvent()
        let known = event()
        try inbox.persist(unknown)
        try inbox.persist(known)

        try pump.quarantineUnidentifiedEvent(unknown)
        #expect(try inbox.events() == [known])
        #expect(try inbox.events(scope: try #require(known.tag?.scope)) == [known])
        #expect(try inbox.unidentifiedEvents().isEmpty)
        #expect(try pump.quarantinedEvents() == [unknown])
        #expect(try OriginalUploadEventInbox(directory: inbox.quarantineDirectory).events() == [unknown])

        try pump.quarantineUnidentifiedEvent(unknown)
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events() == [known])
        #expect(try OriginalUploadEventInbox(directory: inbox.quarantineDirectory).events() == [unknown])
    }

    @Test
    func quarantineRejectsConflictingQuarantinedEventWithSameID() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inbox = OriginalUploadEventInbox(directory: directory.appendingPathComponent("inbox"))
        let event = unidentifiedEvent()
        let conflictingEvent = unidentifiedEvent(id: event.id, taskIdentifier: event.taskIdentifier + 1)
        try inbox.persist(event)

        let quarantine = OriginalUploadEventInbox(directory: inbox.quarantineDirectory)
        try quarantine.persist(conflictingEvent)
        let pump = OriginalBackgroundEventPump(inbox: inbox, quarantineInbox: quarantine)

        #expect(throws: OriginalUploadStorageError.invalidRecord) {
            try pump.quarantineUnidentifiedEvent(event)
        }
        #expect(try inbox.events() == [event])
        #expect(try quarantine.events() == [conflictingEvent])
    }

    @Test
    func failedQuarantineWriteLeavesActiveCompletionUntouched() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let quarantineDirectory = directory.appendingPathComponent("BackgroundEventQuarantine")
        let event = unidentifiedEvent()
        let active = OriginalUploadEventInbox(directory: inboxDirectory)
        try active.persist(event)
        let originalBytes = try Data(contentsOf: canonicalURL(for: event, in: inboxDirectory))
        var injectedFailure = false
        let quarantineCanonical = canonicalURL(for: event, in: quarantineDirectory)
        let quarantine = OriginalUploadEventInbox(
            directory: quarantineDirectory,
            synchronizeDirectory: { candidate in
                if candidate.resolvingSymlinksInPath().standardizedFileURL.path
                    == quarantineDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
                   FileManager.default.fileExists(atPath: quarantineCanonical.path) {
                    injectedFailure = true
                    throw POSIXError(.EIO)
                }
                try DurableFile.synchronize(candidate, directory: true)
            })
        let pump = OriginalBackgroundEventPump(inbox: active, quarantineInbox: quarantine)

        #expect(throws: (any Error).self) {
            try pump.quarantineUnidentifiedEvent(event)
        }
        #expect(injectedFailure)
        #expect(try active.events() == [event])
        #expect(try Data(contentsOf: canonicalURL(for: event, in: inboxDirectory)) == originalBytes)
        #expect(try OriginalUploadEventInbox(directory: quarantineDirectory).events() == [event])
    }

    @Test
    func failedRemovalKeepsBothCopiesAndRetryCompletes() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let event = unidentifiedEvent()
        var allowRemoval = false
        let active = OriginalUploadEventInbox(
            directory: inboxDirectory,
            beforeUnlink: {
                guard allowRemoval else { throw POSIXError(.EIO) }
            })
        let pump = OriginalBackgroundEventPump(inbox: active)
        try active.persist(event)

        #expect(throws: (any Error).self) {
            try pump.quarantineUnidentifiedEvent(event)
        }
        #expect(try active.events() == [event])
        #expect(try pump.quarantinedEvents() == [event])

        allowRemoval = true
        try pump.quarantineUnidentifiedEvent(event)
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events().isEmpty)
        #expect(try pump.quarantinedEvents() == [event])
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingSameIDPumpPersistenceBlocksQuarantine() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let unknown = unidentifiedEvent()
        let canonical = canonicalURL(for: unknown, in: inboxDirectory)
        let sleeping = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer {
            sleeping.continuation.finish()
            release.continuation.finish()
        }
        var allowSynchronization = true
        let inbox = OriginalUploadEventInbox(directory: inboxDirectory) { candidate in
            if candidate.resolvingSymlinksInPath().standardizedFileURL.path
                == inboxDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
               FileManager.default.fileExists(atPath: canonical.path),
               !allowSynchronization {
                throw POSIXError(.EIO)
            }
            try DurableFile.synchronize(candidate, directory: true)
        }
        try inbox.persist(unknown)
        allowSynchronization = false
        let pump = OriginalBackgroundEventPump(inbox: inbox, sleep: { _ in
            sleeping.continuation.yield()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        })

        pump.accept(unknown)
        try #require(pump.hasPersistenceError)
        var sleepIterator = sleeping.stream.makeAsyncIterator()
        try #require(await sleepIterator.next() != nil)
        #expect(throws: OriginalUploadStorageError.busy) {
            try pump.quarantineUnidentifiedEvent(unknown)
        }
        allowSynchronization = true
        #expect(try inbox.events() == [unknown])
        #expect(try pump.quarantinedEvents().isEmpty)

        pump.retry()
        #expect(!pump.hasPersistenceError)
        try pump.quarantineUnidentifiedEvent(unknown)
        #expect(try inbox.events().isEmpty)
        #expect(try pump.quarantinedEvents() == [unknown])
    }

    @Test
    func unidentifiedTasksDoNotHideKnownCancellationTargets() {
        let scope = String(repeating: "a", count: 64)
        let job = UUID()
        let incarnation = UUID()
        let matching = OriginalBackgroundTaskTag(
            scope: scope, jobId: job, jobIncarnation: incarnation, attemptId: UUID())
        let otherJob = OriginalBackgroundTaskTag(
            scope: scope, jobId: UUID(), jobIncarnation: incarnation, attemptId: UUID())
        let otherScope = OriginalBackgroundTaskTag(
            scope: String(repeating: "b", count: 64), jobId: job,
            jobIncarnation: incarnation, attemptId: UUID())
        let otherIncarnation = OriginalBackgroundTaskTag(
            scope: scope, jobId: job, jobIncarnation: UUID(), attemptId: UUID())
        let index = OriginalBackgroundTaskIndex([
            OriginalBackgroundTaskSnapshot(identifier: 1, tag: matching),
            OriginalBackgroundTaskSnapshot(identifier: 2, tag: nil),
            OriginalBackgroundTaskSnapshot(identifier: 3, tag: otherJob),
            OriginalBackgroundTaskSnapshot(identifier: 4, tag: otherScope),
            OriginalBackgroundTaskSnapshot(identifier: 5, tag: otherIncarnation),
        ])
        #expect(index.hasUnidentifiedTasks)
        #expect(index.taskIdentifiers == [1, 2, 3, 4, 5])
        #expect(index.cancellationTargets(scope: scope, jobId: job, incarnation: incarnation) == [1])
    }

    @Test
    func failedCompletionBlocksLaterEventsUntilPersistenceSucceeds() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let first = event()
        let second = event(taskIdentifier: 18)
        var allowSynchronization = false
        let inbox = OriginalUploadEventInbox(directory: inboxDirectory) { directory in
            let firstFile = directory.appendingPathComponent("event-\(first.id).json")
            if !allowSynchronization && FileManager.default.fileExists(atPath: firstFile.path) {
                throw POSIXError(.EIO)
            }
            try DurableFile.synchronize(directory, directory: true)
        }
        let pump = OriginalBackgroundEventPump(inbox: inbox)
        var notifications = 0
        pump.onPendingEvents = { notifications += 1 }
        pump.accept(first)
        pump.accept(second)

        #expect(pump.hasPersistenceError)
        #expect(notifications == 0)
        #expect(!FileManager.default.fileExists(
            atPath: inboxDirectory.appendingPathComponent("event-\(second.id).json").path))

        allowSynchronization = true
        pump.retry()
        #expect(!pump.hasPersistenceError)
        #expect(notifications == 2)
        #expect(try inbox.events() == [first, second])
        pump.retry()
        #expect(notifications == 2)
    }

    @Test("A recovered event cannot be acknowledged while the pump owns its retry")
    func recoveredEventAcknowledgementWaitsForPumpRetry() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let completion = event()
        let unrelated = event(taskIdentifier: 18)
        let canonical = canonicalURL(for: completion, in: inboxDirectory)
        let retryGate = AsyncStream<Void>.makeStream()
        defer { retryGate.continuation.finish() }
        var allowSynchronization = false
        var injectedFailure = false
        let inbox = OriginalUploadEventInbox(directory: inboxDirectory) { candidate in
            let isInbox = candidate.resolvingSymlinksInPath().standardizedFileURL.path
                == inboxDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            if isInbox && !allowSynchronization && FileManager.default.fileExists(atPath: canonical.path) {
                injectedFailure = true
                throw POSIXError(.EIO)
            }
            try DurableFile.synchronize(candidate, directory: true)
        }
        try inbox.persist(unrelated)
        try #require(!itemExists(at: canonical))
        let pump = OriginalBackgroundEventPump(inbox: inbox, sleep: { _ in
            var iterator = retryGate.stream.makeAsyncIterator()
            _ = await iterator.next()
        })
        var notifications = 0
        pump.onPendingEvents = { notifications += 1 }
        pump.accept(completion)
        try #require(injectedFailure)
        try #require(pump.hasPersistenceError)
        try #require(itemExists(at: canonical))
        #expect(notifications == 0)

        let reopened = OriginalUploadEventInbox(directory: inboxDirectory)
        let visible = try reopened.events()
        try #require(visible == [unrelated, completion])
        // An I/O failure must not masquerade as the pending-ID acknowledgement guard.
        allowSynchronization = true
        let sameID = OriginalBackgroundCompletion(
            id: completion.id, taskIdentifier: completion.taskIdentifier + 1, tag: completion.tag,
            httpStatus: completion.httpStatus, transportErrorCode: completion.transportErrorCode)
        #expect(throws: OriginalUploadStorageError.busy) { try pump.acknowledgeReconciledEvent(completion) }
        #expect(throws: OriginalUploadStorageError.busy) { try pump.acknowledgeReconciledEvent(sameID) }
        #expect(pump.hasPersistenceError)
        #expect(try reopened.events() == [unrelated, completion])

        try pump.acknowledgeReconciledEvent(unrelated)
        #expect(try reopened.events() == [completion])
        pump.retry()
        try #require(!pump.hasPersistenceError)
        #expect(notifications == 1)
        #expect(try reopened.events() == [completion])
        try pump.acknowledgeReconciledEvent(completion)
        #expect(!itemExists(at: canonical))
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events().isEmpty)
        pump.retry()
        #expect(notifications == 1)
        #expect(try OriginalUploadEventInbox(directory: inboxDirectory).events().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func transientPersistenceFailureRetriesWithoutAnotherCallback() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let completion = event()
        let sleeping = AsyncStream<Duration>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let acknowledged = AsyncStream<Void>.makeStream()
        var allowSynchronization = false
        let inbox = OriginalUploadEventInbox(directory: inboxDirectory) { directory in
            let file = directory.appendingPathComponent("event-\(completion.id).json")
            if !allowSynchronization && FileManager.default.fileExists(atPath: file.path) {
                throw POSIXError(.EIO)
            }
            try DurableFile.synchronize(directory, directory: true)
        }
        let pump = OriginalBackgroundEventPump(inbox: inbox, sleep: { delay in
            sleeping.continuation.yield(delay)
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        })
        pump.onPendingEvents = { acknowledged.continuation.yield() }
        pump.accept(completion)
        #expect(pump.hasPersistenceError)

        var sleepIterator = sleeping.stream.makeAsyncIterator()
        #expect(await sleepIterator.next() == .seconds(1))
        allowSynchronization = true
        release.continuation.yield()
        var acknowledgementIterator = acknowledged.stream.makeAsyncIterator()
        #expect(await acknowledgementIterator.next() != nil)
        #expect(!pump.hasPersistenceError)
        #expect(try inbox.events() == [completion])
        sleeping.continuation.finish()
        release.continuation.finish()
        acknowledged.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func obsoleteRetryCannotReplaceTheCurrentRetry() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let completion = event()
        let sleeping = AsyncStream<Int>.makeStream()
        let firstRelease = AsyncStream<Void>.makeStream()
        let secondRelease = AsyncStream<Void>.makeStream()
        let acknowledged = AsyncStream<Void>.makeStream()
        let number = Mutex(0)
        var allowSynchronization = false
        var attempts = 0
        let inbox = OriginalUploadEventInbox(directory: inboxDirectory) { directory in
            let file = directory.appendingPathComponent("event-\(completion.id).json")
            if FileManager.default.fileExists(atPath: file.path) {
                attempts += 1
                if !allowSynchronization { throw POSIXError(.EIO) }
            }
            try DurableFile.synchronize(directory, directory: true)
        }
        let pump = OriginalBackgroundEventPump(inbox: inbox, sleep: { _ in
            let current = number.withLock { value in
                value += 1
                return value
            }
            sleeping.continuation.yield(current)
            var iterator = (current == 1 ? firstRelease.stream : secondRelease.stream).makeAsyncIterator()
            _ = await iterator.next()
        })
        pump.onPendingEvents = { acknowledged.continuation.yield() }
        pump.accept(completion)
        var sleepIterator = sleeping.stream.makeAsyncIterator()
        #expect(await sleepIterator.next() == 1)

        firstRelease.continuation.yield()
        pump.retry()
        #expect(await sleepIterator.next() == 2)
        await Task.yield()
        #expect(attempts == 2)
        #expect(pump.hasPersistenceError)

        allowSynchronization = true
        secondRelease.continuation.yield()
        var acknowledgementIterator = acknowledged.stream.makeAsyncIterator()
        #expect(await acknowledgementIterator.next() != nil)
        #expect(!pump.hasPersistenceError)
        #expect(try inbox.events() == [completion])
        sleeping.continuation.finish()
        firstRelease.continuation.finish()
        secondRelease.continuation.finish()
        acknowledged.continuation.finish()
    }

    @Test
    func removalRetriesSynchronizationWhenTheEventIsAlreadyMissing() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let inboxDirectory = directory.appendingPathComponent("inbox")
        let value = event()
        var shouldFail = false
        let inbox = OriginalUploadEventInbox(directory: inboxDirectory) { directory in
            let isInbox = directory.resolvingSymlinksInPath().standardizedFileURL.path
                == inboxDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            if shouldFail && isInbox
                && !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("event-\(value.id).json").path) {
                shouldFail = false
                throw POSIXError(.EIO)
            }
            try DurableFile.synchronize(directory, directory: true)
        }
        try inbox.persist(value)
        shouldFail = true
        #expect(throws: OriginalUploadStorageError.cleanupFailed) { try inbox.remove(value) }
        try #require(!shouldFail)
        #expect(!itemExists(at: canonicalURL(for: value, in: inboxDirectory)))
        try inbox.remove(value)
        #expect(try inbox.events().isEmpty)
    }
}
