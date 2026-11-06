import Foundation
import Testing
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
    func movedTrimHandlesCountAsTrimmed() {
        #expect(!TrimRange.isFullLength(start: 0.5, end: 30, duration: 30))
        #expect(!TrimRange.isFullLength(start: 0, end: 29.5, duration: 30))
        #expect(!TrimRange.isFullLength(start: 5, end: 10, duration: 30))
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
