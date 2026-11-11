// May 10, 2026 - 1:55pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI
import Observation
import PhotosUI
import UIKit

enum ArchiveRefreshResult {
    case succeeded
    case failed
    case superseded
}

struct ArchiveRefreshFeedback {
    private(set) var awaitingManualResult = false
    private(set) var awaitingReuploadResult = false

    mutating func requestManualRefresh() {
        awaitingManualResult = true
    }

    mutating func requestReuploadRefresh() {
        awaitingReuploadResult = true
    }

    mutating func complete(_ result: ArchiveRefreshResult) -> String? {
        guard awaitingManualResult || awaitingReuploadResult else { return nil }
        switch result {
        case .superseded:
            return nil
        case .succeeded:
            let shouldAnnounce = awaitingManualResult
            awaitingManualResult = false
            awaitingReuploadResult = false
            return shouldAnnounce ? "Archive refreshed." : nil
        case .failed:
            let wasReupload = awaitingReuploadResult
            awaitingManualResult = false
            awaitingReuploadResult = false
            return wasReupload
                ? "Upload finished, but its status couldn't be refreshed. Refresh Archive."
                : "Couldn't refresh Archive. Please try again."
        }
    }
}

struct ArchiveAnnouncementQueue {
    private(set) var pending: [String] = []

    mutating func append(_ announcement: String) {
        pending.append(announcement)
    }

    mutating func prepend(_ announcement: String) {
        pending.insert(announcement, at: 0)
    }

    mutating func takeIfPossible(isActive: Bool, hasModal: Bool) -> String? {
        guard isActive, !hasModal, !pending.isEmpty else { return nil }
        let announcement = pending.joined(separator: " ")
        pending.removeAll()
        return announcement
    }
}

/// Keeps completion focus behind the announcement, including queued follow-up notices.
/// If a modal or inactive scene interrupts speech, the caller can replay it when unblocked
/// without restoring the focus target from before the presentation changed.
struct ArchiveCompletionAnnouncementFocus {
    struct Finished: Equatable {
        let focusAssetID: String?
        let interruptedAnnouncement: String?
    }

    private(set) var hasPending = false
    private(set) var isWaitingForVoiceOver = false
    private var pendingFocusAssetID: String?
    private var speakingMessage: String?
    private var speakingFocusAssetID: String?
    private var wasPresentationBlocked = false

    mutating func enqueue(focusAssetID: String?) {
        hasPending = true
        if let focusAssetID { pendingFocusAssetID = focusAssetID }
    }

    mutating func preserveFocusIfAbsent(_ assetID: String?) {
        guard hasPending, pendingFocusAssetID == nil else { return }
        pendingFocusAssetID = assetID
    }

    mutating func beginPost(_ message: String, voiceOverRunning: Bool) -> String? {
        guard hasPending, !isWaitingForVoiceOver else { return nil }
        let focusAssetID = pendingFocusAssetID
        hasPending = false
        pendingFocusAssetID = nil
        guard voiceOverRunning else { return focusAssetID }
        isWaitingForVoiceOver = true
        speakingMessage = message
        speakingFocusAssetID = focusAssetID
        wasPresentationBlocked = false
        return nil
    }

    mutating func presentationBlocked() {
        if isWaitingForVoiceOver { wasPresentationBlocked = true }
        pendingFocusAssetID = nil
    }

    mutating func finish(
        _ message: String, wasSuccessful: Bool, isPresentationBlocked: Bool
    ) -> Finished? {
        guard isWaitingForVoiceOver, speakingMessage == message else { return nil }
        if isPresentationBlocked { pendingFocusAssetID = nil }
        let wasBlocked = wasPresentationBlocked || isPresentationBlocked
        let focusAssetID = wasSuccessful && !wasBlocked ? speakingFocusAssetID : nil
        let interruptedAnnouncement = !wasSuccessful && wasBlocked ? message : nil
        _ = cancelSpeaking()
        return Finished(
            focusAssetID: focusAssetID, interruptedAnnouncement: interruptedAnnouncement)
    }

    @discardableResult
    mutating func cancelSpeaking() -> String? {
        let focusAssetID = wasPresentationBlocked ? nil : speakingFocusAssetID
        isWaitingForVoiceOver = false
        speakingMessage = nil
        speakingFocusAssetID = nil
        wasPresentationBlocked = false
        return focusAssetID
    }
}

@MainActor
struct ArchivePickerConfirmationFocus {
    private(set) var isPending = false

    mutating func selectionChanged(hasSelection: Bool) {
        isPending = hasSelection
    }

    mutating func consumeIfPossible(
        hasSelection: Bool, isPresented: Bool, presentation: FormPresentationState,
        interaction: ArchiveInteractionState, modalID: UUID
    ) -> Bool {
        guard hasSelection, isPresented, interaction.rowModalID == modalID else {
            isPending = false
            return false
        }
        guard isPending,
              interaction.canFocusPickerConfirmation(
                presentation: presentation, modalID: modalID) else { return false }
        isPending = false
        return true
    }
}

@MainActor
@Observable
final class ArchiveInteractionState {
    private(set) var rowModalID: UUID?
    private var visibleRows: [String: UUID] = [:]
    var showDiscardLegacyConfirm = false
    var sceneIsActive = false

    func hasModal(presentation: FormPresentationState) -> Bool {
        presentation.archiveFormVisible || presentation.pendingFormProtectionWarning
            || showDiscardLegacyConfirm || rowModalID != nil
    }

    func canPresentPicker(presentation: FormPresentationState) -> Bool {
        presentation.selectedTab == .archive && presentation.isSceneActive && sceneIsActive
            && !hasModal(presentation: presentation)
    }

    func canFocusPickerConfirmation(
        presentation: FormPresentationState, modalID: UUID
    ) -> Bool {
        rowModalID == modalID && presentation.selectedTab == .archive
            && presentation.isSceneActive && sceneIsActive
            && !presentation.archiveFormVisible && !presentation.pendingFormProtectionWarning
            && !showDiscardLegacyConfirm
    }

    func beginRowModal(_ id: UUID, presentation: FormPresentationState) -> Bool {
        guard canPresentPicker(presentation: presentation) else { return false }
        rowModalID = id
        return true
    }

