import Foundation
import Synchronization
import Testing
@testable import DirectVideoUploader

@MainActor
struct OriginalUploadBackgroundTransportTests {
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
            if shouldFail && directory == inboxDirectory.resolvingSymlinksInPath()
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
        try inbox.remove(value)
        #expect(try inbox.events().isEmpty)
    }
}
