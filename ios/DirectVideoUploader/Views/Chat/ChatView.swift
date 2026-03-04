import SwiftUI
import PhotosUI

/// Main chat view — mirrors the `chat-demo.html` layout.
struct ChatView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    
    @State private var viewModel: ChatViewModel?
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                ChatHeaderView(
                    userName: "Mediasource Fixer",
                    subtitle: auth.currentUser?.team ?? "Newsroom",
                    isConnected: ws.isConnected,
                    onLogout: { auth.logout(); ws.disconnect() }
                )
                
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if let vm = viewModel {
                                ForEach(vm.messages) { message in
                                    MessageBubble(
                                        message: message,
                                        onTapMetadata: message.messageType == .formRequest ? { vm.showMetadata() } : nil,
                                        onTapForm: message.messageType == .formRequest ? { vm.showFormSheet = true } : nil
                                    )
                                    .id(message.id)
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
                    .background(Color.black)
                }
                
                // Input bar
                InputBar(
                    onSend: { text in
                        viewModel?.sendTextMessage(text)
                    },
                    onAttach: {
                        showPhotoPicker = true
                    }
                )
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .videos)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard newItem != nil else { return }
            Task {
                await handleVideoPick(newItem)
                selectedPhotoItem = nil  // Reset so same video can be picked again
            }
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
                    onSubmit: { formData in
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
                MetadataView(clip: clip, asset: vm.lastAsset)
            }
        }
        .task {
            // Initialize ViewModel
            let vm = ChatViewModel(auth: auth, ws: ws)
            viewModel = vm
            
            // Load message history
            await vm.loadMessageHistory()
            
            // Connect WebSocket
            vm.connectWebSocket()
        }
    }
    
    // MARK: - Video Picker Handler
    
    private func handleVideoPick(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        
        print("📹 [Picker] Video selected, loading transferable...")
        
        // Get video data reference
        let movie: VideoTransferable
        do {
            guard let loaded = try await item.loadTransferable(type: VideoTransferable.self) else {
                print("❌ [Picker] loadTransferable returned nil")
                return
            }
            movie = loaded
        } catch {
            print("❌ [Picker] loadTransferable failed: \(error)")
            return
        }
        
        let fileName = movie.url.lastPathComponent
        print("📹 [Picker] Video ready: \(fileName) at \(movie.url.path)")
        
        // Verify file exists
        guard FileManager.default.fileExists(atPath: movie.url.path) else {
            print("❌ [Picker] Video file not found at: \(movie.url.path)")
            return
        }
        
        // Create asset on server
        if let asset = await viewModel?.createAsset(fileName: fileName, fileURL: movie.url) {
            print("✅ Asset created: \(asset.slug)")
            
            // Extract real metadata from the video file
            let metadata = await VideoMetadataExtractor.extract(from: movie.url)
            print("📊 [Metadata] duration=\(metadata.duration)s resolution=\(metadata.resolution) codec=\(metadata.codec)")
            
            await viewModel?.uploadVideo(assetId: asset.id, fileURL: movie.url, metadata: metadata)
            
            // Clean up temp video file after upload (#18)
            try? FileManager.default.removeItem(at: movie.url)
        }
    }
}

// MARK: - Video Transferable

struct VideoTransferable: Transferable {
    let url: URL
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return Self(url: tempURL)
        }
    }
}
