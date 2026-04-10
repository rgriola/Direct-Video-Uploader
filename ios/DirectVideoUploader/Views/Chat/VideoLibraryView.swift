import SwiftUI
import PhotosUI
import Photos
import AVFoundation
import CoreMedia
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
            .background(Theme.black)
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
                    } else {
                        Label("video queued", systemImage: "video.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.white)

                        if loadedMetadata?.gpsLat != nil {
                            Label("GPS", systemImage: "location.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.green)
                        }
                    }

                    Spacer()

                    // Confirm button — outside PhotosPicker touch zone
                    Button(action: handleConfirm) {
                        if pendingConfirm {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                                .frame(width: 80, height: 36)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(Theme.emptyEmojiFont)
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
            .background(Theme.darkBg)
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

        isLoadingMetadata = true
        Task {
            defer {
                isLoadingMetadata = false
                if pendingConfirm {
                    pendingConfirm = false
                    handleConfirm()
                }
            }

            // Resolve real camera filename (e.g. IMG_1245.MOV) from PHAsset
            let cameraFilename = resolveOriginalFilename(item: item)

            // Fast path: get a direct URL from PHAsset without copying the file.
            // This is how native iOS Photos loads videos instantly.
            if let identifier = item.itemIdentifier,
               let videoURL = await resolveVideoURL(identifier: identifier) {
                loadedVideoURL = videoURL
                loadedFileName = cameraFilename ?? videoURL.lastPathComponent
                // Pull metadata from PHAsset properties (no file I/O)
                loadedMetadata = await extractMetadataFromPHAsset(item: item, videoURL: videoURL)
                return
            }

            // Slow fallback: full file copy via Transferable (only if PHAsset path fails)
            do {
                guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
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
                try? FileManager.default.removeItem(at: url)
            }
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

    /// Resolve a direct file URL from a PHAsset without copying the video.
    /// Uses PHImageManager.requestAVAsset which returns an AVURLAsset referencing
    /// the file in-place — no copy, same speed as native iOS Photos.
    private func resolveVideoURL(identifier: String) async -> URL? {
        let results = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let phAsset = results.firstObject else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false  // local only — skip iCloud
            options.version = .current
            options.deliveryMode = .fastFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, _ in
                let url = (avAsset as? AVURLAsset)?.url
                continuation.resume(returning: url)
            }
        }
    }

    /// Extract metadata directly from PHAsset properties — no file I/O needed.
    /// Falls back to file-based extraction only for codec info.
    private func extractMetadataFromPHAsset(item: PhotosPickerItem, videoURL: URL) async -> VideoMetadata {
        // Try to get PHAsset for fast metadata
        if let identifier = item.itemIdentifier {
            let results = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            if let phAsset = results.firstObject {
                let duration = Int(phAsset.duration)
                let width = phAsset.pixelWidth
                let height = phAsset.pixelHeight
                let resolution = "\(max(width, height))×\(min(width, height))"
                let orientation = width >= height ? "landscape" : "portrait"

                // Creation date
                let capturedAt = phAsset.creationDate.map {
                    ISO8601DateFormatter().string(from: $0)
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
                   let desc = descriptions.first {
                    let subType = CMFormatDescriptionGetMediaSubType(desc)
                    codec = codecName(from: subType)
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

        // Fallback: full file-based extraction
        return await VideoMetadataExtractor.extract(from: videoURL)
    }

    /// Map FourCC codec codes to human-readable names.
    private func codecName(from subType: FourCharCode) -> String {
        switch subType {
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha:
            return "HEVC / H.265"
        case kCMVideoCodecType_H264:
            return "AVC / H.264"
        case kCMVideoCodecType_AV1:
            return "AV1"
        default:
            let chars = [
                Character(UnicodeScalar((subType >> 24) & 0xFF)!),
                Character(UnicodeScalar((subType >> 16) & 0xFF)!),
                Character(UnicodeScalar((subType >> 8) & 0xFF)!),
                Character(UnicodeScalar(subType & 0xFF)!),
            ]
            return String(chars)
        }
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