    @discardableResult
    func endRowModal(_ id: UUID) -> Bool {
        guard rowModalID == id else { return false }
        rowModalID = nil
        return true
    }

    func setRowVisible(assetId: String, instanceId: UUID, isVisible: Bool) {
        if isVisible {
            visibleRows[assetId] = instanceId
        } else if visibleRows[assetId] == instanceId {
            visibleRows.removeValue(forKey: assetId)
        }
    }

    func isCurrentRow(assetId: String, instanceId: UUID) -> Bool {
        visibleRows[assetId] == instanceId
    }

    func reset() {
        rowModalID = nil
        visibleRows.removeAll()
        showDiscardLegacyConfirm = false
    }
}

@MainActor
@Observable
final class ArchiveMediaTaskOwner {
    private struct Operation {
        let id: UUID
        let sessionGeneration: UUID
        let intent: ArchiveRetryIntent
        let task: Task<Void, Never>
        let onSuperseded: @MainActor (UUID) -> Void
        var networkStarted = false
    }

    private(set) var runningAssets: Set<ScopedUploadAsset> = []
    private(set) var finishingAssets: Set<ScopedUploadAsset> = []
    private(set) var retryMessages: [String: String] = [:]
    private(set) var completedAssetIDs: Set<String> = []
    private(set) var associationRevision = 0
    private var associationWarnings: [ScopedUploadAsset: String] = [:]
    private var associationRepairAssetIDs: Set<String> = []
    @ObservationIgnored private var operations: [ScopedUploadAsset: Operation] = [:]
    @ObservationIgnored private var cancelled: Set<UUID> = []
    @ObservationIgnored private var snapshotScope: PendingFormScope?
    @ObservationIgnored private var snapshotGeneration: UUID?
    @ObservationIgnored private var currentAssets: [String: Asset] = [:]
    @ObservationIgnored private var assetRevisions: [String: Int] = [:]

    func start(
        assetId: String, scope: PendingFormScope, sessionGeneration: UUID,
        intent: ArchiveRetryIntent,
        onSuperseded: @escaping @MainActor (UUID) -> Void = { _ in },
        onFinished: (@MainActor (UUID) -> Void)? = nil,
        operation: @escaping @MainActor (UUID) async -> Void
    ) -> Bool {
        let key = ScopedUploadAsset(scope: scope, assetId: assetId)
        guard operations[key] == nil,
              intentIsCurrent(intent, assetId: assetId, scope: scope,
                              sessionGeneration: sessionGeneration) else { return false }
        let id = UUID()
        let task = Task {
            await operation(id)
            finish(key: key, id: id)
            onFinished?(id)
        }
        operations[key] = Operation(
            id: id, sessionGeneration: sessionGeneration, intent: intent, task: task,
            onSuperseded: onSuperseded)
        runningAssets.insert(key)
        return true
    }

    func isRunning(assetId: String, scope: PendingFormScope?) -> Bool {
        guard let scope else { return false }
        return runningAssets.contains(ScopedUploadAsset(scope: scope, assetId: assetId))
    }

    func hasRunning(in scope: PendingFormScope) -> Bool {
        runningAssets.contains { $0.scope == scope }
    }

    func hasActive(in scope: PendingFormScope) -> Bool {
        operations.contains { key, operation in
            key.scope == scope && !cancelled.contains(operation.id)
        }
    }

    func isFinishing(assetId: String, scope: PendingFormScope?) -> Bool {
        guard let scope else { return false }
        return finishingAssets.contains(ScopedUploadAsset(scope: scope, assetId: assetId))
    }

    func owns(assetId: String, scope: PendingFormScope, id: UUID) -> Bool {
        operations[ScopedUploadAsset(scope: scope, assetId: assetId)]?.id == id
            && !cancelled.contains(id)
    }

    func markNetworkStarted(assetId: String, scope: PendingFormScope, id: UUID) -> Bool {
        let key = ScopedUploadAsset(scope: scope, assetId: assetId)
        guard owns(assetId: assetId, scope: scope, id: id),
              var operation = operations[key] else { return false }
        operation.networkStarted = true
        operations[key] = operation
        return true
    }

    func updateAssetSnapshot(
        _ assets: [Asset], scope: PendingFormScope, sessionGeneration: UUID
    ) {
        let updated = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        if snapshotScope != scope || snapshotGeneration != sessionGeneration {
            assetRevisions = Dictionary(uniqueKeysWithValues: updated.keys.map { ($0, 0) })
        } else {
            for assetId in Set(currentAssets.keys).union(updated.keys) {
                if currentAssets[assetId] != updated[assetId] {
                    assetRevisions[assetId, default: 0] += 1
                }
            }
        }
        snapshotScope = scope
        snapshotGeneration = sessionGeneration
        currentAssets = updated

        // A retired reader still owns its task and file cleanup. Once network work
        // may have started, keep the per-asset barrier until that task finishes.
        for (key, operation) in Array(operations) {
            guard !operation.networkStarted,
                  operations[key]?.id == operation.id,
                  !intentIsCurrent(
                    operation.intent, assetId: key.assetId, scope: key.scope,
                    sessionGeneration: operation.sessionGeneration) else { continue }
            runningAssets.remove(key)
            operations[key] = nil
            cancelled.remove(operation.id)
            operation.onSuperseded(operation.id)
            operation.task.cancel()
        }
    }

    func retryIntent(
        for asset: Asset, scope: PendingFormScope, sessionGeneration: UUID
    ) -> ArchiveRetryIntent? {
        guard snapshotScope == scope, snapshotGeneration == sessionGeneration,
              currentAssets[asset.id] == asset, asset.permitsDirectMuxRetry,
              let revision = assetRevisions[asset.id] else {
            return nil
        }
        return ArchiveRetryIntent(asset: asset, observationRevision: revision)
    }

    func allowsMediaActions(
        for asset: Asset, scope: PendingFormScope, sessionGeneration: UUID
    ) -> Bool {
        snapshotScope == scope && snapshotGeneration == sessionGeneration
            && currentAssets[asset.id]?.permitsMediaActions == true
    }

