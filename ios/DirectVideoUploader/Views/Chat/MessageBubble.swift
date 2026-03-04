import SwiftUI

/// Individual chat bubble — handles outgoing (blue, right) and incoming (gray, left).
struct MessageBubble: View {
    let message: ChatMessage
    var onTapMetadata: (() -> Void)?
    var onTapForm: (() -> Void)?
    
    private var isOutgoing: Bool { message.isOutgoing }
    
    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 60) }
            
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                // Bubble content
                bubbleContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .clipShape(ChatBubbleShape(isOutgoing: isOutgoing))
                
                // Timestamp
                if let time = formattedTime {
                    Text(time)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 4)
                }
            }
            
            if !isOutgoing { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }
    
    // MARK: - Bubble Content
    
    @ViewBuilder
    private var bubbleContent: some View {
        switch message.messageType {
        case .video:
            videoContent
        case .confirmation:
            confirmationContent
        case .formRequest:
            formRequestContent
        case .slackPost:
            slackContent
        default:
            textContent
        }
    }
    
    private var textContent: some View {
        Text(message.content.displayText)
            .font(.system(size: 16))
            .foregroundStyle(isOutgoing ? .white : Color(hex: "E5E5EA"))
    }
    
    private var videoContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(.system(size: 14))
            Text(message.content.displayText)
                .font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(isOutgoing ? .white : Color(hex: "E5E5EA"))
    }
    
    private var confirmationContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.content.text ?? "Upload confirmed")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "E5E5EA"))
            
            if let url = message.content.mediasourceUrl {
                Link(destination: URL(string: url) ?? URL(string: "https://mediasource.com")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 11))
                        Text("Open in Mediasource")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color(hex: "007AFF"))
                }
            }
        }
    }
    
    private var formRequestContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — User name
            if let userName = message.content.userName {
                Text(userName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            
            // Original filename
            if let fileName = message.content.originalFileName {
                Text(fileName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(hex: "98989D"))
                    .lineLimit(1)
            }
            
            // Mediasource ID
            if let msId = message.content.mediasourceId {
                HStack(spacing: 4) {
                    Text("🔗")
                        .font(.system(size: 12))
                    Text(msId)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: "007AFF"))
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            // Metadata summary rows
            VStack(alignment: .leading, spacing: 4) {
                // GPS
                if let lat = message.content.gpsLat, let lon = message.content.gpsLon {
                    metaSummaryRow(icon: "📍", text: String(format: "%.4f, %.4f", lat, lon))
                }
                
                // Captured date
                if let dateStr = message.content.capturedAt {
                    metaSummaryRow(icon: "🕐", text: formatShortDate(dateStr))
                }
                
                // Codec · Resolution · Duration
                let codecParts = [
                    message.content.codec,
                    message.content.resolution,
                    message.content.duration.map { formatDuration($0) }
                ].compactMap { $0 }
                
                if !codecParts.isEmpty {
                    metaSummaryRow(icon: "🎬", text: codecParts.joined(separator: " · "))
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            // Action buttons
            HStack(spacing: 12) {
                // Show Details → (opens MetadataView)
                if onTapMetadata != nil {
                    Button {
                        onTapMetadata?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                            Text("Show Details")
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(Color(hex: "007AFF"))
                    }
                }
                
                Spacer()
                
                // Tap to add details → (opens ContextFormView)
                if onTapForm != nil {
                    Button {
                        onTapForm?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 11))
                            Text("Add Details")
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(Color(hex: "30D158"))
                    }
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func metaSummaryRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Text(icon)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "98989D"))
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let min = seconds / 60
        let sec = seconds % 60
        return String(format: "%d:%02d", min, sec)
    }
    
    private func formatShortDate(_ isoString: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString) else {
            return isoString
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }
    
    private var slackContent: some View {
        HStack(spacing: 8) {
            Text("💬")
                .font(.system(size: 14))
            Text(message.content.text ?? "Posted to Slack")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "E5E5EA"))
        }
    }
    
    // MARK: - Bubble Background
    
    private var bubbleBackground: some View {
        Group {
            if isOutgoing {
                LinearGradient(
                    colors: [Color(hex: "007AFF"), Color(hex: "0063D1")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                Color(hex: "2C2C2E")
            }
        }
    }
    
    // MARK: - Timestamp
    
    private var formattedTime: String? {
        guard let dateStr = message.createdAt else { return nil }
        
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let date = iso.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) else {
            return nil
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Chat Bubble Shape

struct ChatBubbleShape: Shape {
    let isOutgoing: Bool
    
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        let tailRadius: CGFloat = 6
        
        var path = Path()
        
        if isOutgoing {
            // Rounded rect with tail on bottom-right
            path.addRoundedRect(
                in: CGRect(x: 0, y: 0, width: rect.width - tailRadius, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            // Small tail
            path.move(to: CGPoint(x: rect.width - tailRadius, y: rect.height - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.width, y: rect.height),
                control: CGPoint(x: rect.width - tailRadius, y: rect.height)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.width - tailRadius * 2, y: rect.height),
                control: CGPoint(x: rect.width - tailRadius, y: rect.height)
            )
        } else {
            // Rounded rect with tail on bottom-left
            path.addRoundedRect(
                in: CGRect(x: tailRadius, y: 0, width: rect.width - tailRadius, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            // Small tail
            path.move(to: CGPoint(x: tailRadius, y: rect.height - radius))
            path.addQuadCurve(
                to: CGPoint(x: 0, y: rect.height),
                control: CGPoint(x: tailRadius, y: rect.height)
            )
            path.addQuadCurve(
                to: CGPoint(x: tailRadius * 2, y: rect.height),
                control: CGPoint(x: tailRadius, y: rect.height)
            )
        }
        
        return path
    }
}
