import SwiftUI

/// Individual chat bubble — handles outgoing (blue, right) and incoming (gray, left).
struct MessageBubble: View {
    let message: ChatMessage
    var onTapMetadata: (() -> Void)?
    var onTapForm: (() -> Void)?
    var onTapViewClip: (() -> Void)?
    
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
                        .foregroundStyle(Color.black.opacity(0.7))
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
            .foregroundStyle(isOutgoing ? .white : Theme.incomingText)
    }
    
    private var videoContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(.system(size: 14))
            Text(message.content.displayText)
                .font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(isOutgoing ? .white : Theme.incomingText)
    }
    
    private var confirmationContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main confirmation text
            Text(message.content.text ?? "Upload confirmed")
                .font(.system(size: 15))
                .foregroundStyle(Theme.incomingText)
            
            // Slug
            if let slug = message.content.slug {
                Text(slug)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.incomingText)
                    .lineLimit(1)
            }
            
            // Mediasource ID + URL link + copy button
            if let msId = message.content.mediasourceId {
                HStack(spacing: 4) {
                    Text("🔗")
                        .font(.system(size: 12))
                    Text(msId)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.incomingText)
                    
                    if let slug = message.content.slug {
                        Text(ServerConfig.baseURL.absoluteString + "/clips/" + slug)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.incomingText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    // Copy button
                    Button {
                        let link = message.content.slug.map { ServerConfig.baseURL.absoluteString + "/clips/" + $0 } ?? msId
                        UIPasteboard.general.string = link
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.incomingText.opacity(0.6))
                    }
                }
            }
            
            // Action buttons — Metadata (left) + View (right)
            HStack(spacing: 12) {
                // Metadata button — opens metadata sheet
                if onTapMetadata != nil {
                    Button {
                        onTapMetadata?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 13))
                            Text("Metadata")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(hex: "#1C3A5F"))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                
                // View button — opens clip in browser
                if let msId = message.content.mediasourceId,
                   let clipURL = ServerConfig.clipURL(msId) {
                    Button {
                        UIApplication.shared.open(clipURL)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 13))
                            Text("View")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
    
    private var formRequestContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Slug name
            if let slug = message.content.slug {
                Text(slug)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.incomingText)
                    .lineLimit(1)
            }
            
            // Mediasource ID + URL link + copy button
            if let msId = message.content.mediasourceId {
                HStack(spacing: 4) {
                    Text("🔗")
                        .font(.system(size: 12))
                    Text(msId)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.incomingText)
                    
                    if let slug = message.content.slug {
                        Text(ServerConfig.baseURL.absoluteString + "/clips/" + slug)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.incomingText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    // Copy button
                    Button {
                        let link = message.content.slug.map { ServerConfig.baseURL.absoluteString + "/clips/" + $0 } ?? msId
                        UIPasteboard.general.string = link
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.incomingText.opacity(0.6))
                    }
                }
            }
            
            Divider()
                .background(Color.black.opacity(0.1))
            
            // Action button — Metadata only
            HStack(spacing: 12) {
                if onTapMetadata != nil {
                    Button {
                        onTapMetadata?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 13))
                            Text("Metadata")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .foregroundStyle(Theme.secondaryText)
        }
    }
    
    private func formatShortDate(_ isoString: String) -> String {
        DVUDateFormatting.longDate(isoString)
    }
    
    private var slackContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header with Slack icon
            HStack(spacing: 6) {
                Image(systemName: isOutgoing ? "paperplane.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(isOutgoing ? .white : Theme.green)
                Text(isOutgoing ? "Sending to Slack…" : "Slack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOutgoing ? .white.opacity(0.7) : Theme.secondaryText)
            }
            
            // Message text (command or confirmation)
            Text(message.content.text ?? "Posted to Slack")
                .font(.system(size: 15))
                .foregroundStyle(isOutgoing ? .white : Theme.incomingText)
            
            // Channel/mention badges on confirmation
            if !isOutgoing {
                HStack(spacing: 8) {
                    if let channel = message.content.channel {
                        HStack(spacing: 3) {
                            Text("#")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                            Text(channel)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.blue.opacity(0.3))
                        .foregroundStyle(Theme.black)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    if let mention = message.content.mention {
                        HStack(spacing: 3) {
                            Text("@")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                            Text(mention)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.green.opacity(0.3))
                        .foregroundStyle(Theme.black)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }
    
    // MARK: - Bubble Background
    
    private var bubbleBackground: some View {
        Group {
            if isOutgoing {
                Theme.outgoingBubble
            } else {
                Theme.incomingBubble
            }
        }
    }
    
    // MARK: - Timestamp
    
    private var formattedTime: String? {
        guard let dateStr = message.createdAt else { return nil }
        return DVUDateFormatting.timeOnly(dateStr)
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
