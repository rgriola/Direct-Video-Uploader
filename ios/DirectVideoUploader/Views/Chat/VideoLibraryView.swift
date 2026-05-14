// May 11, 2026 - 4:58pm - GitHub Copilot (GPT-5.3-Codex)
import AVFoundation
import CoreMedia
import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Custom video library sheet with inline PhotosPicker — iOS 26.3 style.
/// Supports multi-clip selection and emits one batch callback.
struct VideoLibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedVideos: [SelectedVideo] = []
    @State private var isLoadingMetadata = false
    @State private var pendingConfirm = false
    @State private var loadError: String?
    @State private var showPhotoAlert = false
    @State private var activeTrimVideo: SelectedVideo?
    @State private var selectionTask: Task<Void, Never>?
    @State private var selectionToken = UUID()

    /// Called when user confirms one or more selected videos.
    var onConfirmBatch: ([SelectedVideo]) -> Void
    /// Called when user taps X or confirms with no selection.
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: 25,
                    selectionBehavior: .ordered,
                    matching: .videos
                ) {
                    EmptyView()
                }
                .photosPickerStyle(.inline)
                .photosPickerDisabledCapabilities(.selectionActions)

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
                        cleanUpLoadedVideos()
                        selectedVideos.removeAll()
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
                    selectionTask?.cancel()
                    cleanUpLoadedVideos()
                    selectedVideos.removeAll()
                    loadError = nil
                    pendingConfirm = false
                } else {
                    handleSelectionChange(newItems)
                }
            }
        }
        .presentationDetents([.large])
        .fullScreenCover(item: $activeTrimVideo) { selected in
            VideoTrimView(
                videoURL: selected.fileURL,
                originalFileName: selected.fileName,
                onTrimmed: { trimmedURL in
                    activeTrimVideo = nil
                    handleTrimResult(trimmedURL: trimmedURL, source: selected)
                },
                onCancel: {
                    activeTrimVideo = nil
                }
            )
            .ignoresSafeArea()
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
        if !selectedItems.isEmpty || !selectedVideos.isEmpty || isLoadingMetadata {
            VStack(spacing: 0) {
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
                    if isLoadingMetadata {
                        ProgressView()
                            .tint(Theme.secondaryText)
                            .scaleEffect(0.8)
                        Text(
                            "Indexing \(selectedItems.count) video\(selectedItems.count == 1 ? "" : "s")…"
                        )
                        .font(Theme.font13Medium)
                        .foregroundStyle(Theme.secondaryText)
                    } else if isBatchReady {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(
                                "\(selectedVideos.count) video\(selectedVideos.count == 1 ? "" : "s") queued",
                                systemImage: "video.fill"
                            )
                            .font(Theme.font13Medium)
                            .foregroundStyle(Theme.white)

                            Text(estimatedTotalBytesText)
                                .font(Theme.font11Regular)
                                .foregroundStyle(Theme.secondaryText)
                        }

                        if gpsVideoCount > 0 {
                            Label("\(gpsVideoCount) GPS", systemImage: "location.fill")
                                .font(Theme.font13Regular)
                                .foregroundStyle(Theme.green)
                        }
                    } else {
                        Label("Select video clips", systemImage: "video")
                            .font(Theme.font13Medium)
                            .foregroundStyle(Theme.secondaryText)
                    }

                    Spacer()

                    if isSingleVideoReady {
                        Button(action: openTrimForSingleSelection) {
                            Text("Trim")
                                .font(Theme.font13Semibold)
                                .foregroundStyle(Color.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.yellow)
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel("Trim selected video")
                        .disabled(isLoadingMetadata || pendingConfirm)
                    }

                    Button(action: handleConfirm) {
                        if pendingConfirm {
                            ProgressView()
                                .tint(Theme.white)
                                .scaleEffect(0.8)
                                .frame(width: 80, height: 36)
                        } else {
                            Text("Send")
                                .font(Theme.font13Semibold)
                                .foregroundStyle(Theme.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(isBatchReady ? Theme.purple : Theme.purple.opacity(0.4))
                                .clipShape(Capsule())
                        }
                    }
                    .disabled(selectedItems.isEmpty || (isLoadingMetadata && !pendingConfirm))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.black)
        }
    }

    // MARK: - Computed Properties

    private var isBatchReady: Bool {
        !selectedItems.isEmpty && selectedVideos.count == selectedItems.count
    }

    private var isSingleVideoReady: Bool {
        isBatchReady && selectedVideos.count == 1
    }

    private var gpsVideoCount: Int {
        selectedVideos.filter { $0.metadata.gpsLat != nil }.count
    }

    private var estimatedTotalBytesText: String {
        let totalBytes = selectedVideos.reduce(Int64(0)) { partial, selected in
            let attrs = try? FileManager.default.attributesOfItem(atPath: selected.fileURL.path)
            let size = attrs?[.size] as? Int64 ?? 0
            return partial + size
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalBytes)
    }

    // MARK: - Actions

    private func handleConfirm() {
        if selectedItems.isEmpty {
            onDismiss()
            return
        }

        guard isBatchReady else {
            pendingConfirm = true
            return
        }

        if selectedVideos.count == 1, let selected = selectedVideos.first {
            onConfirmBatch([selected])
            return
        }

        onConfirmBatch(selectedVideos)
    }

    private func handleTrimResult(trimmedURL: URL, source: SelectedVideo) {
        Task {
            let updatedMetadata = await VideoMetadataExtractor.extract(from: trimmedURL)
            let trimmedVideo = SelectedVideo(
                fileURL: trimmedURL,
                fileName: trimmedURL.lastPathComponent,
                metadata: updatedMetadata,
                phAssetIdentifier: source.phAssetIdentifier
            )
            onConfirmBatch([trimmedVideo])
        }
    }

    private func openTrimForSingleSelection() {
        guard let selected = selectedVideos.first else { return }
        // Present on next run-loop turn so PhotosPicker interaction state can settle.
        Task { @MainActor in
            await Task.yield()
            activeTrimVideo = selected
        }
    }

    private func handleSelectionChange(_ newItems: [PhotosPickerItem]) {
        selectionTask?.cancel()
        cleanUpLoadedVideos()
        selectedVideos.removeAll()
        loadError = nil

        let token = UUID()
        selectionToken = token
        isLoadingMetadata = true

        selectionTask = Task {
            var loaded: [SelectedVideo] = []
            var foundNonVideo = false

            for item in newItems {
                if Task.isCancelled { return }

                let itemTypes = Set(item.supportedContentTypes.map(\.identifier))
                let validVideoTypes: Set<String> = [
                    "public.movie", "public.video", "public.mpeg-4",
                    "com.apple.quicktime-movie", "public.avi",
                ]
                if itemTypes.isDisjoint(with: validVideoTypes) {
                    foundNonVideo = true
                    continue
                }

                if let selected = await loadSelectedVideo(item) {
                    loaded.append(selected)
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard selectionToken == token else { return }
                isLoadingMetadata = false
                selectedVideos = loaded

                if foundNonVideo {
                    showPhotoAlert = true
                }

                if loaded.count != newItems.count {
                    loadError = "Some selected videos could not be loaded. Please re-select."
                }

                if pendingConfirm {
                    pendingConfirm = false
                    if isBatchReady {
                        handleConfirm()
                    }
                }
            }
        }
    }

    private func loadSelectedVideo(_ item: PhotosPickerItem) async -> SelectedVideo? {
        let phAsset: PHAsset? = {
            guard let identifier = item.itemIdentifier else { return nil }
            return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        }()

        let cameraFilename = resolveOriginalFilename(phAsset: phAsset)

        if let phAsset,
            let videoURL = await resolveVideoURL(phAsset: phAsset)
        {
            let metadata = await extractMetadataFromPHAsset(phAsset: phAsset, videoURL: videoURL)
            return SelectedVideo(
                fileURL: videoURL,
                fileName: cameraFilename ?? videoURL.lastPathComponent,
                metadata: metadata,
                phAssetIdentifier: item.itemIdentifier
            )
        }

        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self)
            else {
                return nil
            }

            let metadata = await VideoMetadataExtractor.extract(from: movie.url)
            return SelectedVideo(
                fileURL: movie.url,
                fileName: cameraFilename ?? movie.url.lastPathComponent,
                metadata: metadata,
                phAssetIdentifier: item.itemIdentifier
            )
        } catch {
            AppLog.ui.error("[Library] Failed to load video: \(error.localizedDescription)")
            return nil
        }
    }

    private func cleanUpLoadedVideos() {
        let tempDir = FileManager.default.temporaryDirectory.path
        let urlsToDelete =
            selectedVideos
            .map(\.fileURL)
            .filter { $0.path.hasPrefix(tempDir) }

        for url in urlsToDelete {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: url)
            }
        }

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
            options.isNetworkAccessAllowed = false
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

        let capturedAt = phAsset.creationDate.map {
            DVUDateFormatting.isoString(from: $0)
        }

        let gpsLat = phAsset.location?.coordinate.latitude
        let gpsLon = phAsset.location?.coordinate.longitude
        let gpsAltitude = phAsset.location?.altitude

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