    func intentIsCurrent(
        _ intent: ArchiveRetryIntent, assetId: String,
        scope: PendingFormScope, sessionGeneration: UUID
    ) -> Bool {
        guard snapshotScope == scope, snapshotGeneration == sessionGeneration,
              let current = currentAssets[assetId],
              assetRevisions[assetId] == intent.observationRevision else { return false }
        return intent.permits(current)
    }

    func intentIsCurrent(assetId: String, scope: PendingFormScope, id: UUID) -> Bool {
        guard owns(assetId: assetId, scope: scope, id: id),
              let operation = operations[ScopedUploadAsset(scope: scope, assetId: assetId)] else {
            return false
        }
        return intentIsCurrent(
            operation.intent, assetId: assetId, scope: scope,
            sessionGeneration: operation.sessionGeneration)
    }

    func cancelAll() {
        for (key, operation) in Array(operations) {
            cancelled.insert(operation.id)
            operation.task.cancel()
            if !operation.networkStarted {
                operations[key] = nil
                runningAssets.remove(key)
                cancelled.remove(operation.id)
            }
        }
        retryMessages.removeAll()
        completedAssetIDs.removeAll()
        finishingAssets.removeAll()
        associationWarnings.removeAll()
        associationRepairAssetIDs.removeAll()
        snapshotScope = nil
        snapshotGeneration = nil
        currentAssets.removeAll()
        assetRevisions.removeAll()
    }

    func associationChanged() {
        associationRevision += 1
    }

    func associationWarning(assetId: String, scope: PendingFormScope?) -> String? {
        guard let scope else { return nil }
        return associationWarnings[ScopedUploadAsset(scope: scope, assetId: assetId)]
    }

    func setAssociationWarning(_ message: String?, assetId: String, scope: PendingFormScope) {
        associationWarnings[ScopedUploadAsset(scope: scope, assetId: assetId)] = message
    }

    func requireAssociationRepair(assetId: String, message: String) {
        associationRepairAssetIDs.insert(assetId)
        retryMessages[assetId] = message
    }

    func associationRepairCompleted() {
        for assetId in associationRepairAssetIDs {
            retryMessages[assetId] = nil
        }
        associationRepairAssetIDs.removeAll()
        associationChanged()
    }

    func clearAssociationRepairFailure(assetId: String) {
        if associationRepairAssetIDs.remove(assetId) != nil {
            retryMessages[assetId] = nil
        }
    }

    func beginRetry(assetId: String) {
        retryMessages[assetId] = nil
        completedAssetIDs.remove(assetId)
        associationRepairAssetIDs.remove(assetId)
    }

    func recordFailure(assetId: String, message: String) {
        associationRepairAssetIDs.remove(assetId)
        retryMessages[assetId] = message
    }

    func clearFailure(assetId: String) {
        associationRepairAssetIDs.remove(assetId)
        retryMessages[assetId] = nil
    }

    func recordCompletion(assetId: String, scope: PendingFormScope) {
        retryMessages[assetId] = nil
        completedAssetIDs.insert(assetId)
        finishingAssets.insert(ScopedUploadAsset(scope: scope, assetId: assetId))
    }

    func clearCompletion(assetId: String) {
        completedAssetIDs.remove(assetId)
    }

    private func finish(key: ScopedUploadAsset, id: UUID) {
        guard operations[key]?.id == id else { return }
        operations[key] = nil
        runningAssets.remove(key)
        finishingAssets.remove(key)
        cancelled.remove(id)
    }
}

nonisolated struct ArchiveRetryIntent {
    private let asset: Asset
    let observationRevision: Int

    init(asset: Asset, observationRevision: Int = 0) {
        self.asset = asset
        self.observationRevision = observationRevision
    }

    func permits(_ asset: Asset) -> Bool {
        self.asset.permitsDirectMuxRetry && asset.permitsDirectMuxRetry && self.asset == asset
    }
}

private struct ArchiveRowModalPresentation: Identifiable {
    enum Kind {
        case slack
        case picker(String)
        case repairPhotos
    }

    let id: UUID
    let kind: Kind
    let asset: Asset
    let rowID: UUID
    let session: ArchiveSessionIdentity
    let retryIntent: ArchiveRetryIntent?
    let associationSnapshot: ScopedPhotoAssociationSnapshot?
}

enum ArchiveModalFocusTarget: Equatable {
    case row
    case reupload
    case reuploadProgress
    case repairPhotos
    case slack
}

private struct ArchiveModalFocusRequest: Equatable {
    let assetId: String
    let target: ArchiveModalFocusTarget
}

@MainActor
struct ArchivePendingReuploadSelection: Identifiable {
    let id = UUID()
    let assetId: String
    let item: PhotosPickerItem
    let session: ArchiveSessionIdentity
    let intent: ArchiveRetryIntent
    let associationSnapshot: ScopedPhotoAssociationSnapshot
}

@MainActor
struct ArchiveSessionIdentity {
    let scope: PendingFormScope
    let serverURL: URL
    let generation: UUID
    let token: String

    init?(auth: AuthService, serverURL: URL = ServerConfig.baseURL) {
        guard let user = auth.currentUser, let token = auth.token,
              let scope = PendingFormScope(userId: user.id, serverURL: serverURL),
              let server = AuthServerIdentity.canonical(serverURL),
              auth.isCurrent(AuthenticatedSessionSnapshot(
                  generation: auth.sessionGeneration, token: token,
                  userId: user.id, server: server)) else { return nil }
        self.scope = scope
        self.serverURL = serverURL
        self.generation = auth.sessionGeneration
        self.token = token
    }

    func isCurrent(_ auth: AuthService, serverURL: URL = ServerConfig.baseURL) -> Bool {
        guard auth.sessionGeneration == generation, auth.token == token,
              serverURL == self.serverURL, let user = auth.currentUser,
              let server = AuthServerIdentity.canonical(serverURL),
              auth.isCurrent(AuthenticatedSessionSnapshot(
                  generation: generation, token: token, userId: scope.userId, server: server)),
              let currentScope = PendingFormScope(userId: user.id, serverURL: serverURL)
        else { return false }
        return currentScope == scope
    }

