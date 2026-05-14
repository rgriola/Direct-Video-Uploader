// May 14, 2026 - 2:50pm - GitHub Copilot (Claude Opus 4.7)
// Extracted from VideoUploadService.swift (Priority 4: persistence isolation).
// Includes the queue store + its core data model (PersistedUploadTask + UploadTaskLifecycleState).
// `UploadTaskMetricsSummary` (parameter type on markTelemetry) intentionally remains in
// VideoUploadService.swift — it is upload-engine output, not persistence schema.
import Foundation

// MARK: - Lifecycle State

enum UploadTaskLifecycleState: String, Codable {
    case pending
    case running
    case completed
    case failed
}

// MARK: - Persisted Task Record

struct PersistedUploadTask: Codable, Equatable {
    var localUploadId: String
    var assetId: String
    var fileURL: URL
    var remoteUploadURL: URL
    var taskIdentifier: Int?
    var state: UploadTaskLifecycleState
    var errorMessage: String?
    var retries: Int
    var createdAt: Date
    var updatedAt: Date
    var queueWaitMs: Int? = nil
    var transferDurationMs: Int? = nil
    var telemetryUpdatedAt: Date? = nil
    var telemetryCorrelationId: String? = nil
    var serverUploadCreatedAtMs: Int? = nil
    var metricsTotalDurationMs: Int? = nil
    var metricsNetworkProtocol: String? = nil
    var metricsIsCellular: Bool? = nil
}

// MARK: - Queue Store

enum UploadQueueStore {
    private static let fileName = "upload-queue-state.json"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storageURLOverride: URL?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static var storageURL: URL {
        if let storageURLOverride {
            return storageURLOverride
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName)
    }

    static func all() -> [PersistedUploadTask] {
        lock.withLock {
            loadUnsafe()
        }
    }

    static func upsert(_ task: PersistedUploadTask) {
        lock.withLock {
            var tasks = loadUnsafe()
            if let index = tasks.firstIndex(where: { $0.localUploadId == task.localUploadId }) {
                tasks[index] = task
            } else {
                tasks.append(task)
            }
            saveUnsafe(tasks)
        }
    }

    static func markState(
        localUploadId: String,
        state: UploadTaskLifecycleState,
        errorMessage: String? = nil,
        taskIdentifier: Int? = nil,
        retries: Int? = nil
    ) {
        lock.withLock {
            var tasks = loadUnsafe()
            guard let index = tasks.firstIndex(where: { $0.localUploadId == localUploadId }) else {
                return
            }
            tasks[index].state = state
            tasks[index].errorMessage = errorMessage
            if let taskIdentifier {
                tasks[index].taskIdentifier = taskIdentifier
            }
            if let retries {
                tasks[index].retries = retries
            }
            tasks[index].updatedAt = Date()
            saveUnsafe(tasks)
        }
    }

    static func markTelemetry(
        localUploadId: String,
        queueWaitMs: Int?,
        transferDurationMs: Int?,
        retries: Int? = nil,
        correlationId: String? = nil,
        serverUploadCreatedAtMs: Int? = nil,
        taskMetrics: UploadTaskMetricsSummary? = nil
    ) {
        lock.withLock {
            var tasks = loadUnsafe()
            guard let index = tasks.firstIndex(where: { $0.localUploadId == localUploadId }) else {
                return
            }

            tasks[index].queueWaitMs = queueWaitMs
            tasks[index].transferDurationMs = transferDurationMs
            tasks[index].telemetryUpdatedAt = Date()
            if let correlationId {
                tasks[index].telemetryCorrelationId = correlationId
            }
            if let serverUploadCreatedAtMs {
                tasks[index].serverUploadCreatedAtMs = serverUploadCreatedAtMs
            }
            if let taskMetrics {
                tasks[index].metricsTotalDurationMs = taskMetrics.totalDurationMs
                tasks[index].metricsNetworkProtocol = taskMetrics.networkProtocolName
                tasks[index].metricsIsCellular = taskMetrics.isCellular
            }
            if let retries {
                tasks[index].retries = retries
            }
            tasks[index].updatedAt = Date()
            saveUnsafe(tasks)
        }
    }

    static func remove(localUploadId: String) {
        lock.withLock {
            var tasks = loadUnsafe()
            tasks.removeAll { $0.localUploadId == localUploadId }
            saveUnsafe(tasks)
        }
    }

    @discardableResult
    static func reconcile(activeTaskIdentifiers: Set<Int>) -> [PersistedUploadTask] {
        lock.withLock {
            var tasks = loadUnsafe()
            var changed = false

            for index in tasks.indices {
                guard tasks[index].state == .running else { continue }
                guard let taskIdentifier = tasks[index].taskIdentifier else {
                    tasks[index].state = .failed
                    tasks[index].errorMessage = "Missing task identifier during reconciliation"
                    tasks[index].updatedAt = Date()
                    changed = true
                    continue
                }

                if !activeTaskIdentifiers.contains(taskIdentifier) {
                    tasks[index].state = .failed
                    tasks[index].errorMessage = "Upload task missing during reconciliation"
                    tasks[index].updatedAt = Date()
                    changed = true
                }
            }

            if changed {
                saveUnsafe(tasks)
            }
            return tasks
        }
    }

    static func setStorageURLForTesting(_ storageURL: URL?) {
        lock.withLock {
            storageURLOverride = storageURL
        }
    }

    static func clearAllForTesting() {
        lock.withLock {
            saveUnsafe([])
        }
    }

    private static func loadUnsafe() -> [PersistedUploadTask] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        return (try? decoder.decode([PersistedUploadTask].self, from: data)) ?? []
    }

    private static func saveUnsafe(_ tasks: [PersistedUploadTask]) {
        do {
            let data = try encoder.encode(tasks)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            AppLog.persistence.warning(
                "[UploadQueueStore] Failed to persist queue state: \(error.localizedDescription)")
        }
    }
}
