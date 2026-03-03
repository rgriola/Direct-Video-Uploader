import SwiftUI

/// Individual chat bubble — handles outgoing (blue, right) and incoming (gray, left).
struct MessageBubble: View {
    let message: ChatMessage
    var onTapMetadata: (() -> Void)?
    var onPostToSlack: (() -> Void)?
    
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
            
            if onPostToSlack != nil {
                Button {
                    onPostToSlack?()
                } label: {
                    HStack(spacing: 4) {
                        Text("📡")
                            .font(.system(size: 11))
                        Text("Post to Slack")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(hex: "4A154B").opacity(0.3))
                    .foregroundStyle(Color(hex: "E5E5EA"))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    
    private var formRequestContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "30D158"))
                Text("Context Form")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: "E5E5EA"))
            }
            
            Text(message.content.text ?? "Please fill out the form")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "98989D"))
            
            if onTapMetadata != nil {
                Button {
                    onTapMetadata?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                        Text("View Metadata")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color(hex: "007AFF"))
                }
            }
        }
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
