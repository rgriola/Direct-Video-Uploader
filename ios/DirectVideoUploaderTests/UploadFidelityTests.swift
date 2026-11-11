import AVFoundation
import Foundation
import Network
import Observation
import Photos
import Synchronization
import Testing
import UIKit
@testable import DirectVideoUploader

struct UploadFidelityTests {
    private let base = VideoMetadata(
        duration: 42,
        resolution: "3840×2160",
        codec: "HEVC / H.265",
        orientation: "landscape",
        deviceModel: "iPhone",
        osVersion: "iOS 18.6",
        capturedAt: "2026-05-10T12:00:00Z",
        gpsLat: 40.7,
        gpsLon: -74.0,
        gpsAltitude: 10
    )

    @Test
    func untouchedTrimSelectionCountsAsFullLength() {
        #expect(TrimRange.isFullLength(start: 0, end: 30, duration: 30))
        #expect(TrimRange.isFullLength(start: 0.02, end: 29.97, duration: 30))
        #expect(TrimRange.isFullLength(start: 0, end: 0, duration: 0))
    }

    @Test
    func photosOriginalFilenameCannotEscapeItsTemporaryDirectory() throws {
        #expect(try OriginalVideoLoader.safeOriginalFilename("camera.mov") == "camera.mov")
        #expect(try OriginalVideoLoader.safeOriginalFilename("../../camera.mov") == "camera.mov")
        #expect(throws: OriginalVideoLoader.LoaderError.self) {
            try OriginalVideoLoader.safeOriginalFilename("..")
        }
    }
}

nonisolated private func testForm(_ assetId: String, savedAt: TimeInterval = 0) -> PendingForm {
    PendingForm(
        assetId: assetId, originalFileName: "\(assetId).mov", capturedAt: nil,
        clipCount: 1, duration: 10, thumbnailJPEG: nil,
        savedAt: Date(timeIntervalSince1970: savedAt))
}

nonisolated private struct PreviousPendingFormScope: Encodable {
    let userId: String
    let server: String
}

nonisolated private struct PreviousPendingFormRecord: Encodable {
    let id: UUID
    let scope: PreviousPendingFormScope
    let form: PendingForm
}

nonisolated private func testHTTPResponse(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://example.test")!,
        statusCode: status, httpVersion: nil, headerFields: nil)!
}

nonisolated private func testFormReceipt(_ assetId: String) -> Data {
    Data(#"{"formResponse":{"id":"form","assetId":"\#(assetId)"}}"#.utf8)
}

nonisolated private func testTranscriptReceipt(_ clipId: String = "clip-1") -> Data {
    Data(#"{"ok":true,"clipId":"\#(clipId)"}"#.utf8)
}

nonisolated private func testAssetData(
    id: String, owner: String?, completed: Bool = false,
    uploadMode: Asset.AssetUploadMode? = .mux
) -> Data {
    let user = owner.map { #"{"id":"\#($0)","name":"Reporter"}"# } ?? "null"
    let form = completed ? #"{"id":"form-1"}"# : "null"
    let mode = uploadMode.map { "\"\($0.rawValue)\"" } ?? "null"
    return Data(
        """
        {"asset":{"id":"\(id)","status":"READY","uploadMode":\(mode),"user":\(user),"formResponse":\(form)}}
        """.utf8)
}

@MainActor
private struct FormTestFixture {
    let directory: URL
    let store: PendingFormStore
    let scope: PendingFormScope

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-form-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PendingFormStore(directory: directory)
        scope = PendingFormScope(
            userId: "user-1", serverURL: URL(string: "https://one.example.test")!)!
    }

    var storageURL: URL { directory.appendingPathComponent("pending-forms-v2.json") }
    var legacyURL: URL { directory.appendingPathComponent("pending-form.json") }
    var request: URLRequest { URLRequest(url: URL(string: "https://example.test/api/assets")!) }

    func cleanup() {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove temporary test directory: \(error)")
        }
    }
}

@MainActor
private final class FormTestState {
    var isCurrent = true
    var calls = 0
    var action: (@MainActor () -> Void)?
    var asyncAction: (@MainActor () async -> Void)?
}

@MainActor
private final class ThumbnailTestGate {
    private var pending: [String: CheckedContinuation<UIImage?, Never>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func generate(_ url: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let name = url.lastPathComponent
            pending[name] = continuation
            waiters.removeValue(forKey: name)?.resume()
        }
    }

    func waitForStart(_ name: String) async {
        if pending[name] != nil { return }
        await withCheckedContinuation { continuation in
            waiters[name] = continuation
        }
    }

    func finish(_ name: String) {
        pending.removeValue(forKey: name)?.resume(returning: nil)
    }

    func finishAll() {
        for continuation in pending.values { continuation.resume(returning: nil) }
        pending.removeAll()
    }
}

@MainActor
private final class HandshakeTestGate {
    private var response: CheckedContinuation<(Data, URLResponse), Never>?
    private var started: CheckedContinuation<Void, Never>?

    func waitForResponse() async -> (Data, URLResponse) {
        await withCheckedContinuation { continuation in
            response = continuation
            started?.resume()
            started = nil
        }
    }

    func waitForStart() async {
        if response != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        response?.resume(returning: (Data(#"0{"sid":"test"}"#.utf8), testHTTPResponse(200)))
        response = nil
    }
}

nonisolated private struct RecoveryGateTimeout: Error {}

@MainActor
private final class RecoveryResponseTestGate {
    private var response: CheckedContinuation<(Data, URLResponse), Never>?
    private let started = AsyncStream<Void>.makeStream()

    func waitForResponse() async -> (Data, URLResponse) {
        await withCheckedContinuation { continuation in
            response = continuation
            started.continuation.yield(())
        }
    }

    func waitForStart() async throws {
        if response != nil { return }
        let stream = started.stream
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw RecoveryGateTimeout()
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    func finish(data: Data = Data(), status: Int) {
        response?.resume(returning: (data, testHTTPResponse(status)))
        response = nil
    }
}

@MainActor
private final class SocketURLTestState {
    var url = URL(string: "https://127.0.0.1:9/proxy")!
    var sessionIsCurrent = true
}

nonisolated private enum PhotoStoreTestError: Error {
    case protectionFailed
    case commitFailed
}

@MainActor
struct ScopedPhotoAssociationTests {
    private let fingerprint = VideoContentFingerprint(
        sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        byteCount: 3)
    private let metadata = VideoMetadata(
        duration: 7, resolution: "test", codec: "test", orientation: "landscape",
        deviceModel: "test", osVersion: "test", capturedAt: nil,
        gpsLat: nil, gpsLon: nil, gpsAltitude: nil)

    @Test
    func fingerprintCoversVideoBytes() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let url = fixture.directory.appendingPathComponent("clip.mov")
        try Data("abc".utf8).write(to: url)
        #expect(try await VideoContentFingerprint.calculate(for: url) == fingerprint)
        try Data("abd".utf8).write(to: url)
        #expect(try await VideoContentFingerprint.calculate(for: url) != fingerprint)
    }

    @Test
    func associationsAreScopedAndLegacyContentIsPreserved() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let otherAccount = try #require(
            PendingFormScope(userId: "user-2", serverURL: URL(string: "https://one.example.test")!))
        let otherServer = try #require(
            PendingFormScope(userId: "user-1", serverURL: URL(string: "https://two.example.test")!))
        let legacyURL = fixture.directory.appendingPathComponent("phasset-identifiers.json")
        let legacy = Data(#"{"asset":"unverified-photo"}"#.utf8)
        try legacy.write(to: legacyURL)
        try store.protectLegacyFile()
        #expect(try store.association(assetId: "asset", for: fixture.scope) == nil)

        let first = ScopedPhotoAssociation(
            photoIdentifier: "photo-1", fingerprint: fingerprint, metadata: metadata)
        let second = ScopedPhotoAssociation(
            photoIdentifier: "photo-2", fingerprint: fingerprint, metadata: metadata)
        try store.save(assetId: "asset", association: first, for: fixture.scope)
        try store.save(assetId: "asset", association: second, for: otherAccount)
        #expect(try store.association(assetId: "asset", for: fixture.scope) == first)
        #expect(try store.association(assetId: "asset", for: otherAccount) == second)
        #expect(try store.association(assetId: "asset", for: otherServer) == nil)
        #expect(try Data(contentsOf: legacyURL) == legacy)

        let url = try store.storageURL(for: fixture.scope)
        #expect(!url.lastPathComponent.contains("user-1"))
        #expect(!url.lastPathComponent.contains("one.example.test"))
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test
    func olderScopedLinksArePreservedButNeverTrustedAutomatically() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let currentURL = try store.storageURL(for: fixture.scope)
        let oldURL = fixture.directory.appendingPathComponent(
            currentURL.lastPathComponent.replacingOccurrences(of: "-v3-", with: "-v2-"))
        let oldData = try JSONSerialization.data(withJSONObject: [
            "scope": ["userId": fixture.scope.userId, "server": fixture.scope.server],
            "associations": [
                "asset": [
                    "photoIdentifier": "unverified",
                    "fingerprint": ["sha256": fingerprint.sha256, "byteCount": fingerprint.byteCount],
                ]
            ],
        ])
        try oldData.write(to: oldURL)
        #expect(try store.association(assetId: "asset", for: fixture.scope) == nil)
        let verified = ScopedPhotoAssociation(
            photoIdentifier: "verified", fingerprint: fingerprint, metadata: metadata)
        try store.save(assetId: "asset", association: verified, for: fixture.scope)
        #expect(try store.association(assetId: "asset", for: fixture.scope) == verified)
        #expect(try Data(contentsOf: oldURL) == oldData)
    }

    @Test
    func corruptAssociationsAreReportedWithoutOverwritingThem() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let url = try store.storageURL(for: fixture.scope)
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: url)
        #expect(throws: DecodingError.self) {
            try store.association(assetId: "asset", for: fixture.scope)
        }
        #expect(throws: DecodingError.self) {
            try store.save(
                assetId: "asset",
                association: ScopedPhotoAssociation(
                    photoIdentifier: "photo", fingerprint: fingerprint, metadata: metadata),
                for: fixture.scope)
        }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test
    func failedStagedProtectionLeavesPreviousAssociationUnchanged() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let original = ScopedPhotoAssociation(
            photoIdentifier: "first", fingerprint: fingerprint, metadata: metadata)
        try store.save(assetId: "asset", association: original, for: fixture.scope)
        let failing = ScopedPHAssetIdentifierStore(
            directory: fixture.directory,
            prepareStagedFile: { _ in throw PhotoStoreTestError.protectionFailed })
        #expect(throws: PhotoStoreTestError.self) {
            try failing.save(
                assetId: "asset",
                association: ScopedPhotoAssociation(
                    photoIdentifier: "second", fingerprint: fingerprint, metadata: metadata),
                for: fixture.scope)
        }
        #expect(try store.association(assetId: "asset", for: fixture.scope) == original)
        let staging = fixture.directory.appendingPathComponent(".photo-association-staging")
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        #expect(try staging.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test
    func failedAtomicCommitKeepsOriginalAndSweepsAbandonedStages() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let original = ScopedPhotoAssociation(
            photoIdentifier: "first", fingerprint: fingerprint, metadata: metadata)
        try store.save(assetId: "asset", association: original, for: fixture.scope)
        let oldBytes = try Data(contentsOf: store.storageURL(for: fixture.scope))
        let staging = fixture.directory.appendingPathComponent(".photo-association-staging")
        let abandoned = staging.appendingPathComponent(
            "phasset-identifiers-\(UUID().uuidString).tmp")
        try Data("abandoned".utf8).write(to: abandoned)
        let failing = ScopedPHAssetIdentifierStore(
            directory: fixture.directory,
            commitStagedFile: { _, _ in throw PhotoStoreTestError.commitFailed })
        #expect(throws: PhotoStoreTestError.self) {
            try failing.save(
                assetId: "asset",
                association: ScopedPhotoAssociation(
                    photoIdentifier: "second", fingerprint: fingerprint, metadata: metadata),
                for: fixture.scope)
        }
        #expect(try Data(contentsOf: store.storageURL(for: fixture.scope)) == oldBytes)
        #expect(try store.association(assetId: "asset", for: fixture.scope) == original)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test
    func clearingOneAssociationPreservesOtherScopedLinks() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let association = ScopedPhotoAssociation(
            photoIdentifier: "photo", fingerprint: fingerprint, metadata: metadata)
        try store.save(assetId: "first", association: association, for: fixture.scope)
        try store.save(assetId: "second", association: association, for: fixture.scope)
        try store.remove(assetId: "first", for: fixture.scope)
        #expect(try store.association(assetId: "first", for: fixture.scope) == nil)
        #expect(try store.association(assetId: "second", for: fixture.scope) == association)
    }

    @Test
    func legacyProtectionPreservesTheExistingBackupPolicy() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        var legacyURL = fixture.directory.appendingPathComponent("phasset-identifiers.json")
        try Data("{}".utf8).write(to: legacyURL)
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        for excluded in [false, true] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = excluded
            try legacyURL.setResourceValues(values)
            let before = try legacyURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup
            try store.protectLegacyFile()
            let after = try legacyURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup
            #expect(before == excluded)
            #expect(after == before)
        }
    }

    @Test
    func manualSelectionLinksOnlyWhenCurrentAndOriginalBytesMatch() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let current = fixture.directory.appendingPathComponent("current.mov")
        let original = fixture.directory.appendingPathComponent("original.mov")
        try Data("edited".utf8).write(to: current)
        try Data("camera".utf8).write(to: original)
        let currentFingerprint = try await VideoContentFingerprint.calculate(for: current)
        let originalFingerprint = try await VideoContentFingerprint.calculate(for: original)
        #expect(ManualPhotoRecovery.association(
            identifier: "photo", selected: currentFingerprint, original: originalFingerprint,
            metadata: metadata) == nil)
        #expect(ManualPhotoRecovery.association(
            identifier: "photo", selected: currentFingerprint, original: currentFingerprint,
            metadata: metadata)
            == ScopedPhotoAssociation(
                photoIdentifier: "photo", fingerprint: currentFingerprint, metadata: metadata))
        let changedPhotosMetadata = metadata.fillingMissing(
            capturedAt: "2026-06-01T12:00:00Z", gpsLat: 40, gpsLon: -74, gpsAltitude: nil)
        #expect(changedPhotosMetadata.gpsLat == 40)
        let association = try #require(ManualPhotoRecovery.association(
            identifier: "photo", selected: currentFingerprint, original: currentFingerprint,
            metadata: metadata))
        #expect(association.metadata.gpsLat == nil)
        #expect(association.metadata.capturedAt == nil)
    }

    @Test
    func explicitRepairPreservesDamagedFileAndOtherScopes() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let otherScope = try #require(PendingFormScope(
            userId: "another-user", serverURL: URL(string: "https://one.example.test")!))
        let association = ScopedPhotoAssociation(
            photoIdentifier: "other-photo", fingerprint: fingerprint, metadata: metadata)
        try store.save(assetId: "other", association: association, for: otherScope)
        let damagedURL = try store.storageURL(for: fixture.scope)
        let damaged = Data("{invalid".utf8)
        try damaged.write(to: damagedURL)
        #expect(throws: DecodingError.self) {
            try store.association(assetId: "asset", for: fixture.scope)
        }
        #expect(try store.quarantineDamagedAssociations(for: fixture.scope))
        #expect(try store.association(assetId: "asset", for: fixture.scope) == nil)
        #expect(try store.association(assetId: "other", for: otherScope) == association)
        let savedFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.directory, includingPropertiesForKeys: nil)
        let preserved = try #require(savedFiles.first {
            $0.lastPathComponent.contains("-damaged-")
        })
        #expect(try Data(contentsOf: preserved) == damaged)
        #expect(try !store.quarantineDamagedAssociations(for: fixture.scope))
    }

    @Test
    func archiveOriginRejectsChangedAccountTokenOrServer() throws {
        let server = URL(string: "https://one.example.test")!
        let auth = testAuth(serverURL: server)
        let origin = try #require(ArchiveSessionIdentity(auth: auth, serverURL: server))
        #expect(origin.isCurrent(auth, serverURL: server))
        #expect(!origin.isCurrent(auth, serverURL: URL(string: "https://two.example.test")!))
        #expect(!origin.isCurrent(
            auth, serverURL: URL(string: "https://one.example.test?changed=true")!))

        auth.token = "different-session"
        #expect(!origin.isCurrent(auth, serverURL: server))
    }

    #if !targetEnvironment(simulator)
    @Test
    func associationsAndLegacyFilesUseCompleteProtection() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let legacyURL = fixture.directory.appendingPathComponent("phasset-identifiers.json")
        try Data("{}".utf8).write(to: legacyURL)
        try store.protectLegacyFile()
        try store.save(
            assetId: "asset",
            association: ScopedPhotoAssociation(
                photoIdentifier: "photo", fingerprint: fingerprint, metadata: metadata),
            for: fixture.scope)
        for url in [legacyURL, try store.storageURL(for: fixture.scope)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.protectionKey] as? String == FileProtectionType.complete.rawValue)
        }
    }
    #endif
}

struct TemporaryVideoStorageTests {
    @Test
    func copiesBytesIntoAfterFirstUnlockProtectedFiles() async throws {
        let sourceDirectory = try TemporaryVideoStorage.makeDirectory()
        let destinationDirectory = try TemporaryVideoStorage.makeDirectory()
        defer {
            removeTemporaryVideoItem(sourceDirectory)
            removeTemporaryVideoItem(destinationDirectory)
        }
        let source = sourceDirectory.appendingPathComponent("source.mov")
        let destination = destinationDirectory.appendingPathComponent("selected.mov")
        let bytes = Data("selected video representation".utf8)
        try TemporaryVideoStorage.createFile(at: source)
        try bytes.write(to: source)
        try TemporaryVideoStorage.applyProtection(to: source)
        try await TemporaryVideoStorage.copy(from: source, to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
        for url in [sourceDirectory, destinationDirectory, destination] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #if targetEnvironment(simulator)
            if attributes[.protectionKey] == nil { continue }
            #endif
            #expect(attributes[.protectionKey] as? String
                == FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        }
    }
}

@MainActor
struct PendingFormStoreTests {
    #if !targetEnvironment(simulator)
    @Test
    func savedFormsUseCompleteFileProtection() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        _ = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.storageURL.path)
        #expect(attributes[.protectionKey] as? String == FileProtectionType.complete.rawValue)

        try Data(#"{"assetId":"old"}"#.utf8).write(to: fixture.legacyURL)
        try fixture.store.protectLegacyForm()
        let legacyAttributes = try FileManager.default.attributesOfItem(atPath: fixture.legacyURL.path)
        #expect(legacyAttributes[.protectionKey] as? String == FileProtectionType.complete.rawValue)
    }
    #endif

    @Test
    func scopesUseAccountAndServerWithoutURLCredentialsOrQuery() throws {
        let url = try #require(
            URL(string: "HTTPS://example:password@EXAMPLE.TEST:8443/base?token=value#fragment"))
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: url))
        #expect(PendingFormScope.isValidDigest(scope.server))
        #expect(!scope.server.contains("example.test"))
        #expect(scope == PendingFormScope(
            userId: "user-1", serverURL: URL(string: "https://example.test:8443/base")!))
        #expect(scope != PendingFormScope(
            userId: "user-1", serverURL: URL(string: "https://example.test:8443/other")!))
        #expect(PendingFormScope(userId: "", serverURL: url) == nil)
        #expect(PendingFormScope(userId: "user-1", serverURL: URL(string: "file:///tmp")!) == nil)
        #expect(scope != PendingFormScope(userId: "user-2", serverURL: url))
        #expect(
            scope
                != PendingFormScope(
                    userId: "user-1", serverURL: URL(string: "https://other.example.test")!)
        )
    }

    @Test
    func preservesMultipleFormsAcrossAccountsAndServers() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let otherUser = try #require(
            PendingFormScope(
                userId: "user-2", serverURL: URL(string: "https://one.example.test")!))
        let otherServer = try #require(
            PendingFormScope(
                userId: "user-1", serverURL: URL(string: "https://two.example.test")!))
        let first = try fixture.store.save(testForm("first", savedAt: 1), for: fixture.scope)
        let second = try fixture.store.save(testForm("second", savedAt: 2), for: fixture.scope)
        let otherAccount = try fixture.store.save(testForm("other", savedAt: 0), for: otherUser)
        let otherHost = try fixture.store.save(testForm("remote", savedAt: 0), for: otherServer)

        #expect(try fixture.store.next(for: fixture.scope)?.id == first.id)
        #expect(try fixture.store.record(assetId: "other", for: fixture.scope) == nil)
        #expect(try fixture.store.record(assetId: "remote", for: fixture.scope) == nil)
        try fixture.store.remove(first)
        #expect(try fixture.store.next(for: fixture.scope)?.id == second.id)
        #expect(try fixture.store.contains(otherAccount))
        #expect(try fixture.store.contains(otherHost))
    }

    @Test
    func migratesAllPreviousScopesWithoutChangingRecordIdentity() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let firstId = UUID()
        let secondId = UUID()
        let oldRecords = [
            PreviousPendingFormRecord(
                id: firstId,
                scope: PreviousPendingFormScope(userId: "user-1", server: "https://one.example.test"),
                form: testForm("first", savedAt: 1)),
            PreviousPendingFormRecord(
                id: secondId,
                scope: PreviousPendingFormScope(userId: "user-2", server: "https://one.example.test/proxy"),
                form: testForm("second", savedAt: 2)),
        ]
        try JSONEncoder().encode(oldRecords).write(to: fixture.storageURL)
        try fixture.store.prepareExistingFiles()

        let bytes = try Data(contentsOf: fixture.storageURL)
        let migrated = try JSONDecoder().decode([PendingFormRecord].self, from: bytes)
        #expect(migrated.map(\.id) == [firstId, secondId])
        #expect(migrated.map(\.form.assetId) == ["first", "second"])
        #expect(migrated.allSatisfy { PendingFormScope.isValidDigest($0.scope.server) })
        #expect(migrated[0].scope == fixture.scope)
        #expect(try fixture.store.next(for: fixture.scope)?.id == firstId)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("example.test"))

        try fixture.store.prepareExistingFiles()
        #expect(try Data(contentsOf: fixture.storageURL) == bytes)
    }

    @Test(arguments: [
        "file:///tmp/invalid",
        "sha256-v1:invalid",
    ])
    func malformedScopesPreserveTheEntireStore(server: String) throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let records = [
            PreviousPendingFormRecord(
                id: UUID(),
                scope: PreviousPendingFormScope(userId: "user-1", server: "https://one.example.test"),
                form: testForm("valid")),
            PreviousPendingFormRecord(
                id: UUID(), scope: PreviousPendingFormScope(userId: "user-2", server: server),
                form: testForm("invalid")),
        ]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fixture.storageURL)
        #expect(throws: PendingFormStorageError.self) {
            try fixture.store.prepareExistingFiles()
        }
        #expect(try Data(contentsOf: fixture.storageURL) == original)
    }

    @Test
    func inaccessibleStoreIsNotTreatedAsMissing() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let directory = fixture.directory.appendingPathComponent("inaccessible", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PendingFormStore(directory: directory)
        let original = try store.save(testForm("original"), for: fixture.scope)
        try Data(#"{"assetId":"legacy"}"#.utf8)
            .write(to: directory.appendingPathComponent("pending-form.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            } catch {
                Issue.record("Could not restore test-directory permissions: \(error)")
            }
        }

        do {
            _ = try store.next(for: fixture.scope)
            Issue.record("An inaccessible recovery store must not be treated as empty")
        } catch {
            #expect((error as NSError).domain != NSCocoaErrorDomain
                || (error as NSError).code != NSFileReadNoSuchFileError)
        }
        do {
            _ = try store.hasLegacyForm
            Issue.record("An inaccessible legacy file must not be treated as absent")
        } catch {
            #expect((error as NSError).domain != NSCocoaErrorDomain
                || (error as NSError).code != NSFileReadNoSuchFileError)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(try store.contains(original))
    }

    @Test
    func explicitlySkippedRecordsStayInArchiveAcrossDuplicateRequests() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let original = try fixture.store.save(testForm("skipped"), for: fixture.scope)
        try fixture.store.deferToArchive(original)
        #expect(try fixture.store.next(for: fixture.scope) == nil)
        let replacement = try fixture.store.save(testForm("skipped", savedAt: 2), for: fixture.scope)
        #expect(replacement.autoRecover == false)
        #expect(try fixture.store.next(for: fixture.scope) == nil)
        #expect(try fixture.store.record(assetId: "skipped", for: fixture.scope)?.id == replacement.id)
        #expect(throws: PendingFormStorageError.self) {
            try fixture.store.deferToArchive(original)
        }
    }

    @Test
    func replacementIsNotRemovedByAnOlderRecord() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let original = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let replacement = try fixture.store.save(testForm("asset", savedAt: 1), for: fixture.scope)
        try fixture.store.remove(original)
        #expect(original.id != replacement.id)
        #expect(
            try fixture.store.record(assetId: "asset", for: fixture.scope)?.id == replacement.id)
    }

    @Test
    func legacyFileIsNeverModified() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let legacy = Data(#"{"assetId":"old-asset"}"#.utf8)
        try legacy.write(to: fixture.legacyURL)
        #expect(try fixture.store.hasLegacyForm)
        try fixture.store.protectLegacyForm()
        let record = try fixture.store.save(testForm("new-asset"), for: fixture.scope)
        try fixture.store.remove(record)
        #expect(try Data(contentsOf: fixture.legacyURL) == legacy)
    }

    @Test
    func explicitlyDiscardingLegacyFormPreservesScopedRecords() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        try Data(#"{"assetId":"old"}"#.utf8).write(to: fixture.legacyURL)
        let record = try fixture.store.save(testForm("new"), for: fixture.scope)

        try fixture.store.discardLegacyForm()
        #expect(try !fixture.store.hasLegacyForm)
        #expect(try fixture.store.contains(record))
        try fixture.store.discardLegacyForm()
    }

    @Test
    func corruptStoreIsReportedAndNotOverwritten() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: fixture.storageURL)
        #expect(throws: DecodingError.self) { try fixture.store.next(for: fixture.scope) }
        #expect(throws: DecodingError.self) {
            try fixture.store.save(testForm("asset"), for: fixture.scope)
        }
        #expect(try Data(contentsOf: fixture.storageURL) == corrupt)
    }
}

@MainActor
struct PendingFormRecoveryTests {
    @Test(arguments: [false, true])
    func recordDeferredDuringLookupIsNotAutomaticallyRestored(networkFailure: Bool) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let deferred = try fixture.store.save(testForm("deferred", savedAt: 1), for: fixture.scope)
        let next = try fixture.store.save(testForm("next", savedAt: 2), for: fixture.scope)
        let recovery = PendingFormRecovery(
            store: fixture.store,
            fetch: { request in
                let id = request.url!.lastPathComponent
                if id == "deferred" {
                    try await MainActor.run { try fixture.store.deferToArchive(deferred) }
                    if networkFailure { throw URLError(.notConnectedToInternet) }
                }
                return (testAssetData(id: id, owner: "user-1"), testHTTPResponse(200))
            })

        let outcome = try await recovery.next(
            for: fixture.scope, isCurrent: { true },
            requestForAsset: { URLRequest(url: fixture.request.url!.appendingPathComponent($0)) })

