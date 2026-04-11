import SwiftUI

/// Main chat view — mirrors the `chat-demo.html` layout.
struct ChatView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    
    @State private var viewModel: ChatViewModel?
    @State private var showVideoLibrary = false
    @State private var showPhotoLibrary = false
    @State private var showMediaPicker = false
    @State private var showInstructions = false
    @AppStorage("hasSeenInstructions") private var hasSeenInstructions = false
    
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
                                    // Outgoing video → show sent upload card with thumbnail
                                    if message.messageType == .video && message.isOutgoing,
                                       let info = vm.sentUploads[message.id] {
                                        VideoBubble(
                                            phase: vm.isUploading ? .uploading : .sent,
                                            thumbnail: info.thumbnail,
                                            fileName: info.fileName,
                                            createdDate: info.createdDate,
                                            hasLocation: info.hasLocation,
                                            uploadProgress: vm.uploadProgress
                                        )
                                        .id(message.id)
                                    } else if message.messageType == .muxReady {
                                        // Archive summary card
                                        ConversationSummaryBubble(
                                            mediasourceId: vm.archive.mediasourceId,
                                            formType: vm.archive.formType,
                                            formDescription: vm.archive.formDescription,
                                            formPriority: vm.archive.formPriority,
                                            duration: vm.archive.duration,
                                            resolution: vm.archive.resolution,
                                            fileSize: vm.archive.fileSize
                                        )
                                        .id(message.id)
                                    } else {
                                        MessageBubble(
                                            message: message,
                                            thumbnail: message.messageType == .slackPost ? (vm.slackThumbnails[message.id] ?? vm.form.thumbnail) : nil,
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
                                
                                // Staged photo batch preview — user must confirm before upload
                                if let batch = vm.stagedPhotoBatch {
                                    PhotoBatchBubble(
                                        phase: .staged,
                                        thumbnails: batch.items.prefix(4).map(\.thumbnail),
                                        photoCount: batch.count,
                                        summary: batch.summary,
                                        formatSummary: batch.formatSummary,
                                        hasLocation: batch.hasLocation,
                                        onSend: {
                                            Task { await vm.confirmPhotoUpload() }
                                        },
                                        onCancel: {
                                            vm.cancelStagedPhotos()
                                        }
                                    )
                                    .id("staged-photo-preview")
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
                    .onChange(of: viewModel?.stagedPhotoBatch != nil) { _, _ in
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
                        showMediaPicker = true
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
        .sheet(isPresented: $showPhotoLibrary) {
            PhotoLibraryView(
                onConfirm: { items in
                    showPhotoLibrary = false
                    viewModel?.stagePhotos(items: items)
                },
                onDismiss: {
                    showPhotoLibrary = false
                }
            )
        }
        .confirmationDialog("Select Media", isPresented: $showMediaPicker) {
            Button("\u{1F4F9} Video") {
                showVideoLibrary = true
            }
            Button("\u{1F4F8} Photos") {
                showPhotoLibrary = true
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: Binding(
            get: { viewModel?.showFormSheet ?? false },
            set: { viewModel?.showFormSheet = $0 }
        )) {
            if let vm = viewModel, let assetId = vm.currentAssetId {
                ContextFormView(
                    fields: vm.formFields,
                    originalFileName: vm.form.originalFileName,
                    capturedAt: vm.form.capturedAt,
                    clipCount: vm.form.clipCount,
                    duration: vm.form.duration,
                    thumbnail: vm.form.thumbnail,
                    submitError: vm.form.submitError,
                    onSubmit: { formData, photoMeta in
                        vm.form.submitError = nil  // Clear previous error
                        Task { await vm.submitForm(assetId: assetId, formData: formData, photoMetadata: photoMeta) }
                    },
                    onCancel: {
                        vm.cancelForm()
                    },
                    mediaType: vm.form.mediaType,
                    photoThumbnails: vm.form.photoThumbnails,
                    photoClipIds: vm.form.photoClipIds
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel?.showMetadataSheet ?? false },
            set: { viewModel?.showMetadataSheet = $0 }
        )) {
            if let vm = viewModel, let clip = vm.lastClip {
                MetadataView(clip: clip, asset: vm.lastAsset, thumbnail: vm.form.thumbnail)
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel?.showSlackShareSheet ?? false },
            set: { viewModel?.showSlackShareSheet = $0 }
        )) {
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
            // Show instructions on first launch
            if !hasSeenInstructions {
                showInstructions = true
                hasSeenInstructions = true
            }
        }
        .sheet(isPresented: $showInstructions) {
            InstructionsView()
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        let targetId: String? = if viewModel?.stagedPhotoBatch != nil {
            "staged-photo-preview"
        } else if viewModel?.stagedVideo != nil {
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
