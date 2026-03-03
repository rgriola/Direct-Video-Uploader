import SwiftUI

/// Chat header — mimics the iMessage conversation header.
struct ChatHeaderView: View {
    let userName: String
    let subtitle: String
    let isConnected: Bool
    var onLogout: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "007AFF"), Color(hex: "5856D6")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                    
                    Text("MF")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                
                // Name + status
                VStack(alignment: .leading, spacing: 2) {
                    Text(userName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isConnected ? Color(hex: "30D158") : Color(hex: "FF453A"))
                            .frame(width: 6, height: 6)
                        
                        Text(isConnected ? subtitle : "Connecting...")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                
                Spacer()
                
                // Logout button
                Button {
                    onLogout?()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Color(hex: "1C1C1E")
                    .opacity(0.94)
            )
            
            // Separator
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 0.5)
        }
    }
}
