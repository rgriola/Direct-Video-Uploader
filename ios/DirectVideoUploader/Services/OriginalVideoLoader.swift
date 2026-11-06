import CoreLocation
import Foundation
import Photos
import Synchronization

/// An untouched original copied out of the Photos library, ready to upload.
struct LoadedOriginalVideo: Sendable {
    let fileURL: URL
    let fileName: String
    let metadata: VideoMetadata
}

/// Reads camera originals from Photos (never the Photos-edited version, never transcoded)
/// and saves trimmed copies back to the library.
///
/// Photos delivers callbacks on background queues, so everything here is nonisolated and
/// only Sendable values (identifiers, URLs, dates) cross into and out of these functions.
enum OriginalVideoLoader {

    enum LoaderError: LocalizedError {
        case assetNotFound
        case originalResourceMissing
        case addAccessDenied
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .assetNotFound: "The video could not be found in Photos."
            case .originalResourceMissing: "The original video file could not be found in Photos."
            case .addAccessDenied: "Photo Library access is off."
            case .saveFailed: "The video could not be saved to Photos."
            }
        }
    }

    /// Server clip durations are whole seconds, so allow up to one second of difference.
    static let durationTolerance: Double = 1.0

    // MARK: - Authorization

    /// Shows the system prompt only if the person hasn't decided yet; otherwise returns the current status.
    static func requestReadWriteAccessIfNeeded() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .notDetermined else { return status }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func canRead(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    /// Adding to the library is allowed with read/write access (full or limited) or add-only access.
    static func requestAddAccessIfNeeded() async -> Bool {
        if canRead(PHPhotoLibrary.authorizationStatus(for: .readWrite)) { return true }
        var addStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if addStatus == .notDetermined {
            addStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        return addStatus == .authorized || addStatus == .limited
    }

    // MARK: - Lookup

    /// Duration in seconds of a Photos asset the app can read, or nil if it isn't accessible.
    static func duration(ofAssetWithIdentifier localIdentifier: String) -> Double? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject?.duration
    }

    /// True when a Photos video is the same length as the uploaded clip, meaning it is not
    /// the untrimmed source of a trimmed upload. Unknown clip durations never match.
    static func isSameLength(photosDuration: Double, clipDuration: Int?) -> Bool {
        guard let clipDuration, clipDuration > 0 else { return false }
        return abs(photosDuration - Double(clipDuration)) <= durationTolerance
    }

    // MARK: - Original Export

    /// Copies the camera's original bytes (the `.video` resource, ignoring Photos edits) into a
    /// unique temporary folder, downloading from iCloud when needed. Metadata comes from the
    /// original file, with Photos' capture date and location filling any gaps.
    static func loadOriginal(
        localIdentifier: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> LoadedOriginalVideo {
        guard
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
                .firstObject
        else { throw LoaderError.assetNotFound }

        guard
            let resource = PHAssetResource.assetResources(for: asset).first(where: {
                $0.type == .video
            })
        else { throw LoaderError.originalResourceMissing }

        let photosCreationDate = asset.creationDate
        let photosLocation = asset.location.map {
            (lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, alt: $0.altitude)
        }

        let fileName = resource.originalFilename
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(fileName)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        if let progress {
            options.progressHandler = { value in progress(value) }
        }

        do {
            try await writeResource(resource, to: destination, options: options)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }

        let fileMetadata = await VideoMetadataExtractor.extract(from: destination)
        let metadata = fileMetadata.fillingMissing(
            capturedAt: photosCreationDate.map { DVUDateFormatting.isoString(from: $0) },
            gpsLat: photosLocation?.lat,
            gpsLon: photosLocation?.lon,
            gpsAltitude: photosLocation?.alt
        )
        return LoadedOriginalVideo(fileURL: destination, fileName: fileName, metadata: metadata)
    }

    /// Streams a resource to disk. Unlike `writeData`, cancelling the task stops the
    /// request, so abandoned iCloud downloads don't keep running.
    private static func writeResource(
        _ resource: PHAssetResource, to destination: URL, options: PHAssetResourceRequestOptions
    ) async throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        let request = ResourceRequest()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let requestID = PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { data in
                        do {
                            try handle.write(contentsOf: data)
                        } catch {
                            request.recordWriteError(error)
                            request.cancel()
                        }
                    },
                    completionHandler: { error in
                        try? handle.close()
                        if let writeError = request.writeError {
                            continuation.resume(throwing: writeError)
                        } else if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                )
                request.start(requestID)
                if Task.isCancelled { request.cancel() }
            }
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
    }

    // MARK: - Save to Photos

    /// Adds a video to Photos as a new item and returns its local identifier.
    /// The file is copied, so the caller still owns `fileURL`.
    static func saveVideoToPhotos(
        fileURL: URL,
        fileName: String,
        creationDate: Date?,
        latitude: Double?,
        longitude: Double?,
        altitude: Double?
    ) async throws -> String {
        guard await requestAddAccessIfNeeded() else { throw LoaderError.addAccessDenied }

        let createdIdentifier = CreatedAssetIdentifier()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = fileName
            request.addResource(with: .video, fileURL: fileURL, options: options)
            if let creationDate {
                request.creationDate = creationDate
            }
            if let latitude, let longitude {
                request.location = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    altitude: altitude ?? 0,
                    horizontalAccuracy: 0,
                    verticalAccuracy: altitude == nil ? -1 : 0,
                    timestamp: creationDate ?? Date()
                )
            }
            createdIdentifier.set(request.placeholderForCreatedAsset?.localIdentifier)
        }

        guard let identifier = createdIdentifier.value else { throw LoaderError.saveFailed }
        return identifier
    }
}

