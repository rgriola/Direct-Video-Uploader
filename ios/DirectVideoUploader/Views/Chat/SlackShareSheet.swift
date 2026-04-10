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
                            .font(Theme.font16Medium)
                            .foregroundStyle(Theme.white)
                    }
                    if let msId = mediasourceId {
                        Text(msId)
                            .font(Theme.mono13Medium)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.top, 8)
                
                // Input
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type #channel and/or @person")
                        .font(Theme.font13Regular)
                        .foregroundStyle(Theme.secondaryText)
                    
                    TextField("#channel @person", text: $slackText)
                        .font(Theme.font16Regular)
                        .padding(Theme.space12)
                        .background(Theme.cardBg)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .foregroundStyle(Theme.white)
                        .focused($isFocused)
                }
                
                // Send button
                Button {
                    onSend(slackText)
                } label: {
                    Text("Share to Slack")
                        .font(Theme.font16Semibold)
                        .foregroundStyle(Theme.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.space12)
                        .background(Theme.purple)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                }
                .disabled(slackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .background(Theme.black.ignoresSafeArea())
            .navigationTitle("Share to Slack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                        .foregroundStyle(Theme.blue)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { isFocused = true }
    }
}
