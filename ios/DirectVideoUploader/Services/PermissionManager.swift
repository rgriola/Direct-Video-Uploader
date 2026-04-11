import Photos
import Speech
import UIKit

/// Manages iOS permission states for Photo Library and Speech Recognition.
/// Reads current OS permission status and provides methods to trigger
/// the one-time system prompt or redirect to Settings.app.
@MainActor
@Observable
final class PermissionManager {

    // MARK: - Observable State

    var photoLibraryStatus: PHAuthorizationStatus = .notDetermined
    var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    init() {
        refreshStatuses()
    }

    // MARK: - Status Reading

    /// Re-read current permission states from the OS.
    /// Call on init and whenever the app returns to foreground (user may
    /// have changed permissions in Settings.app while away).
    func refreshStatuses() {
        photoLibraryStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
    }

    // MARK: - Photo Library

    /// Request Photo Library access. If already denied, opens Settings.
    func requestPhotoLibrary() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch current {
        case .notDetermined:
            // First time — iOS will show the system dialog
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            photoLibraryStatus = newStatus
        default:
            // Already granted, denied, or restricted — open Settings to change
            openAppSettings()
        }
    }

    // MARK: - Speech Recognition

    /// Request Speech Recognition permission. If already denied, opens Settings.
    func requestSpeechRecognition() async {
        let current = SFSpeechRecognizer.authorizationStatus()

        switch current {
        case .notDetermined:
            // First time — iOS will show the system dialog.
            //
            // IMPORTANT: SFSpeechRecognizer.requestAuthorization delivers its
            // callback on an arbitrary background thread — NOT the main thread.
            // Capturing only the raw status value (an enum, fully Sendable)
            // inside the continuation is safe.  We then assign it back here on
            // the MainActor after the continuation resumes, avoiding the
            // thread-safety violation that caused the crash when the user tapped
            // "Don't Allow" on the system permission dialog.
            let newStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    // status is a plain enum value — safe to capture & resume from
                    // any thread.
                    continuation.resume(returning: status)
                }
            }
            // Back on @MainActor — safe to write @Observable state.
            speechStatus = newStatus
        default:
            // Already granted, denied, or restricted — open Settings to change.
            openAppSettings()
        }
    }

    // MARK: - Settings

    /// Open this app's page in Settings.app.
    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Helpers

    /// Human-readable label for photo library status.
    var photoLibraryLabel: String {
        switch photoLibraryStatus {
        case .authorized:       return "Full Access"
        case .limited:          return "Limited"
        case .denied:           return "Denied"
        case .restricted:       return "Restricted"
        case .notDetermined:    return "Not Set"
        @unknown default:       return "Unknown"
        }
    }

    /// Human-readable label for speech recognition status.
    var speechLabel: String {
        switch speechStatus {
        case .authorized:       return "Granted"
        case .denied:           return "Denied"
        case .restricted:       return "Restricted"
        case .notDetermined:    return "Not Set"
        @unknown default:       return "Unknown"
        }
    }

    /// Whether photo library is in any granted state.
    var isPhotoLibraryGranted: Bool {
        photoLibraryStatus == .authorized || photoLibraryStatus == .limited
    }

    /// Whether speech recognition is granted.
    var isSpeechGranted: Bool {
        speechStatus == .authorized
    }
}
