import SwiftUI

/// Chat header — mimics the iMessage conversation header.
struct ChatHeaderView: View {
    let userName: String
    let connectionState: WebSocketService.ConnectionState
    
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
                        .font(Theme.headerNameFont)
                        .foregroundStyle(Theme.white)
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: Theme.statusDotSize, height: Theme.statusDotSize)
                        
                        Text(statusText)
                            .font(Theme.headerStatusFont)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Theme.darkBg
                    .opacity(0.94)
            )
            
            // Separator
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 0.5)
        }
    }
}
