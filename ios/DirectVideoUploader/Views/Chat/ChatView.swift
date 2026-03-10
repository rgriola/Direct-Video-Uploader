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
                    connectionState: ws.state,
                    onLogout: { auth.logout(); ws.disconnect() }
                )
                
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if let vm = viewModel {
                                // Typing indicator while awaiting server greeting
                                if vm.isAwaitingGreeting {
                                    TypingIndicatorBubble()
                                        .id("typing-indicator")
                                }
                                
                                ForEach(vm.messages) { message in
                                    // Outgoing video → show sent upload card with thumbnail
                                    if message.messageType == .video && message.isOutgoing,
                                       vm.sentUploadThumbnails[message.id] != nil || vm.sentUploadFileNames[message.id] != nil {
                                        SentUploadBubble(
                                            thumbnail: vm.sentUploadThumbnails[message.id],
                                            fileName: vm.sentUploadFileNames[message.id] ?? message.content.fileName ?? "Video",
                                            createdDate: vm.sentUploadDates[message.id],
                                            hasLocation: vm.sentUploadHasLocation[message.id] ?? false
                                        )
                                        .id(message.id)
                                    } else {
                                        MessageBubble(
                                            message: message,
                                            onTapMetadata: (message.messageType == .formRequest || message.messageType == .confirmation) ? { vm.showMetadata() } : nil,
                                            onTapForm: message.messageType == .formRequest ? { vm.showFormSheet = true } : nil
                                        )
                                        .id(message.id)
                                    }
                                }
                                
                                // Staged video preview — user must confirm before upload
                                if let staged = vm.stagedVideo {
                                    VideoPreviewBubble(
                                        stagedVideo: staged,
                                        onSend: {
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
                        if let lastId = viewModel?.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                
                // Upload progress bar
                if let vm = viewModel, vm.isUploading {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.blue)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Uploading video…")
                                .font(.caption)
                                .foregroundStyle(.white)
                            
                            ProgressView(value: vm.uploadProgress)
                                .tint(.blue)
                        }
                        
                        Text("\(Int(vm.uploadProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.gray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.chatScreen)
                }
                
                // Input bar
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
                onConfirm: { fileURL, fileName, metadata in
                    showVideoLibrary = false
                    Task {
                        await viewModel?.stageVideo(fileURL: fileURL, fileName: fileName, metadata: metadata)
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
        .task {
            // Only create ViewModel once — guard prevents re-creation on tab switch
            guard viewModel == nil else { return }
            let vm = ChatViewModel(auth: auth, ws: ws)
            viewModel = vm
            vm.connectWebSocket()
        }
    }
}
