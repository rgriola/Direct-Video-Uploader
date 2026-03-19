import SwiftUI

/// A single expandable row in the archive list showing upload metadata and actions.
struct ArchiveRowView: View {
    let asset: Asset
    @Environment(WebSocketService.self) private var ws
    @State private var isExpanded = false
    @State private var showSlackShare = false
    
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
                            .fill(Theme.cardBg)
                            .frame(width: 50, height: 50)
                        Text("🎬")
                            .font(Theme.archiveEmojiFont)
                    }
                    
                    // File info
                    VStack(alignment: .leading, spacing: 3) {
                        Text(asset.originalFileName ?? asset.mediasourceId ?? asset.id)
                            .font(Theme.archiveTitleFont)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        
                        HStack(spacing: 6) {
                            Text(asset.mediasourceId ?? asset.id)
                                .font(Theme.monoValueFont)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                            
                            if let type = asset.formResponse?.type {
                                Text("·")
                                    .foregroundStyle(Theme.tertiaryText)
                                Text(type)
                                    .font(Theme.archiveMetaValueFont)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            
                            Text(asset.status.icon)
                                .font(Theme.timestampFont)
                        }
                    }
                    
                    Spacer()
                    
                    // Date + chevron
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(formatShortDate(asset.createdAt))
                            .font(Theme.archiveMetaValueFont)
                            .foregroundStyle(Theme.secondaryText)
                        
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(Theme.headerChevronFont)
                            .foregroundStyle(Theme.tertiaryText)
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
                        .background(Theme.separator)
                    
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
                                metadataRow(label: "Duration", value: DVUDateFormatting.duration(dur))
                            }
                            if let size = clip.fileSize {
                                metadataRow(label: "File Size", value: DVUDateFormatting.fileSize(size))
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
                        if let msId = asset.mediasourceId,
                           let url = ServerConfig.clipURL(msId) {
                            ChatActionButton(
                                icon: "play.circle.fill",
                                label: "View",
                                color: Theme.green,
                                action: { UIApplication.shared.open(url) }
                            )
                        }
                        
                        // Share to Slack button
                        if asset.status == .ready {
                            ChatActionButton(
                                icon: "paperplane.fill",
                                label: "Slack",
                                color: Theme.purple,
                                action: { showSlackShare = true }
                            )
                        }
                        
                        // Status pill
                        Text("\(asset.status.icon) \(asset.status.displayName)")
                            .font(Theme.archiveStatusFont)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.cardBg)
                            .clipShape(Capsule())
                        
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.darkBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showSlackShare) {
            SlackShareSheet(
                mediasourceId: asset.mediasourceId,
                originalFileName: asset.originalFileName,
                onSend: { text in
                    showSlackShare = false
                    ws.sendMessage(text: text)
                },
                onDismiss: { showSlackShare = false }
            )
        }
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(Theme.archiveMetaLabelFont)
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(Theme.archiveMetaValueFont)
                .foregroundStyle(Theme.metaText)
                .lineLimit(3)
        }
    }
    
    private func formatShortDate(_ dateStr: String?) -> String {
        guard let dateStr else { return "" }
        return DVUDateFormatting.shortDate(dateStr)
    }
}
