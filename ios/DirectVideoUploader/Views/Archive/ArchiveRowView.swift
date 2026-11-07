import AVFoundation
import Photos
import PhotosUI
// May 10, 2026 - 1:55pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

enum ArchiveRetryError: Error {
    case intentChanged
}

@MainActor
enum ArchiveRetryVideoLoad {
    static func resolve(
        _ result: Result<VideoTransferable?, any Error>,
        validate: () throws -> Void
    ) throws -> VideoTransferable? {
        do {
            try validate()
        } catch {
            if case .success(let movie?) = result {
                removeTemporaryVideoItem(movie.url.deletingLastPathComponent())
            }
            throw error
        }
        return try result.get()
    }
}

@MainActor
enum ArchiveRetryVerification {
    static func resolve(
        _ result: Result<ScopedPhotoAssociation?, any Error>,
        validate: () throws -> Void,
        onMissing: () -> Void,
        onFailure: (any Error) -> Void
    ) throws -> ScopedPhotoAssociation? {
        try validate()
        switch result {
        case .success(let association):
            if association == nil { onMissing() }
            return association
        case .failure(let error):
            if error is ArchiveRetryError { throw error }
            onFailure(error)
            return nil
        }
    }
}

@MainActor
enum ArchiveRetryPhotoLink {
    enum Outcome: Sendable {
        case committed(ScopedPhotoAssociation?)
        case superseded
        case associationChanged
        case storageFailure(any Error)

        var warningMessage: String? {
            switch self {
            case .committed(let association):
                return association == nil
                    ? "Upload finished without a verified Photos link. Choose the video manually if you retry."
                    : nil
            case .superseded:
                return "Upload finished, but its saved Photos link wasn't changed because the upload changed. Choose the video manually if you retry."
            case .associationChanged:
                return "Upload finished, but its saved Photos link changed during the retry. Choose the video manually if you retry."
            case .storageFailure:
                return "Upload finished, but its saved Photos link couldn't be updated. Choose the video manually if you retry."
            }
        }

        var completionAnnouncement: String {
            if case .storageFailure(let error) = self, isDamagedPhotoAssociationStore(error) {
                return "Re-upload complete, but saved photo links were damaged. If not already repaired, choose Repair saved photo links before retrying, then choose the video manually. Video processing continues."
            }
            if let warningMessage {
                return "\(warningMessage) Video processing continues."
            }
            return "Re-upload complete. Video processing continues."
        }
    }

    static func uploadAndCommit(
        store: ScopedPHAssetIdentifierStore, snapshot: ScopedPhotoAssociationSnapshot,
        assetId: String, scope: PendingFormScope, association: ScopedPhotoAssociation?,
        isCurrent: @MainActor () -> Bool, onOutcome: @MainActor (Outcome) -> Void,
        upload: @MainActor () async throws -> Void
    ) async throws -> Outcome {
        try await upload()
        let outcome: Outcome
        if Task.isCancelled || !isCurrent() {
            outcome = .superseded
        } else {
            do {
                outcome = try store.replaceIfUnchanged(
                    assetId: assetId, association: association, for: scope, expected: snapshot)
                    ? .committed(association) : .associationChanged
            } catch {
                outcome = .storageFailure(error)
            }
        }
        // Publish while still on the same actor turn as the identity check and commit.
        onOutcome(outcome)
        return outcome
    }
}

enum ArchiveReuploadNotice {
    static let repairRequired =
        "Saved photo links need repair. Choose Repair saved photo links before retrying."

    static func preferred(
        reuploadNotice: String?, refreshWarning: String?, photoWarning: String?,
        readWarning: String?, displayedError: String?, isDamaged: Bool
    ) -> String? {
        if isDamaged { return repairRequired }
        guard displayedError == nil else { return nil }
        return reuploadNotice ?? refreshWarning ?? photoWarning ?? readWarning
    }

    static func distinctError(_ error: String?, isDamaged: Bool) -> String? {
        if isDamaged && error == repairRequired { return nil }
        return error
    }
}

@MainActor
struct ArchiveRetryVerificationProgress {
    private(set) var operationID: UUID?
    var isVerifying: Bool { operationID != nil }

    mutating func begin(_ id: UUID) { operationID = id }

    mutating func finish(_ id: UUID) {
        if operationID == id { operationID = nil }
    }

    mutating func reset() { operationID = nil }
}

/// A single expandable row in the archive list showing upload metadata and actions.
struct ArchiveRowView: View {
    let asset: Asset
    var submittedFormData: [String: String]?
    var restoreFocus = false
    var restoreModalFocus: ArchiveModalFocusTarget?
    var pendingReuploadSelection: ArchivePendingReuploadSelection?
    let presentationState: FormPresentationState
    let interaction: ArchiveInteractionState
    let mediaTasks: ArchiveMediaTaskOwner
    let assetSession: ArchiveSessionIdentity?
    @Binding var refreshVersion: Int
    var onAddDetails: () -> Void
    var onUploadCompleted: () async -> ArchiveRefreshResult
    var onFocusRestored: () -> Void
    var onModalFocusRestored: () -> Void
    var onPendingReuploadConsumed: (UUID) -> Bool
    var onReuploadProgressFocus: () -> Void
    var onRepairPhotoLinks: (UUID) -> Bool
    var onShowSlack: (UUID) -> Void
    var onPickVideo: (UUID, String, ScopedPhotoAssociationSnapshot) -> Bool
    var onVisibilityChange: (UUID, Bool) -> Void
    var onReuploadAnnouncement: (String) -> Void
    var onReuploadCompletion: (String, Bool) -> Void
    @Environment(AuthService.self) private var auth
    @State private var rowID = UUID()
    @State private var isExpanded = false
    @AccessibilityFocusState private var rowIsFocused: Bool
    @AccessibilityFocusState private var reuploadProgressIsFocused: Bool
    @AccessibilityFocusState private var reuploadActionIsFocused: Bool
    @AccessibilityFocusState private var repairActionIsFocused: Bool
    @AccessibilityFocusState private var addDetailsIsFocused: Bool
    @AccessibilityFocusState private var slackActionIsFocused: Bool

