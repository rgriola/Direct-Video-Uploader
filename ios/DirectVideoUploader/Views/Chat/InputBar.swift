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
                        .font(Theme.attachButtonFont)
                        .foregroundStyle(Theme.actionBlue)
                }
                
                // Text field
                HStack {
                    TextField("Message", text: $text)
                        .font(Theme.bodyFont)
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
                            .font(Theme.iconFont)
                            .foregroundStyle(.black)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.inputFieldBg)
                .clipShape(Capsule())
                
                // Send button
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(Theme.sendButtonFont)
                        .foregroundStyle(
                            text.isEmpty
                            ? Color.white.opacity(0.7)
                            : Theme.actionBlue
                        )
                }
                .disabled(text.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.inputBarBg)
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
