import SwiftUI

/// Placeholder view for the upcoming Photos feature.
/// Matches the visual style of ArchiveListView and ProfileView.
struct PhotosView: View {
    var body: some View {
        ZStack {
            // Same gradient background as Archive / Profile
            Theme.screenGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photos")
                            .font(Theme.font20Bold)
                            .foregroundStyle(Theme.white)
                        Text("Coming Soon")
                            .font(Theme.font13Regular)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.black)

                Divider().background(Theme.separator)

                // Feature overview
                ScrollView {
                    VStack(spacing: Theme.space24) {
                        // Hero icon
                        Image(systemName: "photo.fill")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(Theme.purple.opacity(0.6))
                            .padding(.top, Theme.space24)

                        // Feature rows
                        VStack(spacing: Theme.space24) {
                            instructionRow(
                                icon: "iphone",
                                text: "Separate photo upload pipeline connected globally to our servers."
                            )
                            instructionRow(
                                icon: "archivebox.fill",
                                text: "Multi-photo uploads grouped by assignment — metadata read and filed for each photo."
                            )
                            instructionRow(
                                icon: "paperplane.fill",
                                text: "Integrated with Slack for easy team sharing workflows."
                            )
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, Theme.space24)
                    }
                }
            }
        }
    }

    private func instructionRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.purple)
                .frame(width: 28, alignment: .center)

            Text(text)
                .font(Theme.font16Regular)
                .foregroundStyle(Theme.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
    }
}
