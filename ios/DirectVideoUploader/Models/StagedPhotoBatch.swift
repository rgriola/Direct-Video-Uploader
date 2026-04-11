import UIKit
import Photos

// MARK: - Photo Item (single photo in a batch)

/// A single photo selected from the user's library, ready for upload.
struct PhotoItem: Identifiable {
    let id: String                // UUID — maps to server clipId after auth
    let phAssetIdentifier: String // PHAsset local identifier
    let image: UIImage            // Full-res image data reference
    let thumbnail: UIImage        // Compressed thumbnail for chat display
    let fileName: String          // e.g. "IMG_1234.HEIC"
    let format: String            // "JPEG" | "HEIC" | "RAW"
    let fileSize: Int64           // bytes
    let width: Int
    let height: Int
    let capturedAt: String?       // ISO 8601
    let gpsLat: Double?
    let gpsLon: Double?
    let gpsAltitude: Double?
    let deviceModel: String
    let osVersion: String
    
    /// Per-photo upload state
    enum UploadState: Equatable {
        case pending
        case uploading(progress: Double)
        case uploaded(imageKitUrl: String)
        case failed(reason: String)
    }
    
    var uploadState: UploadState = .pending
}

// MARK: - Staged Photo Batch

/// A batch of photos staged for upload — analogous to StagedVideo but for N photos.
/// Created after the user confirms selection in PhotoLibraryView.
struct StagedPhotoBatch {
    let items: [PhotoItem]
    
    /// Number of photos in the batch.
    var count: Int { items.count }
    
    /// Composite thumbnail grid (first 4 photos arranged in a 2x2 grid).
    var gridThumbnail: UIImage? {
        createGridThumbnail(from: items.prefix(4).map(\.thumbnail))
    }
    
    /// Display summary: "3 photos · 12.4 MB"
    var summary: String {
        let totalBytes = items.reduce(0) { $0 + $1.fileSize }
        let mb = Double(totalBytes) / (1024 * 1024)
        let sizeStr = mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%.0f KB", Double(totalBytes) / 1024)
        return "\(count) photo\(count == 1 ? "" : "s") · \(sizeStr)"
    }
    
    /// Whether any photo has GPS data.
    var hasLocation: Bool {
        items.contains { $0.gpsLat != nil }
    }
    
    /// Formats string from the batch (e.g. "HEIC, JPEG").
    var formatSummary: String {
        let unique = Set(items.map(\.format))
        return unique.sorted().joined(separator: ", ")
    }
}

// MARK: - Grid Thumbnail Generator

private func createGridThumbnail(from images: [UIImage]) -> UIImage? {
    guard !images.isEmpty else { return nil }
    
    let gridSize: CGFloat = 200
    let spacing: CGFloat = 2
    
    if images.count == 1 {
        return images[0]
    }
    
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: gridSize, height: gridSize))
    return renderer.image { ctx in
        let cols = images.count <= 2 ? 2 : 2
        let rows = images.count <= 2 ? 1 : 2
        let cellW = (gridSize - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        let cellH = (gridSize - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        
        for (i, img) in images.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = CGFloat(col) * (cellW + spacing)
            let y = CGFloat(row) * (cellH + spacing)
            let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
            img.draw(in: rect)
        }
    }
}
