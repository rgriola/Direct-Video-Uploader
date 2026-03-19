import SwiftUI

/// Individual chat bubble — handles outgoing (blue, right) and incoming (gray, left).
struct MessageBubble: View {
    let message: ChatMessage
    var thumbnail: UIImage?
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
                        .font(Theme.timestampFont)
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
            .font(Theme.bodyFont)
            .foregroundStyle(isOutgoing ? .white : Theme.incomingText)
    }
    
    private var videoContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(Theme.iconFont)
            Text(message.content.displayText)
                .font(Theme.bodyFont)
        }
        .foregroundStyle(isOutgoing ? .white : Theme.incomingText)
    }
    
    private var confirmationContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main confirmation text
            Text(message.content.text ?? "Upload confirmed")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.incomingText)
            
            // Slug
            if let slug = message.content.slug {
                Text(slug)
                    .font(Theme.monoSmallFont)
                    .foregroundStyle(Theme.incomingText)
                    .lineLimit(1)
            }
            
            // Mediasource ID + Metadata button on same line
            if let msId = message.content.mediasourceId {
                HStack(spacing: 4) {
                    Text("🔗")
                        .font(Theme.iconSmallFont)
                    Text(msId)
                        .font(Theme.monoIdFont)
                        .foregroundStyle(Theme.incomingText)
                    
                    Spacer()
                    
                    if let onTapMetadata {
                        ChatActionButton(
                            icon: "info.circle.fill",
                            label: "Metadata",
                            color: Theme.actionBlue,
                            action: onTapMetadata
                        )
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
                    .font(Theme.monoSmallFont)
                    .foregroundStyle(Theme.incomingText)
                    .lineLimit(1)
            }
            
            // Mediasource ID + URL link + copy button
            if let msId = message.content.mediasourceId {
                HStack(spacing: 4) {
                    Text("🔗")
                        .font(Theme.iconSmallFont)
                    Text(msId)
                        .font(Theme.monoIdFont)
                        .foregroundStyle(Theme.incomingText)
                    
                    if let clipURL = ServerConfig.clipURL(msId) {
                        Text(clipURL.absoluteString)
                            .font(Theme.urlFont)
                            .foregroundStyle(Theme.incomingText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    // Copy button — copies the full clip viewer URL
                    Button {
                        let link = ServerConfig.clipURL(msId)?.absoluteString ?? msId
                        UIPasteboard.general.string = link
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(Theme.iconSmallFont)
                            .foregroundStyle(Theme.incomingText.opacity(0.6))
                    }
                }
            }
            
            Divider()
                .background(Color.black.opacity(0.1))
            
            // Action button — Metadata only
            HStack(spacing: 12) {
                if let onTapMetadata {
                    ChatActionButton(
                        icon: "info.circle.fill",
                        label: "Metadata",
                        color: Theme.blue,
                        action: onTapMetadata
                    )
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func metaSummaryRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Text(icon)
                .font(Theme.iconSmallFont)
            Text(text)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.secondaryText)
        }
    }
    
    private func formatShortDate(_ isoString: String) -> String {
        DVUDateFormatting.longDate(isoString)
    }
    
    private var slackContent: some View {
        Group {
            if isOutgoing {
                // Outgoing — simple sending indicator
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill")
                            .font(Theme.iconMediumFont)
                            .foregroundStyle(.white)
                        Text("Sending to Slack…")
                            .font(Theme.captionBoldFont)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(message.content.text ?? "")
                        .font(Theme.bodyFont)
                        .foregroundStyle(.white)
                }
            } else {
                // Incoming — structured Slack card
                slackCardContent
            }
        }
    }

    /// Structured Slack confirmation card — thumbnail left, details right, Slack-style.
    private var slackCardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Green accent bar at top (Slack-style)
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.green)
                .frame(height: 3)
                .padding(.horizontal, 8)

            HStack(alignment: .top, spacing: 10) {
                // Thumbnail on the left with green stroke
                if let thumb = thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.green, lineWidth: 2)
                        )
                } else {
                    // Placeholder thumbnail
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.15))
                        .frame(width: 64, height: 64)
                        .overlay(
                            Image(systemName: "video.fill")
                                .font(Theme.titleFont)
                                .foregroundStyle(Theme.secondaryText)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.green, lineWidth: 2)
                        )
                }

                // Right side — details
                VStack(alignment: .leading, spacing: 4) {
                    // Slack header
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(Theme.iconSmallFont)
                            .foregroundStyle(Theme.green)
                        Text("Posted to Slack")
                            .font(Theme.captionBoldFont)
                            .foregroundStyle(Theme.green)
                    }

                    // Owner
                    if let owner = message.content.userName {
                        HStack(spacing: 4) {
                            Image(systemName: "person.fill")
                                .font(Theme.iconTinyFont)
                                .foregroundStyle(Theme.secondaryText)
                            Text(owner)
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.incomingText)
                        }
                    }

                    // Mediasource ID
                    if let msId = message.content.mediasourceId {
                        HStack(spacing: 4) {
                            Text("🔗")
                                .font(Theme.iconTinyFont)
                            Text(msId)
                                .font(Theme.monoSmallFont)
                                .foregroundStyle(Theme.incomingText)
                                .lineLimit(1)
                        }
                    }

                    // Clip URL
                    if let msId = message.content.mediasourceId,
                       let clipURL = ServerConfig.clipURL(msId) {
                        Button {
                            UIApplication.shared.open(clipURL)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.circle.fill")
                                    .font(Theme.iconSmallFont)
                                Text("View Clip")
                                    .font(Theme.captionBoldFont)
                            }
                            .foregroundStyle(Theme.blue)
                        }
                    }
                }
            }
            .padding(.top, 8)

            // Channel/mention badges
            if message.content.channel != nil || message.content.mention != nil {
                HStack(spacing: 8) {
                    if let channel = message.content.channel {
                        ChatBadge(
                            symbol: "#",
                            text: channel,
                            color: Theme.blue.opacity(0.3)
                        )
                    }
                    if let mention = message.content.mention {
                        ChatBadge(
                            symbol: "@",
                            text: mention,
                            color: Theme.green.opacity(0.3)
                        )
                    }
                }
                .padding(.top, 8)
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
        Path(roundedRect: rect, cornerRadius: 18)
    }
}
