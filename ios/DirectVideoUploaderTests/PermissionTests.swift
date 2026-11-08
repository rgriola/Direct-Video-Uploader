import Foundation
import Photos
import Speech
import Synchronization
import Testing
@testable import DirectVideoUploader

/// Fixed-status authorizer that records which system prompts were requested.
nonisolated final class FakePermissionAuthorizer: PermissionAuthorizing {
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

@MainActor
@Suite("Picker presentation accessibility")
struct PickerPresentationAccessibilityTests {
    private func decisionAfterSuspension(
        gate: VideoLibraryPresentationGate, beforeResume: () -> Void
    ) async -> VideoLibraryAutoConfirm {
        let started = AsyncStream<Void>.makeStream()
        let signal = AsyncStream<Void>.makeStream()
        let decision = Task { @MainActor in
            started.continuation.yield(())
            started.continuation.finish()
            for await _ in signal.stream { break }
            return VideoLibraryAutoConfirm.decision(
                isPending: true, isLoading: false, isReady: true, usedPickerCopy: false,
                canPresent: gate.canPresent(
                    showPhotoAlert: false, showTrimSheet: false, hasPendingTrimResult: false))
        }
        for await _ in started.stream { break }
        beforeResume()
        signal.continuation.yield(())
        signal.continuation.finish()
        return await decision.value
    }

    @Test("An async library load checks the current root alert and scene")
    func libraryLoadChecksLiveAlertAndScene() async {
        let presentation = FormPresentationState()
        let gate = VideoLibraryPresentationGate(presentationState: presentation)
        let alertDecision = await decisionAfterSuspension(gate: gate) {
            presentation.pendingFormProtectionWarning = true
        }
        #expect(alertDecision == .wait)
        #expect(!gate.canPresent(
            showPhotoAlert: false, showTrimSheet: false, hasPendingTrimResult: false))
        presentation.pendingFormProtectionWarning = false

        let sceneDecision = await decisionAfterSuspension(gate: gate) {
            presentation.isSceneActive = false
        }
        #expect(sceneDecision == .wait)
        presentation.isSceneActive = true
        let canPresent = gate.canPresent(
            showPhotoAlert: false, showTrimSheet: false, hasPendingTrimResult: false)
        #expect(canPresent)
        #expect(VideoLibraryAutoConfirm.decision(
            isPending: true, isLoading: false, isReady: true,
            usedPickerCopy: false, canPresent: canPresent) == .openTrim)
        #expect(VideoLibraryAutoConfirm.decision(
            isPending: true, isLoading: false, isReady: true,
            usedPickerCopy: true, canPresent: canPresent) == .reviewPickerCopy)
    }

    @Test("Library presentation waits for an active, unobstructed Chat")
    func libraryGateChecksLiveSceneAndModals() {
        let presentation = FormPresentationState()
        let gate = VideoLibraryPresentationGate(presentationState: presentation)
        let canPresent = {
            gate.canPresent(
                showPhotoAlert: false, showTrimSheet: false, hasPendingTrimResult: false)
        }

        #expect(canPresent())
        presentation.isSceneActive = false
        #expect(!canPresent())
        presentation.isSceneActive = true
        presentation.selectedTab = .archive
        #expect(!canPresent())
        presentation.selectedTab = .chat
        presentation.archiveFormVisible = true
        #expect(!canPresent())
        presentation.archiveFormVisible = false
        #expect(!gate.canPresent(
            showPhotoAlert: true, showTrimSheet: false, hasPendingTrimResult: false))
        #expect(!gate.canPresent(
            showPhotoAlert: false, showTrimSheet: true, hasPendingTrimResult: false))
        #expect(!gate.canPresent(
            showPhotoAlert: false, showTrimSheet: false, hasPendingTrimResult: true))
        #expect(canPresent())
    }

    @Test("Presentation changes notify deferred picker work")
    func sharedPresentationChangesUpdateGeneration() {
        let presentation = FormPresentationState()
        var generation = presentation.generation
        presentation.isSceneActive = false
        #expect(presentation.generation != generation)
        generation = presentation.generation
        presentation.isSceneActive = true
        #expect(presentation.generation != generation)
        generation = presentation.generation
        presentation.pendingFormProtectionWarning = true
        #expect(presentation.generation != generation)
        generation = presentation.generation
        presentation.pendingFormProtectionWarning = false
        #expect(presentation.generation != generation)
        generation = presentation.generation
        presentation.selectedTab = .archive
        #expect(presentation.generation != generation)
        generation = presentation.generation
        presentation.archiveFormVisible = true
        #expect(presentation.generation != generation)
    }

    @Test("Archive confirmation focus waits and is consumed only once")
    func archivePickerFocusWaitsForLivePresentation() {
        let presentation = FormPresentationState()
        presentation.selectedTab = .archive
        let interaction = ArchiveInteractionState()
        interaction.sceneIsActive = true
        let modalID = UUID()
        #expect(interaction.beginRowModal(modalID, presentation: presentation))

        var focus = ArchivePickerConfirmationFocus()
        func tryFocus(hasSelection: Bool = true, isPresented: Bool = true) -> Bool {
            focus.consumeIfPossible(
                hasSelection: hasSelection, isPresented: isPresented,
                presentation: presentation, interaction: interaction, modalID: modalID)
        }
        focus.selectionChanged(hasSelection: true)
        presentation.pendingFormProtectionWarning = true
        #expect(!tryFocus())
        #expect(focus.isPending)

        presentation.pendingFormProtectionWarning = false
        presentation.isSceneActive = false
        #expect(!tryFocus())
        presentation.isSceneActive = true
        interaction.sceneIsActive = false
        #expect(!tryFocus())
        interaction.sceneIsActive = true
        presentation.selectedTab = .chat
        #expect(!tryFocus())
        presentation.selectedTab = .archive
        interaction.showDiscardLegacyConfirm = true
        #expect(!tryFocus())
        interaction.showDiscardLegacyConfirm = false
        presentation.archiveFormVisible = true
        #expect(!tryFocus())
        presentation.archiveFormVisible = false
        #expect(!interaction.canFocusPickerConfirmation(
            presentation: presentation, modalID: UUID()))

        #expect(tryFocus())
        #expect(!tryFocus())
        focus.selectionChanged(hasSelection: true)
        focus.selectionChanged(hasSelection: false)
        #expect(!tryFocus(hasSelection: false))
        focus.selectionChanged(hasSelection: true)
        #expect(!tryFocus(isPresented: false))
        #expect(!focus.isPending)
        focus.selectionChanged(hasSelection: true)
        let consumedForOtherModal = focus.consumeIfPossible(
            hasSelection: true, isPresented: true, presentation: presentation,
            interaction: interaction, modalID: UUID())
        #expect(!consumedForOtherModal)
        #expect(!focus.isPending)
        focus.selectionChanged(hasSelection: true)
        #expect(interaction.endRowModal(modalID))
        #expect(!tryFocus())
        #expect(!focus.isPending)
        #expect(!interaction.canFocusPickerConfirmation(
            presentation: presentation, modalID: modalID))
    }
}

