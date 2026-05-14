// May 13, 2026 - 7:27pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation
import UIKit

/// Metadata for a sent-upload card, cached by message ID.
struct SentUploadInfo {
    let thumbnail: UIImage?
    let fileName: String
    let createdDate: String
    let hasLocation: Bool
    let transcribeEnabled: Bool
}

/// Per-clip state for batch upload cards rendered in the chat timeline.
struct BatchClipDisplayState {
    var phase: VideoBubblePhase
    var progress: Double
    var mediasourceId: String?
    var mediasourceUrl: String?
    var formSlug: String?
    var errorText: String?
}

/// Metadata cached after mux:ready for Slack sharing and summary bubble.
struct ArchiveState {
    var assetId: String?
    var mediasourceId: String?
    var mediasourceUrl: String?
    var originalFileName: String?
    var formSlug: String?
    var duration: Int?
    var resolution: String?
    var fileSize: String?
}

/// Context passed to ContextFormView header.
struct FormContext {
    var originalFileName: String?
    var capturedAt: String?
    var clipCount: Int?
    var duration: Int?
    var thumbnail: UIImage?
    var submitError: String?
}
