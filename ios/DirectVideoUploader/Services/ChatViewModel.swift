// May 10, 2026 - 3:07pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation
import Observation
import Photos
import UIKit

nonisolated struct ScopedUploadAsset: Hashable, Sendable {
    let scope: PendingFormScope
    let assetId: String
}

@MainActor
@Observable
final class FormPresentationState {
    enum Tab: Hashable {
        case chat, archive, photos, profile
    }

    var selectedTab = Tab.chat {
        didSet {
            if selectedTab != oldValue { generation = UUID() }
        }
    }
    var archiveFormVisible = false {
        didSet {
            if archiveFormVisible != oldValue { generation = UUID() }
        }
    }
    var pendingFormProtectionWarning = false {
        didSet {
            if pendingFormProtectionWarning != oldValue { generation = UUID() }
        }
    }
    var isSceneActive: Bool {
        didSet {
            if isSceneActive != oldValue { generation = UUID() }
        }
    }
    private(set) var generation = UUID()
    var completedDetailsAssetIDs: Set<String> = []
    var photoAssociatedAssetIDs: Set<String> = []
    private(set) var activeChatUploads: [ScopedUploadAsset: UUID] = [:]
    private(set) var failedChatUploadAssetIDs: Set<String> = []
    private var uploadRecoveryRevisions: [String: Int] = [:]
    private var startedUploadStageIDs: Set<UUID> = []

    init(isSceneActive: Bool = true) {
        self.isSceneActive = isSceneActive
    }

    var canPresentChatForm: Bool {
        selectedTab == .chat && isSceneActive
            && !archiveFormVisible && !pendingFormProtectionWarning
    }

    func canPresentInChat(isSceneActive: Bool) -> Bool {
        canPresentChatForm && isSceneActive
    }

    func beginChatUpload(assetId: String, scope: PendingFormScope, uploadID: UUID) {
        activeChatUploads[ScopedUploadAsset(scope: scope, assetId: assetId)] = uploadID
        failedChatUploadAssetIDs.remove(assetId)
    }

    func finishChatUpload(
        assetId: String, scope: PendingFormScope, uploadID: UUID, failed: Bool
    ) {
        let key = ScopedUploadAsset(scope: scope, assetId: assetId)
        guard activeChatUploads[key] == uploadID else { return }
        activeChatUploads[key] = nil
        if failed { failedChatUploadAssetIDs.insert(assetId) }
    }

    func isChatUploading(assetId: String, scope: PendingFormScope?) -> Bool {
        guard let scope else { return false }
        return activeChatUploads[ScopedUploadAsset(scope: scope, assetId: assetId)] != nil
    }

    func clearChatUploadFailure(assetId: String) {
        failedChatUploadAssetIDs.remove(assetId)
    }

    func clearChatUploadFailures() {
        failedChatUploadAssetIDs.removeAll()
    }

    func uploadRecoveryRevision(for assetId: String) -> Int {
        uploadRecoveryRevisions[assetId, default: 0]
    }

    func markUploadRecovered(assetId: String) {
        uploadRecoveryRevisions[assetId, default: 0] += 1
        clearChatUploadFailure(assetId: assetId)
    }

    func markUploadStarted(stageID: UUID) {
        startedUploadStageIDs.insert(stageID)
    }

    func clearUploadRecoveryState() {
        uploadRecoveryRevisions.removeAll()
        startedUploadStageIDs.removeAll()
    }

    func shouldAnnounceRecoveryNotice(
        code: String?, assetId: String?, params: [String: String]? = nil
    ) -> Bool {
        if code == "IOS_UPLOAD_START_FAILED" || code == "IOS_PREVIOUS_UPLOAD_START_FAILED",
           let stageID = params?["stageId"].flatMap(UUID.init(uuidString:)),
           startedUploadStageIDs.contains(stageID) {
            return false
        }
        guard let assetId else { return true }
        switch code {
        case "IOS_PENDING_FORM_IN_ARCHIVE", "IOS_PENDING_FORM_SAVE_FAILED":
            return !completedDetailsAssetIDs.contains(assetId)
        case "IOS_UPLOAD_FAILED", "IOS_PREVIOUS_UPLOAD_FAILED":
            let revision = params?["uploadRevision"].flatMap(Int.init) ?? 0
            return uploadRecoveryRevision(for: assetId) == revision
        case "IOS_PHOTO_ASSOCIATION_SAVE_FAILED", "IOS_PREVIOUS_PHOTO_ASSOCIATION_SAVE_FAILED":
            return !photoAssociatedAssetIDs.contains(assetId)
        default:
            return true
        }
    }
}

/// Metadata for a sent-upload card, cached by message ID.
struct SentUploadInfo {
    let thumbnail: UIImage?
    let fileName: String
    let createdDate: String
    let hasLocation: Bool
    let transcribeEnabled: Bool
}

/// Metadata cached after mux:ready for Slack sharing and summary bubble.
struct ArchiveState {
    var assetId: String?
    var mediasourceId: String?
    var mediasourceUrl: String?
    var originalFileName: String?
    var formSlug: String?
    var duration: Int?
    var resolution: String?
    var fileSize: String?
}

/// Context passed to ContextFormView header.
struct FormContext {
    var originalFileName: String?
    var capturedAt: String?
    var clipCount: Int?
    var duration: Int?
    var thumbnail: UIImage?
    var submitError: String?
}

/// Central chat view model — manages messages, assets, and coordinates services.
@MainActor
@Observable
final class ChatViewModel {
    // MARK: - State

    var messages: [ChatMessage] = []
    var currentAssetId: String?
    var showFormSheet = false
    private(set) var formAssetId: String?
    var showMetadataSheet = false
    var formFields: [FormField] = []
    var uploadProgress: Double = 0
    var isUploading = false
    var lastClip: Clip?
    var lastAsset: Asset?

    // Staged video — preview before upload (iOS 26.3 flow)
    var stagedVideo: StagedVideo?
    private(set) var stagedUploadPreparation: StagedUploadPreparation = .ready
    var isProcessingVideo = false
    private(set) var isSelectingVideo = false

    // Archive state — conversation closed after mux:ready or new upload
    var isArchived = false
    var showSlackShareSheet = false
    var archive = ArchiveState()

    // Form context (passed to ContextFormView header)
    var form = FormContext()

    /// Metadata for sent-upload cards, keyed by message ID
    var sentUploads: [String: SentUploadInfo] = [:]

    /// Cached thumbnails for Slack confirmation bubbles, keyed by message ID
    var slackThumbnails: [String: UIImage] = [:]

    /// IDs of outgoing Slack messages that have been confirmed by the server
    var slackConfirmedIds: Set<String> = []

    private var stagingTask: Task<Void, Never>?
    private var stagingGeneration: UUID?
    private var stagingFileURL: URL?
    private var preparationAttempts: [UUID: UUID] = [:]
    private var preparationTasks: [UUID: (attempt: UUID, task: Task<Void, Never>)] = [:]
    private var leasedStagedFiles: Set<UUID> = []
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private var activeUploadID: UUID?
    private var pendingAssetCreation: UUID?
    private var uploadFailuresToPreserve: [ChatMessage] = []
    private let messagePolicy = MessagePolicyCoordinator()
    private let sessionScope: PendingFormScope?
    private let sessionServerURL: URL
    private let sessionToken: String?
    private let sessionGeneration: UUID
    private let pendingFormStore: PendingFormStore
    private let pendingFormRecovery: PendingFormRecovery
    private let pendingFormSubmission: PendingFormSubmission
    private let httpTransport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let thumbnailGenerator: @Sendable (URL) async -> UIImage?
    private let photoAssociationStore: ScopedPHAssetIdentifierStore
    private let requestPhotoAddAccess: @Sendable () async -> Bool
    private let saveTrimToPhotos: @Sendable (URL, String, VideoMetadata) async throws -> String?
    private let fingerprintVideo: @Sendable (URL) async throws -> VideoContentFingerprint
    private var activePendingRecord: PendingFormRecord?
    private var activeFormGeneration = UUID() {
        didSet {
            if activeFormGeneration != oldValue { cancelStalePendingFormRecovery() }
        }
    }
    private var submittingFormGeneration: UUID?
    private var pendingRecoveryTask: Task<Void, Never>?
    private var pendingRecoveryID: UUID?
    private var pendingRecoveryKey: RecoveryKey?
    private var retryPendingFormRecovery = false
    private var isLocalFormPresentationBlocked = false
    private let formPresentation: FormPresentationState
    private var isFormPresentationBlocked: Bool {
        isLocalFormPresentationBlocked || !formPresentation.canPresentChatForm
    }
    private var submittedPresentedForm = false
    private var submittedRecoveryCleanupFailed = false
    private var hasAnnouncedLegacyForm = false
    private var skippedFormAssetIds: Set<String> = []
    var isSubmittingForm: Bool { submittingFormGeneration == activeFormGeneration }
    private(set) var formErrorRevision = 0

    private enum WorkflowStage: Int {
        case unknown = 0
        case uploading = 10
        case formRequested = 20
        case formConfirmed = 30
        case processing = 40
        case ready = 50
        case failed = 60
    }

    private var workflowStages: [String: WorkflowStage] = [:]
    private var workflowRevisions: [String: Int] = [:]
    private var hasBlockingConnectivityIssue = false
    private var blockingConnectivityAssetId: String?
    private let reconnectWarningThreshold = 3

    private struct RecoveryKey: Equatable {
        let formGeneration: UUID
        let presentationGeneration: UUID
        let assetId: String?
    }

    private var currentRecoveryKey: RecoveryKey {
        RecoveryKey(
            formGeneration: activeFormGeneration,
            presentationGeneration: formPresentation.generation,
            assetId: currentAssetId)
    }

    // MARK: - Dependencies

