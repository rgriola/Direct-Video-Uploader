import SwiftUI

/// Individual chat bubble — handles outgoing (blue, right) and incoming (gray, left).
struct MessageBubble: View {
    let message: ChatMessage
    var thumbnail: UIImage?
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
                        .font(Theme.timestampFont)
                        .foregroundStyle(Theme.black)
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

    /// Structured Slack confirmation card — thumbnail left, details right.
    private var slackCardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                // Thumbnail — downloaded UIImage or placeholder
                if let thumb = thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.15))
                        .frame(width: 64, height: 64)
                        .overlay(
                            ProgressView()
                        )
                }

                // Details
                VStack(alignment: .leading, spacing: 4) {
                    if let owner = message.content.userName {
                        Text(owner)
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.incomingText)
                    }

                    if let msId = message.content.mediasourceId {
                        Text("MS# \(msId)")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.incomingText)
                    }
                }
            }

            // Captured date
            if let capturedAt = message.content.capturedAt {
                Text(DVUDateFormatting.longDate(capturedAt))
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.incomingText)
            }

            // Channel / mention
            if message.content.channel != nil || message.content.mention != nil {
                HStack(spacing: 12) {
                    if let channel = message.content.channel {
                        Text("#\(channel)")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.incomingText)
                    }
                    if let mention = message.content.mention {
                        Text("@\(mention)")
                            .font(Theme.bodyFont)
                            .foregroundStyle(Theme.incomingText)
                    }
                }
            }

            // Posted to Slack footer
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.green)
                Text("Posted to Slack")
                    .foregroundStyle(Theme.incomingText)
            }
            .font(Theme.bodyFont)
        }
    }
    
    // MARK: - Bubble Background for text messages. 
    
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
