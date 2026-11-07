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

private struct PendingTrimResult {
    let sourceURL: URL
    let outcome: TrimOutcome
}

enum VideoLibraryAutoConfirm: Equatable {
    case wait
    case stop
    case reviewPickerCopy
    case openTrim

    static func decision(
        isPending: Bool, isLoading: Bool, isReady: Bool,
        usedPickerCopy: Bool, canPresent: Bool
    ) -> Self {
        guard isPending else { return .stop }
        if isLoading { return .wait }
        guard isReady else { return .stop }
        if usedPickerCopy { return .reviewPickerCopy }
        return canPresent ? .openTrim : .wait
    }
}

/// Reads the shared presentation state at the time an async load completes.
@MainActor
struct VideoLibraryPresentationGate {
    let presentationState: FormPresentationState

    func canPresent(
        showPhotoAlert: Bool, showTrimSheet: Bool, hasPendingTrimResult: Bool
    ) -> Bool {
        presentationState.canPresentChatForm && !showPhotoAlert
            && !showTrimSheet && !hasPendingTrimResult
    }
}

@MainActor
@Observable
final class TrimSourceLeases {
    private var readers: [URL: Int] = [:]
    @ObservationIgnored private var pendingRemoval: Set<URL> = []
    @ObservationIgnored private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private let remove: (URL) -> Void

    init(remove: @escaping (URL) -> Void = { url in
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        let file = url.standardizedFileURL
        guard file.path.hasPrefix(temporaryDirectory.path + "/") else { return }
        let parent = file.deletingLastPathComponent()
        let target = parent.path == temporaryDirectory.path ? file : parent
        Task.detached(priority: .utility) { removeTemporaryVideoItem(target) }
    }) {
        self.remove = remove
    }

    func acquire(_ url: URL) {
        readers[url, default: 0] += 1
    }

    func release(_ url: URL) {
        guard let count = readers[url], count > 0 else {
            Log.error("Trim source lease released without a reader", logger: Log.media)
            return
        }
        if count > 1 {
            readers[url] = count - 1
            return
        }
        readers.removeValue(forKey: url)
        if pendingRemoval.remove(url) != nil { remove(url) }
        let continuations = waiters.removeValue(forKey: url) ?? []
        continuations.forEach { $0.resume() }
    }

    func hasReaders(_ url: URL) -> Bool {
        readers[url, default: 0] > 0
    }

    func isWaitingUntilUnused(_ url: URL) -> Bool {
        !(waiters[url]?.isEmpty ?? true)
    }

    func removeWhenUnused(_ url: URL) {
        if hasReaders(url) {
            pendingRemoval.insert(url)
        } else {
            remove(url)
        }
    }

    func waitUntilUnused(_ url: URL) async {
        guard hasReaders(url) else { return }
        await withCheckedContinuation { continuation in
            waiters[url, default: []].append(continuation)
        }
    }
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
    @State private var pendingPickerCopyWarning = false
    @State private var pendingLoadErrorAnnouncement: String?
    @State private var pendingConfirmFocus = false
    @AccessibilityFocusState private var confirmIsFocused: Bool
    @State private var loadedAssetIdentifier: String?
    @State private var loadTask: Task<Void, Never>?
    /// Identifies the current load so a superseded one can't touch shared state.
    @State private var activeLoadID: UUID?
    @State private var activeTrimID: UUID?
    @State private var pendingTrimResult: PendingTrimResult?
    @State private var trimHandoffID: UUID?
    @State private var trimHandoffTask: Task<Void, Never>?
    @State private var trimSourceLeases = TrimSourceLeases()

