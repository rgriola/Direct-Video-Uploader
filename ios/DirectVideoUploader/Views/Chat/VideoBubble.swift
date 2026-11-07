import SwiftUI
import AVFoundation

/// Phase of a video bubble in the chat timeline.
enum VideoBubblePhase {
    case staged      // Preview — show cancel X, transcribe toggle, send button
    case uploading   // Progress bar + spinner
    case processing  // Bytes uploaded, Mux is processing — spinner + text
    case sent        // Green ✓ (mux:ready received)
}

/// A staged video ready for the user to preview before uploading.
struct StagedVideo {
    let tempFileURL: URL
    let fileName: String
    let createdDate: String?      // formatted display string
    let thumbnail: UIImage?
    let metadata: VideoMetadata
    /// A trimmed copy that isn't in Photos yet; saved there after a successful upload.
    var isTrimmed: Bool = false
}

/// Unified video bubble — handles staged preview, uploading progress, and sent confirmation
/// through a single phase-driven layout.
struct VideoBubble: View {
    let phase: VideoBubblePhase
    let thumbnail: UIImage?
    let fileName: String
    let createdDate: String?
    let hasLocation: Bool

    // Staged-only callbacks
    var onSend: ((_ transcribe: Bool) -> Void)?
    var onCancel: (() -> Void)?

    // Uploading-only
    var uploadProgress: Double = 0

    // Whether transcription was enabled for this upload (non-staged phases)
    var didTranscribe: Bool = false

    @State private var transcribeEnabled = false

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            VStack(alignment: .trailing, spacing: 4) {
                // Bubble content
                VStack(alignment: .leading, spacing: 0) {
                    // Thumbnail
                    if let thumb = thumbnail {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: 160)
                                .clipped()

                            // Cancel X — staged only
                            if phase == .staged {
                                Button {
                                    onCancel?()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(Theme.display24)
                                        .foregroundStyle(Theme.white, Theme.black.opacity(0.5))
                                        .shadow(radius: 3)
                                }
                                .padding(8)
                            }
                        }
                    }

                    // File info + trailing action
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            // Filename
                            Text(fileName)
                                .font(Theme.mono13Medium)
                                .foregroundStyle(Theme.white)
                                .lineLimit(1)

                            // Created date
                            if let date = createdDate {
                                Text(date)
                                    .font(Theme.font11Regular)
                                    .foregroundStyle(Theme.white)
                            }

                            // Location badge
                            if hasLocation {
                                HStack(spacing: 4) {
                                    Image(systemName: "location.fill")
                                        .font(Theme.icon11)
                                    Text("GPS")
                                        .font(Theme.font11Regular)
                                }
                                .foregroundStyle(Theme.green)
                            }
                        }

                        Spacer()

                        // Transcribe indicator for non-staged phases
                        if phase != .staged && didTranscribe {
                            Image(systemName: "mic.fill")
                                .font(Theme.icon13)
                                .foregroundStyle(Theme.black)
                                .padding(6)
                                .background(Theme.green)
                                .clipShape(Circle())
                        }

                        // Trailing widget — changes per phase
                        trailingWidget
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    // Upload progress bar — uploading phase only
                    if phase == .uploading {
                        VStack(spacing: 4) {
                            ProgressView(value: uploadProgress)
                                .tint(Theme.blue)
                            HStack {
                                Text("Uploading video…")
                                    .font(Theme.font11Regular)
                                    .foregroundStyle(Theme.white)
                                Spacer()
                                Text("\(Int(uploadProgress * 100))%")
                                    .font(Theme.font11Regular.monospacedDigit())
                                    .foregroundStyle(Theme.white)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }

                    // Processing indicator — Mux is transcoding
                    if phase == .processing {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(Theme.icon13)
                                .foregroundStyle(Theme.purple)
                                .phaseAnimator([false, true]) { content, pulse in
                                    content.opacity(pulse ? 1.0 : 0.4)
                                } animation: { _ in .easeInOut(duration: 0.8) }
                            Text("Mediasource processing…")
                                .font(Theme.font11Regular)
                                .foregroundStyle(Theme.white.opacity(0.8))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                }
                .background(Theme.videoBubbleGradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXl))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusXl)
                        .stroke(borderColor.opacity(0.3), lineWidth: 1)
                )

                // Bottom label
                bottomLabel
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Phase-Dependent Elements

    @ViewBuilder
    private var trailingWidget: some View {
        switch phase {
        case .staged:
            // Transcribe toggle — icon only, persists via @AppStorage
            Button {
                transcribeEnabled.toggle()
            } label: {
                Image(systemName: transcribeEnabled ? "mic.fill" : "mic.slash")
                    .font(Theme.icon13)
                    .foregroundStyle(transcribeEnabled ? Theme.black : Theme.secondaryText)
                    .padding(8)
                    .background(transcribeEnabled ? Theme.green : Theme.white)
                    .clipShape(Circle())
            }

            // Send button
            Button {
                onSend?(transcribeEnabled)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.display32)
                    .foregroundStyle(Theme.white)
            }

        case .uploading:
            ProgressView()
                .tint(Theme.white)

        case .processing:
            Image(systemName: "waveform")
                .font(Theme.display24)
                .foregroundStyle(Theme.purple)
                .phaseAnimator([false, true]) { content, pulse in
                    content
                        .opacity(pulse ? 1.0 : 0.3)
                        .scaleEffect(pulse ? 1.0 : 0.85)
                } animation: { _ in .easeInOut(duration: 0.8) }

        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.display32)
                .foregroundStyle(Theme.green)
        }
    }

    private var borderColor: Color {
        switch phase {
        case .sent: Theme.green
        case .processing: Theme.purple
        default: Theme.blue
        }
    }

    @ViewBuilder
    private var bottomLabel: some View {
        switch phase {
        case .staged:
            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .font(Theme.font11Regular)
                Text("Upload")
                    .font(Theme.font11Regular)
            }
            .foregroundStyle(Theme.white.opacity(0.3))
            .padding(.horizontal, 4)

        case .uploading:
            Text("Uploading…")
                .font(Theme.font11Regular)
                .foregroundStyle(Theme.white)
                .padding(.horizontal, 4)

        case .processing:
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(Theme.font11Regular)
                Text("Processing…")
                    .font(Theme.font11Regular)
            }
            .foregroundStyle(Theme.purple)
            .padding(.horizontal, 4)

        case .sent:
            Text("Sent")
                .font(Theme.font11Regular)
                .foregroundStyle(Theme.white)
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - Thumbnail Generation

extension StagedVideo {
    /// Generate a thumbnail from a video file URL.
    @concurrent nonisolated static func generateThumbnail(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)

        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage)
        } catch {
            Log.error("❌ [Thumbnail] Failed to generate: \(Log.describe(error))", logger: Log.media)
            return nil
        }
    }
}