    // Re-upload state
    @State private var isReuploadingVideo = false
    @State private var reuploadProgress: Double = 0
    @State private var reuploadError: String?
    @State private var reuploadErrorRequiresRepair = false
    @State private var reuploadComplete = false
    @State private var reuploadCompletionRefreshVersion: Int?
    @State private var reuploadNotice: String?
    @State private var reuploadRefreshWarning: String?
    @State private var photoAssociationWarning: String?
    @State private var photoAssociationReadWarning: String?
    @State private var photoAssociationDamaged = false
    @State private var verificationProgress = ArchiveRetryVerificationProgress()
    @State private var reuploadSession: ArchiveSessionIdentity?

    private var isVerifyingReupload: Bool { verificationProgress.isVerifying }

    private var isArchiveActive: Bool {
        presentationState.selectedTab == .archive
            && presentationState.isSceneActive && interaction.sceneIsActive
    }

    private var isArchiveModalVisible: Bool {
        interaction.hasModal(presentation: presentationState)
    }

    private var hasActiveChatUpload: Bool {
        presentationState.isChatUploading(assetId: asset.id, scope: assetSession?.scope)
    }

    private var hasActiveArchiveUpload: Bool {
        mediaTasks.isRunning(assetId: asset.id, scope: assetSession?.scope)
    }

    private var hasCompletedReupload: Bool {
        reuploadComplete || mediaTasks.completedAssetIDs.contains(asset.id)
            || mediaTasks.isFinishing(assetId: asset.id, scope: assetSession?.scope)
    }

    /// Asset has no form response and user hasn't just submitted one
    private var needsDetails: Bool {
        asset.formResponse == nil && submittedFormData == nil
    }

    /// Upload is stuck if it has not advanced beyond uploading or processing.
    var isStuckProcessing: Bool {
        asset.status != .error && asset.needsUploadRecovery(at: Date())
    }

    /// Consolidated display state — single source of truth for both the badge and
    /// the action buttons section. Priority order matters: check in this sequence.
    enum RowStatus {
        case needsDetails  // yellow — form not yet filled
        case failed  // red — error or stuck processing
        case reuploading  // blue — active re-upload in progress
        case processing  // blue — waiting for Mux
        case ready  // green — fully processed
    }

    private var rowStatus: RowStatus {
        let completed = hasCompletedReupload
        return Self.resolveStatus(
            assetStatus: asset.status, needsDetails: needsDetails,
            isStuck: isStuckProcessing,
            isReuploading: isReuploadingVideo
                || (hasActiveArchiveUpload && !completed),
            hasReuploadError: reuploadError != nil || mediaTasks.retryMessages[asset.id] != nil
                || presentationState.failedChatUploadAssetIDs.contains(asset.id),
            reuploadComplete: completed,
            isChatUploading: hasActiveChatUpload)
    }

