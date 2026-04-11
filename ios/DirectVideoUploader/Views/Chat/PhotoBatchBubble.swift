import SwiftUI

/// Phase of a photo batch bubble in the chat timeline.
enum PhotoBatchPhase {
    case staged      // Preview grid — show cancel X, send button
    case uploading   // Progress bar across batch
    case sent        // Green ✓ — all photos uploaded
    case partial     // Some failed — amber warning
}

/// Chat bubble displaying a batch of photos — thumbnail grid, batch progress, and status.
/// Analogous to VideoBubble but for photo batches.
struct PhotoBatchBubble: View {
    let phase: PhotoBatchPhase
    let thumbnails: [UIImage]       // Up to 4 for grid preview
    let photoCount: Int
    let summary: String             // e.g. "5 photos · 24.1 MB"
    let formatSummary: String       // e.g. "HEIC, JPEG"
    let hasLocation: Bool
    
    // Staged-only
    var onSend: (() -> Void)?
    var onCancel: (() -> Void)?
    
    // Upload progress
    var batchProgress: Double = 0
    var currentPhotoIndex: Int = 0
    
    // Partial failure info
    var failedCount: Int = 0
    
    var body: some View {
        HStack {
            Spacer(minLength: 60)
            
            VStack(alignment: .trailing, spacing: 4) {
                // Bubble content
                VStack(alignment: .leading, spacing: 0) {
                    // Thumbnail grid
                    ZStack(alignment: .topTrailing) {
                        thumbnailGrid
                            .frame(maxWidth: .infinity)
                            .frame(height: 160)
                            .clipped()
                        
                        // Cancel X — staged only
                        if phase == .staged {
                            Button {
                                onCancel?()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(Theme.display24)
                                    .foregroundStyle(Theme.white, Theme.black.opacity(0.5))
                                    .shadow(radius: 3)
                            }
                            .padding(8)
                        }
                        
                        // Photo count badge
                        if photoCount > 4 {
                            Text("+\(photoCount - 4)")
                                .font(Theme.font13Semibold)
                                .foregroundStyle(Theme.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Theme.black.opacity(0.6))
                                .clipShape(Capsule())
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }
                    }
                    
                    // Info row
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            // Batch summary
                            Text(summary)
                                .font(Theme.mono13Medium)
                                .foregroundStyle(Theme.white)
                            
                            // Format badges
                            Text(formatSummary)
                                .font(Theme.font11Regular)
                                .foregroundStyle(Theme.secondaryText)
                            
                            // Location badge
                            if hasLocation {
                                HStack(spacing: 4) {
                                    Image(systemName: "location.fill")
                                        .font(Theme.icon11)
                                    Text("GPS")
                                        .font(Theme.font11Regular)
                                }
                                .foregroundStyle(Theme.green)
                            }
                        }
                        
                        Spacer()
                        
                        // Trailing widget
                        trailingWidget
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    
                    // Progress bar — uploading phase only
                    if phase == .uploading {
                        VStack(spacing: 4) {
                            ProgressView(value: batchProgress)
                                .tint(Theme.blue)
                            HStack {
                                Text("Uploading photo \(currentPhotoIndex + 1) of \(photoCount)…")
                                    .font(Theme.font11Regular)
                                    .foregroundStyle(Theme.white)
                                Spacer()
                                Text("\(Int(batchProgress * 100))%")
                                    .font(Theme.font11Regular.monospacedDigit())
                                    .foregroundStyle(Theme.white)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                    
                    // Partial failure banner
                    if phase == .partial {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(Theme.icon13)
                            Text("\(failedCount) photo\(failedCount == 1 ? "" : "s") failed to upload")
                                .font(Theme.font11Regular)
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                }
                .background(Theme.videoBubbleGradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXl))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusXl)
                        .stroke(borderColor.opacity(0.3), lineWidth: 1)
                )
                
                // Bottom label
                bottomLabel
            }
        }
        .padding(.vertical, 2)
    }
    
    // MARK: - Thumbnail Grid
    
    @ViewBuilder
    private var thumbnailGrid: some View {
        let count = min(thumbnails.count, 4)
        
        if count == 0 {
            Rectangle()
                .fill(Theme.cardBg.opacity(0.5))
                .overlay {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.secondaryText)
                }
        } else if count == 1 {
            Image(uiImage: thumbnails[0])
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            let cols = count <= 2 ? 2 : 2
            let rows = count <= 2 ? 1 : 2
            
            GeometryReader { geo in
                let cellW = geo.size.width / CGFloat(cols)
                let cellH = geo.size.height / CGFloat(rows)
                
                ForEach(0..<count, id: \.self) { i in
                    let col = i % cols
                    let row = i / cols
                    
                    Image(uiImage: thumbnails[i])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cellW - 1, height: cellH - 1)
                        .clipped()
                        .offset(x: CGFloat(col) * cellW, y: CGFloat(row) * cellH)
                }
            }
        }
    }
    
    // MARK: - Phase-Dependent Elements
    
    @ViewBuilder
    private var trailingWidget: some View {
        switch phase {
        case .staged:
            Button {
                onSend?()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.display32)
                    .foregroundStyle(Theme.white)
            }
            
        case .uploading:
            ProgressView()
                .tint(Theme.white)
            
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.display32)
                .foregroundStyle(Theme.green)
            
        case .partial:
            Image(systemName: "exclamationmark.circle.fill")
                .font(Theme.display32)
                .foregroundStyle(.orange)
        }
    }
    
    private var borderColor: Color {
        switch phase {
        case .sent: return Theme.green
        case .partial: return .orange
        default: return Theme.blue
        }
    }
    
    @ViewBuilder
    private var bottomLabel: some View {
        switch phase {
        case .staged:
            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .font(Theme.font11Regular)
                Text("Upload \(photoCount) photo\(photoCount == 1 ? "" : "s")")
                    .font(Theme.font11Regular)
            }
            .foregroundStyle(Theme.white.opacity(0.3))
            .padding(.horizontal, 4)
            
        case .uploading:
            Text("Uploading…")
                .font(Theme.font11Regular)
                .foregroundStyle(Theme.white)
                .padding(.horizontal, 4)
            
        case .sent:
            Text("Sent")
                .font(Theme.font11Regular)
                .foregroundStyle(Theme.white)
                .padding(.horizontal, 4)
            
        case .partial:
            Text("Partially sent")
                .font(Theme.font11Regular)
                .foregroundStyle(.orange)
                .padding(.horizontal, 4)
        }
    }
}
