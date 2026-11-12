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

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
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

    private func canonicalURL(for event: OriginalBackgroundCompletion, in directory: URL) -> URL {
        directory.appendingPathComponent("event-\(event.id.uuidString).json")
    }

    private func stagedURL(in directory: URL, nonce: UUID = UUID()) -> URL {
        directory.appendingPathComponent("event-update-\(nonce.uuidString).tmp")
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

        let recovered = try OriginalUploadEventInbox(directory: inboxDirectory).events()
        #expect(recovered == [earlier, completion])
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