        guard case .ready(let record, let skippedFailures) = outcome else {
            Issue.record("Expected the next eligible form")
            return
        }
        #expect(record.id == next.id)
        #expect(!skippedFailures)
        #expect(try fixture.store.record(assetId: "deferred", for: fixture.scope)?.autoRecover == false)
    }

    @Test(arguments: [403, 404, 500])
    func unavailableRecordDoesNotBlockLaterForms(status: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let first = try fixture.store.save(testForm("first", savedAt: 1), for: fixture.scope)
        let second = try fixture.store.save(testForm("second", savedAt: 2), for: fixture.scope)
        let recovery = PendingFormRecovery(
            store: fixture.store,
            fetch: { request in
                let id = request.url!.lastPathComponent
                if id == "first" { return (Data(), testHTTPResponse(status)) }
                return (testAssetData(id: id, owner: "user-1"), testHTTPResponse(200))
            })
        let outcome = try await recovery.next(
            for: fixture.scope, isCurrent: { true },
            requestForAsset: { URLRequest(url: fixture.request.url!.appendingPathComponent($0)) })
        guard case .ready(let record, let skippedFailures) = outcome else {
            Issue.record("Expected the later form to be available")
            return
        }
        #expect(record.id == second.id)
        #expect(skippedFailures)
        #expect(try fixture.store.contains(first))
        #expect(try fixture.store.contains(second))
    }

    @Test(arguments: [false, true])
    func replacedRecordIsRetriedAfterFailure(networkFailure: Bool) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let original = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let state = FormTestState()
        let recovery = PendingFormRecovery(
            store: fixture.store,
            fetch: { _ in
                let first = try await MainActor.run {
                    state.calls += 1
                    if state.calls == 1 {
                        _ = try fixture.store.save(testForm("asset", savedAt: 1), for: fixture.scope)
                        return true
                    }
                    return false
                }
                if first {
                    if networkFailure { throw URLError(.notConnectedToInternet) }
                    return (Data(), testHTTPResponse(404))
                }
                return (testAssetData(id: "asset", owner: "user-1"), testHTTPResponse(200))
            })
        let outcome = try await recovery.next(
            for: fixture.scope, isCurrent: { true }, requestForAsset: { _ in fixture.request })
        guard case .ready(let replacement, let skippedFailures) = outcome else {
            Issue.record("Expected the replacement form")
            return
        }
        #expect(replacement.id != original.id)
        #expect(!skippedFailures)
        #expect(state.calls == 2)
    }

    @Test(arguments: [301, 401, 403, 404, 500])
    func httpFailuresKeepTheRecord(status: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let recovery = PendingFormRecovery(
            store: fixture.store,
            fetch: { _ in
                (Data(), testHTTPResponse(status))
            })
        do {
            _ = try await recovery.next(
                for: fixture.scope, isCurrent: { true }, requestForAsset: { _ in fixture.request })
            Issue.record("Expected an HTTP failure")
        } catch PendingFormRecoveryError.httpStatus(let actual) {
            #expect(actual == status)
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
        }
        #expect(try fixture.store.contains(record))
    }

    @Test
    func invalidAndNetworkResponsesKeepTheRecord() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let invalid = PendingFormRecovery(
            store: fixture.store,
            fetch: { _ in
                (
                    Data(),
                    URLResponse(
                        url: URL(string: "https://example.test")!, mimeType: nil,
                        expectedContentLength: 0, textEncodingName: nil)
                )
            })
        do {
            _ = try await invalid.next(
                for: fixture.scope, isCurrent: { true }, requestForAsset: { _ in fixture.request })
            Issue.record("Expected an invalid-response error")
        } catch PendingFormRecoveryError.invalidResponse {
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
        }
        let offline = PendingFormRecovery(
            store: fixture.store,
            fetch: { _ in
                throw URLError(.notConnectedToInternet)
            })
        do {
            _ = try await offline.next(
                for: fixture.scope, isCurrent: { true }, requestForAsset: { _ in fixture.request })
            Issue.record("Expected a network error")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
        }
        let malformed = PendingFormRecovery(
            store: fixture.store,
            fetch: { _ in (Data("{invalid".utf8), testHTTPResponse(200)) })
        do {
            _ = try await malformed.next(
                for: fixture.scope, isCurrent: { true }, requestForAsset: { _ in fixture.request })
            Issue.record("Expected a decoding error")
        } catch is DecodingError {
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
        }
        #expect(try fixture.store.contains(record))
    }

    @Test
    func ownerAndAssetIdentityMustMatch() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        for data in [
            testAssetData(id: "asset", owner: "user-2"),
            testAssetData(id: "asset", owner: nil),
            testAssetData(id: "different", owner: "user-1"),
        ] {
            let recovery = PendingFormRecovery(
                store: fixture.store,
                fetch: { _ in
                    (data, testHTTPResponse(200))
                })
            do {
                _ = try await recovery.next(
                    for: fixture.scope, isCurrent: { true },
                    requestForAsset: { _ in fixture.request })
                Issue.record("Expected an owner or asset mismatch")
            } catch PendingFormRecoveryError.wrongOwner {
            } catch {
                Issue.record("Unexpected recovery error: \(error)")
            }
            #expect(try fixture.store.contains(record))
        }
    }

    @Test
    func completedRecordIsRemovedAndNextUnfinishedRecordIsReturned() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let first = try fixture.store.save(testForm("first", savedAt: 1), for: fixture.scope)
        let second = try fixture.store.save(testForm("second", savedAt: 2), for: fixture.scope)
        let recovery = PendingFormRecovery(
            store: fixture.store,
            fetch: { request in
                let id = request.url!.lastPathComponent
                return (
                    testAssetData(id: id, owner: "user-1", completed: id == "first"),
                    testHTTPResponse(200)
                )
            })
        let outcome = try await recovery.next(
            for: fixture.scope, isCurrent: { true },
            requestForAsset: { URLRequest(url: fixture.request.url!.appendingPathComponent($0)) })
        if case .ready(let record, _) = outcome {
            #expect(record.id == second.id)
        } else {
            Issue.record("Expected the next unfinished form")
        }
        #expect(try !fixture.store.contains(first))
        #expect(try fixture.store.contains(second))
    }

    @Test
    func sessionChangeDuringLookupDoesNotClearOrRestore() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let state = FormTestState()
        let recovery = PendingFormRecovery(
            store: fixture.store,
            fetch: { _ in
                await MainActor.run { state.isCurrent = false }
                return (
                    testAssetData(id: "asset", owner: "user-1", completed: true),
                    testHTTPResponse(200)
                )
            })
        let outcome = try await recovery.next(
            for: fixture.scope, isCurrent: { state.isCurrent },
            requestForAsset: { _ in fixture.request })
        guard case .sessionChanged = outcome else {
            Issue.record("Expected the stale session to be rejected")
            return
        }
        #expect(try fixture.store.contains(record))
    }

    @Test
    func replacedRecordIsRecheckedBeforeRecovery() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let original = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let state = FormTestState()
        let recovery = PendingFormRecovery(
            store: fixture.store,
            fetch: { _ in
                try await MainActor.run {
                    state.calls += 1
                    if state.calls == 1 {
                        _ = try fixture.store.save(
                            testForm("asset", savedAt: 1), for: fixture.scope)
                    }
                }
                return (testAssetData(id: "asset", owner: "user-1"), testHTTPResponse(200))
            })
        let outcome = try await recovery.next(
            for: fixture.scope, isCurrent: { true }, requestForAsset: { _ in fixture.request })
        if case .ready(let record, _) = outcome {
            #expect(record.id != original.id)
            #expect(try fixture.store.contains(record))
        } else {
            Issue.record("Expected the replacement form")
        }
        #expect(state.calls == 2)
    }
}

@MainActor
@Suite(.serialized)
struct PendingFormSubmissionTests {
    @Test
    func concurrentSubmissionsAreCoordinatedByScopeAndAsset() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let coordinator = PendingFormSubmissionCoordinator()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let slow = PendingFormSubmission(
            store: fixture.store, coordinator: coordinator,
            transport: { _ in
                started.continuation.yield(())
                for await _ in release.stream { break }
                return (testFormReceipt("asset"), testHTTPResponse(200))
            })
        let immediate = PendingFormSubmission(
            store: fixture.store, coordinator: coordinator,
            transport: { _ in (testFormReceipt("other"), testHTTPResponse(200)) })
        let first = Task {
            try await slow.submit(
                formData: ["slug": "first"], request: fixture.request, pendingRecord: record,
                scope: fixture.scope, assetId: "asset", isCurrent: { true })
        }
        defer {
            release.continuation.finish()
            first.cancel()
        }
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()
        do {
            _ = try await immediate.submit(
                formData: ["slug": "second"], request: fixture.request, pendingRecord: record,
                scope: fixture.scope, assetId: "asset", isCurrent: { true })
            Issue.record("Expected duplicate submission to be rejected")
        } catch FormSubmissionError.inProgress {
        } catch {
            Issue.record("Unexpected submission error: \(error)")
        }
        let other = try await immediate.submit(
            formData: [:], request: fixture.request, pendingRecord: nil,
            scope: fixture.scope, assetId: "other", isCurrent: { true })
        guard case .submitted = other else {
            Issue.record("A different asset should not be blocked")
            return
        }
        #expect(try fixture.store.contains(record))
        release.continuation.yield(())
        let result = try await first.value
        guard case .submitted = result else {
            Issue.record("Expected the original submission to finish")
            return
        }
        #expect(try !fixture.store.contains(record))
    }

    @Test
    func mismatchedRecoveryRecordIsNeverCleared() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let submission = PendingFormSubmission(
            store: fixture.store, coordinator: PendingFormSubmissionCoordinator(),
            transport: { _ in
                Issue.record("Mismatched records must not be sent")
                return (Data(), testHTTPResponse(200))
            })
        do {
            _ = try await submission.submit(
                formData: [:], request: fixture.request, pendingRecord: record,
                scope: fixture.scope, assetId: "different", isCurrent: { true })
            Issue.record("Expected record mismatch")
        } catch FormSubmissionError.recordMismatch {
        } catch {
            Issue.record("Unexpected submission error: \(error)")
        }
        #expect(try fixture.store.contains(record))
    }

    @Test
    func staleSessionIsRejectedBeforeSending() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let state = FormTestState()
        state.isCurrent = false
        let submission = PendingFormSubmission(
            store: fixture.store,
            transport: { _ in
                await MainActor.run { state.calls += 1 }
                return (Data(), testHTTPResponse(200))
            })
        let outcome = try await submission.submit(
            formData: [:], request: fixture.request, pendingRecord: record,
            scope: fixture.scope, assetId: "asset",
            isCurrent: { state.isCurrent })
        guard case .sessionChanged = outcome else {
            Issue.record("Expected the stale session to be rejected")
            return
        }
        #expect(state.calls == 0)
        #expect(try fixture.store.contains(record))
    }

    @Test(arguments: [301, 401, 403, 404, 500])
    func failedResponsesKeepTheForm(status: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let submission = PendingFormSubmission(
            store: fixture.store,
            transport: { _ in
                (Data(), testHTTPResponse(status))
            })
        do {
            _ = try await submission.submit(
                formData: ["slug": "test"], request: fixture.request, pendingRecord: record,
                scope: fixture.scope, assetId: "asset",
                isCurrent: { true })
            Issue.record("Expected an HTTP submission error")
        } catch FormSubmissionError.httpStatus(let actual) {
            #expect(actual == status)
        } catch {
            Issue.record("Unexpected submission error: \(error)")
        }
        #expect(try fixture.store.contains(record))
    }

    @Test
    func invalidAndNetworkResponsesKeepTheForm() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let invalid = PendingFormSubmission(
            store: fixture.store,
            transport: { _ in
                (
                    Data(),
                    URLResponse(
                        url: URL(string: "https://example.test")!, mimeType: nil,
                        expectedContentLength: 0, textEncodingName: nil)
                )
            })
        do {
            _ = try await invalid.submit(
                formData: [:], request: fixture.request, pendingRecord: record,
                scope: fixture.scope, assetId: "asset", isCurrent: { true })
            Issue.record("Expected an invalid-response error")
        } catch FormSubmissionError.invalidResponse {
        } catch {
            Issue.record("Unexpected submission error: \(error)")
        }
        let offline = PendingFormSubmission(
            store: fixture.store,
            transport: { _ in
                throw URLError(.notConnectedToInternet)
            })
        do {
            _ = try await offline.submit(
                formData: [:], request: fixture.request, pendingRecord: record,
                scope: fixture.scope, assetId: "asset", isCurrent: { true })
            Issue.record("Expected a network error")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("Unexpected submission error: \(error)")
        }
        #expect(try fixture.store.contains(record))
    }

    @Test(arguments: [
        "",
        "<html>Signed in</html>",
        "{}",
        #"{"formResponse":{"id":"form","assetId":"other"}}"#,
    ])
    func invalidReceiptsKeepTheForm(body: String) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let submission = PendingFormSubmission(
            store: fixture.store,
            transport: { _ in
                (Data(body.utf8), testHTTPResponse(body.isEmpty ? 204 : 200))
            })
        do {
            _ = try await submission.submit(
                formData: [:], request: fixture.request, pendingRecord: record,
                scope: fixture.scope, assetId: "asset", isCurrent: { true })
            Issue.record("Expected an invalid receipt error")
        } catch FormSubmissionError.invalidResponse {
        } catch {
            Issue.record("Unexpected submission error: \(error)")
        }
        #expect(try fixture.store.contains(record))
    }

    @Test(arguments: [200, 201])
    func successClearsOnlyTheSubmittedRecord(status: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let other = try fixture.store.save(testForm("other"), for: fixture.scope)
        let submission = PendingFormSubmission(
            store: fixture.store,
            transport: { request in
                #expect(request.timeoutInterval == RedirectSafeTransport.formRequestTimeout)
                let body = try #require(request.httpBody)
                let decoded = try JSONDecoder().decode([String: String].self, from: body)
                #expect(decoded == ["slug": "test"])
                return (testFormReceipt("asset"), testHTTPResponse(status))
            })
        let outcome = try await submission.submit(
            formData: ["slug": "test"], request: fixture.request, pendingRecord: record,
            scope: fixture.scope, assetId: "asset",
            isCurrent: { true })
        guard case .submitted = outcome else {
            Issue.record("Expected a successful submission")
            return
        }
        #expect(try !fixture.store.contains(record))
        #expect(try fixture.store.contains(other))
    }

    @Test
    func staleSessionAndReplacedRecordAreNotCleared() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let state = FormTestState()
        let stale = PendingFormSubmission(
            store: fixture.store,
            transport: { _ in
                await MainActor.run { state.isCurrent = false }
                return (Data(), testHTTPResponse(200))
            })
        let outcome = try await stale.submit(
            formData: [:], request: fixture.request, pendingRecord: record,
            scope: fixture.scope, assetId: "asset",
            isCurrent: { state.isCurrent })
        guard case .sessionChanged = outcome else {
            Issue.record("Expected the stale session to be rejected")
            return
        }
        #expect(try fixture.store.contains(record))

        let replaced = PendingFormSubmission(
            store: fixture.store,
            transport: { _ in
                try await MainActor.run {
                    _ = try fixture.store.save(testForm("asset", savedAt: 1), for: fixture.scope)
                }
                return (testFormReceipt("asset"), testHTTPResponse(200))
            })
        let replacementOutcome = try await replaced.submit(
            formData: [:], request: fixture.request, pendingRecord: record,
            scope: fixture.scope, assetId: "asset", isCurrent: { true })
        guard case .submitted = replacementOutcome else {
            Issue.record("Expected a successful submission")
            return
        }
        let newRecord = try #require(try fixture.store.record(assetId: "asset", for: fixture.scope))
        #expect(newRecord.id != record.id)
    }

    @Test
    func successfulSendReportsRecoveryCleanupFailure() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let corrupt = Data("{invalid".utf8)
        let submission = PendingFormSubmission(
            store: fixture.store,
            transport: { _ in
                try await MainActor.run { try corrupt.write(to: fixture.storageURL) }
                return (testFormReceipt("asset"), testHTTPResponse(200))
            })
        let outcome = try await submission.submit(
            formData: [:], request: fixture.request, pendingRecord: record,
            scope: fixture.scope, assetId: "asset", isCurrent: { true })
        guard case .submittedRecoveryNotCleared = outcome else {
            Issue.record("Expected a recovery cleanup failure")
            return
        }
        #expect(try Data(contentsOf: fixture.storageURL) == corrupt)
    }
}

struct TranscriptDeliveryTests {
    nonisolated private struct Payload: Decodable, Sendable {
        let transcript: String
        let segments: [TranscriptSegment]
        let clipId: String
    }
}

@MainActor
private func testAuth(userId: String = "user-1", serverURL: URL? = nil) -> AuthService {
    let auth = AuthService(storage: .memory, serverURL: { serverURL ?? ServerConfig.baseURL })
    auth.token = "test-session-token"
    auth.currentUser = User(
        id: userId, phoneNumber: "5550100", name: "Reporter", email: nil, team: nil,
        status: "ACTIVE", companyCode: nil, companyName: nil)
    return auth
}

@MainActor
private final class PhotoPreparationGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private let started = AsyncStream<Void>.makeStream()

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.continuation.yield(())
        }
    }

    func waitForStart() async throws {
        if continuation != nil { return }
        let stream = started.stream
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw RecoveryGateTimeout()
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    func finish(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

nonisolated private enum PhotoPreparationTestError: Error {
    case saveFailed
    case fingerprintFailed
}

@MainActor
struct TrimSourceLeaseTests {
    @Test
    func sourceIsRemovedOnlyAfterEveryReaderFinishes() {
        let url = URL(fileURLWithPath: "/tmp/trim-source.mov")
        var removed: [URL] = []
        let leases = TrimSourceLeases { removed.append($0) }
        leases.acquire(url)
        leases.acquire(url)
        leases.removeWhenUnused(url)
        #expect(removed.isEmpty)
        leases.release(url)
        #expect(leases.hasReaders(url))
        #expect(removed.isEmpty)
        leases.release(url)
        #expect(!leases.hasReaders(url))
        #expect(removed == [url])
    }

    @Test
    func fullLengthHandoffWaitsForReadersWithoutRemovingSource() async {
        let url = URL(fileURLWithPath: "/tmp/full-length.mov")
        var removed: [URL] = []
        let leases = TrimSourceLeases { removed.append($0) }
        leases.acquire(url)
        var completed = false
        let handoff = Task { @MainActor in
            await leases.waitUntilUnused(url)
            completed = true
            return !leases.hasReaders(url)
        }
        for _ in 0..<1_000 where !leases.isWaitingUntilUnused(url) {
            await Task.yield()
        }
        #expect(leases.isWaitingUntilUnused(url))
        #expect(!completed)
        #expect(leases.hasReaders(url))
        leases.release(url)
        #expect(await handoff.value)
        #expect(removed.isEmpty)
    }
}

struct VideoLibraryAutoConfirmTests {
    @Test
    func pickerCopyRequiresASeparateConfirmationAfterLoading() {
        #expect(VideoLibraryAutoConfirm.decision(
            isPending: true, isLoading: false, isReady: true,
            usedPickerCopy: true, canPresent: true) == .reviewPickerCopy)
        #expect(VideoLibraryAutoConfirm.decision(
            isPending: true, isLoading: false, isReady: true,
            usedPickerCopy: true, canPresent: false) == .reviewPickerCopy)
    }

    @Test
    func originalWaitsForAnActiveUnobstructedPresentation() {
        #expect(VideoLibraryAutoConfirm.decision(
            isPending: true, isLoading: true, isReady: false,
            usedPickerCopy: false, canPresent: true) == .wait)
        #expect(VideoLibraryAutoConfirm.decision(
            isPending: true, isLoading: false, isReady: true,
            usedPickerCopy: false, canPresent: false) == .wait)
        #expect(VideoLibraryAutoConfirm.decision(
            isPending: true, isLoading: false, isReady: true,
            usedPickerCopy: false, canPresent: true) == .openTrim)
        #expect(VideoLibraryAutoConfirm.decision(
            isPending: true, isLoading: false, isReady: false,
            usedPickerCopy: false, canPresent: true) == .stop)
    }
}

@MainActor
private final class DelayedProgressTransfer: VideoUploadTransfer {
    private let started = AsyncStream<Void>.makeStream()
    private var completion: CheckedContinuation<Void, Never>?
    private var progress: (@MainActor (Double) -> Void)?

    func upload(
        request: URLRequest, fileURL: URL, isCurrent: @MainActor () -> Bool,
        validateBeforeTransfer: (@MainActor () throws -> Void)?,
        onProgress: @escaping @MainActor (Double) -> Void,
        onStart: @MainActor () -> Void
    ) async throws -> (Data, URLResponse) {
        try validateBeforeTransfer?()
        progress = onProgress
        onStart()
        await withCheckedContinuation { continuation in
            completion = continuation
            started.continuation.yield(())
        }
        return (Data(), testHTTPResponse(200))
    }

    func waitForStart() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func publish(_ value: Double) {
        progress?(value)
    }

    func finish() {
        completion?.resume()
        completion = nil
        started.continuation.finish()
    }
}

@MainActor
private final class PhotoPreparationTestState {
    var events: [String] = []
    var saveCalls = 0
    var createCalls = 0
    var muxCalls = 0
    var fingerprintCalls = 0
    var identifier: String? = "saved-photo"
    var shouldFailSave = false
    var shouldFailFingerprint = false
    var shouldFailCreation = false
    var creationStatus: Int?
    var muxError: URLError?
    var saveError: (any Error)?
    var muxUploadURL: URL?
    var createUploadMode: Asset.AssetUploadMode? = .mux
    var savedURL: URL?
    var savedFileName: String?
    var savedMetadata: VideoMetadata?
    var onAuthorization: (() async -> Bool)?
    var onSave: (() async -> String?)?
    var onFingerprint: ((URL) async throws -> VideoContentFingerprint)?
    var onCreate: (() async throws -> Void)?
    var onMux: (() async -> Void)?

    func requestAuthorization() async -> Bool {
        events.append("authorization")
        return await onAuthorization?() ?? true
    }

    func save(_ url: URL, fileName: String, metadata: VideoMetadata) async throws -> String? {
        events.append("photos")
        saveCalls += 1
        savedURL = url
        savedFileName = fileName
        savedMetadata = metadata
        if let saveError { throw saveError }
        if shouldFailSave { throw PhotoPreparationTestError.saveFailed }
        if let onSave { return await onSave() }
        return identifier
    }

    func fingerprint(_ url: URL) async throws -> VideoContentFingerprint {
        events.append("fingerprint")
        fingerprintCalls += 1
        if shouldFailFingerprint { throw PhotoPreparationTestError.fingerprintFailed }
        if let onFingerprint { return try await onFingerprint(url) }
        return try await VideoContentFingerprint.calculate(for: url)
    }

