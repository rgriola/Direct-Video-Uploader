// May 10, 2026 - 1:55pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

/// Swipeable in-app instructions — 5 pages presented as a sheet from the chat header.
struct InstructionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0

    private let pageCount = 6

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.deepBg.ignoresSafeArea()

            TabView(selection: $currentPage) {
                disclosure.tag(0)
                firstThingsPage.tag(1)
                iphoneMediaPage.tag(2)
                howToUsePage.tag(3)
                behindTheScenesPage.tag(4)
                archivePage.tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            // Dismiss button
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.icon16)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(Theme.space16)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
    }

    private var disclosure: some View {
        ScrollView {
            VStack(spacing: Theme.space24) {
                Spacer().frame(height: Theme.space32)

                Image(systemName: "sos")
                    .font(Theme.display44)
                    .foregroundStyle(Theme.red)

                Text("DISCLOSURE - BETA FISH")
                    .font(Theme.font20Bold)
                    .foregroundStyle(Theme.yellow)

                Text(
                    """
                    This is a beta version of Fixer available to anyone with the right access codes.

                    Video uploaded to our server stand-in, Mux.com, is available for anyone to view who has access to this app.

                    Swipe right to continue with our guide and Thank You for taking a look at the Fixer Beta. >>
                    """
                )
                .font(Theme.font28Bold)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(.horizontal, Theme.space24)
            .padding(.bottom, 60)  // room for page dots
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
                    .foregroundStyle(Theme.primaryText)

                VStack(alignment: .leading, spacing: Theme.space16) {
                    instructionRow(
                        emoji: "⚠️",
                        text:
                            "Keep Fixer open until the upload is 100% complete. Closing Fixer will cancel the upload."
                    )
                    instructionRow(
                        icon: "paperplane.fill",
                        text:
                            "When the metadata chat appears, you can Slack your team from the text box. Type @yourperson or #thischannel, Fixer sends the metadata to them."
                    )
                    instructionRow(
                        icon: "archivebox.fill",
                        text:
                            "Archive shows uploads from the last 7 days and older uploads that need details or upload recovery. Find clip metadata, Slack, and web links here."
                    )
                    instructionRow(
                        icon: "plus.circle.fill",
                        text: "Use this plus button to start a new upload."
                    )
                    instructionRow(
                        icon: "iphone",
                        text:
                            "Fixer is designed to replicate texting — send videos just as you would with friends and colleagues."
                    )
                }
                .padding(.horizontal, Theme.space24)

                Spacer()
            }
            .padding(.bottom, 60)  // room for page dots
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

                Text("Recommended iPhone Settings")
                    .font(Theme.font20Bold)
                    .foregroundStyle(Theme.primaryText)

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

                        Text(
                            "When your phone is locked, media is automatically sent to your iCloud. This allows sharing across your devices and optimizes storage. By default videos are compressed during this process unless you turn off this setting."
                        )
                        .font(Theme.font16Regular)
                        .foregroundStyle(Theme.lightText)

                        Text(
                            "Videos already in iCloud significantly delay the upload process: iCloud download > Convert video > Fixer upload > Server encoding."
                        )
                        .font(Theme.font16Regular)
                        .foregroundStyle(Theme.lightText)
                    }

                    // Turn it off note
                    VStack(alignment: .leading, spacing: Theme.space8) {
                        Text("Setting Suggestions")
                            .font(Theme.font16Semibold)
                            .foregroundStyle(Theme.primaryText)

                        Text("- Keep media local on your device")
                            .font(Theme.font16Regular)
                            .foregroundStyle(Theme.lightText)

                        Text("- Set video quality to most compatible (h264)")
                            .font(Theme.font16Regular)
                            .foregroundStyle(Theme.lightText)

                        Text("- Turn on GPS for more complete metadata")
                            .font(Theme.font16Regular)
                            .foregroundStyle(Theme.lightText)

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
                    .foregroundStyle(Theme.primaryText)

                VStack(alignment: .leading, spacing: Theme.space12) {
                    stepRow(
                        icon: "plus.circle.fill",
                        text: "Opens the photo library. Fixer shows only videos.")
                    stepRow(icon: "checkmark.circle.fill", text: "Confirms the video selection.")
                    stepRow(
                        icon: "scissors",
                        text: "Trim clip or click Next >> to skip. Trim just like in iMovie.")
                    stepRow(
                        icon: "mic.circle.fill",
                        text: "Option to transcribe audio. \nThis is an on/off toggle.")
                    stepRow(
                        icon: "arrow.up.circle.fill", text: "Start video upload. Keep Fixer open.")
                    stepRow(
                        icon: "chart.bar.fill",
                        text: "Progress bar appears. The video is uploading.")
                    stepRow(
                        icon: "text.cursor",
                        text:
                            "Required Form Fields: \n**Slug** and **Description** - scroll down and send."
                    )
                    stepRow(
                        icon: "exclamationmark.triangle.fill",
                        text: "Do NOT close Fixer — the upload will stop")
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
                    .foregroundStyle(Theme.primaryText)

                VStack(alignment: .leading, spacing: Theme.space16) {
                    instructionRow(
                        emoji: "📍",
                        text:
                            "Fixer reads GPS, timestamp, file type, size, duration, and device info from your video and populates the asset form for you."
                    )

                    instructionRow(
                        emoji: "🎙️",
                        text:
                            "If you choose to transcribe audio, Fixer uses Apple's Speech Recognition to create it. Always check for transcription accuracy."
                    )

                    instructionRow(
                        emoji: "📎",
                        text: "The metadata is returned with the clip number and link."
                    )
                    instructionRow(
                        emoji: "✅",
                        text:
                            "When the video finishes processing Fixer sends a confirmation message."
                    )

                    instructionRow(
                        emoji: "#️⃣",
                        text: "Once the metadata is available, remember to Slack your team."
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
                    .foregroundStyle(Theme.primaryText)

                VStack(alignment: .leading, spacing: Theme.space16) {
                    instructionRow(
                        emoji: "🗓️",
                        text: "Completed uploads appear for 7 days. Older uploads needing details or recovery stay available."
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
                        text:
                            "If your slug form was incompleted, finish it here — Fixer will update the form."
                    )
                }
                .padding(.horizontal, Theme.space24)

                Spacer()

                // "Got it" button on last page
                Button {
                    dismiss()
                } label: {
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
                .foregroundStyle(Theme.lightText)
        }
    }

    /// SF Symbol icon + text row — uses the actual app icon with purple/white palette.
    private func instructionRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.primaryText, Theme.purple)
                .frame(width: 28)

            Text(text)
                .font(Theme.font16Regular)
                .foregroundStyle(Theme.lightText)
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
                .foregroundStyle(Theme.lightText)
        }
    }

    /// Step row with an inline SF Symbol icon (no number — icon serves as the leading element).
    private func stepRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.primaryText, Theme.purple)
                .frame(width: 24)

            Text(LocalizedStringKey(text))
                .font(Theme.font16Regular)
                .foregroundStyle(Theme.lightText)
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
                .foregroundStyle(Theme.primaryText)
        }
    }
}
