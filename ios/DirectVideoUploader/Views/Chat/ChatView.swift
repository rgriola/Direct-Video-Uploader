// May 10, 2026 - 3:34pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

private struct QueuedChatAnnouncement {
    let text: String
    let code: String?
    let assetId: String?
    let params: [String: String]?
}

/// Main chat view — mirrors the `chat-demo.html` layout.
struct ChatView: View {
    let formPresentation: FormPresentationState
    let onModelCreated: (ChatViewModel) -> Void
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel: ChatViewModel?
    @State private var showVideoLibrary = false
    @State private var videoLibraryPresentationActive = false
    @State private var videoSelectionConfirmed = false
    @State private var pendingAttachmentFocus = false
    @State private var showOnboarding = false
    @State private var onboardingPresentationActive = false
    @State private var guideRequestedAfterOnboarding = false
    @State private var showInstructions = false
    @State private var instructionsPresentationActive = false
    @State private var permissionsPresentationActive = false
    @State private var metadataPresentationActive = false
    @State private var slackPresentationActive = false
    @State private var isFormVisible = false
    @State private var pendingRecoveryAnnouncements: [QueuedChatAnnouncement] = []
    @State private var pendingStagedAnnouncement: String?
    @State private var viewSessionGeneration: UUID?
    @AppStorage(OnboardingCatalog.completionKey) private var hasCompletedOnboarding = false
    @AppStorage(PermissionsPrompt.seenKey) private var hasSeenPermissions = false
    @Environment(PermissionManager.self) private var permissions
    @State private var showPermissions = false

