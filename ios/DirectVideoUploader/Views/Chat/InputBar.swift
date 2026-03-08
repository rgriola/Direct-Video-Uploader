import SwiftUI

/// Input bar at the bottom — text field + send + attachment buttons.
struct InputBar: View {
    var onSend: (String) -> Void
    var onAttach: () -> Void
    
    @State private var text = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Top border
            Rectangle()
                .fill(Color.gray)
                .frame(height: 2)
            
            HStack(spacing: 10) {
                // Attachment button (video picker)
                Button {
                    onAttach()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color(hex: "#1C3A5F"))
                }
                
                // Text field
                HStack {
                    TextField("Message", text: $text)
                        .font(.system(size: 16))
                        .foregroundStyle(.black)
                        .focused($isFocused)
                        .onSubmit {
                            sendMessage()
                        }
                    
                    // Camera shortcut
                    Button {
                        onAttach()
                    } label: {
                        Image(systemName: "video.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.black)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(hex: "#D4D4D4"))
                .clipShape(Capsule())
                
                // Send button
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            text.isEmpty
                            ? Color.white.opacity(0.7)
                            : Color(hex: "#1C3A5F")
                        )
                }
                .disabled(text.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hex: "#ADADAD"))
           // 
        }
    }
    
    private func sendMessage() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        text = ""
    }
}
