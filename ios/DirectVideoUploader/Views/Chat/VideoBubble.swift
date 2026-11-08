import SwiftUI
import AVFoundation

/// Phase of a video bubble in the chat timeline.
enum VideoBubblePhase {
    case staged      // Preview — show cancel X, transcribe toggle, send button
    case uploading   // Progress bar + spinner
    case processing  // Bytes uploaded, Mux is processing — spinner + text
    case sent        // Green ✓ (mux:ready received)
    case failed      // Upload failed or was cancelled

    static func resolve(isUploading: Bool, hasFailed: Bool, isReady: Bool) -> Self {
        if isUploading { return .uploading }
        if hasFailed { return .failed }
        return isReady ? .sent : .processing
    }
}

/// A staged video ready for the user to preview before uploading.
struct StagedVideo {
    let id = UUID()
    let tempFileURL: URL
    let fileName: String
    let createdDate: String?      // formatted display string
    let thumbnail: UIImage?
    let metadata: VideoMetadata
    let phAssetIdentifier: String?
    var isTrimmed: Bool = false
    var isSavedToPhotos = false
    var savedPhotoIdentifier: String?
    var acceptedManualPhotoSelection = false
    var fingerprint: VideoContentFingerprint?
}

enum StagedUploadPreparation: Equatable {
    case ready
    case requestingPhotoAccess
    case savingPhoto
    case verifyingPhoto
    case creatingAsset
    case manualPhotoSelectionRequired
    case manualFingerprintSelectionRequired
    case photoAccessDenied
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .requestingPhotoAccess, .savingPhoto, .verifyingPhoto, .creatingAsset: true
        default: false
        }
    }

    var blocksAttachment: Bool {
        switch self {
        case .requestingPhotoAccess, .savingPhoto, .verifyingPhoto: true
        default: false
        }
    }

    var message: String? {
        switch self {
        case .ready: nil
        case .requestingPhotoAccess: "Checking Photo Library access."
        case .savingPhoto:
            "Saving the trim to Photos. If you cancel now, a copy may still appear in Photos."
        case .verifyingPhoto: "Checking the video for Archive recovery."
        case .creatingAsset: "Starting the upload."
        case .manualPhotoSelectionRequired:
            "The trim was saved to Photos, but its photo link wasn't returned. Choose the correct video manually for Archive retries."
        case .manualFingerprintSelectionRequired:
            "The video couldn't be checked for a saved photo link. Retry the check, or continue and choose the correct video manually for Archive retries."
        case .photoAccessDenied:
            "Photo Library access is required to save this trim. Allow access in Settings, then retry."
        case .failed(let message): message
        }
    }

    var requiresManualConfirmation: Bool {
        self == .manualPhotoSelectionRequired || self == .manualFingerprintSelectionRequired
    }
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
    var onContinueWithoutPhotoIdentifier: ((_ transcribe: Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var preparation: StagedUploadPreparation = .ready
    var willSaveTrim = false
    var savedTrim = false

    // Uploading-only
    var uploadProgress: Double = 0

    // Whether transcription was enabled for this upload (non-staged phases)
    var didTranscribe: Bool = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var transcribeEnabled = false

    var body: some View {
        HStack {
            Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 0 : 60)

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
                                removeButton
                            }
                        }
                    } else if phase == .staged {
                        HStack {
                            Spacer()
                            removeButton
                        }
                    }

                    // This essential disclosure must precede Upload, including with hints disabled.
                    if phase == .staged && willSaveTrim {
                        Text("Uploading saves this trim to Photos first. The copy may include location and sync through iCloud Photos.")
                            .font(.footnote)
                            .foregroundStyle(Theme.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                    }

                    // File info + trailing action
                    fileHeader
                    .padding(.leading, 12)
                    .padding(.trailing, 6)
                    .padding(.vertical, 10)

                    if phase == .staged,
                       preparation.message != nil || savedTrim {
                        VStack(alignment: .leading, spacing: 8) {
                            if let message = preparation.message {
                                HStack(alignment: .top, spacing: 8) {
                                    if preparation.isBusy {
                                        ProgressView()
                                            .tint(Theme.white)
                                    }
                                    Text(message)
                                        .font(.footnote)
                                        .foregroundStyle(Theme.white)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if savedTrim {
                                Text("The saved trim stays in Photos if you remove this preview.")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if preparation == .photoAccessDenied {
                                Button("Open Settings") { onOpenSettings?() }
                                    .buttonStyle(.bordered)
                                    .tint(Theme.white)
                            }
                            if preparation.requiresManualConfirmation {
                                Button("Continue with manual Archive recovery") {
                                    onContinueWithoutPhotoIdentifier?(transcribeEnabled)
                                }
                                .buttonStyle(.bordered)
                                .tint(Theme.white)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }

                    // Upload progress bar — uploading phase only
                    if phase == .uploading {
                        VStack(spacing: 4) {
                            ProgressView(value: uploadProgress)
                                .tint(Theme.blue)
                            HStack {
                                Text("Uploading video…")
                                    .font(.caption)
                                    .foregroundStyle(Theme.white)
                                Spacer()
                                Text("\(Int(uploadProgress * 100))%")
                                    .font(.caption.monospacedDigit())
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
                                .font(.caption)
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
    private var fileHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                fileInformation
                HStack {
                    Spacer()
                    trailingItems
                }
            }
        } else {
            HStack(spacing: 10) {
                fileInformation
                Spacer()
                trailingItems
            }
        }
    }

    private var fileInformation: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fileName)
                .font(.subheadline.monospaced().weight(.medium))
                .foregroundStyle(Theme.white)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            if let date = createdDate {
                Text(date)
                    .font(.caption)
                    .foregroundStyle(Theme.white)
            }
            if hasLocation {
                Label("GPS", systemImage: "location.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.green)
            }
        }
    }

    @ViewBuilder
    private var trailingItems: some View {
        if phase != .staged && didTranscribe {
            Image(systemName: "mic.fill")
                .font(Theme.icon13)
                .foregroundStyle(Theme.black)
                .padding(6)
                .background(Theme.green)
                .clipShape(Circle())
        }
        trailingWidget
    }

    private var removeButton: some View {
        Button {
            onCancel?()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(Theme.display24)
                .foregroundStyle(Theme.white, Theme.black.opacity(0.5))
                .shadow(radius: 3)
                .padding(8)
                .tapTarget(alignment: .topTrailing)
        }
        .accessibilityLabel("Remove video")
        .accessibilityHint(
            preparation == .savingPhoto
                ? "A copy may still appear in Photos."
                : (savedTrim ? "The saved trim will remain in Photos." : ""))
        .disabled(preparation == .creatingAsset)
    }

    @ViewBuilder
    private var trailingWidget: some View {
        switch phase {
        case .staged:
            HStack(spacing: 0) {
                // Transcribe toggle — icon only, scoped to this staged preview
                Button {
                    transcribeEnabled.toggle()
                } label: {
                    Image(systemName: transcribeEnabled ? "mic.fill" : "mic.slash")
                        .font(Theme.icon13)
                        .foregroundStyle(transcribeEnabled ? Theme.black : Theme.secondaryText)
                        .padding(8)
                        .background(transcribeEnabled ? Theme.green : Theme.white)
                        .clipShape(Circle())
                        .tapTarget()
                }
                .accessibilityLabel("Transcribe")
                .accessibilityValue(transcribeEnabled ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
                .disabled(preparation.isBusy)

                // Send button
                Button {
                    onSend?(transcribeEnabled)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(Theme.display32)
                        .foregroundStyle(Theme.white)
                        .tapTarget()
                }
                .accessibilityLabel(
                    isRetryingUpload ? "Retry video upload" : "Upload video")
                .accessibilityHint(willSaveTrim
                    ? "Saves this trim to Photos first. The copy may include location and sync through iCloud Photos."
                    : "")
                .disabled(preparation.isBusy || preparation == .manualPhotoSelectionRequired)
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

        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.display24)
                .foregroundStyle(Theme.white)
                .accessibilityHidden(true)
        }
    }

    private var isRetryingUpload: Bool {
        if case .failed = preparation { return true }
        return preparation == .photoAccessDenied
            || preparation == .manualFingerprintSelectionRequired
    }

    private var borderColor: Color {
        switch phase {
        case .sent: Theme.green
        case .processing: Theme.purple
        case .failed: Theme.red
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
                    .font(.caption)
            }
            .foregroundStyle(Theme.white.opacity(0.3))
            .padding(.horizontal, 4)

        case .uploading:
            Text("Uploading…")
                .font(.caption)
                .foregroundStyle(Theme.white)
                .padding(.horizontal, 4)

        case .processing:
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(Theme.font11Regular)
                Text("Processing…")
                    .font(.caption)
            }
            .foregroundStyle(Theme.purple)
            .padding(.horizontal, 4)

        case .sent:
            Text("Sent")
                .font(.caption)
                .foregroundStyle(Theme.white)
                .padding(.horizontal, 4)

        case .failed:
            Text("Upload failed. Retry in Archive.")
                .font(.caption.weight(.semibold))
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