    static func resolveStatus(
        assetStatus: AssetStatus, needsDetails: Bool, isStuck: Bool,
        isReuploading: Bool, hasReuploadError: Bool, reuploadComplete: Bool,
        isChatUploading: Bool = false
    ) -> RowStatus {
        if isChatUploading { return .processing }
        if isReuploading { return .reuploading }
        if hasReuploadError { return .failed }
        if reuploadComplete { return .processing }
        if assetStatus == .error || isStuck { return .failed }
        if assetStatus == .processing || assetStatus == .uploading { return .processing }
        if needsDetails { return .needsDetails }
        return .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Collapsed Row (always visible)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    // Thumbnail
                    if let thumbnailUrl = asset.clips?.first?.thumbnailUrl,
                        let url = URL(string: thumbnailUrl)
                    {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.radiusSm)
                                    .fill(Theme.cardBg)
                                Image(systemName: "film")
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                        }
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.radiusSm)
                                .fill(Theme.cardBg)
                                .frame(width: 50, height: 50)
                            Text("🎬")
                                .font(Theme.display32)
                        }
                    }

                    // File info
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            asset.formResponse?.slug ?? asset.originalFileName ?? asset
                                .mediasourceId ?? asset.id
                        )
                        .font(Theme.font16Medium)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(asset.mediasourceId ?? asset.id)
                                .font(Theme.mono13Medium)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)

                            switch rowStatus {
                            case .needsDetails:
                                Circle()
                                    .fill(Theme.yellow)
                                    .frame(width: Theme.statusDotSize, height: Theme.statusDotSize)
                                Text("Needs Details")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.warningText)
                            case .failed:
                                Circle()
                                    .fill(Theme.red)
                                    .frame(width: Theme.statusDotSize, height: Theme.statusDotSize)
                                Text("Upload Failed")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.errorText)
                            case .reuploading:
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text(isReuploadingVideo
                                    ? "Uploading \(Int(reuploadProgress * 100))%" : "Re-uploading")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.blue)
                            case .processing:
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text(hasActiveChatUpload ? "Uploading" : "Processing")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.blue)
                            case .ready:
                                Circle()
                                    .fill(Theme.green)
                                    .frame(width: Theme.statusDotSize, height: Theme.statusDotSize)
                                Text("Ready")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.green)
                            }
                            if needsDetails && rowStatus != .needsDetails {
                                Text("Needs Details")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.warningText)
                            }
                        }
                    }

                    Spacer()

                    // Date + chevron
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(formatShortDate(asset.createdAt))
                            .font(Theme.font11Regular)
                            .foregroundStyle(Theme.secondaryText)

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(Theme.icon11)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityFocused($rowIsFocused)

            // MARK: - Expanded Detail
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                        .background(Theme.separator)

                    // Metadata grid
                    VStack(alignment: .leading, spacing: 6) {
                        if let mid = asset.mediasourceId {
                            metadataRow(label: "Mediasource", value: mid)
                        }
                        if let slug = asset.formResponse?.slug ?? submittedFormData?["slug"],
                            !slug.isEmpty
                        {
                            metadataRow(label: "Slug", value: slug)
                        }
                        if let desc = asset.formResponse?.description
                            ?? submittedFormData?["description"], !desc.isEmpty
                        {
                            metadataRow(label: "Description", value: desc)
                        }
                        if let type = asset.formResponse?.type ?? submittedFormData?["type"],
                            !type.isEmpty
                        {
                            metadataRow(label: "Type", value: type)
                        }
                        if let priority = asset.formResponse?.priority
                            ?? submittedFormData?["priority"], !priority.isEmpty
                        {
                            metadataRow(label: "Priority", value: priority)
                        }

                        // Clip metadata (first clip)
                        if let clip = asset.clips?.first {
                            if let captured = clip.capturedAt {
                                metadataRow(label: "Recorded", value: formatShortDate(captured))
                            }

                            let techSpec = [clip.resolution, clip.codec].compactMap { $0 }.joined(
                                separator: " • ")
                            if !techSpec.isEmpty {
                                metadataRow(label: "Format", value: techSpec)
                            }

                            if let dur = clip.duration {
                                metadataRow(
                                    label: "Duration", value: DVUDateFormatting.duration(dur))
                            }

                            if let size = clip.fileSize {
                                metadataRow(
                                    label: "File Size", value: DVUDateFormatting.fileSize(size))
                            }

                            if let device = clip.deviceModel {
                                metadataRow(label: "Device", value: device)
                            }
                            if clip.gpsLat != nil, clip.gpsLon != nil {
                                metadataRow(
                                    label: "GPS",
                                    value: String(format: "%.4f, %.4f", clip.gpsLat!, clip.gpsLon!))
                            }

                        }
                    }

                    // Transcript panel (only if transcript exists)
                    if let clip = asset.clips?.first,
                        let transcript = clip.transcript, !transcript.isEmpty
                    {
                        Divider()
                            .background(Theme.separator)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "text.quote")
                                    .font(Theme.icon13)
                                    .foregroundStyle(Theme.blue)
                                Text("Transcript")
                                    .font(Theme.font13Semibold)
                                    .foregroundStyle(Theme.primaryText)

                                Spacer()

                                // Copy button
                                Button {
                                    UIPasteboard.general.string = transcript
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(Theme.icon13)
                                        .foregroundStyle(Theme.secondaryText)
                                        .tapTarget()
                                }
                                .accessibilityLabel("Copy transcript")
                            }

                            // Scrollable transcript text
                            ScrollView {
                                Text(transcript)
                                    .font(Theme.font13Regular)
                                    .foregroundStyle(Theme.metaText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                            .padding(10)
                            .background(Theme.glassOverlay)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                        }
                    }
                    // Action buttons — equal width
                    VStack(spacing: 8) {
                        switch rowStatus {
                        case .failed:
                            archiveButton(
                                icon: "arrow.clockwise.circle.fill",
                                label: "Re-upload (pick video)",
                                color: Theme.errorText
                            ) {
                                beginReupload()
                            }
                            .accessibilityFocused($reuploadActionIsFocused)
                            .task(id: restoreModalFocus) {
                                focusReuploadActionIfRequested()
                            }
                        case .reuploading:
                            HStack(spacing: 12) {
                                if let thumbnailUrl = asset.clips?.first?.thumbnailUrl,
                                    let url = URL(string: thumbnailUrl)
                                {
                                    AsyncImage(url: url) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 6).fill(Theme.cardBg)
                                    }
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Theme.cardBg)
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Image(systemName: "film").foregroundStyle(
                                                Theme.tertiaryText
                                            ).font(Theme.icon13))
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(!isReuploadingVideo
                                        ? "Re-upload in progress…"
                                        : (isVerifyingReupload
                                            ? "Verifying video…"
                                            : "Uploading \(Int(reuploadProgress * 100))%"))
                                        .font(Theme.font13Semibold)
                                        .foregroundStyle(Theme.blue)
                                    if isReuploadingVideo {
                                        ProgressView(value: reuploadProgress)
                                            .tint(Theme.blue)
                                    } else {
                                        ProgressView().tint(Theme.blue)
                                    }
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                isVerifyingReupload ? "Verifying video" : "Re-uploading video")
                            .accessibilityValue(
                                isVerifyingReupload || !isReuploadingVideo
                                    ? "" : "\(Int(reuploadProgress * 100)) percent")
                            .accessibilityFocused($reuploadProgressIsFocused)
                            .task(id: restoreModalFocus) {
                                guard restoreModalFocus == .reuploadProgress else { return }
                                reuploadProgressIsFocused = true
                                onModalFocusRestored()
                            }
                        case .processing:
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text(
                                    hasActiveChatUpload
                                        ? "Uploading in Chat\u{2026}"
                                        : (asset.status == .uploading && !hasCompletedReupload
                                            ? "Uploading\u{2026}" : "Processing on server\u{2026}"))
                                    .font(Theme.font13Semibold)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.buttonPaddingV)
                        case .needsDetails, .ready:
                            EmptyView()
                        }
                        HStack(spacing: 8) {
                            if rowStatus == .needsDetails || rowStatus == .ready {
                                if let msId = asset.mediasourceId,
                                    let url = ServerConfig.clipURL(msId)
                                {
                                    archiveButton(
                                        icon: "play.circle.fill", label: "View", color: Theme.green
                                    ) {
                                        UIApplication.shared.open(url)
                                    }
                                }

                                archiveButton(
                                    icon: "paperplane.fill", label: "Slack", color: Theme.purple
                                ) {
                                    onShowSlack(rowID)
                                }
                                .accessibilityFocused($slackActionIsFocused)
                                .task(id: restoreModalFocus) {
                                    guard restoreModalFocus == .slack else { return }
                                    slackActionIsFocused = true
                                    onModalFocusRestored()
                                }
                            }

                            if needsDetails {
                                addDetailsButton.id("add-details-\(asset.id)")
                            } else if rowStatus == .ready {
                                archiveButton(
                                    icon: "checkmark.circle.fill", label: "Details",
                                    color: Theme.green.opacity(0.5)
                                ) {}
                                .allowsHitTesting(false)
                            }
                        }
                    }

                    if let reuploadNotice = ArchiveReuploadNotice.preferred(
                        reuploadNotice: reuploadNotice, refreshWarning: reuploadRefreshWarning,
                        photoWarning: photoAssociationWarning, readWarning: photoAssociationReadWarning,
                        displayedError: reuploadError ?? mediaTasks.retryMessages[asset.id],
                        isDamaged: photoAssociationDamaged) {
                        Label(reuploadNotice, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let associationWarning = mediaTasks.associationWarning(
                        assetId: asset.id, scope: assetSession?.scope) {
                        Label(associationWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Re-upload error
                    if let reuploadError = ArchiveReuploadNotice.distinctError(
                        reuploadError ?? mediaTasks.retryMessages[asset.id],
                        isDamaged: photoAssociationDamaged) {
                        Text(reuploadError)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.errorText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if photoAssociationDamaged {
                        Button("Repair saved photo links") {
                            if !onRepairPhotoLinks(rowID) {
                                onReuploadAnnouncement("Close the current sheet before repairing photo links.")
                            }
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(Theme.warningText)
                        .accessibilityFocused($repairActionIsFocused)
                        .task(id: restoreModalFocus) {
                            guard restoreModalFocus == .repairPhotos else { return }
                            repairActionIsFocused = true
                            onModalFocusRestored()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
        .onChange(of: restoreFocus) { _, shouldFocus in
            if shouldFocus { restoreDetailsFocus() }
        }
        .onChange(of: restoreModalFocus) { _, target in
            if let target { restoreModalFocusIfNeeded(target) }
        }
        .onChange(of: pendingReuploadSelection?.id) { _, _ in
            consumePendingReuploadSelection()
        }
        .onChange(of: refreshVersion) { _, version in
            reuploadRefreshWarning = nil
            mediaTasks.clearCompletion(assetId: asset.id)
            if let completedAt = reuploadCompletionRefreshVersion, version != completedAt {
                reuploadComplete = false
                reuploadCompletionRefreshVersion = nil
            }
        }
        .onChange(of: assetSession?.scope) { _, _ in refreshPhotoAssociation() }
        .onChange(of: assetSession?.generation) { _, _ in refreshPhotoAssociation() }
        .onChange(of: assetSession?.serverURL) { _, _ in refreshPhotoAssociation() }
        .onChange(of: mediaTasks.associationRevision) { _, _ in
            let wasDamaged = photoAssociationDamaged
            refreshPhotoAssociation()
            if wasDamaged && !photoAssociationDamaged {
                if reuploadErrorRequiresRepair {
                    reuploadError = nil
                    reuploadErrorRequiresRepair = false
                }
                mediaTasks.clearAssociationRepairFailure(assetId: asset.id)
            }
        }
        .onChange(of: presentationState.isSceneActive) { _, isActive in
            if isActive { refreshPhotoAssociation() }
        }
        .onAppear {
            onVisibilityChange(rowID, true)
            refreshPhotoAssociation()
            if restoreFocus { restoreDetailsFocus() }
            if let restoreModalFocus { restoreModalFocusIfNeeded(restoreModalFocus) }
            consumePendingReuploadSelection()
        }
        .onDisappear {
            onVisibilityChange(rowID, false)
        }
    }

    // MARK: - Helpers

    private var addDetailsButton: some View {
        archiveButton(icon: "square.and.pencil", label: "Add Details", color: Theme.yellow) {
            onAddDetails()
        }
        .accessibilityFocused($addDetailsIsFocused)
        .task(id: restoreFocus) {
            if restoreFocus {
                addDetailsIsFocused = true
                onFocusRestored()
            }
        }
    }

    private func restoreDetailsFocus() {
        if needsDetails {
            isExpanded = true
        } else {
            rowIsFocused = true
            onFocusRestored()
        }
    }

    private func restoreModalFocusIfNeeded(_ target: ArchiveModalFocusTarget) {
        if (target == .reupload && rowStatus == .failed)
            || (target == .reuploadProgress && rowStatus == .reuploading)
            || (target == .reuploadProgress && rowStatus == .failed)
            || (target == .repairPhotos && (photoAssociationDamaged || rowStatus == .failed))
            || (target == .slack && (rowStatus == .ready || rowStatus == .needsDetails)) {
            isExpanded = true
        } else {
            rowIsFocused = true
            onModalFocusRestored()
        }
    }

    private func focusReuploadActionIfRequested() {
        guard restoreModalFocus == .reupload
                || (restoreModalFocus == .repairPhotos && !photoAssociationDamaged)
                || (restoreModalFocus == .reuploadProgress && rowStatus == .failed) else { return }
        reuploadActionIsFocused = true
        onModalFocusRestored()
    }

    @ViewBuilder
    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(Theme.font11Regular)
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(Theme.font11Regular)
                .foregroundStyle(Theme.metaText)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func archiveButton(
        icon: String, label: String, color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .accessibilityHidden(true)
                Text(label)
            }
            .font(Theme.font13Semibold)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.buttonPaddingV)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: Theme.buttonCornerRadius))
            .tapTarget()
        }
        .buttonStyle(.plain)
    }

    private func formatShortDate(_ dateStr: String?) -> String {
        guard let dateStr else { return "" }
        return DVUDateFormatting.shortDate(dateStr)
    }

    // MARK: - Re-upload

    private func refreshPhotoAssociation() {
        photoAssociationDamaged = false
        guard let session = assetSession, session.isCurrent(auth) else { return }
        do {
            _ = try ScopedPHAssetIdentifierStore.shared.association(
                assetId: asset.id, for: session.scope)
            photoAssociationReadWarning = nil
        } catch {
            Log.error("⚠️ [Archive] Could not read the saved photo association: \(Log.describe(error))", logger: Log.media)
            photoAssociationDamaged = isDamagedPhotoAssociationStore(error)
            photoAssociationReadWarning = photoAssociationDamaged
                ? ArchiveReuploadNotice.repairRequired
                : "Couldn't read the saved photo link. Unlock this device and try again."
        }
    }

    private func beginReupload() {
        guard !isReuploadingVideo, !hasActiveArchiveUpload, !hasActiveChatUpload else {
            onReuploadAnnouncement("This upload is already in progress.")
            return
        }
        guard let session = assetSession, session.isCurrent(auth) else {
            reuploadSession = nil
            failReupload("Your account or server changed. Refresh Archive before re-uploading.")
            return
        }
        reuploadSession = session
        refreshPhotoAssociation()
        if photoAssociationDamaged {
            failReupload(ArchiveReuploadNotice.repairRequired, requiresAssociationRepair: true)
            return
        }
        if let photoAssociationReadWarning {
            failReupload(photoAssociationReadWarning)
            return
        }
        presentReuploadPicker(
            "Choose the correct original video or saved trim to re-upload.", session: session)
    }

    private func presentReuploadPicker(_ message: String, session: ArchiveSessionIdentity) {
        do {
            let snapshot = try ScopedPHAssetIdentifierStore.shared.snapshot(
                assetId: asset.id, for: session.scope)
            let presented = onPickVideo(rowID, message, snapshot)
            if !presented { deferReuploadPicker(message) }
        } catch {
            Log.error("⚠️ [Archive] Could not snapshot the saved photo association: \(Log.describe(error))", logger: Log.media)
            photoAssociationDamaged = isDamagedPhotoAssociationStore(error)
            let warning = photoAssociationDamaged
                ? ArchiveReuploadNotice.repairRequired
                : "Couldn't read the saved photo link. Unlock this device and try again."
            photoAssociationReadWarning = warning
            failReupload(warning, requiresAssociationRepair: photoAssociationDamaged)
        }
    }

    private func consumePendingReuploadSelection() {
        guard let pending = pendingReuploadSelection, pending.assetId == asset.id else { return }
        guard onPendingReuploadConsumed(pending.id) else { return }
        guard pending.session.isCurrent(auth), pending.intent.permits(asset),
              pending.associationSnapshot.matches(assetId: asset.id, scope: pending.session.scope),
              mediaTasks.intentIsCurrent(
                pending.intent, assetId: asset.id, scope: pending.session.scope,
                sessionGeneration: pending.session.generation),
              !isReuploadingVideo,
              !mediaTasks.isRunning(assetId: asset.id, scope: pending.session.scope),
              !presentationState.isChatUploading(assetId: asset.id, scope: pending.session.scope) else {
            onReuploadAnnouncement(
                "The selected video wasn't used because this upload changed or a retry is already running.")
            return
        }
        reuploadSession = pending.session
        let started = mediaTasks.start(
            assetId: asset.id, scope: pending.session.scope,
            sessionGeneration: pending.session.generation, intent: pending.intent,
            onSuperseded: { _ in
                guard pending.session.isCurrent(auth),
                      !mediaTasks.isRunning(assetId: asset.id, scope: pending.session.scope)
                else { return }
                if presentationState.isChatUploading(assetId: asset.id, scope: pending.session.scope) {
                    isReuploadingVideo = false
                    verificationProgress.reset()
                    return
                }
                abandonChangedRetry()
            }
        ) { operationID in
            await handleReupload(
                item: pending.item, session: pending.session, operationID: operationID,
                associationSnapshot: pending.associationSnapshot)
        }
        guard started else {
            onReuploadAnnouncement(
                "The selected video wasn't used because this upload changed or a retry is already running.")
            return
        }
        startReuploadProgress(focusProgress: true)
    }

    private func deferReuploadPicker(_ message: String) {
        let instruction = "\(message) When ready, choose Re-upload (pick video) in Archive."
        reuploadNotice = instruction
        onReuploadAnnouncement(instruction)
    }

    /// Upload the current representation explicitly selected in the picker.
    private func handleReupload(
        item: PhotosPickerItem, session: ArchiveSessionIdentity, operationID: UUID,
        associationSnapshot: ScopedPhotoAssociationSnapshot
    ) async {
        guard ownsOperation(session, operationID) else { return }

        do {
            let load: Result<VideoTransferable?, any Error>
            do {
                load = .success(try await item.loadTransferable(type: VideoTransferable.self))
            } catch {
                load = .failure(error)
            }
            let loaded = try ArchiveRetryVideoLoad.resolve(load) {
                guard ownsOperation(session, operationID) else { throw UploadError.sessionChanged }
                try requireCurrentIntent(session, operationID)
            }
            guard let movie = loaded else {
                failReupload("Could not load video from Photos library")
                return
            }
            defer { removeTemporaryVideoItem(movie.url.deletingLastPathComponent()) }
            let metadata = await VideoMetadataExtractor.extract(from: movie.url)
            guard ownsOperation(session, operationID) else { throw UploadError.sessionChanged }
            try requireCurrentIntent(session, operationID)
            guard OriginalVideoLoader.hasCompatibleDuration(
                photosDuration: Double(metadata.duration),
                clipDuration: asset.clips?.first?.duration) else {
                throw PhotoAssociationError.durationMismatch
            }

            let verification: Result<ScopedPhotoAssociation?, any Error>
            do {
                verification = .success(try await verifiedAssociationForSelectedVideo(
                    item: item, fileURL: movie.url, metadata: metadata,
                    session: session, operationID: operationID))
            } catch {
                verification = .failure(error)
            }
            let association = try ArchiveRetryVerification.resolve(
                verification,
                validate: {
                    guard ownsOperation(session, operationID) else { throw UploadError.sessionChanged }
                    try requireCurrentIntent(session, operationID)
                },
                onMissing: {
                    warnManualPhotoRetry(
                        "The selected Photos version will upload as selected. Choose it again if you need to retry.")
                },
                onFailure: { error in
                    Log.error("⚠️ [Archive] Could not verify the selected Photos version: \(Log.describe(error))", logger: Log.media)
                    warnManualPhotoRetry(
                        "The selected video can upload, but its Photos link couldn't be verified. Choose it again if you need to retry.")
                }
            )
            try await performUpload(
                fileURL: movie.url, metadata: metadata, session: session,
                operationID: operationID, newAssociation: association,
                associationSnapshot: associationSnapshot)
        } catch PhotoAssociationError.durationMismatch {
            guard ownsUnchangedOperation(session, operationID) else { return }
            failReupload("That video's duration doesn't match this upload. Choose the saved video or trim.")
        } catch ArchiveRetryError.intentChanged {
            guard ownsOperation(session, operationID) else { return }
            abandonChangedRetry()
        } catch {
            guard ownsUnchangedOperation(session, operationID) else { return }
            failReupload("Re-upload failed. Check your connection and try again.")
            Log.error("❌ [Archive] Re-upload failed: \(Log.describe(error))", logger: Log.media)
        }
    }

    private func verifiedAssociationForSelectedVideo(
        item: PhotosPickerItem, fileURL: URL, metadata: VideoMetadata,
        session: ArchiveSessionIdentity, operationID: UUID
    ) async throws -> ScopedPhotoAssociation? {
        guard ownsOperation(session, operationID) else { throw UploadError.sessionChanged }
        try requireCurrentIntent(session, operationID)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard OriginalVideoLoader.canRead(status), let identifier = item.itemIdentifier,
              OriginalVideoLoader.duration(ofAssetWithIdentifier: identifier) != nil else {
            return nil
        }
        verificationProgress.begin(operationID)
        defer { verificationProgress.finish(operationID) }
        let selected = try await VideoContentFingerprint.calculate(for: fileURL)
        guard ownsOperation(session, operationID) else { throw UploadError.sessionChanged }
        try requireCurrentIntent(session, operationID)
        let original = try await OriginalVideoLoader.loadOriginal(localIdentifier: identifier)
        defer { removeTemporaryVideoItem(original.fileURL.deletingLastPathComponent()) }
        guard ownsOperation(session, operationID) else { throw UploadError.sessionChanged }
        try requireCurrentIntent(session, operationID)
        let originalFingerprint = try await VideoContentFingerprint.calculate(for: original.fileURL)
        guard ownsOperation(session, operationID) else { throw UploadError.sessionChanged }
        try requireCurrentIntent(session, operationID)
        return ManualPhotoRecovery.association(
            identifier: identifier, selected: selected, original: originalFingerprint,
            metadata: metadata)
    }

    private func warnManualPhotoRetry(_ message: String) {
        photoAssociationWarning = message
        onReuploadAnnouncement(message)
    }

    private func publishPhotoLinkOutcome(
        _ outcome: ArchiveRetryPhotoLink.Outcome, session: ArchiveSessionIdentity, operationID: UUID
    ) {
        guard ownsOperation(session, operationID) else { return }
        switch outcome {
        case .committed(let association):
            mediaTasks.setAssociationWarning(
                outcome.warningMessage, assetId: asset.id, scope: session.scope)
            photoAssociationWarning = nil
            if association == nil {
                presentationState.photoAssociatedAssetIDs.remove(asset.id)
            } else {
                presentationState.photoAssociatedAssetIDs.insert(asset.id)
            }
            mediaTasks.associationChanged()
        case .superseded, .associationChanged, .storageFailure:
            if case .storageFailure(let error) = outcome {
                Log.error("⚠️ [Archive] Could not update the photo association after upload: \(Log.describe(error))", logger: Log.media)
                if isDamagedPhotoAssociationStore(error) {
                    photoAssociationDamaged = true
                    photoAssociationReadWarning = ArchiveReuploadNotice.repairRequired
                }
            }
            if let warning = outcome.warningMessage {
                mediaTasks.setAssociationWarning(warning, assetId: asset.id, scope: session.scope)
            }
        }
    }

    /// Upload the selected video and retain a verified local photo link when available.
    private func performUpload(
        fileURL: URL, metadata: VideoMetadata, session: ArchiveSessionIdentity,
        operationID: UUID, newAssociation: ScopedPhotoAssociation?,
        associationSnapshot: ScopedPhotoAssociationSnapshot
    ) async throws {
        guard ownsOperation(session, operationID) else { throw UploadError.sessionChanged }
        try requireCurrentIntent(session, operationID)
        if !OriginalVideoLoader.hasCompatibleDuration(
            photosDuration: Double(metadata.duration),
            clipDuration: asset.clips?.first?.duration) {
            throw PhotoAssociationError.durationMismatch
        }
        try requireCurrentIntent(session, operationID)
        guard mediaTasks.markNetworkStarted(
            assetId: asset.id, scope: session.scope, id: operationID
        ) else { throw UploadError.sessionChanged }
        let uploader = VideoUploadService()

        let progressTask = Task {
            while !Task.isCancelled, ownsOperation(session, operationID) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, ownsOperation(session, operationID) else { return }
                reuploadProgress = uploader.uploadProgress
            }
        }
        defer { progressTask.cancel() }

        let outcome = try await ArchiveRetryPhotoLink.uploadAndCommit(
            store: .shared, snapshot: associationSnapshot, assetId: asset.id,
            scope: session.scope, association: newAssociation,
            isCurrent: {
                ownsOperation(session, operationID)
                    && mediaTasks.intentIsCurrent(
                        assetId: asset.id, scope: session.scope, id: operationID)
            },
            onOutcome: { outcome in
                publishPhotoLinkOutcome(outcome, session: session, operationID: operationID)
            },
            upload: {
                _ = try await uploader.uploadViaMux(
                    assetId: asset.id,
                    fileURL: fileURL,
                    token: session.token,
                    serverURL: session.serverURL,
                    metadata: metadata,
                    isCurrent: { ownsOperation(session, operationID) },
                    validateBeforeTransfer: { try requireCurrentIntent(session, operationID) }
                )
            }
        )

        guard ownsOperation(session, operationID) else { throw UploadError.sessionChanged }
        let restoreFocus = reuploadProgressIsFocused && isArchiveActive && !isArchiveModalVisible
        reuploadProgress = 1.0
        reuploadCompletionRefreshVersion = refreshVersion
        reuploadComplete = true
        isReuploadingVideo = false
        mediaTasks.recordCompletion(assetId: asset.id, scope: session.scope)
        onReuploadCompletion(outcome.completionAnnouncement, restoreFocus)
        Log.debug("✅ [Archive] Re-upload complete for asset: \(asset.id)", logger: Log.media)

        let refreshed = await onUploadCompleted()
        if case .failed = refreshed, ownsOperation(session, operationID) {
            let message = "Upload finished, but its status couldn't be refreshed. Refresh Archive."
            reuploadRefreshWarning = message
        }
    }

    private func startReuploadProgress(focusProgress: Bool = false) {
        let moveFocus = focusProgress
            || (reuploadActionIsFocused && isArchiveActive && !isArchiveModalVisible)
        isReuploadingVideo = true
        verificationProgress.reset()
        mediaTasks.beginRetry(assetId: asset.id)
        reuploadProgress = 0
        reuploadError = nil
        reuploadErrorRequiresRepair = false
        reuploadNotice = nil
        reuploadRefreshWarning = nil
        reuploadComplete = false
        reuploadCompletionRefreshVersion = nil
        onReuploadAnnouncement("Re-upload started.")
        if moveFocus { onReuploadProgressFocus() }
    }

    private func ownsOperation(_ session: ArchiveSessionIdentity, _ id: UUID) -> Bool {
        !Task.isCancelled && session.isCurrent(auth)
            && !presentationState.isChatUploading(assetId: asset.id, scope: session.scope)
            && mediaTasks.owns(assetId: asset.id, scope: session.scope, id: id)
    }

    private func requireCurrentIntent(_ session: ArchiveSessionIdentity, _ id: UUID) throws {
        guard mediaTasks.intentIsCurrent(assetId: asset.id, scope: session.scope, id: id) else {
            throw ArchiveRetryError.intentChanged
        }
    }

    private func ownsUnchangedOperation(_ session: ArchiveSessionIdentity, _ id: UUID) -> Bool {
        guard ownsOperation(session, id) else { return false }
        guard mediaTasks.intentIsCurrent(assetId: asset.id, scope: session.scope, id: id) else {
            abandonChangedRetry()
            return false
        }
        return true
    }

    private func abandonChangedRetry() {
        let restoreFocus = reuploadProgressIsFocused && isArchiveActive && !isArchiveModalVisible
        let message = "This upload changed. Refresh Archive before retrying."
        isReuploadingVideo = false
        verificationProgress.reset()
        reuploadError = nil
        reuploadErrorRequiresRepair = false
        reuploadNotice = message
        mediaTasks.clearFailure(assetId: asset.id)
        onReuploadAnnouncement(message)
        if restoreFocus { rowIsFocused = true }
    }

    private func failReupload(_ message: String, requiresAssociationRepair: Bool = false) {
        let restoreFocus = reuploadProgressIsFocused && isArchiveActive && !isArchiveModalVisible
        isReuploadingVideo = false
        guard reuploadSession?.isCurrent(auth) ?? true else { return }
        reuploadError = message
        reuploadErrorRequiresRepair = requiresAssociationRepair
        if reuploadSession?.isCurrent(auth) == true {
            if requiresAssociationRepair {
                mediaTasks.requireAssociationRepair(assetId: asset.id, message: message)
            } else {
                mediaTasks.recordFailure(assetId: asset.id, message: message)
            }
        }
        onReuploadAnnouncement(message)
        if restoreFocus { reuploadActionIsFocused = true }
    }
}

