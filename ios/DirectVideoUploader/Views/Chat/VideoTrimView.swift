import AVFoundation
import AVKit
// May 10, 2026 - 12:59pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI
import UIKit

// MARK: - Public API (unchanged contract)

/// Result of the trim screen.
enum TrimOutcome {
    /// Nothing was cut; upload the original file as-is.
    case fullLength
    /// A passthrough copy of the selected range.
    case trimmed(URL)
}

/// Decides whether a trim selection actually removes footage.
nonisolated enum TrimRange {
    /// Selections within this distance of either end count as untouched (under two frames at 30 fps).
    static let fullLengthTolerance: Double = 0.05
    /// Shortest selection the handles allow.
    static let minimumDuration: Double = 1.0

    static func isFullLength(start: Double, end: Double, duration: Double) -> Bool {
        guard duration > 0 else { return true }
        return start <= fullLengthTolerance && end >= duration - fullLengthTolerance
    }

    /// VoiceOver swipe step for the trim handles and playhead, coarser for longer clips.
    static func accessibilityStep(duration: Double) -> Double {
        switch duration {
        case ..<60: 0.5
        case ..<300: 1
        default: 5
        }
    }

    static func nudgedStart(_ start: Double, end: Double, by delta: Double) -> Double {
        min(max(start + delta, 0), max(end - minimumDuration, 0))
    }

    static func nudgedEnd(_ end: Double, start: Double, duration: Double, by delta: Double) -> Double {
        max(min(end + delta, duration), min(start + minimumDuration, duration))
    }

    /// Spoken form of a time, e.g. "1 minute, 2.5 seconds".
    static func spokenTime(_ seconds: Double) -> String {
        let tenths = (max(seconds, 0) * 10).rounded() / 10
        let isWhole = tenths.truncatingRemainder(dividingBy: 1) == 0
        return Duration.milliseconds(Int64((tenths * 1000).rounded())).formatted(
            .units(
                allowed: [.minutes, .seconds], width: .wide,
                fractionalPart: isWhole ? .hide : .show(length: 1))
        )
    }
}

/// Lossless video trim UI using AVFoundation passthrough export.
/// Shows a filmstrip scrubber, draggable trim handles, and an inline player preview.
/// The trimmed output has identical quality to the original — no re-encoding.
/// When the full length is kept, no copy is made and the original is uploaded.
struct VideoTrimView: View {
    let videoURL: URL
    let originalFileName: String
    let sourceLeases: TrimSourceLeases
    var onFinished: (TrimOutcome) -> Void
    var onCancel: () -> Void
    var onTeardown: () -> Void

    @State private var vm = TrimViewModel()
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportError: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportID: UUID?
    @State private var isPresented = false

