import SwiftUI

/// Chat header — mimics the iMessage conversation header.
struct ChatHeaderView: View {
    let userName: String
    let connectionState: WebSocketService.ConnectionState
    var onLogout: (() -> Void)?
    
    private var statusColor: Color {
        switch connectionState {
        case .connected:    return Theme.green
        case .connecting:   return Theme.yellow
        case .disconnected: return Theme.red
        }
    }
    
    private var statusText: String {
        switch connectionState {
        case .connected:    return "Ready"
        case .connecting:   return "Working..."
        case .disconnected: return "Trying to connect..."
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Theme.blue, Theme.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                    
                    Text("MF")
                        .font(Theme.headerAvatarFont)
                        .foregroundStyle(.white)
                }
                
                // Name + status
                VStack(alignment: .leading, spacing: 2) {
                    Text(userName)
                        .font(Theme.headerNameFont)
                        .foregroundStyle(.white)
                    
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
                
                // Logout button
                Button {
                    onLogout?()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(Theme.iconHeaderFont)
                        .foregroundStyle(.white.opacity(0.5))
                }
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
