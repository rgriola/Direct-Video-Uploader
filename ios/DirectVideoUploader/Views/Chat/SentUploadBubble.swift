import SwiftUI

/// Sent-upload card — stays in the chat thread after the user taps Send.
/// Shows thumbnail, filename, date, location badge and a green checkmark.
struct SentUploadBubble: View {
    let thumbnail: UIImage?
    let fileName: String
    let createdDate: String?
    let hasLocation: Bool
    
    var body: some View {
        HStack {
            Spacer(minLength: 60)
            
            VStack(alignment: .trailing, spacing: 4) {
                // Bubble content
                VStack(alignment: .leading, spacing: 0) {
                    // Thumbnail
                    if let thumb = thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 160)
                            .clipped()
                    }
                    
                    // File info + green checkmark
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            // Filename
                            Text(fileName)
                                .font(Theme.monoSmallFont)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            
                            // Created date
                            if let date = createdDate {
                                Text(date)
                                    .font(Theme.timestampFont)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            
                            // Location badge
                            if hasLocation {
                                HStack(spacing: 4) {
                                    Image(systemName: "location.fill")
                                        .font(Theme.locationIconFont)
                                    Text("Location included")
                                        .font(Theme.locationFont)
                                }
                                .foregroundStyle(Theme.green)
                            }
                        }
                        
                        Spacer()
                        
                        // Green checkmark — sent
                        Image(systemName: "checkmark.circle.fill")
                            .font(Theme.iconLargeFont)
                            .foregroundStyle(Theme.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .background(
                    LinearGradient(
                        colors: [Theme.videoBubbleHi, Theme.videoBubbleLo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Theme.green.opacity(0.3), lineWidth: 1)
                )
                
                // Label
                Text("Sent")
                    .font(Theme.timestampFont)
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 2)
    }
}
