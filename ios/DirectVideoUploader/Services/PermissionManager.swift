import Photos
import Speech
import UIKit

/// Reads and requests the system permissions the app uses. Injected so tests can supply fixed statuses.
nonisolated protocol PermissionAuthorizing: Sendable {
    func photoLibraryStatus() -> PHAuthorizationStatus
    func speechStatus() -> SFSpeechRecognizerAuthorizationStatus
    func requestPhotoLibrary() async -> PHAuthorizationStatus
    func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus
}

/// The real system authorization calls. Nonisolated: the Speech callback arrives on a
/// background queue and must not inherit main-actor isolation.
nonisolated struct SystemPermissionAuthorizer: PermissionAuthorizing {
    func photoLibraryStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func speechStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func requestPhotoLibrary() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }
}

/// Whether to show the onboarding Permissions screen.
nonisolated enum PermissionsPrompt {
    static let seenKey = "hasSeenPermissionsPrompt"

    /// Shown once, and only while at least one permission hasn't been decided.
    static func shouldPresent(
        hasSeen: Bool,
        photoLibrary: PHAuthorizationStatus,
        speech: SFSpeechRecognizerAuthorizationStatus
    ) -> Bool {
        !hasSeen && (photoLibrary == .notDetermined || speech == .notDetermined)
    }
}

/// Manages iOS permission states for Photo Library and Speech Recognition.
/// Reads current OS permission status and provides methods to trigger
/// the one-time system prompt or redirect to Settings.app.
@MainActor
@Observable
final class PermissionManager {

    // MARK: - Observable State

    var photoLibraryStatus: PHAuthorizationStatus = .notDetermined
    var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private let authorizer: any PermissionAuthorizing

    init(authorizer: any PermissionAuthorizing = SystemPermissionAuthorizer()) {
        self.authorizer = authorizer
        refreshStatuses()
    }

    // MARK: - Status Reading

    /// Re-read current permission states from the OS. Called whenever the app becomes
    /// active, since permissions can change in Settings or from prompts elsewhere in the app.
    func refreshStatuses() {
        photoLibraryStatus = authorizer.photoLibraryStatus()
        speechStatus = authorizer.speechStatus()
    }

    // MARK: - Photo Library

    /// Request Photo Library access. If already decided, opens Settings.
    func requestPhotoLibrary() async {
        guard authorizer.photoLibraryStatus() == .notDetermined else {
            openAppSettings()
            return
        }
        photoLibraryStatus = await authorizer.requestPhotoLibrary()
    }

    // MARK: - Speech Recognition

    /// Request Speech Recognition permission. If already decided, opens Settings.
    func requestSpeechRecognition() async {
        guard authorizer.speechStatus() == .notDetermined else {
            openAppSettings()
            return
        }
        speechStatus = await authorizer.requestSpeech()
    }

    /// Shows the system prompt for each permission that hasn't been decided, Photo Library first.
    func requestUndecidedPermissions() async {
        refreshStatuses()
        if photoLibraryStatus == .notDetermined {
            photoLibraryStatus = await authorizer.requestPhotoLibrary()
        }
        if speechStatus == .notDetermined {
            speechStatus = await authorizer.requestSpeech()
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

    /// Whether the person has to change this in Settings (denied or restricted).
    var isPhotoLibraryBlocked: Bool {
        photoLibraryStatus == .denied || photoLibraryStatus == .restricted
    }

    var isSpeechBlocked: Bool {
        speechStatus == .denied || speechStatus == .restricted
    }

    /// Whether speech recognition is granted.
    var isSpeechGranted: Bool {
        speechStatus == .authorized
    }
}
