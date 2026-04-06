import SwiftUI

/// Sent-upload card — stays in the chat thread after the user taps Send.
/// Shows thumbnail, filename, date, location badge and a green checkmark.
struct SentUploadBubble: View {
    let thumbnail: UIImage?
    let fileName: String
    let createdDate: String?
    let hasLocation: Bool
    var isUploading: Bool = false
    var uploadProgress: Double = 0
    
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
                                .foregroundStyle(Theme.white)
                                .lineLimit(1)
                            
                            // Created date
                            if let date = createdDate {
                                Text(date)
                                    .font(Theme.timestampFont)
                                    .foregroundStyle(Theme.white)
                            }
                            
                            // Location badge
                            if hasLocation {
                                HStack(spacing: 4) {
                                    Image(systemName: "location.fill")
                                        .font(Theme.locationIconFont)
                                    Text("GPS")
                                        .font(Theme.locationFont)
                                }
                                .foregroundStyle(Theme.green)
                            }
                        }
                        
                        Spacer()
                        
                        if isUploading {
                            // Spinning indicator during upload
                            ProgressView()
                                .tint(Theme.white)
                        } else {
                            // Green checkmark — sent
                            Image(systemName: "checkmark.circle.fill")
                                .font(Theme.iconLargeFont)
                                .foregroundStyle(Theme.green)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    
                    // Upload progress bar
                    if isUploading {
                        VStack(spacing: 4) {
                            ProgressView(value: uploadProgress)
                                .tint(Theme.blue)
                            HStack {
                                Text("Uploading video…")
                                    .font(Theme.timestampFont)
                                    .foregroundStyle(Theme.white)
                                Spacer()
                                Text("\(Int(uploadProgress * 100))%")
                                    .font(Theme.timestampFont.monospacedDigit())
                                    .foregroundStyle(Theme.white)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                }
                .background(Theme.videoBubbleGradient)// bg for preview bubble
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Theme.green.opacity(0.3), lineWidth: 1)
                )
                
                // Label
                Text(isUploading ? "Uploading…" : "Sent")
                    .font(Theme.timestampFont)
                    .foregroundStyle(Theme.white)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 2)
    }
}
