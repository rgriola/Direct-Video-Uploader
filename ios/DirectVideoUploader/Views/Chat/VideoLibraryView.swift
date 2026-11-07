import AVFoundation
import CoreMedia
import Photos
import PhotosUI
// May 10, 2026 - 12:59pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI
import UIKit

/// A library video ready to stage for upload.
struct PickedVideo {
    let fileURL: URL
    let fileName: String
    let metadata: VideoMetadata
    /// Photos identifier of the uploaded file. Nil for trimmed copies, which don't exist in Photos yet.
    let phAssetIdentifier: String?
    let isTrimmed: Bool
}

/// Custom video library sheet with inline PhotosPicker — iOS 26.3 style.
/// Provides Clear / Confirm toolbar buttons and a footer with selection count + location info.
/// With Photo Library access, the camera original is copied byte-for-byte (including from iCloud);
/// without it, the picker's current version is used and a notice explains that Photos edits may be included.
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
    @State private var downloadProgress: Double?
    @State private var usedPickerCopy = false
    @State private var loadedAssetIdentifier: String?
    @State private var loadTask: Task<Void, Never>?
    /// Identifies the current load so a superseded one can't touch shared state.
    @State private var activeLoadID: UUID?

    /// Called when user finishes trimming (or keeps the full length) a selected video.
    var onConfirm: (PickedVideo) -> Void
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
                    matching: .videos,
                    preferredItemEncoding: .current,
                    photoLibrary: .shared()
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
                        pendingConfirm = false
                        selectedItems.removeAll()
                        cleanUpLoadedVideo()
                    }
                    .foregroundStyle(selectedItems.isEmpty ? .gray : .white)
                    .disabled(selectedItems.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        cleanUpLoadedVideo()
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.gray)
                    .accessibilityLabel("Close")
                }
            }
            .onChange(of: selectedItems) { _, newItems in
                if newItems.isEmpty {
                    pendingConfirm = false
                    cleanUpLoadedVideo()
                } else {
                    handleSelectionChange(newItems)
                }
            }
        }
        .presentationDetents([.large])
        // Swipe-to-dismiss skips the X button; presenting the trim cover also fires this, so skip it then.
        .onDisappear {
            if !showTrimSheet { cleanUpLoadedVideo() }
        }
        .fullScreenCover(isPresented: $showTrimSheet) {
            if let url = loadedVideoURL {
                VideoTrimView(
                    videoURL: url,
                    originalFileName: loadedFileName ?? url.lastPathComponent,
                    onFinished: { outcome in
                        showTrimSheet = false
                        handleTrimResult(outcome)
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

                if usedPickerCopy, loadedVideoURL != nil, loadError == nil {
                    Label(
                        "Photos edits may be included. Allow Photo Library access in Settings to upload the original.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(Theme.font13Regular)
                    .foregroundStyle(Theme.yellow)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.yellow.opacity(0.15))
                    .accessibilityLabel(Self.pickerCopyWarning)
                }

                HStack(spacing: 12) {
                    // Video info
                    if isLoadingMetadata {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(Theme.secondaryText)
                                .scaleEffect(0.8)
                            Text(loadingText)
                                .font(Theme.font13Medium)
                                .foregroundStyle(Theme.secondaryText)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(downloadProgress == nil ? "Loading video" : "Downloading original")
                        .accessibilityValue(downloadProgress.map { "\(Int($0 * 100)) percent" } ?? "")
                        .accessibilityAddTraits(.updatesFrequently)
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
                    .accessibilityLabel("Trim and stage video")
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

    private static let pickerCopyWarning =
        "Warning: Photos edits may be included. Allow Photo Library access in Settings to upload the original."

    private var loadingText: String {
        guard let downloadProgress else { return "Loading video..." }
        return "Downloading original… \(Int(downloadProgress * 100))%"
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

    /// Hand off the original (full length) or the trimmed copy with the original's metadata.
    private func handleTrimResult(_ outcome: TrimOutcome) {
        guard let originalURL = loadedVideoURL, let originalMetadata = loadedMetadata else { return }
        let originalName = loadedFileName ?? originalURL.lastPathComponent

        switch outcome {
        case .fullLength:
            let picked = PickedVideo(
                fileURL: originalURL,
                fileName: originalName,
                metadata: originalMetadata,
                phAssetIdentifier: loadedAssetIdentifier,
                isTrimmed: false
            )
            releaseLoadedVideo()
            onConfirm(picked)

        case .trimmed(let trimmedURL):
            releaseLoadedVideo()
            deleteIfTemporary(originalURL)
            Task {
                let trimmedMetadata = await VideoMetadataExtractor.extract(from: trimmedURL)
                let picked = PickedVideo(
                    fileURL: trimmedURL,
                    fileName: trimmedURL.lastPathComponent,
                    metadata: originalMetadata.replacingDuration(trimmedMetadata.duration),
                    phAssetIdentifier: nil,
                    isTrimmed: true
                )
                onConfirm(picked)
            }
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

        let loadID = UUID()
        activeLoadID = loadID
        isLoadingMetadata = true
        loadTask = Task {
            defer {
                if activeLoadID == loadID {
                    isLoadingMetadata = false
                    downloadProgress = nil
                }
                if pendingConfirm && activeLoadID == loadID && !Task.isCancelled {
                    pendingConfirm = false
                    // Only auto-confirm if loading succeeded — prevents infinite retry loop on failure
                    if loadedVideoURL != nil {
                        handleConfirm()
                    }
                }
            }

            let status = await OriginalVideoLoader.requestReadWriteAccessIfNeeded()
            guard !Task.isCancelled else { return }

            if OriginalVideoLoader.canRead(status),
                let identifier = item.itemIdentifier,
                OriginalVideoLoader.duration(ofAssetWithIdentifier: identifier) != nil
            {
                await loadOriginal(identifier: identifier, loadID: loadID)
            } else {
                await loadPickerCopy(item)
            }
        }
    }

    /// Copies the untouched camera original out of Photos. Failures are reported rather than
    /// silently replaced with a possibly edited copy.
    private func loadOriginal(identifier: String, loadID: UUID) async {
        let (progressStream, progressContinuation) = AsyncStream.makeStream(
            of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let progressTask = Task {
            for await value in progressStream where activeLoadID == loadID {
                downloadProgress = value
            }
        }

        let result: Result<LoadedOriginalVideo, any Error>
        do {
            result = .success(
                try await withTaskCancellationHandler {
                    try await OriginalVideoLoader.loadOriginal(
                        localIdentifier: identifier,
                        progress: { progressContinuation.yield($0) }
                    )
                } onCancel: {
                    progressContinuation.finish()
                })
        } catch {
            result = .failure(error)
        }

        // Drain progress before publishing the result so a late value can't follow it.
        progressContinuation.finish()
        await progressTask.value

        do {
            let original = try result.get()
            guard !Task.isCancelled else {
                deleteIfTemporary(original.fileURL)
                return
            }
            loadedVideoURL = original.fileURL
            loadedFileName = original.fileName
            loadedMetadata = original.metadata
            loadedAssetIdentifier = identifier
            usedPickerCopy = false
        } catch {
            guard !Task.isCancelled else { return }
            Log.error("❌ [Library] Failed to load original: \(Log.describe(error))", logger: Log.media)
            loadError = "Couldn't load the original video: \(error.localizedDescription)"
        }
    }

    /// Without Photo Library access, use the picker's copy of the current version (no transcoding).
    private func loadPickerCopy(_ item: PhotosPickerItem) async {
        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                if !Task.isCancelled { loadError = "Could not load video from library" }
                return
            }
            guard !Task.isCancelled else {
                deleteIfTemporary(movie.url)
                return
            }
            let metadata = await VideoMetadataExtractor.extract(from: movie.url)
            guard !Task.isCancelled else {
                deleteIfTemporary(movie.url)
                return
            }
            loadedVideoURL = movie.url
            loadedFileName = movie.url.lastPathComponent
            loadedMetadata = metadata
            loadedAssetIdentifier = nil
            usedPickerCopy = true
            AccessibilityNotification.Announcement(Self.pickerCopyWarning).post()
        } catch {
            guard !Task.isCancelled else { return }
            Log.error("❌ [Library] Failed to load video: \(Log.describe(error))", logger: Log.media)
            loadError = "Failed to load video: \(error.localizedDescription)"
        }
    }

    /// Cancels loading and deletes the temporary copy.
    private func cleanUpLoadedVideo() {
        loadTask?.cancel()
        loadTask = nil
        activeLoadID = nil
        if let url = loadedVideoURL {
            deleteIfTemporary(url)
        }
        releaseLoadedVideo()
        isLoadingMetadata = false
        downloadProgress = nil
    }

    /// Forgets the loaded file without deleting it (ownership moved to the caller).
    private func releaseLoadedVideo() {
        loadedVideoURL = nil
        loadedFileName = nil
        loadedMetadata = nil
        loadedAssetIdentifier = nil
        usedPickerCopy = false
    }

    /// Deletes a file (and its per-load folder) only if it lives in our temporary directory.
    private func deleteIfTemporary(_ url: URL) {
        let tempDir = FileManager.default.temporaryDirectory.standardizedFileURL
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix(tempDir.path + "/") else { return }
        let parent = standardized.deletingLastPathComponent()
        let target = parent.path == tempDir.path ? standardized : parent
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: target)
        }
    }
}

// MARK: - Video Transferable

/// Loads a video file from PhotosPicker into a temporary location,
/// preserving the original filename from the system.
nonisolated struct VideoTransferable: Transferable {
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
