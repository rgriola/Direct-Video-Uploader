import SwiftUI

/// Small sheet for entering #channel @user to share a clip to Slack.
struct SlackShareSheet: View {
    let mediasourceId: String?
    let originalFileName: String?
    var onSend: (String) -> Void
    var onDismiss: () -> Void
    
    @State private var slackText = "#general "
    @FocusState private var isFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Context
                VStack(spacing: 4) {
                    if let name = originalFileName {
                        Text(name)
                            .font(Theme.archiveTitleFont)
                            .foregroundStyle(.white)
                    }
                    if let msId = mediasourceId {
                        Text(msId)
                            .font(Theme.monoValueFont)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.top, 8)
                
                // Input
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type #channel and/or @person")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.secondaryText)
                    
                    TextField("#channel @person", text: $slackText)
                        .font(Theme.bodyFont)
                        .padding(12)
                        .background(Theme.cardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                        .focused($isFocused)
                }
                
                // Send button
                Button {
                    onSend(slackText)
                } label: {
                    Text("Share to Slack")
                        .font(Theme.loginButtonFont)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(slackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .background(Theme.darkBg.ignoresSafeArea())
            .navigationTitle("Share to Slack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                        .foregroundStyle(Theme.tint)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { isFocused = true }
    }
}
