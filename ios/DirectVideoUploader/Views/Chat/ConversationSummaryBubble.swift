import SwiftUI

/// Inline summary card shown when the conversation is archived (mux:ready received).
/// Displays metadata and offers View + Share to Slack actions.
struct ConversationSummaryBubble: View {
    let mediasourceId: String?
    let formType: String?
    let formDescription: String?
    let formPriority: String?
    let duration: Int?
    let resolution: String?
    let fileSize: String?
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(Theme.iconLargeFont)
                        .foregroundStyle(Theme.green)
                    Text("Video Confirmed")
                        .font(Theme.bodyMediumFont)
                        .foregroundStyle(Theme.incomingText)
                }
                // horizontal line
                Divider().background(Color.black.opacity(0.1))

                // Metadata rows
                VStack(alignment: .leading, spacing: 5) {
                    if let msId = mediasourceId {
                        HStack {
                            Text("🔗")
                                .font(Theme.iconSmallFont)
                            Text(msId)
                                .font(Theme.monoIdFont)
                                .foregroundStyle(Theme.incomingText)

                            Spacer()

                            if let url = ServerConfig.clipURL(msId) {
                                ChatActionButton(
                                    icon: "play.circle.fill",
                                    label: "View",
                                    color: Theme.green,
                                    action: { UIApplication.shared.open(url) }
                                )
                            }
                        }
                    }
                    if let type = formType {
                        let priority = formPriority ?? ""
                        let combined = priority.isEmpty ? type : "\(type) · \(priority) Priority"
                        metaRow(icon: "tag.fill", label: combined)
                    }

                    // Technical details
                    let details = buildDetailsString()
                    if !details.isEmpty {
                        metaRow(icon: "film", label: details)
                    }
                }
            }
            .padding(14)
            .background(Theme.incomingBubble)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer(minLength: 60)
        }
        .padding(.horizontal, 4)
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    private func metaRow(icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Theme.iconSmallFont)
                .foregroundStyle(Theme.incomingText.opacity(0.5))
                .frame(width: 16)
            Text(label)
                .font(Theme.archiveMetaValueFont)
                .foregroundStyle(Theme.incomingText)
                .lineLimit(2)
        }
    }
    
    private func buildDetailsString() -> String {
        var parts: [String] = []
        if let dur = duration {
            parts.append(DVUDateFormatting.duration(dur))
        }
        if let res = resolution {
            parts.append(res)
        }
        if let size = fileSize {
            parts.append(DVUDateFormatting.fileSize(size))
        }
        return parts.joined(separator: " · ")
    }
}
