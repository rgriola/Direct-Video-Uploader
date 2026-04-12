import SwiftUI

/// Inline summary card shown when the conversation is archived (mux:ready received).
/// Displays metadata and offers View + Share to Slack actions.
struct ConversationSummaryBubble: View {
    let mediasourceId: String?
    let formSlug: String?
    let duration: Int?
    let resolution: String?
    let fileSize: String?
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(Theme.display24)
                        .foregroundStyle(Theme.green)
                    Text("Video Ready")
                        .font(Theme.font16Medium)
                        .foregroundStyle(Theme.black)
                }

                Divider().background(Theme.black.opacity(0.1))

                // Metadata rows
                VStack(alignment: .leading, spacing: 5) {
                    if let msId = mediasourceId {
                        HStack {
                            Text("🔗")
                                .font(Theme.icon13)
                            Text(msId)
                                .font(Theme.mono16Bold)
                                .foregroundStyle(Theme.black)

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

                    if let slug = formSlug {
                        metaRow(icon: "tag.fill", label: slug)
                    }

                    let details = buildDetailsString()
                    if !details.isEmpty {
                        metaRow(icon: "film", label: details)
                    }
                }
            }
            .padding(14)
            .background(Theme.incomingBubble)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg))

            Spacer(minLength: 60)
        }
        .padding(.horizontal, 4)
    }
    
    // MARK: - Helpers
    
    private func metaRow(icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Theme.icon13)
                .foregroundStyle(Theme.black.opacity(0.5))
                .frame(width: 16)
            Text(label)
                .font(Theme.font11Regular)
                .foregroundStyle(Theme.black)
                .lineLimit(2)
        }
    }
    
    private func buildDetailsString() -> String {
        [
            duration.map { DVUDateFormatting.duration($0) },
            resolution,
            fileSize.map { DVUDateFormatting.fileSize($0) },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}
