// May 11, 2026 - 6:21pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

/// Main chat view — mirrors the `chat-demo.html` layout.
struct ChatView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws

    @State private var viewModel: ChatViewModel?
    @State private var showVideoLibrary = false
    @State private var showOnboarding = false
    @State private var showInstructions = false
    @AppStorage(OnboardingCatalog.completionKey) private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            Theme.chatScreen.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                ChatHeaderView(
                    userName: "Fixer",
                    connectionState: ws.state,
                    onTapInstructions: { showInstructions = true }
                )

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if let vm = viewModel {
                                if vm.shouldRenderBatchQueueBeforeMessages {
                                    batchQueueBubble(vm: vm)
                                        .id("batch-upload-preview")
                                }

                                ForEach(vm.messages) { message in
                                    messageRow(message: message, vm: vm)

                                    if vm.shouldRenderBatchQueue(after: message.id) {
                                        batchQueueBubble(vm: vm)
                                            .id("batch-upload-preview")
                                    }
                                }

                                if vm.shouldRenderBatchQueueAtEnd {
                                    batchQueueBubble(vm: vm)
                                        .id("batch-upload-preview")
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
                                            vm.transcribeOnUpload = transcribe
                                            Task { await vm.confirmStagedUpload() }
                                        },
                                        onCancel: {
                                            vm.cancelStagedVideo()
                                        }
                                    )
                                    .id("staged-video-preview")
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: viewModel?.messages.count) { _, _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: viewModel?.stagedVideo != nil) { _, _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: viewModel?.isUploading) { _, _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: viewModel?.batchProgress) { _, _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: viewModel?.showsBatchBubbleInTimeline) { _, _ in
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
                        showVideoLibrary = true
                    }
                )
            }
        }
        .sheet(isPresented: $showVideoLibrary) {
            VideoLibraryView(
                onConfirmBatch: { selectedVideos in
                    showVideoLibrary = false
                    Task {
                        await viewModel?.stageVideoBatch(selectedVideos: selectedVideos)
                    }
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
            )
        ) {
            if let vm = viewModel {
                ContextFormView(
                    fields: vm.formFields,
                    originalFileName: vm.form.originalFileName,
                    capturedAt: vm.form.capturedAt,
                    clipCount: vm.form.clipCount,
                    duration: vm.form.duration,
                    thumbnail: vm.form.thumbnail,
                    submitError: vm.form.submitError,
                    onSubmit: { formData in
                        vm.form.submitError = nil  // Clear previous error
                        Task { await vm.submitCurrentForm(formData: formData) }
                    },
                    onCancel: {
                        vm.cancelForm()
                    }
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel?.showMetadataSheet ?? false },
                set: { viewModel?.showMetadataSheet = $0 }
            )
        ) {
            if let vm = viewModel, let clip = vm.lastClip {
                MetadataView(
                    clip: clip,
                    asset: vm.lastAsset,
                    thumbnail: vm.metadataSheetThumbnail ?? vm.form.thumbnail
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel?.showSlackShareSheet ?? false },
                set: { viewModel?.showSlackShareSheet = $0 }
            )
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
            let vm = ChatViewModel(auth: auth, ws: ws)
            viewModel = vm
            vm.connectWebSocket()

            if !hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingWalkthroughView(
                onOpenGuide: {
                    showInstructions = true
                }
            )
        }
        .sheet(isPresented: $showInstructions) {
            InstructionsView()
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        let targetId: String? =
            if viewModel?.stagedVideo != nil {
                "staged-video-preview"
            } else if let lastMessageId = viewModel?.messages.last?.id {
                lastMessageId
            } else if viewModel?.showsBatchBubbleInTimeline == true {
                "batch-upload-preview"
            } else {
                nil
            }
        if let targetId {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(targetId, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func batchQueueBubble(vm: ChatViewModel) -> some View {
        BatchUploadBubble(
            state: vm.batchState,
            totalCount: vm.batchItems.count,
            completedCount: vm.batchCompletedCount,
            failedCount: vm.batchFailedCount,
            progress: vm.batchProgress,
            fileNames: vm.batchDisplayFileNames,
            onSend: {
                Task { await vm.confirmBatchUpload() }
            },
            onCancel: {
                vm.cancelStagedBatch()
            },
            onRetry: {
                Task { await vm.retryFailedBatchItems() }
            }
        )
    }

    @ViewBuilder
    private func messageRow(message: ChatMessage, vm: ChatViewModel) -> some View {
        if message.messageType == .video && message.isOutgoing,
            let info = vm.sentUploads[message.id]
        {
            let batchDisplay = vm.batchClipDisplayState(for: message.assetId)

            VideoBubble(
                phase: batchDisplay?.phase ?? videoBubblePhase(for: vm),
                thumbnail: info.thumbnail,
                fileName: info.fileName,
                createdDate: info.createdDate,
                hasLocation: info.hasLocation,
                uploadProgress: batchDisplay?.progress ?? vm.uploadProgress,
                didTranscribe: info.transcribeEnabled,
                mediasourceId: batchDisplay?.mediasourceId,
                formSlug: batchDisplay?.formSlug,
                errorText: batchDisplay?.errorText,
                onTapMetadata: message.assetId.map { assetId in
                    { vm.showMetadata(for: assetId) }
                }
            )
            .id(message.id)
        } else if message.messageType == .muxReady {
            let canUseArchiveFallback = message.assetId == vm.archive.assetId
            let summaryMediasourceId =
                message.content.mediasourceId
                ?? (canUseArchiveFallback ? vm.archive.mediasourceId : nil)
            let summaryMediasourceUrl =
                message.content.mediasourceUrl
                ?? (canUseArchiveFallback ? vm.archive.mediasourceUrl : nil)
            let summaryFormSlug =
                message.content.slug
                ?? (canUseArchiveFallback ? vm.archive.formSlug : nil)
            let summaryDuration =
                message.content.duration
                ?? (canUseArchiveFallback ? vm.archive.duration : nil)
            let summaryResolution =
                message.content.resolution
                ?? (canUseArchiveFallback ? vm.archive.resolution : nil)
            let summaryFileSize =
                message.content.fileSize
                ?? (canUseArchiveFallback ? vm.archive.fileSize : nil)

            ConversationSummaryBubble(
                mediasourceId: summaryMediasourceId,
                mediasourceUrl: summaryMediasourceUrl,
                formSlug: summaryFormSlug,
                duration: summaryDuration,
                resolution: summaryResolution,
                fileSize: summaryFileSize
            )
            .id(message.id)
        } else {
            MessageBubble(
                message: message,
                thumbnail: message.messageType == .slackPost
                    ? (vm.slackThumbnails[message.id] ?? vm.form.thumbnail) : nil,
                slackSent: message.messageType == .slackPost && message.isOutgoing
                    && vm.slackConfirmedIds.contains(message.id),
                onTapMetadata: message.messageType == .confirmation
                    ? { vm.showMetadata(for: message.assetId) } : nil
            )
            .id(message.id)
        }
    }

    private func videoBubblePhase(for vm: ChatViewModel) -> VideoBubblePhase {
        if vm.isUploading {
            return .uploading
        } else if vm.archive.assetId != nil {
            return .sent
        } else {
            return .processing
        }
    }
}