    func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/errors") { return (Data(), testHTTPResponse(200)) }
        if path.hasSuffix("/assets") {
            events.append("create")
            createCalls += 1
            if shouldFailCreation { throw CancellationError() }
            if let creationStatus { return (Data(), testHTTPResponse(creationStatus)) }
            try await onCreate?()
            let body = try JSONDecoder().decode(CreateAssetRequest.self, from: request.httpBody ?? Data())
            let id = (body.fileName as NSString).deletingPathExtension
            return (testAssetData(id: id, owner: "user-1", uploadMode: createUploadMode), testHTTPResponse(200))
        }
        if path.hasSuffix("/mux-upload") {
            events.append("mux")
            muxCalls += 1
            await onMux?()
            if let muxError { throw muxError }
            if let muxUploadURL {
                let data = try JSONSerialization.data(withJSONObject: [
                    "uploadUrl": muxUploadURL.absoluteString,
                    "clipId": "clip",
                    "muxUploadId": "synthetic",
                ])
                return (data, testHTTPResponse(200))
            }
            return (Data(), testHTTPResponse(503))
        }
        throw URLError(.badURL)
    }

    func model(
        fixture: FormTestFixture, auth: AuthService,
        formPresentation: FormPresentationState = FormPresentationState(),
        associationStore: ScopedPHAssetIdentifierStore? = nil,
        videoTransfer: (any VideoUploadTransfer)? = nil
    ) -> ChatViewModel {
        ChatViewModel(
            auth: auth, ws: WebSocketService(), formPresentation: formPresentation,
            pendingFormStore: fixture.store,
            httpTransport: { try await self.transport($0) },
            videoTransfer: videoTransfer,
            thumbnailGenerator: { _ in nil },
            photoAssociationStore: associationStore
                ?? ScopedPHAssetIdentifierStore(directory: fixture.directory),
            requestPhotoAddAccess: { await self.requestAuthorization() },
            saveTrimToPhotos: { url, fileName, metadata in
                try await self.save(url, fileName: fileName, metadata: metadata)
            },
            fingerprintVideo: { try await self.fingerprint($0) })
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PhotosFirstStagingTests {
    private let metadata = VideoMetadata(
        duration: 7, resolution: "test", codec: "test", orientation: "landscape",
        deviceModel: "test", osVersion: "test", capturedAt: "2026-05-10T12:00:00Z",
        gpsLat: 40.7, gpsLon: -74.0, gpsAltitude: 10)

    private func stage(
        _ vm: ChatViewModel, fixture: FormTestFixture, name: String = "trim.mov",
        trimmed: Bool = true, identifier: String? = nil
    ) async throws -> (URL, UUID) {
        let url = fixture.directory.appendingPathComponent(name)
        try Data("video-\(name)".utf8).write(to: url)
        await vm.stageVideo(
            fileURL: url, fileName: name, metadata: metadata,
            phAssetIdentifier: identifier, isTrimmed: trimmed).value
        return (url, try #require(vm.stagedVideo?.id))
    }

    @Test
    func savesTrimAndScopedAssociationBeforeRequestingMuxUpload() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let auth = testAuth()
        let state = PhotoPreparationTestState()
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let vm = state.model(fixture: fixture, auth: auth, associationStore: store)
        let (url, id) = try await stage(vm, fixture: fixture)
        let expected = try await VideoContentFingerprint.calculate(for: url)
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        state.onMux = {
            do {
                let association = try #require(try store.association(assetId: "trim", for: scope))
                #expect(association.photoIdentifier == "saved-photo")
                #expect(association.fingerprint == expected)
                #expect(association.metadata == metadata)
            } catch {
                Issue.record("Association was not available before the Mux request: \(error)")
            }
        }
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.events.prefix(5) == ["authorization", "photos", "fingerprint", "create", "mux"])
        #expect(state.savedURL == url)
        #expect(state.savedFileName == "trim.mov")
        #expect(state.savedMetadata?.duration == 7)
        #expect(state.savedMetadata?.capturedAt == metadata.capturedAt)
        #expect(state.savedMetadata?.gpsLat == metadata.gpsLat)
        #expect(state.savedMetadata?.gpsLon == metadata.gpsLon)
        let association = try #require(try store.association(assetId: "trim", for: scope))
        #expect(association.photoIdentifier == "saved-photo")
        #expect(association.fingerprint == expected)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func failedSaveRetainsPreviewAndRetryDoesNotContactServerEarly() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        state.shouldFailSave = true
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (url, id) = try await stage(vm, fixture: fixture)
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.createCalls == 0)
        #expect(vm.stagedVideo?.id == id)
        #expect(FileManager.default.fileExists(atPath: url.path))
        guard case .failed = vm.stagedUploadPreparation else {
            Issue.record("Expected an actionable Photos save failure")
            return
        }
        state.shouldFailSave = false
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.saveCalls == 2)
        #expect(state.createCalls == 1)
    }

    @Test
    func deniedPhotosAccessKeepsPreviewAndAllowsRetry() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        state.onAuthorization = { false }
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (url, id) = try await stage(vm, fixture: fixture)
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.saveCalls == 0)
        #expect(state.createCalls == 0)
        #expect(vm.stagedVideo?.id == id)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(vm.stagedUploadPreparation == .photoAccessDenied)
        #expect(vm.stagedUploadPreparation.message?.contains("Settings") == true)
        state.onAuthorization = { true }
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.saveCalls == 1)
        #expect(state.createCalls == 1)
    }

    @Test
    func failedAssetCreationRetriesWithoutSavingAnotherPhotosCopy() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        state.shouldFailCreation = true
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (url, id) = try await stage(vm, fixture: fixture)
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(vm.stagedVideo?.id == id)
        #expect(vm.stagedVideo?.isSavedToPhotos == true)
        #expect(FileManager.default.fileExists(atPath: url.path))
        state.shouldFailCreation = false
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.saveCalls == 1)
        #expect(state.fingerprintCalls == 1)
        #expect(state.createCalls == 2)
    }

    @Test
    func fingerprintFailureRetriesWithoutSavingTheTrimAgain() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        state.shouldFailFingerprint = true
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (url, id) = try await stage(vm, fixture: fixture)
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.createCalls == 0)
        #expect(vm.stagedVideo?.isSavedToPhotos == true)
        #expect(FileManager.default.fileExists(atPath: url.path))
        state.shouldFailFingerprint = false
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.saveCalls == 1)
        #expect(state.fingerprintCalls == 2)
        #expect(state.createCalls == 1)
    }

    @Test
    func fingerprintFailureAllowsExplicitManualRecoveryWithoutResaving() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        state.shouldFailFingerprint = true
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let vm = state.model(fixture: fixture, auth: testAuth(), associationStore: store)
        let (_, id) = try await stage(vm, fixture: fixture)
        await vm.confirmStagedUpload(id: id, transcribe: false, acceptManualPhotoSelection: true)
        #expect(vm.stagedUploadPreparation == .manualFingerprintSelectionRequired)
        #expect(state.createCalls == 0)
        await vm.confirmStagedUpload(id: id, transcribe: false, acceptManualPhotoSelection: true)
        #expect(state.saveCalls == 1)
        #expect(state.fingerprintCalls == 1)
        #expect(state.createCalls == 1)
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        #expect(try store.association(assetId: "trim", for: scope) == nil)
    }

    @Test
    func photosStorageErrorExplainsTheActualFailure() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        state.saveError = NSError(
            domain: PHPhotosErrorDomain, code: PHPhotosError.Code.notEnoughSpace.rawValue)
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (_, id) = try await stage(vm, fixture: fixture)
        await vm.confirmStagedUpload(id: id, transcribe: false)
        guard case .failed(let message) = vm.stagedUploadPreparation else {
            Issue.record("Expected an actionable storage error")
            return
        }
        #expect(message.contains("storage"))
        #expect(state.createCalls == 0)
    }

    @Test
    func realServerStartFailureKeepsTheSavedTrimForRetry() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        state.creationStatus = 503
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (url, id) = try await stage(vm, fixture: fixture)
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.createCalls == 3)
        #expect(state.muxCalls == 0)
        #expect(vm.stagedVideo?.isSavedToPhotos == true)
        #expect(FileManager.default.fileExists(atPath: url.path))
        guard case .failed(let message) = vm.stagedUploadPreparation else {
            Issue.record("Expected an actionable upload-start error on the preview")
            return
        }
        #expect(message.contains("Retry"))
        #expect(!vm.messages.contains { $0.content.code == "IOS_UPLOAD_START_FAILED" })
        state.creationStatus = nil
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.saveCalls == 1)
        #expect(state.createCalls == 4)
    }

    @Test
    func networkFailureIsTerminalAndProvidesArchiveRecovery() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let presentation = FormPresentationState()
        state.muxError = URLError(.notConnectedToInternet)
        let vm = state.model(fixture: fixture, auth: testAuth(), formPresentation: presentation)
        let (_, id) = try await stage(vm, fixture: fixture, name: "offline.mov", trimmed: false)
        await vm.confirmStagedUpload(id: id, transcribe: false)

        let notice = try #require(vm.messages.first { $0.content.code == "IOS_UPLOAD_FAILED" })
        #expect(notice.displayText.contains("Archive"))
        #expect(notice.displayText.contains("Connection interrupted"))
        #expect(notice.content.params?["uploadRevision"] == "0")
        #expect(!vm.messages.contains { $0.content.code == "IOS_CONNECTIVITY_BLOCKING" })
        #expect(vm.uploadHasFailed(assetId: "offline"))
        #expect(VideoBubblePhase.resolve(
            isUploading: false, hasFailed: vm.uploadHasFailed(assetId: "offline"),
            isReady: false) == .failed)

        presentation.markUploadRecovered(assetId: "offline")
        #expect(!vm.uploadHasFailed(assetId: "offline"))
        #expect(!presentation.shouldAnnounceRecoveryNotice(
            code: notice.content.code, assetId: notice.assetId, params: notice.content.params))
    }

    @Test
    func successfulRetryClearsTheEarlierStartFailureForThatPreview() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let presentation = FormPresentationState()
        let gate = PhotoPreparationGate<Bool>()
        state.onCreate = {
            if state.createCalls == 1 { _ = await gate.wait() }
            throw URLError(.cannotConnectToHost)
        }
        let vm = state.model(fixture: fixture, auth: testAuth(), formPresentation: presentation)
        let (_, id) = try await stage(vm, fixture: fixture, name: "retry-start.mov", trimmed: false)
        let task = Task { await vm.confirmStagedUpload(id: id, transcribe: false) }
        defer { gate.finish(false); task.cancel() }
        try await gate.waitForStart()
        vm.beginVideoSelection()
        gate.finish(true)
        await task.value

        let notice = try #require(vm.messages.first {
            $0.content.code == "IOS_PREVIOUS_UPLOAD_START_FAILED"
        })
        #expect(notice.displayText.contains("Retry its preview"))
        #expect(vm.stagedVideo?.id == id)
        vm.endVideoSelection()
        state.onCreate = nil
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(!vm.messages.contains { $0.id == notice.id })
        #expect(!presentation.shouldAnnounceRecoveryNotice(
            code: notice.content.code, assetId: notice.assetId, params: notice.content.params))
    }

    @Test
    func aNewServerFailureAfterRecoveryProducesANewNotice() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let presentation = FormPresentationState()
        let data = Data(#"{"asset":{"id":"asset","status":"ERROR"}}"#.utf8)
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), formPresentation: presentation,
            pendingFormStore: fixture.store,
            httpTransport: { _ in (data, testHTTPResponse(200)) })
        vm.currentAssetId = "asset"
        await vm.fetchAssetDetail(assetId: "asset")
        let earlier = try #require(vm.messages.first { $0.content.code == "IOS_UPLOAD_FAILED" })
        #expect(vm.uploadHasFailed(assetId: "asset"))
        presentation.markUploadRecovered(assetId: "asset")
        #expect(!vm.uploadHasFailed(assetId: "asset"))

        await vm.fetchAssetDetail(assetId: "asset")
        let failures = vm.messages.filter { $0.content.code == "IOS_UPLOAD_FAILED" }
        #expect(failures.count == 2)
        let later = try #require(failures.last)
        #expect(later.content.params?["uploadRevision"] == "1")
        #expect(vm.uploadHasFailed(assetId: "asset"))
        #expect(!presentation.shouldAnnounceRecoveryNotice(
            code: earlier.content.code, assetId: earlier.assetId, params: earlier.content.params))
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: later.content.code, assetId: later.assetId, params: later.content.params))
    }

    @Test(arguments: [200, 503])
    func staleAssetLookupCannotPublishAfterRecovery(status: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let gate = RecoveryResponseTestGate()
        let presentation = FormPresentationState()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), formPresentation: presentation,
            pendingFormStore: fixture.store,
            httpTransport: { _ in await gate.waitForResponse() })
        vm.currentAssetId = "asset"
        let task = Task { await vm.fetchAssetDetail(assetId: "asset") }
        defer { gate.finish(status: status); task.cancel() }
        try await gate.waitForStart()
        presentation.markUploadRecovered(assetId: "asset")
        gate.finish(data: Data(#"{"asset":{"id":"asset","status":"ERROR"}}"#.utf8), status: status)
        await task.value

        #expect(vm.lastAsset == nil)
        #expect(!vm.uploadHasFailed(assetId: "asset"))
        #expect(!vm.messages.contains {
            $0.content.code == "IOS_UPLOAD_FAILED" || $0.content.code == "IOS_ASSET_DETAILS_LOAD_FAILED"
        })
    }

    @Test
    func missingPhotoIdentifierRequiresExplicitContinuationWithoutDuplicateSave() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        state.identifier = nil
        state.shouldFailCreation = true
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (_, id) = try await stage(vm, fixture: fixture)
        await vm.confirmStagedUpload(id: id, transcribe: false, acceptManualPhotoSelection: true)
        #expect(vm.stagedUploadPreparation == .manualPhotoSelectionRequired)
        #expect(state.createCalls == 0)
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.createCalls == 0)
        await vm.confirmStagedUpload(id: id, transcribe: false, acceptManualPhotoSelection: true)
        #expect(state.createCalls == 1)
        state.shouldFailCreation = false
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.saveCalls == 1)
        #expect(state.fingerprintCalls == 0)
        #expect(state.createCalls == 2)
    }

    @Test
    func cancellationDuringPermissionDoesNotSubmitPhotosOrServerRequest() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let gate = PhotoPreparationGate<Bool>()
        state.onAuthorization = { await gate.wait() }
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (url, id) = try await stage(vm, fixture: fixture)
        let task = Task { await vm.confirmStagedUpload(id: id, transcribe: false) }
        defer { gate.finish(false); task.cancel() }
        try await gate.waitForStart()
        vm.cancelStagedVideo(id: id)
        #expect(FileManager.default.fileExists(atPath: url.path))
        gate.finish(true)
        await task.value
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(state.saveCalls == 0)
        #expect(state.createCalls == 0)
        #expect(vm.stagedVideo == nil)
    }

    @Test
    func cancelledCallerKeepsPreviewRetryableBeforePhotosIsSubmitted() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let gate = PhotoPreparationGate<Bool>()
        state.onAuthorization = { await gate.wait() }
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (url, id) = try await stage(vm, fixture: fixture)
        let task = Task { await vm.confirmStagedUpload(id: id, transcribe: false) }
        defer { gate.finish(false); task.cancel() }
        try await gate.waitForStart()
        task.cancel()
        gate.finish(true)
        await task.value
        #expect(state.saveCalls == 0)
        #expect(state.createCalls == 0)
        #expect(vm.stagedVideo?.id == id)
        #expect(FileManager.default.fileExists(atPath: url.path))
        guard case .failed = vm.stagedUploadPreparation else {
            Issue.record("Expected an interrupted, retryable preview")
            return
        }
        vm.cancelStagedVideo(id: id)
    }

    @Test
    func cancelledCallerRecordsSuccessfulPhotosTransactionBeforeRetrying() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let gate = PhotoPreparationGate<String?>()
        var transactionWasCancelled = true
        state.onSave = {
            let identifier = await gate.wait()
            transactionWasCancelled = Task.isCancelled
            return Task.isCancelled ? nil : identifier
        }
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (url, id) = try await stage(vm, fixture: fixture)
        let task = Task { await vm.confirmStagedUpload(id: id, transcribe: false) }
        defer { gate.finish(nil); task.cancel() }
        try await gate.waitForStart()
        task.cancel()
        #expect(FileManager.default.fileExists(atPath: url.path))
        gate.finish("saved-photo")
        await task.value
        #expect(!transactionWasCancelled)
        #expect(vm.stagedVideo?.isSavedToPhotos == true)
        #expect(vm.stagedVideo?.savedPhotoIdentifier == "saved-photo")
        #expect(state.createCalls == 0)
        guard case .failed = vm.stagedUploadPreparation else {
            Issue.record("Expected an interrupted, retryable preview")
            return
        }
        state.onSave = nil
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(state.saveCalls == 1)
        #expect(state.createCalls == 1)
    }

    @Test
    func duplicateConfirmationAndLateCancelledSaveDoNotStartAnUpload() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let gate = PhotoPreparationGate<String?>()
        state.onSave = { await gate.wait() }
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (url, id) = try await stage(vm, fixture: fixture)
        let first = Task { await vm.confirmStagedUpload(id: id, transcribe: false) }
        defer { gate.finish(nil); first.cancel() }
        try await gate.waitForStart()
        await vm.confirmStagedUpload(id: id, transcribe: true)
        #expect(state.saveCalls == 1)
        #expect(state.createCalls == 0)
        vm.cancelStagedVideo(id: id)
        #expect(FileManager.default.fileExists(atPath: url.path))
        gate.finish("saved-photo")
        await first.value
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(vm.stagedVideo == nil)
        #expect(state.createCalls == 0)
    }

    @Test
    func sessionChangeInvalidatesStageButLeasesFileUntilPhotosReturns() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let auth = testAuth()
        let state = PhotoPreparationTestState()
        let gate = PhotoPreparationGate<String?>()
        state.onSave = { await gate.wait() }
        let vm = state.model(fixture: fixture, auth: auth)
        let (url, id) = try await stage(vm, fixture: fixture)
        let task = Task { await vm.confirmStagedUpload(id: id, transcribe: false) }
        defer { gate.finish(nil); task.cancel() }
        try await gate.waitForStart()
        auth.logout()
        #expect(vm.invalidateIfSessionChanged())
        #expect(vm.stagedVideo == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        gate.finish("saved-photo")
        await task.value
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(state.createCalls == 0)
    }

    @Test
    func removingStageCancelsFingerprintButRetainsFileUntilReaderReturns() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let gate = PhotoPreparationGate<Bool>()
        var observedCancellation = false
        state.onFingerprint = { url in
            _ = await gate.wait()
            observedCancellation = Task.isCancelled
            try Task.checkCancellation()
            return try await VideoContentFingerprint.calculate(for: url)
        }
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (url, id) = try await stage(vm, fixture: fixture)
        let task = Task { await vm.confirmStagedUpload(id: id, transcribe: false) }
        defer { gate.finish(false); task.cancel() }
        try await gate.waitForStart()
        vm.cancelStagedVideo(id: id)
        #expect(FileManager.default.fileExists(atPath: url.path))
        gate.finish(true)
        await task.value
        #expect(observedCancellation)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(state.createCalls == 0)
    }

    @Test
    func cancellingConfirmationCancelsInFlightAssetCreation() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let gate = PhotoPreparationGate<Bool>()
        var observedCancellation = false
        state.onCreate = {
            _ = await gate.wait()
            observedCancellation = Task.isCancelled
            try Task.checkCancellation()
        }
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (url, id) = try await stage(vm, fixture: fixture, trimmed: false)
        let task = Task { await vm.confirmStagedUpload(id: id, transcribe: false) }
        defer { gate.finish(false); task.cancel() }
        try await gate.waitForStart()
        task.cancel()
        #expect(FileManager.default.fileExists(atPath: url.path))
        gate.finish(true)
        await task.value
        #expect(observedCancellation)
        #expect(state.muxCalls == 0)
        #expect(vm.stagedVideo?.id == id)
        vm.cancelStagedVideo(id: id)
    }

    @Test
    func replacingStageDuringSaveCannotReviveIt() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let gate = PhotoPreparationGate<String?>()
        state.onSave = { await gate.wait() }
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (oldURL, oldID) = try await stage(vm, fixture: fixture, name: "old.mov")
        let task = Task { await vm.confirmStagedUpload(id: oldID, transcribe: false) }
        defer { gate.finish(nil); task.cancel() }
        try await gate.waitForStart()
        let (newURL, newID) = try await stage(vm, fixture: fixture, name: "new.mov")
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        gate.finish("saved-photo")
        await task.value
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        #expect(vm.stagedVideo?.id == newID)
        #expect(state.createCalls == 0)
        vm.cancelStagedVideo(id: newID)
    }

    @Test
    func savingNewTrimDoesNotResetAnEarlierActiveUpload() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let muxGate = PhotoPreparationGate<Bool>()
        let photoGate = PhotoPreparationGate<String?>()
        state.onMux = { _ = await muxGate.wait() }
        state.onSave = { await photoGate.wait() }
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (oldURL, oldID) = try await stage(
            vm, fixture: fixture, name: "first.mov", trimmed: false)
        let oldTask = Task { await vm.confirmStagedUpload(id: oldID, transcribe: false) }
        defer { muxGate.finish(true); photoGate.finish(nil); oldTask.cancel() }
        try await muxGate.waitForStart()
        #expect(vm.currentAssetId == "first")
        #expect(vm.isUploading)
        let (newURL, newID) = try await stage(vm, fixture: fixture, name: "second.mov")
        let newTask = Task { await vm.confirmStagedUpload(id: newID, transcribe: false) }
        defer { newTask.cancel() }
        try await photoGate.waitForStart()
        #expect(vm.currentAssetId == "first")
        #expect(vm.isUploading)
        #expect(state.createCalls == 1)
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        vm.cancelStagedVideo(id: newID)
        photoGate.finish("saved-photo")
        await newTask.value
        #expect(!FileManager.default.fileExists(atPath: newURL.path))
        muxGate.finish(true)
        await oldTask.value
    }

    @Test
    func earlierUploadFailureSurvivesNewTrimPreflightAndConversationReset() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let muxGate = PhotoPreparationGate<Bool>()
        let photoGate = PhotoPreparationGate<String?>()
        state.onMux = { _ = await muxGate.wait() }
        state.onSave = { await photoGate.wait() }
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (_, oldID) = try await stage(vm, fixture: fixture, name: "first.mov", trimmed: false)
        let oldTask = Task { await vm.confirmStagedUpload(id: oldID, transcribe: false) }
        defer { muxGate.finish(true); photoGate.finish(nil); oldTask.cancel() }
        try await muxGate.waitForStart()
        let (_, newID) = try await stage(vm, fixture: fixture, name: "second.mov")
        let newTask = Task { await vm.confirmStagedUpload(id: newID, transcribe: false) }
        defer { newTask.cancel() }
        try await photoGate.waitForStart()
        muxGate.finish(true)
        await oldTask.value
        #expect(vm.messages.contains {
            $0.content.code == "IOS_PREVIOUS_UPLOAD_FAILED"
                && $0.content.text?.contains("first.mov") == true
        })
        state.onMux = nil
        photoGate.finish("saved-photo")
        await newTask.value
        #expect(vm.currentAssetId == "second")
        #expect(vm.messages.contains {
            $0.content.code == "IOS_PREVIOUS_UPLOAD_FAILED"
                && $0.content.text?.contains("first.mov") == true
        })
    }

    @Test
    func activeChatUploadStaysClaimedUntilCancellationCompletes() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let presentation = FormPresentationState()
        let gate = PhotoPreparationGate<Bool>()
        state.onMux = { _ = await gate.wait() }
        let vm = state.model(fixture: fixture, auth: testAuth(), formPresentation: presentation)
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let (_, id) = try await stage(vm, fixture: fixture, name: "active.mov", trimmed: false)
        let task = Task { await vm.confirmStagedUpload(id: id, transcribe: false) }
        defer { gate.finish(true); task.cancel() }
        try await gate.waitForStart()
        #expect(presentation.isChatUploading(assetId: "active", scope: scope))
        vm.cancelUpload()
        #expect(presentation.isChatUploading(assetId: "active", scope: scope))
        gate.finish(true)
        await task.value
        #expect(!presentation.isChatUploading(assetId: "active", scope: scope))
        #expect(presentation.failedChatUploadAssetIDs.contains("active"))
    }

    @Test(arguments: [nil, Asset.AssetUploadMode.original, .unknown])
    func unverifiedNewAssetDoesNotStartMuxUpload(mode: Asset.AssetUploadMode?) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        state.createUploadMode = mode
        let vm = state.model(fixture: fixture, auth: testAuth())
        let (_, id) = try await stage(vm, fixture: fixture, name: "unverified.mov", trimmed: false)

        await vm.confirmStagedUpload(id: id, transcribe: false)

        #expect(state.createCalls == 1)
        #expect(state.muxCalls == 0)
        #expect(vm.messages.contains { $0.content.code == "IOS_UPLOAD_MODE_UNAVAILABLE" })
        #expect(vm.stagedVideo?.id == id)
    }

    @Test
    func cancelledUploadIgnoresProgressUntilItsTransferFinishes() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        state.muxUploadURL = URL(string: "https://uploads.example.test/video")!
        let transfer = DelayedProgressTransfer()
        let vm = state.model(fixture: fixture, auth: testAuth(), videoTransfer: transfer)
        let (_, id) = try await stage(vm, fixture: fixture, name: "active.mov", trimmed: false)
        let task = Task { await vm.confirmStagedUpload(id: id, transcribe: false) }
        defer { transfer.finish(); task.cancel() }
        await transfer.waitForStart()

        transfer.publish(0.4)
        for _ in 0..<50 where vm.uploadProgress != 0.4 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(vm.uploadProgress == 0.4)
        vm.cancelUpload()
        transfer.publish(0.9)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!vm.isUploading)
        #expect(vm.uploadProgress == 0)

        transfer.finish()
        await task.value
    }

    @Test
    func successfulBackgroundPutRetainsSourceUntilServerResponds() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let baseURL = try await server.start()
        let state = PhotoPreparationTestState()
        let presentation = FormPresentationState()
        state.muxUploadURL = URL(string: "https://uploads.example.test/video")!
        let vm = state.model(
            fixture: fixture, auth: testAuth(), formPresentation: presentation,
            videoTransfer: LoopbackVideoUploadTransfer(endpoint: baseURL.appendingPathComponent("upload")))
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let (url, id) = try await stage(vm, fixture: fixture, name: "actual-put.mov")
        let task = Task { await vm.confirmStagedUpload(id: id, transcribe: false) }
        defer { task.cancel() }
        let bytes = try await server.waitForUpload()
        #expect(bytes == Data("video-actual-put.mov".utf8))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(presentation.isChatUploading(assetId: "actual-put", scope: scope))
        #expect(server.completeUpload())
        await task.value
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!presentation.isChatUploading(assetId: "actual-put", scope: scope))
        #expect(!presentation.failedChatUploadAssetIDs.contains("actual-put"))
    }

    @Test
    func sessionChangeCancelsEveryOverlappingUploadAttempt() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let auth = testAuth()
        let state = PhotoPreparationTestState()
        let firstGate = PhotoPreparationGate<Bool>()
        let secondGate = PhotoPreparationGate<Bool>()
        var firstCancelled = false
        var secondCancelled = false
        state.onMux = {
            if state.muxCalls == 1 {
                _ = await firstGate.wait()
                firstCancelled = Task.isCancelled
            } else {
                _ = await secondGate.wait()
                secondCancelled = Task.isCancelled
            }
        }
        let vm = state.model(fixture: fixture, auth: auth)
        let (firstURL, firstID) = try await stage(
            vm, fixture: fixture, name: "first-cancel.mov", trimmed: false)
        let first = Task { await vm.confirmStagedUpload(id: firstID, transcribe: false) }
        defer { firstGate.finish(false); secondGate.finish(false); first.cancel() }
        try await firstGate.waitForStart()
        let (secondURL, secondID) = try await stage(
            vm, fixture: fixture, name: "second-cancel.mov", trimmed: false)
        let second = Task { await vm.confirmStagedUpload(id: secondID, transcribe: false) }
        defer { second.cancel() }
        try await secondGate.waitForStart()
        auth.logout()
        #expect(vm.invalidateIfSessionChanged())
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        firstGate.finish(true)
        secondGate.finish(true)
        await first.value
        await second.value
        #expect(firstCancelled)
        #expect(secondCancelled)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
    }

    @Test
    func corruptAssociationIsPreservedAndUserIsToldToSelectManually() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let storeURL = try store.storageURL(for: scope)
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: storeURL)
        let vm = state.model(fixture: fixture, auth: testAuth(), associationStore: store)
        let (_, id) = try await stage(vm, fixture: fixture)
        await vm.confirmStagedUpload(id: id, transcribe: false)
        #expect(try Data(contentsOf: storeURL) == corrupt)
        #expect(state.muxCalls == 1)
        #expect(vm.messages.contains { $0.content.code == "IOS_PHOTO_ASSOCIATION_SAVE_FAILED" })
    }

    @Test
    func untrimmedOriginalAlsoGetsScopedFingerprintWithoutSavingToPhotos() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = PhotoPreparationTestState()
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let vm = state.model(fixture: fixture, auth: testAuth(), associationStore: store)
        let (url, id) = try await stage(
            vm, fixture: fixture, name: "original.mov", trimmed: false, identifier: "original-photo")
        let expected = try await VideoContentFingerprint.calculate(for: url)
        await vm.confirmStagedUpload(id: id, transcribe: false)
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let association = try #require(try store.association(assetId: "original", for: scope))
        #expect(association.photoIdentifier == "original-photo")
        #expect(association.fingerprint == expected)
        #expect(state.saveCalls == 0)
    }
}

@MainActor
@Suite(.serialized)
struct VideoStagingTests {
    private let metadata = VideoMetadata(
        duration: 1, resolution: "test", codec: "test", orientation: "landscape",
        deviceModel: "test", osVersion: "test", capturedAt: nil,
        gpsLat: nil, gpsLon: nil, gpsAltitude: nil)

    @Test
    func stalePreviewActionsCannotUploadOrCancelReplacement() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let gate = ThumbnailTestGate()
        defer { gate.finishAll() }
        let state = FormTestState()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run { state.calls += 1 }
                throw CancellationError()
            }, thumbnailGenerator: { await gate.generate($0) })
        let fileA = fixture.directory.appendingPathComponent("a.mov")
        let fileB = fixture.directory.appendingPathComponent("b.mov")
        try Data("a".utf8).write(to: fileA)
        try Data("b".utf8).write(to: fileB)

        let first = vm.stageVideo(
            fileURL: fileA, fileName: "a.mov", metadata: metadata, phAssetIdentifier: "photos-a")
        await gate.waitForStart("a.mov")
        gate.finish("a.mov")
        await first.value
        let stagedA = try #require(vm.stagedVideo)

        let second = vm.stageVideo(
            fileURL: fileB, fileName: "b.mov", metadata: metadata, phAssetIdentifier: "photos-b")
        await gate.waitForStart("b.mov")
        await vm.confirmStagedUpload(id: stagedA.id, transcribe: true)
        #expect(state.calls == 0)
        #expect(vm.stagedVideo == nil)
        #expect(vm.isProcessingVideo)
        gate.finish("b.mov")
        await second.value
        let stagedB = try #require(vm.stagedVideo)
        #expect(stagedB.id != stagedA.id)
        #expect(stagedB.phAssetIdentifier == "photos-b")
        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        vm.cancelStagedVideo(id: stagedA.id)
        #expect(vm.stagedVideo?.id == stagedB.id)
        #expect(FileManager.default.fileExists(atPath: fileB.path))
    }

    @Test(arguments: [false, true])
    func supersededThumbnailCannotReplaceNewSelection(oldFinishesFirst: Bool) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let gate = ThumbnailTestGate()
        defer { gate.finishAll() }
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            thumbnailGenerator: { await gate.generate($0) })
        let fileA = fixture.directory.appendingPathComponent("a.mov")
        let fileB = fixture.directory.appendingPathComponent("b.mov")
        try Data("a".utf8).write(to: fileA)
        try Data("b".utf8).write(to: fileB)
        let first = vm.stageVideo(
            fileURL: fileA, fileName: "a.mov", metadata: metadata, phAssetIdentifier: "photos-a")
        await gate.waitForStart("a.mov")
        let second = vm.stageVideo(
            fileURL: fileB, fileName: "b.mov", metadata: metadata, phAssetIdentifier: "photos-b")
        await gate.waitForStart("b.mov")

        if oldFinishesFirst {
            gate.finish("a.mov")
            await first.value
            #expect(vm.isProcessingVideo)
            #expect(vm.stagedVideo == nil)
            gate.finish("b.mov")
            await second.value
        } else {
            gate.finish("b.mov")
            await second.value
            gate.finish("a.mov")
            await first.value
        }
        #expect(!vm.isProcessingVideo)
        #expect(vm.stagedVideo?.fileName == "b.mov")
        #expect(vm.stagedVideo?.phAssetIdentifier == "photos-b")
        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(FileManager.default.fileExists(atPath: fileB.path))
    }

    @Test
    func newPreviewKeepsItsOwnIdentifierWhileEarlierUploadStarts() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let gate = ThumbnailTestGate()
        defer { gate.finishAll() }
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                started.continuation.yield(())
                for await _ in release.stream { break }
                throw CancellationError()
            }, thumbnailGenerator: { await gate.generate($0) })
        let fileA = fixture.directory.appendingPathComponent("a.mov")
        let fileB = fixture.directory.appendingPathComponent("b.mov")
        try Data("a".utf8).write(to: fileA)
        try Data("b".utf8).write(to: fileB)
        let first = vm.stageVideo(
            fileURL: fileA, fileName: "a.mov", metadata: metadata, phAssetIdentifier: "photos-a")
        await gate.waitForStart("a.mov")
        gate.finish("a.mov")
        await first.value
        let stagedA = try #require(vm.stagedVideo)
        let upload = Task { await vm.confirmStagedUpload(id: stagedA.id, transcribe: true) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()

        let second = vm.stageVideo(
            fileURL: fileB, fileName: "b.mov", metadata: metadata, phAssetIdentifier: "photos-b")
        await gate.waitForStart("b.mov")
        gate.finish("b.mov")
        await second.value
        release.continuation.yield(())
        await upload.value
        #expect(vm.stagedVideo?.fileName == "b.mov")
        #expect(vm.stagedVideo?.phAssetIdentifier == "photos-b")
        #expect(FileManager.default.fileExists(atPath: fileB.path))
    }

    @Test(arguments: [false, true])
    func earlierUploadFailureRemainsVisibleAfterStartingAnotherUpload(
        creationFailure: Bool
    ) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let secondStarted = AsyncStream<Void>.makeStream()
        let secondRelease = AsyncStream<Void>.makeStream()
        let state = FormTestState()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { request in
                let path = request.url?.path ?? ""
                if path.hasSuffix("/errors") { return (Data(), testHTTPResponse(200)) }
                if path.hasSuffix("/assets") {
                    let body = try JSONDecoder().decode(
                        CreateAssetRequest.self, from: request.httpBody ?? Data())
                    let id = body.fileName == "first.mov" ? "first" : "second"
                    if id == "first", creationFailure {
                        let attempt = await MainActor.run {
                            state.calls += 1
                            return state.calls
                        }
                        if attempt == 1 {
                            started.continuation.yield(())
                            for await _ in release.stream { break }
                        }
                        return (Data(), testHTTPResponse(500))
                    }
                    return (testAssetData(id: id, owner: "user-1"), testHTTPResponse(200))
                }
                if path.hasSuffix("/second/mux-upload") {
                    secondStarted.continuation.yield(())
                    for await _ in secondRelease.stream { break }
                    throw CancellationError()
                }
                if path.hasSuffix("/first/mux-upload") {
                    started.continuation.yield(())
                    for await _ in release.stream { break }
                    return (Data(), testHTTPResponse(503))
                }
                Issue.record("Unexpected upload request")
                throw URLError(.badURL)
            })
        let firstURL = fixture.directory.appendingPathComponent("first.mov")
        let secondURL = fixture.directory.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        vm.stagedVideo = StagedVideo(
            tempFileURL: firstURL, fileName: "first.mov", createdDate: nil, thumbnail: nil,
            metadata: metadata, phAssetIdentifier: nil)
        let firstID = try #require(vm.stagedVideo?.id)
        let firstUpload = Task { await vm.confirmStagedUpload(id: firstID, transcribe: false) }
        defer {
            release.continuation.finish()
            secondRelease.continuation.finish()
            firstUpload.cancel()
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()

        vm.stagedVideo = StagedVideo(
            tempFileURL: secondURL, fileName: "second.mov", createdDate: nil, thumbnail: nil,
            metadata: metadata, phAssetIdentifier: nil)
        let secondID = try #require(vm.stagedVideo?.id)
        let secondUpload = Task { await vm.confirmStagedUpload(id: secondID, transcribe: false) }
        defer { secondUpload.cancel() }
        var secondIterator = secondStarted.stream.makeAsyncIterator()
        _ = await secondIterator.next()
        #expect(vm.currentAssetId == "second")
        #expect(vm.isUploading)

        release.continuation.yield(())
        await firstUpload.value
        let code = creationFailure
            ? "IOS_PREVIOUS_UPLOAD_START_FAILED" : "IOS_PREVIOUS_UPLOAD_FAILED"
        let notice = try #require(vm.messages.first { $0.content.code == code })
        #expect(notice.displayText.contains("first.mov"))
        #expect(notice.assetId == (creationFailure ? nil : "first"))
        #expect(vm.currentAssetId == "second")
        #expect(vm.isUploading)
        if creationFailure { #expect(state.calls == 3) }
        secondRelease.continuation.yield(())
        await secondUpload.value
    }
}

