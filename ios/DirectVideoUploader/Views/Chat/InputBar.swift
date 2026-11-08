import SwiftUI

/// Input bar at the bottom — text field + send + attachment buttons.
struct InputBar: View {
    var onSend: (String) -> Void
    var onAttach: () -> Void
    var attachmentDisabled = false
    var restoreAttachmentFocus: Bool
    var onAttachmentFocusRestored: () -> Void
    
    @State private var text = ""
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var attachmentIsFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Top border
            Rectangle()
                .fill(Theme.black)
                .frame(height: 2)
            
            HStack(spacing: 10) {
                // Attachment button (video picker)
                Button {
                    onAttach()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(Theme.display32)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.white, Theme.purple)
                        .tapTarget()
                    }
                .accessibilityLabel("Attach video")
                .accessibilityFocused($attachmentIsFocused)
                .disabled(attachmentDisabled)
                .task(id: restoreAttachmentFocus && !attachmentDisabled) {
                    guard restoreAttachmentFocus, !attachmentDisabled else { return }
                    attachmentIsFocused = true
                    onAttachmentFocusRestored()
                }
                
                // Text field
                HStack {
                   
                    TextField("Message", text: $text, prompt: Text("Slack from here # or @").foregroundColor(Theme.secondaryText))
                        .font(Theme.font16Regular)
                        .foregroundStyle(Theme.black)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .focused($isFocused)
                        .onSubmit {
                            sendMessage()
                        }


                        // Send button
                        Button {
                            sendMessage()
                            } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(Theme.display32)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                        text.isEmpty ? Theme.purple : Theme.white,
                                        text.isEmpty ? Theme.white : Theme.purple
                                    )
                                    .tapTarget()
                                }
                                .disabled(text.isEmpty)
                                .accessibilityLabel("Send message")
                        }
                        .padding(.leading, 4)
                        .background(Theme.lightGray)
                        .clipShape(Capsule())
                
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.black) // Footer background
        }
        .background(Theme.black)
    }
    
    private func sendMessage() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        text = ""
    }
}
