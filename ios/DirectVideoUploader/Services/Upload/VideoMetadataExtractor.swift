import AVFoundation
import UIKit

/// Extracts real metadata from a local video file using AVAsset.
struct VideoMetadata: Codable {
    let duration: Int          // seconds
    let resolution: String     // e.g. "3840×2160"
    let codec: String          // e.g. "HEVC / H.265"
    let orientation: String    // "landscape" or "portrait"
    let deviceModel: String    // e.g. "iPhone"
    let osVersion: String      // e.g. "iOS 19.3"
    let capturedAt: String?    // ISO 8601
    let gpsLat: Double?
    let gpsLon: Double?
    let gpsAltitude: Double?
}

enum VideoMetadataExtractor {
    
    /// Extract metadata from a local video file URL.
    static func extract(from url: URL) async -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        
        // Duration
        let duration: Int
        if let cmDuration = try? await asset.load(.duration) {
            duration = Int(CMTimeGetSeconds(cmDuration))
        } else {
            duration = 0
        }
        
        // Video track properties
        var resolution = "Unknown"
        var codec = "Unknown"
        var orientation = "landscape"
        
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let videoTrack = tracks.first {
            // Resolution & orientation
            if let naturalSize = try? await videoTrack.load(.naturalSize),
               let transform = try? await videoTrack.load(.preferredTransform) {
                let transformed = naturalSize.applying(transform)
                let width = abs(Int(transformed.width))
                let height = abs(Int(transformed.height))
                resolution = "\(max(width, height))×\(min(width, height))"
                orientation = width >= height ? "landscape" : "portrait"
            }
            
            // Codec
            if let descriptions = try? await videoTrack.load(.formatDescriptions) {
                for desc in descriptions {
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                    codec = codecName(from: mediaSubType)
                    break
                }
            }
        }
        
        // Creation date from metadata
        var capturedAt: String?
        if let creationDate = try? await asset.load(.creationDate),
           let dateValue = try? await creationDate.load(.dateValue) {
            capturedAt = DVUDateFormatting.isoString(from: dateValue)
        }
        
        // GPS from common metadata
        var gpsLat: Double?
        var gpsLon: Double?
        var gpsAltitude: Double?
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                if let key = item.commonKey {
                    if key == .commonKeyLocation, let loc = try? await item.load(.stringValue) {
                        // Location format: "+40.7128-074.0060/" or "+40.9088-073.8290+042.291/"
                        let parts = parseISO6709(loc)
                        gpsLat = parts.lat
                        gpsLon = parts.lon
                        gpsAltitude = parts.alt
                    }
                }
            }
        }
        
        // Device info (MainActor-isolated properties)
        let deviceModel = await UIDevice.current.model  // "iPhone"
        let osVersion = await "iOS \(UIDevice.current.systemVersion)"
        
        return VideoMetadata(
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
    
    // MARK: - Helpers
    
    static func codecName(from subType: FourCharCode) -> String {
        switch subType {
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha:
            return "HEVC / H.265"
        case kCMVideoCodecType_H264:
            return "AVC / H.264"
        case kCMVideoCodecType_AV1:
            return "AV1"
        case kCMVideoCodecType_VP9:
            return "VP9"
        case kCMVideoCodecType_MPEG4Video:
            return "MPEG-4"
        default:
            let chars = [
                Character(UnicodeScalar((subType >> 24) & 0xFF)!),
                Character(UnicodeScalar((subType >> 16) & 0xFF)!),
                Character(UnicodeScalar((subType >> 8) & 0xFF)!),
                Character(UnicodeScalar(subType & 0xFF)!),
            ]
            return String(chars)
        }
    }
    
    /// Parse ISO 6709 location string like "+40.7128-074.0060/" or "+40.9088-073.8290+042.291/"
    private static func parseISO6709(_ raw: String) -> (lat: Double?, lon: Double?, alt: Double?) {
        // Remove trailing /
        let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Find all +/- signs after position 0 (latitude starts at index 0)
        var signPositions: [String.Index] = []
        for (i, char) in clean.enumerated() {
            if (char == "+" || char == "-") && i > 0 {
                signPositions.append(clean.index(clean.startIndex, offsetBy: i))
            }
        }
        
        guard let lonStart = signPositions.first else {
            return (nil, nil, nil)
        }
        
        let latStr = String(clean[clean.startIndex..<lonStart])
        
        // If there's a third sign (altitude), stop longitude before it
        let lonEnd = signPositions.count >= 2 ? signPositions[1] : clean.endIndex
        let lonStr = String(clean[lonStart..<lonEnd])
        
        // Altitude is everything after the second sign
        var altitude: Double? = nil
        if signPositions.count >= 2 {
            let altStr = String(clean[signPositions[1]...])
            altitude = Double(altStr)
        }
        
        return (Double(latStr), Double(lonStr), altitude)
    }
}