    var body: some View {
        ZStack {
            Theme.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Toolbar
                trimToolbar
                    .padding(.top, 50)

                Spacer(minLength: 12)

                // Video preview — tap to toggle play/pause
                ZStack {
                    PlayerView(player: vm.player)
                        .aspectRatio(vm.videoAspect, contentMode: .fit)
                        .clipped()

                    // Play/pause toggle overlay — visible when paused
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(Theme.display44)
                        .foregroundStyle(Theme.white.opacity(vm.isPlaying ? 0 : 0.7))
                        .animation(.easeInOut(duration: 0.2), value: vm.isPlaying)
                }
                .onTapGesture { vm.togglePlayPause() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(vm.isPlaying ? "Pause video" : "Play video")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { vm.togglePlayPause() }
                .padding(.horizontal, 4)

                Spacer(minLength: 12)

                // Time labels
                timeLabels
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                // Filmstrip + trim handles
                TrimScrubberView(vm: vm)
                    .frame(height: 60)
                    // Room for the outer half of the 44 pt handle hit areas at the screen edges.
                    .padding(.horizontal, 28)
                    .padding(.bottom, 74)
            }

            // Export overlay
            if isExporting {
                exportOverlay
            }
        }
        .onAppear {
            guard !isPresented else { return }
            isPresented = true
            sourceLeases.acquire(videoURL)
            sourceLeases.acquire(videoURL)
            vm.load(url: videoURL) { sourceLeases.release(videoURL) }
        }
        .onDisappear {
            guard isPresented else { return }
            isPresented = false
            exportID = nil
            exportTask?.cancel()
            exportTask = nil
            vm.cleanup()
            onTeardown()
            sourceLeases.release(videoURL)
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Toolbar

    private var trimToolbar: some View {
        HStack {
            Button {
                vm.pause()
                onCancel()
            } label: {
                Text("Cancel").tapTarget()
            }
            .foregroundStyle(Theme.white)

            Spacer()

            Text("Trim Video")
                .font(Theme.font16Semibold)
                .foregroundStyle(Theme.white)

            Spacer()

            Button {
                handleExport()
            } label: {
                Text("Next >>").tapTarget()
            }
            .foregroundStyle(Theme.yellow)
            .fontWeight(.semibold)
            .disabled(isExporting)
            .accessibilityLabel("Next")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(Theme.black)
    }

    // MARK: - Time labels

    private var timeLabels: some View {
        HStack {
            Text(formatTime(vm.trimStart))
                .font(Theme.mono13Medium)
                .foregroundStyle(Theme.yellow)

            Spacer()

            let trimDuration = vm.trimEnd - vm.trimStart
            Text(formatTime(trimDuration))
                .font(Theme.font13Medium)
                .foregroundStyle(Theme.white.opacity(0.7))

            Spacer()

            Text(formatTime(vm.trimEnd))
                .font(Theme.mono13Medium)
                .foregroundStyle(Theme.yellow)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Selected length")
        .accessibilityValue(TrimRange.spokenTime(vm.trimEnd - vm.trimStart))
    }

    // MARK: - Export overlay

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: exportProgress)
                    .progressViewStyle(.linear)
                    .tint(Theme.yellow)
                    .frame(width: 180)
                Text("Exporting… \(Int(exportProgress * 100))%")
                    .font(Theme.font16Medium)
                    .foregroundStyle(Theme.white)
            }
            .padding(Theme.space32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusLg))
        }
    }

    // MARK: - Export

    private func handleExport() {
        vm.pause()
        if TrimRange.isFullLength(start: vm.trimStart, end: vm.trimEnd, duration: vm.duration) {
            onFinished(.fullLength)
            return
        }
        isExporting = true
        exportProgress = 0
        let id = UUID()
        exportID = id
        sourceLeases.acquire(videoURL)

        exportTask = Task {
            defer {
                sourceLeases.release(videoURL)
                if exportID == id {
                    exportID = nil
                    exportTask = nil
                }
            }
            do {
                let outputURL = try await PassthroughExporter.export(
                    source: videoURL,
                    originalFileName: originalFileName,
                    startTime: vm.trimStart,
                    endTime: vm.trimEnd,
                    onProgress: { progress in
                        Task { @MainActor in
                            if exportID == id { exportProgress = progress }
                        }
                    }
                )
                guard !Task.isCancelled, exportID == id else {
                    removeTemporaryVideoItem(outputURL.deletingLastPathComponent())
                    return
                }
                isExporting = false
                onFinished(.trimmed(outputURL))
            } catch {
                guard !Task.isCancelled, exportID == id else { return }
                isExporting = false
                exportError = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", mins, secs, frac)
    }
}

// MARK: - TrimViewModel

/// Manages player state, thumbnail generation, and trim range.
@MainActor
@Observable
final class TrimViewModel {
    var duration: Double = 0
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var currentTime: Double = 0
    var thumbnails: [UIImage] = []
    var videoAspect: CGFloat = 16.0 / 9.0
    var isPlaying: Bool = true

    let player = AVPlayer()
    private var asset: AVURLAsset?
    private var timeObserver: Any?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    // Keep blocking session calls off-main and ordered across presentation/dismissal.
    nonisolated private static let audioSessionQueue = DispatchQueue(
        label: "com.directvideo.uploader.trim-audio",
        qos: .userInitiated
    )

    static let thumbnailCount = 12
    static let minimumTrimDuration = TrimRange.minimumDuration

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    func load(url: URL, onFinished: @escaping @MainActor () -> Void = {}) {
        loadTask?.cancel()
        let asset = AVURLAsset(url: url)
        self.asset = asset

        loadTask = Task { @MainActor in
            defer { onFinished() }
            guard !Task.isCancelled else { return }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Self.audioSessionQueue.async {
                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.playback)
                        try session.setActive(true)
                    } catch {
                        Log.error("Trim audio activation failed: \(Log.describe(error))", logger: Log.media)
                    }
                    continuation.resume()
                }
            }
            guard !Task.isCancelled else { return }

            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)

            // Load duration
            let cmDur = try? await asset.load(.duration)
            guard !Task.isCancelled else { return }
            if let cmDur {
                let dur = CMTimeGetSeconds(cmDur)
                duration = dur
                trimEnd = dur
            }

            // Load aspect ratio from video track
            if let tracks = try? await asset.loadTracks(withMediaType: .video),
                let track = tracks.first,
                let size = try? await track.load(.naturalSize),
                let transform = try? await track.load(.preferredTransform)
            {
                guard !Task.isCancelled else { return }
                let transformed = size.applying(transform)
                let w = abs(transformed.width)
                let h = abs(transformed.height)
                if h > 0 { videoAspect = w / h }
            }

            // Generate thumbnails
            guard !Task.isCancelled else { return }
            await generateThumbnails(asset: asset)
            guard !Task.isCancelled else { return }

            // Set up looping observer (but don't auto-play)
            setupLooping()
            // Default to paused — user taps play when ready
            player.pause()
            isPlaying = false
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func cleanup() {
        loadTask?.cancel()
        loadTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        asset = nil
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
        Self.audioSessionQueue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Log.error("Trim audio deactivation failed: \(Log.describe(error))", logger: Log.media)
            }
        }
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func fireHaptic() {
        haptic.impactOccurred()
    }

    func seekToTrimStart() {
        let time = CMTime(seconds: trimStart, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekToTrimEnd() {
        let time = CMTime(seconds: trimEnd, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekTo(_ seconds: Double) {
        let clamped = Swift.min(Swift.max(seconds, trimStart), trimEnd)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Thumbnails

    private func generateThumbnails(asset: AVURLAsset) async {
        guard duration > 0 else { return }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 120)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let count = Self.thumbnailCount
        var images: [UIImage] = []

        for i in 0..<count {
            guard !Task.isCancelled else { return }
            let fraction = Double(i) / Double(count)
            let time = CMTime(seconds: fraction * duration, preferredTimescale: 600)
            do {
                let (cgImage, _) = try await generator.image(at: time)
                images.append(UIImage(cgImage: cgImage))
            } catch {
                // Use a black placeholder on failure
                images.append(UIImage())
            }
        }

        guard !Task.isCancelled else { return }
        thumbnails = images
    }

    // MARK: - Looping

    private func setupLooping() {
        // Periodic time observer — clamp playback to trim range
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let t = CMTimeGetSeconds(time)
            Task { @MainActor in
                self.currentTime = t
                // Loop back to start of trim range when reaching the end
                if t >= self.trimEnd {
                    let start = CMTime(seconds: self.trimStart, preferredTimescale: 600)
                    self.player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }

}

// MARK: - PlayerView (AVPlayerLayer wrapper)

private struct PlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView { PlayerUIView(player: player) }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {}

    class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        init(player: AVPlayer) {
            super.init(frame: .zero)
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            backgroundColor = .black
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}

// MARK: - TrimScrubberView (filmstrip + handles)

private struct TrimScrubberView: View {
    var vm: TrimViewModel

    /// Which handle the user is currently dragging (if any).
    @State private var activeDrag: DragHandle?
    @State private var dragOrigin: Double = 0
    private enum DragHandle { case start, end }

    private let handleWidth: CGFloat = 18
    private let handleHitWidth: CGFloat = 44
    private let cornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let usableW = totalW - handleWidth * 2  // space between handles
            let pxPerSec = vm.duration > 0 ? usableW / vm.duration : 0
            let minTrim = TrimViewModel.minimumTrimDuration

            let leftX = handleWidth + vm.trimStart * pxPerSec
            let rightX = handleWidth + vm.trimEnd * pxPerSec

            ZStack(alignment: .leading) {
                // Filmstrip background — tap to seek
                filmstrip(width: totalW, height: geo.size.height)
                    .onTapGesture { location in
                        let tappedTime = (location.x - handleWidth) / pxPerSec
                        vm.seekTo(tappedTime)
                    }
                    .accessibilityHidden(true)

                // Dimmed regions outside trim
                dimRegion(
                    centerX: (leftX - handleWidth) / 2,
                    width: max(leftX - handleWidth, 0),
                    height: geo.size.height)
                dimRegion(
                    centerX: (rightX + handleWidth + totalW) / 2,
                    width: max(totalW - rightX - handleWidth, 0),
                    height: geo.size.height)

                // Trim border (top + bottom yellow lines)
                trimBorder(
                    leftX: leftX - handleWidth, rightX: rightX + handleWidth,
                    height: geo.size.height)

                // Playhead hit target sits below the handles so a handle wins where they meet.
                if vm.duration > 0 {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: handleHitWidth, height: geo.size.height + 8)
                        .contentShape(Rectangle())
                        .accessibilityElement()
                        .accessibilityLabel("Playhead")
                        .accessibilityValue(TrimRange.spokenTime(vm.currentTime))
                        .accessibilityAdjustableAction { adjust(.playhead, $0) }
                        .accessibilitySortPriority(2)
                        .position(x: playX(pxPerSec), y: geo.size.height / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    if vm.isPlaying { vm.pause() }
                                    let newTime = clamp(
                                        (val.location.x - handleWidth) / pxPerSec,
                                        min: vm.trimStart, max: vm.trimEnd)
                                    vm.currentTime = newTime
                                    vm.seekTo(newTime)
                                }
                        )
                }

                // Handle hit areas extend outward from the selection, so they never overlap.
                trimHandle(edge: .leading)
                    .frame(width: handleHitWidth, height: geo.size.height, alignment: .trailing)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Trim start")
                    .accessibilityValue(TrimRange.spokenTime(vm.trimStart))
                    .accessibilityAdjustableAction { adjust(.start, $0) }
                    .accessibilitySortPriority(3)
                    .position(x: leftX - handleHitWidth / 2, y: geo.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                if activeDrag == nil {
                                    vm.fireHaptic()
                                    dragOrigin = vm.trimStart
                                }
                                activeDrag = .start
                                // Relative to the touch-down point, so grabbing the wide hit area doesn't jump the handle.
                                let newStart = clamp(
                                    dragOrigin + val.translation.width / pxPerSec, min: 0,
                                    max: vm.trimEnd - minTrim)
                                vm.trimStart = newStart
                                vm.seekToTrimStart()
                            }
                            .onEnded { _ in
                                vm.fireHaptic()
                                activeDrag = nil
                                vm.player.play()
                                vm.isPlaying = true
                            }
                    )

                trimHandle(edge: .trailing)
                    .frame(width: handleHitWidth, height: geo.size.height, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Trim end")
                    .accessibilityValue(TrimRange.spokenTime(vm.trimEnd))
                    .accessibilityAdjustableAction { adjust(.end, $0) }
                    .accessibilitySortPriority(1)
                    .position(x: rightX + handleHitWidth / 2, y: geo.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                if activeDrag == nil {
                                    vm.fireHaptic()
                                    dragOrigin = vm.trimEnd
                                }
                                activeDrag = .end
                                let newEnd = clamp(
                                    dragOrigin + val.translation.width / pxPerSec,
                                    min: vm.trimStart + minTrim, max: vm.duration)
                                vm.trimEnd = newEnd
                                vm.seekToTrimEnd()
                            }
                            .onEnded { _ in
                                vm.fireHaptic()
                                activeDrag = nil
                                vm.player.play()
                                vm.isPlaying = true
                            }
                    )

                // Visible playhead line, drawn above the handles
                if vm.duration > 0 {
                    Rectangle()
                        .fill(Theme.white)
                        .frame(width: 2, height: geo.size.height + 8)
                        .position(x: playX(pxPerSec), y: geo.size.height / 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func playX(_ pxPerSec: Double) -> CGFloat {
        handleWidth + vm.currentTime * pxPerSec
    }

    private enum AdjustTarget { case start, end, playhead }

    /// VoiceOver swipe up/down on a handle or the playhead. Keeps playback paused so audio doesn't talk over speech.
    private func adjust(_ target: AdjustTarget, _ direction: AccessibilityAdjustmentDirection) {
        let step = TrimRange.accessibilityStep(duration: vm.duration)
        let delta: Double
        switch direction {
        case .increment: delta = step
        case .decrement: delta = -step
        @unknown default: return
        }
        vm.pause()
        switch target {
        case .start:
            vm.trimStart = TrimRange.nudgedStart(vm.trimStart, end: vm.trimEnd, by: delta)
            vm.seekToTrimStart()
        case .end:
            vm.trimEnd = TrimRange.nudgedEnd(
                vm.trimEnd, start: vm.trimStart, duration: vm.duration, by: delta)
            vm.seekToTrimEnd()
        case .playhead:
            let newTime = clamp(vm.currentTime + delta, min: vm.trimStart, max: vm.trimEnd)
            vm.currentTime = newTime
            vm.seekTo(newTime)
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func filmstrip(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            if vm.thumbnails.isEmpty {
                // Placeholder while loading
                ForEach(0..<TrimViewModel.thumbnailCount, id: \.self) { _ in
                    Theme.cardBg
                        .frame(width: width / CGFloat(TrimViewModel.thumbnailCount), height: height)
                }
            } else {
                ForEach(Array(vm.thumbnails.enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width / CGFloat(vm.thumbnails.count), height: height)
                        .clipped()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    private func dimRegion(centerX: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        if width > 0 {
            Rectangle()
                .fill(Theme.black.opacity(0.6))
                .frame(width: width, height: height)
                .position(x: centerX, y: height / 2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func trimBorder(leftX: CGFloat, rightX: CGFloat, height: CGFloat) -> some View {
        let w = rightX - leftX
        if w > 0 {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.yellow).frame(height: 3)
                Spacer()
                Rectangle().fill(Theme.yellow).frame(height: 3)
            }
            .frame(width: w, height: height)
            .position(x: leftX + w / 2, y: height / 2)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func trimHandle(edge: HorizontalEdge) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.yellow)
            .frame(width: handleWidth, height: 60)
            .overlay {
                // Chevron arrows
                Image(
                    systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right"
                )
                .font(Theme.font16Bold)
                .foregroundStyle(Theme.black)
            }
    }

    // MARK: - Helpers

    private func clamp(_ value: Double, min lo: Double, max hi: Double) -> Double {
        Swift.min(Swift.max(value, lo), hi)
    }
}

// MARK: - PassthroughExporter

/// Exports a trimmed video using AVAssetExportPresetPassthrough — zero re-encoding.
/// The output is a byte-for-byte copy of the original bitstream within the trim range.
nonisolated enum PassthroughExporter {

    enum ExportError: LocalizedError {
        case noCompatibleFileType
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noCompatibleFileType:
                return "No compatible output file type for passthrough export."
            case .exportFailed(let msg): return msg
            case .cancelled: return "Export was cancelled."
            }
        }
    }

    @concurrent static func export(
        source: URL,
        originalFileName: String,
        startTime: Double,
        endTime: Double,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)

        guard
            let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetPassthrough)
        else {
            throw ExportError.noCompatibleFileType
        }

        // Determine output file type — prefer QuickTime for .mov, MP4 otherwise
        let ext = (originalFileName as NSString).pathExtension.lowercased()
        let fileType: AVFileType
        if ext == "mp4" || ext == "m4v" {
            // Check if MP4 is supported; fall back to QuickTime
            if session.supportedFileTypes.contains(.mp4) {
                fileType = .mp4
            } else {
                fileType = .mov
            }
        } else {
            fileType = .mov
        }
        // Carry the original's capture date, location and camera details into the copy.
        if let sourceMetadata = try? await asset.load(.metadata), !sourceMetadata.isEmpty {
            session.metadata = sourceMetadata
        }
        try Task.checkCancellation()

        // Build trimmed output filename
        let name = (originalFileName as NSString).deletingPathExtension
        let outExt = fileType == .mp4 ? "mp4" : "mov"
        let editedName = "\(name)-edited.\(outExt)"
        // A unique folder per export, so re-trimming can't replace a copy that's still uploading.
        let destFolder = try TemporaryVideoStorage.makeDirectory()
        let destURL = destFolder.appendingPathComponent(editedName)

        // Set trim range
        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let end = CMTime(seconds: endTime, preferredTimescale: 600)
        session.timeRange = CMTimeRange(start: start, end: end)

        let states = session.states(updateInterval: 0.1)
        let progressTask = Task {
            for await state in states {
                if case .exporting(let progress) = state {
                    onProgress?(progress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        do {
            try await session.export(to: destURL, as: fileType)
            try Task.checkCancellation()
            try TemporaryVideoStorage.applyProtection(to: destURL)
        } catch is CancellationError {
            removeTemporaryVideoItem(destFolder)
            throw ExportError.cancelled
        } catch {
            removeTemporaryVideoItem(destFolder)
            if Task.isCancelled { throw ExportError.cancelled }
            throw ExportError.exportFailed(error.localizedDescription)
        }
        onProgress?(1.0)
        return destURL
    }
}