    let auth: AuthService
    let ws: WebSocketService
    init(
        auth: AuthService,
        ws: WebSocketService,
        formPresentation: FormPresentationState = FormPresentationState(),
        pendingFormStore: PendingFormStore = .shared,
        httpTransport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await RedirectSafeTransport.data(for: $0)
        },
        thumbnailGenerator: @escaping @Sendable (URL) async -> UIImage? = {
            await StagedVideo.generateThumbnail(from: $0)
        },
        photoAssociationStore: ScopedPHAssetIdentifierStore = .shared,
        requestPhotoAddAccess: @escaping @Sendable () async -> Bool = {
            await OriginalVideoLoader.requestAddAccessIfNeeded()
        },
        saveTrimToPhotos: @escaping @Sendable (URL, String, VideoMetadata) async throws -> String? = {
            fileURL, fileName, metadata in
            try await OriginalVideoLoader.saveVideoToPhotos(
                fileURL: fileURL,
                fileName: fileName,
                creationDate: metadata.capturedAt.flatMap { DVUDateFormatting.parseISO($0) },
                latitude: metadata.gpsLat,
                longitude: metadata.gpsLon,
                altitude: metadata.gpsAltitude)
        },
        fingerprintVideo: @escaping @Sendable (URL) async throws -> VideoContentFingerprint = {
            try await VideoContentFingerprint.calculate(for: $0)
        }
    ) {
        self.auth = auth
        self.ws = ws
        self.formPresentation = formPresentation
        self.pendingFormStore = pendingFormStore
        self.pendingFormRecovery = PendingFormRecovery(store: pendingFormStore, fetch: httpTransport)
        self.pendingFormSubmission = PendingFormSubmission(store: pendingFormStore, transport: httpTransport)
        self.httpTransport = httpTransport
        self.thumbnailGenerator = thumbnailGenerator
        self.photoAssociationStore = photoAssociationStore
        self.requestPhotoAddAccess = requestPhotoAddAccess
        self.saveTrimToPhotos = saveTrimToPhotos
        self.fingerprintVideo = fingerprintVideo
        let serverURL = ServerConfig.baseURL
        self.sessionServerURL = serverURL
        self.sessionScope = auth.currentUser.flatMap {
            PendingFormScope(userId: $0.id, serverURL: serverURL)
        }
        self.sessionToken = auth.token
        self.sessionGeneration = auth.sessionGeneration
        setupWebSocketHandlers()
        setupConnectionHandlers()
    }

    private var sessionIsCurrent: Bool {
        guard let sessionScope, let sessionToken,
              let currentUser = auth.currentUser,
              auth.sessionGeneration == sessionGeneration,
              auth.token == sessionToken,
              ServerConfig.baseURL == sessionServerURL,
              let currentScope = PendingFormScope(userId: currentUser.id, serverURL: ServerConfig.baseURL)
        else { return false }
        return currentScope == sessionScope
    }

    // MARK: - WebSocket Handlers

    private func setupWebSocketHandlers() {
        ws.onMessage = { [weak self] message in
            guard let self, self.sessionIsCurrent else { return }
            if let assetId = message.assetId, !assetId.isEmpty {
                guard self.pendingAssetCreation == nil,
                      assetId == self.currentAssetId
                        || (self.currentAssetId == nil && assetId == self.archive.assetId)
                else { return }
            }

            self.clearBlockingConnectivityIssueIfNeeded(assetId: message.assetId)

            // When server confirms a Slack post, mark the last outgoing
            // .slackPost as confirmed so the bubble switches to "Sent".
            if message.messageType == .slackPost,
                message.direction == .incoming
            {
                if let outId = self.messages.last(where: {
                    $0.messageType == .slackPost && $0.direction == .outgoing
                        && !self.slackConfirmedIds.contains($0.id)
                })?.id {
                    self.slackConfirmedIds.insert(outId)
                }
            }

            self.appendMessage(message, source: .websocket)

            // Auto-download thumbnail for Slack confirmation bubbles
            if message.messageType == .slackPost,
                message.direction == .incoming,
                let urlStr = message.content.thumbnailUrl,
                let url = URL(string: urlStr)
            {
                self.downloadSlackThumbnail(url: url, messageId: message.id)
            }
        }

        ws.onUploadComplete = { [weak self] data in
            guard let self, self.sessionIsCurrent else { return }
            let assetId = data["assetId"] as? String ?? ""
            guard !assetId.isEmpty, assetId == self.currentAssetId,
                  self.pendingAssetCreation == nil else { return }
            Log.debug("✅ [Upload] Upload complete for asset: \(assetId)", logger: Log.upload)

            self.clearBlockingConnectivityIssueIfNeeded(assetId: assetId)

            if !assetId.isEmpty {
                _ = self.promoteStage(for: assetId, to: .processing)
            }

            // Fetch the full asset (with clips) so MetadataView can display it
            Task { @MainActor in
                await self.fetchAssetDetail(assetId: assetId)
            }
        }

        ws.onFormRequest = { [weak self] data in
            guard let self, self.sessionIsCurrent, let scope = self.sessionScope else { return }
            guard let assetId = data["assetId"] as? String, !assetId.isEmpty else {
                Log.error("⚠️ [Form] Form request is missing its asset ID", logger: Log.upload)
                return
            }
            if self.showFormSheet && self.formAssetId == assetId { return }

            let anotherFlowIsActive =
                self.isFormPresentationBlocked || self.showMetadataSheet || self.showSlackShareSheet
                || self.isSelectingVideo || self.isProcessingVideo || self.stagedVideo != nil
                || self.pendingAssetCreation != nil
                || (self.showFormSheet && self.formAssetId != assetId)
                || (self.currentAssetId != nil && self.currentAssetId != assetId)
            let pending = PendingForm(
                assetId: assetId,
                originalFileName: data["originalFileName"] as? String,
                capturedAt: data["capturedAt"] as? String,
                clipCount: data["clipCount"] as? Int,
                duration: data["duration"] as? Int,
                thumbnailJPEG: self.currentAssetId == assetId
                    ? self.form.thumbnail?.jpegData(compressionQuality: 0.5) : nil,
                savedAt: Date()
            )
            let record: PendingFormRecord?
            do {
                record = try self.pendingFormStore.save(pending, for: scope)
            } catch {
                record = nil
                Log.error("⚠️ [Form] Failed to save pending form: \(Log.describe(error))", logger: Log.upload)
                self.appendErrorBubble(
                    "This form couldn't be saved for recovery. Add its details now or from Archive.",
                    assetId: assetId, code: "IOS_PENDING_FORM_SAVE_FAILED")
            }
            if anotherFlowIsActive || record?.autoRecover == false
                || self.skippedFormAssetIds.contains(assetId)
            {
                self.appendErrorBubble(
                    "An upload needs details. Open Archive to add them.",
                    assetId: assetId, code: "IOS_PENDING_FORM_IN_ARCHIVE")
                return
            }

            if self.currentAssetId != assetId {
                self.form = FormContext()
            }
            self.currentAssetId = assetId
            self.formAssetId = assetId
            self.activeFormGeneration = UUID()
            self.activePendingRecord = record
            self.submittedPresentedForm = false

            self.clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
            _ = self.promoteStage(for: assetId, to: .formRequested)

            // Store form context for ContextFormView header
            self.form.originalFileName = data["originalFileName"] as? String
            self.form.clipCount = data["clipCount"] as? Int
            self.form.duration = data["duration"] as? Int
            self.form.capturedAt = data["capturedAt"] as? String
            self.form.submitError = nil

            self.formFields = self.buildFormFields()
            self.showFormSheet = true
        }

        ws.onFormConfirmed = { [weak self] data in
            guard let self, self.sessionIsCurrent else { return }
            let assetId = data["assetId"] as? String
            guard let assetId, assetId == self.currentAssetId,
                  self.pendingAssetCreation == nil else { return }

            self.clearBlockingConnectivityIssueIfNeeded(assetId: assetId)

            let fallbackText =
                data["messageFallbackText"] as? String
                ?? data["message"] as? String
                ?? "High five. Form received."
            let messageCode = data["messageCode"] as? String ?? "WS_FORM_CONFIRMED"
            let messageParams = self.parseStringParams(data["messageParams"])
            let messageSchemaVersion =
                data["messageSchemaVersion"] as? Int ?? MessageCatalog.schemaVersion
            let mediasourceId = data["mediasourceId"] as? String
            let mediasourceUrl = data["mediasourceUrl"] as? String
            let originalFileName = data["originalFileName"] as? String
            let capturedAt = data["capturedAt"] as? String

            let previousStage = self.promoteStage(for: assetId, to: .formConfirmed)
            let hasExistingFormConfirmation = self.hasWorkflowMessage(
                code: messageCode,
                assetId: assetId,
                mediasourceId: mediasourceId
            )

            if previousStage != .failed,
                previousStage.rawValue >= WorkflowStage.formConfirmed.rawValue,
                hasExistingFormConfirmation
            {
                return
            }

            self.ensureFormConfirmedMessage(
                assetId: assetId,
                mediasourceId: mediasourceId,
                mediasourceUrl: mediasourceUrl,
                originalFileName: originalFileName,
                capturedAt: capturedAt,
                fallbackText: fallbackText,
                code: messageCode,
                params: messageParams,
                schemaVersion: messageSchemaVersion,
                source: .workflow
            )
        }

        ws.onMuxReady = { [weak self] data in
            guard let self, self.sessionIsCurrent else { return }
            let assetId = data["assetId"] as? String
            guard let assetId, assetId == self.currentAssetId,
                  self.pendingAssetCreation == nil else { return }
            let mediasourceId = data["mediasourceId"] as? String
            let mediasourceUrl = data["mediasourceUrl"] as? String
            let originalFileName = data["originalFileName"] as? String
            let formSlug = data["formSlug"] as? String
            let duration = data["duration"] as? Int
            let resolution = data["resolution"] as? String
            let fileSize = data["fileSize"] as? String

            self.clearBlockingConnectivityIssueIfNeeded(assetId: assetId)

            let hasSubmittedForm =
                !(formSlug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if hasSubmittedForm {
                // If form:confirmed arrives late (or is missed), ensure the metadata
                // confirmation bubble still appears before the ready summary.
                self.ensureFormConfirmedMessage(
                    assetId: assetId,
                    mediasourceId: mediasourceId,
                    mediasourceUrl: mediasourceUrl,
                    originalFileName: originalFileName,
                    capturedAt: nil,
                    fallbackText: nil,
                    source: .workflow
                )
            }

            Log.debug("✅ [Mux Ready] Asset \(assetId) confirmed on Mediasource", logger: Log.upload)

            let previousStage = self.promoteStage(for: assetId, to: .ready)
            if previousStage != .failed,
                previousStage.rawValue >= WorkflowStage.ready.rawValue
            {
                let missingSummary = !self.hasWorkflowMessage(
                    code: "IOS_MUX_READY_SUMMARY",
                    assetId: assetId,
                    mediasourceId: mediasourceId
                )
                let missingFollowup = !self.hasWorkflowMessage(
                    code: "IOS_MUX_READY_FOLLOWUP",
                    assetId: assetId,
                    mediasourceId: mediasourceId
                )

                if !missingSummary, !missingFollowup {
                    return
                }

                // Recovery path for reconnect churn: if stage is already READY but
                // UI messages are missing, clear asset dedupe and backfill them.
                self.messagePolicy.resetAssetScope(assetId: assetId)
            }

            self.applyReadyWorkflowState(
                assetId: assetId,
                mediasourceId: mediasourceId,
                mediasourceUrl: mediasourceUrl,
                originalFileName: originalFileName,
                formSlug: formSlug,
                duration: duration,
                resolution: resolution,
                fileSize: fileSize,
                source: .workflow
            )
        }

    }

    // MARK: - Connection State Handlers

    private func setupConnectionHandlers() {
        ws.onConnected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.reconcileActiveWorkflowStateAfterReconnect()
            }
        }

        ws.onReconnecting = { [weak self] attempt, maxAttempts in
            guard let self else { return }
            guard attempt >= self.reconnectWarningThreshold else { return }
            // Connection state is reflected in ChatHeaderView (Ready / Working / Trying to connect)
            // Report to server DB (best-effort — may fail if offline)
            Task {
                await self.reportError(
                    category: "websocket",
                    message: "WebSocket reconnecting (attempt \(attempt)/\(maxAttempts))",
                    severity: "WARNING"
                )
            }
        }

        ws.onConnectionLost = { [weak self] in
            guard let self else { return }
            // Connection state is reflected in ChatHeaderView (red dot + "Trying to connect...")
            Task {
                await self.reportError(
                    category: "websocket",
                    message: "WebSocket max reconnect attempts exhausted — connection lost",
                    severity: "CRITICAL"
                )
            }
        }
    }

    // MARK: - Error Helpers

    private func isConnectivityIssue(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .notConnectedToInternet,
                .networkConnectionLost,
                .timedOut,
                .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed,
                .resourceUnavailable,
                .internationalRoamingOff,
                .callIsActive,
                .dataNotAllowed,
                .secureConnectionFailed:
                return true
            default:
                break
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                .networkConnectionLost,
                .timedOut,
                .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed,
                .resourceUnavailable,
                .internationalRoamingOff,
                .callIsActive,
                .dataNotAllowed,
                .secureConnectionFailed:
                return true
            default:
                break
            }
        }

        return false
    }

    private func noteBlockingConnectivityIssue(operation: String, assetId: String?) {
        guard !hasBlockingConnectivityIssue else { return }

        hasBlockingConnectivityIssue = true
        blockingConnectivityAssetId = assetId

        let connectivityMessage = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text:
                    "Connection interrupted while \(operation). Upload and metadata sync are paused until reconnection.",
                code: "IOS_CONNECTIVITY_BLOCKING",
                params: ["operation": operation],
                fallbackText:
                    "Connection interrupted while \(operation). Upload and metadata sync are paused until reconnection.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(connectivityMessage, source: .workflow)
    }

    private func clearBlockingConnectivityIssueIfNeeded(assetId: String?) {
        guard hasBlockingConnectivityIssue else { return }

        hasBlockingConnectivityIssue = false
        let recoveredAssetId = assetId ?? blockingConnectivityAssetId
        blockingConnectivityAssetId = nil

        let recoveredMessage = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: recoveredAssetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: "Connection restored. Upload and metadata sync resumed.",
                code: "IOS_CONNECTIVITY_RECOVERED",
                fallbackText: "Connection restored. Upload and metadata sync resumed.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(recoveredMessage, source: .workflow)
    }

    private func promoteStage(for assetId: String?, to stage: WorkflowStage) -> WorkflowStage {
        guard let assetId, !assetId.isEmpty else { return .unknown }

        let revision = formPresentation.uploadRecoveryRevision(for: assetId)
        if let previousRevision = workflowRevisions[assetId], previousRevision != revision {
            workflowStages[assetId] = nil
            messagePolicy.resetAssetScope(assetId: assetId)
        }
        workflowRevisions[assetId] = revision
        let previous = workflowStages[assetId] ?? .unknown

        if stage == .failed {
            if previous != .failed {
                workflowStages[assetId] = .failed
                messagePolicy.resetAssetScope(assetId: assetId)
            }
            return previous
        }

        if previous == .failed {
            workflowStages[assetId] = stage
            return previous
        }

        if stage.rawValue > previous.rawValue {
            workflowStages[assetId] = stage
        }
        return previous
    }

    func uploadHasFailed(assetId: String?) -> Bool {
        guard let assetId else { return false }
        return formPresentation.failedChatUploadAssetIDs.contains(assetId)
            || (workflowStages[assetId] == .failed
                && workflowRevisions[assetId] == formPresentation.uploadRecoveryRevision(for: assetId))
    }

    private func inferredStage(from asset: Asset) -> WorkflowStage {
        switch asset.status {
        case .error:
            return .failed
        case .ready:
            return .ready
        case .processing:
            return .processing
        case .uploading:
            if asset.formResponse != nil {
                return .formConfirmed
            }
            return .uploading
        }
    }

    private func applyReadyWorkflowState(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        formSlug: String?,
        duration: Int?,
        resolution: String?,
        fileSize: String?,
        source: MessagePolicyCoordinator.Source
    ) {
        // Store archive metadata
        archive.assetId = assetId
        archive.mediasourceId = mediasourceId
        archive.mediasourceUrl = mediasourceUrl
        archive.originalFileName = originalFileName
        archive.formSlug = formSlug
        archive.duration = duration
        archive.resolution = resolution
        archive.fileSize = fileSize
        isArchived = true

        let hasSummary = hasWorkflowMessage(
            code: "IOS_MUX_READY_SUMMARY",
            assetId: assetId,
            mediasourceId: mediasourceId
        )

        if !hasSummary {
            let summaryMessage = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: assetId,
                direction: .incoming,
                messageType: .muxReady,
                content: MessageContent(
                    text: "Mediasource confirmed.",
                    code: "IOS_MUX_READY_SUMMARY",
                    params: mediasourceId.map { ["mediasourceId": $0] },
                    fallbackText: "Mediasource confirmed.",
                    schemaVersion: MessageCatalog.schemaVersion,
                    slug: formSlug,
                    mediasourceId: mediasourceId,
                    mediasourceUrl: mediasourceUrl,
                    originalFileName: originalFileName,
                    duration: duration,
                    resolution: resolution
                ),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            appendMessage(summaryMessage, source: source)
        }

        // After 1 second, append a normalized follow-up message.
        let hasFollowup = hasWorkflowMessage(
            code: "IOS_MUX_READY_FOLLOWUP",
            assetId: assetId,
            mediasourceId: mediasourceId
        )
        guard !hasFollowup else { return }

        let firstName = auth.currentUser?.name.components(separatedBy: " ").first ?? "there"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))

            guard
                self.sessionIsCurrent, !Task.isCancelled,
                self.pendingAssetCreation == nil,
                self.archive.assetId == assetId,
                self.currentAssetId == nil || self.currentAssetId == assetId,
                !self.hasWorkflowMessage(
                    code: "IOS_MUX_READY_FOLLOWUP",
                    assetId: assetId,
                    mediasourceId: mediasourceId
                )
            else {
                return
            }

            let message = "You're a rock star. Send another video when ready."
            let followUp = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: assetId,
                direction: .incoming,
                messageType: .greeting,
                content: MessageContent(
                    text: message,
                    code: "IOS_MUX_READY_FOLLOWUP",
                    params: ["firstName": firstName],
                    fallbackText: message,
                    schemaVersion: MessageCatalog.schemaVersion
                ),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            self.appendMessage(followUp, source: source)
        }
    }

    private func activeSlackTargetAssetId() -> String? {
        if let currentAssetId, !currentAssetId.isEmpty {
            return currentAssetId
        }

        if isArchived,
            let archivedAssetId = archive.assetId,
            !archivedAssetId.isEmpty
        {
            return archivedAssetId
        }

        return nil
    }

    private func ensureFormConfirmedMessage(
        assetId: String?,
        mediasourceId: String?,
        mediasourceUrl: String?,
        originalFileName: String?,
        capturedAt: String?,
        fallbackText: String?,
        code: String = "WS_FORM_CONFIRMED",
        params: [String: String]? = nil,
        schemaVersion: Int? = nil,
        source: MessagePolicyCoordinator.Source
    ) {
        guard
            !hasWorkflowMessage(
                code: code,
                assetId: assetId,
                mediasourceId: mediasourceId
            )
        else {
            return
        }

        let resolvedFallback =
            fallbackText
            ?? MessageCatalog.resolve(code: code, params: params ?? [:])
            ?? "High five. I will text when the video is done. Metadata is ready, and you can Slack your team below."

        let confirmation = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .confirmation,
            content: MessageContent(
                text: resolvedFallback,
                code: code,
                params: params,
                fallbackText: resolvedFallback,
                schemaVersion: schemaVersion ?? MessageCatalog.schemaVersion,
                slug: nil,
                mediasourceId: mediasourceId,
                mediasourceUrl: mediasourceUrl,
                originalFileName: originalFileName,
                capturedAt: capturedAt
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(confirmation, source: source)
    }

    private func appendReconciledFormConfirmed(
        asset: Asset,
        source: MessagePolicyCoordinator.Source = .workflow
    ) {
        guard asset.formResponse != nil else { return }

        let fallback =
            MessageCatalog.resolve(code: "WS_FORM_CONFIRMED", params: [:])
            ?? "High five. I will text when the video is done. Metadata is ready, and you can Slack your team below."

        ensureFormConfirmedMessage(
            assetId: asset.id,
            mediasourceId: asset.mediasourceId,
            mediasourceUrl: asset.mediasourceUrl,
            originalFileName: asset.originalFileName ?? asset.clips?.first?.originalFileName,
            capturedAt: asset.clips?.first?.capturedAt,
            fallbackText: fallback,
            source: source
        )
    }

    private func reconcileWorkflowState(
        from asset: Asset,
        source: MessagePolicyCoordinator.Source = .workflow
    ) {
        let reconciledStage = inferredStage(from: asset)
        let previousStage = promoteStage(for: asset.id, to: reconciledStage)

        if reconciledStage == .failed,
            previousStage != .failed
        {
            appendErrorBubble(
                "Upload failed: Processing failed. Open Archive to retry.",
                assetId: asset.id,
                code: "IOS_UPLOAD_FAILED",
                params: ["reason": "Processing failed. Open Archive to retry."]
            )
            return
        }

        if asset.formResponse != nil,
            reconciledStage.rawValue >= WorkflowStage.formConfirmed.rawValue
        {
            appendReconciledFormConfirmed(asset: asset, source: source)
        }

        if reconciledStage == .ready {
            if previousStage != .failed,
                previousStage.rawValue >= WorkflowStage.ready.rawValue
            {
                let missingSummary = !hasWorkflowMessage(
                    code: "IOS_MUX_READY_SUMMARY",
                    assetId: asset.id,
                    mediasourceId: asset.mediasourceId
                )
                let missingFollowup = !hasWorkflowMessage(
                    code: "IOS_MUX_READY_FOLLOWUP",
                    assetId: asset.id,
                    mediasourceId: asset.mediasourceId
                )

                if !missingSummary, !missingFollowup {
                    return
                }

                messagePolicy.resetAssetScope(assetId: asset.id)
            }

            applyReadyWorkflowState(
                assetId: asset.id,
                mediasourceId: asset.mediasourceId,
                mediasourceUrl: asset.mediasourceUrl,
                originalFileName: asset.originalFileName
                    ?? asset.clips?.first?.originalFileName,
                formSlug: asset.formResponse?.slug,
                duration: asset.clips?.first?.duration,
                resolution: asset.clips?.first?.resolution,
                fileSize: asset.clips?.first?.fileSize,
                source: source
            )
        }
    }

    private func hasWorkflowMessage(
        code: String,
        assetId: String?,
        mediasourceId: String?
    ) -> Bool {
        messages.contains { message in
            guard message.content.code == code else { return false }

            if let assetId, !assetId.isEmpty,
                message.assetId == assetId
            {
                return true
            }

            if let mediasourceId, !mediasourceId.isEmpty,
                message.content.mediasourceId == mediasourceId
            {
                return true
            }

            return false
        }
    }

    private func reconcileActiveWorkflowStateAfterReconnect() async {
        guard sessionIsCurrent else { return }
        guard let assetId = currentAssetId ?? archive.assetId else { return }

        let recoveryRevision = formPresentation.uploadRecoveryRevision(for: assetId)
        let request = auth.authenticatedRequest(for: ServerConfig.assetURL(assetId))
        do {
            let (data, response) = try await httpTransport(request)
            guard sessionIsCurrent,
                  pendingAssetCreation == nil,
                  formPresentation.uploadRecoveryRevision(for: assetId) == recoveryRevision,
                  currentAssetId == assetId || (currentAssetId == nil && archive.assetId == assetId)
            else { return }
            guard let http = response as? HTTPURLResponse else {
                Log.error("⚠️ [Reconnect] Invalid workflow-state response", logger: Log.network)
                return
            }
            guard http.statusCode == 200 else {
                Log.error("⚠️ [Reconnect] Workflow-state lookup failed: HTTP \(http.statusCode)", logger: Log.network)
                return
            }

            let detail = try JSONDecoder().decode(AssetDetailResponse.self, from: data)
            let asset = detail.asset
            guard asset.id == assetId else {
                Log.error("⚠️ [Reconnect] Workflow-state asset did not match request", logger: Log.network)
                return
            }
            lastAsset = asset
            lastClip = asset.clips?.first

            clearBlockingConnectivityIssueIfNeeded(assetId: asset.id)
            reconcileWorkflowState(from: asset, source: .workflow)
        } catch {
            guard sessionIsCurrent, pendingAssetCreation == nil,
                  formPresentation.uploadRecoveryRevision(for: assetId) == recoveryRevision,
                  currentAssetId == assetId || (currentAssetId == nil && archive.assetId == assetId)
            else { return }
            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(operation: "syncing workflow state", assetId: assetId)
            }
            Log.error("⚠️ [Reconnect] State reconcile skipped: \(Log.describe(error))", logger: Log.network)
        }
    }

    /// Central append gate for progressive messaging and dedupe policy.
    private func appendMessage(_ message: ChatMessage, source: MessagePolicyCoordinator.Source) {
        let shouldDebugCode = {
            guard let code = message.content.code else { return false }
            return code == "WS_FORM_CONFIRMED"
                || code == "IOS_MUX_READY_SUMMARY"
                || code == "IOS_MUX_READY_FOLLOWUP"
        }()

        guard messagePolicy.shouldPresent(message, source: source) else {
            if shouldDebugCode {
                let identity = message.assetId ?? message.content.mediasourceId ?? "n/a"
                Log.error("⚠️ [Chat] Dropped message by policy: code=\(message.content.code ?? "n/a") source=\(source) target=\(identity)", logger: Log.app)
            }
            return
        }

        messages.append(message)

        if shouldDebugCode {
            let identity = message.assetId ?? message.content.mediasourceId ?? "n/a"
            Log.debug("💬 [Chat] Appended message: code=\(message.content.code ?? "n/a") source=\(source) target=\(identity) total=\(messages.count)", logger: Log.app)
        }
    }

    /// Show an error message to the user as a chat bubble.
    @discardableResult
    private func appendErrorBubble(
        _ text: String,
        assetId: String? = nil,
        code: String? = nil,
        params: [String: String]? = nil
    ) -> ChatMessage {
        var noticeParams = params ?? [:]
        if (code == "IOS_UPLOAD_FAILED" || code == "IOS_PREVIOUS_UPLOAD_FAILED"),
           let assetId {
            noticeParams["uploadRevision"] = String(
                formPresentation.uploadRecoveryRevision(for: assetId))
        }
        let errorMsg = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: text,
                code: code,
                params: noticeParams.isEmpty ? nil : noticeParams,
                fallbackText: code == nil ? nil : text,
                schemaVersion: code == nil ? nil : MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(errorMsg, source: .error)
        return errorMsg
    }

    /// Report an error to the server's error_logs table (best-effort, fire-and-forget).
    /// Future: server will send text/email for CRITICAL errors.
    func reportError(
        category: String,
        message: String,
        severity: String = "WARNING",
        assetId: String? = nil,
        details: [String: String]? = nil
    ) async {
        guard sessionIsCurrent else { return }
        var request = auth.authenticatedRequest(for: ServerConfig.errorsURL, method: "POST")
        var body: [String: Any] = [
            "source": "ios",
            "category": category,
            "message": message,
            "severity": severity,
        ]
        if let assetId { body["assetId"] = assetId }
        if let details { body["details"] = details }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await httpTransport(request)
            guard let http = response as? HTTPURLResponse else {
                Log.error("⚠️ [Report] Invalid error-report response", logger: Log.network)
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                Log.error("⚠️ [Report] Error-report request failed: HTTP \(http.statusCode)", logger: Log.network)
                return
            }
        } catch {
            Log.error("⚠️ [Report] Could not send error report: \(Log.describe(error))", logger: Log.network)
        }
    }

    // MARK: - Send Text Message

    // Matches #channel or @mention anywhere in the text (mirrors server-side regex)
    private static let slackCommandPattern = try? NSRegularExpression(pattern: "[#@][\\w.-]+")

    func sendTextMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Detect Slack commands: #channel or @user (anywhere in the message, matching server-side regex)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let isSlackCommand = Self.slackCommandPattern?.firstMatch(in: trimmed, range: range) != nil
        let slackTargetAssetId = isSlackCommand ? activeSlackTargetAssetId() : nil

        // If Slack command but no current upload, tell user to upload first
        if isSlackCommand && slackTargetAssetId == nil {
            let localOut = ChatMessage(
                id: UUID().uuidString,
                userId: auth.currentUser?.id,
                assetId: nil,
                direction: .outgoing,
                messageType: .slackPost,
                content: MessageContent(text: text),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            appendMessage(localOut, source: .outgoing)
            let reply = ChatMessage(
                id: UUID().uuidString,
                userId: nil,
                assetId: nil,
                direction: .incoming,
                messageType: .text,
                content: MessageContent(
                    text:
                        "Upload a video first and I can grab the metadata so you can Slack it. Previous uploads are in your Archive, and you can Slack from there.",
                    code: "IOS_SLACK_REQUIRES_UPLOAD",
                    fallbackText:
                        "Upload a video first and I can grab the metadata so you can Slack it. Previous uploads are in your Archive, and you can Slack from there.",
                    schemaVersion: MessageCatalog.schemaVersion
                ),
                createdAt: DVUDateFormatting.isoString(from: Date())
            )
            appendMessage(reply, source: .workflow)
            return
        }

        // Optimistic UI — add message locally
        let localMessage = ChatMessage(
            id: UUID().uuidString,
            userId: auth.currentUser?.id,
            assetId: nil,
            direction: .outgoing,
            messageType: isSlackCommand ? .slackPost : .text,
            content: MessageContent(text: text),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(localMessage, source: .outgoing)

        let messageAssetId: String? = {
            if let currentAssetId, !currentAssetId.isEmpty {
                return currentAssetId
            }
            if isSlackCommand {
                return slackTargetAssetId
            }
            return nil
        }()

        // Send via WebSocket — always pass explicit assetId so the server
        // doesn't fall back to "most recent READY asset" (wrong metadata bug).
        ws.sendMessage(text: text, assetId: messageAssetId)
    }
    // MARK: - Create Asset (Video Upload Flow)

    private func createAsset(
        staged: StagedVideo, transcribe: Bool, uploadID: UUID
    ) async -> Asset? {
        guard sessionIsCurrent, !Task.isCancelled else { return nil }
        let fileName = staged.fileName
        let fileURL = staged.tempFileURL
        var request = auth.authenticatedRequest(for: ServerConfig.assetsURL, method: "POST")
        let body = CreateAssetRequest(fileName: fileName)
        request.httpBody = try? JSONEncoder().encode(body)

        // Get actual file size before notifying server
        let fileSize: Int64 = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            return attrs?[.size] as? Int64 ?? 0
        }()

        do {
            let asset = try await withRetry(attempts: 3) { attempt in
                guard self.sessionIsCurrent, !Task.isCancelled else { throw CancellationError() }
                let (data, httpResponse) = try await self.httpTransport(request)
                guard self.sessionIsCurrent, !Task.isCancelled else { throw CancellationError() }
                let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0

                guard statusCode >= 200, statusCode < 300 else {
                    Log.error("❌ [Upload] createAsset HTTP \(statusCode)", logger: Log.upload)
                    throw NSError(
                        domain: "createAsset", code: statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Server returned \(statusCode)"])
                }

                let response = try JSONDecoder().decode(CreateAssetResponse.self, from: data)
                return response.asset
            }

            guard sessionIsCurrent, !Task.isCancelled else { return nil }
            formPresentation.markUploadStarted(stageID: staged.id)
            let stageID = staged.id.uuidString
            messages.removeAll {
                ($0.content.code == "IOS_UPLOAD_START_FAILED"
                    || $0.content.code == "IOS_PREVIOUS_UPLOAD_START_FAILED")
                    && $0.content.params?["stageId"] == stageID
            }
            uploadFailuresToPreserve.removeAll {
                $0.content.code == "IOS_PREVIOUS_UPLOAD_START_FAILED"
                    && $0.content.params?["stageId"] == stageID
            }
            if activeUploadID == uploadID {
                currentAssetId = asset.id
                _ = promoteStage(for: asset.id, to: .uploading)
                clearBlockingConnectivityIssueIfNeeded(assetId: asset.id)

                let msgId = UUID().uuidString
                let videoMessage = ChatMessage(
                    id: msgId,
                    userId: auth.currentUser?.id,
                    assetId: asset.id,
                    direction: .outgoing,
                    messageType: .video,
                    content: MessageContent(text: "📹 \(fileName)", fileName: fileName),
                    createdAt: DVUDateFormatting.isoString(from: Date())
                )
                appendMessage(videoMessage, source: .outgoing)
                sentUploads[msgId] = SentUploadInfo(
                    thumbnail: staged.thumbnail,
                    fileName: fileName,
                    createdDate: staged.createdDate ?? DVUDateFormatting.longDate(from: Date()),
                    hasLocation: staged.metadata.gpsLat != nil,
                    transcribeEnabled: transcribe
                )
            }

            // Notify WebSocket with real file size
            ws.sendVideoUpload(
                assetId: asset.id,
                fileName: fileName,
                fileSize: fileSize
            )

            return asset
        } catch {
            guard sessionIsCurrent, !Task.isCancelled, !(error is CancellationError) else {
                return nil
            }
            let errorDesc = Log.describe(error)
            if activeUploadID != uploadID || stagedVideo?.id != staged.id
                || isSelectingVideo || isProcessingVideo {
                appendPreviousUploadFailure(
                    "An earlier upload of \(fileName) couldn't start. Retry its preview if available, or select it again.",
                    code: "IOS_PREVIOUS_UPLOAD_START_FAILED", fileName: fileName,
                    uploadID: uploadID, stageID: staged.id)
            }
            Task {
                await reportError(
                    category: "upload",
                    message: "Asset creation failed after 3 attempts: \(errorDesc)",
                    severity: "ERROR",
                    details: ["fileName": fileName]
                )
            }
            return nil
        }
    }

    // MARK: - Upload Video

    /// Returns the uploaded clip when the file finished uploading.
    private func uploadVideo(
        assetId: String, fileURL: URL, fileName: String, metadata: VideoMetadata, uploadID: UUID
    ) async -> MuxUploadResponse? {
        guard sessionIsCurrent, let token = sessionToken, !Task.isCancelled else { return nil }
        let uploader = VideoUploadService(createTransport: httpTransport)
        if activeUploadID == uploadID {
            isUploading = true
            uploadProgress = 0
        }
        defer {
            if activeUploadID == uploadID { isUploading = false }
        }

        // Poll uploader progress on main actor
        let progressTask = Task { @MainActor in
            while !Task.isCancelled, self.sessionIsCurrent, self.activeUploadID == uploadID {
                self.uploadProgress = uploader.uploadProgress
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { progressTask.cancel() }

        do {
            // Single path: Mux direct upload via background URLSession.
            // iOS handles network interruptions automatically (waitsForConnectivity).
            let muxResult = try await uploader.uploadViaMux(
                assetId: assetId, fileURL: fileURL, token: token,
                serverURL: sessionServerURL, metadata: metadata,
                isCurrent: { self.sessionIsCurrent })
            guard sessionIsCurrent, !Task.isCancelled else { return nil }
            Log.debug("✅ [Upload] Mux direct upload completed for asset: \(assetId), clipId: \(muxResult.clipId)", logger: Log.upload)
            if activeUploadID == uploadID { uploadProgress = 1 }
            return muxResult
        } catch {
            guard sessionIsCurrent, !Task.isCancelled, !(error is CancellationError) else {
                return nil
            }
            Log.error("❌ [Upload] Failed for asset \(assetId): \(Log.describe(error))", logger: Log.upload)
            if activeUploadID == uploadID, currentAssetId == assetId {
                _ = promoteStage(for: assetId, to: .failed)
            }
            if activeUploadID == uploadID, currentAssetId == assetId,
               !isSelectingVideo, !isProcessingVideo, stagedVideo == nil {
                let reason = isConnectivityIssue(error)
                    ? "Connection interrupted. Open Archive to retry."
                    : "Open Archive to retry."
                appendErrorBubble(
                    "Upload failed: \(reason)",
                    assetId: assetId,
                    code: "IOS_UPLOAD_FAILED",
                    params: ["reason": reason]
                )
            } else {
                appendPreviousUploadFailure(
                    "An earlier upload of \(fileName) failed. Open Archive to retry.",
                    assetId: assetId, code: "IOS_PREVIOUS_UPLOAD_FAILED",
                    fileName: fileName, uploadID: uploadID)
            }
            Task {
                await reportError(
                    category: "upload",
                    message: "File upload failed: \(Log.describe(error))",
                    severity: "ERROR",
                    assetId: assetId
                )
            }
        }

        return nil
    }

    // MARK: - Send Transcript

    /// Send transcript text + timestamped segments to the server (non-fatal).
    func sendTranscript(assetId: String, clipId: String, result: TranscriptionResult) async -> Bool {
        guard sessionIsCurrent, !Task.isCancelled else {
            Log.error("⚠️ [Transcribe] Session changed before transcript save", logger: Log.transcription)
            return false
        }
        let request = auth.authenticatedRequest(
            for: ServerConfig.transcriptURL(assetId, clipId: clipId), method: "PATCH")

        do {
            try await TranscriptDelivery.send(
                result, clipId: clipId, request: request, transport: httpTransport)
            guard sessionIsCurrent, !Task.isCancelled else { return false }
            Log.debug("✅ [Transcribe] Transcript saved for asset \(assetId) (\(result.segments.count) segments)", logger: Log.transcription)
            return true
        } catch is CancellationError {
            return false
        } catch TranscriptDeliveryError.httpStatus(let status) {
            Log.error("⚠️ [Transcribe] Transcript save failed: HTTP \(status)", logger: Log.transcription)
        } catch {
            Log.error("⚠️ [Transcribe] Failed to save transcript: \(Log.describe(error))", logger: Log.transcription)
        }
        return false
    }

    // MARK: - Video Staging (iOS 26.3 Flow)

    func beginVideoSelection() {
        isSelectingVideo = true
        deferPendingFormRecovery()
    }

    func endVideoSelection() {
        isSelectingVideo = false
    }

    func deferPendingFormRecovery() {
        activeFormGeneration = UUID()
    }

    func cancelStalePendingFormRecovery() {
        guard let pendingRecoveryKey, pendingRecoveryKey != currentRecoveryKey else { return }
        cancelPendingFormRecovery()
    }

    func cancelPendingFormRecovery() {
        pendingRecoveryTask?.cancel()
        pendingRecoveryTask = nil
        pendingRecoveryID = nil
        pendingRecoveryKey = nil
        retryPendingFormRecovery = false
    }

    @discardableResult
    func invalidateIfSessionChanged() -> Bool {
        guard !sessionIsCurrent else { return false }
        cancelPendingFormRecovery()
        stagingTask?.cancel()
        stagingTask = nil
        stagingGeneration = nil
        stagingFileURL = nil
        isProcessingVideo = false
        for preparation in preparationTasks.values { preparation.task.cancel() }
        preparationAttempts.removeAll()
        if let stagedVideo {
            if !leasedStagedFiles.contains(stagedVideo.id) {
                cleanupTempFile(stagedVideo.tempFileURL)
            }
            self.stagedVideo = nil
        }
        stagedUploadPreparation = .ready
        for task in uploadTasks.values { task.cancel() }
        return true
    }

    func setFormPresentationBlocked(_ blocked: Bool) {
        if blocked && !isLocalFormPresentationBlocked { deferPendingFormRecovery() }
        isLocalFormPresentationBlocked = blocked
    }

    /// Reserve the selection before thumbnail generation can yield to another action.
    @discardableResult
    func stageVideo(
        fileURL: URL, fileName: String, metadata: VideoMetadata, phAssetIdentifier: String? = nil,
        isTrimmed: Bool = false
    ) -> Task<Void, Never> {
        guard sessionIsCurrent else {
            cleanupTempFile(fileURL)
            return Task {}
        }
        stagingTask?.cancel()
        if let stagedVideo {
            preparationAttempts.removeValue(forKey: stagedVideo.id)
            if stagedUploadPreparation != .creatingAsset {
                preparationTasks[stagedVideo.id]?.task.cancel()
            }
            if !leasedStagedFiles.contains(stagedVideo.id) {
                cleanupTempFile(stagedVideo.tempFileURL)
            }
            self.stagedVideo = nil
        }
        stagedUploadPreparation = .ready
        activeFormGeneration = UUID()
        let generation = UUID()
        stagingGeneration = generation
        stagingFileURL = fileURL
        isProcessingVideo = true
        let task = Task {
            let thumbnail = await thumbnailGenerator(fileURL)
            guard sessionIsCurrent, !Task.isCancelled, stagingGeneration == generation else {
                if stagingGeneration == generation {
                    stagingGeneration = nil
                    stagingFileURL = nil
                    stagingTask = nil
                    isProcessingVideo = false
                }
                if stagingFileURL != fileURL && stagedVideo?.tempFileURL != fileURL {
                    cleanupTempFile(fileURL)
                }
                return
            }
            let createdDate = metadata.capturedAt.map { DVUDateFormatting.longDate($0) }
            stagedVideo = StagedVideo(
                tempFileURL: fileURL,
                fileName: fileName,
                createdDate: createdDate,
                thumbnail: thumbnail,
                metadata: metadata,
                phAssetIdentifier: isTrimmed ? nil : phAssetIdentifier,
                isTrimmed: isTrimmed
            )
            stagingGeneration = nil
            stagingFileURL = nil
            stagingTask = nil
            isProcessingVideo = false
        }
        stagingTask = task
        return task
    }

    /// Save a trim before creating its server asset, retaining the stage on failure.
    func confirmStagedUpload(
        id: UUID, transcribe: Bool, acceptManualPhotoSelection: Bool = false
    ) async {
        guard sessionIsCurrent, !Task.isCancelled, !isSelectingVideo, !isProcessingVideo,
              stagedVideo?.id == id,
              preparationAttempts[id] == nil else { return }

        let attempt = UUID()
        preparationAttempts[id] = attempt
        let task = Task {
            await prepareStagedUpload(
                id: id, transcribe: transcribe,
                acceptManualPhotoSelection: acceptManualPhotoSelection, attempt: attempt)
        }
        preparationTasks[id] = (attempt, task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if preparationTasks[id]?.attempt == attempt { preparationTasks[id] = nil }
    }

    private func prepareStagedUpload(
        id: UUID, transcribe: Bool, acceptManualPhotoSelection: Bool, attempt: UUID
    ) async {
        guard sessionIsCurrent, !Task.isCancelled, preparationAttempts[id] == attempt,
              var staged = stagedVideo, staged.id == id else {
            if preparationAttempts[id] == attempt { preparationAttempts[id] = nil }
            return
        }
        let acceptedKnownMissingIdentifier = acceptManualPhotoSelection
            && stagedUploadPreparation == .manualPhotoSelectionRequired
            && staged.isSavedToPhotos && staged.savedPhotoIdentifier == nil
        let acceptedUnverifiedFingerprint = acceptManualPhotoSelection
            && stagedUploadPreparation == .manualFingerprintSelectionRequired
            && staged.fingerprint == nil
        leasedStagedFiles.insert(id)
        let fileURL = staged.tempFileURL
        defer {
            if preparationAttempts[id] == attempt {
                preparationAttempts[id] = nil
                if let current = stagedVideo, current.id == id, stagedUploadPreparation.isBusy {
                    stagedUploadPreparation = .failed(
                        current.isTrimmed && current.isSavedToPhotos
                            ? "Upload preparation was interrupted. Retry or remove the preview; the trim remains in Photos."
                            : "Upload preparation was interrupted. Retry or remove the preview.")
                }
            }
            leasedStagedFiles.remove(id)
            if stagedVideo?.id != id { cleanupTempFile(fileURL) }
        }

        func ownsStage() -> Bool {
            sessionIsCurrent && stagedVideo?.id == id && preparationAttempts[id] == attempt
        }

        func isCurrent() -> Bool {
            ownsStage() && !Task.isCancelled
                && !isSelectingVideo && !isProcessingVideo
        }

        if staged.isTrimmed && !staged.isSavedToPhotos {
            stagedUploadPreparation = .requestingPhotoAccess
            let authorized = await requestPhotoAddAccess()
            guard isCurrent() else { return }
            guard authorized else {
                stagedUploadPreparation = .photoAccessDenied
                return
            }

            stagedUploadPreparation = .savingPhoto
            do {
                let save = saveTrimToPhotos
                let fileName = staged.fileName
                let metadata = staged.metadata
                let transaction = Task.detached {
                    try await save(fileURL, fileName, metadata)
                }
                let identifier = try await transaction.value
                guard ownsStage() else { return }
                staged.isSavedToPhotos = true
                staged.savedPhotoIdentifier = identifier.flatMap { $0.isEmpty ? nil : $0 }
                stagedVideo = staged
            } catch {
                guard ownsStage() else { return }
                Log.error("❌ [Photos] Failed to save trimmed copy: \(Log.describe(error))", logger: Log.media)
                stagedUploadPreparation = Self.photoSaveFailure(error)
                return
            }
        }
        guard isCurrent() else { return }

        if staged.isTrimmed && staged.isSavedToPhotos && staged.savedPhotoIdentifier == nil
            && !staged.acceptedManualPhotoSelection
        {
            guard acceptedKnownMissingIdentifier else {
                stagedUploadPreparation = .manualPhotoSelectionRequired
                return
            }
            staged.acceptedManualPhotoSelection = true
            stagedVideo = staged
        }

        let photoIdentifier = staged.isTrimmed
            ? staged.savedPhotoIdentifier : staged.phAssetIdentifier
        if acceptedUnverifiedFingerprint {
            staged.acceptedManualPhotoSelection = true
            stagedVideo = staged
        }
        if photoIdentifier != nil && staged.fingerprint == nil && !staged.acceptedManualPhotoSelection {
            stagedUploadPreparation = .verifyingPhoto
            do {
                let fingerprint = try await fingerprintVideo(fileURL)
                guard isCurrent() else { return }
                guard fingerprint.isValid else { throw PhotoAssociationError.invalidFingerprint }
                staged.fingerprint = fingerprint
                stagedVideo = staged
            } catch {
                guard isCurrent() else { return }
                Log.error("❌ [Photos] Could not verify video for Archive: \(Log.describe(error))", logger: Log.media)
                stagedUploadPreparation = .manualFingerprintSelectionRequired
                return
            }
        }
        guard isCurrent() else { return }

        stagedUploadPreparation = .creatingAsset
        if isArchived || currentAssetId != nil {
            startNewConversation(preservingStagedVideo: true)
        }

        let fileName = staged.fileName
        let metadata = staged.metadata
        let uploadID = UUID()
        activeUploadID = uploadID
        pendingAssetCreation = uploadID

        let task = Task {
            let created = await createAsset(staged: staged, transcribe: transcribe, uploadID: uploadID)
            if pendingAssetCreation == uploadID { pendingAssetCreation = nil }
            guard sessionIsCurrent, !Task.isCancelled else { return }
            guard let asset = created else {
                if stagedVideo?.id == id {
                    stagedUploadPreparation = .failed(
                        staged.isTrimmed
                            ? "The upload couldn't be started. Retry or remove the preview; the trim remains in Photos."
                            : "The upload couldn't be started. Retry or remove the preview.")
                }
                return
            }
            Log.debug("✅ [Upload] Asset created: \(asset.mediasourceId ?? asset.id)", logger: Log.upload)

            guard let uploadScope = sessionScope else {
                Log.error("❌ [Upload] Missing account scope for an active upload", logger: Log.upload)
                return
            }
            formPresentation.beginChatUpload(
                assetId: asset.id, scope: uploadScope, uploadID: uploadID)
            if activeUploadID == uploadID {
                prepareStagedContext(staged)
            }
            if let photoIdentifier, let fingerprint = staged.fingerprint {
                do {
                    guard let sessionScope else { throw PhotoAssociationError.invalidScope }
                    try photoAssociationStore.save(
                        assetId: asset.id,
                        association: ScopedPhotoAssociation(
                            photoIdentifier: photoIdentifier, fingerprint: fingerprint,
                            metadata: metadata),
                        for: sessionScope)
                    formPresentation.photoAssociatedAssetIDs.insert(asset.id)
                } catch {
                    Log.error("⚠️ [Photos] Could not save Archive association: \(Log.describe(error))", logger: Log.media)
                    if activeUploadID == uploadID, currentAssetId == asset.id {
                        appendErrorBubble(
                            "The photo link couldn't be saved. If you retry this upload, choose the matching video in Archive.",
                            assetId: asset.id, code: "IOS_PHOTO_ASSOCIATION_SAVE_FAILED")
                    } else {
                        appendPreviousUploadFailure(
                            "The photo link for \(fileName) couldn't be saved. Choose the matching video if you retry.",
                            assetId: asset.id, code: "IOS_PREVIOUS_PHOTO_ASSOCIATION_SAVE_FAILED",
                            fileName: fileName, uploadID: uploadID)
                    }
                }
            }
            let uploaded = await uploadVideo(
                assetId: asset.id, fileURL: fileURL, fileName: fileName,
                metadata: metadata, uploadID: uploadID)
            formPresentation.finishChatUpload(
                assetId: asset.id, scope: uploadScope, uploadID: uploadID,
                failed: sessionIsCurrent && uploaded == nil)

            guard sessionIsCurrent, !Task.isCancelled, let uploaded else { return }

            if transcribe {
                await transcribeAndReport(
                    assetId: asset.id, clipId: uploaded.clipId, fileURL: fileURL,
                    fileName: fileName, uploadID: uploadID)
            }
        }
        uploadTasks[uploadID] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        uploadTasks[uploadID] = nil
    }

    private static func photoSaveFailure(_ error: Error) -> StagedUploadPreparation {
        if let loaderError = error as? OriginalVideoLoader.LoaderError,
           case .addAccessDenied = loaderError {
            return .photoAccessDenied
        }
        let failure = error as NSError
        if (failure.domain == NSCocoaErrorDomain
                && failure.code == CocoaError.fileWriteOutOfSpace.rawValue)
            || (failure.domain == NSPOSIXErrorDomain
                && failure.code == Int(POSIXErrorCode.ENOSPC.rawValue)) {
            return .failed("There isn't enough storage to save the trim in Photos. Free space and retry.")
        }
        guard failure.domain == PHPhotosErrorDomain,
              let code = PHPhotosError.Code(rawValue: failure.code) else {
            return .failed("Photos couldn't save the trim (error \(failure.code)). Retry; contact support if the problem continues.")
        }
        switch code {
        case .accessUserDenied:
            return .photoAccessDenied
        case .accessRestricted:
            return .failed("Photo Library access is restricted on this device. Check device restrictions before retrying.")
        case .notEnoughSpace:
            return .failed("There isn't enough storage to save the trim in Photos. Free space and retry.")
        case .invalidResource, .missingResource:
            return .failed("Photos couldn't use the trim file. Remove the preview and select the video again.")
        case .operationInterrupted, .userCancelled:
            return .failed("Saving the trim to Photos was interrupted. Retry.")
        case .networkError, .networkAccessRequired:
            return .failed("Photos couldn't save the trim because of a network problem. Check your connection and retry.")
        default:
            return .failed("Photos couldn't save the trim (error \(failure.code)). Retry; contact support if the problem continues.")
        }
    }

    /// Cancel an in-progress upload.
    func cancelUpload() {
        if let activeUploadID { uploadTasks[activeUploadID]?.cancel() }
        isUploading = false
        uploadProgress = 0
        if let assetId = currentAssetId {
            _ = promoteStage(for: assetId, to: .failed)
        }
        appendErrorBubble("Upload cancelled.", code: "IOS_UPLOAD_CANCELLED")
    }

    /// User cancelled staged video — discard and clean up.
    func cancelStagedVideo(id: UUID) {
        guard let staged = stagedVideo, staged.id == id else { return }
        guard stagedUploadPreparation != .creatingAsset else { return }
        preparationAttempts[id] = nil
        preparationTasks[id]?.task.cancel()
        stagedVideo = nil
        stagedUploadPreparation = .ready
        if !leasedStagedFiles.contains(id) { cleanupTempFile(staged.tempFileURL) }
    }

    // MARK: - Private Helpers

    /// Save thumbnail + metadata from staged video, clear the preview.
    private func prepareStagedContext(_ staged: StagedVideo) {
        form.thumbnail = staged.thumbnail
        if stagedVideo?.id == staged.id {
            stagedVideo = nil
            stagedUploadPreparation = .ready
        }
    }

    /// Parse dynamic payload params into a string-only dictionary for template rendering.
    private func parseStringParams(_ value: Any?) -> [String: String]? {
        guard let dict = value as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (key, raw) in dict {
            switch raw {
            case let s as String:
                out[key] = s
            case let b as Bool:
                out[key] = b ? "true" : "false"
            case let n as NSNumber:
                out[key] = n.stringValue
            default:
                continue
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Transcribe audio and update the status bubble in-place.
    private func transcribeAndReport(
        assetId: String, clipId: String, fileURL: URL, fileName: String, uploadID: UUID
    ) async {
        guard sessionIsCurrent, !Task.isCancelled else { return }
        let transcribingMsg = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: assetId,
            direction: .incoming,
            messageType: .text,
            content: MessageContent(
                text: "Transcribing audio...",
                code: "IOS_TRANSCRIBE_START",
                fallbackText: "Transcribing audio...",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        if activeUploadID == uploadID, currentAssetId == assetId {
            appendMessage(transcribingMsg, source: .workflow)
        }

        let transcriber = TranscriptionService()
        let result = await transcriber.transcribe(
            videoURL: fileURL, isCurrent: { self.sessionIsCurrent })
        guard sessionIsCurrent, !Task.isCancelled else { return }
        if let result {
            await deliverTranscriptAndUpdateBubble(
                assetId: assetId, clipId: clipId, result: result, messageId: transcribingMsg.id,
                createdAt: transcribingMsg.createdAt, fileName: fileName)
        } else {
            let statusText: String
            let statusCode: String
            var statusParams: [String: String]? = nil
            switch transcriber.state {
            case .noSpeech:
                statusText = "No clear audio detected in video."
                statusCode = "IOS_TRANSCRIBE_NO_SPEECH"
            case .failed(let reason):
                statusText = "Transcription failed: \(reason)"
                statusCode = "IOS_TRANSCRIBE_FAILED"
                statusParams = ["reason": reason]
            default:
                statusText = "Transcription did not produce results."
                statusCode = "IOS_TRANSCRIBE_EMPTY"
            }
            updateTranscriptionBubble(
                id: transcribingMsg.id, assetId: assetId,
                text: statusText,
                code: statusCode,
                params: statusParams,
                createdAt: transcribingMsg.createdAt,
                fileName: fileName)
        }
    }

    func deliverTranscriptAndUpdateBubble(
        assetId: String, clipId: String, result: TranscriptionResult, messageId: String,
        createdAt: String?, fileName: String? = nil
    ) async {
        let sent = await sendTranscript(assetId: assetId, clipId: clipId, result: result)
        guard sessionIsCurrent, !Task.isCancelled else { return }
        if sent {
            updateTranscriptionBubble(
                id: messageId, assetId: assetId,
                text: "Transcript saved to Mediasource. (\(result.segments.count) words.)",
                code: "IOS_TRANSCRIBE_SUCCESS",
                params: ["wordCount": "\(result.segments.count)"],
                createdAt: createdAt)
        } else {
            updateTranscriptionBubble(
                id: messageId, assetId: assetId,
                text: "The transcript wasn't saved. To try again, upload the video with transcription enabled.",
                code: "IOS_TRANSCRIBE_SAVE_FAILED",
                createdAt: createdAt,
                fileName: fileName)
        }
    }

    /// Replace the content of a transcription status bubble.
    private func updateTranscriptionBubble(
        id: String,
        assetId: String,
        text: String,
        code: String? = nil,
        params: [String: String]? = nil,
        createdAt: String?,
        fileName: String? = nil
    ) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx] = ChatMessage(
                id: id, userId: nil, assetId: assetId,
                direction: .incoming, messageType: .text,
                content: MessageContent(
                    text: text,
                    code: code,
                    params: params,
                    fallbackText: code == nil ? nil : text,
                    schemaVersion: code == nil ? nil : MessageCatalog.schemaVersion
                ),
                createdAt: createdAt
            )
        } else if let fileName {
            appendErrorBubble(
                "Transcription for \(fileName): \(text)", assetId: assetId,
                code: "IOS_PREVIOUS_TRANSCRIBE_RESULT",
                params: ["fileName": fileName, "result": text, "messageId": id])
        }
    }

    private func appendPreviousUploadFailure(
        _ message: String, assetId: String? = nil, code: String, fileName: String,
        uploadID: UUID, stageID: UUID? = nil
    ) {
        var params = ["fileName": fileName, "uploadId": uploadID.uuidString]
        if let stageID { params["stageId"] = stageID.uuidString }
        let notice = appendErrorBubble(
            message, assetId: assetId, code: code, params: params)
        if isSelectingVideo || isProcessingVideo || stagedVideo != nil {
            uploadFailuresToPreserve.append(notice)
        }
    }

    /// Clean up the temporary video file after upload + transcription, including the
    /// per-load folder (`tmp/<UUID>/`) it was copied or exported into.
    private func cleanupTempFile(_ url: URL) {
        removeTemporaryVideoItem(url)
        let tempDir = FileManager.default.temporaryDirectory.standardizedFileURL
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        if parent.deletingLastPathComponent().path == tempDir.path,
            UUID(uuidString: parent.lastPathComponent) != nil
        {
            removeTemporaryVideoItem(parent)
        }
    }

    // MARK: - Cancel Form (skip details → archive)

    /// User chose to skip the form. Archive the conversation immediately.
    /// PendingForm stays on disk so the form can be reopened later from Archive.
    /// Video continues uploading in background.
    func cancelForm() {
        guard !isSubmittingForm else { return }
        if let formAssetId { skippedFormAssetIds.insert(formAssetId) }
        if let activePendingRecord {
            do {
                try pendingFormStore.deferToArchive(activePendingRecord)
            } catch {
                Log.error("⚠️ [Form] Could not save the skip preference: \(Log.describe(error))", logger: Log.upload)
                appendErrorBubble(
                    "The form was skipped, but that preference couldn't be saved. It may reopen after restart.",
                    assetId: formAssetId, code: "IOS_PENDING_FORM_SKIP_SAVE_FAILED")
            }
        }
        showFormSheet = false
        isArchived = true
        activeFormGeneration = UUID()

        // Add a chat bubble confirming the skip
        let msg = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: currentAssetId,
            direction: .incoming,
            messageType: .systemNote,
            content: MessageContent(
                text:
                    "No worries. You can add details from your Archive anytime.",
                code: "IOS_FORM_SKIPPED",
                fallbackText:
                    "No worries. You can add details from your Archive anytime.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(msg, source: .workflow)
    }

    func formDismissed() -> String? {
        guard !showFormSheet else { return nil }
        let announcement: String? = submittedPresentedForm
            ? (submittedRecoveryCleanupFailed
                ? "Details sent, but the saved recovery state couldn't be updated."
                : "Details sent.")
            : nil
        submittedPresentedForm = false
        submittedRecoveryCleanupFailed = false
        activeFormGeneration = UUID()
        activePendingRecord = nil
        formAssetId = nil
        return announcement
    }

    // MARK: - Submit Form

    func submitForm(assetId: String, formData: [String: String]) async {
        guard sessionIsCurrent, let scope = sessionScope else {
            form.submitError = "Your session changed. Sign in again to submit these details."
            formErrorRevision += 1
            return
        }
        guard showFormSheet, formAssetId == assetId else { return }
        let generation = activeFormGeneration
        guard submittingFormGeneration != generation else { return }
        submittingFormGeneration = generation
        defer {
            if submittingFormGeneration == generation {
                submittingFormGeneration = nil
            }
        }
        let pendingRecord = activePendingRecord.flatMap {
            $0.scope == scope && $0.form.assetId == assetId ? $0 : nil
        }
        let request = auth.authenticatedRequest(for: ServerConfig.formURL(assetId), method: "POST")

        do {
            let outcome = try await pendingFormSubmission.submit(
                formData: formData, request: request, pendingRecord: pendingRecord,
                scope: scope, assetId: assetId,
                isCurrent: { self.sessionIsCurrent })
            if case .submittedRecoveryNotCleared(let error) = outcome {
                Log.error("⚠️ [Form] Failed to clear saved recovery state: \(Log.describe(error))", logger: Log.upload)
            }
            guard sessionIsCurrent else { return }
            if case .sessionChanged = outcome { return }
            formPresentation.completedDetailsAssetIDs.insert(assetId)
            guard activeFormGeneration == generation,
                  formAssetId == assetId, showFormSheet else { return }

            // Form sheet closes — server will push form:confirmed via WS
            // with the "High Five!" confirmation bubble + metadata
            form.submitError = nil
            submittedPresentedForm = true
            if case .submittedRecoveryNotCleared = outcome {
                submittedRecoveryCleanupFailed = true
            } else {
                submittedRecoveryCleanupFailed = false
            }
            showFormSheet = false
            activePendingRecord = nil
            clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
            if case .submittedRecoveryNotCleared = outcome {
                appendErrorBubble(
                    "Details were sent, but the saved recovery state couldn't be updated.",
                    assetId: assetId, code: "IOS_PENDING_FORM_CLEAR_FAILED")
            }
        } catch {
            if case FormSubmissionError.httpStatus(let status) = error {
                Log.error("❌ [Form] Submit failed: HTTP \(status)", logger: Log.upload)
            } else {
                Log.error("❌ [Form] Failed to submit form: \(Log.describe(error))", logger: Log.upload)
            }
            guard sessionIsCurrent, activeFormGeneration == generation, showFormSheet else { return }
            if case FormSubmissionError.inProgress = error {
                form.submitError = "These details are already being sent. Wait and try again."
                formErrorRevision += 1
                return
            }
            // Keep form open so user can retry — show error in chat too
            form.submitError = "Couldn't confirm the details were sent. Retry or check Archive."
            formErrorRevision += 1
            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(
                    operation: "submitting form details", assetId: assetId)
            } else {
                appendErrorBubble(
                    "Couldn't confirm the details were sent. The form is still open.",
                    assetId: assetId,
                    code: "IOS_FORM_SUBMIT_FAILED"
                )
            }
            Task {
                await reportError(
                    category: "form",
                    message: "Form submission failed: \(Log.describe(error))",
                    severity: "ERROR",
                    assetId: assetId
                )
            }
        }
    }

    // MARK: - Connect

    func connectWebSocket() {
        guard sessionIsCurrent, let token = auth.token else { return }
        workflowStages.removeAll()
        workflowRevisions.removeAll()
        messagePolicy.resetForFreshConnection()
        hasBlockingConnectivityIssue = false
        blockingConnectivityAssetId = nil
        // Fresh conversation — clear old messages
        messages.removeAll()
        // Tear down any existing connection/reconnect loop before connecting with fresh token
        ws.disconnect()
        ws.connect(token: token)
    }

    func disconnectWebSocket() {
        ws.disconnect()
    }

    // MARK: - Fetch Asset Detail

    func fetchAssetDetail(assetId: String) async {
        guard sessionIsCurrent, currentAssetId == assetId else { return }
        let recoveryRevision = formPresentation.uploadRecoveryRevision(for: assetId)
        let request = auth.authenticatedRequest(for: ServerConfig.assetURL(assetId))
        do {
            let (data, urlResponse) = try await httpTransport(request)
            guard sessionIsCurrent, currentAssetId == assetId,
                  pendingAssetCreation == nil,
                  formPresentation.uploadRecoveryRevision(for: assetId) == recoveryRevision else { return }
            guard let http = urlResponse as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let response = try JSONDecoder().decode(AssetDetailResponse.self, from: data)
            guard response.asset.id == assetId else {
                throw URLError(.badServerResponse)
            }
            self.lastAsset = response.asset
            self.lastClip = response.asset.clips?.first
            clearBlockingConnectivityIssueIfNeeded(assetId: assetId)
            reconcileWorkflowState(from: response.asset, source: .workflow)
        } catch {
            guard sessionIsCurrent, currentAssetId == assetId,
                  pendingAssetCreation == nil,
                  formPresentation.uploadRecoveryRevision(for: assetId) == recoveryRevision else { return }
            Log.error("❌ [Asset] Failed to fetch asset detail: \(Log.describe(error))", logger: Log.network)
            if isConnectivityIssue(error) {
                noteBlockingConnectivityIssue(operation: "syncing metadata", assetId: assetId)
            } else {
                appendErrorBubble(
                    "Could not load video details.",
                    assetId: assetId,
                    code: "IOS_ASSET_DETAILS_LOAD_FAILED"
                )
            }
        }
    }

    func showMetadata() {
        guard lastClip != nil else { return }
        deferPendingFormRecovery()
        showMetadataSheet = true
    }

    // MARK: - Pending Form Recovery

    /// Check for a form that was pending when app was killed.
    func recoverPendingFormIfNeeded(restartInFlight: Bool = false) async {
        guard sessionIsCurrent, let scope = sessionScope else { return }
        if !hasAnnouncedLegacyForm {
            do {
                if try pendingFormStore.hasLegacyForm {
                    hasAnnouncedLegacyForm = true
                    do {
                        try pendingFormStore.protectLegacyForm()
                    } catch {
                        Log.error("⚠️ [Form] Could not protect legacy recovery state: \(Log.describe(error))", logger: Log.upload)
                        appendErrorBubble(
                            "The older saved form couldn't be protected. Open Archive to remove it if no longer needed.",
                            code: "IOS_LEGACY_FORM_PROTECTION_FAILED")
                    }
                    appendErrorBubble(
                        "An older pending form was preserved. Sign in to the account that uploaded the video and open Archive to add its details.",
                        code: "IOS_LEGACY_PENDING_FORM")
                }
            } catch {
                Log.error("⚠️ [Form] Could not inspect legacy recovery state: \(Log.describe(error))", logger: Log.upload)
                appendErrorBubble(
                    "Couldn't check for older saved forms. Unlock this device and try again.",
                    code: "IOS_LEGACY_FORM_CHECK_FAILED")
            }
        }
        let key = currentRecoveryKey
        if !restartInFlight, let pendingRecoveryTask, pendingRecoveryKey == key {
            retryPendingFormRecovery = true
            await pendingRecoveryTask.value
            return
        }
        cancelPendingFormRecovery()
        let recoveryID = UUID()
        pendingRecoveryID = recoveryID
        pendingRecoveryKey = key
        let task = Task { @MainActor in
            repeat {
                guard !Task.isCancelled, self.pendingRecoveryID == recoveryID else { return }
                self.retryPendingFormRecovery = false
                await self.recoverNextPendingForm(for: scope, key: key, recoveryID: recoveryID)
            } while self.retryPendingFormRecovery && self.sessionIsCurrent
                && !Task.isCancelled && self.pendingRecoveryID == recoveryID
            if self.pendingRecoveryID == recoveryID {
                self.pendingRecoveryTask = nil
                self.pendingRecoveryID = nil
                self.pendingRecoveryKey = nil
                self.retryPendingFormRecovery = false
            }
        }
        pendingRecoveryTask = task
        await task.value
    }

    private func recoverNextPendingForm(
        for scope: PendingFormScope, key: RecoveryKey, recoveryID: UUID
    ) async {
        func isCurrent() -> Bool {
            !Task.isCancelled && pendingRecoveryID == recoveryID
                && currentRecoveryKey == key && sessionIsCurrent
                && !isFormPresentationBlocked && !showFormSheet
                && !showMetadataSheet && !showSlackShareSheet
                && (!isUploading || key.assetId != nil) && !isProcessingVideo
                && !isSelectingVideo && pendingAssetCreation == nil && stagedVideo == nil
        }
        guard isCurrent() else { return }

        do {
            let result = try await pendingFormRecovery.next(
                for: scope, assetId: key.assetId,
                isCurrent: isCurrent,
                requestForAsset: {
                    self.auth.authenticatedRequest(for: ServerConfig.assetURL($0))
                })
            guard isCurrent() else { return }
            if case .ready(let record, let skippedFailures) = result {
                if skippedFailures && retryPendingFormRecovery { return }
                if skippedFailures {
                    appendErrorBubble(
                        "A saved form couldn't be restored. Check your connection or sign in again, then open Archive to add its details.",
                        code: "IOS_PENDING_FORM_RECOVERY_FAILED")
                }
                Log.debug("🔄 [Recovery] Restoring pending form for asset: \(record.form.assetId)", logger: Log.app)
                restoreFormFromPending(record)
            }
        } catch {
            guard isCurrent() else { return }
            if retryPendingFormRecovery { return }
            if case PendingFormRecoveryError.httpStatus(let status) = error {
                Log.error("⚠️ [Recovery] Pending form lookup failed: HTTP \(status)", logger: Log.app)
            } else {
                Log.error("⚠️ [Recovery] Could not check pending form: \(Log.describe(error))", logger: Log.app)
            }
            appendErrorBubble(
                "A saved form couldn't be restored. Check your connection or sign in again, then open Archive to add its details.",
                code: "IOS_PENDING_FORM_RECOVERY_FAILED")
        }
    }

    /// Restore form UI from persisted PendingForm state.
    private func restoreFormFromPending(_ record: PendingFormRecord) {
        let pendingForm = record.form
        activePendingRecord = record
        activeFormGeneration = UUID()
        currentAssetId = pendingForm.assetId
        formAssetId = pendingForm.assetId
        submittedPresentedForm = false
        form = FormContext()
        form.originalFileName = pendingForm.originalFileName
        form.capturedAt = pendingForm.capturedAt
        form.clipCount = pendingForm.clipCount
        form.duration = pendingForm.duration
        if let jpegData = pendingForm.thumbnailJPEG {
            form.thumbnail = UIImage(data: jpegData)
        }
        formFields = buildFormFields()
        showFormSheet = true

        // Reconcile immediately after restoring pending form so relaunches after
        // force-quit can catch up missed state changes without waiting for another reconnect.
        Task { @MainActor in
            await reconcileActiveWorkflowStateAfterReconnect()
        }
    }

    /// Build the standard form fields (used for both live and recovery).
    private func buildFormFields() -> [FormField] {
        FormField.defaultVideoFields()
    }

    // MARK: - Archive / New Conversation

    /// Clear current conversation and start fresh for a new upload.
    func startNewConversation(preservingStagedVideo: Bool = false) {
        let preservedFailures = uploadFailuresToPreserve.filter {
            formPresentation.shouldAnnounceRecoveryNotice(
                code: $0.content.code, assetId: $0.assetId, params: $0.content.params)
        }
        uploadFailuresToPreserve.removeAll()
        workflowStages.removeAll()
        workflowRevisions.removeAll()
        messagePolicy.resetForNewConversation()
        hasBlockingConnectivityIssue = false
        blockingConnectivityAssetId = nil
        messages.removeAll()
        currentAssetId = nil
        formAssetId = nil
        activeUploadID = nil
        isArchived = false
        archive = ArchiveState()
        form = FormContext()
        activePendingRecord = nil
        activeFormGeneration = UUID()
        lastAsset = nil
        lastClip = nil
        if !preservingStagedVideo { stagedVideo = nil }
        isUploading = false
        uploadProgress = 0
        showFormSheet = false
        showMetadataSheet = false
        showSlackShareSheet = false
        sentUploads.removeAll()
        slackThumbnails.removeAll()
        slackConfirmedIds.removeAll()

        // Re-send greeting for the fresh conversation
        let firstName = auth.currentUser?.name.components(separatedBy: " ").first ?? "there"
        let greeting = ChatMessage(
            id: UUID().uuidString,
            userId: nil,
            assetId: nil,
            direction: .incoming,
            messageType: .greeting,
            content: MessageContent(
                text: "Hey \(firstName). Upload away.",
                code: "IOS_GREETING_NEW_CONVERSATION",
                params: ["firstName": firstName],
                fallbackText: "Hey \(firstName). Upload away.",
                schemaVersion: MessageCatalog.schemaVersion
            ),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(greeting, source: .workflow)
        for notice in preservedFailures {
            appendMessage(notice, source: .error)
        }
    }

    /// Send a Slack share for the archived asset.
    func shareToSlack(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let archiveAssetId = archive.assetId, !archiveAssetId.isEmpty else {
            appendErrorBubble(
                "Upload a video first and I can grab the metadata so you can Slack it. Previous uploads are in your Archive, and you can Slack from there.",
                code: "IOS_SLACK_REQUIRES_UPLOAD"
            )
            return
        }

        // Optimistic UI — add Slack post message locally
        let localMessage = ChatMessage(
            id: UUID().uuidString,
            userId: auth.currentUser?.id,
            assetId: archiveAssetId,
            direction: .outgoing,
            messageType: .slackPost,
            content: MessageContent(text: text),
            createdAt: DVUDateFormatting.isoString(from: Date())
        )
        appendMessage(localMessage, source: .outgoing)
        showSlackShareSheet = false

        // Send via WebSocket — server detects #channel/@mention pattern
        ws.sendMessage(text: text, assetId: archiveAssetId)
    }

    /// Download a thumbnail image and cache it for the Slack bubble.
    private func downloadSlackThumbnail(url: URL, messageId: String) {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    self.slackThumbnails[messageId] = image
                }
            } catch {
                Log.error("⚠️ [Slack] Failed to download thumbnail: \(Log.describe(error))", logger: Log.network)
            }
        }
    }
}