/// Carries the placeholder identifier out of the Photos change block, which runs on a background queue.
private final class CreatedAssetIdentifier: Sendable {
    private let storage = Mutex<String?>(nil)

    func set(_ identifier: String?) {
        storage.withLock { $0 = identifier }
    }

    var value: String? {
        storage.withLock { $0 }
    }
}

/// Thread-safe handle to an in-flight Photos data request so it can be cancelled from any queue.
private final class ResourceRequest: Sendable {
    private struct State {
        var id: PHAssetResourceDataRequestID?
        var cancelled = false
        var writeError: (any Error)?
    }

    private let state = Mutex(State())

    func start(_ id: PHAssetResourceDataRequestID) {
        let cancelNow = state.withLock { state in
            state.id = id
            return state.cancelled
        }
        if cancelNow { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func cancel() {
        let id = state.withLock { state -> PHAssetResourceDataRequestID? in
            state.cancelled = true
            return state.id
        }
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func recordWriteError(_ error: any Error) {
        state.withLock { if $0.writeError == nil { $0.writeError = error } }
    }

    var writeError: (any Error)? {
        state.withLock { $0.writeError }
    }
}

// MARK: - Metadata Helpers

extension VideoMetadata {
    /// Fills capture date and GPS only where the file itself had none.
    func fillingMissing(
        capturedAt: String?, gpsLat: Double?, gpsLon: Double?, gpsAltitude: Double?
    ) -> VideoMetadata {
        let useFallbackLocation = self.gpsLat == nil || self.gpsLon == nil
        return VideoMetadata(
            duration: duration,
            resolution: resolution,
            codec: codec,
            orientation: orientation,
            deviceModel: deviceModel,
            osVersion: osVersion,
            capturedAt: self.capturedAt ?? capturedAt,
            gpsLat: useFallbackLocation ? gpsLat : self.gpsLat,
            gpsLon: useFallbackLocation ? gpsLon : self.gpsLon,
            gpsAltitude: useFallbackLocation ? gpsAltitude : self.gpsAltitude
        )
    }

    /// Keeps the original's metadata but reports the trimmed copy's length.
    func replacingDuration(_ duration: Int) -> VideoMetadata {
        VideoMetadata(
            duration: duration,
            resolution: resolution,
            codec: codec,
            orientation: orientation,
            deviceModel: deviceModel,
            osVersion: osVersion,
            capturedAt: capturedAt,
            gpsLat: gpsLat,
            gpsLon: gpsLon,
            gpsAltitude: gpsAltitude
        )
    }
}