nonisolated private final class UploadCancellationCounter: Sendable {
    let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
}

nonisolated private final class CancellationLifetimeProbe: Sendable {
    let counter: UploadCancellationCounter

    init(counter: UploadCancellationCounter) {
        self.counter = counter
    }

    func cancel() { counter.increment() }
}

struct TaskCancellationBridgeTests {
    @Test
    func cancellationWorksBeforeAndAfterTaskRegistration() {
        let before = TaskCancellationBridge()
        let beforeCounter = UploadCancellationCounter()
        before.cancel()
        before.register { beforeCounter.increment() }
        before.cancel()
        #expect(beforeCounter.value.withLock { $0 } == 1)

        let after = TaskCancellationBridge()
        let afterCounter = UploadCancellationCounter()
        after.register { afterCounter.increment() }
        after.cancel()
        after.cancel()
        #expect(afterCounter.value.withLock { $0 } == 1)
    }

    @Test
    func cancellationBeforeRegistrationRetainsTheHandleUntilTheBridgeIsReleased() {
        let counter = UploadCancellationCounter()
        var bridge: TaskCancellationBridge? = TaskCancellationBridge()
        weak var retainedProbe: CancellationLifetimeProbe?
        bridge?.cancel()
        do {
            let probe = CancellationLifetimeProbe(counter: counter)
            retainedProbe = probe
            bridge?.register { probe.cancel() }
        }
        #expect(counter.value.withLock { $0 } == 1)
        #expect(retainedProbe != nil)
        bridge = nil
        #expect(retainedProbe == nil)
    }
}

