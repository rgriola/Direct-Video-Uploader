import SwiftUI
import AVFoundation

/// A staged video ready for the user to preview before uploading.
struct StagedVideo {
    let tempFileURL: URL
    let fileName: String
    let createdDate: String?      // formatted display string
    let thumbnail: UIImage?
    let metadata: VideoMetadata
}

/// Chat bubble showing a video preview with thumbnail, filename, date — plus send / cancel buttons.
/// Appears in the message list after the user picks a video from the library.
struct VideoPreviewBubble: View {
    let stagedVideo: StagedVideo
    var onSend: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            VStack(alignment: .trailing, spacing: 4) {
                // Bubble content
                VStack(alignment: .leading, spacing: 0) {
                    // Thumbnail
                    if let thumb = stagedVideo.thumbnail {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: 160)
                                .clipped()

                            // Cancel "X" button overlay
                            Button {
                                onCancel()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(Theme.iconXLFont)
                                    .foregroundStyle(.white, .black.opacity(0.5))
                                    .shadow(radius: 3)
                            }
                            .padding(8)
                        }
                    }

                    // File info + send button
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            // Filename
                            Text(stagedVideo.fileName)
                                .font(Theme.monoSmallFont)
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            // Created date
                            if let date = stagedVideo.createdDate {
                                Text(date)
                                    .font(Theme.timestampFont)
                                    .foregroundStyle(.white.opacity(0.6))
                            }

                            // Location badge
                            if stagedVideo.metadata.gpsLat != nil {
                                HStack(spacing: 4) {
                                    Image(systemName: "location.fill")
                                        .font(Theme.locationIconFont)
                                    Text("Location included")
                                        .font(Theme.locationFont)
                                }
                                .foregroundStyle(Theme.green)
                            }
                        }

                        Spacer()

                        // Send button 
                        Button {
                            onSend()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(Theme.iconLargeFont)
                                .foregroundStyle(Theme.blue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .background( /// background for videopreview bubble.
                    LinearGradient(
                        colors: [Theme.videoBubbleHi, Theme.videoBubbleLo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Theme.blue.opacity(0.3), lineWidth: 1)
                )

                // Label
                Text("Tap ↑ to upload")
                    .font(Theme.timestampFont)
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 2)
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
