import Photos
import Speech
import Synchronization
import Testing
@testable import DirectVideoUploader

/// Fixed-status authorizer that records which system prompts were requested.
final class FakePermissionAuthorizer: PermissionAuthorizing {
    struct State {
        var photo: PHAuthorizationStatus
        var speech: SFSpeechRecognizerAuthorizationStatus
        var photoAfterRequest: PHAuthorizationStatus
        var speechAfterRequest: SFSpeechRecognizerAuthorizationStatus
        var photoRequests = 0
        var speechRequests = 0
    }

    let state: Mutex<State>

    init(
        photo: PHAuthorizationStatus,
        speech: SFSpeechRecognizerAuthorizationStatus,
        photoAfterRequest: PHAuthorizationStatus = .authorized,
        speechAfterRequest: SFSpeechRecognizerAuthorizationStatus = .authorized
    ) {
        state = Mutex(State(
            photo: photo,
            speech: speech,
            photoAfterRequest: photoAfterRequest,
            speechAfterRequest: speechAfterRequest
        ))
    }

    var photoRequests: Int { state.withLock { $0.photoRequests } }
    var speechRequests: Int { state.withLock { $0.speechRequests } }

    func photoLibraryStatus() -> PHAuthorizationStatus { state.withLock { $0.photo } }
    func speechStatus() -> SFSpeechRecognizerAuthorizationStatus { state.withLock { $0.speech } }

    func requestPhotoLibrary() async -> PHAuthorizationStatus {
        state.withLock {
            $0.photoRequests += 1
            $0.photo = $0.photoAfterRequest
            return $0.photo
        }
    }

    func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        state.withLock {
            $0.speechRequests += 1
            $0.speech = $0.speechAfterRequest
            return $0.speech
        }
    }
}

@Suite("Permissions prompt rule")
struct PermissionsPromptTests {
    @Test("Shown when unseen and something is undecided")
    func showsWhenUndecided() {
        #expect(PermissionsPrompt.shouldPresent(hasSeen: false, photoLibrary: .notDetermined, speech: .authorized))
        #expect(PermissionsPrompt.shouldPresent(hasSeen: false, photoLibrary: .authorized, speech: .notDetermined))
    }

    @Test("Not shown once seen")
    func hiddenAfterSeen() {
        #expect(!PermissionsPrompt.shouldPresent(hasSeen: true, photoLibrary: .notDetermined, speech: .notDetermined))
    }

    @Test("Not shown when everything is decided")
    func hiddenWhenDecided() {
        #expect(!PermissionsPrompt.shouldPresent(hasSeen: false, photoLibrary: .limited, speech: .denied))
    }
}

@MainActor
@Suite("PermissionManager")
struct PermissionManagerTests {
    @Test("Reads statuses from the authorizer")
    func readsStatuses() {
        let manager = PermissionManager(authorizer: FakePermissionAuthorizer(photo: .limited, speech: .denied))
        #expect(manager.photoLibraryStatus == .limited)
        #expect(manager.speechStatus == .denied)
        #expect(manager.photoLibraryLabel == "Limited")
        #expect(manager.speechLabel == "Denied")
        #expect(manager.isPhotoLibraryGranted)
        #expect(!manager.isPhotoLibraryBlocked)
        #expect(manager.isSpeechBlocked)
        #expect(!manager.isSpeechGranted)
    }

    @Test("Row states map from statuses", arguments: [
        (PHAuthorizationStatus.authorized, PermissionRowState.granted),
        (.limited, .limited),
        (.denied, .blocked),
        (.restricted, .blocked),
        (.notDetermined, .undecided),
    ])
    func photoRowState(status: PHAuthorizationStatus, expected: PermissionRowState) {
        let manager = PermissionManager(authorizer: FakePermissionAuthorizer(photo: status, speech: .authorized))
        #expect(manager.photoLibraryRowState == expected)
    }

    @Test("Speech row states map from statuses", arguments: [
        (SFSpeechRecognizerAuthorizationStatus.authorized, PermissionRowState.granted),
        (.denied, .blocked),
        (.restricted, .blocked),
        (.notDetermined, .undecided),
    ])
    func speechRowState(status: SFSpeechRecognizerAuthorizationStatus, expected: PermissionRowState) {
        let manager = PermissionManager(authorizer: FakePermissionAuthorizer(photo: .authorized, speech: status))
        #expect(manager.speechRowState == expected)
    }

    @Test("Requests both prompts when both are undecided")
    func requestsBoth() async {
        let fake = FakePermissionAuthorizer(
            photo: .notDetermined,
            speech: .notDetermined,
            photoAfterRequest: .limited,
            speechAfterRequest: .denied
        )
        let manager = PermissionManager(authorizer: fake)
        await manager.requestUndecidedPermissions()
        #expect(fake.photoRequests == 1)
        #expect(fake.speechRequests == 1)
        #expect(manager.photoLibraryStatus == .limited)
        #expect(manager.speechStatus == .denied)
    }

    @Test("Skips prompts that were already decided")
    func skipsDecided() async {
        let fake = FakePermissionAuthorizer(photo: .authorized, speech: .notDetermined)
        let manager = PermissionManager(authorizer: fake)
        await manager.requestUndecidedPermissions()
        #expect(fake.photoRequests == 0)
        #expect(fake.speechRequests == 1)
        #expect(manager.speechStatus == .authorized)
    }

    @Test("Transcription authorization uses the authorizer")
    func transcriptionAuthorization() async {
        let undecided = FakePermissionAuthorizer(photo: .authorized, speech: .notDetermined)
        #expect(await TranscriptionService(authorizer: undecided).requestAuthorization())
        #expect(undecided.speechRequests == 1)

        let denied = FakePermissionAuthorizer(photo: .authorized, speech: .denied)
        #expect(await !TranscriptionService(authorizer: denied).requestAuthorization())
        #expect(denied.speechRequests == 0)
    }
}
