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
                Theme.deepBg.ignoresSafeArea()
                
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
                                .font(Theme.titleFont)
                                .foregroundStyle(.white)
                            
                            if let name = clip.originalFileName ?? asset?.originalFileName {
                                Text(name)
                                    .font(Theme.metaFileFont)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            
                            if let id = asset?.mediasourceId {
                                HStack(spacing: 4) {
                                    Text("🔗")
                                        .font(Theme.iconMediumFont)
                                    Text(id)
                                        .font(Theme.metaIdFont)
                                        .foregroundStyle(Theme.blue)
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
                                    metadataRow(icon: "🕐", label: "Captured", value: DVUDateFormatting.longDate(captured))
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
                                    metadataRow(icon: "⏱", label: "Duration", value: DVUDateFormatting.duration(duration))
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
                            
                            // Transcript section
                            if let transcript = clip.transcript, !transcript.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "text.quote")
                                            .font(Theme.iconMediumFont)
                                            .foregroundStyle(Theme.tint)
                                        Text("Transcript")
                                            .font(Theme.captionBoldFont)
                                            .foregroundStyle(.white)
                                    }
                                    
                                    Text(transcript)
                                        .font(Theme.captionFont)
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(20)
                                        .textSelection(.enabled)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                            }
                        } else {
                            // No metadata fallback
                            VStack(spacing: 12) {
                                Text("🚫")
                                    .font(Theme.metaEmptyEmojiFont)
                                Text("No Metadata Found")
                                    .font(Theme.metaEmptyTitleFont)
                                    .foregroundStyle(.white)
                                Text("Add details in Mediasource.")
                                    .font(Theme.metaLabelFont)
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
                        if let msId = asset?.mediasourceId,
                           let url = ServerConfig.clipURL(msId) {
                            Link(destination: url) {
                                HStack {
                                    Image(systemName: "play.circle.fill")
                                    Text("View Clip")
                                        .font(Theme.metaLinkFont)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.viewGreen.opacity(0.15))
                                .foregroundStyle(Theme.viewGreen)
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
                        .foregroundStyle(Theme.blue)
                }
            }
        }
    }
    
    // MARK: - Row
    
    private func metadataRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Text(icon)
                .font(Theme.metaIconFont)
                .frame(width: 28)
            
            Text(label)
                .font(Theme.metaLabelFont)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(Theme.metaValueFont)
                .foregroundStyle(.white)
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color.white.opacity(0.05))
    }
    
    // MARK: - Date Formatting
    
    private func formatDate(_ isoString: String) -> String {
        DVUDateFormatting.longDate(isoString)
    }
}