@MainActor
@Suite("Archive completion accessibility")
struct ArchiveCompletionAccessibilityTests {
    @Test("Final notices include both the Photos outcome and processing status")
    func completionIncludesPhotoOutcome() {
        let metadata = VideoMetadata(
            duration: 7, resolution: "test", codec: "test", orientation: "landscape",
            deviceModel: "test", osVersion: "test", capturedAt: nil,
            gpsLat: nil, gpsLon: nil, gpsAltitude: nil)
        let verified = ScopedPhotoAssociation(
            photoIdentifier: "photo",
            fingerprint: VideoContentFingerprint(
                sha256: String(repeating: "a", count: 64), byteCount: 1),
            metadata: metadata)
        let committed = ArchiveRetryPhotoLink.Outcome.committed(verified)
        #expect(committed.completionAnnouncement == "Re-upload complete. Video processing continues.")

        let missing = ArchiveRetryPhotoLink.Outcome.committed(nil)
        #expect(missing.completionAnnouncement
            == "Upload finished without a verified Photos link. Choose the video manually if you retry. Video processing continues.")

        let changed = ArchiveRetryPhotoLink.Outcome.associationChanged
        #expect(changed.completionAnnouncement.contains("saved Photos link changed"))
        #expect(changed.completionAnnouncement.contains("Video processing continues."))

