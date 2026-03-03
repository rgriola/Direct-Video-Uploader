import Foundation

// MARK: - Asset

struct Asset: Codable, Identifiable {
    let id: String
    let slug: String
    let mediasourceId: String?
    let mediasourceUrl: String?
    let status: AssetStatus
    let clipCount: Int?
    let totalDuration: Int?
    let createdAt: String?
    let user: AssetUser?
    let clips: [Clip]?
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

// MARK: - Clip

struct Clip: Codable, Identifiable {
    let id: String
    let clipIndex: Int?
    let gpsLat: Double?
    let gpsLon: Double?
    let capturedAt: String?
    let deviceModel: String?
    let osVersion: String?
    let codec: String?
    let resolution: String?
    let orientation: String?
    let duration: Int?
    let fileSize: Int64?
    let status: String?
    let storageUrl: String?
    let streamUrl: String?
    let thumbnailUrl: String?
}

// MARK: - Create Asset

struct CreateAssetRequest: Codable {
    let fileName: String
}

struct CreateAssetResponse: Codable {
    let asset: Asset
}

struct AssetDetailResponse: Codable {
    let asset: Asset
}
