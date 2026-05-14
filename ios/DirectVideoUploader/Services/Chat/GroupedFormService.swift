// May 14, 2026 - 1:35pm - GitHub Copilot (Claude Opus 4.7)
import Foundation

@MainActor
final class GroupedFormService {
    enum DebugEvent {
        case attempt
        case suppressedFormRequest
        case success
        case failure
    }

    private static let debugTruthyValues: Set<String> = ["1", "true", "yes", "on"]
    private var submitAttemptCountByAssetId: [String: Int] = [:]

    func resetSubmitAttempts() {
        submitAttemptCountByAssetId.removeAll()
    }

    func buildSequencedFormData(
        for assetId: String,
        pendingBatchFormData: [String: String]?,
        batchItems: [VideoBatchItem]
    ) -> [String: String]? {
        guard var formData = pendingBatchFormData else { return nil }
        guard batchItems.count > 1 else { return formData }
        guard let itemIndex = batchItems.firstIndex(where: { $0.assetId == assetId }) else {
            return formData
        }

        let sequenceNumber = itemIndex + 1
        let baseTitle = (formData["slug"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseTitle.isEmpty {
            formData["slug"] = makeSequencedTitle(
                baseTitle: baseTitle,
                sequenceNumber: sequenceNumber
            )
        }

        return formData
    }

    func logSubmitDebug(
        assetId: String,
        event: DebugEvent,
        formData: [String: String]? = nil,
        statusCode: Int? = nil,
        error: Error? = nil
    ) {
        guard isSubmitDebugEnabled else { return }

        switch event {
        case .attempt:
            let nextAttempt = (submitAttemptCountByAssetId[assetId] ?? 0) + 1
            submitAttemptCountByAssetId[assetId] = nextAttempt
            let slug = formData?["slug"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            AppLog.chat.debug(
                "[GroupedFormDebug] submit attempt #\(nextAttempt) assetId=\(assetId) slug=\"\(slug)\""
            )

        case .suppressedFormRequest:
            let attempts = submitAttemptCountByAssetId[assetId] ?? 0
            AppLog.chat.debug(
                "[GroupedFormDebug] ws form:request suppressed assetId=\(assetId) attempts=\(attempts)"
            )

        case .success:
            let attempts = submitAttemptCountByAssetId[assetId] ?? 0
            let status = statusCode.map(String.init) ?? "n/a"
            AppLog.chat.debug(
                "[GroupedFormDebug] submit success assetId=\(assetId) attempt=\(attempts) status=\(status)"
            )

        case .failure:
            let attempts = submitAttemptCountByAssetId[assetId] ?? 0
            let status = statusCode.map(String.init) ?? "n/a"
            let reason = error?.localizedDescription ?? "unknown"
            AppLog.chat.warning(
                "[GroupedFormDebug] submit failure assetId=\(assetId) attempt=\(attempts) status=\(status) error=\(reason)"
            )
        }
    }

    func submitPayload(
        assetId: String,
        formData: [String: String],
        auth: AuthService,
        api: APIClient = .shared,
        isConnectivityIssue: (Error) -> Bool,
        clearBlockingConnectivityIssue: (String?) -> Void,
        noteBlockingConnectivityIssue: (String, String?) -> Void,
        reportFailure: @escaping (String) async -> Void
    ) async -> Bool {
        logSubmitDebug(assetId: assetId, event: .attempt, formData: formData)

        let request = auth.authenticatedRequest(for: ServerConfig.formURL(assetId), method: "POST")

        do {
            let (_, statusCode) = try await api.sendJSONObject(request, body: formData)
            logSubmitDebug(assetId: assetId, event: .success, statusCode: statusCode)
            clearBlockingConnectivityIssue(assetId)
            return true
        } catch {
            let statusCode = (error as? APIError)?.statusCode
            logSubmitDebug(
                assetId: assetId,
                event: .failure,
                statusCode: statusCode,
                error: error
            )

            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue("applying grouped form", assetId)
            }

            await reportFailure(error.localizedDescription)
            return false
        }
    }

    private var isSubmitDebugEnabled: Bool {
        #if DEBUG
            if let envRaw = ProcessInfo.processInfo.environment["DVU_DEBUG_GROUPED_FORM_SUBMITS"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !envRaw.isEmpty
            {
                return Self.debugTruthyValues.contains(envRaw)
            }
            return UserDefaults.standard.bool(forKey: UserDefaultsKeys.debugGroupedFormSubmits)
        #else
            return false
        #endif
    }

    private func makeSequencedTitle(baseTitle: String, sequenceNumber: Int) -> String {
        let trimmed = baseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")

        if parts.count > 1, let trailingNumber = Int(parts.last ?? ""), trailingNumber > 0 {
            let root = parts.dropLast().joined(separator: " ")
            return "\(root) \(sequenceNumber)"
        }

        return "\(trimmed) \(sequenceNumber)"
    }
}
