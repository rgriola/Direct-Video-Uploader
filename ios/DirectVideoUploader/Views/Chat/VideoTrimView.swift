import SwiftUI
import AVFoundation
import AVKit
import UIKit

// MARK: - Public API (unchanged contract)

/// Lossless video trim UI using AVFoundation passthrough export.
/// Shows a filmstrip scrubber, draggable trim handles, and an inline player preview.
/// The trimmed output has identical quality to the original — no re-encoding.
struct VideoTrimView: View {
    let videoURL: URL
    let originalFileName: String
    var onTrimmed: (URL) -> Void
    var onCancel: () -> Void

    @StateObject private var vm = TrimViewModel()
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Toolbar
                trimToolbar
                    .padding(.top, 50)

                Spacer().frame(height: 200)

                // Video preview
                PlayerView(player: vm.player)
                    .aspectRatio(vm.videoAspect, contentMode: .fit)
                    .clipped()
                    .padding(.horizontal, 4)

                Spacer(minLength: 12)

                // Time labels
                timeLabels
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                // Filmstrip + trim handles
                TrimScrubberView(vm: vm)
                    .frame(height: 60)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 74)
            }

            // Export overlay
            if isExporting {
                exportOverlay
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { vm.load(url: videoURL) }
        .onDisappear { vm.pause() }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Toolbar

    private var trimToolbar: some View {
        HStack {
            Button("Cancel") {
                vm.pause()
                onCancel()
            }
            .foregroundStyle(.white)

            Spacer()

            Text("Trim Video")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            Button("Choose") {
                handleExport()
            }
            .foregroundStyle(Theme.yellow)
            .fontWeight(.semibold)
            .disabled(isExporting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.darkBg)
    }

    // MARK: - Time labels

    private var timeLabels: some View {
        HStack {
            Text(formatTime(vm.trimStart))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.yellow)

            Spacer()

            let trimDuration = vm.trimEnd - vm.trimStart
            Text(formatTime(trimDuration))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Text(formatTime(vm.trimEnd))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.yellow)
        }
    }

    // MARK: - Export overlay

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(.white)
                Text("Exporting…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Export

    private func handleExport() {
        vm.pause()
        isExporting = true

        Task {
            do {
                let outputURL = try await PassthroughExporter.export(
                    source: videoURL,
                    originalFileName: originalFileName,
                    startTime: vm.trimStart,
                    endTime: vm.trimEnd
                )
                await MainActor.run {
                    isExporting = false
                    onTrimmed(outputURL)
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
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
final class TrimViewModel: ObservableObject {
    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var currentTime: Double = 0
    @Published var thumbnails: [UIImage] = []
    @Published var videoAspect: CGFloat = 16.0 / 9.0

    let player = AVPlayer()
    private var asset: AVURLAsset?
    private nonisolated(unsafe) var timeObserver: Any?

    static let thumbnailCount = 12

    func load(url: URL) {
        let asset = AVURLAsset(url: url)
        self.asset = asset

        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        Task {
            // Load duration
            if let cmDur = try? await asset.load(.duration) {
                let dur = CMTimeGetSeconds(cmDur)
                duration = dur
                trimEnd = dur
            }

            // Load aspect ratio from video track
            if let tracks = try? await asset.loadTracks(withMediaType: .video),
               let track = tracks.first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let transformed = size.applying(transform)
                let w = abs(transformed.width)
                let h = abs(transformed.height)
                if h > 0 { videoAspect = w / h }
            }

            // Generate thumbnails
            await generateThumbnails(asset: asset)

            // Start playback and looping
            setupLooping()
            player.play()
        }
    }

    func pause() {
        player.pause()
    }

    func seekToTrimStart() {
        let time = CMTime(seconds: trimStart, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekToTrimEnd() {
        let time = CMTime(seconds: trimEnd, preferredTimescale: 600)
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

    deinit {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
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
    @ObservedObject var vm: TrimViewModel

    /// Which handle the user is currently dragging (if any).
    @State private var activeDrag: DragHandle?
    private enum DragHandle { case start, end }

    private let handleWidth: CGFloat = 18
    private let cornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let usableW = totalW - handleWidth * 2  // space between handles
            let pxPerSec = vm.duration > 0 ? usableW / vm.duration : 0

            let leftX = handleWidth + vm.trimStart * pxPerSec
            let rightX = handleWidth + vm.trimEnd * pxPerSec

            ZStack(alignment: .leading) {
                // Filmstrip background
                filmstrip(width: totalW, height: geo.size.height)

                // Dimmed regions outside trim
                dimRegion(x: 0, width: leftX - handleWidth, height: geo.size.height)
                dimRegion(x: rightX + handleWidth, width: totalW - rightX - handleWidth, height: geo.size.height)

                // Trim border (top + bottom yellow lines)
                trimBorder(leftX: leftX - handleWidth, rightX: rightX + handleWidth, height: geo.size.height)

                // Left handle
                trimHandle(edge: .leading)
                    .position(x: leftX - handleWidth / 2, y: geo.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                activeDrag = .start
                                let newStart = clamp((val.location.x - handleWidth / 2) / pxPerSec, min: 0, max: vm.trimEnd - 0.5)
                                vm.trimStart = newStart
                                vm.seekToTrimStart()
                            }
                            .onEnded { _ in
                                activeDrag = nil
                                vm.player.play()
                            }
                    )

                // Right handle
                trimHandle(edge: .trailing)
                    .position(x: rightX + handleWidth / 2, y: geo.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                activeDrag = .end
                                let newEnd = clamp((val.location.x - handleWidth / 2) / pxPerSec, min: vm.trimStart + 0.5, max: vm.duration)
                                vm.trimEnd = newEnd
                                vm.seekToTrimEnd()
                            }
                            .onEnded { _ in
                                activeDrag = nil
                                vm.player.play()
                            }
                    )

                // Playhead indicator
                if vm.duration > 0 {
                    let playX = handleWidth + vm.currentTime * pxPerSec
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2, height: geo.size.height + 8)
                        .position(x: playX, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func filmstrip(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            if vm.thumbnails.isEmpty {
                // Placeholder while loading
                ForEach(0..<TrimViewModel.thumbnailCount, id: \.self) { _ in
                    Color(hex: "2C2C2E")
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
    private func dimRegion(x: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        if width > 0 {
            Rectangle()
                .fill(Color.black.opacity(0.6))
                .frame(width: max(width, 0), height: height)
                .offset(x: x)
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
            .offset(x: leftX)
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
                Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
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
enum PassthroughExporter {

    enum ExportError: LocalizedError {
        case noCompatibleFileType
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noCompatibleFileType: return "No compatible output file type for passthrough export."
            case .exportFailed(let msg): return msg
            case .cancelled: return "Export was cancelled."
            }
        }
    }

    static func export(
        source: URL,
        originalFileName: String,
        startTime: Double,
        endTime: Double
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
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
        session.outputFileType = fileType

        // Build trimmed output filename
        let name = (originalFileName as NSString).deletingPathExtension
        let outExt = fileType == .mp4 ? "mp4" : "mov"
        let editedName = "\(name)-edited.\(outExt)"
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(editedName)
        try? FileManager.default.removeItem(at: destURL)

        session.outputURL = destURL

        // Set trim range
        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let end = CMTime(seconds: endTime, preferredTimescale: 600)
        session.timeRange = CMTimeRange(start: start, end: end)

        // Export
        await session.export()

        switch session.status {
        case .completed:
            return destURL
        case .cancelled:
            throw ExportError.cancelled
        default:
            throw ExportError.exportFailed(session.error?.localizedDescription ?? "Unknown export error")
        }
    }
}