nonisolated private enum ArchivePhotoLinkTransferError: Error {
    case preflight
    case put
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ArchiveRetryPhotoLinkTests {
    private let fingerprint = VideoContentFingerprint(
        sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        byteCount: 3)
    private let metadata = VideoMetadata(
        duration: 7, resolution: "test", codec: "test", orientation: "landscape",
        deviceModel: "test", osVersion: "test", capturedAt: nil,
        gpsLat: nil, gpsLon: nil, gpsAltitude: nil)

    private func link(_ identifier: String) -> ScopedPhotoAssociation {
        ScopedPhotoAssociation(
            photoIdentifier: identifier, fingerprint: fingerprint, metadata: metadata)
    }

    @Test(arguments: [0, 1, 2, 3])
    func actualMuxPutControlsReplacementAndRemoval(scenario: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let endpoint = try await server.start().appendingPathComponent("upload")
        let file = fixture.directory.appendingPathComponent("selected.mov")
        let bytes = Data("selected-video".utf8)
        try bytes.write(to: file)
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let old = link("old")
        let replacement: ScopedPhotoAssociation? = scenario == 1 ? nil : link("new")
        try store.save(assetId: "asset", association: old, for: fixture.scope)
        let snapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        let response = try JSONSerialization.data(withJSONObject: [
            "uploadUrl": "https://uploads.example.test/video", "clipId": "clip", "muxUploadId": "test",
        ])
        let uploader = VideoUploadService(createTransport: { _ in
            (response, testHTTPResponse(200))
        }, transfer: LoopbackVideoUploadTransfer(endpoint: endpoint))
        let owner = ArchiveMediaTaskOwner()
        var outcomeCount = 0
        let task = Task {
            try await ArchiveRetryPhotoLink.uploadAndCommit(
                store: store, snapshot: snapshot, assetId: "asset", scope: fixture.scope,
                association: replacement, isCurrent: { true },
                onOutcome: { outcome in
                    outcomeCount += 1
                    owner.setAssociationWarning(
                        outcome.warningMessage, assetId: "asset", scope: fixture.scope)
                },
                upload: {
                    _ = try await uploader.uploadViaMux(
                        assetId: "asset", fileURL: file, token: "test-token",
                        serverURL: URL(string: "https://example.test")!,
                        isCurrent: { true },
                        validateBeforeTransfer: {
                            if scenario == 2 { throw ArchiveRetryError.intentChanged }
                        })
                })
        }
        defer { task.cancel() }

        if scenario == 2 {
            do {
                _ = try await task.value
                Issue.record("The pre-PUT rejection unexpectedly succeeded")
            } catch ArchiveRetryError.intentChanged {
            } catch {
                Issue.record("Unexpected pre-PUT result: \(error)")
            }
            #expect(uploader.backgroundTransferStartCount == 0)
            #expect(!server.completeUpload())
            #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
            #expect(outcomeCount == 0)
            return
        }

        #expect(try await server.waitForUpload() == bytes)
        #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
        #expect(outcomeCount == 0)
        if scenario == 3 {
            #expect(server.completeUpload(status: 500))
            do {
                _ = try await task.value
                Issue.record("The failed PUT unexpectedly succeeded")
            } catch UploadError.serverError(let status, _) {
                #expect(status == 500)
            } catch {
                Issue.record("Unexpected PUT result: \(error)")
            }
            #expect(uploader.backgroundTransferStartCount == 1)
            #expect(outcomeCount == 0)
            #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
            return
        }
        #expect(server.completeUpload())
        let outcome = try await task.value
        guard case .committed = outcome else {
            Issue.record("Expected the successful PUT to commit the Photos link")
            return
        }
        #expect((outcome.warningMessage != nil) == (scenario == 1))
        if scenario == 1 {
            #expect(outcome.warningMessage?.contains("manually") == true)
        }
        #expect(owner.associationWarning(assetId: "asset", scope: fixture.scope) == outcome.warningMessage)
        #expect(outcomeCount == 1)
        #expect(try store.association(assetId: "asset", for: fixture.scope) == replacement)
        #expect(uploader.backgroundTransferStartCount == 1)
    }

    @Test(arguments: [0, 1, 2])
    func failedOrCancelledNoncooperativeTransferRetainsOldLink(scenario: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let old = link("old")
        let replacement = link("new")
        try store.save(assetId: "asset", association: old, for: fixture.scope)
        let snapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        let preflight = PhotoPreparationGate<Bool>()
        let put = PhotoPreparationGate<Bool>()
        var outcomeCount = 0
        let task = Task {
            try await ArchiveRetryPhotoLink.uploadAndCommit(
                store: store, snapshot: snapshot, assetId: "asset", scope: fixture.scope,
                association: replacement, isCurrent: { true },
                onOutcome: { _ in outcomeCount += 1 },
                upload: {
                    guard await preflight.wait() else { throw ArchivePhotoLinkTransferError.preflight }
                    guard await put.wait() else { throw ArchivePhotoLinkTransferError.put }
                })
        }
        defer { preflight.finish(false); put.finish(false); task.cancel() }
        try await preflight.waitForStart()
        #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
        if scenario == 0 {
            preflight.finish(false)
        } else {
            preflight.finish(true)
            try await put.waitForStart()
            #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
            if scenario == 1 {
                put.finish(false)
            } else {
                task.cancel()
                put.finish(true)
            }
        }

        if scenario < 2 {
            do {
                _ = try await task.value
                Issue.record("The failed transfer unexpectedly succeeded")
            } catch ArchivePhotoLinkTransferError.preflight {
                #expect(scenario == 0)
            } catch ArchivePhotoLinkTransferError.put {
                #expect(scenario == 1)
            } catch {
                Issue.record("Unexpected transfer result: \(error)")
            }
            #expect(outcomeCount == 0)
        } else {
            let outcome = try await task.value
            guard case .superseded = outcome else {
                Issue.record("Expected cancellation to prevent the association commit")
                return
            }
            #expect(outcomeCount == 1)
        }
        #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
    }

    @Test(arguments: [0, 1, 2])
    func verificationAbortOrPrePutFailureRetainsOldLink(scenario: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let old = link("old")
        try store.save(assetId: "asset", association: old, for: fixture.scope)
        let snapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        let gate = PhotoPreparationGate<Bool>()
        var current = true
        var warned = false
        var uploadStarted = false
        let task = Task {
            _ = await gate.wait()
            let association = try ArchiveRetryVerification.resolve(
                .failure(PhotoPreparationTestError.fingerprintFailed),
                validate: {
                    try Task.checkCancellation()
                    guard current else { throw ArchiveRetryError.intentChanged }
                },
                onMissing: { warned = true },
                onFailure: { _ in warned = true })
            return try await ArchiveRetryPhotoLink.uploadAndCommit(
                store: store, snapshot: snapshot, assetId: "asset", scope: fixture.scope,
                association: association, isCurrent: { current }, onOutcome: { _ in },
                upload: {
                    uploadStarted = true
                    throw ArchivePhotoLinkTransferError.preflight
                })
        }
        defer { gate.finish(true); task.cancel() }
        try await gate.waitForStart()
        #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
        if scenario == 0 { task.cancel() }
        if scenario == 1 { current = false }
        gate.finish(true)
        do {
            _ = try await task.value
            Issue.record("The aborted retry unexpectedly succeeded")
        } catch {
            switch scenario {
            case 0: #expect(error is CancellationError)
            case 1: #expect(error is ArchiveRetryError)
            default: #expect(error is ArchivePhotoLinkTransferError)
            }
        }
        #expect(warned == (scenario == 2))
        #expect(uploadStarted == (scenario == 2))
        #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func laterWriterAndReversionNeverGetOverwritten(scenario: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let writer = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let old = link("old")
        let later = link("later")
        let selected = link("selected")
        if scenario != 5 {
            try store.save(assetId: "asset", association: old, for: fixture.scope)
        }
        // This is the snapshot captured before presenting the picker.
        let snapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        if scenario == 0 {
            try writer.save(assetId: "asset", association: later, for: fixture.scope)
        }
        let gate = PhotoPreparationGate<Bool>()
        let task = Task {
            try await ArchiveRetryPhotoLink.uploadAndCommit(
                store: store, snapshot: snapshot, assetId: "asset", scope: fixture.scope,
                association: selected, isCurrent: { true }, onOutcome: { _ in },
                upload: { _ = await gate.wait() })
        }
        defer { gate.finish(true); task.cancel() }
        try await gate.waitForStart()
        switch scenario {
        case 0:
            break // The later write happened while the picker was open.
        case 1:
            try writer.save(assetId: "asset", association: later, for: fixture.scope)
        case 2:
            try writer.save(assetId: "asset", association: later, for: fixture.scope)
            try writer.save(assetId: "asset", association: old, for: fixture.scope)
        case 3:
            try writer.save(assetId: "asset", association: old, for: fixture.scope)
        case 4:
            try writer.remove(assetId: "asset", for: fixture.scope)
            try writer.save(assetId: "asset", association: old, for: fixture.scope)
        default:
            try writer.remove(assetId: "asset", for: fixture.scope)
        }
        let expected: ScopedPhotoAssociation? = scenario <= 1 ? later : (scenario == 5 ? nil : old)
        gate.finish(true)
        let outcome = try await task.value
        guard case .associationChanged = outcome else {
            Issue.record("Expected the later writer to invalidate the picker snapshot")
            return
        }
        #expect(outcome.warningMessage?.contains("manually") == true)
        #expect(try store.association(assetId: "asset", for: fixture.scope) == expected)
    }

    @Test
    func laterSuccessfulRetryWinsOverAnEarlierTransport() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let old = link("old")
        let later = link("later")
        let earlierLink = link("earlier")
        try store.save(assetId: "asset", association: old, for: fixture.scope)
        let earlierSnapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        let laterSnapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        let earlierGate = PhotoPreparationGate<Bool>()
        let laterGate = PhotoPreparationGate<Bool>()
        let earlier = Task {
            try await ArchiveRetryPhotoLink.uploadAndCommit(
                store: store, snapshot: earlierSnapshot, assetId: "asset", scope: fixture.scope,
                association: earlierLink, isCurrent: { true }, onOutcome: { _ in },
                upload: { _ = await earlierGate.wait() })
        }
        let newer = Task {
            try await ArchiveRetryPhotoLink.uploadAndCommit(
                store: store, snapshot: laterSnapshot, assetId: "asset", scope: fixture.scope,
                association: later, isCurrent: { true }, onOutcome: { _ in },
                upload: { _ = await laterGate.wait() })
        }
        defer { earlierGate.finish(true); laterGate.finish(true); earlier.cancel(); newer.cancel() }
        try await earlierGate.waitForStart()
        try await laterGate.waitForStart()
        laterGate.finish(true)
        let newerOutcome = try await newer.value
        guard case .committed = newerOutcome else {
            Issue.record("Expected the later retry to commit")
            return
        }
        earlierGate.finish(true)
        let earlierOutcome = try await earlier.value
        guard case .associationChanged = earlierOutcome else {
            Issue.record("Expected the earlier retry to preserve the later association")
            return
        }
        #expect(try store.association(assetId: "asset", for: fixture.scope) == later)
    }

    @Test
    func unrelatedAssetsAndScopesDoNotInvalidateSnapshot() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let writer = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let otherScope = try #require(PendingFormScope(
            userId: "another-user", serverURL: URL(string: "https://one.example.test")!))
        let old = link("old")
        let other = link("other")
        let replacement = link("new")
        try store.save(assetId: "asset", association: old, for: fixture.scope)
        let snapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        try writer.save(assetId: "other", association: other, for: fixture.scope)
        try writer.save(assetId: "asset", association: other, for: otherScope)
        let outcome = try await ArchiveRetryPhotoLink.uploadAndCommit(
            store: store, snapshot: snapshot, assetId: "asset", scope: fixture.scope,
            association: replacement, isCurrent: { true }, onOutcome: { _ in }, upload: {})
        guard case .committed = outcome else {
            Issue.record("An unrelated write should not block the commit")
            return
        }
        #expect(try store.association(assetId: "asset", for: fixture.scope) == replacement)
        #expect(try store.association(assetId: "other", for: fixture.scope) == other)
        #expect(try store.association(assetId: "asset", for: otherScope) == other)
    }

    @Test
    func snapshotCannotBeAppliedToAnotherAssetScopeOrStore() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let otherFixture = try FormTestFixture()
        defer { otherFixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let otherStore = ScopedPHAssetIdentifierStore(directory: otherFixture.directory)
        let otherScope = try #require(PendingFormScope(
            userId: "another-user", serverURL: URL(string: "https://one.example.test")!))
        let old = link("old")
        try store.save(assetId: "asset", association: old, for: fixture.scope)
        try store.save(assetId: "other", association: old, for: fixture.scope)
        try store.save(assetId: "asset", association: old, for: otherScope)
        try otherStore.save(assetId: "asset", association: old, for: fixture.scope)
        let snapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        for (targetStore, assetId, scope) in [
            (store, "other", fixture.scope), (store, "asset", otherScope),
            (otherStore, "asset", fixture.scope),
        ] {
            let outcome = try await ArchiveRetryPhotoLink.uploadAndCommit(
                store: targetStore, snapshot: snapshot, assetId: assetId, scope: scope,
                association: link("new"), isCurrent: { true }, onOutcome: { _ in }, upload: {})
            guard case .associationChanged = outcome else {
                Issue.record("A snapshot must not authorize a different asset, scope, or store")
                return
            }
            #expect(try targetStore.association(assetId: assetId, for: scope) == old)
        }
        #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
    }

    @Test
    func repairInvalidatesSnapshotEvenWhenTheLinkIsStillAbsent() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let snapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        try Data("{invalid".utf8).write(to: store.storageURL(for: fixture.scope))
        #expect(try store.quarantineDamagedAssociations(for: fixture.scope))
        let outcome = try await ArchiveRetryPhotoLink.uploadAndCommit(
            store: store, snapshot: snapshot, assetId: "asset", scope: fixture.scope,
            association: link("new"), isCurrent: { true }, onOutcome: { _ in }, upload: {})
        guard case .associationChanged = outcome else {
            Issue.record("Repair must invalidate snapshots for the whole scope")
            return
        }
        #expect(try store.association(assetId: "asset", for: fixture.scope) == nil)
    }

    @Test(arguments: [false, true])
    func storageFailureKeepsOldLinkAndProducesManualRetryWarning(remove: Bool) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let old = link("old")
        try store.save(assetId: "asset", association: old, for: fixture.scope)
        let snapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        let oldBytes = try Data(contentsOf: store.storageURL(for: fixture.scope))
        let failing = ScopedPHAssetIdentifierStore(
            directory: fixture.directory,
            commitStagedFile: { _, _ in throw PhotoStoreTestError.commitFailed })
        let owner = ArchiveMediaTaskOwner()
        let outcome = try await ArchiveRetryPhotoLink.uploadAndCommit(
            store: failing, snapshot: snapshot, assetId: "asset", scope: fixture.scope,
            association: remove ? nil : link("new"), isCurrent: { true },
            onOutcome: { result in
                if let warning = result.warningMessage {
                    owner.setAssociationWarning(warning, assetId: "asset", scope: fixture.scope)
                }
            }, upload: {})
        guard case .storageFailure(let error) = outcome else {
            Issue.record("Expected a post-PUT storage warning")
            return
        }
        #expect(error is PhotoStoreTestError)
        let warning = owner.associationWarning(assetId: "asset", scope: fixture.scope)
        #expect(warning?.contains("manually") == true)
        #expect(owner.associationWarning(assetId: "other", scope: fixture.scope) == nil)
        let otherScope = try #require(PendingFormScope(
            userId: "another-user", serverURL: URL(string: "https://one.example.test")!))
        #expect(owner.associationWarning(assetId: "asset", scope: otherScope) == nil)
        #expect(try Data(contentsOf: store.storageURL(for: fixture.scope)) == oldBytes)
        #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
        owner.cancelAll()
        #expect(owner.associationWarning(assetId: "asset", scope: fixture.scope) == nil)

        let stale = try await ArchiveRetryPhotoLink.uploadAndCommit(
            store: store, snapshot: snapshot, assetId: "asset", scope: fixture.scope,
            association: link("late"), isCurrent: { true }, onOutcome: { _ in }, upload: {})
        guard case .associationChanged = stale else {
            Issue.record("A failed mutation must conservatively invalidate older snapshots")
            return
        }
        #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
    }

    @Test
    func unreadableStoreAfterPutIsReportedWithoutOverwritingIt() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        try store.save(assetId: "asset", association: link("old"), for: fixture.scope)
        let snapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        let replacement = link("new")
        let gate = PhotoPreparationGate<Bool>()
        let task = Task {
            try await ArchiveRetryPhotoLink.uploadAndCommit(
                store: store, snapshot: snapshot, assetId: "asset", scope: fixture.scope,
                association: replacement, isCurrent: { true }, onOutcome: { _ in },
                upload: { _ = await gate.wait() })
        }
        defer { gate.finish(true); task.cancel() }
        try await gate.waitForStart()
        let corrupt = Data("{invalid".utf8)
        let url = try store.storageURL(for: fixture.scope)
        try corrupt.write(to: url)
        gate.finish(true)
        let outcome = try await task.value
        guard case .storageFailure(let error) = outcome else {
            Issue.record("Expected an unreadable-store warning")
            return
        }
        #expect(error is DecodingError)
        #expect(outcome.warningMessage?.contains("manually") == true)
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test(arguments: [0, 1, 2, 3])
    func operationSessionAndIntentAreCheckedAfterTransport(change: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let store = ScopedPHAssetIdentifierStore(directory: fixture.directory)
        let old = link("old")
        let replacement = link("new")
        try store.save(assetId: "asset", association: old, for: fixture.scope)
        let snapshot = try store.snapshot(assetId: "asset", for: fixture.scope)
        let asset = try JSONDecoder().decode(
            Asset.self, from: Data(#"{"id":"asset","uploadMode":"MUX","status":"ERROR"}"#.utf8))
        let changed = try JSONDecoder().decode(
            Asset.self, from: Data(#"{"id":"asset","uploadMode":"MUX","status":"PROCESSING"}"#.utf8))
        let owner = ArchiveMediaTaskOwner()
        let serverURL = URL(string: "https://one.example.test")!
        let auth = testAuth(serverURL: serverURL)
        let session = try #require(ArchiveSessionIdentity(auth: auth, serverURL: serverURL))
        #expect(session.scope == fixture.scope)
        let generation = session.generation
        owner.updateAssetSnapshot([asset], scope: fixture.scope, sessionGeneration: generation)
        let intent = try #require(owner.retryIntent(
            for: asset, scope: fixture.scope, sessionGeneration: generation))
        let gate = PhotoPreparationGate<Bool>()
        let finished = AsyncStream<Void>.makeStream()
        var outcome: ArchiveRetryPhotoLink.Outcome?
        var published = false
        let started = owner.start(
            assetId: asset.id, scope: fixture.scope, sessionGeneration: generation, intent: intent,
            onFinished: { _ in _ = finished.continuation.yield(()) }
        ) { id in
            #expect(owner.markNetworkStarted(assetId: asset.id, scope: fixture.scope, id: id))
            outcome = try? await ArchiveRetryPhotoLink.uploadAndCommit(
                store: store, snapshot: snapshot, assetId: asset.id, scope: fixture.scope,
                association: replacement,
                isCurrent: {
                    session.isCurrent(auth, serverURL: serverURL)
                        && owner.owns(assetId: asset.id, scope: fixture.scope, id: id)
                        && owner.intentIsCurrent(assetId: asset.id, scope: fixture.scope, id: id)
                },
                onOutcome: { _ in
                    if session.isCurrent(auth, serverURL: serverURL)
                        && owner.owns(assetId: asset.id, scope: fixture.scope, id: id) {
                        published = true
                    }
                },
                upload: { _ = await gate.wait() })
        }
        #expect(started)
        defer { gate.finish(true); owner.cancelAll() }
        try await gate.waitForStart()
        switch change {
        case 0:
            owner.updateAssetSnapshot([changed], scope: fixture.scope, sessionGeneration: generation)
        case 1:
            auth.token = "replacement-session-token"
        case 3:
            owner.updateAssetSnapshot([changed], scope: fixture.scope, sessionGeneration: generation)
            owner.updateAssetSnapshot([asset], scope: fixture.scope, sessionGeneration: generation)
        default:
            owner.cancelAll()
        }
        gate.finish(true)
        var iterator = finished.stream.makeAsyncIterator()
        _ = await iterator.next()
        guard case .superseded? = outcome else {
            Issue.record("Expected the stale operation to leave its Photos link alone")
            return
        }
        #expect(published == (change == 0 || change == 3))
        #expect(try store.association(assetId: "asset", for: fixture.scope) == old)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ArchiveMediaTaskOwnerTests {
    @Test
    func retryRequiresVerifiedMuxModeAndInvalidatesWhenModeChanges() throws {
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let generation = UUID()
        let mux = try JSONDecoder().decode(
            AssetDetailResponse.self, from: testAssetData(id: "asset", owner: "user-1")).asset
        owner.updateAssetSnapshot([mux], scope: scope, sessionGeneration: generation)
        let intent = try #require(owner.retryIntent(for: mux, scope: scope, sessionGeneration: generation))

        let unverifiedModes: [Asset.AssetUploadMode?] = [.original, .unknown, nil]
        for mode in unverifiedModes {
            var changed = mux
            changed.uploadMode = mode
            owner.updateAssetSnapshot([changed], scope: scope, sessionGeneration: generation)
            #expect(owner.retryIntent(for: changed, scope: scope, sessionGeneration: generation) == nil)
            #expect(!intent.permits(changed))
            #expect(!owner.intentIsCurrent(
                intent, assetId: mux.id, scope: scope, sessionGeneration: generation))
        }
        owner.updateAssetSnapshot([mux], scope: scope, sessionGeneration: generation)
        #expect(!owner.intentIsCurrent(
            intent, assetId: mux.id, scope: scope, sessionGeneration: generation))
    }

    @Test
    func retryIsClaimedPerAssetAndCancelledUntilItsReaderReturns() async throws {
        let owner = ArchiveMediaTaskOwner()
        let gate = PhotoPreparationGate<Bool>()
        let finished = AsyncStream<Void>.makeStream()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let asset = try JSONDecoder().decode(
            AssetDetailResponse.self, from: testAssetData(id: "asset", owner: "user-1")).asset
        let intent = ArchiveRetryIntent(asset: asset)
        let generation = UUID()
        owner.updateAssetSnapshot([asset], scope: scope, sessionGeneration: generation)
        var operationID: UUID?
        var observedCancellation = false
        #expect(owner.start(assetId: "asset", scope: scope, sessionGeneration: generation, intent: intent) { id in
            operationID = id
            _ = await gate.wait()
            observedCancellation = Task.isCancelled
            finished.continuation.yield(())
        })
        try await gate.waitForStart()
        let id = try #require(operationID)
        #expect(owner.owns(assetId: "asset", scope: scope, id: id))
        #expect(!owner.start(assetId: "asset", scope: scope, sessionGeneration: generation, intent: intent) { _ in })
        #expect(owner.markNetworkStarted(assetId: "asset", scope: scope, id: id))
        owner.cancelAll()
        #expect(!owner.owns(assetId: "asset", scope: scope, id: id))
        #expect(owner.isRunning(assetId: "asset", scope: scope))
        gate.finish(true)
        var iterator = finished.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(observedCancellation)
        #expect(!owner.isRunning(assetId: "asset", scope: scope))
    }

    @Test
    func refreshedAssetInvalidatesRetryBeforeItsSideEffects() async throws {
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let asset = try JSONDecoder().decode(
            AssetDetailResponse.self, from: testAssetData(id: "asset", owner: "user-1")).asset
        let generation = UUID()
        let intent = ArchiveRetryIntent(asset: asset)
        let gate = PhotoPreparationGate<Bool>()
        let finished = AsyncStream<Void>.makeStream()
        var operationID: UUID?
        var performedSideEffect = false
        owner.updateAssetSnapshot([asset], scope: scope, sessionGeneration: generation)
        #expect(owner.start(assetId: "asset", scope: scope, sessionGeneration: generation, intent: intent) { id in
            operationID = id
            _ = await gate.wait()
            performedSideEffect = owner.intentIsCurrent(assetId: "asset", scope: scope, id: id)
            finished.continuation.yield(())
        })
        defer { gate.finish(true) }
        try await gate.waitForStart()
        let id = try #require(operationID)
        #expect(owner.intentIsCurrent(assetId: "asset", scope: scope, id: id))
        owner.updateAssetSnapshot([], scope: scope, sessionGeneration: generation)
        #expect(!owner.intentIsCurrent(assetId: "asset", scope: scope, id: id))
        gate.finish(true)
        var iterator = finished.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!performedSideEffect)
    }

    @Test
    func retiredRetryBlocksOnlyItsOwnAccountAndServer() async throws {
        let owner = ArchiveMediaTaskOwner()
        let first = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let other = try #require(PendingFormScope(userId: "user-2", serverURL: ServerConfig.baseURL))
        let asset = try JSONDecoder().decode(
            AssetDetailResponse.self, from: testAssetData(id: "asset", owner: "user-1")).asset
        let intent = ArchiveRetryIntent(asset: asset)
        let firstGeneration = UUID()
        let secondGeneration = UUID()
        let gate = PhotoPreparationGate<Bool>()
        var firstOperationID: UUID?
        owner.updateAssetSnapshot([asset], scope: first, sessionGeneration: firstGeneration)
        #expect(owner.start(assetId: "asset", scope: first, sessionGeneration: firstGeneration, intent: intent) { id in
            firstOperationID = id
            _ = await gate.wait()
        })
        defer { gate.finish(true) }
        try await gate.waitForStart()
        let id = try #require(firstOperationID)
        #expect(owner.markNetworkStarted(assetId: "asset", scope: first, id: id))
        owner.cancelAll()
        #expect(owner.hasRunning(in: first))
        #expect(!owner.hasActive(in: first))
        #expect(!owner.hasRunning(in: other))
        owner.updateAssetSnapshot([asset], scope: first, sessionGeneration: secondGeneration)
        #expect(!owner.start(assetId: "asset", scope: first, sessionGeneration: secondGeneration, intent: intent) { _ in })
        owner.updateAssetSnapshot([asset], scope: other, sessionGeneration: secondGeneration)
        #expect(owner.start(assetId: "asset", scope: other, sessionGeneration: secondGeneration, intent: intent) { _ in })
        gate.finish(true)
    }

    @Test
    func retiredPhotoReaderDoesNotBlockRepairOrAReplacementRetry() async throws {
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let asset = try JSONDecoder().decode(
            AssetDetailResponse.self, from: testAssetData(id: "asset", owner: "user-1")).asset
        let oldGeneration = UUID()
        let newGeneration = UUID()
        let oldGate = PhotoPreparationGate<Bool>()
        let newGate = PhotoPreparationGate<Bool>()
        let oldFinished = AsyncStream<Void>.makeStream()
        defer { oldGate.finish(true); newGate.finish(true); owner.cancelAll() }

        owner.updateAssetSnapshot([asset], scope: scope, sessionGeneration: oldGeneration)
        let oldIntent = try #require(owner.retryIntent(
            for: asset, scope: scope, sessionGeneration: oldGeneration))
        #expect(owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: oldGeneration, intent: oldIntent
        ) { _ in
            _ = await oldGate.wait()
            oldFinished.continuation.yield(())
        })
        try await oldGate.waitForStart()
        owner.cancelAll()
        #expect(!owner.hasRunning(in: scope))
        #expect(!owner.hasActive(in: scope))

        owner.updateAssetSnapshot([asset], scope: scope, sessionGeneration: newGeneration)
        let newIntent = try #require(owner.retryIntent(
            for: asset, scope: scope, sessionGeneration: newGeneration))
        #expect(owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: newGeneration, intent: newIntent
        ) { _ in
            _ = await newGate.wait()
        })
        try await newGate.waitForStart()
        oldGate.finish(true)
        var iterator = oldFinished.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(owner.isRunning(assetId: asset.id, scope: scope))
        #expect(owner.hasActive(in: scope))
    }

    @Test(arguments: [false, true])
    func snapshotSupersedesReaderWithoutDisruptingReplacement(removed: Bool) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let directory = fixture.directory.appendingPathComponent("reader")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("video.mov")
        try Data("selected-video".utf8).write(to: file)
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let generation = UUID()
        let decoder = JSONDecoder()
        let asset = try decoder.decode(
            Asset.self, from: Data(
                #"{"id":"asset","uploadMode":"MUX","status":"ERROR","clips":[{"id":"clip","codec":"h264"}]}"#.utf8))
        let changed = try decoder.decode(
            Asset.self, from: Data(
                #"{"id":"asset","uploadMode":"MUX","status":"ERROR","clips":[{"id":"clip","codec":"hevc"}]}"#.utf8))
        let other = try decoder.decode(
            Asset.self, from: Data(#"{"id":"other","uploadMode":"MUX","status":"ERROR"}"#.utf8))
        let otherChanged = try decoder.decode(
            Asset.self, from: Data(#"{"id":"other","uploadMode":"MUX","status":"READY"}"#.utf8))
        let oldGate = PhotoPreparationGate<Bool>()
        let newGate = PhotoPreparationGate<Bool>()
        let oldFinished = AsyncStream<UUID>.makeStream()
        let newFinished = AsyncStream<UUID>.makeStream()
        defer {
            oldGate.finish(true)
            newGate.finish(true)
            owner.cancelAll()
        }

        owner.updateAssetSnapshot([asset, other], scope: scope, sessionGeneration: generation)
        let oldIntent = try #require(owner.retryIntent(
            for: asset, scope: scope, sessionGeneration: generation))
        var oldID: UUID?
        var retiredID: UUID?
        var retirementCount = 0
        var oldWasCancelled = false
        var staleMutation = false
        #expect(owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: generation, intent: oldIntent,
            onSuperseded: { id in
                retiredID = id
                retirementCount += 1
            },
            onFinished: { _ = oldFinished.continuation.yield($0) }
        ) { id in
            oldID = id
            _ = await oldGate.wait()
            oldWasCancelled = Task.isCancelled
            do {
                _ = try ArchiveRetryVideoLoad.resolve(.success(VideoTransferable(url: file))) {
                    guard owner.owns(assetId: asset.id, scope: scope, id: id) else {
                        throw UploadError.sessionChanged
                    }
                    guard owner.intentIsCurrent(assetId: asset.id, scope: scope, id: id) else {
                        throw ArchiveRetryError.intentChanged
                    }
                }
                staleMutation = true
            } catch UploadError.sessionChanged {
            } catch {
                Issue.record("Unexpected retired reader result: \(error)")
            }
        })
        try await oldGate.waitForStart()
        let originalID = try #require(oldID)

        owner.updateAssetSnapshot([asset, otherChanged], scope: scope, sessionGeneration: generation)
        #expect(owner.owns(assetId: asset.id, scope: scope, id: originalID))
        #expect(retirementCount == 0)

        owner.updateAssetSnapshot(
            removed ? [otherChanged] : [changed, otherChanged],
            scope: scope, sessionGeneration: generation)
        #expect(retiredID == originalID)
        #expect(retirementCount == 1)
        #expect(!owner.owns(assetId: asset.id, scope: scope, id: originalID))
        #expect(!owner.hasRunning(in: scope))
        #expect(!owner.hasActive(in: scope))
        #expect(FileManager.default.fileExists(atPath: file.path))

        // A reversion or reappearance must not revive the old intent.
        owner.updateAssetSnapshot([asset, otherChanged], scope: scope, sessionGeneration: generation)
        #expect(!owner.intentIsCurrent(
            oldIntent, assetId: asset.id, scope: scope, sessionGeneration: generation))
        let newIntent = try #require(owner.retryIntent(
            for: asset, scope: scope, sessionGeneration: generation))
        var newID: UUID?
        #expect(owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: generation, intent: newIntent,
            onFinished: { _ = newFinished.continuation.yield($0) }
        ) { id in
            newID = id
            _ = await newGate.wait()
        })
        try await newGate.waitForStart()
        let replacementID = try #require(newID)
        #expect(replacementID != originalID)

        oldGate.finish(true)
        var oldIterator = oldFinished.stream.makeAsyncIterator()
        let completedOldID = await oldIterator.next()
        #expect(completedOldID == originalID)
        #expect(oldWasCancelled)
        #expect(!staleMutation)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(owner.owns(assetId: asset.id, scope: scope, id: replacementID))
        #expect(owner.isRunning(assetId: asset.id, scope: scope))
        #expect(owner.hasActive(in: scope))
        #expect(retirementCount == 1)

        newGate.finish(true)
        var newIterator = newFinished.stream.makeAsyncIterator()
        let completedNewID = await newIterator.next()
        #expect(completedNewID == replacementID)
        #expect(!owner.isRunning(assetId: asset.id, scope: scope))
    }

    @Test
    func snapshotCanRetireReaderBeforeItsTaskStarts() async throws {
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let generation = UUID()
        let asset = try JSONDecoder().decode(
            Asset.self, from: Data(#"{"id":"asset","uploadMode":"MUX","status":"ERROR"}"#.utf8))
        let changed = try JSONDecoder().decode(
            Asset.self, from: Data(#"{"id":"asset","uploadMode":"MUX","status":"UPLOADING"}"#.utf8))
        let replacementGate = PhotoPreparationGate<Bool>()
        let oldFinished = AsyncStream<UUID>.makeStream()
        defer { replacementGate.finish(true); owner.cancelAll() }
        owner.updateAssetSnapshot([asset], scope: scope, sessionGeneration: generation)
        let intent = try #require(owner.retryIntent(
            for: asset, scope: scope, sessionGeneration: generation))
        var retiredID: UUID?
        var oldStartedCancelled = false
        var staleMutation = false
        #expect(owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: generation, intent: intent,
            onSuperseded: { retiredID = $0 },
            onFinished: { _ = oldFinished.continuation.yield($0) }
        ) { id in
            oldStartedCancelled = Task.isCancelled
            guard owner.owns(assetId: asset.id, scope: scope, id: id) else { return }
            staleMutation = true
        })

        owner.updateAssetSnapshot([changed], scope: scope, sessionGeneration: generation)
        let oldID = try #require(retiredID)
        #expect(!owner.hasActive(in: scope))
        let replacementIntent = try #require(owner.retryIntent(
            for: changed, scope: scope, sessionGeneration: generation))
        var replacementID: UUID?
        #expect(owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: generation,
            intent: replacementIntent
        ) { id in
            replacementID = id
            _ = await replacementGate.wait()
        })
        try await replacementGate.waitForStart()
        var iterator = oldFinished.stream.makeAsyncIterator()
        let completedOldID = await iterator.next()
        #expect(completedOldID == oldID)
        #expect(oldStartedCancelled)
        #expect(!staleMutation)
        let newID = try #require(replacementID)
        #expect(owner.owns(assetId: asset.id, scope: scope, id: newID))
    }

    @Test
    func snapshotSupersessionKeepsSubmittedNetworkBarrier() async throws {
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let generation = UUID()
        let nextGeneration = UUID()
        let asset = try JSONDecoder().decode(
            Asset.self, from: Data(#"{"id":"asset","uploadMode":"MUX","status":"ERROR"}"#.utf8))
        let changed = try JSONDecoder().decode(
            Asset.self, from: Data(#"{"id":"asset","uploadMode":"MUX","status":"PROCESSING"}"#.utf8))
        let gate = PhotoPreparationGate<Bool>()
        let finished = AsyncStream<UUID>.makeStream()
        defer { gate.finish(true); owner.cancelAll() }
        owner.updateAssetSnapshot([asset], scope: scope, sessionGeneration: generation)
        let intent = try #require(owner.retryIntent(
            for: asset, scope: scope, sessionGeneration: generation))
        var operationID: UUID?
        var superseded = false
        var observedCancellation = false
        let started = owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: generation, intent: intent,
            onSuperseded: { _ in superseded = true },
            onFinished: { _ = finished.continuation.yield($0) }
        ) { id in
            operationID = id
            #expect(owner.markNetworkStarted(assetId: asset.id, scope: scope, id: id))
            _ = await gate.wait()
            observedCancellation = Task.isCancelled
        }
        #expect(started)
        try await gate.waitForStart()
        let id = try #require(operationID)
        owner.updateAssetSnapshot([changed], scope: scope, sessionGeneration: generation)
        let changedIntent = try #require(owner.retryIntent(
            for: changed, scope: scope, sessionGeneration: generation))
        #expect(owner.owns(assetId: asset.id, scope: scope, id: id))
        #expect(owner.isRunning(assetId: asset.id, scope: scope))
        #expect(owner.hasActive(in: scope))
        #expect(!superseded)
        #expect(!owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: generation,
            intent: changedIntent) { _ in })

        owner.cancelAll()
        owner.updateAssetSnapshot([changed], scope: scope, sessionGeneration: nextGeneration)
        let nextIntent = try #require(owner.retryIntent(
            for: changed, scope: scope, sessionGeneration: nextGeneration))
        #expect(!owner.hasActive(in: scope))
        #expect(owner.isRunning(assetId: asset.id, scope: scope))
        #expect(!owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: nextGeneration,
            intent: nextIntent) { _ in })

        gate.finish(true)
        var iterator = finished.stream.makeAsyncIterator()
        let completedID = await iterator.next()
        #expect(completedID == id)
        #expect(observedCancellation)
        #expect(!owner.isRunning(assetId: asset.id, scope: scope))
        #expect(owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: nextGeneration,
            intent: nextIntent) { _ in })
    }

    @Test(arguments: [0, 1, 2])
    func verificationFailureWarnsOnlyForCurrentIntent(scenario: Int) async throws {
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let generation = UUID()
        let asset = try JSONDecoder().decode(
            Asset.self, from: Data(#"{"id":"asset","uploadMode":"MUX","status":"ERROR"}"#.utf8))
        let changed = try JSONDecoder().decode(
            Asset.self, from: Data(#"{"id":"asset","uploadMode":"MUX","status":"READY"}"#.utf8))
        let gate = PhotoPreparationGate<Bool>()
        let finished = AsyncStream<UUID>.makeStream()
        defer { gate.finish(true); owner.cancelAll() }
        owner.updateAssetSnapshot([asset], scope: scope, sessionGeneration: generation)
        let intent = try #require(owner.retryIntent(
            for: asset, scope: scope, sessionGeneration: generation))
        var operationID: UUID?
        var warningCount = 0
        var result = 0
        let started = owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: generation, intent: intent,
            onFinished: { _ = finished.continuation.yield($0) }
        ) { id in
            operationID = id
            // Keep ownership in scenario 2 to exercise intent validation independently
            // of reader retirement.
            if scenario == 2 {
                #expect(owner.markNetworkStarted(assetId: asset.id, scope: scope, id: id))
            }
            _ = await gate.wait()
            do {
                let failure: Result<ScopedPhotoAssociation?, any Error> =
                    .failure(PhotoPreparationTestError.fingerprintFailed)
                _ = try ArchiveRetryVerification.resolve(
                    failure,
                    validate: {
                        guard owner.owns(assetId: asset.id, scope: scope, id: id) else {
                            throw UploadError.sessionChanged
                        }
                        guard owner.intentIsCurrent(assetId: asset.id, scope: scope, id: id) else {
                            throw ArchiveRetryError.intentChanged
                        }
                    },
                    onMissing: { Issue.record("Unexpected missing-association warning") },
                    onFailure: { _ in warningCount += 1 })
            } catch ArchiveRetryError.intentChanged {
                result = 1
            } catch UploadError.sessionChanged {
                result = 2
            } catch {
                Issue.record("Unexpected verification result: \(error)")
            }
        }
        #expect(started)
        try await gate.waitForStart()
        let id = try #require(operationID)
        if scenario != 0 {
            owner.updateAssetSnapshot([changed], scope: scope, sessionGeneration: generation)
        }
        #expect(owner.owns(assetId: asset.id, scope: scope, id: id) == (scenario != 1))
        gate.finish(true)
        var iterator = finished.stream.makeAsyncIterator()
        let completedID = await iterator.next()
        #expect(completedID == id)
        #expect(warningCount == (scenario == 0 ? 1 : 0))
        #expect(result == (scenario == 1 ? 2 : scenario == 2 ? 1 : 0))
    }

    @Test
    func retiredVerificationCleanupCannotResetReplacementProgress() {
        var progress = ArchiveRetryVerificationProgress()
        let oldID = UUID()
        let newID = UUID()
        progress.begin(oldID)
        progress.reset()
        progress.begin(newID)
        progress.finish(oldID)
        #expect(progress.operationID == newID)
        #expect(progress.isVerifying)
        progress.finish(newID)
        #expect(!progress.isVerifying)
    }

    @Test
    func observedChangesAndReversionsPermanentlyInvalidateAnIntent() throws {
        func asset(status: String = "ERROR", codec: String = "h264") throws -> Asset {
            try JSONDecoder().decode(
                Asset.self,
                from: Data(
                    """
                    {"id":"asset","uploadMode":"MUX","status":"\(status)",
                     "clips":[{"id":"clip","codec":"\(codec)"}]}
                    """.utf8))
        }
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let generation = UUID()
        let original = try asset()
        owner.updateAssetSnapshot([original], scope: scope, sessionGeneration: generation)
        let first = try #require(owner.retryIntent(
            for: original, scope: scope, sessionGeneration: generation))
        owner.updateAssetSnapshot([original], scope: scope, sessionGeneration: generation)
        #expect(owner.intentIsCurrent(
            first, assetId: original.id, scope: scope, sessionGeneration: generation))
        owner.updateAssetSnapshot([try asset(codec: "hevc")], scope: scope, sessionGeneration: generation)
        owner.updateAssetSnapshot([original], scope: scope, sessionGeneration: generation)
        #expect(!owner.intentIsCurrent(
            first, assetId: original.id, scope: scope, sessionGeneration: generation))

        let second = try #require(owner.retryIntent(
            for: original, scope: scope, sessionGeneration: generation))
        owner.updateAssetSnapshot([], scope: scope, sessionGeneration: generation)
        owner.updateAssetSnapshot([original], scope: scope, sessionGeneration: generation)
        #expect(!owner.intentIsCurrent(
            second, assetId: original.id, scope: scope, sessionGeneration: generation))

        let third = try #require(owner.retryIntent(
            for: original, scope: scope, sessionGeneration: generation))
        owner.updateAssetSnapshot([try asset(status: "UPLOADING")], scope: scope, sessionGeneration: generation)
        #expect(!owner.intentIsCurrent(
            third, assetId: original.id, scope: scope, sessionGeneration: generation))
        owner.updateAssetSnapshot([original], scope: scope, sessionGeneration: UUID())
        #expect(!owner.intentIsCurrent(
            third, assetId: original.id, scope: scope, sessionGeneration: generation))
    }

    @Test(arguments: [0, 1, 2, 3])
    func refreshedIntentIsCheckedBeforeTheBackgroundPut(change: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let endpoint = try await server.start().appendingPathComponent("upload")
        let file = fixture.directory.appendingPathComponent("selected.mov")
        let bytes = Data("selected-video".utf8)
        try bytes.write(to: file)
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let generation = UUID()
        let asset = try JSONDecoder().decode(
            Asset.self, from: Data(
                #"{"id":"asset","uploadMode":"MUX","status":"UPLOADING","clips":[{"id":"clip","muxUploadId":"upload"}]}"#.utf8))
        let completed = try JSONDecoder().decode(
            Asset.self, from: Data(
                #"{"id":"asset","uploadMode":"MUX","status":"UPLOADING","clips":[{"id":"clip","muxUploadId":"upload","muxAssetId":"mux-asset"}]}"#.utf8))
        owner.updateAssetSnapshot([asset], scope: scope, sessionGeneration: generation)
        let intent = try #require(owner.retryIntent(
            for: asset, scope: scope, sessionGeneration: generation))
        let gate = PhotoPreparationGate<Bool>()
        let finished = AsyncStream<Void>.makeStream()
        defer { gate.finish(true); owner.cancelAll() }
        let response = try JSONSerialization.data(withJSONObject: [
            "uploadUrl": "https://uploads.example.test/video", "clipId": "clip", "muxUploadId": "test",
        ])
        let uploader = VideoUploadService(createTransport: { _ in
            _ = await gate.wait()
            return (response, testHTTPResponse(200))
        }, transfer: LoopbackVideoUploadTransfer(endpoint: endpoint))
        var sawChangedIntent = false
        var uploaded = false
        let started = owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: generation, intent: intent
        ) { id in
            #expect(owner.markNetworkStarted(assetId: asset.id, scope: scope, id: id))
            do {
                _ = try await uploader.uploadViaMux(
                    assetId: asset.id, fileURL: file, token: "test-token",
                    serverURL: URL(string: "https://example.test")!,
                    isCurrent: { owner.owns(assetId: asset.id, scope: scope, id: id) },
                    validateBeforeTransfer: {
                        guard owner.intentIsCurrent(assetId: asset.id, scope: scope, id: id)
                        else { throw ArchiveRetryError.intentChanged }
                    })
                uploaded = true
            } catch ArchiveRetryError.intentChanged {
                sawChangedIntent = true
            } catch {
                Issue.record("Unexpected upload result: \(error)")
            }
            finished.continuation.yield(())
        }
        #expect(started)
        try await gate.waitForStart()
        if change == 1 {
            owner.updateAssetSnapshot([], scope: scope, sessionGeneration: generation)
        } else if change == 2 || change == 3 {
            owner.updateAssetSnapshot([completed], scope: scope, sessionGeneration: generation)
            if change == 3 {
                owner.updateAssetSnapshot([asset], scope: scope, sessionGeneration: generation)
            }
        } else {
            owner.updateAssetSnapshot([asset], scope: scope, sessionGeneration: generation)
        }
        gate.finish(true)
        if change == 0 {
            #expect(try await server.waitForUpload() == bytes)
            #expect(server.completeUpload())
        }
        var iterator = finished.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(sawChangedIntent == (change != 0))
        #expect(uploaded == (change == 0))
        #expect(uploader.backgroundTransferStartCount == (change == 0 ? 1 : 0))
        if change != 0 { #expect(!server.completeUpload()) }
    }

    @Test(arguments: [0, 1, 2])
    func supersededPhotoLoadRejectsNilErrorAndSuccessfulResults(kind: Int) throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let directory = fixture.directory.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("video.mov")
        try Data("video".utf8).write(to: file)
        let result: Result<VideoTransferable?, any Error>
        switch kind {
        case 0:
            result = .success(nil)
        case 1:
            result = .failure(PhotoPreparationTestError.fingerprintFailed)
        default:
            result = .success(VideoTransferable(url: file))
        }
        do {
            _ = try ArchiveRetryVideoLoad.resolve(result) {
                throw ArchiveRetryError.intentChanged
            }
            Issue.record("A superseded Photos result must not continue")
        } catch ArchiveRetryError.intentChanged {
        } catch {
            Issue.record("Unexpected Photos load result: \(error)")
        }
        if kind == 2 { #expect(!FileManager.default.fileExists(atPath: file.path)) }
    }

    @Test
    func completedTransferRemainsProcessingUntilRefreshWorkFinishes() async throws {
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let asset = try JSONDecoder().decode(
            AssetDetailResponse.self, from: testAssetData(id: "asset", owner: "user-1")).asset
        let generation = UUID()
        let gate = PhotoPreparationGate<Bool>()
        let finished = AsyncStream<Void>.makeStream()
        defer { gate.finish(true); owner.cancelAll() }
        owner.updateAssetSnapshot([asset], scope: scope, sessionGeneration: generation)
        let intent = try #require(owner.retryIntent(
            for: asset, scope: scope, sessionGeneration: generation))
        #expect(owner.start(
            assetId: asset.id, scope: scope, sessionGeneration: generation, intent: intent
        ) { _ in
            owner.recordCompletion(assetId: asset.id, scope: scope)
            owner.clearCompletion(assetId: asset.id)
            _ = await gate.wait()
            finished.continuation.yield(())
        })
        try await gate.waitForStart()
        #expect(owner.isRunning(assetId: asset.id, scope: scope))
        #expect(owner.isFinishing(assetId: asset.id, scope: scope))
        #expect(ArchiveRowView.resolveStatus(
            assetStatus: .error, needsDetails: false, isStuck: false,
            isReuploading: owner.isRunning(assetId: asset.id, scope: scope)
                && !owner.isFinishing(assetId: asset.id, scope: scope),
            hasReuploadError: false,
            reuploadComplete: owner.isFinishing(assetId: asset.id, scope: scope)) == .processing)
        gate.finish(true)
        var iterator = finished.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!owner.isRunning(assetId: asset.id, scope: scope))
        #expect(!owner.isFinishing(assetId: asset.id, scope: scope))
    }

    @Test
    func pickerIntentSurvivesRowReplacementButRejectsChangedAsset() throws {
        func asset(status: String, clipID: String, duration: Int = 7, latitude: Double = 1) throws -> Asset {
            try JSONDecoder().decode(
                Asset.self,
                from: Data(
                    """
                    {"id":"asset","uploadMode":"MUX","status":"\(status)","clipCount":1,
                     "clips":[{"id":"\(clipID)","status":"ready","createdAt":"2026-05-10T12:00:00Z",
                               "duration":\(duration),"gpsLat":\(latitude)}]}
                    """.utf8))
        }
        let failed = try asset(status: "ERROR", clipID: "one")
        let intent = ArchiveRetryIntent(asset: failed)
        #expect(intent.permits(try asset(status: "ERROR", clipID: "one")))
        #expect(!intent.permits(try asset(status: "READY", clipID: "one")))
        #expect(!intent.permits(try asset(status: "ERROR", clipID: "two")))
        #expect(!intent.permits(try asset(status: "ERROR", clipID: "one", duration: 8)))
        #expect(!intent.permits(try asset(status: "ERROR", clipID: "one", latitude: 2)))
        let locallyFailedReady = ArchiveRetryIntent(
            asset: try asset(status: "READY", clipID: "one"))
        #expect(locallyFailedReady.permits(try asset(status: "READY", clipID: "one")))

        let paused = try JSONDecoder().decode(
            Asset.self,
            from: Data(
                #"{"id":"asset","uploadMode":"MUX","status":"ERROR","moderation":"PAUSED","clips":[{"id":"one","status":"ready","duration":7,"gpsLat":1}]}"#
                    .utf8))
        #expect(!intent.permits(paused))
    }

    @Test
    func retryStateSurvivesRowsAndClearsWhenResolved() throws {
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        owner.requireAssociationRepair(assetId: "asset", message: "Repair photo links.")
        owner.recordFailure(assetId: "other", message: "Another retry failed.")
        #expect(owner.retryMessages["asset"] == "Repair photo links.")
        owner.associationRepairCompleted()
        #expect(owner.retryMessages["asset"] == nil)
        #expect(owner.retryMessages["other"] == "Another retry failed.")
        owner.recordFailure(assetId: "asset", message: "Choose the video again.")
        owner.beginRetry(assetId: "asset")
        #expect(owner.retryMessages["asset"] == nil)
        owner.requireAssociationRepair(assetId: "asset", message: "Repair photo links.")
        owner.recordFailure(assetId: "asset", message: "A different retry failed.")
        owner.associationRepairCompleted()
        #expect(owner.retryMessages["asset"] == "A different retry failed.")
        owner.beginRetry(assetId: "asset")
        owner.recordCompletion(assetId: "asset", scope: scope)
        #expect(owner.completedAssetIDs.contains("asset"))
        owner.clearCompletion(assetId: "asset")
        #expect(!owner.completedAssetIDs.contains("asset"))
    }

    @Test
    func staleChatUploadCompletionCannotClearANewSessionClaim() throws {
        let state = FormPresentationState()
        let scope = try #require(PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let other = try #require(PendingFormScope(userId: "user-2", serverURL: ServerConfig.baseURL))
        let old = UUID()
        let current = UUID()
        state.beginChatUpload(assetId: "asset", scope: scope, uploadID: old)
        state.clearChatUploadFailures()
        #expect(state.isChatUploading(assetId: "asset", scope: scope))
        #expect(!state.isChatUploading(assetId: "asset", scope: other))
        state.beginChatUpload(assetId: "asset", scope: scope, uploadID: current)
        state.finishChatUpload(assetId: "asset", scope: scope, uploadID: old, failed: true)
        #expect(state.isChatUploading(assetId: "asset", scope: scope))
        #expect(!state.failedChatUploadAssetIDs.contains("asset"))
        state.finishChatUpload(assetId: "asset", scope: scope, uploadID: current, failed: true)
        #expect(!state.isChatUploading(assetId: "asset", scope: scope))
        #expect(state.failedChatUploadAssetIDs.contains("asset"))
        state.clearChatUploadFailure(assetId: "asset")
        #expect(!state.failedChatUploadAssetIDs.contains("asset"))
    }
}

