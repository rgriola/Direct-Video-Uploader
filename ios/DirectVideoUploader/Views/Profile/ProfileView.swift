import SwiftUI

/// Simple profile screen with logout option.
struct ProfileView: View {
    @Environment(AuthService.self) private var auth
    @Environment(WebSocketService.self) private var ws
    @State private var showLogoutConfirm = false

    var body: some View {
        ZStack {
          // view background
          Theme.screenGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                Text("Profile")
                    .font(Theme.headerNameFont)
                    .foregroundStyle(Theme.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.black.opacity(0.94))

                Spacer()

                // Logout button
                Button {
                    showLogoutConfirm = true
                } label: {
                    Text("Logout")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .confirmationDialog("Are you sure?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                    Button("Logout", role: .destructive) {
                        auth.logout()
                        ws.disconnect()
                    }
                }
            }
        }
    }
}