    func url(for path: String) -> URL? {
        URL(string: "\(serverURL.absoluteString)\(path)")
    }
}

/// Archive list — shows all of the user's past uploads in an expandable list.
struct ArchiveListView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var presentationState: FormPresentationState
    let mediaTasks: ArchiveMediaTaskOwner

    @State private var assets: [Asset] = []
    @State private var assetsSession: ArchiveSessionIdentity?
    @State private var completedAssetIDs: Set<String> = []
    @State private var refreshVersion = 0
    @State private var submittedFormData: [String: [String: String]] = [:]
    @State private var formPresentation: ArchiveFormPresentation?
    @State private var submittedFocusAssetID: String?
    @State private var focusAssetID: String?
    @State private var announcements = ArchiveAnnouncementQueue()
    @State private var completionAnnouncementFocus = ArchiveCompletionAnnouncementFocus()
    @State private var interaction = ArchiveInteractionState()
    @State private var rowModalPresentation: ArchiveRowModalPresentation?
    @State private var activeRowModal: ArchiveRowModalPresentation?
    @State private var selectedReuploadItem: PhotosPickerItem?
    @State private var pendingReuploadSelection: ArchivePendingReuploadSelection?
    @State private var photoRepairError: String?
    @AccessibilityFocusState private var photoRepairErrorIsFocused: Bool
    @State private var modalFocusRequest: ArchiveModalFocusRequest?
    @State private var pendingHeaderFocus = false
    @AccessibilityFocusState private var archiveHeaderIsFocused: Bool
    @State private var detailsFocusAssetID: String?
    @State private var hasLegacyForm = false
    @State private var legacyNotice: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var fetchGeneration = UUID()
    @State private var refreshFeedback = ArchiveRefreshFeedback()

    private var hasArchiveModal: Bool {
        interaction.hasModal(presentation: presentationState)
    }

    /// Keep unfinished uploads available for manual recovery regardless of age.
    private var visibleAssets: [Asset] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return assets.filter { completedAssetIDs.contains($0.id) || Self.isVisible($0, cutoff: cutoff) }
    }

    static func isVisible(_ asset: Asset, cutoff: Date) -> Bool {
        if asset.isModerated { return true }
        if asset.formResponse == nil || asset.status != .ready { return true }
        if let submittedAt = asset.formResponse?.submittedAt,
           let submitted = DVUDateFormatting.parseISO(submittedAt), submitted >= cutoff {
            return true
        }
        guard let dateStr = asset.createdAt,
              let date = DVUDateFormatting.parseISO(dateStr)
        else { return true }
        return date >= cutoff
    }

    private var stuckCount: Int {
        let now = Date()
        return visibleAssets.filter {
            !presentationState.isChatUploading(assetId: $0.id, scope: assetsSession?.scope)
                && (presentationState.failedChatUploadAssetIDs.contains($0.id)
                    || $0.needsUploadRecovery(at: now))
        }.count
    }

    var body: some View {
        @Bindable var interaction = interaction
        ZStack {
            // view background
            Theme.screenGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Archive")
                            .font(Theme.font20Bold)
                            .foregroundStyle(Theme.primaryText)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($archiveHeaderIsFocused)
                        Text(
                            "\(visibleAssets.count) upload\(visibleAssets.count == 1 ? "" : "s") (7 days + unfinished)"
                        )
                        .font(Theme.font13Regular)
                        .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()

                    Button {
                        Task { await refreshAssetsFromUser() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(Theme.icon20)
                            .foregroundStyle(Theme.blue)
                            .tapTarget()
                    }
                    .accessibilityLabel("Refresh")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.cardBg)

                Divider().background(Theme.separator)

                if let errorMessage, !assets.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.font13Regular)
                        .foregroundStyle(Theme.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.space12)
                }

                if hasLegacyForm || legacyNotice != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if hasLegacyForm {
                            Text("An older saved form has no account information. Add details in Archive or remove the saved copy.")
                                .font(Theme.font13Regular)
                                .foregroundStyle(Theme.primaryText)
                            Button("Remove Saved Form") { interaction.showDiscardLegacyConfirm = true }
                                .font(Theme.font13Semibold)
                                .foregroundStyle(Theme.blue)
                                .tapTarget()
                        }
                        if let legacyNotice {
                            Text(legacyNotice)
                                .font(Theme.font13Regular)
                                .foregroundStyle(Theme.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.space12)
                    .background(Theme.yellow.opacity(0.15))
                }

                // Stuck uploads banner
                if stuckCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.red)
                        Text(
                            "\(stuckCount) upload\(stuckCount == 1 ? "" : "s") failed — tap to expand and re-upload"
                        )
                        .font(Theme.font13Regular)
                        .foregroundStyle(Theme.primaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.red.opacity(0.15))
                }

                // Content
                if isLoading && assets.isEmpty {
                    Spacer()
                    ProgressView()
                        .tint(Theme.primaryText)
                    Spacer()
                } else if let error = errorMessage, assets.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("⚠️")
                            .font(Theme.display44)
                        Text(error)
                            .font(Theme.font13Regular)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button {
                            Task { await refreshAssetsFromUser() }
                        } label: {
                            Text("Retry")
                                .padding(.horizontal, Theme.space12)
                                .tapTarget()
                        }
                        .font(Theme.font13Regular)
                        .foregroundStyle(Theme.blue)
                    }
                    .padding()
                    Spacer()
                } else if visibleAssets.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("📦")
                            .font(Theme.display64)
                        Text("No recent uploads")
                            .font(Theme.font16Medium)
                            .foregroundStyle(Theme.primaryText)
                        Text("No uploads in the last 7 days or needing recovery.")
                            .font(Theme.font13Regular)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(visibleAssets) { asset in
                                    ArchiveRowView(
                                        asset: asset,
                                        submittedFormData: submittedFormData[asset.id],
                                        restoreFocus: focusAssetID == asset.id
                                            && presentationState.selectedTab == .archive
                                            && presentationState.isSceneActive
                                            && interaction.sceneIsActive
                                            && !hasArchiveModal
                                            && !completionAnnouncementFocus.hasPending
                                            && !completionAnnouncementFocus.isWaitingForVoiceOver,
                                        restoreModalFocus: modalFocusRequest?.assetId == asset.id
                                            && canFocusArchive
                                            && !completionAnnouncementFocus.hasPending
                                            && !completionAnnouncementFocus.isWaitingForVoiceOver
                                                ? modalFocusRequest?.target : nil,
                                        pendingReuploadSelection:
                                            pendingReuploadSelection?.assetId == asset.id
                                                ? pendingReuploadSelection : nil,
                                        presentationState: presentationState,
                                        interaction: interaction,
                                        mediaTasks: mediaTasks,
                                        assetSession: assetsSession,
                                        refreshVersion: $refreshVersion,
                                        onAddDetails: {
                                            guard let session = assetsSession,
                                                  session.isCurrent(auth) else {
                                                reportStaleAssets()
                                                return
                                            }
                                            focusAssetID = nil
                                            presentationState.archiveFormVisible = true
                                            detailsFocusAssetID = asset.id
                                            completedAssetIDs.insert(asset.id)
                                            formPresentation = ArchiveFormPresentation(
                                                asset: asset, session: session)
                                        },
                                        onUploadCompleted: {
                                            completedAssetIDs.insert(asset.id)
                                            presentationState.markUploadRecovered(assetId: asset.id)
                                            refreshFeedback.requestReuploadRefresh()
                                            let result = await fetchAssets()
                                            if case .succeeded = result {
                                                mediaTasks.clearCompletion(assetId: asset.id)
                                            }
                                            return result
                                        },
                                        onFocusRestored: {
                                            if focusAssetID == asset.id { focusAssetID = nil }
                                        },
                                        onModalFocusRestored: {
                                            if modalFocusRequest?.assetId == asset.id {
                                                modalFocusRequest = nil
                                            }
                                        },
                                        onPendingReuploadConsumed: { id in
                                            guard pendingReuploadSelection?.id == id else { return false }
                                            pendingReuploadSelection = nil
                                            return true
                                        },
                                        onReuploadProgressFocus: {
                                            requestModalFocus(assetId: asset.id, target: .reuploadProgress)
                                        },
                                        onRepairPhotoLinks: { rowID in
                                            presentRowModal(.repairPhotos, asset: asset, rowID: rowID)
                                        },
                                        onShowSlack: { rowID in
                                            guard assetsSession?.isCurrent(auth) == true else {
                                                reportStaleAssets()
                                                return
                                            }
                                            if !presentRowModal(
                                                .slack, asset: asset, rowID: rowID)
                                            {
                                                enqueueAnnouncement(
                                                    "Close the current sheet before sharing.")
                                            }
                                        },
                                        onPickVideo: { rowID, message, associationSnapshot in
                                            presentRowModal(
                                                .picker(message), asset: asset, rowID: rowID,
                                                associationSnapshot: associationSnapshot)
                                        },
                                        onVisibilityChange: { rowID, isVisible in
                                            interaction.setRowVisible(
                                                assetId: asset.id, instanceId: rowID,
                                                isVisible: isVisible)
                                        },
                                        onReuploadAnnouncement: { announcement in
                                            let title = asset.originalFileName
                                                ?? asset.mediasourceId ?? "Upload"
                                            enqueueAnnouncement("\(title): \(announcement)")
                                        },
                                        onReuploadCompletion: { announcement, restoreFocus in
                                            let title = asset.originalFileName
                                                ?? asset.mediasourceId ?? "Upload"
                                            if modalFocusRequest?.assetId == asset.id,
                                               modalFocusRequest?.target == .reuploadProgress {
                                                modalFocusRequest = nil
                                            }
                                            completionAnnouncementFocus.enqueue(
                                                focusAssetID: restoreFocus ? asset.id : nil)
                                            enqueueAnnouncement("\(title): \(announcement)")
                                        })
                                    .id(asset.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: focusAssetID) { _, assetID in
                            if let assetID { proxy.scrollTo(assetID, anchor: .center) }
                        }
                        .onChange(of: modalFocusRequest) { _, request in
                            if let request { proxy.scrollTo(request.assetId, anchor: .center) }
                        }
                        .onChange(of: pendingReuploadSelection?.id) { _, _ in
                            if let pendingReuploadSelection {
                                proxy.scrollTo(pendingReuploadSelection.assetId, anchor: .center)
                            }
                        }
                        .onChange(of: presentationState.selectedTab) { _, tab in
                            if tab == .archive, let pendingReuploadSelection {
                                proxy.scrollTo(pendingReuploadSelection.assetId, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .task {
            refreshLegacyFormStatus()
            await fetchAssets()
        }
        .confirmationDialog(
            "Remove the older saved form?", isPresented: $interaction.showDiscardLegacyConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove Saved Form", role: .destructive) { discardLegacyForm() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its account is unknown. This removes the saved copy from this device and cannot be undone. Server videos are not deleted.")
        }
        .sheet(item: $rowModalPresentation, onDismiss: finishRowModal) { modal in
            switch modal.kind {
            case .slack:
                SlackShareSheet(
                    mediasourceId: modal.asset.mediasourceId,
                    originalFileName: modal.asset.originalFileName,
                    onSend: { text in
                        guard rowModalIsCurrent(modal) else { return }
                        rowModalPresentation = nil
                        ws.sendMessage(text: text, assetId: modal.asset.id)
                    },
                    onDismiss: {
                        if rowModalIsCurrent(modal) { rowModalPresentation = nil }
                    })
            case .picker(let message):
                ArchiveReuploadPicker(
                    message: message,
                    modalID: modal.id,
                    presentationState: presentationState,
                    interaction: interaction,
                    isPresented: { rowModalIsCurrent(modal) },
                    onSelect: { item in
                        guard rowModalIsCurrent(modal) else { return }
                        selectedReuploadItem = item
                        rowModalPresentation = nil
                    },
                    onCancel: {
                        if rowModalIsCurrent(modal) { rowModalPresentation = nil }
                    })
            case .repairPhotos:
                photoRepairSheet(modal)
            }
        }
        .sheet(item: $formPresentation, onDismiss: {
            presentationState.archiveFormVisible = false
            let assetID = detailsFocusAssetID ?? submittedFocusAssetID
            if submittedFocusAssetID != nil { announcements.append("Details sent.") }
            submittedFocusAssetID = nil
            detailsFocusAssetID = nil
            if let assetID { focusAssetID = assetID }
            announceIfPossible()
            if assetID != nil { Task { await fetchAssets() } }
        }) { presentation in
            ArchiveDetailsSheet(presentation: presentation) { formData in
                guard presentation.session.isCurrent(auth) else { return }
                let asset = presentation.asset
                if !assets.contains(where: { $0.id == asset.id }) { assets.append(asset) }
                completedAssetIDs.insert(asset.id)
                submittedFormData[asset.id] = formData
                submittedFocusAssetID = asset.id
                presentationState.completedDetailsAssetIDs.insert(asset.id)
            }
        }
        .onChange(of: auth.sessionGeneration) { _, _ in
            fetchGeneration = UUID()
            formPresentation = nil
            presentationState.archiveFormVisible = false
            assets = []
            assetsSession = nil
            completedAssetIDs = []
            submittedFormData = [:]
            submittedFocusAssetID = nil
            focusAssetID = nil
            announcements = ArchiveAnnouncementQueue()
            completionAnnouncementFocus = ArchiveCompletionAnnouncementFocus()
            rowModalPresentation = nil
            activeRowModal = nil
            selectedReuploadItem = nil
            pendingReuploadSelection = nil
            photoRepairError = nil
            modalFocusRequest = nil
            pendingHeaderFocus = false
            interaction.reset()
            detailsFocusAssetID = nil
            refreshLegacyFormStatus()
            isLoading = false
            errorMessage = nil
            refreshFeedback = ArchiveRefreshFeedback()
            if auth.isAuthenticated, auth.currentUser != nil {
                Task { await fetchAssets() }
            }
        }
        .onChange(of: presentationState.selectedTab) { _, _ in archivePresentationChanged() }
        .onChange(of: presentationState.pendingFormProtectionWarning) { _, _ in
            archivePresentationChanged()
        }
        .onChange(of: presentationState.isSceneActive) { _, _ in archivePresentationChanged() }
        .onChange(of: presentationState.archiveFormVisible) { _, _ in archivePresentationChanged() }
        .onChange(of: interaction.showDiscardLegacyConfirm) { _, _ in archivePresentationChanged() }
        .onChange(of: interaction.rowModalID) { _, _ in archivePresentationChanged() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            interaction.sceneIsActive = phase == .active
            archivePresentationChanged()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIAccessibility.announcementDidFinishNotification)
        ) { notification in
            let value = notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey]
            let message = (value as? String) ?? (value as? NSAttributedString)?.string
            let successful = (notification.userInfo?[
                UIAccessibility.announcementWasSuccessfulUserInfoKey] as? NSNumber)?.boolValue ?? false
            guard let message else { return }
            let isBlocked = !canFocusArchive
            guard let finished = completionAnnouncementFocus.finish(
                message, wasSuccessful: successful, isPresentationBlocked: isBlocked) else { return }
            if let interrupted = finished.interruptedAnnouncement {
                announcements.prepend(interrupted)
                if !completionAnnouncementFocus.hasPending {
                    completionAnnouncementFocus.enqueue(focusAssetID: nil)
                }
            }
            restoreCompletionFocusIfPossible(finished.focusAssetID)
            announceIfPossible()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIAccessibility.voiceOverStatusDidChangeNotification)
        ) { _ in
            guard !UIAccessibility.isVoiceOverRunning else { return }
            let focusAssetID = completionAnnouncementFocus.cancelSpeaking()
            restoreCompletionFocusIfPossible(focusAssetID)
            announceIfPossible()
        }
    }

    // MARK: - Fetch

    private func presentRowModal(
        _ kind: ArchiveRowModalPresentation.Kind, asset: Asset, rowID: UUID,
        associationSnapshot: ScopedPhotoAssociationSnapshot? = nil
    ) -> Bool {
        guard pendingReuploadSelection == nil,
              let session = assetsSession, session.isCurrent(auth),
              mediaTasks.allowsMediaActions(
                for: asset, scope: session.scope, sessionGeneration: session.generation),
              interaction.isCurrentRow(assetId: asset.id, instanceId: rowID) else { return false }
        let retryIntent: ArchiveRetryIntent?
        if case .picker = kind {
            guard let associationSnapshot,
                  associationSnapshot.matches(assetId: asset.id, scope: session.scope),
                  let intent = mediaTasks.retryIntent(
                for: asset, scope: session.scope, sessionGeneration: session.generation
            ) else { return false }
            retryIntent = intent
        } else {
            retryIntent = nil
        }
        let id = UUID()
        guard interaction.beginRowModal(id, presentation: presentationState) else { return false }
        let modal = ArchiveRowModalPresentation(
            id: id, kind: kind, asset: asset, rowID: rowID,
            session: session, retryIntent: retryIntent, associationSnapshot: associationSnapshot)
        selectedReuploadItem = nil
        photoRepairError = nil
        activeRowModal = modal
        rowModalPresentation = modal
        return true
    }

    private func rowModalIsCurrent(_ modal: ArchiveRowModalPresentation) -> Bool {
        activeRowModal?.id == modal.id && rowModalPresentation?.id == modal.id
            && modal.session.isCurrent(auth)
            && mediaTasks.allowsMediaActions(
                for: modal.asset, scope: modal.session.scope,
                sessionGeneration: modal.session.generation)
    }

    private func finishRowModal() {
        guard let modal = activeRowModal else { return }
        let item = selectedReuploadItem
        activeRowModal = nil
        selectedReuploadItem = nil
        guard interaction.endRowModal(modal.id),
              modal.session.isCurrent(auth) else { return }

        switch modal.kind {
        case .picker:
            if let item {
                guard let intent = modal.retryIntent,
                      let associationSnapshot = modal.associationSnapshot,
                      associationSnapshot.matches(
                        assetId: modal.asset.id, scope: modal.session.scope),
                      visibleAssets.contains(where: { $0.id == modal.asset.id }),
                      mediaTasks.intentIsCurrent(
                        intent, assetId: modal.asset.id, scope: modal.session.scope,
                        sessionGeneration: modal.session.generation) else {
                    enqueueAnnouncement(
                        "The selected video wasn't used because this upload changed. Refresh Archive before retrying.")
                    requestModalFocus(assetId: modal.asset.id, target: .row)
                    announceIfPossible()
                    return
                }
                pendingReuploadSelection = ArchivePendingReuploadSelection(
                    assetId: modal.asset.id, item: item, session: modal.session, intent: intent,
                    associationSnapshot: associationSnapshot)
            } else {
                requestModalFocus(assetId: modal.asset.id, target: .reupload)
            }
        case .slack:
            requestModalFocus(assetId: modal.asset.id, target: .slack)
        case .repairPhotos:
            requestModalFocus(assetId: modal.asset.id, target: .repairPhotos)
        }
        if pendingReuploadSelection == nil { announceIfPossible() }
    }

    private func photoRepairSheet(_ modal: ArchiveRowModalPresentation) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Repair saved photo links")
                        .font(.title2.weight(.semibold))
                    Text("The damaged file will be kept on this device. Existing photo links may no longer be available. Archive retries require choosing the video manually.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if let photoRepairError {
                        Text(photoRepairError)
                            .font(.footnote)
                            .foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityFocused($photoRepairErrorIsFocused)
                            .task(id: photoRepairError) { photoRepairErrorIsFocused = true }
                    }
                    Button("Repair Saved Links", role: .destructive) {
                        repairPhotoLinks(modal)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel", role: .cancel) { rowModalPresentation = nil }
                        .buttonStyle(.bordered)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.black)
            .foregroundStyle(Theme.white)
            .navigationTitle("Photo Link Repair")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func repairPhotoLinks(_ modal: ArchiveRowModalPresentation) {
        guard rowModalIsCurrent(modal) else { return }
        guard !mediaTasks.hasActive(in: modal.session.scope) else {
            reportPhotoRepairError("Wait for active re-uploads to finish, then try again.")
            return
        }
        do {
            let repaired = try ScopedPHAssetIdentifierStore.shared
                .quarantineDamagedAssociations(for: modal.session.scope)
            if repaired {
                presentationState.photoAssociatedAssetIDs.removeAll()
            }
            mediaTasks.associationRepairCompleted()
            rowModalPresentation = nil
            enqueueAnnouncement(repaired
                ? "Damaged photo links were kept on this device. Choose videos manually when retrying."
                : "The saved photo links no longer need repair.")
        } catch {
            Log.error("⚠️ [Archive] Could not repair saved photo links: \(Log.describe(error))", logger: Log.media)
            reportPhotoRepairError(
                "Couldn't repair the saved links. Unlock this device and try again; contact support if the problem continues.")
        }
    }

    private func reportPhotoRepairError(_ message: String) {
        photoRepairError = message
        AccessibilityNotification.Announcement(message).post()
    }

    private var canFocusArchive: Bool {
        presentationState.selectedTab == .archive && presentationState.isSceneActive
            && interaction.sceneIsActive && scenePhase == .active && !hasArchiveModal
    }

    private func requestModalFocus(assetId: String, target: ArchiveModalFocusTarget) {
        if visibleAssets.contains(where: { $0.id == assetId }) {
            modalFocusRequest = ArchiveModalFocusRequest(assetId: assetId, target: target)
        } else {
            pendingHeaderFocus = true
        }
    }

    private func reportStaleAssets() {
        let message = "Your account or server changed. Refresh Archive before continuing."
        errorMessage = message
        enqueueAnnouncement(message)
    }

    private func refreshAssetsFromUser() async {
        refreshFeedback.requestManualRefresh()
        await fetchAssets()
    }

    private struct ArchiveReuploadPicker: View {
        let message: String
        let modalID: UUID
        let presentationState: FormPresentationState
        let interaction: ArchiveInteractionState
        let isPresented: () -> Bool
        let onSelect: (PhotosPickerItem) -> Void
        let onCancel: () -> Void

        @State private var selection: PhotosPickerItem?
        @State private var pendingConfirmationFocus = ArchivePickerConfirmationFocus()
        @AccessibilityFocusState private var confirmationIsFocused: Bool

        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.space12)
                    if let selection {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Confirm the selected video")
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityFocused($confirmationIsFocused)
                                Text("This selection may change the footage. Make sure it is the correct original or saved trim. The server may keep earlier upload details, including location.")
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Use selected video") { onSelect(selection) }
                                    .buttonStyle(.borderedProminent)
                            }
                            .foregroundStyle(Theme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.space12)
                        }
                        .frame(maxHeight: 220)
                    }
                    PhotosPicker(
                        selection: $selection, matching: .videos,
                        preferredItemEncoding: .current, photoLibrary: .shared()
                    ) {
                        EmptyView()
                    }
                    .photosPickerStyle(.inline)
                    .photosPickerDisabledCapabilities(.selectionActions)
                }
                .background(Theme.cardBg)
                .navigationTitle("Choose Video")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel", action: onCancel)
                    }
                }
                .onChange(of: selection) { _, item in
                    pendingConfirmationFocus.selectionChanged(hasSelection: item != nil)
                    if item == nil { confirmationIsFocused = false }
                    focusConfirmationIfPossible()
                }
            }
            .presentationDetents([.large])
            .onChange(of: presentationState.generation) { _, _ in focusConfirmationIfPossible() }
            .onChange(of: interaction.sceneIsActive) { _, _ in focusConfirmationIfPossible() }
            .onChange(of: interaction.showDiscardLegacyConfirm) { _, _ in focusConfirmationIfPossible() }
            .onChange(of: interaction.rowModalID) { _, _ in focusConfirmationIfPossible() }
            .onChange(of: isPresented()) { _, _ in focusConfirmationIfPossible() }
        }

        private func focusConfirmationIfPossible() {
            if pendingConfirmationFocus.consumeIfPossible(
                hasSelection: selection != nil, isPresented: isPresented(),
                presentation: presentationState, interaction: interaction, modalID: modalID
            ) {
                confirmationIsFocused = true
            }
        }
    }

    private func completeRefresh(_ result: ArchiveRefreshResult) -> ArchiveRefreshResult {
        if let announcement = refreshFeedback.complete(result) {
            enqueueAnnouncement(announcement)
        }
        return result
    }

    private func enqueueAnnouncement(_ announcement: String) {
        announcements.append(announcement)
        announceIfPossible()
    }

    private func archivePresentationChanged() {
        if !canFocusArchive { completionAnnouncementFocus.presentationBlocked() }
        announceIfPossible()
    }

    private func restoreCompletionFocusIfPossible(_ assetID: String?) {
        guard canFocusArchive, pendingReuploadSelection == nil else { return }
        if !announcements.pending.isEmpty {
            if completionAnnouncementFocus.hasPending {
                completionAnnouncementFocus.preserveFocusIfAbsent(assetID)
            } else if assetID != nil || pendingHeaderFocus || modalFocusRequest != nil || focusAssetID != nil {
                completionAnnouncementFocus.enqueue(focusAssetID: assetID)
            }
            return
        }
        guard let assetID, modalFocusRequest == nil,
              focusAssetID == nil, !pendingHeaderFocus else { return }
        requestModalFocus(assetId: assetID, target: .row)
    }

    private func announceIfPossible() {
        guard !completionAnnouncementFocus.isWaitingForVoiceOver else { return }
        if pendingHeaderFocus && canFocusArchive && !completionAnnouncementFocus.hasPending {
            pendingHeaderFocus = false
            archiveHeaderIsFocused = true
        }
        guard pendingReuploadSelection == nil else { return }
        let isActive = presentationState.selectedTab == .archive
            && presentationState.isSceneActive && interaction.sceneIsActive && scenePhase == .active
        if let announcement = announcements.takeIfPossible(
            isActive: isActive, hasModal: hasArchiveModal
        ) {
            let focusAssetID = completionAnnouncementFocus.beginPost(
                announcement, voiceOverRunning: UIAccessibility.isVoiceOverRunning)
            // Use the UIKit announcement paired with the finish notification above.
            UIAccessibility.post(notification: .announcement, argument: announcement)
            if !completionAnnouncementFocus.isWaitingForVoiceOver {
                restoreCompletionFocusIfPossible(focusAssetID)
                if pendingHeaderFocus && canFocusArchive {
                    pendingHeaderFocus = false
                    archiveHeaderIsFocused = true
                }
            }
        }
    }

    private func refreshLegacyFormStatus() {
        do {
            hasLegacyForm = try PendingFormStore.shared.hasLegacyForm
            legacyNotice = nil
            if hasLegacyForm { try PendingFormStore.shared.protectLegacyForm() }
        } catch {
            Log.error("⚠️ [Archive] Could not check or protect legacy recovery state: \(Log.describe(error))", logger: Log.media)
            let message = "Couldn't check or protect an older saved form. Unlock this device and try again."
            legacyNotice = message
            enqueueAnnouncement(message)
        }
    }

    private func discardLegacyForm() {
        do {
            try PendingFormStore.shared.discardLegacyForm()
            hasLegacyForm = false
            legacyNotice = nil
            enqueueAnnouncement("Older saved form removed.")
        } catch {
            Log.error("⚠️ [Archive] Could not remove legacy recovery state: \(Log.describe(error))", logger: Log.media)
            let message = "The older saved form couldn't be removed. Please try again."
            legacyNotice = message
            enqueueAnnouncement(message)
        }
    }

    @discardableResult
    private func fetchAssets() async -> ArchiveRefreshResult {
        guard let session = ArchiveSessionIdentity(auth: auth),
              let url = session.url(for: "/api/assets/mine")
        else {
            errorMessage = "Couldn't access Archive. Check your account and server address."
            return completeRefresh(.failed)
        }

        let generation = UUID()
        fetchGeneration = generation
        isLoading = true
        errorMessage = nil
        defer {
            if fetchGeneration == generation { isLoading = false }
        }

        func isCurrent() -> Bool {
            fetchGeneration == generation && session.isCurrent(auth)
        }

        do {
            let request = try auth.authenticatedRequest(for: url)
            let (data, response) = try await RedirectSafeTransport.data(for: request)
            guard isCurrent() else { return .superseded }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.error("⚠️ [Archive] Invalid or unsuccessful response", logger: Log.network)
                errorMessage = "Couldn't refresh Archive. Please try again."
                return completeRefresh(.failed)
            }
            let decoded = try JSONDecoder().decode(MyAssetsResponse.self, from: data)
            assets = decoded.assets
            assetsSession = session
            mediaTasks.updateAssetSnapshot(
                decoded.assets, scope: session.scope, sessionGeneration: session.generation)
            refreshVersion += 1
            if let pendingReuploadSelection,
               (!visibleAssets.contains(where: { $0.id == pendingReuploadSelection.assetId })
                || !decoded.assets.contains(where: {
                    $0.id == pendingReuploadSelection.assetId && $0.permitsMediaActions
                })) {
                self.pendingReuploadSelection = nil
                pendingHeaderFocus = true
                announcements.append(
                    "The selected video wasn't used because this upload is paused or no longer available.")
            }
            if let modal = activeRowModal,
               !decoded.assets.contains(where: {
                   $0.id == modal.asset.id && $0.permitsMediaActions
               }) {
                rowModalPresentation = nil
                selectedReuploadItem = nil
                enqueueAnnouncement(
                    "Playback, sharing, and re-upload are unavailable while this video is paused.")
            }
            if let modalFocusRequest,
               !visibleAssets.contains(where: { $0.id == modalFocusRequest.assetId }) {
                self.modalFocusRequest = nil
                pendingHeaderFocus = true
            }
            if let focusAssetID, !visibleAssets.contains(where: { $0.id == focusAssetID }) {
                self.focusAssetID = nil
                pendingHeaderFocus = true
            }
            let result = completeRefresh(.succeeded)
            announceIfPossible()
            return result
        } catch {
            guard isCurrent() else { return .superseded }
            Log.error("⚠️ [Archive] Could not load uploads: \(Log.describe(error))", logger: Log.network)
            errorMessage = "Couldn't refresh Archive. Please try again."
            return completeRefresh(.failed)
        }
    }
}