@MainActor
struct ArchiveRowStatusTests {
    @Test
    func pausedStateOverridesUploadAndRetryStatuses() {
        #expect(ArchiveRowView.resolveStatus(
            assetStatus: .error, needsDetails: true, isStuck: true,
            isReuploading: true, hasReuploadError: true, reuploadComplete: false,
            isChatUploading: true, isPaused: true) == .paused)
    }

    @Test(arguments: [AssetStatus.ready, .uploading, .processing, .error])
    func failedLocalAttemptKeepsRetryEvenWhenCachedAssetLooksReady(status: AssetStatus) {
        #expect(ArchiveRowView.resolveStatus(
            assetStatus: status, needsDetails: true, isStuck: false,
            isReuploading: false, hasReuploadError: true, reuploadComplete: false) == .failed)
    }

    @Test(arguments: [AssetStatus.uploading, .processing])
    func missingDetailsDoesNotHideServerProcessing(status: AssetStatus) {
        #expect(ArchiveRowView.resolveStatus(
            assetStatus: status, needsDetails: true, isStuck: false,
            isReuploading: false, hasReuploadError: false, reuploadComplete: false) == .processing)
    }

    @Test
    func completedTransferWaitsForServerInsteadOfUsingCachedReadyState() {
        #expect(ArchiveRowView.resolveStatus(
            assetStatus: .ready, needsDetails: true, isStuck: false,
            isReuploading: false, hasReuploadError: false, reuploadComplete: true) == .processing)
    }

    @Test
    func activeReuploadOverridesPreviousError() {
        #expect(ArchiveRowView.resolveStatus(
            assetStatus: .error, needsDetails: true, isStuck: true,
            isReuploading: true, hasReuploadError: true, reuploadComplete: false) == .reuploading)
    }

    @Test
    func activeChatUploadSuppressesStaleRetryStatus() {
        #expect(ArchiveRowView.resolveStatus(
            assetStatus: .error, needsDetails: true, isStuck: true,
            isReuploading: false, hasReuploadError: true, reuploadComplete: false,
            isChatUploading: true) == .processing)
    }
}

@MainActor
struct ArchiveRefreshFeedbackTests {
    @Test(arguments: [false, true])
    func supersededManualRefreshReportsTheLatestResult(succeeded: Bool) {
        var feedback = ArchiveRefreshFeedback()
        feedback.requestManualRefresh()
        #expect(feedback.complete(.superseded) == nil)
        #expect(feedback.awaitingManualResult)

        let message = feedback.complete(succeeded ? .succeeded : .failed)
        #expect(message == (succeeded
            ? "Archive refreshed." : "Couldn't refresh Archive. Please try again."))
        #expect(!feedback.awaitingManualResult)
        #expect(feedback.complete(.succeeded) == nil)
    }

    @Test(arguments: [false, true])
    func supersededReuploadRefreshReportsTheLatestResult(succeeded: Bool) {
        var feedback = ArchiveRefreshFeedback()
        feedback.requestReuploadRefresh()
        #expect(feedback.complete(.superseded) == nil)
        #expect(feedback.awaitingReuploadResult)

        let message = feedback.complete(succeeded ? .succeeded : .failed)
        #expect(message == (succeeded ? nil
            : "Upload finished, but its status couldn't be refreshed. Refresh Archive."))
        #expect(!feedback.awaitingReuploadResult)
        #expect(feedback.complete(.failed) == nil)
    }

    @Test
    func combinedRefreshFailureRetainsReuploadContext() {
        var feedback = ArchiveRefreshFeedback()
        feedback.requestReuploadRefresh()
        feedback.requestManualRefresh()
        #expect(feedback.complete(.superseded) == nil)
        #expect(feedback.complete(.failed)
            == "Upload finished, but its status couldn't be refreshed. Refresh Archive.")
        #expect(!feedback.awaitingManualResult)
        #expect(!feedback.awaitingReuploadResult)
    }

    @Test
    func announcementsWaitForArchiveAndItsModals() {
        var queue = ArchiveAnnouncementQueue()
        queue.append("Upload finished.")
        #expect(queue.takeIfPossible(isActive: false, hasModal: false) == nil)
        queue.append("Archive refreshed.")
        #expect(queue.takeIfPossible(isActive: true, hasModal: true) == nil)
        #expect(queue.takeIfPossible(isActive: true, hasModal: false)
            == "Upload finished. Archive refreshed.")
        #expect(queue.takeIfPossible(isActive: true, hasModal: false) == nil)
    }

    @Test
    func completedDetailsSuppressOnlyTheirOwnResolvedNotices() {
        let presentation = FormPresentationState()
        presentation.completedDetailsAssetIDs.insert("finished")
        #expect(!presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PENDING_FORM_IN_ARCHIVE", assetId: "finished"))
        #expect(!presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PENDING_FORM_SAVE_FAILED", assetId: "finished"))
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PENDING_FORM_IN_ARCHIVE", assetId: "other"))
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PENDING_FORM_SAVE_FAILED", assetId: "other"))
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PENDING_FORM_RECOVERY_FAILED", assetId: "finished"))
    }

    @Test
    func successfulReuploadSuppressesOnlyNoticesFromTheResolvedAttempt() {
        let presentation = FormPresentationState()
        let earlier = ["uploadRevision": "0"]
        let later = ["uploadRevision": "1"]
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_UPLOAD_FAILED", assetId: "finished", params: earlier))
        presentation.markUploadRecovered(assetId: "finished")
        #expect(!presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PREVIOUS_UPLOAD_FAILED", assetId: "finished", params: earlier))
        #expect(!presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_UPLOAD_FAILED", assetId: "finished", params: earlier))
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_UPLOAD_FAILED", assetId: "finished", params: later))
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PREVIOUS_UPLOAD_FAILED", assetId: "other", params: earlier))
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PREVIOUS_UPLOAD_START_FAILED", assetId: "finished"))
        presentation.markUploadRecovered(assetId: "finished")
        #expect(!presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_UPLOAD_FAILED", assetId: "finished", params: later))
    }

    @Test
    func photoWarningsAreSuppressedOnlyAfterThatLinkIsSaved() {
        let presentation = FormPresentationState()
        presentation.markUploadRecovered(assetId: "asset")
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PHOTO_ASSOCIATION_SAVE_FAILED", assetId: "asset"))
        presentation.photoAssociatedAssetIDs.insert("asset")
        #expect(!presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PHOTO_ASSOCIATION_SAVE_FAILED", assetId: "asset"))
        #expect(!presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PREVIOUS_PHOTO_ASSOCIATION_SAVE_FAILED", assetId: "asset"))
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: "IOS_PHOTO_ASSOCIATION_SAVE_FAILED", assetId: "other"))
    }

    @Test
    func successfulStartSuppressesOnlyThatStagesOlderStartNotice() {
        let presentation = FormPresentationState()
        let finished = UUID()
        let other = UUID()
        let code = "IOS_PREVIOUS_UPLOAD_START_FAILED"
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: code, assetId: nil, params: ["stageId": finished.uuidString]))
        presentation.markUploadStarted(stageID: finished)
        #expect(!presentation.shouldAnnounceRecoveryNotice(
            code: code, assetId: nil, params: ["stageId": finished.uuidString]))
        #expect(presentation.shouldAnnounceRecoveryNotice(
            code: code, assetId: nil, params: ["stageId": other.uuidString]))
    }

    @Test
    func chatWaitsForActiveSceneAndProtectionAlertDismissal() {
        let presentation = FormPresentationState()
        #expect(presentation.canPresentInChat(isSceneActive: true))
        #expect(!presentation.canPresentInChat(isSceneActive: false))

        presentation.isSceneActive = false
        #expect(!presentation.canPresentInChat(isSceneActive: true))
        presentation.isSceneActive = true
        let generation = presentation.generation
        presentation.pendingFormProtectionWarning = true
        #expect(presentation.generation != generation)
        #expect(!presentation.canPresentInChat(isSceneActive: true))
        presentation.pendingFormProtectionWarning = false
        #expect(presentation.canPresentInChat(isSceneActive: true))
    }

    @Test
    func pickerUsesCurrentTabSceneAndModalState() {
        let presentation = FormPresentationState()
        let interaction = ArchiveInteractionState()
        presentation.selectedTab = .archive
        interaction.sceneIsActive = true
        #expect(interaction.canPresentPicker(presentation: presentation))

        presentation.selectedTab = .chat
        #expect(!interaction.canPresentPicker(presentation: presentation))
        presentation.selectedTab = .archive
        interaction.sceneIsActive = false
        #expect(!interaction.canPresentPicker(presentation: presentation))
        interaction.sceneIsActive = true
        presentation.isSceneActive = false
        #expect(!interaction.canPresentPicker(presentation: presentation))
        presentation.isSceneActive = true
        let modalID = UUID()
        #expect(interaction.beginRowModal(modalID, presentation: presentation))
        #expect(!interaction.canPresentPicker(presentation: presentation))
        #expect(!interaction.endRowModal(UUID()))
        #expect(!interaction.canPresentPicker(presentation: presentation))
        #expect(interaction.endRowModal(modalID))
        interaction.showDiscardLegacyConfirm = true
        #expect(!interaction.canPresentPicker(presentation: presentation))
        interaction.showDiscardLegacyConfirm = false
        presentation.pendingFormProtectionWarning = true
        #expect(!interaction.canPresentPicker(presentation: presentation))
        presentation.pendingFormProtectionWarning = false
        presentation.archiveFormVisible = true
        #expect(!interaction.canPresentPicker(presentation: presentation))
        presentation.archiveFormVisible = false
        #expect(interaction.canPresentPicker(presentation: presentation))
    }

    @Test
    func staleRowDisappearanceDoesNotMakeAReplacementRowUnavailable() {
        let interaction = ArchiveInteractionState()
        let previous = UUID()
        let current = UUID()
        interaction.setRowVisible(assetId: "asset", instanceId: previous, isVisible: true)
        interaction.setRowVisible(assetId: "asset", instanceId: current, isVisible: true)
        interaction.setRowVisible(assetId: "asset", instanceId: previous, isVisible: false)
        #expect(!interaction.isCurrentRow(assetId: "asset", instanceId: previous))
        #expect(interaction.isCurrentRow(assetId: "asset", instanceId: current))
    }
}

@MainActor
@Suite(.serialized)
struct ChatFormRecoveryTests {
    @Test
    func archiveAndInactiveTabsDeferLiveRequestsUntilChatIsAvailable() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let presentation = FormPresentationState()
        let ws = WebSocketService()
        let state = FormTestState()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, formPresentation: presentation,
            pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run { state.calls += 1 }
                return (testAssetData(id: "asset", owner: "user-1"), testHTTPResponse(200))
            })

        presentation.selectedTab = .archive
        ws.onFormRequest?(["assetId": "asset", "originalFileName": "asset.mov"])
        await vm.recoverPendingFormIfNeeded()
        #expect(!vm.showFormSheet)
        #expect(state.calls == 0)
        #expect(try fixture.store.record(assetId: "asset", for: scope) != nil)

        presentation.archiveFormVisible = true
        presentation.selectedTab = .chat
        await vm.recoverPendingFormIfNeeded()
        #expect(!vm.showFormSheet)
        #expect(state.calls == 0)

        presentation.archiveFormVisible = false
        await vm.recoverPendingFormIfNeeded()
        #expect(vm.showFormSheet)
        #expect(vm.formAssetId == "asset")
        #expect(state.calls == 1)
    }

    @Test
    func tabTransitionInvalidatesInFlightRecoveryAfterReturningToChat() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let record = try fixture.store.save(testForm("asset"), for: scope)
        let presentation = FormPresentationState()
        let state = FormTestState()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), formPresentation: presentation,
            pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run {
                    state.calls += 1
                    if state.calls == 1 {
                        presentation.selectedTab = .archive
                        presentation.archiveFormVisible = true
                        presentation.archiveFormVisible = false
                        presentation.selectedTab = .chat
                    }
                }
                return (testAssetData(id: "asset", owner: "user-1"), testHTTPResponse(200))
            })

        await vm.recoverPendingFormIfNeeded()
        #expect(!vm.showFormSheet)
        #expect(try fixture.store.contains(record))
        await vm.recoverPendingFormIfNeeded()
        #expect(vm.showFormSheet)
        #expect(vm.formAssetId == "asset")
        #expect(state.calls >= 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func invalidatedRecoveryDoesNotDelayRetryOrMutateSavedForms(
        oldResponseIsCompleted: Bool
    ) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let first = try fixture.store.save(testForm("first", savedAt: 1), for: scope)
        let second = try fixture.store.save(testForm("second", savedAt: 2), for: scope)
        let presentation = FormPresentationState()
        let oldGate = RecoveryResponseTestGate()
        let replacementGate = RecoveryResponseTestGate()
        let state = FormTestState()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), formPresentation: presentation,
            pendingFormStore: fixture.store,
            httpTransport: { request in
                let attempt = await MainActor.run {
                    state.calls += 1
                    if request.url?.lastPathComponent == "second" {
                        Issue.record("Invalidated recovery continued scanning saved forms")
                    }
                    return state.calls
                }
                if attempt == 1 { return await oldGate.waitForResponse() }
                if attempt == 2 { return await replacementGate.waitForResponse() }
                return (testAssetData(id: "first", owner: "user-1"), testHTTPResponse(200))
            })
        let original = Task { await vm.recoverPendingFormIfNeeded() }
        defer {
            oldGate.finish(status: 500)
            replacementGate.finish(status: 500)
            original.cancel()
        }
        try await oldGate.waitForStart()

        presentation.selectedTab = .archive
        presentation.selectedTab = .chat
        let replacement = Task { await vm.recoverPendingFormIfNeeded() }
        defer { replacement.cancel() }
        try await replacementGate.waitForStart()

        oldGate.finish(
            data: oldResponseIsCompleted
                ? testAssetData(id: "first", owner: "user-1", completed: true) : Data(),
            status: oldResponseIsCompleted ? 200 : 500)
        await original.value
        #expect(!vm.showFormSheet)
        #expect(try fixture.store.contains(first))
        #expect(!vm.messages.contains {
            $0.content.code == "IOS_PENDING_FORM_RECOVERY_FAILED"
        })

        replacementGate.finish(
            data: testAssetData(id: "first", owner: "user-1"), status: 200)
        await replacement.value
        #expect(vm.showFormSheet)
        #expect(vm.formAssetId == "first")
        #expect(try fixture.store.contains(second))
    }

    @Test(.timeLimit(.minutes(1)))
    func sameGenerationReconnectRetriesWithoutReportingAnObsoleteFailure() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        _ = try fixture.store.save(testForm("asset"), for: scope)
        let gate = RecoveryResponseTestGate()
        let state = FormTestState()
        let retryStarted = AsyncStream<Void>.makeStream()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                let attempt = await MainActor.run {
                    state.calls += 1
                    return state.calls
                }
                if attempt == 1 { return await gate.waitForResponse() }
                return (testAssetData(id: "asset", owner: "user-1"), testHTTPResponse(200))
            })
        let original = Task { await vm.recoverPendingFormIfNeeded() }
        defer {
            gate.finish(status: 500)
            original.cancel()
        }
        try await gate.waitForStart()
        let retry = Task {
            retryStarted.continuation.yield(())
            await vm.recoverPendingFormIfNeeded()
        }
        defer { retry.cancel() }
        var iterator = retryStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
        gate.finish(status: 500)
        await retry.value
        await original.value
        #expect(vm.showFormSheet)
        #expect(state.calls >= 2)
        #expect(!vm.messages.contains {
            $0.content.code == "IOS_PENDING_FORM_RECOVERY_FAILED"
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func queuedRecoveryRetriesFailedRecordBeforeRestoringLaterRecord() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        _ = try fixture.store.save(testForm("first", savedAt: 1), for: scope)
        let second = try fixture.store.save(testForm("second", savedAt: 2), for: scope)
        let gate = RecoveryResponseTestGate()
        let state = FormTestState()
        let retryStarted = AsyncStream<Void>.makeStream()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { request in
                let id = request.url?.lastPathComponent ?? ""
                if id == "first" {
                    let attempt = await MainActor.run {
                        state.calls += 1
                        return state.calls
                    }
                    if attempt == 1 { return await gate.waitForResponse() }
                }
                return (testAssetData(id: id, owner: "user-1"), testHTTPResponse(200))
            })
        let original = Task { await vm.recoverPendingFormIfNeeded() }
        defer {
            gate.finish(status: 500)
            original.cancel()
        }
        try await gate.waitForStart()
        let retry = Task {
            retryStarted.continuation.yield(())
            await vm.recoverPendingFormIfNeeded()
        }
        defer { retry.cancel() }
        var iterator = retryStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
        gate.finish(status: 500)
        await retry.value
        await original.value
        #expect(vm.formAssetId == "first")
        #expect(try fixture.store.contains(second))
        #expect(!vm.messages.contains {
            $0.content.code == "IOS_PENDING_FORM_RECOVERY_FAILED"
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func reconnectSupersedesAStalledSameGenerationLookup() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        _ = try fixture.store.save(testForm("asset"), for: scope)
        let oldGate = RecoveryResponseTestGate()
        let replacementGate = RecoveryResponseTestGate()
        let state = FormTestState()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                let attempt = await MainActor.run {
                    state.calls += 1
                    return state.calls
                }
                if attempt == 1 { return await oldGate.waitForResponse() }
                if attempt == 2 { return await replacementGate.waitForResponse() }
                return (testAssetData(id: "asset", owner: "user-1"), testHTTPResponse(200))
            })
        let original = Task { await vm.recoverPendingFormIfNeeded() }
        defer {
            oldGate.finish(status: 500)
            replacementGate.finish(status: 500)
            original.cancel()
        }
        try await oldGate.waitForStart()
        let replacement = Task { await vm.recoverPendingFormIfNeeded(restartInFlight: true) }
        defer { replacement.cancel() }
        try await replacementGate.waitForStart()
        replacementGate.finish(data: testAssetData(id: "asset", owner: "user-1"), status: 200)
        await replacement.value
        #expect(vm.formAssetId == "asset")
        oldGate.finish(status: 500)
        await original.value
        #expect(!vm.messages.contains {
            $0.content.code == "IOS_PENDING_FORM_RECOVERY_FAILED"
        })
    }

    @Test
    func modalBlockedLiveRequestIsPreservedUntilPresentationResumes() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let ws = WebSocketService()
        let state = FormTestState()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run { state.calls += 1 }
                return (testAssetData(id: "asset", owner: "user-1"), testHTTPResponse(200))
            })

        vm.setFormPresentationBlocked(true)
        ws.onFormRequest?(["assetId": "asset", "originalFileName": "asset.mov"])
        #expect(!vm.showFormSheet)
        let record = try #require(try fixture.store.record(assetId: "asset", for: scope))
        await vm.recoverPendingFormIfNeeded()
        #expect(state.calls == 0)
        #expect(!vm.showFormSheet)
        #expect(try fixture.store.contains(record))

        vm.setFormPresentationBlocked(false)
        await vm.recoverPendingFormIfNeeded()
        #expect(state.calls == 1)
        #expect(vm.showFormSheet)
        #expect(vm.formAssetId == "asset")
    }

    @Test
    func currentUploadFormRetriesAfterPickerClosesWithoutRestoringAnotherAsset() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let other = try fixture.store.save(testForm("other", savedAt: 1), for: scope)
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { request in
                #expect(request.url?.lastPathComponent == "current")
                return (testAssetData(id: "current", owner: "user-1"), testHTTPResponse(200))
            })
        vm.currentAssetId = "current"
        vm.isUploading = true
        vm.beginVideoSelection()
        ws.onFormRequest?(["assetId": "current", "originalFileName": "current.mov"])
        #expect(!vm.showFormSheet)
        vm.isArchived = true
        vm.endVideoSelection()

        await vm.recoverPendingFormIfNeeded()
        #expect(vm.showFormSheet)
        #expect(vm.formAssetId == "current")
        #expect(try fixture.store.contains(other))
    }

    @Test
    func skippedFormDoesNotReopenAfterDuplicateRequestOrRelaunch() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let ws = WebSocketService()
        let state = FormTestState()
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { _ in
            await MainActor.run { state.calls += 1 }
            return (testAssetData(id: "asset", owner: "user-1"), testHTTPResponse(200))
        }
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store, httpTransport: transport)
        ws.onFormRequest?(["assetId": "asset"])
        #expect(vm.showFormSheet)
        vm.cancelForm()
        #expect(try fixture.store.record(assetId: "asset", for: scope)?.autoRecover == false)
        ws.onFormRequest?(["assetId": "asset"])
        #expect(!vm.showFormSheet)
        #expect(try fixture.store.record(assetId: "asset", for: scope)?.autoRecover == false)

        let relaunched = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: transport)
        await relaunched.recoverPendingFormIfNeeded()
        #expect(!relaunched.showFormSheet)
        #expect(state.calls == 0)
    }

    @Test
    func recoveryRetriesAfterPickerClosesDuringLookup() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        _ = try fixture.store.save(testForm("old"), for: scope)
        let state = FormTestState()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                let action = await MainActor.run {
                    state.calls += 1
                    return state.calls == 1 ? state.asyncAction : nil
                }
                await action?()
                return (testAssetData(id: "old", owner: "user-1"), testHTTPResponse(200))
            })
        state.asyncAction = { [weak vm] in
            guard let vm else { return }
            vm.beginVideoSelection()
            vm.endVideoSelection()
            await vm.recoverPendingFormIfNeeded()
        }

        await vm.recoverPendingFormIfNeeded()
        #expect(vm.showFormSheet)
        #expect(vm.formAssetId == "old")
        #expect(state.calls >= 2)
    }

    @Test
    func creationReservesWorkflowAndStopsAfterSessionChange() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let auth = testAuth()
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let ws = WebSocketService()
        let state = FormTestState()
        let file = fixture.directory.appendingPathComponent("synthetic.mov")
        try Data("test".utf8).write(to: file)
        let vm = ChatViewModel(
            auth: auth, ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run {
                    state.calls += 1
                    ws.onFormRequest?(["assetId": "other"])
                    auth.token = "new-session"
                }
                return (testAssetData(id: "created", owner: "user-1"), testHTTPResponse(200))
            })
        vm.stagedVideo = StagedVideo(
            tempFileURL: file, fileName: "synthetic.mov", createdDate: nil, thumbnail: nil,
            metadata: VideoMetadata(
                duration: 1, resolution: "test", codec: "test", orientation: "landscape",
                deviceModel: "test", osVersion: "test", capturedAt: nil,
                gpsLat: nil, gpsLon: nil, gpsAltitude: nil), phAssetIdentifier: nil)

        let stagedID = try #require(vm.stagedVideo?.id)
        await vm.confirmStagedUpload(id: stagedID, transcribe: false)
        #expect(!vm.showFormSheet)
        #expect(vm.currentAssetId == nil)
        #expect(try fixture.store.record(assetId: "other", for: scope) != nil)
        #expect(state.calls == 1)
    }

    @Test
    func presentedFormStaysBoundToItsOriginalAsset() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { request in
                #expect(request.url?.lastPathComponent == "form")
                #expect(request.url?.deletingLastPathComponent().lastPathComponent == "first")
                return (testFormReceipt("first"), testHTTPResponse(200))
            })
        ws.onFormRequest?(["assetId": "first"])
        vm.currentAssetId = "second"
        ws.onFormRequest?(["assetId": "second"])
        #expect(vm.formAssetId == "first")
        await vm.submitForm(assetId: "first", formData: ["slug": "test"])
        #expect(!vm.showFormSheet)
        #expect(vm.formDismissed() == "Details sent.")
    }

    @Test
    func oldReadyEventDoesNotReplaceCurrentConversation() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in throw URLError(.notConnectedToInternet) })
        ws.onFormRequest?(["assetId": "current"])
        ws.onMuxReady?(["assetId": "old", "mediasourceId": "old-media"])
        #expect(vm.currentAssetId == "current")
        #expect(!vm.isArchived)
        #expect(vm.archive.assetId == nil)
    }

    @Test
    func oldAssetMessagesCannotAppearInCurrentConversation() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in throw URLError(.notConnectedToInternet) })
        vm.currentAssetId = "current"
        func message(_ id: String, assetId: String) -> ChatMessage {
            ChatMessage(
                id: id, userId: nil, assetId: assetId, direction: .incoming,
                messageType: .text, content: MessageContent(text: id), createdAt: nil)
        }
        ws.onMessage?(message("old", assetId: "old"))
        ws.onMessage?(message("current", assetId: "current"))
        #expect(vm.messages.map(\.id) == ["current"])
    }

    @Test
    func delayedReadyFollowupCannotAppearInNewConversation() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in throw URLError(.notConnectedToInternet) })
        vm.currentAssetId = "old"
        ws.onMuxReady?(["assetId": "old", "mediasourceId": "old-media"])
        #expect(vm.archive.assetId == "old")
        #expect(vm.messages.contains { $0.content.code == "IOS_MUX_READY_SUMMARY" })
        vm.startNewConversation()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!vm.messages.contains { $0.content.code == "IOS_MUX_READY_FOLLOWUP" })
    }

    @Test
    func lateAssetLookupCannotReplaceCurrentMetadata() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = FormTestState()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run { state.action?() }
                return (testAssetData(id: "old", owner: "user-1"), testHTTPResponse(200))
            })
        vm.currentAssetId = "old"
        state.action = { [weak vm] in vm?.currentAssetId = "current" }
        await vm.fetchAssetDetail(assetId: "old")
        #expect(vm.currentAssetId == "current")
        #expect(vm.lastAsset == nil)
    }

    @Test
    func legacyNoticeDoesNotRevealTheOldForm() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let legacy = Data(#"{"assetId":"private-asset","originalFileName":"private.mov"}"#.utf8)
        try legacy.write(to: fixture.legacyURL)
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in throw URLError(.notConnectedToInternet) })

        await vm.recoverPendingFormIfNeeded()
        let notice = try #require(
            vm.messages.first { $0.content.code == "IOS_LEGACY_PENDING_FORM" })
        #expect(!notice.displayText.contains("private-asset"))
        #expect(!notice.displayText.contains("private.mov"))
        #expect(!vm.showFormSheet)
        #expect(try Data(contentsOf: fixture.legacyURL) == legacy)
    }

    @Test
    func currentSessionRestoresItsOwnForm() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let record = try fixture.store.save(testForm("asset"), for: scope)
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                (testAssetData(id: "asset", owner: "user-1"), testHTTPResponse(200))
            })

        await vm.recoverPendingFormIfNeeded()
        #expect(vm.showFormSheet)
        #expect(vm.currentAssetId == "asset")
        #expect(vm.form.originalFileName == "asset.mov")
        #expect(try fixture.store.contains(record))
    }

    @Test
    func newFormIsNotOverwrittenByAnInFlightRecovery() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let oldRecord = try fixture.store.save(testForm("old"), for: scope)
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run {
                    ws.onFormRequest?(["assetId": "new", "originalFileName": "new.mov"])
                }
                return (testAssetData(id: "old", owner: "user-1"), testHTTPResponse(200))
            })

        await vm.recoverPendingFormIfNeeded()
        #expect(vm.showFormSheet)
        #expect(vm.currentAssetId == "new")
        #expect(vm.form.originalFileName == "new.mov")
        #expect(try fixture.store.contains(oldRecord))
        #expect(try fixture.store.record(assetId: "new", for: scope) != nil)
    }

    @Test(arguments: [false, true])
    func videoSelectionPreventsInFlightRecovery(closesBeforeResponse: Bool) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let record = try fixture.store.save(testForm("old"), for: scope)
        let state = FormTestState()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run { state.action?() }
                return (testAssetData(id: "old", owner: "user-1"), testHTTPResponse(200))
            })
        state.action = { [weak vm] in
            vm?.beginVideoSelection()
            if closesBeforeResponse { vm?.endVideoSelection() }
        }

        await vm.recoverPendingFormIfNeeded()
        #expect(!vm.showFormSheet)
        #expect(vm.currentAssetId == nil)
        #expect(try fixture.store.contains(record))
    }

    @Test
    func incomingFormDoesNotInterruptVideoSelection() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in throw URLError(.notConnectedToInternet) })
        vm.beginVideoSelection()
        ws.onFormRequest?(["assetId": "asset", "originalFileName": "asset.mov"])
        #expect(!vm.showFormSheet)
        #expect(try fixture.store.record(assetId: "asset", for: scope) != nil)
        #expect(vm.messages.contains { $0.content.code == "IOS_PENDING_FORM_IN_ARCHIVE" })
    }

    @Test
    func incomingFormDoesNotReplaceAnOpenForm() throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in throw URLError(.notConnectedToInternet) })
        ws.onFormRequest?(["assetId": "first"])
        ws.onFormRequest?(["assetId": "second"])
        #expect(vm.showFormSheet)
        #expect(vm.currentAssetId == "first")
        #expect(try fixture.store.record(assetId: "first", for: scope) != nil)
        #expect(try fixture.store.record(assetId: "second", for: scope) != nil)
    }

    @Test
    func changedSessionDoesNotRestoreOrClearAnOldForm() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let auth = testAuth()
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let record = try fixture.store.save(testForm("asset"), for: scope)
        let vm = ChatViewModel(
            auth: auth, ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run { auth.token = "different-test-session" }
                return (
                    testAssetData(id: "asset", owner: "user-1", completed: true),
                    testHTTPResponse(200)
                )
            })

        await vm.recoverPendingFormIfNeeded()
        #expect(!vm.showFormSheet)
        #expect(try fixture.store.contains(record))
    }

    @Test
    func returningToTheSameTokenDoesNotReviveAnOldSession() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let auth = testAuth()
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let record = try fixture.store.save(testForm("asset"), for: scope)
        let vm = ChatViewModel(
            auth: auth, ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run {
                    let originalToken = auth.token
                    auth.token = nil
                    auth.token = originalToken
                }
                return (
                    testAssetData(id: "asset", owner: "user-1", completed: true),
                    testHTTPResponse(200)
                )
            })

        await vm.recoverPendingFormIfNeeded()
        #expect(!vm.showFormSheet)
        #expect(try fixture.store.contains(record))
    }

    @Test(arguments: [401, 403, 404, 500])
    func submissionFailureKeepsTheFormOpen(status: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let auth = testAuth()
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: auth, ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in (Data(), testHTTPResponse(status)) })
        ws.onFormRequest?(["assetId": "asset", "originalFileName": "asset.mov"])
        let record = try #require(try fixture.store.record(assetId: "asset", for: scope))

        await vm.submitForm(assetId: "asset", formData: ["slug": "test"])
        #expect(vm.showFormSheet)
        #expect(vm.form.submitError != nil)
        #expect(!vm.isSubmittingForm)
        #expect(try fixture.store.contains(record))
    }

    @Test
    func submissionSuccessClosesTheFormAndKeepsOtherRecords() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let other = try fixture.store.save(testForm("other"), for: scope)
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in (testFormReceipt("asset"), testHTTPResponse(200)) })
        ws.onFormRequest?(["assetId": "asset"])
        let record = try #require(try fixture.store.record(assetId: "asset", for: scope))

        await vm.submitForm(assetId: "asset", formData: ["slug": "test"])
        #expect(!vm.showFormSheet)
        #expect(try !fixture.store.contains(record))
        #expect(try fixture.store.contains(other))
    }

    @Test
    func successfulSubmissionAnnouncesRecoveryCleanupFailure() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let corrupt = Data("{invalid".utf8)
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in
                try await MainActor.run { try corrupt.write(to: fixture.storageURL) }
                return (testFormReceipt("asset"), testHTTPResponse(200))
            })
        ws.onFormRequest?(["assetId": "asset"])

        await vm.submitForm(assetId: "asset", formData: ["slug": "test"])
        #expect(!vm.showFormSheet)
        #expect(vm.messages.contains { $0.content.code == "IOS_PENDING_FORM_CLEAR_FAILED" })
        #expect(
            vm.formDismissed()
                == "Details sent, but the saved recovery state couldn't be updated.")
        #expect(vm.formDismissed() == nil)
        #expect(try Data(contentsOf: fixture.storageURL) == corrupt)
    }

    @Test
    func timedOutSubmissionKeepsTheFormOpenForRetry() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in throw URLError(.timedOut) })
        ws.onFormRequest?(["assetId": "asset"])
        let record = try #require(try fixture.store.record(assetId: "asset", for: scope))

        await vm.submitForm(assetId: "asset", formData: ["slug": "test"])
        #expect(vm.showFormSheet)
        #expect(vm.form.submitError == "Couldn't confirm the details were sent. Retry or check Archive.")
        #expect(vm.formDismissed() == nil)
        #expect(!vm.isSubmittingForm)
        #expect(try fixture.store.contains(record))
    }

    @Test(arguments: ["", "<html>Signed in</html>", #"{"formResponse":{"id":"form","assetId":"other"}}"#])
    func invalidFormReceiptsKeepTheFormOpen(body: String) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: testAuth(), ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in
                (Data(body.utf8), testHTTPResponse(body.isEmpty ? 204 : 200))
            })
        ws.onFormRequest?(["assetId": "asset"])
        let record = try #require(try fixture.store.record(assetId: "asset", for: scope))

        await vm.submitForm(assetId: "asset", formData: ["slug": "test"])
        #expect(vm.showFormSheet)
        #expect(vm.form.submitError != nil)
        #expect(try fixture.store.contains(record))
    }

    @Test
    func staleSubmissionDoesNotCloseOrClearTheForm() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let auth = testAuth()
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let ws = WebSocketService()
        let vm = ChatViewModel(
            auth: auth, ws: ws, pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run {
                    auth.currentUser = User(
                        id: "user-2", phoneNumber: "5550101", name: "Other", email: nil,
                        team: nil, status: "ACTIVE", companyCode: nil, companyName: nil)
                    auth.token = "other-test-session"
                }
                return (Data(), testHTTPResponse(200))
            })
        ws.onFormRequest?(["assetId": "asset"])
        let record = try #require(try fixture.store.record(assetId: "asset", for: scope))

        await vm.submitForm(assetId: "asset", formData: ["slug": "test"])
        #expect(vm.showFormSheet)
        #expect(vm.form.submitError == nil)
        #expect(try fixture.store.contains(record))
    }

    @Test(arguments: [200, 204, 401, 403, 404, 500])
    func transcriptBubbleReflectsServerResponse(status: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { request in
                #expect(request.url?.path.hasSuffix("/assets/asset/clips/clip-1/transcript") == true)
                return (status == 204 ? Data() : testTranscriptReceipt(), testHTTPResponse(status))
            })
        let result = TranscriptionResult(text: "hello", segments: [])
        vm.messages = [
            ChatMessage(
                id: "transcribing", userId: nil, assetId: "asset", direction: .incoming,
                messageType: .text, content: MessageContent(code: "IOS_TRANSCRIBE_START"),
                createdAt: nil)
        ]
        await vm.deliverTranscriptAndUpdateBubble(
            assetId: "asset", clipId: "clip-1", result: result,
            messageId: "transcribing", createdAt: nil)
        let expectedCode =
            status == 200
            ? "IOS_TRANSCRIBE_SUCCESS" : "IOS_TRANSCRIBE_SAVE_FAILED"
        #expect(vm.messages.first?.content.code == expectedCode)
    }

    @Test(arguments: [false, true])
    func transcriptBubbleReportsInvalidAndNetworkResponses(offline: Bool) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                if offline { throw URLError(.notConnectedToInternet) }
                return (
                    Data(),
                    URLResponse(
                        url: URL(string: "https://example.test")!, mimeType: nil,
                        expectedContentLength: 0, textEncodingName: nil)
                )
            })
        vm.messages = [
            ChatMessage(
                id: "transcribing", userId: nil, assetId: "asset", direction: .incoming,
                messageType: .text, content: MessageContent(code: "IOS_TRANSCRIBE_START"),
                createdAt: nil)
        ]
        await vm.deliverTranscriptAndUpdateBubble(
            assetId: "asset", clipId: "clip-1",
            result: TranscriptionResult(text: "hello", segments: []),
            messageId: "transcribing", createdAt: nil)
        #expect(vm.messages.first?.content.code == "IOS_TRANSCRIBE_SAVE_FAILED")
    }

    @Test(arguments: [
        "",
        "<html>Signed in</html>",
        #"{"ok":false,"clipId":"clip-1"}"#,
        #"{"ok":true,"clipId":"other"}"#,
    ])
    func transcriptBubbleRejectsInvalidReceipts(body: String) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                (Data(body.utf8), testHTTPResponse(body.isEmpty ? 204 : 200))
            })
        vm.messages = [
            ChatMessage(
                id: "transcribing", userId: nil, assetId: "asset", direction: .incoming,
                messageType: .text, content: MessageContent(code: "IOS_TRANSCRIBE_START"),
                createdAt: nil)
        ]
        await vm.deliverTranscriptAndUpdateBubble(
            assetId: "asset", clipId: "clip-1",
            result: TranscriptionResult(text: "hello", segments: []),
            messageId: "transcribing", createdAt: nil)
        #expect(vm.messages.first?.content.code == "IOS_TRANSCRIBE_SAVE_FAILED")
    }

    @Test
    func staleTranscriptCompletionDoesNotUpdateTheBubble() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let auth = testAuth()
        let vm = ChatViewModel(
            auth: auth, ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                await MainActor.run { auth.token = "new-test-session" }
                return (testTranscriptReceipt(), testHTTPResponse(200))
            })
        vm.messages = [
            ChatMessage(
                id: "transcribing", userId: nil, assetId: "asset", direction: .incoming,
                messageType: .text, content: MessageContent(code: "IOS_TRANSCRIBE_START"),
                createdAt: nil)
        ]
        await vm.deliverTranscriptAndUpdateBubble(
            assetId: "asset", clipId: "clip-1",
            result: TranscriptionResult(text: "hello", segments: []),
            messageId: "transcribing", createdAt: nil)
        #expect(vm.messages.first?.content.code == "IOS_TRANSCRIBE_START")
    }

    @Test
    func cancelledTranscriptSaveDoesNotPublishAStaleFailure() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let gate = PhotoPreparationGate<Bool>()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                _ = await gate.wait()
                return (Data(), testHTTPResponse(500))
            })
        vm.messages = [
            ChatMessage(
                id: "transcribing", userId: nil, assetId: "asset", direction: .incoming,
                messageType: .text, content: MessageContent(code: "IOS_TRANSCRIBE_START"),
                createdAt: nil)
        ]
        let task = Task {
            await vm.deliverTranscriptAndUpdateBubble(
                assetId: "asset", clipId: "clip-1",
                result: TranscriptionResult(text: "hello", segments: []),
                messageId: "transcribing", createdAt: nil, fileName: "video.mov")
        }
        defer { gate.finish(true); task.cancel() }
        try await gate.waitForStart()
        task.cancel()
        gate.finish(true)
        await task.value
        #expect(vm.messages.first?.content.code == "IOS_TRANSCRIBE_START")
        #expect(vm.messages.count == 1)
    }

    @Test
    func earlierTranscriptFailureReportsItsOwnVideo() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let vm = ChatViewModel(
            auth: testAuth(), ws: WebSocketService(), pendingFormStore: fixture.store,
            httpTransport: { _ in
                started.continuation.yield(())
                for await _ in release.stream { break }
                return (Data(), testHTTPResponse(500))
            })
        vm.currentAssetId = "earlier"
        vm.messages = [
            ChatMessage(
                id: "earlier-transcription", userId: nil, assetId: "earlier",
                direction: .incoming, messageType: .text,
                content: MessageContent(code: "IOS_TRANSCRIBE_START"), createdAt: nil)
        ]
        let oldTranscript = Task {
            await vm.deliverTranscriptAndUpdateBubble(
                assetId: "earlier", clipId: "clip-1",
                result: TranscriptionResult(text: "hello", segments: []),
                messageId: "earlier-transcription", createdAt: nil, fileName: "earlier.mov")
        }
        defer {
            release.continuation.finish()
            oldTranscript.cancel()
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        vm.startNewConversation()
        vm.currentAssetId = "current"
        release.continuation.yield(())
        await oldTranscript.value

        let notice = try #require(
            vm.messages.first { $0.content.code == "IOS_PREVIOUS_TRANSCRIBE_RESULT" })
        #expect(notice.assetId == "earlier")
        #expect(notice.displayText.contains("earlier.mov"))
        #expect(notice.displayText.contains("wasn't saved"))
        #expect(vm.currentAssetId == "current")
    }
}

