import SwiftUI

/// Typing indicator bubble — three pulsing dots shown while awaiting server greeting.
/// Mimics the iMessage "someone is typing…" indicator.
struct TypingIndicatorBubble: View {
    @State private var phase = 0.0
    
    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color(hex: "A0A0A0"))
                        .frame(width: 8, height: 8)
                        .scaleEffect(dotScale(for: index))
                        .opacity(dotOpacity(for: index))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(hex: "2C2C2E"))
            .clipShape(ChatBubbleShape(isOutgoing: false))
            
            Spacer(minLength: 60)
        }
        .padding(.vertical, 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 1.0
            }
        }
    }
    
    private func dotScale(for index: Int) -> CGFloat {
        let offset = Double(index) * 0.15
        let value = sin((phase + offset) * .pi)
        return 0.7 + 0.3 * value
    }
    
    private func dotOpacity(for index: Int) -> Double {
        let offset = Double(index) * 0.15
        let value = sin((phase + offset) * .pi)
        return 0.4 + 0.6 * value
    }
}