    var body: some View {
        ZStack {
            Theme.chatScreen.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                ChatHeaderView(
                    userName: "Fixer",
                    connectionState: ws.state,
                    onTapInstructions: {
                        viewModel?.setFormPresentationBlocked(true)
                        instructionsPresentationActive = true
                        showInstructions = true
                    }
                )

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if let vm = viewModel {
                                ForEach(vm.messages) { message in
                                    messageRow(message: message, vm: vm)
                                }

                                // Staged video preview — user must confirm before upload
                                if let staged = vm.stagedVideo {
                                    VideoBubble(
                                        phase: .staged,
                                        thumbnail: staged.thumbnail,
                                        fileName: staged.fileName,
                                        createdDate: staged.createdDate,
                                        hasLocation: staged.metadata.gpsLat != nil,
                                        onSend: { transcribe in
                                            Task {
                                                await vm.confirmStagedUpload(id: staged.id, transcribe: transcribe)
                                            }
                                        },
                                        onCancel: {
                                            vm.cancelStagedVideo(id: staged.id)
                                            resumePendingFormRecovery()
                                        },
                                        onContinueWithoutPhotoIdentifier: { transcribe in
                                            Task {
                                                await vm.confirmStagedUpload(
                                                    id: staged.id, transcribe: transcribe,
                                                    acceptManualPhotoSelection: true)
                                            }
                                        },
                                        onOpenSettings: { permissions.openAppSettings() },
                                        preparation: vm.stagedUploadPreparation,
                                        willSaveTrim: staged.isTrimmed && !staged.isSavedToPhotos,
                                        savedTrim: staged.isTrimmed && staged.isSavedToPhotos
                                    )
                                    .id(staged.id.uuidString)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: viewModel?.messages.count) { _, _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: viewModel?.messages.map(\.id)) { oldIDs, _ in
                        guard viewSessionGeneration == auth.sessionGeneration else {
                            pendingRecoveryAnnouncements.removeAll()
                            return
                        }
                        let previous = Set(oldIDs ?? [])
                        let codes: Set<String> = [
                            "IOS_LEGACY_PENDING_FORM", "IOS_PENDING_FORM_RECOVERY_FAILED",
                            "IOS_PENDING_FORM_IN_ARCHIVE", "IOS_PENDING_FORM_SAVE_FAILED",
                            "IOS_LEGACY_FORM_PROTECTION_FAILED", "IOS_PENDING_FORM_SKIP_SAVE_FAILED",
                            "IOS_LEGACY_FORM_CHECK_FAILED",
                            "IOS_UPLOAD_START_FAILED", "IOS_UPLOAD_FAILED",
                            "IOS_PREVIOUS_UPLOAD_START_FAILED", "IOS_PREVIOUS_UPLOAD_FAILED",
                            "IOS_PREVIOUS_TRIM_SAVE_FAILED", "IOS_PREVIOUS_TRANSCRIBE_RESULT",
                            "IOS_PHOTO_ASSOCIATION_SAVE_FAILED",
                            "IOS_PREVIOUS_PHOTO_ASSOCIATION_SAVE_FAILED",
                        ]
                        let notices = (viewModel?.messages ?? []).filter {
                            !previous.contains($0.id) && codes.contains($0.content.code ?? "")
                        }
                        pendingRecoveryAnnouncements.append(contentsOf: notices.map {
                            QueuedChatAnnouncement(
                                text: $0.displayText, code: $0.content.code, assetId: $0.assetId,
                                params: $0.content.params)
                        })
                        announceRecoveryNoticesIfPossible()
                    }
                    .onChange(of: viewModel?.stagedVideo?.id) { _, _ in
                        if viewModel?.stagedVideo == nil { pendingStagedAnnouncement = nil }
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: viewModel?.stagedUploadPreparation) { _, state in
                        pendingStagedAnnouncement = viewModel?.stagedVideo == nil
                            ? nil : state?.message
                        announceRecoveryNoticesIfPossible()
                    }
                    .onChange(of: viewModel?.isUploading) { _, _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }

                // Input bar — always visible so user can text or #Slack after archive
                InputBar(
                    onSend: { text in
                        viewModel?.sendTextMessage(text)
                    },
                    onAttach: {
                        guard let viewModel else { return }
                        videoSelectionConfirmed = false
                        pendingAttachmentFocus = false
                        viewModel.beginVideoSelection()
                        videoLibraryPresentationActive = true
                        showVideoLibrary = true
                    },
                    attachmentDisabled: viewModel?.stagedUploadPreparation.blocksAttachment ?? false,
                    restoreAttachmentFocus: canRestoreAttachmentFocus,
                    onAttachmentFocusRestored: { pendingAttachmentFocus = false }
                )
            }
        }
        .sheet(isPresented: $showVideoLibrary, onDismiss: {
            videoLibraryPresentationActive = false
            guard viewSessionGeneration == auth.sessionGeneration else { return }
            viewModel?.endVideoSelection()
            if !videoSelectionConfirmed {
                pendingAttachmentFocus = true
                resumePendingFormRecovery()
            }
            announceRecoveryNoticesIfPossible()
        }) {
            VideoLibraryView(
                presentationState: formPresentation,
                onConfirm: { picked in
                    guard viewSessionGeneration == auth.sessionGeneration,
                          let viewModel else {
                        Log.error("⚠️ [Library] Discarded a selection after the session changed", logger: Log.media)
                        showVideoLibrary = false
                        return false
                    }
                    videoSelectionConfirmed = true
                    viewModel.stageVideo(
                        fileURL: picked.fileURL, fileName: picked.fileName,
                        metadata: picked.metadata,
                        phAssetIdentifier: picked.phAssetIdentifier,
                        isTrimmed: picked.isTrimmed)
                    showVideoLibrary = false
                    return true
                },
                onDismiss: {
                    showVideoLibrary = false
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel?.showFormSheet ?? false },
                set: { viewModel?.showFormSheet = $0 }
            ),
            onDismiss: {
                guard viewSessionGeneration == auth.sessionGeneration else { return }
                isFormVisible = false
                if let announcement = viewModel?.formDismissed() {
                    pendingRecoveryAnnouncements.insert(
                        QueuedChatAnnouncement(
                            text: announcement, code: nil, assetId: nil, params: nil),
                        at: 0)
                }
                announceRecoveryNoticesIfPossible()
            }
        ) {
            if let vm = viewModel, let assetId = vm.formAssetId {
                ContextFormView(
                    fields: vm.formFields,
                    originalFileName: vm.form.originalFileName,
                    capturedAt: vm.form.capturedAt,
                    clipCount: vm.form.clipCount,
                    duration: vm.form.duration,
                    thumbnail: vm.form.thumbnail,
                    submitError: vm.form.submitError,
                    errorRevision: vm.formErrorRevision,
                    isSubmitting: vm.isSubmittingForm,
                    onSubmit: { formData in
                        vm.form.submitError = nil  // Clear previous error
                        await vm.submitForm(assetId: assetId, formData: formData)
                    },
                    onCancel: {
                        vm.cancelForm()
                    }
                )
                .onAppear { isFormVisible = true }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel?.showMetadataSheet ?? false },
                set: { viewModel?.showMetadataSheet = $0 }
            ),
            onDismiss: {
                metadataPresentationActive = false
                resumePendingFormRecovery()
                announceRecoveryNoticesIfPossible()
            }
        ) {
            if let vm = viewModel, let clip = vm.lastClip {
                MetadataView(clip: clip, asset: vm.lastAsset, thumbnail: vm.form.thumbnail)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel?.showSlackShareSheet ?? false },
                set: { viewModel?.showSlackShareSheet = $0 }
            ),
            onDismiss: {
                slackPresentationActive = false
                resumePendingFormRecovery()
                announceRecoveryNoticesIfPossible()
            }
        ) {
            if let vm = viewModel {
                SlackShareSheet(
                    mediasourceId: vm.archive.mediasourceId,
                    originalFileName: vm.archive.originalFileName,
                    onSend: { text in vm.shareToSlack(text: text) },
                    onDismiss: { vm.showSlackShareSheet = false }
                )
            }
        }
        .task {
            // Only create ViewModel once — guard prevents re-creation on tab switch
            guard viewModel == nil else { return }
            viewSessionGeneration = auth.sessionGeneration
            let vm = ChatViewModel(auth: auth, ws: ws, formPresentation: formPresentation)
            viewModel = vm
            onModelCreated(vm)
            vm.setFormPresentationBlocked(true)
            vm.connectWebSocket()

            presentPermissionsIfNeeded()
        }
        .sheet(isPresented: $showOnboarding, onDismiss: {
            onboardingPresentationActive = false
            presentPermissionsIfNeeded()
            announceRecoveryNoticesIfPossible()
        }) {
            OnboardingWalkthroughView(
                onOpenGuide: {
                    guideRequestedAfterOnboarding = true
                }
            )
        }
        .sheet(isPresented: $showInstructions, onDismiss: {
            instructionsPresentationActive = false
            presentPermissionsIfNeeded()
            announceRecoveryNoticesIfPossible()
        }) {
            InstructionsView()
        }
        .sheet(isPresented: $showPermissions, onDismiss: {
            permissionsPresentationActive = false
            resumePendingFormRecovery()
            announceRecoveryNoticesIfPossible()
        }) {
            PermissionsView()
        }
        .onChange(of: ws.state) { _, state in
            if state == .connected { resumePendingFormRecovery(restartInFlight: true) }
        }
        .onChange(of: viewModel?.showMetadataSheet) { _, isPresented in
            if isPresented == true { metadataPresentationActive = true }
        }
        .onChange(of: viewModel?.showSlackShareSheet) { _, isPresented in
            if isPresented == true { slackPresentationActive = true }
        }
        .onChange(of: formPresentation.generation) { _, _ in
            viewModel?.cancelStalePendingFormRecovery()
            if formPresentation.canPresentChatForm {
                presentPermissionsIfNeeded()
                announceRecoveryNoticesIfPossible()
            }
        }
        .onDisappear {
            viewModel?.cancelPendingFormRecovery()
        }
        .onAppear {
            if viewModel != nil {
                presentPermissionsIfNeeded()
                announceRecoveryNoticesIfPossible()
            }
        }
    }

    /// Shows the Permissions screen once, after the walkthrough and guide are closed.
    private var canRestoreAttachmentFocus: Bool {
        pendingAttachmentFocus && viewSessionGeneration == auth.sessionGeneration
            && formPresentation.canPresentInChat(isSceneActive: scenePhase == .active)
            && !onboardingPresentationActive && !instructionsPresentationActive
            && !permissionsPresentationActive && !videoLibraryPresentationActive
            && !isFormVisible && !(viewModel?.showFormSheet ?? false)
            && !metadataPresentationActive && !(viewModel?.showMetadataSheet ?? false)
            && !slackPresentationActive && !(viewModel?.showSlackShareSheet ?? false)
    }

    private func presentPermissionsIfNeeded() {
        guard formPresentation.canPresentInChat(isSceneActive: scenePhase == .active),
              !onboardingPresentationActive, !instructionsPresentationActive,
              !permissionsPresentationActive, !videoLibraryPresentationActive,
              !isFormVisible, !(viewModel?.showFormSheet ?? false),
              !metadataPresentationActive, !(viewModel?.showMetadataSheet ?? false),
              !slackPresentationActive, !(viewModel?.showSlackShareSheet ?? false) else { return }
        if guideRequestedAfterOnboarding {
            guideRequestedAfterOnboarding = false
            viewModel?.setFormPresentationBlocked(true)
            instructionsPresentationActive = true
            showInstructions = true
            return
        }
        if !hasCompletedOnboarding {
            viewModel?.setFormPresentationBlocked(true)
            onboardingPresentationActive = true
            showOnboarding = true
            return
        }
        permissions.refreshStatuses()
        if PermissionsPrompt.shouldPresent(
            hasSeen: hasSeenPermissions,
            photoLibrary: permissions.photoLibraryStatus,
            speech: permissions.speechStatus
        ) {
            viewModel?.setFormPresentationBlocked(true)
            permissionsPresentationActive = true
            showPermissions = true
        } else {
            resumePendingFormRecovery()
        }
    }

    private func resumePendingFormRecovery(restartInFlight: Bool = false) {
        guard viewSessionGeneration == auth.sessionGeneration,
              formPresentation.canPresentInChat(isSceneActive: scenePhase == .active),
              !onboardingPresentationActive, !instructionsPresentationActive,
              !permissionsPresentationActive, !videoLibraryPresentationActive,
              !metadataPresentationActive, !(viewModel?.showMetadataSheet ?? false),
              !slackPresentationActive, !(viewModel?.showSlackShareSheet ?? false),
              let viewModel else { return }
        viewModel.setFormPresentationBlocked(false)
        Task { await viewModel.recoverPendingFormIfNeeded(restartInFlight: restartInFlight) }
    }

    private func announceRecoveryNoticesIfPossible() {
        guard viewSessionGeneration == auth.sessionGeneration else {
            pendingRecoveryAnnouncements.removeAll()
            pendingStagedAnnouncement = nil
            return
        }
        guard !isFormVisible, !(viewModel?.showFormSheet ?? false),
              formPresentation.canPresentInChat(isSceneActive: scenePhase == .active),
              !onboardingPresentationActive, !instructionsPresentationActive,
              !permissionsPresentationActive, !videoLibraryPresentationActive,
              !metadataPresentationActive, !(viewModel?.showMetadataSheet ?? false),
              !slackPresentationActive, !(viewModel?.showSlackShareSheet ?? false),
              !pendingRecoveryAnnouncements.isEmpty || pendingStagedAnnouncement != nil else { return }
        var notices = pendingRecoveryAnnouncements.filter {
            formPresentation.shouldAnnounceRecoveryNotice(
                code: $0.code, assetId: $0.assetId, params: $0.params)
        }.map(\.text)
        if let pendingStagedAnnouncement { notices.append(pendingStagedAnnouncement) }
        let announcement = notices.joined(separator: " ")
        pendingRecoveryAnnouncements = []
        pendingStagedAnnouncement = nil
        if !announcement.isEmpty {
            AccessibilityNotification.Announcement(announcement).post()
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        let targetId: String? =
            if let staged = viewModel?.stagedVideo {
                staged.id.uuidString
            } else {
                viewModel?.messages.last?.id
            }
        if let targetId {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(targetId, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func messageRow(message: ChatMessage, vm: ChatViewModel) -> some View {
        if message.messageType == .video && message.isOutgoing,
            let info = vm.sentUploads[message.id]
        {
            VideoBubble(
                phase: videoBubblePhase(for: vm, assetId: message.assetId),
                thumbnail: info.thumbnail,
                fileName: info.fileName,
                createdDate: info.createdDate,
                hasLocation: info.hasLocation,
                uploadProgress: vm.uploadProgress,
                didTranscribe: info.transcribeEnabled
            )
            .id(message.id)
        } else if message.messageType == .muxReady {
            let summaryMediasourceId = message.content.mediasourceId ?? vm.archive.mediasourceId
            let summaryMediasourceUrl = message.content.mediasourceUrl ?? vm.archive.mediasourceUrl
            let summaryFormSlug = message.content.slug ?? vm.archive.formSlug
            let summaryDuration = message.content.duration ?? vm.archive.duration
            let summaryResolution = message.content.resolution ?? vm.archive.resolution

            ConversationSummaryBubble(
                mediasourceId: summaryMediasourceId,
                mediasourceUrl: summaryMediasourceUrl,
                formSlug: summaryFormSlug,
                duration: summaryDuration,
                resolution: summaryResolution,
                fileSize: vm.archive.fileSize
            )
            .id(message.id)
        } else {
            MessageBubble(
                message: message,
                thumbnail: message.messageType == .slackPost
                    ? (vm.slackThumbnails[message.id] ?? vm.form.thumbnail) : nil,
                slackSent: message.messageType == .slackPost && message.isOutgoing
                    && vm.slackConfirmedIds.contains(message.id),
                onTapMetadata: message.messageType == .confirmation ? { vm.showMetadata() } : nil
            )
            .id(message.id)
        }
    }

    private func videoBubblePhase(for vm: ChatViewModel, assetId: String?) -> VideoBubblePhase {
        VideoBubblePhase.resolve(
            isUploading: assetId != nil && vm.isUploading && vm.currentAssetId == assetId,
            hasFailed: vm.uploadHasFailed(assetId: assetId),
            isReady: assetId != nil && vm.archive.assetId == assetId)
    }
}