    let presentationState: FormPresentationState
    /// Called when user finishes trimming (or keeps the full length) a selected video.
    var onConfirm: (PickedVideo) -> Bool
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
                        cancelTrimHandoff()
                        selectedItems.removeAll()
                        cleanUpLoadedVideo()
                    }
                    .foregroundStyle(selectedItems.isEmpty ? .gray : .white)
                    .disabled(selectedItems.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        cancelTrimHandoff()
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
                    cancelTrimHandoff()
                    cleanUpLoadedVideo()
                } else {
                    handleSelectionChange(newItems)
                }
            }
        }
        .presentationDetents([.large])
        .onChange(of: presentationState.generation) { _, _ in resumeLibraryPresentation() }
        .onChange(of: showPhotoAlert) { _, _ in resumeLibraryPresentation() }
        .onChange(of: isFinishingTrim) { _, _ in resumeLibraryPresentation() }
        .onChange(of: loadError) { _, error in
            pendingLoadErrorAnnouncement = error
            announceLibraryNoticesIfPossible()
        }
        // Swipe-to-dismiss skips the X button; presenting the trim cover also fires this, so skip it then.
        .onDisappear {
            if !showTrimSheet {
                activeTrimID = nil
                cancelTrimHandoff()
                cleanUpLoadedVideo()
            }
        }
        .fullScreenCover(isPresented: $showTrimSheet, onDismiss: finishTrimDismissal) {
            if let url = loadedVideoURL, let trimID = activeTrimID {
                VideoTrimView(
                    videoURL: url,
                    originalFileName: loadedFileName ?? url.lastPathComponent,
                    sourceLeases: trimSourceLeases,
                    onFinished: { outcome in
                        guard activeTrimID == trimID, loadedVideoURL == url else {
                            if case .trimmed(let trimmedURL) = outcome {
                                deleteIfTemporary(trimmedURL)
                            }
                            return
                        }
                        activeTrimID = nil
                        pendingTrimResult = PendingTrimResult(sourceURL: url, outcome: outcome)
                        showTrimSheet = false
                    },
                    onCancel: {
                        guard activeTrimID == trimID else { return }
                        activeTrimID = nil
                        showTrimSheet = false
                    },
                    onTeardown: {
                        guard activeTrimID == trimID else { return }
                        activeTrimID = nil
                        showTrimSheet = false
                        cancelTrimHandoff()
                        cleanUpLoadedVideo()
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
                        .font(.footnote)
                        .foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
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
                    .font(.footnote)
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
                    } else if isFinishingTrim {
                        Label("Finishing previous trim...", systemImage: "hourglass")
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
                                .frame(width: 80, height: 44)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(Theme.display32)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                    Theme.white,
                                    isVideoReady ? Theme.purple : Theme.purple.opacity(0.4)
                                )
                                .tapTarget()
                        }
                    }
                    .disabled((isLoadingMetadata && !pendingConfirm) || isFinishingTrim)
                    .accessibilityLabel(loadError == nil ? "Trim and stage video" : "Retry loading video")
                    .accessibilityHint(loadError == nil ? "" : "Tries to load the selected video again.")
                    .accessibilityFocused($confirmIsFocused)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.black)
        }
    }

    // MARK: - Computed Properties

    private var isVideoReady: Bool {
        loadedVideoURL != nil && loadedMetadata != nil && !isFinishingTrim
    }

    private var isFinishingTrim: Bool {
        trimHandoffID != nil || (loadedVideoURL.map { trimSourceLeases.hasReaders($0) } ?? false)
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
            cancelTrimHandoff()
            onDismiss()
        } else if isVideoReady {
            guard canPresentTrim else {
                pendingConfirm = true
                return
            }
            activeTrimID = UUID()
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
            cancelTrimHandoff()
            let handoffID = UUID()
            trimHandoffID = handoffID
            trimHandoffTask = Task {
                await trimSourceLeases.waitUntilUnused(originalURL)
                guard !Task.isCancelled, trimHandoffID == handoffID else {
                    deleteIfTemporary(originalURL)
                    return
                }
                trimHandoffID = nil
                trimHandoffTask = nil
                if !onConfirm(picked) { deleteIfTemporary(picked.fileURL) }
            }

        case .trimmed(let trimmedURL):
            releaseLoadedVideo()
            deleteIfTemporary(originalURL)
            cancelTrimHandoff()
            let handoffID = UUID()
            trimHandoffID = handoffID
            trimHandoffTask = Task {
                let trimmedMetadata = await VideoMetadataExtractor.extract(from: trimmedURL)
                guard !Task.isCancelled, trimHandoffID == handoffID else {
                    deleteIfTemporary(trimmedURL)
                    return
                }
                trimHandoffID = nil
                trimHandoffTask = nil
                let picked = PickedVideo(
                    fileURL: trimmedURL,
                    fileName: trimmedURL.lastPathComponent,
                    metadata: originalMetadata.replacingDuration(trimmedMetadata.duration),
                    phAssetIdentifier: nil,
                    isTrimmed: true
                )
                if !onConfirm(picked) { deleteIfTemporary(picked.fileURL) }
            }
        }
    }

    private func handleSelectionChange(_ newItems: [PhotosPickerItem]) {
        cancelTrimHandoff()
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
                    finishPendingConfirmationIfPossible()
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
            pendingPickerCopyWarning = true
            announceLibraryNoticesIfPossible()
        } catch {
            guard !Task.isCancelled else { return }
            Log.error("❌ [Library] Failed to load video: \(Log.describe(error))", logger: Log.media)
            loadError = "Failed to load video: \(error.localizedDescription)"
        }
    }

    /// Cancels loading and deletes the temporary copy.
    private func cancelTrimHandoff() {
        if let pendingTrimResult {
            if case .trimmed(let url) = pendingTrimResult.outcome { deleteIfTemporary(url) }
            self.pendingTrimResult = nil
        }
        trimHandoffID = nil
        trimHandoffTask?.cancel()
        trimHandoffTask = nil
    }

    private func finishTrimDismissal() {
        guard let result = pendingTrimResult else {
            pendingConfirmFocus = loadedVideoURL != nil
            resumeLibraryPresentation()
            return
        }
        pendingTrimResult = nil
        guard loadedVideoURL == result.sourceURL else {
            if case .trimmed(let url) = result.outcome { deleteIfTemporary(url) }
            return
        }
        handleTrimResult(result.outcome)
    }

    private func cleanUpLoadedVideo() {
        loadTask?.cancel()
        loadTask = nil
        activeLoadID = nil
        pendingPickerCopyWarning = false
        pendingLoadErrorAnnouncement = nil
        pendingConfirmFocus = false
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
        trimSourceLeases.removeWhenUnused(url)
    }

    private var canPresentTrim: Bool {
        VideoLibraryPresentationGate(presentationState: presentationState).canPresent(
            showPhotoAlert: showPhotoAlert, showTrimSheet: showTrimSheet,
            hasPendingTrimResult: pendingTrimResult != nil)
    }

    private func resumeLibraryPresentation() {
        announceLibraryNoticesIfPossible()
        finishPendingConfirmationIfPossible()
        if pendingConfirmFocus && canPresentTrim && isVideoReady {
            pendingConfirmFocus = false
            confirmIsFocused = true
        }
    }

    private func finishPendingConfirmationIfPossible() {
        switch VideoLibraryAutoConfirm.decision(
            isPending: pendingConfirm, isLoading: isLoadingMetadata, isReady: isVideoReady,
            usedPickerCopy: usedPickerCopy, canPresent: canPresentTrim
        ) {
        case .wait:
            return
        case .stop:
            pendingConfirm = false
        case .reviewPickerCopy:
            pendingConfirm = false
            announceLibraryNoticesIfPossible()
        case .openTrim:
            pendingConfirm = false
            handleConfirm()
        }
    }

    private func announceLibraryNoticesIfPossible() {
        guard canPresentTrim else { return }
        var notices: [String] = []
        if pendingPickerCopyWarning { notices.append(Self.pickerCopyWarning) }
        if let pendingLoadErrorAnnouncement { notices.append(pendingLoadErrorAnnouncement) }
        pendingPickerCopyWarning = false
        pendingLoadErrorAnnouncement = nil
        if !notices.isEmpty {
            AccessibilityNotification.Announcement(notices.joined(separator: " ")).post()
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
            let subdir = try TemporaryVideoStorage.makeDirectory()
            let tempURL = subdir.appendingPathComponent(originalName)
            do {
                try await TemporaryVideoStorage.copy(from: received.file, to: tempURL)
                return Self(url: tempURL)
            } catch {
                removeTemporaryVideoItem(subdir)
                throw error
            }
        }
    }
}
