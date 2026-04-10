import SwiftUI
import AVFoundation

/// Phase of a video bubble in the chat timeline.
enum VideoBubblePhase {
    case staged      // Preview — show cancel X, transcribe toggle, send button
    case uploading   // Progress bar + spinner
    case sent        // Green ✓
}

/// A staged video ready for the user to preview before uploading.
struct StagedVideo {
    let tempFileURL: URL
    let fileName: String
    let createdDate: String?      // formatted display string
    let thumbnail: UIImage?
    let metadata: VideoMetadata
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
                                        .font(Theme.iconXLFont)
                                        .foregroundStyle(.white, .black.opacity(0.5))
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
                                .font(Theme.monoSmallFont)
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            // Created date
                            if let date = createdDate {
                                Text(date)
                                    .font(Theme.timestampFont)
                                    .foregroundStyle(Theme.white)
                            }

                            // Location badge
                            if hasLocation {
                                HStack(spacing: 4) {
                                    Image(systemName: "location.fill")
                                        .font(Theme.locationIconFont)
                                    Text("GPS")
                                        .font(Theme.locationFont)
                                }
                                .foregroundStyle(Theme.green)
                            }
                        }

                        Spacer()

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
                                    .font(Theme.timestampFont)
                                    .foregroundStyle(Theme.white)
                                Spacer()
                                Text("\(Int(uploadProgress * 100))%")
                                    .font(Theme.timestampFont.monospacedDigit())
                                    .foregroundStyle(Theme.white)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                }
                .background(Theme.videoBubbleGradient)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
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
            // Transcribe toggle
            Button {
                transcribeEnabled.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: transcribeEnabled ? "mic.fill" : "mic.slash")
                        .font(Theme.iconFont)
                    Text("Transcribe")
                        .font(Theme.captionFont)
                }
                .foregroundStyle(transcribeEnabled ? Color.black : Color.gray)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(transcribeEnabled ? Theme.green : Color.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(transcribeEnabled ? Theme.green.opacity(0.8) : Color.white.opacity(0.9), lineWidth: 1))

            }

            // Send button
            Button {
                onSend?(transcribeEnabled)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.iconLargeFont)
                    .foregroundStyle(Theme.white)
            }

        case .uploading:
            ProgressView()
                .tint(Theme.white)

        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.iconLargeFont)
                .foregroundStyle(Theme.green)
        }
    }

    private var borderColor: Color {
        phase == .sent ? Theme.green : Theme.blue
    }

    @ViewBuilder
    private var bottomLabel: some View {
        switch phase {
        case .staged:
            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .font(Theme.timestampFont)
                Text("Upload")
                    .font(Theme.timestampFont)
            }
            .foregroundStyle(.white.opacity(0.3))
            .padding(.horizontal, 4)

        case .uploading:
            Text("Uploading…")
                .font(Theme.timestampFont)
                .foregroundStyle(Theme.white)
                .padding(.horizontal, 4)

        case .sent:
            Text("Sent")
                .font(Theme.timestampFont)
                .foregroundStyle(Theme.white)
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - Thumbnail Generation

extension StagedVideo {
    /// Generate a thumbnail from a video file URL.
    static func generateThumbnail(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)

        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage)
        } catch {
            print("❌ [Thumbnail] Failed to generate: \(error)")
            return nil
        }
    }
}
