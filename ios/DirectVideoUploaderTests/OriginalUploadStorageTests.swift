import Foundation
import Testing
@testable import DirectVideoUploader

@MainActor
struct OriginalUploadStorageTests {
    private final class SynchronizationProbe {
        let shouldFail: (URL) -> Bool
        private(set) var failedURL: URL?
        private(set) var synchronized: [URL] = []

        init(shouldFail: @escaping (URL) -> Bool) {
            self.shouldFail = shouldFail
        }

        func synchronize(_ url: URL) throws {
            if failedURL == nil && shouldFail(url) {
                failedURL = url
                throw POSIXError(.EIO)
            }
            try DurableFile.synchronize(url, directory: true)
            synchronized.append(url)
        }
    }

    private let metadata = VideoMetadata(
        duration: 12, resolution: "1920x1080", codec: "HEVC", orientation: "landscape",
        deviceModel: "iPhone", osVersion: "iOS", capturedAt: nil,
        gpsLat: 0, gpsLon: 0, gpsAltitude: nil)

    private func auth(
        _ user: String = "user-1", _ server: String = "https://one.example.test"
    ) -> AuthService {
        let serverURL = URL(string: server)!
        let auth = AuthService(storage: .memory, serverURL: { serverURL })
        auth.token = "test-token"
        auth.currentUser = User(
            id: user, phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        return auth
    }

    private func access(_ auth: AuthService) throws -> OriginalUploadAccess {
        try OriginalUploadAccess(
            auth: auth, allowedOrigins: ["https://one.example.test", "https://other.example.test"])
    }

    private func access(
        _ user: String = "user-1", _ server: String = "https://one.example.test"
    ) throws -> OriginalUploadAccess {
        try access(auth(user, server))
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("original-upload-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanup(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove the upload test directory: \(Log.describe(error))")
        }
    }

    private func prepare(
        directory: URL, access: OriginalUploadAccess
    ) async throws -> (OriginalUploadJournal, OriginalUploadJob) {
        let source = directory.appendingPathComponent("selected.mov")
        try Data("native original".utf8).write(to: source)
        let journal = OriginalUploadJournal(directory: directory.appendingPathComponent("journal"))
        let job = try await journal.prepare(
            id: UUID(), source: source, fileName: "selected.mov", metadata: metadata,
            photoIdentifier: "photo-1", transcribe: true, access: access)
        return (journal, job)
    }

    private func uploading(
        _ original: OriginalUploadJob, journal: OriginalUploadJournal, access: OriginalUploadAccess
    ) throws -> OriginalUploadJob {
        var job = original
        job.state = .reserving
        job = try journal.update(job, access: access)
        job.assetId = UUID().uuidString
        job = try journal.update(job, access: access)
        job.sessionId = UUID().uuidString
        job.state = .uploading
        return try journal.update(job, access: access)
    }

    private func serverSession(
        _ job: OriginalUploadJob, id: String, clipId: String,
        status: OriginalUploadServerSession.Status, parts: [OriginalUploadServerPart] = []
    ) throws -> OriginalUploadServerSession {
        OriginalUploadServerSession(
            id: id, assetId: try #require(job.assetId), clipId: clipId, status: status,
            expectedSizeBytes: String(job.fingerprint.byteCount),
            expectedSha256: job.fingerprint.sha256,
            partSizeBytes: OriginalUploadFiles.maximumPartSize,
            partCount: job.manifest.parts.count,
            expiresAt: DVUDateFormatting.isoString(from: Date().addingTimeInterval(60)),
            completedAt: nil, parts: parts)
    }

    private func inventory(
        tasks: Set<Int> = [], jobs: Set<UUID> = [], attempts: Set<UUID> = [],
        unidentified: Bool = false, fence: OriginalUploadTaskFence = .shared
    ) throws -> OriginalUploadTaskInventory {
        try fence.inventory(
            snapshot: fence.beginSnapshot(),
            taskIdentifiers: tasks, jobIDs: jobs, attemptIDs: attempts,
            hasUnidentifiedTasks: unidentified)
    }

    private func schedule(
        _ prepared: (job: OriginalUploadJob, part: OriginalUploadPart), identifier: Int,
        journal: OriginalUploadJournal, access: OriginalUploadAccess
    ) throws -> OriginalUploadJob {
        let attempt = try #require(prepared.job.attempts.first)
        return try journal.scheduleReadyPart(
            for: prepared.job, attemptId: attempt.id, verifiedPart: prepared.part, access: access,
            createTask: { _ in (handle: identifier, identifier: identifier) },
            startTask: { _ in }, cancelTask: { _ in })
    }

