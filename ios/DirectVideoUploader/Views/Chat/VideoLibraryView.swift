import SwiftUI
import PhotosUI
import Photos

/// Custom video library sheet with inline PhotosPicker — iOS 26.3 style.
/// Provides Clear / Confirm toolbar buttons and a footer with selection count + location info.
struct VideoLibraryView: View {
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var loadedVideoURL: URL?
    @State private var loadedMetadata: VideoMetadata?
    @State private var loadedFileName: String?
    @State private var isLoadingMetadata = false
    @State private var pendingConfirm = false

    /// Called when user taps ✓ with a video selected.
    var onConfirm: (URL, String, VideoMetadata) -> Void
    /// Called when user taps ✓ with nothing selected, or the sheet is dismissed.
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Inline Photos Picker — system photo browser embedded in our view
                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: 1,
                    selectionBehavior: .ordered,
                    matching: .videos
                ) {
                    // Label is ignored in inline mode
                    EmptyView()
                }
                .photosPickerStyle(.inline)
                .photosPickerDisabledCapabilities(.selectionActions)

                // Footer bar — video count + location status
                footerBar
            }
            .background(Color.black)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(hex: "1C1C1E"), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        selectedItems.removeAll()
                        cleanUpLoadedVideo()
                    }
                    .foregroundStyle(selectedItems.isEmpty ? .gray : .white)
                    .disabled(selectedItems.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        handleConfirm()
                    } label: {
                        if pendingConfirm {
                            ProgressView()
                                .tint(Color(hex: "007AFF"))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                        }
                    }
                    .foregroundStyle(Color(hex: "007AFF"))
                }
            }
            .onChange(of: selectedItems) { _, newItems in
                handleSelectionChange(newItems)
            }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerBar: some View {
        if !selectedItems.isEmpty {
            HStack(spacing: 12) {
                // Video count
                Label(
                    "\(selectedItems.count) video selected",
                    systemImage: "video.fill"
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)

                Spacer()

                // Location info
                if isLoadingMetadata {
                    ProgressView()
                        .tint(.gray)
                        .scaleEffect(0.8)
                } else if let meta = loadedMetadata {
                    if meta.gpsLat != nil {
                        Label("Location", systemImage: "location.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "30D158"))
                    } else {
                        Label("No Location", systemImage: "location.slash")
                            .font(.system(size: 13))
                            .foregroundStyle(.gray)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(hex: "1C1C1E"))
        }
    }

    // MARK: - Actions

    private func handleConfirm() {
        if selectedItems.isEmpty {
            onDismiss()
        } else if let url = loadedVideoURL, let metadata = loadedMetadata {
            let fileName = loadedFileName ?? url.lastPathComponent
            onConfirm(url, fileName, metadata)
        } else if isLoadingMetadata {
            // Video still loading — auto-confirm when ready
            pendingConfirm = true
        }
    }

    private func handleSelectionChange(_ newItems: [PhotosPickerItem]) {
        // Clean up previous loaded video (if user re-selects)
        cleanUpLoadedVideo()

        guard let item = newItems.first else { return }

        isLoadingMetadata = true
        Task {
            // Resolve real camera filename (e.g. IMG_1245.MOV) from PHAsset
            let cameraFilename = resolveOriginalFilename(item: item)
            
            do {
                guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                    isLoadingMetadata = false
                    return
                }
                loadedVideoURL = movie.url
                // Prefer PHAsset filename > file system name
                loadedFileName = cameraFilename ?? movie.url.lastPathComponent
                loadedMetadata = await VideoMetadataExtractor.extract(from: movie.url)
            } catch {
                print("❌ [Library] Failed to load video: \(error)")
            }
            isLoadingMetadata = false
            
            // Auto-confirm if user already tapped ✓ while loading
            if pendingConfirm {
                pendingConfirm = false
                handleConfirm()
            }
        }
    }

    private func cleanUpLoadedVideo() {
        if let url = loadedVideoURL {
            try? FileManager.default.removeItem(at: url)
        }
        loadedVideoURL = nil
        loadedFileName = nil
        loadedMetadata = nil
        isLoadingMetadata = false
    }

    /// Resolve the original camera filename (e.g. IMG_1245.MOV) from PHAsset via PHAssetResource.
    private func resolveOriginalFilename(item: PhotosPickerItem) -> String? {
        guard let identifier = item.itemIdentifier else { return nil }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer the primary video resource's original filename
        return resources.first?.originalFilename
    }
}

// MARK: - Video Transferable

/// Loads a video file from PhotosPicker into a temporary location,
/// preserving the original filename from the system.
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            // Keep the original filename from the photo library (e.g. IMG_1245.MOV)
            let originalName = received.file.lastPathComponent
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(originalName)
            // Remove any previous file at this path (re-pick same video)
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return Self(url: tempURL)
        }
    }
}
