import SwiftUI
import UIKit

/// Wraps `UIVideoEditorController` so the user can optionally trim a video before upload.
/// If the device/video doesn't support editing, the skip callback fires automatically.
struct VideoTrimView: UIViewControllerRepresentable {
    let videoURL: URL
    /// Called with the trimmed (or original) file URL.
    var onTrimmed: (URL) -> Void
    /// Called when the user cancels — returns to the library.
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIVideoEditorController {
        let editor = UIVideoEditorController()
        editor.videoPath = videoURL.path
        editor.videoQuality = .typeHigh
        editor.delegate = context.coordinator
        return editor
    }

    func updateUIViewController(_ uiViewController: UIVideoEditorController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onTrimmed: onTrimmed, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIVideoEditorControllerDelegate, UINavigationControllerDelegate {
        let onTrimmed: (URL) -> Void
        let onCancel: () -> Void

        init(onTrimmed: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onTrimmed = onTrimmed
            self.onCancel = onCancel
        }

        func videoEditorController(_ editor: UIVideoEditorController, didSaveEditedVideoToPath editedVideoPath: String) {
            onTrimmed(URL(fileURLWithPath: editedVideoPath))
        }

        func videoEditorControllerDidCancel(_ editor: UIVideoEditorController) {
            onCancel()
        }

        func videoEditorController(_ editor: UIVideoEditorController, didFailWithError error: any Error) {
            print("❌ [Trim] Video editor failed: \(error.localizedDescription)")
            onCancel()
        }
    }
}
