// May 11, 2026 - 6:35pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

/// Individual chat bubble — handles outgoing (blue, right) and incoming (gray, left).
struct MessageBubble: View {
    let message: ChatMessage
    var thumbnail: UIImage?
    var slackSent: Bool = false
    var onTapMetadata: (() -> Void)?

    private var isOutgoing: Bool { message.isOutgoing }
    private var isBatchSummary: Bool { message.content.code == "IOS_BATCH_SUMMARY" }

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 60) }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                // Bubble content
                bubbleContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isOutgoing ? Theme.purple : Theme.incomingBubble)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXl))

                // Timestamp
                if let time = formattedTime {
                    Text(time)
                        .font(Theme.font11Regular)
                        .foregroundStyle(Theme.secondaryText)
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
        case .slackPost:
            slackContent
        default:
            textContent
        }
    }

    // MARK: - Text

    @ViewBuilder
    private var textContent: some View {
        if isBatchSummary {
            Text(message.displayText)
                .font(Theme.mono11Medium)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .foregroundStyle(isOutgoing ? Theme.white : Theme.primaryText)
        } else {
            Text(message.displayText)
                .font(Theme.font16Regular)
                .foregroundStyle(isOutgoing ? Theme.white : Theme.primaryText)
        }
    }

    // MARK: - Video

    private var videoContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(Theme.icon13)
            Text(message.displayText)
                .font(Theme.font16Regular)
        }
        .foregroundStyle(isOutgoing ? Theme.white : Theme.primaryText)
    }

    // MARK: - Confirmation

    private var confirmationContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main confirmation text
            Text(message.displayText)
                .font(Theme.font16Regular)
                .foregroundStyle(Theme.primaryText)

            // Slug
            if let slug = message.content.slug {
                Text(slug)
                    .font(Theme.mono13Medium)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
            }

            // Mediasource ID + Metadata button on same line
            if let msId = message.content.mediasourceId {
                HStack(spacing: 4) {
                    Text("🔗")
                        .font(Theme.icon13)
                    Text(msId)
                        .font(Theme.mono16Bold)
                        .foregroundStyle(Theme.primaryText)

                    Spacer()

                    if let onTapMetadata {
                        ChatActionButton(
                            icon: "info.circle.fill",
                            label: "Metadata",
                            color: Theme.purple,
                            action: onTapMetadata
                        )
                    }
                }
            }
        }
    }

    // MARK: - Slack

    @ViewBuilder
    private var slackContent: some View {
        if isOutgoing {
            // Outgoing — sending/sent indicator
            VStack(alignment: .leading, spacing: 6) {
                Text(message.displayText)
                    .font(Theme.font16Regular)
                    .foregroundStyle(Theme.white)

                HStack(spacing: 6) {
                    Image(systemName: slackSent ? "checkmark.circle.fill" : "paperplane.fill")
                        .font(Theme.icon13)
                        .foregroundStyle(slackSent ? Theme.green : Theme.white)
                    Text(slackSent ? "Sent to Slack" : "Sending to Slack…")
                        .font(Theme.font13Semibold)
                        .foregroundStyle(slackSent ? Theme.white : Theme.white.opacity(0.7))
                }
            }
        } else {
            // Incoming — structured Slack card
            slackCardContent
        }
    }

    /// Structured Slack confirmation card — thumbnail left, details right.
    private var slackCardContent: some View {
        HStack(alignment: .top, spacing: 10) {
            // Thumbnail — downloaded UIImage or placeholder
            if let thumb = thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            } else {
                RoundedRectangle(cornerRadius: Theme.radiusSm)
                    .fill(Theme.glassOverlay)
                    .frame(width: 72, height: 72)
                    .overlay(
                        ProgressView()
                    )
            }

            // All details stacked to the right of thumbnail
            VStack(alignment: .leading, spacing: 4) {
                if let owner = message.content.userName {
                    Text(owner)
                        .font(Theme.font16Regular)
                        .foregroundStyle(Theme.primaryText)
                }

                if let msId = message.content.mediasourceId {
                    Text("MS# \(msId)")
                        .font(Theme.font16Regular)
                        .foregroundStyle(Theme.primaryText)
                }

                // Captured date
                if let capturedAt = message.content.capturedAt {
                    Text(DVUDateFormatting.longDate(capturedAt))
                        .font(Theme.font11Regular)
                        .foregroundStyle(Theme.secondaryText)
                }

                // Channel / mention
                if message.content.channel != nil || message.content.mention != nil {
                    HStack(spacing: 6) {
                        if let channel = message.content.channel {
                            Text("#\(channel)")
                                .font(Theme.font13Medium)
                                .foregroundStyle(Theme.purple)
                        }
                        if let mention = message.content.mention {
                            Text("@\(mention)")
                                .font(Theme.font13Medium)
                                .foregroundStyle(Theme.purple)
                        }
                    }
                }

                // Posted to Slack footer
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.green)
                    Text("Posted to Slack")
                        .foregroundStyle(Theme.primaryText)
                }
                .font(Theme.font13Medium)
            }
        }
    }

    // MARK: - Timestamp

    private var formattedTime: String? {
        guard let dateStr = message.createdAt else { return nil }
        return DVUDateFormatting.timeOnly(dateStr)
    }
}
