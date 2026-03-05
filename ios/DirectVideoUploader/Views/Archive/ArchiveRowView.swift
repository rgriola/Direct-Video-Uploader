import SwiftUI

/// A single expandable row in the archive list showing upload metadata and actions.
struct ArchiveRowView: View {
    let asset: Asset
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Collapsed Row (always visible)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    // Thumbnail placeholder
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: "2C2C2E"))
                            .frame(width: 50, height: 50)
                        Text("🎬")
                            .font(.system(size: 22))
                    }
                    
                    // File info
                    VStack(alignment: .leading, spacing: 3) {
                        Text(asset.originalFileName ?? asset.slug)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        
                        HStack(spacing: 6) {
                            Text(asset.slug)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color(hex: "98989D"))
                                .lineLimit(1)
                            
                            if let type = asset.formResponse?.type {
                                Text("·")
                                    .foregroundStyle(Color(hex: "636366"))
                                Text(type)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: "98989D"))
                            }
                            
                            Text(asset.status.icon)
                                .font(.system(size: 11))
                        }
                    }
                    
                    Spacer()
                    
                    // Date + chevron
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(formatShortDate(asset.createdAt))
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: "98989D"))
                        
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: "636366"))
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            
            // MARK: - Expanded Detail
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                        .background(Color(hex: "38383A"))
                    
                    // Metadata grid
                    VStack(alignment: .leading, spacing: 6) {
                        if let mid = asset.mediasourceId {
                            metadataRow(label: "Mediasource", value: mid)
                        }
                        if let desc = asset.formResponse?.description, !desc.isEmpty {
                            metadataRow(label: "Description", value: desc)
                        }
                        if let priority = asset.formResponse?.priority {
                            metadataRow(label: "Priority", value: priority)
                        }
                        
                        // Clip metadata (first clip)
                        if let clip = asset.clips?.first {
                            if let res = clip.resolution {
                                metadataRow(label: "Resolution", value: res)
                            }
                            if let codec = clip.codec {
                                metadataRow(label: "Codec", value: codec)
                            }
                            if let dur = clip.duration {
                                metadataRow(label: "Duration", value: formatDuration(dur))
                            }
                            if let size = clip.fileSize {
                                metadataRow(label: "File Size", value: formatFileSize(size))
                            }
                            if let device = clip.deviceModel {
                                metadataRow(label: "Device", value: device)
                            }
                            if clip.gpsLat != nil, clip.gpsLon != nil {
                                metadataRow(label: "GPS", value: String(format: "%.4f, %.4f", clip.gpsLat!, clip.gpsLon!))
                            }
                            if let captured = clip.capturedAt {
                                metadataRow(label: "Captured", value: formatShortDate(captured))
                            }
                        }
                    }
                    
                    // Action buttons
                    HStack(spacing: 12) {
                        // View button — open in browser
                        Button {
                            if let url = URL(string: "\(ServerConfig.baseURL)/clips/\(asset.slug)") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 13))
                                Text("View")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(hex: "30D158"))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                        
                        // Status pill
                        Text("\(asset.status.icon) \(asset.status.displayName)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(hex: "98989D"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(hex: "2C2C2E"))
                            .clipShape(Capsule())
                        
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(hex: "1C1C1E"))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: "636366"))
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "EBEBF5"))
                .lineLimit(3)
        }
    }
    
    private func formatShortDate(_ dateStr: String?) -> String {
        guard let dateStr else { return "" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd/yy"
        return fmt.string(from: date)
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
    
    private func formatFileSize(_ sizeStr: String) -> String {
        guard let bytes = Double(sizeStr) else { return sizeStr }
        if bytes > 1_000_000_000 {
            return String(format: "%.1f GB", bytes / 1_000_000_000)
        } else if bytes > 1_000_000 {
            return String(format: "%.1f MB", bytes / 1_000_000)
        } else if bytes > 1_000 {
            return String(format: "%.0f KB", bytes / 1_000)
        }
        return "\(Int(bytes)) B"
    }
}
