import SwiftUI
import PhotosUI
import Photos
import UIKit

/// Custom video library sheet with inline PhotosPicker — iOS 26.3 style.
/// Provides Clear / Confirm toolbar buttons and a footer with selection count + location info.
struct VideoLibraryView: View {
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var loadedVideoURL: URL?
    @State private var loadedMetadata: VideoMetadata?
    @State private var loadedFileName: String?
    @State private var isLoadingMetadata = false
    @State private var pendingConfirm = false
    @State private var loadError: String?
    @State private var showTrimSheet = false

    /// Called when user taps ✓ with a video selected.
    var onConfirm: (URL, String, VideoMetadata, String?) -> Void
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

                // Footer bar — video count + location status + confirm button
                footerBar
            }
            .background(Color.black)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Theme.darkBg, for: .navigationBar)
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
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.gray)
                }
            }
            .onChange(of: selectedItems) { _, newItems in
                handleSelectionChange(newItems)
            }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showTrimSheet) {
            if let url = loadedVideoURL {
                VideoTrimView(
                    videoURL: url,
                    originalFileName: loadedFileName ?? url.lastPathComponent,
                    onTrimmed: { trimmedURL in
                        showTrimSheet = false
                        handleTrimResult(trimmedURL: trimmedURL)
                    },
                    onCancel: {
                        showTrimSheet = false
                    }
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerBar: some View {
        if !selectedItems.isEmpty {
            VStack(spacing: 0) {
                // Error banner
                if let error = loadError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.red.opacity(0.15))
                }

                HStack(spacing: 12) {
                    // Video info
                    if isLoadingMetadata {
                        ProgressView()
                            .tint(.gray)
                            .scaleEffect(0.8)
                        Text("Loading video...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.gray)
                    } else if let meta = loadedMetadata {
                        Label(
                            "\(selectedItems.count) video selected",
                            systemImage: "video.fill"
                        )
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)

                        if meta.gpsLat != nil {
                            Label("Location", systemImage: "location.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.green)
                        }
                    } else {
                        Label(
                            "\(selectedItems.count) video selected",
                            systemImage: "video.fill"
                        )
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                    }

                    Spacer()

                    // Confirm button — outside PhotosPicker touch zone
                    Button {
                        handleConfirm()
                    } label: {
                        if pendingConfirm {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                                .frame(width: 80, height: 36)
                        } else {
                            Label("Trim & Send", systemImage: "scissors")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                    }
                    .background(
                        (loadedVideoURL != nil && loadedMetadata != nil)
                            ? Theme.blue : Theme.blue.opacity(0.4)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(isLoadingMetadata && !pendingConfirm)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.darkBg)
        }
    }

    // MARK: - Actions

    private func handleConfirm() {
        if selectedItems.isEmpty {
            onDismiss()
        } else if loadedVideoURL != nil, loadedMetadata != nil {
            showTrimSheet = true
        } else if isLoadingMetadata || loadedVideoURL == nil {
            pendingConfirm = true
            if !isLoadingMetadata, let item = selectedItems.first {
                loadError = nil
                handleSelectionChange([item])
            }
        }
    }
    
    /// Handle result from the video trim editor.
    private func handleTrimResult(trimmedURL: URL) {
        // Use the trimmed file's name (includes -edited suffix if trimmed)
        let fileName = trimmedURL.lastPathComponent
        // Resolve PHAsset identifier for re-upload recovery
        let phAssetId = selectedItems.first.flatMap { $0.itemIdentifier }
        // Re-extract metadata from trimmed file (duration/fileSize changed)
        Task {
            let updatedMetadata = await VideoMetadataExtractor.extract(from: trimmedURL)
            onConfirm(trimmedURL, fileName, updatedMetadata, phAssetId)
        }
    }

    private func handleSelectionChange(_ newItems: [PhotosPickerItem]) {
        // Clean up previous loaded video (if user re-selects)
        cleanUpLoadedVideo()
        loadError = nil

        guard let item = newItems.first else { return }

        isLoadingMetadata = true
        Task {
            // Resolve real camera filename (e.g. IMG_1245.MOV) from PHAsset
            let cameraFilename = resolveOriginalFilename(item: item)
            
            do {
                guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                    loadError = "Could not load video from library"
                    isLoadingMetadata = false
                    if pendingConfirm { pendingConfirm = false }
                    return
                }
                loadedVideoURL = movie.url
                // Prefer PHAsset filename > file system name
                loadedFileName = cameraFilename ?? movie.url.lastPathComponent
                loadedMetadata = await VideoMetadataExtractor.extract(from: movie.url)
            } catch {
                print("❌ [Library] Failed to load video: \(error)")
                loadError = "Failed to load video: \(error.localizedDescription)"
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