struct ArchiveFormPresentation: Identifiable {
    let id = UUID()
    let asset: Asset
    let session: ArchiveSessionIdentity
}

struct ArchiveDetailsSheet: View {
    let presentation: ArchiveFormPresentation
    let onSubmitted: ([String: String]) -> Void

    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var isActive = true
    @State private var isSubmitting = false
    @State private var isSubmitted = false
    @State private var submitError: String?
    @State private var errorRevision = 0

    private var asset: Asset { presentation.asset }

    var body: some View {
        ContextFormView(
            fields: FormField.defaultVideoFields(),
            originalFileName: asset.originalFileName,
            capturedAt: asset.clips?.first?.capturedAt,
            clipCount: asset.clipCount,
            duration: asset.clips?.first?.duration,
            thumbnail: nil,
            submitError: submitError,
            errorRevision: errorRevision,
            isSubmitting: isSubmitting,
            submissionComplete: isSubmitted,
            onSubmit: { formData in
                submitError = nil
                await submit(formData)
            }
        )
        .onDisappear { isActive = false }
    }

    private func submit(_ formData: [String: String]) async {
        guard !isSubmitting else { return }
        guard presentation.session.isCurrent(auth),
              let url = presentation.session.url(for: "/api/assets/\(asset.id)/form")
        else {
            submitError = "Your session changed. Sign in again to submit these details."
            errorRevision += 1
            return
        }
        let scope = presentation.session.scope
        isSubmitting = true
        defer { isSubmitting = false }
        let isCurrent: @MainActor () -> Bool = {
            presentation.session.isCurrent(auth)
        }

        let pendingRecord: PendingFormRecord?
        let recoveryReadFailed: Bool
        do {
            pendingRecord = try PendingFormStore.shared.record(assetId: asset.id, for: scope)
            recoveryReadFailed = false
        } catch {
            pendingRecord = nil
            recoveryReadFailed = true
            Log.error("⚠️ [Archive] Could not read saved recovery state: \(Log.describe(error))", logger: Log.media)
        }
        let request = auth.authenticatedRequest(for: url, method: "POST")

        do {
            let outcome = try await PendingFormSubmission(store: .shared).submit(
                formData: formData, request: request, pendingRecord: pendingRecord,
                scope: scope, assetId: asset.id, isCurrent: isCurrent)
            if case .submittedRecoveryNotCleared(let error) = outcome {
                Log.error("⚠️ [Archive] Failed to clear saved recovery state: \(Log.describe(error))", logger: Log.media)
            }
            guard isCurrent(), isActive else { return }
            if case .sessionChanged = outcome { return }

            isSubmitted = true
            onSubmitted(formData)
            Log.debug("✅ [Archive] Form submitted for asset: \(asset.id)", logger: Log.media)
            if recoveryReadFailed {
                submitError = "Details were sent, but saved recovery state couldn't be read. You can close this form."
                errorRevision += 1
            } else if case .submittedRecoveryNotCleared = outcome {
                submitError = "Details were sent, but saved recovery state couldn't be updated. You can close this form."
                errorRevision += 1
            } else {
                dismiss()
            }
        } catch {
            if case FormSubmissionError.httpStatus(let status) = error {
                Log.error("❌ [Archive] Form submit failed: HTTP \(status)", logger: Log.media)
            } else {
                Log.error("❌ [Archive] Form submit failed: \(Log.describe(error))", logger: Log.media)
            }
            guard isCurrent(), isActive else { return }
            if case FormSubmissionError.inProgress = error {
                submitError = "These details are already being sent. Wait and try again."
            } else {
                submitError = "Couldn't confirm the details were sent. Retry or check Archive."
            }
            errorRevision += 1
        }
    }
}
