import SwiftUI

/// Swipeable in-app instructions — 4 pages presented as a sheet from the chat header.
struct InstructionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0

    private let pageCount = 4

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.black.ignoresSafeArea()

            TabView(selection: $currentPage) {
                firstThingsPage.tag(0)
                iphoneMediaPage.tag(1)
                howToUsePage.tag(2)
                archivePage.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            // Dismiss button
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(Theme.icon16)
                    .foregroundStyle(Theme.white.opacity(0.6))
                    .padding(Theme.space16)
                    .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Page 1: First Things to Know

    private var firstThingsPage: some View {
        ScrollView {
            VStack(spacing: Theme.space24) {
                Spacer().frame(height: Theme.space32)

                Image(systemName: "checkmark.shield.fill")
                    .font(Theme.display44)
                    .foregroundStyle(Theme.green)

                Text("First Things to Know")
                    .font(Theme.font20Bold)
                    .foregroundStyle(Theme.white)

                VStack(alignment: .leading, spacing: Theme.space16) {
                    instructionRow(
                        emoji: "⚠️",
                        text: "Do not close Fixer until the upload is complete. The progress bar tracks upload — you'll get a confirmation message when it's done."
                    )
                    instructionRow(
                        emoji: "💬",
                        text: "As soon as the first Metadata chat appears, you can Slack people right from the text box. Type @yourperson or #thischannel and Fixer sends the metadata to them."
                    )
                    instructionRow(
                        emoji: "📦",
                        text: "Once your upload is finished it moves to Archive and is held for 7 days."
                    )
                    instructionRow(
                        emoji: "➕",
                        text: "You can start an additional upload right away."
                    )
                    instructionRow(
                        emoji: "📱",
                        text: "Fixer is designed to replicate texting — share videos just like you share with friends and colleagues."
                    )
                }
                .padding(.horizontal, Theme.space24)

                Spacer()
            }
            .padding(.bottom, 60) // room for page dots
        }
    }

    // MARK: - Page 2: iPhone Media Settings

    private var iphoneMediaPage: some View {
        ScrollView {
            VStack(spacing: Theme.space24) {
                Spacer().frame(height: Theme.space32)

                Image(systemName: "iphone")
                    .font(Theme.display44)
                    .foregroundStyle(Theme.blue)

                Text("iPhone Media Management")
                    .font(Theme.font20Bold)
                    .foregroundStyle(Theme.white)

                VStack(alignment: .leading, spacing: Theme.space16) {
                    // iCloud warning
                    VStack(alignment: .leading, spacing: Theme.space8) {
                        Text("iCloud Optimization")
                            .font(Theme.font16Semibold)
                            .foregroundStyle(Theme.amber)

                        Text("Apple automatically moves videos to iCloud to save space. This can cause significant upload delays — the video must be downloaded before uploading. Videos are also compressed with optimization.")
                            .font(Theme.font16Regular)
                            .foregroundStyle(Theme.white.opacity(0.85))
                    }

                    // Turn it off note
                    VStack(alignment: .leading, spacing: Theme.space8) {
                        Text("Can I Turn It Off?")
                            .font(Theme.font16Semibold)
                            .foregroundStyle(Theme.white)

                        Text("Yes — but it affects where ALL your media lives. Only recommended if your device is dedicated to work and you can prioritize it for video/photo purposes.")
                            .font(Theme.font16Regular)
                            .foregroundStyle(Theme.white.opacity(0.85))
                    }

                    // Recommended settings box
                    VStack(alignment: .leading, spacing: Theme.space12) {
                        HStack(spacing: Theme.space8) {
                            Image(systemName: "star.fill")
                                .font(Theme.icon13)
                                .foregroundStyle(Theme.yellow)
                            Text("Recommended for Speed & Quality")
                                .font(Theme.font13Semibold)
                                .foregroundStyle(Theme.yellow)
                        }

                        VStack(alignment: .leading, spacing: Theme.space8) {
                            settingRow("Turn off iPhone Optimization")
                            settingRow("Photos in Cloud → OFF")
                            settingRow("Privacy & Security → Fixer → Current → ON")
                        }

                        Text("This preserves the original video without compression and significantly reduces upload times.")
                            .font(Theme.font13Regular)
                            .foregroundStyle(Theme.white.opacity(0.6))
                    }
                    .padding(Theme.space16)
                    .background(Theme.glassOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusMd)
                            .strokeBorder(Theme.yellow.opacity(0.3), lineWidth: 1)
                    )
                }
                .padding(.horizontal, Theme.space24)

                Spacer()
            }
            .padding(.bottom, 60)
        }
    }

    // MARK: - Page 3: How to Use Fixer

    private var howToUsePage: some View {
        ScrollView {
            VStack(spacing: Theme.space24) {
                Spacer().frame(height: Theme.space32)

                Image(systemName: "video.badge.plus")
                    .font(Theme.display44)
                    .foregroundStyle(Theme.purple)

                Text("How to Use Fixer")
                    .font(Theme.font20Bold)
                    .foregroundStyle(Theme.white)

                VStack(alignment: .leading, spacing: Theme.space12) {
                    stepRow(1, "Tap the **+** button (bottom left) to open your video library. Fixer filters out photos.")
                    stepRow(2, "Select your video and tap the purple **✓** checkmark.")
                    stepRow(3, "**Optional:** Trim your clip — works just like iMovie.")
                    stepRow(4, "Tap **Next >>** to queue the video for upload in chat.")
                    stepRow(5, "**Optional:** Choose to transcribe your audio.")
                    stepRow(6, "Tap the **↑** arrow to start the upload.")
                    stepRow(7, "A progress bar appears — the slug form pops up automatically.")
                    stepRow(8, "Fill in **Slug** and **Description** (required) and send.")
                    stepRow(9, "⚠️ **Do NOT close Fixer** — the upload will stop.")
                }
                .padding(.horizontal, Theme.space24)

                // Behind the scenes
                VStack(alignment: .leading, spacing: Theme.space8) {
                    Text("What's Happening")
                        .font(Theme.font13Semibold)
                        .foregroundStyle(Theme.secondaryText)

                    Text("Fixer reads GPS, file type, size, duration, and device info from your video. If you transcribed, that's included too. The server returns your Mediasource number and clip link. When upload and processing finish, you get a confirmation.")
                        .font(Theme.font13Regular)
                        .foregroundStyle(Theme.white.opacity(0.6))
                }
                .padding(Theme.space16)
                .background(Theme.glassOverlay)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                .padding(.horizontal, Theme.space24)

                Spacer()
            }
            .padding(.bottom, 60)
        }
    }

    // MARK: - Page 4: Archive

    private var archivePage: some View {
        ScrollView {
            VStack(spacing: Theme.space24) {
                Spacer().frame(height: Theme.space32)

                Image(systemName: "archivebox.fill")
                    .font(Theme.display44)
                    .foregroundStyle(Theme.amber)

                Text("Archive")
                    .font(Theme.font20Bold)
                    .foregroundStyle(Theme.white)

                VStack(alignment: .leading, spacing: Theme.space16) {
                    instructionRow(
                        emoji: "🗓️",
                        text: "Completed and unfinished uploads are held for 7 days."
                    )
                    instructionRow(
                        emoji: "🔗",
                        text: "Find the metadata and web link for each video."
                    )
                    instructionRow(
                        emoji: "💬",
                        text: "Share video details directly to Slack."
                    )
                    instructionRow(
                        emoji: "📝",
                        text: "If your slug form wasn't completed, finish it here — Fixer will update the server."
                    )
                }
                .padding(.horizontal, Theme.space24)

                Spacer()

                // "Got it" button on last page
                Button { dismiss() } label: {
                    Text("Got it")
                        .font(Theme.font16Semibold)
                        .foregroundStyle(Theme.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.space16)
                        .background(Theme.purple)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                }
                .padding(.horizontal, Theme.space24)
                .padding(.bottom, 60)
            }
        }
    }

    // MARK: - Helpers

    /// Emoji + text row used on pages 1 and 4.
    private func instructionRow(emoji: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space12) {
            Text(emoji)
                .font(Theme.display24)

            Text(text)
                .font(Theme.font16Regular)
                .foregroundStyle(Theme.white.opacity(0.85))
        }
    }

    /// Numbered step row used on page 3.
    private func stepRow(_ number: Int, _ markdown: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Theme.space12) {
            Text("\(number)")
                .font(Theme.font13Semibold)
                .foregroundStyle(Theme.purple)
                .frame(width: 24, height: 24)
                .background(Theme.purple.opacity(0.15))
                .clipShape(Circle())

            Text(markdown)
                .font(Theme.font16Regular)
                .foregroundStyle(Theme.white.opacity(0.85))
        }
    }

    /// Settings recommendation row.
    private func settingRow(_ text: String) -> some View {
        HStack(spacing: Theme.space8) {
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.icon13)
                .foregroundStyle(Theme.green)
            Text(text)
                .font(Theme.font16Regular)
                .foregroundStyle(Theme.white)
        }
    }
}
