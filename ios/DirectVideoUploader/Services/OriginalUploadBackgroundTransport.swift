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
    private struct StoredEvent: Codable {
        let sequence: UInt64
        let event: OriginalBackgroundCompletion
    }

    private let directory: URL
    private let synchronizeDirectory: (URL) throws -> Void

    init(
        directory: URL,
        synchronizeDirectory: @escaping (URL) throws -> Void = {
            try DurableFile.synchronize($0, directory: true)
        }
    ) {
        self.directory = directory.standardizedFileURL
        self.synchronizeDirectory = synchronizeDirectory
    }

    func persist(_ event: OriginalBackgroundCompletion) throws {
        guard event.isValid else { throw OriginalUploadStorageError.invalidRecord }
        try prepare()
        let destination = eventURL(event.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try read(destination).event == event else { throw OriginalUploadStorageError.invalidRecord }
            try synchronizeDirectory(directory)
            return
        }
        let records = try readRecords()
        let (sequence, overflow) = (records.last?.sequence ?? 0).addingReportingOverflow(1)
        guard !overflow else { throw OriginalUploadStorageError.invalidRecord }
        let staged = directory.appendingPathComponent("event-update-\(UUID().uuidString).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var created = false
        var published = false
        do {
            try OriginalUploadFiles.writeProtected(
                encoder.encode(StoredEvent(sequence: sequence, event: event)), to: staged)
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
                Log.error("Could not synchronize a background upload event: \(Log.describe(error))", logger: Log.upload)
                throw OriginalUploadStorageError.durabilityUncertain
            }
            if created { try OriginalUploadFiles.removeOwnedItem(staged) }
            throw operationError
        }
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
        let destination = eventURL(event.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try read(destination).event == event else { throw OriginalUploadStorageError.invalidRecord }
        }
        try OriginalUploadFiles.removeOwnedItem(destination, synchronizeDirectory: synchronizeDirectory)
    }

    private func readRecords() throws -> [StoredEvent] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var result: [StoredEvent] = []
        var sequences: Set<UInt64> = []
        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix("event-update-"), name.hasSuffix(".tmp"),
               UUID(uuidString: String(name.dropFirst("event-update-".count).dropLast(4))) != nil {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw OriginalUploadStorageError.invalidRecord
                }
                try OriginalUploadFiles.removeOwnedItem(file, synchronizeDirectory: synchronizeDirectory)
                continue
            }
            guard name.hasPrefix("event-"), name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropFirst("event-".count).dropLast(5))) else {
                throw OriginalUploadStorageError.invalidRecord
            }
            let record = try read(file)
            guard record.event.id == id, sequences.insert(record.sequence).inserted else {
                throw OriginalUploadStorageError.invalidRecord
            }
            result.append(record)
        }
        return result.sorted { $0.sequence < $1.sequence }
    }

    private func prepare() throws {
        try OriginalUploadFiles.createProtectedDirectory(directory, synchronizeDirectory: synchronizeDirectory)
    }

    private func eventURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("event-\(id.uuidString).json")
    }

    private func read(_ url: URL) throws -> StoredEvent {
        let record = try JSONDecoder().decode(StoredEvent.self, from: OriginalUploadFiles.readJournal(url))
        guard record.sequence > 0, record.event.isValid else { throw OriginalUploadStorageError.invalidRecord }
        return record
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
        try inbox.remove(event)
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