@MainActor
struct ArchiveVisibilityTests {
    private func asset(
        createdAt: String?, completed: Bool, status: AssetStatus = .ready,
        submittedAt: String? = nil, moderation: AssetModeration? = nil
    ) -> Asset {
        Asset(
            id: "asset", mediasourceId: nil, mediasourceUrl: nil, originalFileName: nil,
            status: status, clipCount: nil, totalDuration: nil, createdAt: createdAt, user: nil,
            clips: nil,
            formResponse: completed
                ? FormResponse(
                    id: "form", assetId: nil, slug: nil, type: nil,
                    description: nil, priority: nil, submittedAt: submittedAt)
                : nil,
            userId: nil, updatedAt: nil, moderation: moderation, uploadMode: .mux)
    }

    @Test
    func recentlySubmittedDetailsKeepAnOlderReadyAssetVisible() {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let old = "2000-01-01T00:00:00Z"
        #expect(ArchiveListView.isVisible(
            asset(createdAt: old, completed: true, submittedAt: DVUDateFormatting.isoString(from: cutoff)),
            cutoff: cutoff))
        #expect(!ArchiveListView.isVisible(
            asset(
                createdAt: old, completed: true,
                submittedAt: DVUDateFormatting.isoString(from: cutoff.addingTimeInterval(-1))),
            cutoff: cutoff))
    }

    @Test
    func oldUnfinishedUploadsRemainAvailableForManualRecovery() {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            ArchiveListView.isVisible(
                asset(createdAt: "2000-01-01T00:00:00Z", completed: false), cutoff: cutoff))
        #expect(
            !ArchiveListView.isVisible(
                asset(createdAt: "2000-01-01T00:00:00Z", completed: true), cutoff: cutoff))
        #expect(
            ArchiveListView.isVisible(
                asset(createdAt: "2030-01-01T00:00:00Z", completed: true), cutoff: cutoff))
        #expect(ArchiveListView.isVisible(asset(createdAt: nil, completed: true), cutoff: cutoff))
        #expect(
            ArchiveListView.isVisible(
                asset(createdAt: DVUDateFormatting.isoString(from: cutoff), completed: true),
                cutoff: cutoff))
        #expect(
            !ArchiveListView.isVisible(
                asset(
                    createdAt: DVUDateFormatting.isoString(from: cutoff.addingTimeInterval(-1)),
                    completed: true), cutoff: cutoff))
        for status in [AssetStatus.uploading, .processing, .error] {
            #expect(ArchiveListView.isVisible(
                asset(createdAt: "2000-01-01T00:00:00Z", completed: true, status: status),
                cutoff: cutoff))
        }
    }

    @Test
    func oldPausedAssetsRemainVisibleAndDoNotOfferUploadRecovery() {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let oldDate = "2000-01-01T00:00:00Z"
        let paused = asset(
            createdAt: oldDate, completed: true, status: .error, moderation: .paused)

        #expect(ArchiveListView.isVisible(paused, cutoff: cutoff))
        #expect(!paused.needsUploadRecovery(at: cutoff))
        #expect(!ArchiveListView.isVisible(
            asset(createdAt: oldDate, completed: true), cutoff: cutoff))
    }

    @Test
    func pausedAssetSnapshotInvalidatesRetryIntent() throws {
        let owner = ArchiveMediaTaskOwner()
        let scope = try #require(
            PendingFormScope(userId: "user-1", serverURL: ServerConfig.baseURL))
        let generation = UUID()
        let active = asset(createdAt: "2000-01-01T00:00:00Z", completed: true, status: .error)
        let paused = asset(
            createdAt: "2000-01-01T00:00:00Z", completed: true,
            status: .error, moderation: .paused)
        owner.updateAssetSnapshot([active], scope: scope, sessionGeneration: generation)
        let intent = try #require(owner.retryIntent(
            for: active, scope: scope, sessionGeneration: generation))

        owner.updateAssetSnapshot([paused], scope: scope, sessionGeneration: generation)

        #expect(!owner.intentIsCurrent(
            intent, assetId: active.id, scope: scope, sessionGeneration: generation))
        #expect(owner.retryIntent(
            for: paused, scope: scope, sessionGeneration: generation) == nil)
    }

    @Test
    func uploadRecoveryUsesTheFiveMinuteBoundary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for status in [AssetStatus.uploading, .processing] {
            #expect(!asset(
                createdAt: DVUDateFormatting.isoString(from: now.addingTimeInterval(-300)),
                completed: true, status: status).needsUploadRecovery(at: now))
            #expect(asset(
                createdAt: DVUDateFormatting.isoString(from: now.addingTimeInterval(-301)),
                completed: true, status: status).needsUploadRecovery(at: now))
        }
        #expect(asset(createdAt: nil, completed: true, status: .error).needsUploadRecovery(at: now))
        #expect(!asset(createdAt: nil, completed: true, status: .ready).needsUploadRecovery(at: now))
    }
}

@MainActor
struct SessionBoundaryTests {
    @Test
    func appTransportSecurityDoesNotAllowUnrestrictedHTTP() {
        let settings = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        #expect(settings?["NSAllowsArbitraryLoads"] as? Bool != true)
        #expect(settings?["NSAllowsLocalNetworking"] as? Bool != true)
    }

    @Test
    func insecureMuxCapabilityIsRejectedBeforeStartingATransfer() async throws {
        let response = Data(#"{"uploadUrl":"http://127.0.0.1:9/upload","clipId":"clip"}"#.utf8)
        let uploader = VideoUploadService(
            createTransport: { _ in (response, testHTTPResponse(200)) },
            transfer: LoopbackVideoUploadTransfer(endpoint: URL(string: "http://127.0.0.1:9/upload")!))
        do {
            _ = try await uploader.uploadViaMux(
                assetId: "asset", fileURL: URL(fileURLWithPath: "/nonexistent-video"),
                token: "test-token", serverURL: URL(string: "https://example.test")!,
                isCurrent: { true })
            Issue.record("An insecure Mux capability must not be used")
        } catch UploadError.invalidResponse {
        } catch {
            Issue.record("Unexpected upload error: \(error)")
        }
        #expect(uploader.backgroundTransferStartCount == 0)
    }

    @Test(arguments: [false, true])
    func delayedReconnectOnlyRunsForItsOwnGeneration(invalidate: Bool) async throws {
        let gate = PhotoPreparationGate<Bool>()
        let coordinator = WebSocketRetryCoordinator(sleep: { _ in
            _ = await gate.wait()
        })
        var retries = 0
        let task = coordinator.schedule(after: 1) { retries += 1 }
        try await gate.waitForStart()
        if invalidate { coordinator.invalidate() }
        gate.finish(true)
        await task.value
        #expect(retries == (invalidate ? 0 : 1))
    }

    @Test(arguments: [false, true])
    func stoppedHandshakeCannotOpenSocket(serverChanged: Bool) async throws {
        let gate = HandshakeTestGate()
        defer { gate.finish() }
        let state = SocketURLTestState()
        let ws = WebSocketService(
            serverURL: { state.url },
            handshakeTransport: { _ in await gate.waitForResponse() })
        defer { ws.disconnect() }
        let task = try #require(ws.connect(token: "synthetic-token"))
        await gate.waitForStart()
        if serverChanged {
            state.url = URL(string: "https://127.0.0.1:10/proxy")!
        } else {
            ws.disconnect()
        }
        gate.finish()
        await task.value
        #expect(ws.state == .disconnected)
        #expect(!ws.hasActiveSocket)
    }

    @Test
    func cancellingHandshakeReleasesItsConnectionWithoutWaitingForTransport() async throws {
        let oldGate = HandshakeTestGate()
        let replacementGate = HandshakeTestGate()
        defer { oldGate.finish(); replacementGate.finish() }
        let ws = WebSocketService(handshakeTransport: { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-token" {
                return await replacementGate.waitForResponse()
            }
            return await oldGate.waitForResponse()
        })
        defer { ws.disconnect() }
        let task = try #require(ws.connect(token: "synthetic-token"))
        await oldGate.waitForStart()

        let disconnected = AsyncStream<Void>.makeStream()
        defer { disconnected.continuation.finish() }
        withObservationTracking {
            _ = ws.state
        } onChange: {
            disconnected.continuation.yield(())
        }
        task.cancel()
        try await withThrowingTaskGroup(of: Void.self) { group in
            let stream = disconnected.stream
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw RecoveryGateTimeout()
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        #expect(ws.state == .disconnected)
        let replacement = try #require(ws.connect(token: "replacement-token"))
        await replacementGate.waitForStart()
        oldGate.finish()
        await task.value
        #expect(ws.state == .connecting)
        #expect(ws.connect(token: "third-token") == nil)
        ws.disconnect()
        replacementGate.finish()
        await replacement.value
        #expect(ws.state == .disconnected)
    }

    @Test
    func cancellingBackoffReleasesItsConnection() async throws {
        let reconnecting = AsyncStream<Void>.makeStream()
        let ws = WebSocketService(handshakeTransport: { _ in (Data(), testHTTPResponse(500)) })
        ws.onReconnecting = { _, _ in reconnecting.continuation.yield(()) }
        defer { reconnecting.continuation.finish(); ws.disconnect() }
        let task = try #require(ws.connect(token: "synthetic-token"))
        var iterator = reconnecting.stream.makeAsyncIterator()
        _ = await iterator.next()

        task.cancel()
        await task.value
        #expect(ws.state == .disconnected)
        let replacement = try #require(ws.connect(token: "replacement-token"))
        ws.disconnect()
        await replacement.value
    }

    @Test
    func invalidatedSessionCannotProcessSocketAcknowledgementsOrEvents() async throws {
        let gate = HandshakeTestGate()
        defer { gate.finish() }
        let state = SocketURLTestState()
        let coordinator = WebSocketRetryCoordinator()
        let ws = WebSocketService(
            serverURL: { state.url },
            handshakeTransport: { _ in await gate.waitForResponse() },
            retryCoordinator: coordinator)
        defer { ws.disconnect() }
        var connections = 0
        var events = 0
        ws.onConnected = { connections += 1 }
        ws.onFormRequest = { _ in events += 1 }
        let connection = ws.connect(token: "synthetic-token", isCurrent: { state.sessionIsCurrent })
        let task = try #require(connection)
        await gate.waitForStart()
        let generation = coordinator.generation

        state.sessionIsCurrent = false
        ws.receiveEngineIOMessage("40{}", generation: generation)
        ws.receiveEngineIOMessage(
            #"42["form:request",{"assetId":"asset"}]"#, generation: generation)
        #expect(connections == 0)
        #expect(events == 0)
        #expect(ws.state == .disconnected)
        gate.finish()
        await task.value
        #expect(!ws.hasActiveSocket)
    }

    @Test
    func overlappingLoginsDoNotStartAnotherRequest() async throws {
        let state = FormTestState()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let auth = AuthService(
            storage: .memory,
            transport: { _ in
                await MainActor.run { state.calls += 1 }
                started.continuation.yield(())
                for await _ in release.stream { break }
                return (Data(#"{"error":"Rejected"}"#.utf8), testHTTPResponse(401))
            })
        let first = Task {
            try await auth.login(phoneNumber: "5550100", pin: "1111", companyCode: "TEST")
        }
        defer {
            release.continuation.finish()
            first.cancel()
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        do {
            try await auth.login(phoneNumber: "5550101", pin: "2222", companyCode: "TEST")
            Issue.record("Expected an overlapping sign-in to be rejected")
        } catch AuthError.loginInProgress {
        } catch {
            Issue.record("Unexpected authentication error: \(error)")
        }
        #expect(state.calls == 1)
        #expect(auth.isLoading)
        release.continuation.yield(())
        do {
            try await first.value
            Issue.record("Expected the first sign-in to be rejected by the server")
        } catch AuthError.loginFailed {
        } catch {
            Issue.record("Unexpected authentication error: \(error)")
        }
        #expect(!auth.isLoading)
        #expect(auth.currentUser == nil)
    }

    @Test
    func logoutInvalidatesLoginEvenWithoutAnExistingSession() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let auth = AuthService(
            storage: .memory,
            transport: { _ in
                started.continuation.yield(())
                for await _ in release.stream { break }
                return (Data(), testHTTPResponse(200))
            })
        let login = Task {
            try await auth.login(phoneNumber: "5550100", pin: "1111", companyCode: "TEST")
        }
        defer {
            release.continuation.finish()
            login.cancel()
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        auth.logout()
        release.continuation.yield(())
        do {
            try await login.value
            Issue.record("Expected logout to invalidate the pending sign-in")
        } catch AuthError.sessionChanged {
        } catch {
            Issue.record("Unexpected authentication error: \(error)")
        }
        #expect(auth.token == nil)
        #expect(auth.currentUser == nil)
    }

    @Test(arguments: [200, 401])
    func staleUserLookupCannotReplaceOrLogOutNewSession(status: Int) async throws {
        let state = FormTestState()
        let oldUser = User(
            id: "old", phoneNumber: "5550100", name: "Old", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let newUser = User(
            id: "new", phoneNumber: "5550101", name: "New", email: nil, team: nil,
            status: "ACTIVE", companyCode: nil, companyName: nil)
        let payload = try JSONEncoder().encode(MeResponse(user: oldUser))
        let auth = AuthService(
            storage: .memory,
            transport: { _ in
                await MainActor.run { state.action?() }
                return (payload, testHTTPResponse(status))
            })
        auth.token = "old-token"
        auth.currentUser = oldUser
        state.action = { [weak auth] in
            auth?.token = "new-token"
            auth?.currentUser = newUser
        }
        do {
            try await auth.fetchMe()
            Issue.record("Expected the stale response to be rejected")
        } catch AuthError.sessionChanged {
        } catch {
            Issue.record("Unexpected authentication error: \(error)")
        }
        #expect(auth.token == "new-token")
        #expect(auth.currentUser?.id == "new")
    }

    @Test
    func staleMuxCreationDoesNotStartTheFileUpload() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let state = FormTestState()
        let uploader = VideoUploadService(createTransport: { _ in
            await MainActor.run {
                state.calls += 1
                state.isCurrent = false
            }
            return (
                Data(#"{"uploadUrl":"https://example.test/never-upload","clipId":"clip"}"#.utf8),
                testHTTPResponse(200)
            )
        })
        do {
            _ = try await uploader.uploadViaMux(
                assetId: "asset", fileURL: fixture.directory.appendingPathComponent("video.mov"),
                token: "test-token", serverURL: URL(string: "https://example.test")!,
                isCurrent: { state.isCurrent })
            Issue.record("Expected session change to stop the upload")
        } catch UploadError.sessionChanged {
        } catch {
            Issue.record("Unexpected upload error: \(error)")
        }
        #expect(state.calls == 1)
    }

    @Test
    func sessionChangeStopsBeforeSpeechRecognition() async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let file = fixture.directory.appendingPathComponent("synthetic.mov")
        try Data("test".utf8).write(to: file)
        let authorizer = FakePermissionAuthorizer(photo: .authorized, speech: .authorized)
        let service = TranscriptionService(authorizer: authorizer)
        var checks = 0
        let result = await service.transcribe(videoURL: file, isCurrent: {
            checks += 1
            return checks == 1
        })
        #expect(result == nil)
        #expect(checks == 2)
        if case .requesting = service.state {
        } else {
            Issue.record("Recognition must not start after the session changes")
        }
    }
}

@MainActor
private final class LoopbackVideoUploadTransfer: VideoUploadTransfer {
    private let endpoint: URL

    init(endpoint: URL) {
        self.endpoint = endpoint
    }

    func upload(
        request: URLRequest, fileURL: URL, isCurrent: @MainActor () -> Bool,
        validateBeforeTransfer: (@MainActor () throws -> Void)?,
        onProgress: @escaping @MainActor (Double) -> Void,
        onStart: @MainActor () -> Void
    ) async throws -> (Data, URLResponse) {
        guard request.url?.scheme == "https",
              endpoint.scheme == "http", endpoint.host == "127.0.0.1" else {
            throw UploadError.invalidResponse
        }
        var loopbackRequest = request
        loopbackRequest.url = endpoint
        let cancellation = TaskCancellationBridge()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try Task.checkCancellation()
                    guard isCurrent() else { throw UploadError.sessionChanged }
                    try validateBeforeTransfer?()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let delegate = UploadDelegate(
                    onProgress: { progress in
                        Task { @MainActor in onProgress(progress) }
                    },
                    onComplete: { data, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, let response {
                            continuation.resume(returning: (data, response))
                        } else {
                            continuation.resume(throwing: UploadError.invalidResponse)
                        }
                    })
                let configuration = URLSessionConfiguration.background(
                    withIdentifier: "com.directvideo.upload.test.\(UUID().uuidString)")
                configuration.isDiscretionary = false
                configuration.waitsForConnectivity = true
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                let task = session.uploadTask(with: loopbackRequest, fromFile: fileURL)
                cancellation.register { task.cancel() }
                task.resume()
                onStart()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

nonisolated private final class LoopbackRedirectServer: @unchecked Sendable {
    private struct Connections {
        var stopped = false
        var connections: [NWConnection] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.loopback.redirect")
    private let forwarded = Mutex(0)
    private let receivedCookie = Mutex(false)
    private let receivedRequests = Mutex(0)
    private let receivedBasicCredential = Mutex(false)
    private let redirectTarget = Mutex<String?>(nil)
    private let pendingUpload = Mutex<NWConnection?>(nil)
    private let pendingExtraChunk = Mutex<NWConnection?>(nil)
    private let connections = Mutex(Connections())
    private let uploads = AsyncStream<Data>.makeStream()
    private let boundedPrefixes = AsyncStream<String>.makeStream()
    private let stalledResponses = AsyncStream<String>.makeStream()
    private let responseCancellations = AsyncStream<String>.makeStream()

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var forwardedCount: Int { forwarded.withLock { $0 } }
    var didReceiveCookie: Bool { receivedCookie.withLock { $0 } }
    var requestCount: Int { receivedRequests.withLock { $0 } }
    var didReceiveBasicCredential: Bool { receivedBasicCredential.withLock { $0 } }

    func redirect(to url: URL) {
        redirectTarget.withLock { $0 = url.absoluteString }
    }

    func resetBasicCredentialObservation() {
        receivedBasicCredential.withLock { $0 = false }
    }

    func start() async throws -> URL {
        let events = AsyncThrowingStream<UInt16, any Error>.makeStream()
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            let accepted = self.connections.withLock { state in
                guard !state.stopped else { return false }
                state.connections.append(connection)
                connection.start(queue: self.queue)
                return true
            }
            guard accepted else {
                connection.cancel()
                return
            }
            self.receive(connection, data: Data())
        }
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    events.continuation.yield(port)
                    events.continuation.finish()
                }
            case .failed(let error):
                events.continuation.finish(throwing: error)
            default:
                break
            }
        }
        listener.start(queue: queue)
        for try await port in events.stream {
            return URL(string: "http://127.0.0.1:\(port)")!
        }
        throw URLError(.cannotConnectToHost)
    }

    func stop() {
        let accepted = connections.withLock { state in
            state.stopped = true
            let accepted = state.connections
            state.connections.removeAll()
            return accepted
        }
        listener.cancel()
        uploads.continuation.finish()
        boundedPrefixes.continuation.finish()
        stalledResponses.continuation.finish()
        responseCancellations.continuation.finish()
        let connection = pendingUpload.withLock { pending in
            let connection = pending
            pending = nil
            return connection
        }
        connection?.cancel()
        pendingExtraChunk.withLock { $0 = nil }
        for connection in accepted { connection.cancel() }
    }

    func waitForUpload() async throws -> Data {
        let stream = uploads.stream
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let data = await iterator.next() else { throw URLError(.cannotConnectToHost) }
                return data
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw RecoveryGateTimeout()
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw CancellationError() }
            return data
        }
    }

    func completeUpload(status: Int = 200) -> Bool {
        let connection = pendingUpload.withLock { pending in
            let connection = pending
            pending = nil
            return connection
        }
        guard let connection else { return false }
        let reason = status == 200 ? "OK" : "Error"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
        return true
    }

    func waitForResponseCancellation() async throws -> String {
        try await waitForEvent(responseCancellations.stream)
    }

    func waitForStalledResponse() async throws -> String {
        try await waitForEvent(stalledResponses.stream)
    }

    func waitForBoundedPrefix() async throws -> String {
        try await waitForEvent(boundedPrefixes.stream)
    }

    func sendBoundedExtraByte() -> Bool {
        let connection = pendingExtraChunk.withLock { pending in
            let connection = pending
            pending = nil
            return connection
        }
        guard let connection else { return false }
        connection.send(content: Data("1\r\na\r\n".utf8), completion: .contentProcessed { _ in })
        return true
    }

    private func waitForEvent(_ stream: AsyncStream<String>) async throws -> String {
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let path = await iterator.next() else { throw URLError(.cannotConnectToHost) }
                return path
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw RecoveryGateTimeout()
            }
            defer { group.cancelAll() }
            guard let path = try await group.next() else { throw CancellationError() }
            return path
        }
    }

