import SwiftUI

/// Metadata detail view — shows clip details (GPS, device, codec, etc.)
struct MetadataView: View {
    let clip: Clip
    let asset: Asset?
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "0A0E1A").ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 0) {
                        // Hero
                        VStack(spacing: 8) {
                            Text(asset?.slug ?? "Clip Details")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                            
                            if let id = asset?.mediasourceId {
                                Text("#\(id)")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color(hex: "007AFF"))
                            }
                        }
                        .padding(.vertical, 24)
                        
                        // Metadata rows
                        VStack(spacing: 1) {
                            if let lat = clip.gpsLat, let lon = clip.gpsLon {
                                metadataRow(icon: "📍", label: "GPS", value: String(format: "%.4f, %.4f", lat, lon))
                            }
                            
                            if let captured = clip.capturedAt {
                                metadataRow(icon: "🕐", label: "Captured", value: formatDate(captured))
                            }
                            
                            if let device = clip.deviceModel {
                                let os = clip.osVersion.map { " · \($0)" } ?? ""
                                metadataRow(icon: "📱", label: "Device", value: "\(device)\(os)")
                            }
                            
                            if let codec = clip.codec {
                                let res = clip.resolution ?? ""
                                metadataRow(icon: "🎥", label: "Video", value: "\(codec) · \(res)")
                            }
                            
                            if let orientation = clip.orientation {
                                metadataRow(icon: "↔️", label: "Orientation", value: orientation.capitalized)
                            }
                            
                            if let duration = clip.duration {
                                let min = duration / 60
                                let sec = duration % 60
                                metadataRow(icon: "⏱", label: "Duration", value: String(format: "%d:%02d", min, sec))
                            }
                            
                            if let size = clip.fileSize {
                                let mb = Double(size) / 1_000_000
                                metadataRow(icon: "📁", label: "File Size", value: String(format: "%.1f MB", mb))
                            }
                            
                            if let status = clip.status {
                                metadataRow(icon: "✅", label: "Status", value: status)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 16)
                        
                        // Mediasource link
                        if let urlString = asset?.mediasourceUrl,
                           let url = URL(string: urlString) {
                            Link(destination: url) {
                                HStack {
                                    Image(systemName: "link")
                                    Text("Open in Mediasource")
                                        .font(.system(size: 15, weight: .medium))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(hex: "007AFF").opacity(0.15))
                                .foregroundStyle(Color(hex: "007AFF"))
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
