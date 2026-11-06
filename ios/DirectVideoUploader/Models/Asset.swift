import Foundation

// MARK: - Asset

struct Asset: Codable, Identifiable, Sendable {
    let id: String
    let mediasourceId: String?
    let mediasourceUrl: String?
    let originalFileName: String?
    let status: AssetStatus
    let clipCount: Int?
    let totalDuration: Int?
    let createdAt: String?
    let user: AssetUser?
    let clips: [Clip]?
    let formResponse: FormResponse?
}

struct AssetUser: Codable, Sendable {
    let id: String
    let name: String
    let phoneNumber: String?
}

enum AssetStatus: String, Codable, Sendable {
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

// MARK: - Clip

struct Clip: Codable, Identifiable, Sendable {
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

struct CreateAssetRequest: Codable, Sendable {
    let fileName: String
}

struct CreateAssetResponse: Codable, Sendable {
    let asset: Asset
}

struct AssetDetailResponse: Codable, Sendable {
    let asset: Asset
}

// MARK: - Form Response

struct FormResponse: Codable, Sendable {
    let id: String
    let assetId: String?
    let slug: String?
    let type: String?
    let description: String?
    let priority: String?
    let submittedAt: String?
}

// MARK: - My Assets Response

struct MyAssetsResponse: Codable, Sendable {
    let assets: [Asset]
}
