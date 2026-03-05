import SwiftUI

/// Input bar at the bottom — text field + send + attachment buttons.
struct InputBar: View {
    var onSend: (String) -> Void
    var onAttach: () -> Void
    
    @State private var text = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Separator
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 0.5)
            
            HStack(spacing: 10) {
                // Attachment button (video picker)
                Button {
                    onAttach()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.blue)
                }
                
                // Text field
                HStack {
                    TextField("Message", text: $text)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
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
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.darkBg)
                .clipShape(Capsule())
                
                // Send button
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            text.isEmpty
                            ? Color.white.opacity(0.2)
                            : Theme.blue
                        )
                }
                .disabled(text.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.94))
        }
    }
    
    private func sendMessage() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        text = ""
    }
}
