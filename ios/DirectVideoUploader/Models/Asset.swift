import Foundation

// MARK: - Asset

struct Asset: Codable, Identifiable {
    let id: String
    let mediasourceId: String?
    let mediasourceUrl: String?
    let originalFileName: String?
    let status: AssetStatus
    let assetType: AssetType?
    let clipCount: Int?
    let totalDuration: Int?
    let createdAt: String?
    let user: AssetUser?
    let clips: [Clip]?
    let formResponse: FormResponse?
}

struct AssetUser: Codable {
    let id: String
    let name: String
    let phoneNumber: String?
}

enum AssetStatus: String, Codable {
    case uploading = "UPLOADING"
    case processing = "PROCESSING"
    case ready = "READY"
    case error = "ERROR"
    
    var displayName: String {
        switch self {
        case .uploading: return "Uploading"
        case .processing: return "Processing"
        case .ready: return "Ready"
        case .error: return "Error"
        }
    }
    
    var icon: String {
        switch self {
        case .uploading: return "📤"
        case .processing: return "⏳"
        case .ready: return "✅"
        case .error: return "❌"
        }
    }
}

// MARK: - Asset Type

enum AssetType: String, Codable {
    case video = "VIDEO"
    case photo = "PHOTO"
}

// MARK: - Clip

struct Clip: Codable, Identifiable {
    let id: String
    let clipIndex: Int?
    let originalFileName: String?
    let gpsLat: Double?
    let gpsLon: Double?
    let gpsAltitude: Double?
    let capturedAt: String?
    let deviceModel: String?
    let osVersion: String?
    let codec: String?
    let resolution: String?
    let orientation: String?
    let duration: Int?
    let fileSize: String?
    let transcript: String?
    let transcriptSegments: [TranscriptSegment]?
    let status: String?
    let storageUrl: String?
    let streamUrl: String?
    let thumbnailUrl: String?
}

// MARK: - Create Asset

struct CreateAssetRequest: Codable {
    let fileName: String
    let type: String?
}

struct CreateAssetResponse: Codable {
    let asset: Asset
}

struct AssetDetailResponse: Codable {
    let asset: Asset
}

// MARK: - Form Response

struct FormResponse: Codable {
    let id: String
    let assetId: String?
    let slug: String?
    let type: String?
    let description: String?
    let priority: String?
    let submittedAt: String?
}

// MARK: - My Assets Response

struct MyAssetsResponse: Codable {
    let assets: [Asset]
}
