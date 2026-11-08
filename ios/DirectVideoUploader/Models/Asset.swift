import Foundation

// MARK: - Asset

nonisolated struct Asset: Codable, Identifiable, Sendable, Equatable {
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
    let userId: String?
    let updatedAt: String?
    var moderation: AssetModeration? = nil

    var isModerated: Bool {
        guard let moderation else { return false }
        return moderation != .active
    }

    var permitsMediaActions: Bool { !isModerated }

    func needsUploadRecovery(at date: Date) -> Bool {
        guard permitsMediaActions else { return false }
        if status == .error { return true }
        guard status == .uploading || status == .processing else { return false }
        let timestamp = (status == .processing ? clips?.first?.createdAt : nil) ?? createdAt
        guard let timestamp, let created = DVUDateFormatting.parseISO(timestamp) else { return true }
        return date.timeIntervalSince(created) > 300
    }
}

nonisolated enum AssetModeration: String, Codable, Sendable, Equatable {
    case active = "ACTIVE"
    case paused = "PAUSED"
    case flaggedForRemoval = "FLAGGED_FOR_REMOVAL"
    case removed = "REMOVED"
    case unknown = "UNKNOWN"

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

nonisolated struct AssetUser: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let phoneNumber: String?
}

nonisolated enum AssetStatus: String, Codable, Sendable, Equatable {
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

nonisolated struct Clip: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let assetId: String?
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
    let createdAt: String?
    let status: String?
    let storageUrl: String?
    let streamUrl: String?
    let thumbnailUrl: String?
    let muxAssetId: String?
    let muxPlaybackId: String?
    let muxUploadId: String?
}

// MARK: - Create Asset

nonisolated struct CreateAssetRequest: Codable, Sendable {
    let fileName: String
}

nonisolated struct CreateAssetResponse: Codable, Sendable {
    let asset: Asset
}

nonisolated struct AssetDetailResponse: Codable, Sendable {
    let asset: Asset
}

// MARK: - Form Response

nonisolated struct FormResponse: Codable, Sendable, Equatable {
    let id: String
    let assetId: String?
    let slug: String?
    let type: String?
    let description: String?
    let priority: String?
    let submittedAt: String?
}

// MARK: - My Assets Response

nonisolated struct MyAssetsResponse: Codable, Sendable {
    let assets: [Asset]
}