    @Test
    func scopeStopIsStickyScopedAndRequiresCurrentAccess() async throws {
        let service = auth()
        let current = try access(service)
        let otherUser = try access("other-user")
        let otherServer = try access("user-1", "https://other.example.test")
        let fence = OriginalUploadTaskFence()
        let oldSnapshot = fence.beginSnapshot()
        let permit = try fence.stopScope(access: current)
        #expect(throws: OriginalUploadStorageError.busy) {
            try fence.inventory(snapshot: oldSnapshot, taskIdentifiers: [], jobIDs: [], attemptIDs: [],
                                hasUnidentifiedTasks: false)
        }
        #expect(throws: OriginalUploadStorageError.scopeStopped) {
            try fence.requireActive(scope: current.scope, access: current)
        }
        try fence.requireActive(scope: otherUser.scope, access: otherUser)
        try fence.requireActive(scope: otherServer.scope, access: otherServer)
        #expect(throws: OriginalUploadStorageError.invalidScope) {
            try OriginalUploadTaskFence().stoppedScope(for: permit)
        }
        let user = try #require(service.currentUser)
        service.logout()
        #expect(throws: OriginalUploadStorageError.invalidScope) { try fence.stopScope(access: current) }
        service.token = "new-token"
        service.currentUser = user
        let relogged = try access(service)
        #expect(throws: OriginalUploadStorageError.scopeStopped) {
            try fence.requireActive(scope: relogged.scope, access: relogged)
        }
        // The permit remains usable without the former credentials.
        let orphan = OriginalBackgroundTaskSnapshot(
            identifier: 41, tag: OriginalBackgroundTaskTag(
                scope: try OriginalUploadJournal.scopeIdentifier(current.scope),
                jobId: UUID(), jobIncarnation: UUID(), attemptId: UUID()))
        var cancelled = false
        let result = try await OriginalBackgroundScopeStop.request(
            permit: permit, fence: fence, tasks: { [orphan] },
            snapshot: { $0 }, cancel: { _ in cancelled = true })
        #expect(cancelled && result.requestedTaskIdentifiers == [41])
        #expect(!result.inventoryStale)
    }

    @Test
    func reentrantScopeStopAtSchedulingBoundariesCancelsAndRetainsRecordedAttempt() async throws {
        for boundary in 0...2 {
            let directory = try fixture()
            defer { cleanup(directory) }
            let current = try access()
            let (initialJournal, initial) = try await prepare(directory: directory, access: current)
            let running = try uploading(initial, journal: initialJournal, access: current)
            let prepared = try await initialJournal.preparePart(for: running, number: 1, access: current)
            let attempt = try #require(prepared.job.attempts.first)
            let fence = OriginalUploadTaskFence()
            var injected = false
            let journal = OriginalUploadJournal(
                directory: directory.appendingPathComponent("journal"),
                synchronizeDirectory: { directory in
                    try DurableFile.synchronize(directory, directory: true)
                    guard boundary == 2, !injected,
                          let data = try? Data(contentsOf: directory.appendingPathComponent("job.json")),
                          let job = try? JSONDecoder().decode(OriginalUploadJob.self, from: data),
                          job.attempts.contains(where: { $0.state == .scheduled }) else { return }
                    injected = true
                    _ = try fence.stopScope(access: current)
                }, taskFence: fence)
            if boundary == 0 { _ = try fence.stopScope(access: current) }
            var created = false
            var started = false
            var cancelled = false
            #expect(throws: OriginalUploadStorageError.scopeStopped) {
                try journal.scheduleReadyPart(
                    for: prepared.job, attemptId: attempt.id, verifiedPart: prepared.part, access: current,
                    createTask: { _ in
                        created = true
                        if boundary == 1 { _ = try fence.stopScope(access: current) }
                        return (handle: 17, identifier: 17)
                    },
                    startTask: { _ in started = true }, cancelTask: { _ in cancelled = true })
            }
            #expect(created == (boundary != 0))
            #expect(cancelled == created)
            #expect(!started)
            let saved = try journal.read(id: prepared.job.id, access: current)
            #expect(saved.attempts.first?.state == (boundary == 2 ? .scheduled : .ready))
            #expect(saved.attempts.first?.taskIdentifier == (boundary == 2 ? 17 : nil))
            #expect(FileManager.default.fileExists(atPath: prepared.part.url.path))
        }
    }

    @Test
    func scopeStopCancelsOnlyUnambiguousScopedTasksAndReportsStaleInventory() async throws {
        let current = try access()
        let fence = OriginalUploadTaskFence()
        let permit = try fence.stopScope(access: current)
        let scope = try OriginalUploadJournal.scopeIdentifier(current.scope)
        func tag(_ scope: String, _ attempt: UUID = UUID()) -> OriginalBackgroundTaskTag {
            OriginalBackgroundTaskTag(scope: scope, jobId: UUID(), jobIncarnation: UUID(), attemptId: attempt)
        }
        let duplicate = UUID()
        let items = [
            OriginalBackgroundTaskSnapshot(identifier: 1, tag: tag(scope)),
            OriginalBackgroundTaskSnapshot(identifier: 2, tag: nil),
            OriginalBackgroundTaskSnapshot(identifier: 3, tag: tag(String(repeating: "b", count: 64))),
            OriginalBackgroundTaskSnapshot(identifier: 4, tag: tag(scope)),
            OriginalBackgroundTaskSnapshot(identifier: 4, tag: tag(scope)),
            OriginalBackgroundTaskSnapshot(identifier: 5, tag: tag(scope, duplicate)),
            OriginalBackgroundTaskSnapshot(identifier: 6, tag: tag(scope, duplicate)),
            OriginalBackgroundTaskSnapshot(identifier: 7, tag: tag(scope)),
        ]
        var cancelled: [Int] = []
        let result = try await OriginalBackgroundScopeStop.request(
            permit: permit, fence: fence, tasks: { items }, snapshot: { $0 },
            cancel: { cancelled.append($0.identifier) })
        #expect(Set(cancelled) == [1, 7])
        #expect(result.requestedTaskIdentifiers == [1, 7])
        #expect(result.hasUnidentifiedTasks && result.hasDuplicateIdentifiers && result.hasDuplicateAttempts)
        #expect(!result.inventoryStale)

        var enumerated = false
        await #expect(throws: OriginalUploadStorageError.invalidScope) {
            try await OriginalBackgroundScopeStop.request(
                permit: permit, fence: OriginalUploadTaskFence(), tasks: { enumerated = true; return items },
                snapshot: { $0 }, cancel: { _ in })
        }
        #expect(!enumerated)
        cancelled.removeAll()
        let stale = try await OriginalBackgroundScopeStop.request(
            permit: permit, fence: fence,
            tasks: {
                _ = try? fence.stopScope(access: access("different-user"))
                return items
            }, snapshot: { $0 }, cancel: { cancelled.append($0.identifier) })
        #expect(stale.inventoryStale)
        #expect(stale.requestedTaskIdentifiers.isEmpty && cancelled.isEmpty)

        var snapshots = 0
        let changed = try await OriginalBackgroundScopeStop.request(
            permit: permit, fence: fence, tasks: { [items[0]] },
            snapshot: { item in
                snapshots += 1
                return snapshots == 1 ? item : OriginalBackgroundTaskSnapshot(identifier: item.identifier, tag: nil)
            }, cancel: { cancelled.append($0.identifier) })
        #expect(changed.inventoryStale && changed.requestedTaskIdentifiers.isEmpty)
        #expect(cancelled.isEmpty)

        let interrupted = try await OriginalBackgroundScopeStop.request(
            permit: permit, fence: fence, tasks: { [items[0], items[7]] }, snapshot: { $0 },
            cancel: {
                cancelled.append($0.identifier)
                _ = try? fence.stopScope(access: access("third-user"))
            })
        #expect(interrupted.inventoryStale)
        #expect(interrupted.requestedTaskIdentifiers == [1])
        #expect(cancelled == [1])
    }

    @Test
    func changedMissingOrAmbiguousTaskAttachmentsCannotBeTrusted() throws {
        let scope = try OriginalUploadJournal.scopeIdentifier(access().scope)
        let attempt = UUID()
        let tag = OriginalBackgroundTaskTag(
            scope: scope, jobId: UUID(), jobIncarnation: UUID(), attemptId: attempt)
        let attached = OriginalBackgroundTaskSnapshot(
            identifier: 41, tag: tag, attachment: tag.taskDescription)

        // A stable pair is usable, but comparing parsed tags alone would miss
        // changes to the exact OS taskDescription.
        try OriginalBackgroundTaskIndex.requireStableAttachments([attached], [attached])
        let rewritten = OriginalBackgroundTaskSnapshot(
            identifier: 41, tag: tag, attachment: "rewritten:\(tag.taskDescription)")
        #expect(throws: OriginalUploadStorageError.busy) {
            try OriginalBackgroundTaskIndex.requireStableAttachments([attached], [rewritten])
        }
        let detached = OriginalBackgroundTaskSnapshot(identifier: 41, tag: nil, attachment: nil)
        #expect(throws: OriginalUploadStorageError.busy) {
            try OriginalBackgroundTaskIndex.requireStableAttachments([attached], [detached])
        }

        // A duplicate attempt is ambiguous even if both descriptions stay
        // unchanged; neither task may become a cancellation target.
        let duplicate = OriginalBackgroundTaskSnapshot(
            identifier: 42, tag: tag, attachment: tag.taskDescription)
        let index = OriginalBackgroundTaskIndex([attached, duplicate])
        #expect(index.hasUnidentifiedTasks)
        #expect(index.cancellationTargets(scope: scope, jobId: tag.jobId, incarnation: tag.jobIncarnation).isEmpty)
    }

    @Test
    func stagesExactBytesAndPersistsAccountScopedIdentity() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, job) = try await prepare(directory: directory, access: current)
        let original = try journal.originalURL(for: job, access: current)

        #expect(job.mode == .original)
        #expect(job.fingerprint.byteCount == 15)
        #expect(job.fingerprint.sha256 == "77ececd9176974f1a4c22a09919d4c7c0f70d35042f2380f8eb4147bb5c5e2d2")
        #expect(try Data(contentsOf: original) == Data("native original".utf8))
        #expect(try journal.read(id: job.id, access: current) == job)
        #expect(try journal.jobs(access: current) == [job])
        #expect(try journal.jobs(access: access("other-user")).isEmpty)
        #expect(try journal.jobs(access: access("user-1", "https://other.example.test")).isEmpty)
        let data = try Data(contentsOf: original.deletingLastPathComponent().appendingPathComponent("job.json"))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("Authorization"))
        #expect(!text.contains("signature"))
        #expect(!text.contains("token"))
    }

    @Test
    func enforcesExactSizeLimitAndRemovesPartialCopies() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let source = directory.appendingPathComponent("selected")
        let destination = directory.appendingPathComponent("original")
        #expect(OriginalUploadFiles.maximumSize == 524_288_000)
        #expect(OriginalUploadFiles.maximumPartSize == 52_428_800)
        try Data().write(to: source)
        await #expect(throws: OriginalUploadStorageError.emptyFile) {
            try await OriginalUploadFiles.stage(source: source, destination: destination, maximumSize: 5)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try Data("12345".utf8).write(to: source)
        let result = try await OriginalUploadFiles.stage(
            source: source, destination: destination, maximumSize: 5)
        #expect(result.fingerprint.byteCount == 5)
        try FileManager.default.removeItem(at: destination)
        try Data("123456".utf8).write(to: source)
        await #expect(throws: OriginalUploadStorageError.fileTooLarge) {
            try await OriginalUploadFiles.stage(source: source, destination: destination, maximumSize: 5)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func createsBoundedPartsMatchingTheStagedManifest() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let source = directory.appendingPathComponent("selected")
        let original = directory.appendingPathComponent("original")
        try Data("abcdefghijk".utf8).write(to: source)
        let manifest = try await OriginalUploadFiles.stage(source: source, destination: original, partSize: 4)
        let first = try await OriginalUploadFiles.part(
            source: original, destination: directory.appendingPathComponent("part-1"),
            manifest: manifest, number: 1)
        let last = try await OriginalUploadFiles.part(
            source: original, destination: directory.appendingPathComponent("part-3"),
            manifest: manifest, number: 3)
        #expect(try Data(contentsOf: first.url) == Data("abcd".utf8))
        #expect(try Data(contentsOf: last.url) == Data("ijk".utf8))
        #expect(first.fingerprint == manifest.parts[0])
        #expect(last.fingerprint == manifest.parts[2])
        await #expect(throws: OriginalUploadStorageError.invalidPart) {
            try await OriginalUploadFiles.part(
                source: original, destination: directory.appendingPathComponent("part-4"),
                manifest: manifest, number: 4)
        }
    }

    @Test
    func refusesSameSizeMutationBeforePublishingPart() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, initial) = try await prepare(directory: directory, access: current)
        let job = try uploading(initial, journal: journal, access: current)
        let original = try journal.originalURL(for: job, access: current)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        try Data("native modified".utf8).write(to: original)

        await #expect(throws: OriginalUploadStorageError.fileChanged) {
            try await journal.preparePart(for: job, number: 1, access: current)
        }
        let recovered = try #require(journal.jobs(access: current).first)
        #expect(recovered.attempts.isEmpty)
    }

    @Test
    func recoversAReadyPartAndRejectsChangedBytes() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, initial) = try await prepare(directory: directory, access: current)
        let job = try uploading(initial, journal: journal, access: current)
        let prepared = try await journal.preparePart(for: job, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let recovered = OriginalUploadJournal(directory: directory.appendingPathComponent("journal"))
        let saved = try recovered.read(id: job.id, access: current)
        let part = try await recovered.readyPart(for: saved, attemptId: attempt.id, access: current)
        #expect(part.fingerprint == job.manifest.parts[0])

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: part.url.path)
        try Data("native modified".utf8).write(to: part.url)
        await #expect(throws: OriginalUploadStorageError.fileChanged) {
            try await recovered.readyPart(for: saved, attemptId: attempt.id, access: current)
        }
    }

    @Test
    func uncertainReadyPartPublicationRetainsBytesForRecovery() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (initialJournal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: initialJournal, access: current)
        let probe = SynchronizationProbe { directory in
            let url = directory.appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: url),
                  let job = try? JSONDecoder().decode(OriginalUploadJob.self, from: data) else {
                return false
            }
            return job.attempts.contains { $0.state == .ready }
        }
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"),
            synchronizeDirectory: probe.synchronize)

        await #expect(throws: OriginalUploadStorageError.durabilityUncertain) {
            try await journal.preparePart(for: running, number: 1, access: current)
        }
        #expect(probe.failedURL != nil)
        let recovered = try #require(journal.jobs(access: current).first)
        let attempt = try #require(recovered.attempts.first)
        #expect(attempt.state == .ready)
        let part = try await journal.readyPart(for: recovered, attemptId: attempt.id, access: current)
        #expect(try Data(contentsOf: part.url) == Data("native original".utf8))
        #expect(probe.synchronized.contains(probe.failedURL!))
    }

    @Test
    func uncertainJobPublicationIsRetainedAndReconciled() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let source = directory.appendingPathComponent("selected.mov")
        try Data("native original".utf8).write(to: source)
        let id = UUID()
        let probe = SynchronizationProbe { scope in
            scope.lastPathComponent.hasPrefix("scope-")
                && FileManager.default.fileExists(
                    atPath: scope.appendingPathComponent("job-\(id.uuidString)").path)
        }
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"),
            synchronizeDirectory: probe.synchronize)

        await #expect(throws: OriginalUploadStorageError.durabilityUncertain) {
            try await journal.prepare(
                id: id, source: source, fileName: "selected.mov", metadata: metadata,
                photoIdentifier: nil, transcribe: false, access: current)
        }
        let failedURL = try #require(probe.failedURL)
        let recovered = try #require(journal.jobs(access: current).first)
        #expect(recovered.id == id)
        #expect(try Data(contentsOf: journal.originalURL(for: recovered, access: current))
            == Data("native original".utf8))
        #expect(probe.synchronized.contains(failedURL))
    }

    @Test
    func uncertainInitialJournalIsDiscardedBeforeAskingForPreparationAgain() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let source = directory.appendingPathComponent("selected.mov")
        try Data("native original".utf8).write(to: source)
        let id = UUID()
        let probe = SynchronizationProbe { preparation in
            preparation.lastPathComponent.hasPrefix("preparing-")
                && FileManager.default.fileExists(
                    atPath: preparation.appendingPathComponent("job.json").path)
        }
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"),
            synchronizeDirectory: probe.synchronize)

        await #expect(throws: OriginalUploadStorageError.preparationDiscarded) {
            try await journal.prepare(
                id: id, source: source, fileName: "selected.mov", metadata: metadata,
                photoIdentifier: nil, transcribe: false, access: current)
        }
        #expect(probe.failedURL != nil)
        #expect(try journal.jobs(access: current).isEmpty)
        #expect(try Data(contentsOf: source) == Data("native original".utf8))
        let prepared = try await journal.prepare(
            id: id, source: source, fileName: "selected.mov", metadata: metadata,
            photoIdentifier: nil, transcribe: false, access: current)
        #expect(prepared.id == id)
    }

    @Test
    func retriesDirectoryCreationSynchronizationWhenDirectoryAlreadyExists() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let root = directory.appendingPathComponent("journal", isDirectory: true)
        let probe = SynchronizationProbe { url in
            url == root.resolvingSymlinksInPath()
                && ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                    .contains { $0.hasPrefix("scope-") }
        }
        let journal = OriginalUploadJournal(directory: root, synchronizeDirectory: probe.synchronize)
        let current = try access()

        #expect(throws: POSIXError.self) { try journal.jobs(access: current) }
        let failedURL = try #require(probe.failedURL)
        #expect(try journal.jobs(access: current).isEmpty)
        #expect(probe.synchronized.contains(failedURL))
    }

    @Test
    func cleanupRetriesSynchronizationAfterAnUnlink() throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let file = directory.appendingPathComponent("part")
        try Data("video".utf8).write(to: file)
        var calls = 0

        #expect(throws: OriginalUploadStorageError.cleanupFailed) {
            try OriginalUploadFiles.removeOwnedItem(file) { _ in
                calls += 1
                throw POSIXError(.EIO)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try OriginalUploadFiles.removeOwnedItem(file) { parent in
            calls += 1
            try DurableFile.synchronize(parent, directory: true)
        }
        #expect(calls == 2)

        let missingChild = directory.appendingPathComponent("removed-parent/child")
        try OriginalUploadFiles.removeOwnedItem(missingChild) { parent in
            #expect(parent == directory)
            try DurableFile.synchronize(parent, directory: true)
        }
    }

    @Test
    func removingAnUnstartedJobCanRetryAfterItsDirectoryWasUnlinked() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (initialJournal, job) = try await prepare(directory: directory, access: current)
        let jobDirectory = try initialJournal.originalURL(for: job, access: current)
            .deletingLastPathComponent()
        let scopeDirectory = jobDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        let probe = SynchronizationProbe { parent in
            parent == scopeDirectory && !FileManager.default.fileExists(atPath: jobDirectory.path)
        }
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"),
            synchronizeDirectory: probe.synchronize)

        #expect(throws: OriginalUploadStorageError.cleanupFailed) {
            try journal.removeUnstarted(job, access: current)
        }
        let failedURL = try #require(probe.failedURL)
        #expect(!FileManager.default.fileExists(atPath: jobDirectory.path))
        try journal.removeUnstarted(job, access: current)
        #expect(probe.synchronized.contains(failedURL))
        #expect(try journal.jobs(access: current).isEmpty)
    }

    @Test
    func cleanupCannotSucceedWhileTheSameJobIsBeingPreparedAgain() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (initialJournal, job) = try await prepare(directory: directory, access: current)
        try initialJournal.removeUnstarted(job, access: current)
        let started = AsyncStream<Void>.makeStream()
        let proceed = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); proceed.continuation.finish() }
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"),
            stageOriginal: { source, destination in
                started.continuation.yield(())
                var iterator = proceed.stream.makeAsyncIterator()
                _ = await iterator.next()
                return try await OriginalUploadFiles.stage(source: source, destination: destination)
            })
        let preparation = Task {
            try await journal.prepare(
                id: job.id, source: directory.appendingPathComponent("selected.mov"),
                fileName: "selected.mov", metadata: metadata,
                photoIdentifier: nil, transcribe: false, access: current)
        }
        defer { preparation.cancel() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()

        #expect(throws: OriginalUploadStorageError.busy) {
            try initialJournal.removeUnstarted(job, access: current)
        }
        proceed.continuation.yield(())
        let replacement = try await preparation.value
        #expect(replacement.id == job.id)
        #expect(try journal.read(id: replacement.id, access: current) == replacement)
    }

    @Test
    func cleanupRemovesAnAbandonedPreparationForTheSameJob() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, job) = try await prepare(directory: directory, access: current)
        let scope = try journal.originalURL(for: job, access: current)
            .deletingLastPathComponent().deletingLastPathComponent()
        try journal.removeUnstarted(job, access: current)
        let abandoned = scope.appendingPathComponent("preparing-\(job.id.uuidString)")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        try Data("staged video".utf8).write(to: abandoned.appendingPathComponent("original"))

        try journal.removeUnstarted(job, access: current)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(try journal.jobs(access: current).isEmpty)
    }

    @Test
    func scheduledPartsAreRetiredOnlyAfterTaskReconciliation() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: journal, access: current)
        let prepared = try await journal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let scheduled = try schedule(prepared, identifier: 17, journal: journal, access: current)
        let session = try serverSession(
            scheduled, id: try #require(scheduled.sessionId),
            clipId: UUID().uuidString, status: .open)

        #expect(scheduled.attempts.first?.state == .scheduled)
        #expect(scheduled.attempts.first?.taskIdentifier == 17)
        #expect(try journal.read(id: scheduled.id, access: current) == scheduled)
        for tasks in try [
            inventory(tasks: [17]),
            inventory(attempts: [attempt.id]),
            inventory(unidentified: true),
        ] {
            #expect(throws: OriginalUploadStorageError.busy) {
                try journal.retireAttempt(
                    for: scheduled, attemptId: attempt.id, session: session, tasks: tasks, access: current)
            }
            #expect(FileManager.default.fileExists(atPath: prepared.part.url.path))
        }
        var stored = scheduled
        stored.state = .stored
        #expect(throws: OriginalUploadStorageError.invalidRecord) {
            try journal.update(stored, access: current)
        }

        let retired = try journal.retireAttempt(
            for: scheduled, attemptId: attempt.id, session: session, tasks: inventory(), access: current)
        #expect(retired.attempts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: prepared.part.url.path))
        #expect(try journal.read(id: retired.id, access: current) == retired)
        #expect(throws: OriginalUploadStorageError.staleJob) {
            try schedule(prepared, identifier: 18, journal: journal, access: current)
        }
    }

    @Test
    func retirementWaitsForAnActivePartVerification() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (initialJournal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: initialJournal, access: current)
        let prepared = try await initialJournal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let session = try serverSession(
            prepared.job, id: try #require(prepared.job.sessionId),
            clipId: UUID().uuidString, status: .open)
        let started = AsyncStream<Void>.makeStream()
        let proceed = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); proceed.continuation.finish() }
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"),
            verifyPart: { url, number, expected in
                started.continuation.yield(())
                var iterator = proceed.stream.makeAsyncIterator()
                _ = await iterator.next()
                return try await OriginalUploadFiles.verifyPart(at: url, number: number, expected: expected)
            })
        let verification = Task {
            try await journal.readyPart(for: prepared.job, attemptId: attempt.id, access: current)
        }
        defer { verification.cancel() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()

        #expect(throws: OriginalUploadStorageError.busy) {
            try journal.retireAttempt(
                for: prepared.job, attemptId: attempt.id, session: session, tasks: inventory(), access: current)
        }
        #expect(FileManager.default.fileExists(atPath: prepared.part.url.path))
        proceed.continuation.yield(())
        _ = try await verification.value
        let retired = try journal.retireAttempt(
            for: prepared.job, attemptId: attempt.id, session: session, tasks: inventory(), access: current)
        #expect(retired.attempts.isEmpty)
    }

    @Test
    func schedulingInvalidatesAnEarlierTaskInventory() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (initialJournal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: initialJournal, access: current)
        let prepared = try await initialJournal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let session = try serverSession(
            prepared.job, id: try #require(prepared.job.sessionId),
            clipId: UUID().uuidString, status: .open)
        let fence = OriginalUploadTaskFence()
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"), taskFence: fence)
        #expect(journal.usesTaskFence(fence))
        #expect(!journal.usesTaskFence(OriginalUploadTaskFence()))
        let snapshot = fence.beginSnapshot()
        let stale = try inventory(fence: fence)
        var started = false
        let scheduled = try journal.scheduleReadyPart(
            for: prepared.job, attemptId: attempt.id, verifiedPart: prepared.part, access: current,
            createTask: { _ in (handle: 17, identifier: 17) },
            startTask: { _ in started = true }, cancelTask: { _ in })
        #expect(started)

        #expect(throws: OriginalUploadStorageError.busy) {
            try fence.inventory(
                snapshot: snapshot, taskIdentifiers: [], jobIDs: [], attemptIDs: [],
                hasUnidentifiedTasks: false)
        }
        #expect(throws: OriginalUploadStorageError.busy) {
            try journal.retireAttempt(
                for: scheduled, attemptId: attempt.id, session: session, tasks: stale, access: current)
        }
        #expect(FileManager.default.fileExists(atPath: prepared.part.url.path))
        let retired = try journal.retireAttempt(
            for: scheduled, attemptId: attempt.id, session: session,
            tasks: inventory(fence: fence), access: current)
        #expect(retired.attempts.isEmpty)
    }

    @Test
    func retirementAfterVerificationPreventsTaskCreation() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: journal, access: current)
        let prepared = try await journal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let verified = try await journal.readyPart(for: prepared.job, attemptId: attempt.id, access: current)
        let session = try serverSession(
            prepared.job, id: try #require(prepared.job.sessionId),
            clipId: UUID().uuidString, status: .open)
        _ = try journal.retireAttempt(
            for: prepared.job, attemptId: attempt.id, session: session, tasks: inventory(), access: current)
        var created = false

        #expect(throws: OriginalUploadStorageError.staleJob) {
            try journal.scheduleReadyPart(
                for: prepared.job, attemptId: attempt.id, verifiedPart: verified, access: current,
                createTask: { _ in created = true; return (handle: 17, identifier: 17) },
                startTask: { _ in }, cancelTask: { _ in })
        }
        #expect(!created)
    }

    @Test
    func durableCancellationPreventsAnAlreadyVerifiedPartFromStarting() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: journal, access: current)
        let prepared = try await journal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let verified = try await journal.readyPart(for: prepared.job, attemptId: attempt.id, access: current)
        let cancelled = try journal.requestCancellation(for: prepared.job, access: current)
        let recovered = try OriginalUploadJournal(directory: directory.appendingPathComponent("journal"))
            .read(id: cancelled.id, access: current)
        #expect(recovered.cancellationRequested)
        var created = false
        #expect(throws: OriginalUploadStorageError.cancellationRequested) {
            try journal.scheduleReadyPart(
                for: prepared.job, attemptId: attempt.id, verifiedPart: verified, access: current,
                createTask: { _ in created = true; return (handle: 17, identifier: 17) },
                startTask: { _ in }, cancelTask: { _ in })
        }
        #expect(throws: OriginalUploadStorageError.cancellationRequested) {
            try journal.scheduleReadyPart(
                for: cancelled, attemptId: attempt.id, verifiedPart: verified, access: current,
                createTask: { _ in created = true; return (handle: 17, identifier: 17) },
                startTask: { _ in }, cancelTask: { _ in })
        }
        #expect(!created)
        var reversed = cancelled
        reversed.cancellationRequested = false
        #expect(throws: OriginalUploadStorageError.immutableJobChanged) {
            try journal.update(reversed, access: current)
        }
    }

    @Test
    func cancellationAfterSchedulingRetainsThePartUntilTheTaskIsGone() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: journal, access: current)
        let prepared = try await journal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let scheduled = try schedule(prepared, identifier: 17, journal: journal, access: current)
        let cancelled = try journal.requestCancellation(for: scheduled, access: current)
        let session = try serverSession(
            cancelled, id: try #require(cancelled.sessionId),
            clipId: UUID().uuidString, status: .open)
        let recovered = try OriginalUploadJournal(directory: directory.appendingPathComponent("journal"))
            .read(id: cancelled.id, access: current)
        #expect(recovered.cancellationRequested)
        #expect(recovered.attempts.first?.taskIdentifier == 17)
        #expect(throws: OriginalUploadStorageError.busy) {
            try journal.retireAttempt(
                for: recovered, attemptId: attempt.id, session: session,
                tasks: inventory(tasks: [17], jobs: [recovered.id], attempts: [attempt.id]),
                access: current)
        }
        #expect(FileManager.default.fileExists(atPath: prepared.part.url.path))
        let retired = try journal.retireAttempt(
            for: recovered, attemptId: attempt.id, session: session, tasks: inventory(), access: current)
        #expect(retired.cancellationRequested)
        #expect(retired.attempts.isEmpty)
    }

    @Test
    func cancellationStillStopsKnownTasksWhenItsJournalWriteIsUncertain() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (initialJournal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: initialJournal, access: current)
        let prepared = try await initialJournal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let fence = OriginalUploadTaskFence()
        let probe = SynchronizationProbe { directory in
            let url = directory.appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: url),
                  let job = try? JSONDecoder().decode(OriginalUploadJob.self, from: data) else {
                return false
            }
            return job.cancellationRequested
        }
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"),
            synchronizeDirectory: probe.synchronize, taskFence: fence)
        let scope = try OriginalUploadJournal.scopeIdentifier(current.scope)
        let known = OriginalBackgroundTaskSnapshot(
            identifier: 17,
            tag: OriginalBackgroundTaskTag(
                scope: scope, jobId: prepared.job.id,
                jobIncarnation: prepared.job.incarnation, attemptId: attempt.id))
        let unknown = OriginalBackgroundTaskSnapshot(identifier: 18, tag: nil)
        var cancelled: [Int] = []
        await #expect(throws: OriginalUploadStorageError.durabilityUncertain) {
            try await OriginalBackgroundCancellation.request(
                for: prepared.job, journal: journal, fence: fence, access: current,
                tasks: { [known, unknown] }, snapshot: { $0 },
                cancel: { cancelled.append($0.identifier) })
        }
        #expect(cancelled == [17])
        var created = false
        #expect(throws: OriginalUploadStorageError.cancellationRequested) {
            try journal.scheduleReadyPart(
                for: prepared.job, attemptId: attempt.id, verifiedPart: prepared.part, access: current,
                createTask: { _ in created = true; return (handle: 19, identifier: 19) },
                startTask: { _ in }, cancelTask: { _ in })
        }
        #expect(!created)
        #expect(FileManager.default.fileExists(atPath: prepared.part.url.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationStillStopsKnownTasksWhenInventoryBecomesStale() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (initialJournal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: initialJournal, access: current)
        let prepared = try await initialJournal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let fence = OriginalUploadTaskFence()
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"), taskFence: fence)
        let otherSource = directory.appendingPathComponent("other.mov")
        try Data("other original".utf8).write(to: otherSource)
        let other = try await journal.prepare(
            id: UUID(), source: otherSource, fileName: "other.mov", metadata: metadata,
            photoIdentifier: nil, transcribe: false, access: current)
        let otherRunning = try uploading(other, journal: journal, access: current)
        let otherPart = try await journal.preparePart(for: otherRunning, number: 1, access: current)
        let scope = try OriginalUploadJournal.scopeIdentifier(current.scope)
        let known = OriginalBackgroundTaskSnapshot(
            identifier: 17,
            tag: OriginalBackgroundTaskTag(
                scope: scope, jobId: prepared.job.id,
                jobIncarnation: prepared.job.incarnation, attemptId: attempt.id))
        let unknown = OriginalBackgroundTaskSnapshot(identifier: 18, tag: nil)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish() }
        var cancelled: [Int] = []
        let cancellation = Task {
            try await OriginalBackgroundCancellation.request(
                for: prepared.job, journal: journal, fence: fence, access: current,
                tasks: {
                    entered.continuation.yield()
                    var iterator = release.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    return [known, unknown]
                }, snapshot: { $0 }, cancel: { cancelled.append($0.identifier) })
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        _ = try schedule(otherPart, identifier: 19, journal: journal, access: current)
        release.continuation.yield()
        await #expect(throws: OriginalUploadStorageError.busy) { try await cancellation.value }
        #expect(cancelled == [17])
        let saved = try journal.read(id: prepared.job.id, access: current)
        #expect(saved.cancellationRequested)
        let retried = try await OriginalBackgroundCancellation.request(
            for: saved, journal: journal, fence: fence, access: current,
            tasks: { [known, unknown] }, snapshot: { $0 },
            cancel: { cancelled.append($0.identifier) })
        #expect(retried.requestedTaskIdentifiers == [17])
        #expect(retried.hasUnidentifiedTasks)
        #expect(cancelled == [17, 17])
    }

    @Test
    func staleCancellationCannotStopAReplacementWithTheSameRequestID() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, old) = try await prepare(directory: directory, access: current)
        try journal.removeUnstarted(old, access: current)
        let replacement = try await journal.prepare(
            id: old.id, source: directory.appendingPathComponent("selected.mov"),
            fileName: "selected.mov", metadata: metadata, photoIdentifier: "photo-1",
            transcribe: true, access: current)
        #expect(replacement.incarnation != old.incarnation)
        let running = try uploading(replacement, journal: journal, access: current)
        let prepared = try await journal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let task = OriginalBackgroundTaskSnapshot(
            identifier: 17,
            tag: OriginalBackgroundTaskTag(
                scope: try OriginalUploadJournal.scopeIdentifier(current.scope),
                jobId: replacement.id, jobIncarnation: replacement.incarnation, attemptId: attempt.id))
        var cancelled: [Int] = []
        await #expect(throws: OriginalUploadStorageError.staleJob) {
            try await OriginalBackgroundCancellation.request(
                for: old, journal: journal, fence: .shared, access: current,
                tasks: { [task] }, snapshot: { $0 }, cancel: { cancelled.append($0.identifier) })
        }
        #expect(cancelled.isEmpty)
        var started = false
        let scheduled = try journal.scheduleReadyPart(
            for: prepared.job, attemptId: attempt.id, verifiedPart: prepared.part, access: current,
            createTask: { _ in (handle: 17, identifier: 17) },
            startTask: { _ in started = true }, cancelTask: { _ in })
        #expect(started)
        #expect(!scheduled.cancellationRequested)
    }

    @Test
    func uncertainTaskRecordingCancelsTheTaskBeforeItStarts() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (initialJournal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: initialJournal, access: current)
        let prepared = try await initialJournal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let probe = SynchronizationProbe { directory in
            let url = directory.appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: url),
                  let job = try? JSONDecoder().decode(OriginalUploadJob.self, from: data) else {
                return false
            }
            return job.attempts.contains { $0.state == .scheduled }
        }
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"),
            synchronizeDirectory: probe.synchronize)
        var started = false
        var cancelled = false

        #expect(throws: OriginalUploadStorageError.durabilityUncertain) {
            try journal.scheduleReadyPart(
                for: prepared.job, attemptId: attempt.id, verifiedPart: prepared.part, access: current,
                createTask: { _ in (handle: 17, identifier: 17) },
                startTask: { _ in started = true }, cancelTask: { _ in cancelled = true })
        }
        #expect(!started)
        #expect(cancelled)
        let recovered = try journal.read(id: prepared.job.id, access: current)
        #expect(recovered.attempts.first?.state == .scheduled)
        #expect(FileManager.default.fileExists(atPath: prepared.part.url.path))
    }

    @Test
    func cancelledSchedulingDoesNotCreateATask() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: journal, access: current)
        let prepared = try await journal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let entered = AsyncStream<Void>.makeStream()
        let proceed = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); proceed.continuation.finish() }
        var created = false
        let task = Task {
            entered.continuation.yield(())
            var iterator = proceed.stream.makeAsyncIterator()
            _ = await iterator.next()
            return try journal.scheduleReadyPart(
                for: prepared.job, attemptId: attempt.id, verifiedPart: prepared.part, access: current,
                createTask: { _ in created = true; return (handle: 17, identifier: 17) },
                startTask: { _ in }, cancelTask: { _ in })
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        proceed.continuation.yield(())

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!created)
        #expect(try journal.read(id: prepared.job.id, access: current) == prepared.job)
    }

    @Test
    func cancellationAfterTaskRecordingCancelsWithoutStarting() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (initialJournal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: initialJournal, access: current)
        let prepared = try await initialJournal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        var injected = false
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"),
            synchronizeDirectory: { directory in
                try DurableFile.synchronize(directory, directory: true)
                guard !injected,
                      let data = try? Data(contentsOf: directory.appendingPathComponent("job.json")),
                      let job = try? JSONDecoder().decode(OriginalUploadJob.self, from: data),
                      job.attempts.contains(where: { $0.state == .scheduled }) else { return }
                injected = true
                withUnsafeCurrentTask { $0?.cancel() }
            })
        var started = false
        var cancelled = false
        let task = Task {
            try journal.scheduleReadyPart(
                for: prepared.job, attemptId: attempt.id, verifiedPart: prepared.part, access: current,
                createTask: { _ in (handle: 17, identifier: 17) },
                startTask: { _ in started = true }, cancelTask: { _ in cancelled = true })
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(injected)
        #expect(!started)
        #expect(cancelled)
        let recovered = try journal.read(id: prepared.job.id, access: current)
        #expect(recovered.attempts.first?.state == .scheduled)
    }

    @Test
    func interruptedRetirementIsRecordedAndCanFinishAfterRelaunch() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (initialJournal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: initialJournal, access: current)
        let prepared = try await initialJournal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let session = try serverSession(
            prepared.job, id: try #require(prepared.job.sessionId),
            clipId: UUID().uuidString, status: .open)
        let probe = SynchronizationProbe { parent in
            parent.resolvingSymlinksInPath() == prepared.part.url.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                && !FileManager.default.fileExists(atPath: prepared.part.url.path)
        }
        let journal = OriginalUploadJournal(
            directory: directory.appendingPathComponent("journal"),
            synchronizeDirectory: probe.synchronize)

        #expect(throws: OriginalUploadStorageError.cleanupFailed) {
            try journal.retireAttempt(
                for: prepared.job, attemptId: attempt.id, session: session, tasks: inventory(), access: current)
        }
        #expect(probe.failedURL != nil)
        #expect(!FileManager.default.fileExists(atPath: prepared.part.url.path))
        let relaunched = OriginalUploadJournal(directory: directory.appendingPathComponent("journal"))
        let recovered = try relaunched.read(id: prepared.job.id, access: current)
        #expect(recovered.attempts.first?.state == .retiring)
        let retired = try relaunched.retireAttempt(
            for: recovered, attemptId: attempt.id, session: session, tasks: inventory(), access: current)
        #expect(retired.attempts.isEmpty)
    }

    @Test
    func endedSessionCanBeReplacedOnlyAfterItsAttemptsAndTasksDrain() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: journal, access: current)
        let prepared = try await journal.preparePart(for: running, number: 1, access: current)
        let attempt = try #require(prepared.job.attempts.first)
        let scheduled = try schedule(prepared, identifier: 23, journal: journal, access: current)
        let clipId = UUID().uuidString
        let ended = try serverSession(
            scheduled, id: try #require(scheduled.sessionId), clipId: clipId, status: .expired,
            parts: [OriginalUploadServerPart(
                partNumber: 1, sizeBytes: String(scheduled.manifest.parts[0].byteCount),
                sha256: String(repeating: "b", count: 64))])
        let replacement = try serverSession(
            scheduled, id: UUID().uuidString, clipId: clipId, status: .open)

        #expect(throws: OriginalUploadStorageError.busy) {
            try journal.replaceEndedSession(
                for: scheduled, previous: ended, replacement: replacement, tasks: inventory(), access: current)
        }
        let retired = try journal.retireAttempt(
            for: scheduled, attemptId: attempt.id, session: ended, tasks: inventory(), access: current)
        for tasks in try [inventory(jobs: [retired.id]), inventory(unidentified: true)] {
            #expect(throws: OriginalUploadStorageError.busy) {
                try journal.replaceEndedSession(
                    for: retired, previous: ended, replacement: replacement, tasks: tasks, access: current)
            }
        }
        let replaced = try journal.replaceEndedSession(
            for: retired, previous: ended, replacement: replacement, tasks: inventory(), access: current)
        #expect(replaced.sessionId == replacement.id)
        #expect(replaced.assetId == running.assetId)
        #expect(try journal.read(id: replaced.id, access: current) == replaced)
    }

    @Test
    func callerChosenPreparationIdentityCannotCreateADuplicateJob() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let source = directory.appendingPathComponent("source")
        try Data("video".utf8).write(to: source)
        let journal = OriginalUploadJournal(directory: directory.appendingPathComponent("journal"))
        let id = UUID()
        let job = try await journal.prepare(
            id: id, source: source, fileName: "video.mov", metadata: metadata,
            photoIdentifier: nil, transcribe: false, access: current)
        await #expect(throws: OriginalUploadStorageError.jobAlreadyExists) {
            try await journal.prepare(
                id: id, source: source, fileName: "video.mov", metadata: metadata,
                photoIdentifier: nil, transcribe: false, access: current)
        }
        #expect(try journal.read(id: id, access: current) == job)
        #expect(try journal.jobs(access: current) == [job])
    }

    @Test
    func rejectsStaleAndRegressiveStateUpdates() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, initial) = try await prepare(directory: directory, access: current)
        let running = try uploading(initial, journal: journal, access: current)
        #expect(throws: OriginalUploadStorageError.staleJob) {
            try journal.update(initial, access: current)
        }
        var replaced = running
        replaced.sessionId = UUID().uuidString
        #expect(throws: OriginalUploadStorageError.immutableJobChanged) {
            try journal.update(replaced, access: current)
        }
        var stored = running
        stored.state = .stored
        stored = try journal.update(stored, access: current)
        var regressed = stored
        regressed.state = .uploading
        #expect(throws: OriginalUploadStorageError.immutableJobChanged) {
            try journal.update(regressed, access: current)
        }
        #expect(throws: OriginalUploadStorageError.busy) {
            try journal.removeUnstarted(stored, access: current)
        }
    }

    @Test
    func rejectsStaleAccessAndDoesNotReadAnotherScope() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let auth = auth()
        let current = try access(auth)
        let (journal, job) = try await prepare(directory: directory, access: current)
        #expect(throws: (any Error).self) {
            try journal.read(id: job.id, access: access("other-user"))
        }
        auth.logout()
        #expect(throws: OriginalUploadStorageError.invalidScope) {
            try journal.read(id: job.id, access: current)
        }
        #expect(throws: OriginalUploadStorageError.invalidScope) {
            try journal.update(job, access: current)
        }
        #expect(throws: OriginalUploadStorageError.invalidScope) {
            try journal.originalURL(for: job, access: current)
        }
        #expect(throws: OriginalUploadStorageError.invalidScope) {
            try journal.removeUnstarted(job, access: current)
        }
    }

    @Test
    func rejectsSymlinkedSourceAndExclusiveDestinationReuse() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let source = directory.appendingPathComponent("source")
        let link = directory.appendingPathComponent("link")
        let output = directory.appendingPathComponent("original")
        try Data("video".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: OriginalUploadStorageError.invalidFile) {
            try await OriginalUploadFiles.stage(source: link, destination: output)
        }
        try Data("existing".utf8).write(to: output)
        await #expect(throws: (any Error).self) {
            try await OriginalUploadFiles.stage(source: source, destination: output)
        }
        #expect(try Data(contentsOf: output) == Data("existing".utf8))
    }

    @Test
    func removesOnlyAbandonedPreparations() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, job) = try await prepare(directory: directory, access: current)
        let original = try journal.originalURL(for: job, access: current)
        let scopeDirectory = original.deletingLastPathComponent().deletingLastPathComponent()
        let abandoned = scopeDirectory.appendingPathComponent("preparing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: abandoned.appendingPathComponent("original"))

        #expect(try journal.jobs(access: current) == [job])
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test
    func cleansUncommittedJournalFilesWithoutChangingTheCommittedRecord() async throws {
        let directory = try fixture()
        defer { cleanup(directory) }
        let current = try access()
        let (journal, job) = try await prepare(directory: directory, access: current)
        let original = try journal.originalURL(for: job, access: current)
        let staged = original.deletingLastPathComponent()
            .appendingPathComponent("job-update-\(UUID().uuidString).tmp")
        try Data("unfinished".utf8).write(to: staged)
        #expect(try journal.read(id: job.id, access: current) == job)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }
}
