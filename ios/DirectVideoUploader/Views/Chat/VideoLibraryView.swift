import AVFoundation
import CoreMedia
import Photos
import PhotosUI
// May 10, 2026 - 12:59pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI
import UIKit

/// Custom video library sheet with inline PhotosPicker — iOS 26.3 style.
/// Provides Clear / Confirm toolbar buttons and a footer with selection count + location info.
struct VideoLibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var loadedVideoURL: URL?
    @State private var loadedMetadata: VideoMetadata?
    @State private var loadedFileName: String?
    @State private var isLoadingMetadata = false
    @State private var pendingConfirm = false
    @State private var loadError: String?
    @State private var showTrimSheet = false
    @State private var showPhotoAlert = false

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
            .background(Theme.black)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Theme.black, for: .navigationBar)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
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
                if newItems.isEmpty {
                    cleanUpLoadedVideo()
                } else {
                    handleSelectionChange(newItems)
                }
            }
        }
        .presentationDetents([.large])
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
        .alert("Videos Only", isPresented: $showPhotoAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Fixer doesn't handle photos just yet. Only video.")
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerBar: some View {
        if !selectedItems.isEmpty || loadedVideoURL != nil || isLoadingMetadata {
            VStack(spacing: 0) {
                // Error banner
                if let error = loadError {
                    Text(error)
                        .font(Theme.font13Regular)
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
                            .tint(Theme.secondaryText)
                            .scaleEffect(0.8)
                        Text("Loading video...")
                            .font(Theme.font13Medium)
                            .foregroundStyle(Theme.secondaryText)
                    } else if loadedVideoURL != nil {
                        Label("video queued", systemImage: "video.fill")
                            .font(Theme.font13Medium)
                            .foregroundStyle(Theme.white)

                        if loadedMetadata?.gpsLat != nil {
                            Label("GPS", systemImage: "location.fill")
                                .font(Theme.font13Regular)
                                .foregroundStyle(Theme.green)
                        }
                    } else {
                        Label("Select a video", systemImage: "video")
                            .font(Theme.font13Medium)
                            .foregroundStyle(Theme.secondaryText)
                    }

                    Spacer()

                    // Confirm button — outside PhotosPicker touch zone
                    Button(action: handleConfirm) {
                        if pendingConfirm {
                            ProgressView()
                                .tint(Theme.white)
                                .scaleEffect(0.8)
                                .frame(width: 80, height: 36)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(Theme.display32)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                    Theme.white,
                                    isVideoReady ? Theme.purple : Theme.purple.opacity(0.4)
                                )
                        }
                    }
                    .disabled(isLoadingMetadata && !pendingConfirm)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.black)
        }
    }

    // MARK: - Computed Properties

    private var isVideoReady: Bool {
        loadedVideoURL != nil && loadedMetadata != nil
    }

    // MARK: - Actions

    private func handleConfirm() {
        if selectedItems.isEmpty {
            onDismiss()
        } else if isVideoReady {
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

        // Reject non-video items (photos can slip through in Collections view)
        let validVideoTypes: Set<String> = [
            "public.movie", "public.video", "public.mpeg-4",
            "com.apple.quicktime-movie", "public.avi",
        ]
        let itemTypes = Set(item.supportedContentTypes.map(\.identifier))
        guard !itemTypes.isDisjoint(with: validVideoTypes) else {
            showPhotoAlert = true
            selectedItems.removeAll()
            return
        }

        isLoadingMetadata = true
        Task {
            defer {
                isLoadingMetadata = false
                if pendingConfirm {
                    pendingConfirm = false
                    // Only auto-confirm if loading succeeded — prevents infinite retry loop on failure
                    if loadedVideoURL != nil {
                        handleConfirm()
                    }
                }
            }

            // Resolve PHAsset once — used for filename, video URL, and metadata
            let phAsset: PHAsset? = {
                guard let identifier = item.itemIdentifier else { return nil }
                return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                    .firstObject
            }()

            let cameraFilename = resolveOriginalFilename(phAsset: phAsset)

            // Fast path: get a direct URL from PHAsset without copying the file.
            // This is how native iOS Photos loads videos instantly.
            if let phAsset,
                let videoURL = await resolveVideoURL(phAsset: phAsset)
            {
                loadedVideoURL = videoURL
                loadedFileName = cameraFilename ?? videoURL.lastPathComponent
                // Pull metadata from PHAsset properties (no file I/O)
                loadedMetadata = await extractMetadataFromPHAsset(
                    phAsset: phAsset, videoURL: videoURL)
                return
            }

            // Slow fallback: full file copy via Transferable (only if PHAsset path fails)
            do {
                guard let movie = try await item.loadTransferable(type: VideoTransferable.self)
                else {
                    loadError = "Could not load video from library"
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
        }
    }

    private func cleanUpLoadedVideo() {
        if let url = loadedVideoURL {
            // Only delete temp copies we made (Transferable fallback path).
            // Don't delete Photos library references (fast path).
            let tempDir = FileManager.default.temporaryDirectory.path
            if url.path.hasPrefix(tempDir) {
                Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        loadedVideoURL = nil
        loadedFileName = nil
        loadedMetadata = nil
        isLoadingMetadata = false
    }

    /// Resolve the original camera filename (e.g. IMG_1245.MOV) from PHAsset via PHAssetResource.
    private func resolveOriginalFilename(phAsset: PHAsset?) -> String? {
        guard let phAsset else { return nil }
        let resources = PHAssetResource.assetResources(for: phAsset)
        return resources.first?.originalFilename
    }

    /// Resolve a direct file URL from a PHAsset without copying the video.
    /// Uses PHImageManager.requestAVAsset which returns an AVURLAsset referencing
    /// the file in-place — no copy, same speed as native iOS Photos.
    private func resolveVideoURL(phAsset: PHAsset) async -> URL? {
        await withCheckedContinuation { continuation in
            var resumed = false
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false  // local only — skip iCloud
            options.version = .current
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) {
                avAsset, _, _ in
                guard !resumed else { return }
                resumed = true
                let url = (avAsset as? AVURLAsset)?.url
                continuation.resume(returning: url)
            }
        }
    }

    /// Extract metadata directly from PHAsset properties — no file I/O needed.
    /// Falls back to file-based extraction only for codec info.
    private func extractMetadataFromPHAsset(phAsset: PHAsset, videoURL: URL) async -> VideoMetadata
    {
        let duration = Int(phAsset.duration)
        let width = phAsset.pixelWidth
        let height = phAsset.pixelHeight
        let resolution = "\(max(width, height))×\(min(width, height))"
        let orientation = width >= height ? "landscape" : "portrait"

        // Creation date
        let capturedAt = phAsset.creationDate.map {
            DVUDateFormatting.isoString(from: $0)
        }

        // GPS from PHAsset location
        let gpsLat = phAsset.location?.coordinate.latitude
        let gpsLon = phAsset.location?.coordinate.longitude
        let gpsAltitude = phAsset.location?.altitude

        // Codec — quick AVAsset header read (doesn't load full file)
        let asset = AVURLAsset(url: videoURL)
        var codec = "Unknown"
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
            let track = tracks.first,
            let descriptions = try? await track.load(.formatDescriptions),
            let desc = descriptions.first
        {
            let subType = CMFormatDescriptionGetMediaSubType(desc)
            codec = VideoMetadataExtractor.codecName(from: subType)
        }

        let deviceModel = UIDevice.current.model
        let osVersion = "iOS \(UIDevice.current.systemVersion)"

        return VideoMetadata(
            duration: duration,
            resolution: resolution,
            codec: codec,
            orientation: orientation,
            deviceModel: deviceModel,
            osVersion: osVersion,
            capturedAt: capturedAt,
            gpsLat: gpsLat,
            gpsLon: gpsLon,
            gpsAltitude: gpsAltitude
        )
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
            let subdir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            let tempURL = subdir.appendingPathComponent(originalName)
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return Self(url: tempURL)
        }
    }
}
