// May 10, 2026 - 3:34pm - GitHub Copilot (GPT-5.3-Codex)
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
                onConfirm: { picked in
                    showVideoLibrary = false
                    Task {
                        await viewModel?.stageVideo(
                            fileURL: picked.fileURL, fileName: picked.fileName,
                            metadata: picked.metadata,
                            phAssetIdentifier: picked.phAssetIdentifier,
                            isTrimmed: picked.isTrimmed)
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
            if let vm = viewModel, let assetId = vm.currentAssetId {
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
                        Task { await vm.submitForm(assetId: assetId, formData: formData) }
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
                MetadataView(clip: clip, asset: vm.lastAsset, thumbnail: vm.form.thumbnail)
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
                phase: videoBubblePhase(for: vm),
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
