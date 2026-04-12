import SwiftUI

/// Swipeable in-app instructions — 5 pages presented as a sheet from the chat header.
struct InstructionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0

    private let pageCount = 5

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.black.ignoresSafeArea()

            TabView(selection: $currentPage) {
                firstThingsPage.tag(0)
                iphoneMediaPage.tag(1)
                howToUsePage.tag(2)
                behindTheScenesPage.tag(3)
                archivePage.tag(4)
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
                        text: "Keep Fixer open until the upload is 100% complete. Closing Fixer will stop cancel the upload."
                    )
                    instructionRow(
                        icon: "paperplane.fill",
                        text: "When the metadata chat appears, you can Slack your team from the text box. Type @yourperson or #thischannel, Fixer sends the metadata to them."
                    )
                    instructionRow(
                        icon: "archivebox.fill",
                        text: "Uploads move to Archive upon completion & are held for 7 days. The clip metadata, Slack, and web link live here."
                    )
                    instructionRow(
                        icon: "plus.circle.fill",
                        text: "Use this plus button to start a new upload."
                    )
                    instructionRow(
                        icon: "iphone",
                        text: "Fixer is designed to replicate texting — send videos just as you would with friends and colleagues."
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
                    .foregroundStyle(Theme.purple)

                Text("Recommeded iPhone Settings")
                    .font(Theme.font20Bold)
                    .foregroundStyle(Theme.white)

                    VStack(alignment: .leading, spacing: Theme.space16) {
                        // Recommended settings box
                        VStack(alignment: .leading, spacing: Theme.space12) {

                            HStack(spacing: Theme.space8) {
                                Image(systemName: "star.fill")
                                    .font(Theme.icon13)
                                    .foregroundStyle(Theme.yellow)
                                Text("The Goal: Preserve video quality and reduce upload time")
                                    .font(Theme.font13Semibold)
                                    .foregroundStyle(Theme.yellow)
                            }
    
                            VStack(alignment: .leading, spacing: Theme.space8) {
                                settingRow("Photo Sync to iCloud -> OFF")
                                settingRow("Camera > Record Video > 1080p @ 30fps")
                                settingRow("Camera > Formats > Most Compatible (h264)")
                            }

                        }
                        .padding(Theme.space16)
                        .background(Theme.glassOverlay)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusMd)
                                .strokeBorder(Theme.yellow.opacity(0.3), lineWidth: 1)
                        )

                        // iCloud warning
                        VStack(alignment: .leading, spacing: Theme.space8) {
                            Text("How Apple Manages Your Media")
                                .font(Theme.font16Semibold)
                                .foregroundStyle(Theme.amber)

                            Text("When your phone is locked media is automatically sent to your iCloud. This allows sharing across your devices and optimizes storage. By default videos are compressed during this process unless you turn off this setting.")
                                .font(Theme.font16Regular)
                                .foregroundStyle(Theme.white.opacity(0.85))
                            
                            Text("Video already in iCloud significantly delays the upload process: iCloud download > Convert video > Fixer upload > Server encoding.")
                                .font(Theme.font16Regular)
                                .foregroundStyle(Theme.white.opacity(0.85))
                        }

                        // Turn it off note
                        VStack(alignment: .leading, spacing: Theme.space8) {
                            Text("Setting Suggestion")
                                .font(Theme.font16Semibold)
                                .foregroundStyle(Theme.white)

                            Text("- Keep media local on your device.")
                                .font(Theme.font16Regular)
                                .foregroundStyle(Theme.white.opacity(0.85))
                            
                            Text("- Set video quality to most compatible (h264)")
                                .font(Theme.font16Regular)
                                .foregroundStyle(Theme.white.opacity(0.85))
                            
                            Text("- Turn on GPS for more complete metadata.")
                                .font(Theme.font16Regular)
                                .foregroundStyle(Theme.white.opacity(0.85))

                        }

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

                Text("Steps to Use Fixer")
                    .font(Theme.font20Bold)
                    .foregroundStyle(Theme.white)

                VStack(alignment: .leading, spacing: Theme.space12) {
                    stepRow(icon: "plus.circle.fill", text: "Opens the photo library. Fixer shows only videos.")
                    stepRow(icon: "checkmark.circle.fill", text: "Confirms the video selection.")
                    stepRow(icon: "scissors", text: "Trim clip or click Next >> to skip. Trim just like in iMovie.")
                    stepRow(icon: "mic.circle.fill", text: "Option to transcribe audio. \nThis is an on/off toggle.")
                    stepRow(icon: "arrow.up.circle.fill", text: "Start video upload. Keep Fixer Open")
                    stepRow(icon: "chart.bar.fill", text: "Progress bar appears, your video is uploading")
                    stepRow(icon: "text.cursor", text: "Required Form Fields: \n**Slug** and **Description** - scroll down and send.")
                    stepRow(icon: "exclamationmark.triangle.fill", text: "Do NOT close Fixer — the upload will stop.")
                }
                .padding(.horizontal, Theme.space24)

                Spacer()
            }
            .padding(.bottom, 60)
        }
    }

    // MARK: - Page 4: Behind the Scenes

    private var behindTheScenesPage: some View {
        ScrollView {
            VStack(spacing: Theme.space24) {
                Spacer().frame(height: Theme.space32)

                Image(systemName: "gearshape.2.fill")
                    .font(Theme.display44)
                    .foregroundStyle(Theme.blue)

                Text("What's Happening Inside Fixer")
                    .font(Theme.font20Bold)
                    .foregroundStyle(Theme.white)

                VStack(alignment: .leading, spacing: Theme.space16) {
                    instructionRow(
                        emoji: "📍",
                        text: "Fixer reads GPS, file type, size, duration, and device info from your video and populates the asset form for you."
                    )

                    instructionRow(
                        emoji: "🎙️",
                        text: "If you choose to transcribe audio Fixer uses Apple's Speech Recognition to create it. You should always check for accuracy of the transcription."
                    )

                    instructionRow(
                        emoji: "📎",
                        text: "The metadata is returned to you with the clip number and link."
                    )
                    instructionRow(
                        emoji: "✅",
                        text: "When the video finishes processing Fixer sends a confirmation message."
                    )

                    instructionRow(
                        emoji: "#️⃣",
                        text: "As soon as the metadata is processed you can Slack your team with the info."
                    )
                }
                .padding(.horizontal, Theme.space24)

                Spacer()
            }
            .padding(.bottom, 60)
        }
    }

    // MARK: - Page 5: Archive

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
                        text: "If your slug form wasn't completed, finish it here — Fixer will update the form."
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

    /// SF Symbol icon + text row — uses the actual app icon with purple/white palette.
    private func instructionRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.white, Theme.purple)
                .frame(width: 28)

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
    
    /// Step row with an inline SF Symbol icon (no number — icon serves as the leading element).
    private func stepRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.white, Theme.purple)
                .frame(width: 24)

            Text(LocalizedStringKey(text))
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
