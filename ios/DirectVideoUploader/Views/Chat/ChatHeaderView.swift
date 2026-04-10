import SwiftUI

/// Chat header — mimics the iMessage conversation header.
struct ChatHeaderView: View {
    let userName: String
    let connectionState: WebSocketService.ConnectionState
    var onTapInstructions: (() -> Void)?
    
    private var statusColor: Color {
        switch connectionState {
        case .connected:    return Theme.green
        case .connecting:   return Theme.yellow
        case .disconnected: return Theme.red
        }
    }
    
    private var statusText: String {
        switch connectionState {
            case .connected:    return "GO"
            case .connecting:   return "Connecting..."
            case .disconnected: return "Getting a new token..."
            }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Avatar
                ZStack {
                    Image("FixerClean")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                        .background(Circle().fill(Theme.purple))
                    }
                
                // Name + status
                VStack(alignment: .leading, spacing: 2) {
                    Text(userName)
                        .font(Theme.font16Semibold)
                        .foregroundStyle(Theme.white)
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: Theme.statusDotSize, height: Theme.statusDotSize)
                        
                        Text(statusText)
                            .font(Theme.font11Regular)
                            .foregroundStyle(Theme.white.opacity(0.6))
                    }
                }
                
                Spacer()
                
                // Instructions button
                if let onTap = onTapInstructions {
                    Button(action: onTap) {
                        if #available(iOS 18.0, *) {
                            Image(systemName: "service.dog")
                                .font(Theme.icon20)
                                .foregroundStyle(Theme.purple)
                                .symbolEffect(.bounce.up.wholeSymbol, options: .nonRepeating)
                        } else {
                            Image(systemName: "service.dog")
                                .font(Theme.icon20)
                                .foregroundStyle(Theme.purple)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Theme.black
                    .opacity(0.94)
            )
            
            // Separator
            Rectangle()
                .fill(Theme.glassBorder)
                .frame(height: 0.5)
        }
    }
}
