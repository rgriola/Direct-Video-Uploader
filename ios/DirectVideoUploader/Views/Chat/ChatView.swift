import SwiftUI

/// Main chat view — mirrors the `chat-demo.html` layout.
struct ChatView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    
    @State private var viewModel: ChatViewModel?
    @State private var showVideoLibrary = false
    
    var body: some View {
        ZStack {
            Theme.chatScreen.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                ChatHeaderView(
                    userName: "Fixer",
                    connectionState: ws.state
                )
                
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if let vm = viewModel {
                                ForEach(vm.messages) { message in
                                    // Outgoing video → show sent upload card with thumbnail
                                    if message.messageType == .video && message.isOutgoing,
                                       vm.sentUploadThumbnails[message.id] != nil || vm.sentUploadFileNames[message.id] != nil {
                                        VideoBubble(
                                            phase: vm.isUploading ? .uploading : .sent,
                                            thumbnail: vm.sentUploadThumbnails[message.id],
                                            fileName: vm.sentUploadFileNames[message.id] ?? message.content.fileName ?? "Video",
                                            createdDate: vm.sentUploadDates[message.id],
                                            hasLocation: vm.sentUploadHasLocation[message.id] ?? false,
                                            uploadProgress: vm.uploadProgress
                                        )
                                        .id(message.id)
                                    } else if message.messageType == .muxReady {
                                        // Archive summary card
                                        ConversationSummaryBubble(
                                            mediasourceId: vm.archivedMediasourceId,
                                            formType: vm.archivedFormType,
                                            formDescription: vm.archivedFormDescription,
                                            formPriority: vm.archivedFormPriority,
                                            duration: vm.archivedDuration,
                                            resolution: vm.archivedResolution,
                                            fileSize: vm.archivedFileSize
                                        )
                                        .id(message.id)
                                    } else {
                                        MessageBubble(
                                            message: message,
                                            thumbnail: message.messageType == .slackPost ? (vm.slackThumbnails[message.id] ?? vm.formThumbnail) : nil,
                                            onTapMetadata: (message.messageType == .formRequest || message.messageType == .confirmation) ? { vm.showMetadata() } : nil,
                                            onTapForm: message.messageType == .formRequest ? { vm.showFormSheet = true } : nil
                                        )
                                        .id(message.id)
                                    }
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
                onConfirm: { fileURL, fileName, metadata, phAssetId in
                    showVideoLibrary = false
                    Task {
                        await viewModel?.stageVideo(fileURL: fileURL, fileName: fileName, metadata: metadata, phAssetIdentifier: phAssetId)
                    }
                },
                onDismiss: {
                    showVideoLibrary = false
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { viewModel?.showFormSheet ?? false },
            set: { viewModel?.showFormSheet = $0 }
        )) {
            if let vm = viewModel, let assetId = vm.currentAssetId {
                ContextFormView(
                    fields: vm.formFields,
                    originalFileName: vm.formOriginalFileName,
                    capturedAt: vm.formCapturedAt,
                    clipCount: vm.formClipCount,
                    duration: vm.formDuration,
                    thumbnail: vm.formThumbnail,
                    submitError: vm.formSubmitError,
                    onSubmit: { formData in
                        vm.formSubmitError = nil  // Clear previous error
                        Task { await vm.submitForm(assetId: assetId, formData: formData) }
                    },
                    onCancel: {
                        vm.cancelForm()
                    }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel?.showMetadataSheet ?? false },
            set: { viewModel?.showMetadataSheet = $0 }
        )) {
            if let vm = viewModel, let clip = vm.lastClip {
                MetadataView(clip: clip, asset: vm.lastAsset, thumbnail: vm.formThumbnail)
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel?.showSlackShareSheet ?? false },
            set: { viewModel?.showSlackShareSheet = $0 }
        )) {
            if let vm = viewModel {
                SlackShareSheet(
                    mediasourceId: vm.archivedMediasourceId,
                    originalFileName: vm.archivedOriginalFileName,
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
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        let targetId: String? = if viewModel?.stagedVideo != nil {
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
}