        let superseded = ArchiveRetryPhotoLink.Outcome.superseded
        #expect(superseded.completionAnnouncement.contains("upload changed"))
        #expect(superseded.completionAnnouncement.contains("Video processing continues."))

        let failed = ArchiveRetryPhotoLink.Outcome.storageFailure(
            NSError(domain: "test", code: 1))
        #expect(failed.completionAnnouncement.contains("couldn't be updated"))
        #expect(failed.completionAnnouncement.contains("Video processing continues."))
        #expect(!failed.completionAnnouncement.contains("Repair saved photo links"))
    }

    @Test("Damaged links take priority over an earlier verification warning")
    func damagedStoreRequiresRepairBeforeRetry() {
        let damaged = ArchiveRetryPhotoLink.Outcome.storageFailure(
            PhotoAssociationError.invalidRecord)
        #expect(damaged.completionAnnouncement.contains("Re-upload complete"))
        #expect(damaged.completionAnnouncement.contains("If not already repaired"))
        #expect(damaged.completionAnnouncement.contains(
            "choose Repair saved photo links before retrying"))
        #expect(damaged.completionAnnouncement.contains("choose the video manually"))

        let preferredWhileDamaged = ArchiveReuploadNotice.preferred(
            reuploadNotice: "Another notice", refreshWarning: "Refresh warning",
            photoWarning: "Earlier verification warning", readWarning: "Old read warning",
            displayedError: "Earlier error", isDamaged: true)
        #expect(preferredWhileDamaged == ArchiveReuploadNotice.repairRequired)
        #expect(ArchiveReuploadNotice.distinctError("Earlier error", isDamaged: true) == "Earlier error")
        #expect(ArchiveReuploadNotice.distinctError(
            ArchiveReuploadNotice.repairRequired, isDamaged: true) == nil)
        let preferredAfterRepair = ArchiveReuploadNotice.preferred(
            reuploadNotice: nil, refreshWarning: nil,
            photoWarning: "Earlier verification warning", readWarning: nil,
            displayedError: nil, isDamaged: false)
        #expect(preferredAfterRepair == "Earlier verification warning")
        let preferredWithOtherError = ArchiveReuploadNotice.preferred(
            reuploadNotice: nil, refreshWarning: nil,
            photoWarning: "Earlier verification warning", readWarning: nil,
            displayedError: "Earlier error", isDamaged: false)
        #expect(preferredWithOtherError == nil)
    }

    @Test("Completion speech and its focus wait for the permitted presentation")
    func completionAndFocusWaitForVoiceOver() throws {
        var queue = ArchiveAnnouncementQueue()
        var focus = ArchiveCompletionAnnouncementFocus()
        let message = "clip: Upload finished without a verified Photos link."
        focus.enqueue(focusAssetID: "asset")
        queue.append(message)

        let whileInactive = queue.takeIfPossible(isActive: false, hasModal: false)
        let whileModal = queue.takeIfPossible(isActive: true, hasModal: true)
        #expect(whileInactive == nil)
        #expect(whileModal == nil)
        #expect(focus.hasPending)

        let taken = queue.takeIfPossible(isActive: true, hasModal: false)
        let ready = try #require(taken)
        let immediateFocus = focus.beginPost(ready, voiceOverRunning: true)
        #expect(immediateFocus == nil)
        #expect(focus.isWaitingForVoiceOver)
        queue.append("Refresh failed.")
        let whileSpeaking = queue.takeIfPossible(
            isActive: !focus.isWaitingForVoiceOver, hasModal: false)
        #expect(whileSpeaking == nil)

        let unrelated = focus.finish(
            "another announcement", wasSuccessful: true, isPresentationBlocked: false)
        #expect(unrelated == nil)
        #expect(focus.isWaitingForVoiceOver)
        let finished = focus.finish(ready, wasSuccessful: true, isPresentationBlocked: false)
        #expect(finished?.focusAssetID == "asset")
        #expect(finished?.interruptedAnnouncement == nil)
        #expect(!focus.isWaitingForVoiceOver)
        let duplicate = focus.finish(ready, wasSuccessful: true, isPresentationBlocked: false)
        #expect(duplicate == nil)
        let followUp = queue.takeIfPossible(isActive: true, hasModal: false)
        #expect(followUp == "Refresh failed.")
    }

    @Test("A completion interrupted by a modal is retried after dismissal")
    func completionInterruptedByModalIsRequeued() throws {
        var queue = ArchiveAnnouncementQueue()
        var focus = ArchiveCompletionAnnouncementFocus()
        let message = "clip: Upload finished without a verified Photos link."
        focus.enqueue(focusAssetID: "asset")
        queue.append(message)
        let initialTake = queue.takeIfPossible(isActive: true, hasModal: false)
        let initial = try #require(initialTake)
        _ = focus.beginPost(initial, voiceOverRunning: true)

        focus.presentationBlocked()
        queue.append("Refresh failed.")
        let finishResult = focus.finish(
            initial, wasSuccessful: false, isPresentationBlocked: true)
        let finished = try #require(finishResult)
        #expect(finished.focusAssetID == nil)
        let interrupted = try #require(finished.interruptedAnnouncement)
        queue.prepend(interrupted)
        focus.enqueue(focusAssetID: nil)

        let whileModal = queue.takeIfPossible(isActive: true, hasModal: true)
        #expect(whileModal == nil)
        let whileInactive = queue.takeIfPossible(isActive: false, hasModal: false)
        #expect(whileInactive == nil)
        let afterDismissalTake = queue.takeIfPossible(isActive: true, hasModal: false)
        let afterDismissal = try #require(afterDismissalTake)
        #expect(afterDismissal == "\(message) Refresh failed.")
        _ = focus.beginPost(afterDismissal, voiceOverRunning: true)
        let replayFinished = focus.finish(
            afterDismissal, wasSuccessful: true, isPresentationBlocked: false)
        #expect(replayFinished?.focusAssetID == nil)
        #expect(replayFinished?.interruptedAnnouncement == nil)
    }

    @Test("Follow-up completions retain focus without replacing a newer focus request")
    func completionFocusCarriesAcrossQueuedCompletions() {
        var focus = ArchiveCompletionAnnouncementFocus()
        focus.enqueue(focusAssetID: "first")
        _ = focus.beginPost("First", voiceOverRunning: true)
        focus.enqueue(focusAssetID: nil)
        let first = focus.finish("First", wasSuccessful: true, isPresentationBlocked: false)
        focus.preserveFocusIfAbsent(first?.focusAssetID)
        _ = focus.beginPost("Second", voiceOverRunning: true)
        let second = focus.finish("Second", wasSuccessful: true, isPresentationBlocked: false)
        #expect(second?.focusAssetID == "first")

        focus.enqueue(focusAssetID: "first")
        _ = focus.beginPost("First", voiceOverRunning: true)
        focus.enqueue(focusAssetID: "second")
        focus.enqueue(focusAssetID: nil)
        let prematurePost = focus.beginPost("Second", voiceOverRunning: true)
        #expect(prematurePost == nil)
        #expect(focus.hasPending)
        #expect(focus.isWaitingForVoiceOver)
        let previous = focus.finish("First", wasSuccessful: true, isPresentationBlocked: false)
        focus.preserveFocusIfAbsent(previous?.focusAssetID)
        _ = focus.beginPost("Second", voiceOverRunning: true)
        let newer = focus.finish("Second", wasSuccessful: true, isPresentationBlocked: false)
        #expect(newer?.focusAssetID == "second")

        focus.enqueue(focusAssetID: "first")
        _ = focus.beginPost("First", voiceOverRunning: true)
        focus.enqueue(focusAssetID: "second")
        focus.presentationBlocked()
        _ = focus.finish("First", wasSuccessful: false, isPresentationBlocked: false)
        _ = focus.beginPost("Second", voiceOverRunning: true)
        let afterModal = focus.finish("Second", wasSuccessful: true, isPresentationBlocked: false)
        #expect(afterModal?.focusAssetID == nil)
    }

    @Test("Interrupted or invalidated speech does not restore stale focus")
    func completionFocusHandlesInterruptionAndVoiceOverOff() {
        var focus = ArchiveCompletionAnnouncementFocus()
        focus.enqueue(focusAssetID: "asset")
        let immediate = focus.beginPost("Complete", voiceOverRunning: false)
        #expect(immediate == "asset")
        #expect(!focus.hasPending)
        #expect(!focus.isWaitingForVoiceOver)

        focus.enqueue(focusAssetID: "asset")
        _ = focus.beginPost("Complete", voiceOverRunning: true)
        let interrupted = focus.finish(
            "Complete", wasSuccessful: false, isPresentationBlocked: false)
        #expect(interrupted != nil)
        #expect(interrupted?.focusAssetID == nil)
        #expect(interrupted?.interruptedAnnouncement == nil)
        #expect(!focus.isWaitingForVoiceOver)

        focus.enqueue(focusAssetID: "asset")
        _ = focus.beginPost("Complete", voiceOverRunning: true)
        focus.presentationBlocked()
        let blocked = focus.finish(
            "Complete", wasSuccessful: false, isPresentationBlocked: false)
        #expect(blocked?.focusAssetID == nil)
        #expect(blocked?.interruptedAnnouncement == "Complete")

        focus.enqueue(focusAssetID: "asset")
        _ = focus.beginPost("Complete", voiceOverRunning: true)
        let blockedBeforeChangeCallback = focus.finish(
            "Complete", wasSuccessful: false, isPresentationBlocked: true)
        #expect(blockedBeforeChangeCallback?.interruptedAnnouncement == "Complete")

        focus.enqueue(focusAssetID: "asset")
        _ = focus.beginPost("Complete", voiceOverRunning: true)
        focus.presentationBlocked()
        let finishedAfterBlocking = focus.finish(
            "Complete", wasSuccessful: true, isPresentationBlocked: false)
        #expect(finishedAfterBlocking?.focusAssetID == nil)
        #expect(finishedAfterBlocking?.interruptedAnnouncement == nil)

        focus.enqueue(focusAssetID: "asset")
        _ = focus.beginPost("Complete", voiceOverRunning: true)
        let focusWhenVoiceOverTurnsOff = focus.cancelSpeaking()
        #expect(focusWhenVoiceOverTurnsOff == "asset")

        focus.enqueue(focusAssetID: "asset")
        _ = focus.beginPost("Complete", voiceOverRunning: true)
        focus.presentationBlocked()
        let cancelledFocus = focus.cancelSpeaking()
        #expect(cancelledFocus == nil)
        let stale = focus.finish("Complete", wasSuccessful: true, isPresentationBlocked: false)
        #expect(stale == nil)
        #expect(!focus.isWaitingForVoiceOver)
    }
}
