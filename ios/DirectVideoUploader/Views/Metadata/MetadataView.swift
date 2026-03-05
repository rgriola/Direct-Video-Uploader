import SwiftUI
import UIKit

/// Metadata detail view — read-only sheet showing ALL available metadata for a clip.
/// "Show Details" button opens this. 99% of users won't look, but it validates the file.
struct MetadataView: View {
    let clip: Clip
    let asset: Asset?
    var thumbnail: UIImage? = nil
    
    @Environment(\.dismiss) private var dismiss
    
    /// Whether the clip has any meaningful metadata beyond just timestamps
    private var hasRichMeta: Bool {
        clip.gpsLat != nil || clip.codec != nil || clip.deviceModel != nil ||
        clip.resolution != nil || clip.duration != nil
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "0A0E1A").ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 0) {
                        // Hero — file identity
                        VStack(spacing: 8) {
                            // Thumbnail
                            if let thumb = thumbnail {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(height: 120)
                                    .frame(maxWidth: .infinity)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 4)
                            }
                            
                            Text("📄 File Metadata")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                            
                            if let name = clip.originalFileName ?? asset?.originalFileName {
                                Text(name)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            
                            if let id = asset?.mediasourceId {
                                HStack(spacing: 4) {
                                    Text("🔗")
                                        .font(.system(size: 13))
                                    Text(id)
                                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color(hex: "007AFF"))
                                }
                            }
                        }
                        .padding(.vertical, 24)
                        
                        if hasRichMeta {
                            // Full metadata rows
                            VStack(spacing: 1) {
                                // Location
                                if let lat = clip.gpsLat, let lon = clip.gpsLon {
                                    metadataRow(icon: "📍", label: "GPS", value: String(format: "%.4f, %.4f", lat, lon))
                                }
                                
                                // Capture date
                                if let captured = clip.capturedAt {
                                    metadataRow(icon: "🕐", label: "Captured", value: formatDate(captured))
                                }
                                
                                // Device
                                if let device = clip.deviceModel {
                                    metadataRow(icon: "📱", label: "Device", value: device)
                                }
                                
                                // OS
                                if let os = clip.osVersion {
                                    metadataRow(icon: "⚙️", label: "OS", value: os)
                                }
                                
                                // Codec
                                if let codec = clip.codec {
                                    metadataRow(icon: "🎬", label: "Codec", value: codec)
                                }
                                
                                // Resolution
                                if let res = clip.resolution {
                                    metadataRow(icon: "📐", label: "Resolution", value: res)
                                }
                                
                                // Orientation
                                if let orientation = clip.orientation {
                                    metadataRow(icon: "↔️", label: "Orientation", value: orientation.capitalized)
                                }
                                
                                // Duration
                                if let duration = clip.duration {
                                    let min = duration / 60
                                    let sec = duration % 60
                                    metadataRow(icon: "⏱", label: "Duration", value: String(format: "%d:%02d", min, sec))
                                }
                                
                                // File size
                                if let size = clip.fileSize, let bytes = Int64(size) {
                                    let mb = Double(bytes) / 1_000_000
                                    metadataRow(icon: "📁", label: "File Size", value: String(format: "%.1f MB", mb))
                                }
                                
                                // Status
                                if let status = clip.status {
                                    metadataRow(icon: "✅", label: "Status", value: status)
                                }
                                
                                // Storage URL
                                if let url = clip.storageUrl {
                                    metadataRow(icon: "💾", label: "Storage", value: url)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 16)
                        } else {
                            // No metadata fallback
                            VStack(spacing: 12) {
                                Text("🚫")
                                    .font(.system(size: 44))
                                Text("No Metadata Found")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("Add details in Mediasource.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.5))
                                
                                // Still show what we have: file size & timestamps
                                VStack(spacing: 1) {
                                    if let size = clip.fileSize, let bytes = Int64(size) {
                                        let mb = Double(bytes) / 1_000_000
                                        metadataRow(icon: "📁", label: "File Size", value: String(format: "%.1f MB", mb))
                                    }
                                    if let status = clip.status {
                                        metadataRow(icon: "✅", label: "Status", value: status)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 24)
                        }
                        
                        // View clip link
                        if let slug = asset?.slug,
                           let url = URL(string: "\(ServerConfig.baseURL)/clips/\(slug)") {
                            Link(destination: url) {
                                HStack {
                                    Image(systemName: "play.circle.fill")
                                    Text("View Clip")
                                        .font(.system(size: 15, weight: .medium))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(hex: "34C759").opacity(0.15))
                                .foregroundStyle(Color(hex: "34C759"))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color(hex: "007AFF"))
                }
            }
        }
    }
    
    // MARK: - Row
    
    private func metadataRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Text(icon)
                .font(.system(size: 16))
                .frame(width: 28)
            
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color.white.opacity(0.05))
    }
    
    // MARK: - Date Formatting
    
    private func formatDate(_ isoString: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let date = iso.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString) else {
            return isoString
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }
}