    private func sendBoundedResponse(_ connection: NWConnection, path: String) {
        let limit = 64 * 1024
        if path == "bounded-exact" {
            var response = Data(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(limit)\r\nConnection: close\r\n\r\n".utf8)
            response.append(Data(repeating: 0x61, count: limit))
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        watchForCancellation(connection, path: path)
        if path == "bounded-stall-headers" {
            stalledResponses.continuation.yield(path)
            return
        }
        let header: String
        var body = Data()
        if path == "bounded-declared-oversize" {
            header = "Content-Length: \(limit + 1)\r\n"
            body.append(0x61)
        } else if path.hasPrefix("bounded-stall-after-headers") {
            header = "Content-Length: 100\r\n"
        } else if path == "bounded-stall-body" {
            header = "Transfer-Encoding: chunked\r\n"
            body.append(Data("1\r\na\r\n".utf8))
        } else {
            header = "Transfer-Encoding: chunked\r\n"
            body.append(Data("\(String(limit, radix: 16))\r\n".utf8))
            body.append(Data(repeating: 0x61, count: limit))
            body.append(Data("\r\n".utf8))
        }
        let contentType = path == "bounded-stall-after-headers-no-type"
            ? "" : "Content-Type: application/json\r\n"
        var response = Data("HTTP/1.1 200 OK\r\n\(contentType)\(header)\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            if error == nil, path == "bounded-stall-body" || path.hasPrefix("bounded-stall-after-headers") {
                self?.stalledResponses.continuation.yield(path)
            } else if error == nil, path == "bounded-stream-oversize" {
                self?.pendingExtraChunk.withLock { $0 = connection }
                self?.boundedPrefixes.continuation.yield(path)
            }
        })
    }

    private func watchForCancellation(_ connection: NWConnection, path: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) {
            [weak self] _, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if complete || error != nil {
                self.responseCancellations.continuation.yield(path)
                connection.cancel()
            } else {
                self.watchForCancellation(connection, path: path)
            }
        }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] chunk, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var data = data
            if let chunk { data.append(chunk) }
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
                if complete {
                    connection.cancel()
                } else {
                    self.receive(connection, data: data)
                }
                return
            }
            let request = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
            self.receivedRequests.withLock { $0 += 1 }
            for path in [
                "bounded-exact", "bounded-declared-oversize", "bounded-stream-oversize",
                "bounded-stall-headers", "bounded-stall-after-headers",
                "bounded-stall-after-headers-no-type", "bounded-stall-body",
            ] {
                if request.contains(" /\(path) ") {
                    self.sendBoundedResponse(connection, path: path)
                    return
                }
            }
            if request.hasPrefix("PUT /upload ") {
                let lengthHeader = request.components(separatedBy: "\r\n").first {
                    $0.lowercased().hasPrefix("content-length:")
                }
                guard let lengthText = lengthHeader?.split(separator: ":", maxSplits: 1).last,
                      let length = Int(lengthText.trimmingCharacters(in: .whitespaces)) else {
                    connection.cancel()
                    self.uploads.continuation.finish()
                    return
                }
                let body = data[headerEnd.upperBound...]
                guard body.count >= length else {
                    if complete {
                        connection.cancel()
                        self.uploads.continuation.finish()
                    } else {
                        self.receive(connection, data: data)
                    }
                    return
                }
                self.pendingUpload.withLock { $0 = connection }
                self.uploads.continuation.yield(Data(body.prefix(length)))
                return
            }
            let status: String
            let headers: String
            if request.contains(" /set-cookie ") {
                status = "200 OK"
                headers = "Set-Cookie: dvu-cookie-test=synthetic; Path=/\r\n"
            } else if request.contains(" /check-cookie ") {
                self.receivedCookie.withLock {
                    $0 = request.lowercased().contains("cookie: dvu-cookie-test=synthetic")
                }
                status = "200 OK"
                headers = ""
            } else if request.contains(" /redirected ") {
                self.forwarded.withLock { $0 += 1 }
                status = "200 OK"
                headers = ""
            } else if request.contains(" /basic-challenge ") {
                self.receivedBasicCredential.withLock {
                    $0 = $0 || request.lowercased().contains("\r\nauthorization: basic ")
                }
                status = "401 Unauthorized"
                headers = "WWW-Authenticate: Basic realm=\"dvu-synthetic\"\r\n"
            } else {
                let code = request.contains("/redirect-302") ? 302
                    : request.contains("/redirect-308") ? 308 : 307
                status = "\(code) Redirect"
                let target = self.redirectTarget.withLock { $0 } ?? "/redirected"
                headers = "Location: \(target)\r\n"
            }
            let response = "HTTP/1.1 \(status)\r\n\(headers)Content-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

@MainActor
@Suite(.serialized)
struct RedirectTransportTests {
    private struct SignalTimeout: Error {
        let phase: String
    }

    private func waitForSignal<Value: Sendable>(
        _ stream: AsyncStream<Value>, timeout: Duration, phase: String
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let value = await iterator.next() else { throw CancellationError() }
                return value
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SignalTimeout(phase: phase)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func preCancelledBoundedRequestDoesNotStart() async throws {
        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let baseURL = try await server.start()
        let started = Mutex(false)
        let task = Task {
            try await RedirectSafeTransport.boundedData(
                for: URLRequest(url: baseURL.appendingPathComponent("bounded-stall-headers")),
                maximumBytes: 64 * 1024,
                onStart: { started.withLock { $0 = true } })
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled request must not start")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected pre-cancellation error: \(error)")
        }
        #expect(!started.withLock { $0 })
        #expect(server.requestCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func boundedResponsesEnforceTheLimitAndCancelUnfinishedStreams() async throws {
        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let baseURL = try await server.start()
        let limit = 64 * 1024
        var exactRequest = URLRequest(url: baseURL.appendingPathComponent("bounded-exact"))
        exactRequest.timeoutInterval = 10
        let (body, response) = try await RedirectSafeTransport.boundedData(
            for: exactRequest, maximumBytes: limit)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body == Data(repeating: 0x61, count: limit))

        let declaredPath = "bounded-declared-oversize"
        var declaredRequest = URLRequest(url: baseURL.appendingPathComponent(declaredPath))
        declaredRequest.timeoutInterval = 10
        do {
            _ = try await RedirectSafeTransport.boundedData(for: declaredRequest, maximumBytes: limit)
            Issue.record("An oversized declared response should fail")
        } catch let error as URLError {
            #expect(error.code == .dataLengthExceedsMaximum)
        } catch {
            Issue.record("Unexpected bounded response error: \(error)")
        }
        #expect(try await server.waitForResponseCancellation() == declaredPath)

        let streamPath = "bounded-stream-oversize"
        var streamRequest = URLRequest(url: baseURL.appendingPathComponent(streamPath))
        streamRequest.timeoutInterval = 10
        let consumed = AsyncStream<Int>.makeStream()
        let streamTask = Task {
            try await RedirectSafeTransport.boundedData(
                for: streamRequest, maximumBytes: limit,
                onBody: { _ = consumed.continuation.yield($0) })
        }
        defer { streamTask.cancel(); consumed.continuation.finish() }
        #expect(try await server.waitForBoundedPrefix() == streamPath)
        #expect(try await waitForSignal(consumed.stream, timeout: .seconds(5), phase: "first byte") == 1)
        #expect(try await waitForSignal(consumed.stream, timeout: .seconds(5), phase: "limit") == limit)
        #expect(server.sendBoundedExtraByte())
        do {
            _ = try await streamTask.value
            Issue.record("A streamed response over the limit should fail")
        } catch let error as URLError {
            #expect(error.code == .dataLengthExceedsMaximum)
        } catch {
            Issue.record("Unexpected streamed response error: \(error)")
        }
        #expect(try await server.waitForResponseCancellation() == streamPath)
    }

    @Test(.timeLimit(.minutes(1)))
    func callerCancellationStopsWaitingForHeadersAndBody() async throws {
        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let baseURL = try await server.start()
        for path in [
            "bounded-stall-headers", "bounded-stall-after-headers",
            "bounded-stall-after-headers-no-type", "bounded-stall-body",
        ] {
            let request = URLRequest(url: baseURL.appendingPathComponent(path))
            let responseStarted = AsyncStream<Void>.makeStream()
            let bodyStarted = AsyncStream<Void>.makeStream()
            let receivedResponse = Mutex(false)
            let task = Task {
                try await RedirectSafeTransport.boundedData(
                    for: request, maximumBytes: 64 * 1024,
                    onResponse: {
                        receivedResponse.withLock { $0 = true }
                        _ = responseStarted.continuation.yield(())
                    },
                    onBody: { _ in _ = bodyStarted.continuation.yield(()) })
            }
            defer {
                task.cancel()
                responseStarted.continuation.finish()
                bodyStarted.continuation.finish()
            }
            #expect(try await server.waitForStalledResponse() == path)
            if path == "bounded-stall-body" {
                try await waitForSignal(
                    responseStarted.stream, timeout: .seconds(5), phase: "\(path) response")
                try await waitForSignal(
                    bodyStarted.stream, timeout: .seconds(5), phase: "\(path) body")
            } else if path == "bounded-stall-headers" {
                #expect(!receivedResponse.withLock { $0 })
            }
            let completion = AsyncStream<String>.makeStream()
            let observer = Task {
                let outcome: String
                do {
                    _ = try await task.value
                    outcome = "completed"
                } catch is CancellationError {
                    outcome = "cancelled"
                } catch let error as URLError {
                    outcome = error.code == .cancelled ? "cancelled" : "URL error \(error.code.rawValue)"
                } catch {
                    outcome = "error \(error)"
                }
                completion.continuation.yield(outcome)
                completion.continuation.finish()
            }
            defer { observer.cancel(); completion.continuation.finish() }
            let started = ContinuousClock.now
            task.cancel()
            let outcome = try await waitForSignal(
                completion.stream, timeout: .seconds(5), phase: "\(path) cancellation")
            #expect(outcome == "cancelled", "\(path): \(outcome)")
            #expect(started.duration(to: .now) < .seconds(5))
            #expect(try await server.waitForResponseCancellation() == path)
        }
    }

    @Test
    func bearerTransportDoesNotPersistOrSendCookies() async throws {
        let configuration = RedirectSafeTransport.configuration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForResource == RedirectSafeTransport.resourceTimeout)

        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let baseURL = try await server.start()
        let (_, setResponse) = try await RedirectSafeTransport.data(
            for: URLRequest(url: baseURL.appendingPathComponent("set-cookie")))
        let (_, checkResponse) = try await RedirectSafeTransport.data(
            for: URLRequest(url: baseURL.appendingPathComponent("check-cookie")))
        #expect((setResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect((checkResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(!server.didReceiveCookie)
    }

    @Test(.timeLimit(.minutes(1)))
    func boundedBearerTransportDoesNotUseStoredChallengeCredentials() async throws {
        let configuration = RedirectSafeTransport.boundedConfiguration()
        #expect(configuration.urlCredentialStorage == nil)

        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let baseURL = try await server.start()
        let port = try #require(baseURL.port)
        let space = URLProtectionSpace(
            host: "127.0.0.1", port: port, protocol: "http",
            realm: "dvu-synthetic", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let credential = URLCredential(
            user: "synthetic-user", password: "synthetic-password", persistence: .forSession)
        let storage = URLCredentialStorage.shared
        storage.setDefaultCredential(credential, for: space)
        defer { storage.remove(credential, for: space) }
        #expect(storage.defaultCredential(for: space)?.user == "synthetic-user")

        let url = baseURL.appendingPathComponent("basic-challenge")
        var controlRequest = URLRequest(url: url)
        controlRequest.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        let (_, controlResponse) = try await RedirectSafeTransport.data(for: controlRequest)
        #expect((controlResponse as? HTTPURLResponse)?.statusCode == 401)
        #expect(server.didReceiveBasicCredential)
        server.resetBasicCredentialObservation()

        var request = URLRequest(url: url)
        request.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        let (_, response) = try await RedirectSafeTransport.boundedData(for: request, maximumBytes: 1_024)
        #expect((response as? HTTPURLResponse)?.statusCode == 401)
        #expect(!server.didReceiveBasicCredential)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [302, 307, 308])
    func boundedPostDoesNotForwardCredentialsOrBodyAcrossOrigins(status: Int) async throws {
        let origin = try LoopbackRedirectServer()
        let destination = try LoopbackRedirectServer()
        defer {
            origin.stop()
            destination.stop()
        }
        let originURL = try await origin.start()
        let destinationURL = try await destination.start()
        origin.redirect(to: destinationURL.appendingPathComponent("redirected"))

        var request = URLRequest(url: originURL.appendingPathComponent("redirect-\(status)"))
        request.httpMethod = "POST"
        request.httpBody = Data("synthetic-body".utf8)
        request.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        let (_, response) = try await RedirectSafeTransport.boundedData(for: request, maximumBytes: 1_024)
        #expect((response as? HTTPURLResponse)?.statusCode == status)
        #expect(destination.requestCount == 0)
    }

    @Test
    func socketURLsKeepTheConfiguredProxyPath() throws {
        let base = try #require(URL(string: "https://example.test/team%20one/"))
        let polling = try #require(WebSocketService.socketURL(baseURL: base, isWebSocket: false))
        let upgraded = try #require(
            WebSocketService.socketURL(baseURL: base, isWebSocket: true, sid: "session/id"))
        let pollParts = try #require(URLComponents(url: polling, resolvingAgainstBaseURL: false))
        let socketParts = try #require(URLComponents(url: upgraded, resolvingAgainstBaseURL: false))
        #expect(pollParts.scheme == "https")
        #expect(socketParts.scheme == "wss")
        #expect(pollParts.percentEncodedPath == "/team%20one/socket.io")
        #expect(socketParts.percentEncodedPath == "/team%20one/socket.io")
        #expect(pollParts.queryItems?.first(where: { $0.name == "transport" })?.value == "polling")
        #expect(socketParts.queryItems?.first(where: { $0.name == "transport" })?.value == "websocket")
        #expect(socketParts.queryItems?.first(where: { $0.name == "sid" })?.value == "session/id")
        #expect(WebSocketService.socketURL(
            baseURL: URL(string: "file:///tmp")!, isWebSocket: false) == nil)
    }

    @Test(arguments: [302, 307, 308])
    func realRedirectsAreNotFollowedOrTreatedAsSuccess(status: Int) async throws {
        let fixture = try FormTestFixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.save(testForm("asset"), for: fixture.scope)
        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let baseURL = try await server.start()
        let url = baseURL.appendingPathComponent("redirect-\(status)")

        var boundedRequest = URLRequest(url: url)
        boundedRequest.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        let (_, boundedResponse) = try await RedirectSafeTransport.boundedData(
            for: boundedRequest, maximumBytes: 1_024)
        #expect((boundedResponse as? HTTPURLResponse)?.statusCode == status)

        var formRequest = URLRequest(url: url)
        formRequest.httpMethod = "POST"
        do {
            _ = try await PendingFormSubmission(
                store: fixture.store, coordinator: PendingFormSubmissionCoordinator()
            ).submit(
                formData: ["slug": "synthetic"], request: formRequest, pendingRecord: record,
                scope: fixture.scope, assetId: "asset", isCurrent: { true })
            Issue.record("A redirect must not submit or clear a form")
        } catch FormSubmissionError.httpStatus(let actual) {
            #expect(actual == status)
        } catch {
            Issue.record("Unexpected form error: \(error)")
        }
        #expect(try fixture.store.contains(record))

        var transcriptRequest = URLRequest(url: url)
        transcriptRequest.httpMethod = "PATCH"
        do {
            try await TranscriptDelivery.send(
                TranscriptionResult(text: "synthetic", segments: []),
                clipId: "clip", request: transcriptRequest)
            Issue.record("A redirect must not save a transcript")
        } catch TranscriptDeliveryError.httpStatus(let actual) {
            #expect(actual == status)
        } catch {
            Issue.record("Unexpected transcript error: \(error)")
        }

        do {
            _ = try await PendingFormRecovery(store: fixture.store).next(
                for: fixture.scope, isCurrent: { true },
                requestForAsset: { _ in URLRequest(url: url) })
            Issue.record("A redirect must not restore a form")
        } catch PendingFormRecoveryError.httpStatus(let actual) {
            #expect(actual == status)
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
        }
        #expect(try fixture.store.contains(record))
        #expect(server.forwardedCount == 0)
    }
}

extension TranscriptDeliveryTests {
    @Test(arguments: [200, 201])
    func sendsTranscriptAndSegmentsOnSuccess(status: Int) async throws {
        let result = TranscriptionResult(
            text: "hello",
            segments: [TranscriptSegment(word: "hello", start: 0, end: 0.5, confidence: 0.9)])
        var request = URLRequest(url: URL(string: "https://example.test/transcript")!)
        request.httpMethod = "PATCH"
        try await TranscriptDelivery.send(
            result, clipId: "clip-1", request: request,
            transport: { request in
                #expect(request.httpMethod == "PATCH")
                let body = try #require(request.httpBody)
                let payload = try JSONDecoder().decode(Payload.self, from: body)
                #expect(payload.transcript == "hello")
                #expect(payload.clipId == "clip-1")
                #expect(payload.segments.count == 1)
                #expect(payload.segments.first?.word == "hello")
                #expect(payload.segments.first?.end == 0.5)
                return (testTranscriptReceipt(), testHTTPResponse(status))
            })
    }

    @Test(arguments: [301, 401, 403, 404, 500])
    func rejectsNonSuccessStatuses(status: Int) async throws {
        let result = TranscriptionResult(text: "hello", segments: [])
        let request = URLRequest(url: URL(string: "https://example.test/transcript")!)
        do {
            try await TranscriptDelivery.send(
                result, clipId: "clip-1", request: request,
                transport: { _ in
                    (Data(), testHTTPResponse(status))
                })
            Issue.record("Expected a transcript delivery failure")
        } catch TranscriptDeliveryError.httpStatus(let actual) {
            #expect(actual == status)
        } catch {
            Issue.record("Unexpected transcript error: \(error)")
        }
    }

    @Test(arguments: [
        "",
        "<html>Signed in</html>",
        #"{"ok":false,"clipId":"clip-1"}"#,
        #"{"ok":true,"clipId":"other"}"#,
    ])
    func rejectsInvalidSuccessReceipts(body: String) async throws {
        let result = TranscriptionResult(text: "hello", segments: [])
        let request = URLRequest(url: URL(string: "https://example.test/transcript")!)
        do {
            try await TranscriptDelivery.send(
                result, clipId: "clip-1", request: request,
                transport: { _ in
                    (Data(body.utf8), testHTTPResponse(body.isEmpty ? 204 : 200))
                })
            Issue.record("Expected an invalid receipt error")
        } catch TranscriptDeliveryError.invalidResponse {
        } catch {
            Issue.record("Unexpected transcript error: \(error)")
        }
    }

    @Test
    func rejectsInvalidAndNetworkResponses() async throws {
        let result = TranscriptionResult(text: "hello", segments: [])
        let request = URLRequest(url: URL(string: "https://example.test/transcript")!)
        do {
            try await TranscriptDelivery.send(
                result, clipId: "clip-1", request: request,
                transport: { _ in
                    (
                        Data(),
                        URLResponse(
                            url: URL(string: "https://example.test")!, mimeType: nil,
                            expectedContentLength: 0, textEncodingName: nil)
                    )
                })
            Issue.record("Expected an invalid-response error")
        } catch TranscriptDeliveryError.invalidResponse {
        } catch {
            Issue.record("Unexpected transcript error: \(error)")
        }
        do {
            try await TranscriptDelivery.send(
                result, clipId: "clip-1", request: request,
                transport: { _ in
                    throw URLError(.notConnectedToInternet)
                })
            Issue.record("Expected a network error")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("Unexpected transcript error: \(error)")
        }
    }
}

extension UploadFidelityTests {
    @Test
    func movedTrimHandlesCountAsTrimmed() {
        #expect(!TrimRange.isFullLength(start: 0.5, end: 30, duration: 30))
        #expect(!TrimRange.isFullLength(start: 0, end: 29.5, duration: 30))
        #expect(!TrimRange.isFullLength(start: 5, end: 10, duration: 30))
    }

    @Test
    func accessibilityStepScalesWithDuration() {
        #expect(TrimRange.accessibilityStep(duration: 20) == 0.5)
        #expect(TrimRange.accessibilityStep(duration: 120) == 1)
        #expect(TrimRange.accessibilityStep(duration: 900) == 5)
    }

    @Test
    func nudgedHandlesStayInBoundsAndKeepMinimumLength() {
        #expect(TrimRange.nudgedStart(0.2, end: 30, by: -0.5) == 0)
        #expect(TrimRange.nudgedStart(9, end: 10, by: 0.5) == 9)
        #expect(TrimRange.nudgedStart(5, end: 30, by: 1) == 6)
        #expect(TrimRange.nudgedEnd(29.8, start: 0, duration: 30, by: 0.5) == 30)
        #expect(TrimRange.nudgedEnd(6, start: 5, duration: 30, by: -0.5) == 6)
        #expect(TrimRange.nudgedEnd(20, start: 0, duration: 30, by: -1) == 19)
    }

    @Test
    func spokenTimeIsReadable() {
        #expect(TrimRange.spokenTime(62.5).contains("minute"))
        #expect(TrimRange.spokenTime(2.5).contains("2.5"))
        #expect(!TrimRange.spokenTime(5).contains("."))
    }

    @Test @MainActor
    func dismissingTrimImmediatelyCancelsPlayerLoading() async {
        let model = TrimViewModel()
        model.load(url: FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-trim.mov"))
        model.cleanup()

        await Task.yield()

        #expect(model.player.currentItem == nil)
        #expect(model.thumbnails.isEmpty)
    }

    @Test
    func photosVideoMatchesClipOnlyWhenLengthsAgree() {
        #expect(OriginalVideoLoader.isSameLength(photosDuration: 42.4, clipDuration: 42))
        #expect(OriginalVideoLoader.isSameLength(photosDuration: 41.0, clipDuration: 42))
        #expect(!OriginalVideoLoader.isSameLength(photosDuration: 60, clipDuration: 42))
    }

    @Test
    func unknownClipLengthNeverMatches() {
        #expect(!OriginalVideoLoader.isSameLength(photosDuration: 42, clipDuration: nil))
        #expect(!OriginalVideoLoader.isSameLength(photosDuration: 0, clipDuration: 0))
    }

    @Test
    func unknownDurationDoesNotRejectASelectedOrFingerprintVerifiedVideo() {
        #expect(OriginalVideoLoader.hasCompatibleDuration(photosDuration: 42, clipDuration: nil))
        #expect(OriginalVideoLoader.hasCompatibleDuration(photosDuration: 42, clipDuration: 0))
        #expect(OriginalVideoLoader.hasCompatibleDuration(photosDuration: 0, clipDuration: 42))
        #expect(!OriginalVideoLoader.hasCompatibleDuration(photosDuration: 60, clipDuration: 42))
        #expect(OriginalVideoLoader.hasCompatibleDuration(photosDuration: 42.4, clipDuration: 42))
    }

    @Test
    func trimmedCopyKeepsOriginalMetadataWithNewDuration() {
        let trimmed = base.replacingDuration(12)
        #expect(trimmed.duration == 12)
        #expect(trimmed.capturedAt == base.capturedAt)
        #expect(trimmed.gpsLat == base.gpsLat)
        #expect(trimmed.gpsLon == base.gpsLon)
        #expect(trimmed.codec == base.codec)
        #expect(trimmed.resolution == base.resolution)
    }

    @Test
    func fileMetadataWinsOverPhotosFallbacks() {
        let merged = base.fillingMissing(
            capturedAt: "2000-01-01T00:00:00Z", gpsLat: 1, gpsLon: 2, gpsAltitude: 3)
        #expect(merged.capturedAt == base.capturedAt)
        #expect(merged.gpsLat == 40.7)
        #expect(merged.gpsLon == -74.0)
        #expect(merged.gpsAltitude == 10)
    }

    @Test
    func photosFallbacksFillMissingCaptureDateAndLocation() {
        let bare = VideoMetadata(
            duration: 42, resolution: "1920×1080", codec: "H.264", orientation: "portrait",
            deviceModel: "iPhone", osVersion: "iOS 18.6",
            capturedAt: nil, gpsLat: nil, gpsLon: nil, gpsAltitude: nil
        )
        let merged = bare.fillingMissing(
            capturedAt: "2026-05-10T12:00:00Z", gpsLat: 1, gpsLon: 2, gpsAltitude: 3)
        #expect(merged.capturedAt == "2026-05-10T12:00:00Z")
        #expect(merged.gpsLat == 1)
        #expect(merged.gpsLon == 2)
        #expect(merged.gpsAltitude == 3)
    }
}
