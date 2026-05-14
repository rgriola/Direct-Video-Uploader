// May 11, 2026 - 6:23pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

/// Centralized chat copy catalog.
///
/// Server sends message codes + params, while iOS resolves final display text.
/// This keeps rendering style and copy behavior in one iOS-owned code path.
enum MessageCatalog {
     static let schemaVersion = 1

     private static let greetingTemplates: [String] = [
          "{time} {firstName}. I am ready for your video.",
          "{time} {firstName}. Let's get your footage uploaded.",
          "{time} {firstName}! Drop a video and I'll handle the rest.",
          "{time} {firstName}. I am speeding, rack and roll.",
          "{time} {firstName}, time to make great TV!",
          "{time} {firstName}, upload away, I've got you covered.",
          "{time} {firstName}. Videos don't upload themselves.",
          "{time} {firstName}. Standing by for your next masterpiece.",
          "{time} {firstName}. Signal is 5 x 5, send it over.",
          "{time} {firstName}, to grow your audience just add content.",
     ]

     private static let morningTimePhrases = [
          "Good morning", "Rise and shine", "Top of the morning", "Morning", "Suuup.",
     ]
     private static let afternoonTimePhrases = [
          "Good afternoon", "Hey there", "Afternoon", "Hello",
     ]
     private static let eveningTimePhrases = [
          "Good evening", "Evening", "Hey night owl", "Burning the midnight oil",
     ]

     private static let tipTemplates: [String] = [
          "Tap the plus button and choose your video.",
          "Once uploaded, type @name or #channel to Slack your video.",
          "I'll archive your video when it's finished.",
          "You can start a new upload as soon as the current one finishes.",
          "Use the transcribe toggle to create a transcript.",
          "Keep Fixer open until the progress bar is 100%.",
          "I'll send your metadata once I read the video file.",
          "Don't skip the slug form, Fixer can fix just so much.",
          "Permissions are in your profile. So is logout, but I don't want you to go.",
          "The guide dog in the top right opens how Fixer works.",
     ]

     private static let streamReadyFollowupTemplates: [String] = [
          "{firstName}, you are working hard today. Send another when ready.",
          "{firstName}, nice clip. Send another whenever you're ready.",
          "{firstName}, it's in the can. I'd love to see more dailies.",
          "{firstName}, take five - or send five more videos. I don't judge.",
          "{firstName}, you're on fire. Firetrucks are on standby.",
          "{firstName}, your cloud butler just filed your clip.",
          "{firstName}, that was golden. Where is the podium?",
          "{firstName}, go grab coffee. We have the file.",
          "{firstName}, we are a good team. Ready when you are.",
          "{firstName}, you're a rock star. Send another video when ready.",
     ]

     private static let batchClosingTemplates: [String] = [
          "{firstName}, batch wrapped. Use #channel or @person here to Slack your clip details, then send the next upload when you're ready.",
          "{firstName}, your batch is logged. Drop a #channel or @person message to Slack this update from chat.",
          "{firstName}, great run. You can Slack metadata right here with # or @, and then roll the next upload.",
          "{firstName}, queue complete. Need to notify the team? Type #channel or @person and I'll post the metadata.",
          "{firstName}, mission complete. Slack your update from this box with #channel or @person, and let's keep moving.",
     ]

     private static let templates: [String: String] = [
          // Server-driven codes
          "WS_SLACK_NOT_CONFIGURED": "Slack is not configured. Set SLACK_BOT_TOKEN on the server.",
          "WS_SLACK_REQUIRES_UPLOAD":
               "You can Slack your team after your first video of the day. Check the archive for previous uploads.",
          "WS_TEXT_AUTO_REPLY_SEND_VIDEO":
               "Hey {userName}, I cannot text just yet. Send me your videos. Tap the plus button to pick a video from your camera roll.",
          "WS_FORM_CONFIRMED":
               "High five. I will text when the video is done. Metadata is ready, and you can Slack your team below.",
          "WS_SLACK_CONFIRMATION_OK": "{targets}",
          "WS_SLACK_CONFIRMATION_FAILED": "Could not post to {failedTargets}.",
          "WS_SLACK_CONFIRMATION_PARTIAL": "Posted to {okTargets}. Failed: {failedTargets}.",

          // iOS-local codes
          "IOS_SLACK_REQUIRES_UPLOAD":
               "Upload a video first and I can grab the metadata so you can Slack it. Previous uploads are in your Archive, and you can Slack from there.",
          "IOS_UPLOAD_START_FAILED": "Could not start upload. Please try again.",
          "IOS_UPLOAD_FAILED": "Upload failed: {reason}",
          "IOS_TRANSCRIBE_START": "Transcribing audio...",
          "IOS_TRANSCRIBE_SUCCESS":
               "Transcript sent to Mediasource. ({wordCount} words.) Transcript is available in Archive.",
          "IOS_TRANSCRIBE_NO_SPEECH": "No clear audio detected in video.",
          "IOS_TRANSCRIBE_FAILED": "Transcription failed: {reason}",
          "IOS_TRANSCRIBE_EMPTY": "Transcription did not produce results.",
          "IOS_FORM_SKIPPED":
               "No worries. Your video is still uploading. You can add details from your Archive anytime.",
          "IOS_FORM_SUBMIT_FAILED": "Form submission failed. The form is still open. Please retry.",
          "IOS_ASSET_DETAILS_LOAD_FAILED": "Could not load video details.",
          "IOS_GREETING_NEW_CONVERSATION": "Hey {firstName}. Upload away.",
          "IOS_MUX_READY_SUMMARY": "Mediasource confirmed.",
          "IOS_MUX_READY_FOLLOWUP":
               "You're a rock star. Send another video when ready.",
          "IOS_BATCH_HIGH_FIVE": "High five. Batch upload complete.",
          "IOS_UPLOAD_CANCELLED": "Upload cancelled.",
          "IOS_CONNECTIVITY_BLOCKING":
               "Connection interrupted while {operation}. Upload and metadata sync are paused until reconnection.",
          "IOS_CONNECTIVITY_RECOVERED":
               "Connection restored. Upload and metadata sync resumed.",
     ]

     static func resolve(content: MessageContent, stableSeed: String? = nil) -> String {
          if let code = content.code,
               code == "WS_GREETING_CONNECTED"
          {
               return resolveGreeting(
                    params: content.params ?? [:], fallbackText: content.fallbackText,
                    stableSeed: stableSeed)
          }

          if let code = content.code,
               code == "WS_SYSTEM_TIP_GUIDE"
          {
               return resolveTip(fallbackText: content.fallbackText, stableSeed: stableSeed)
          }

          if let code = content.code,
               code == "IOS_MUX_READY_FOLLOWUP"
          {
               return resolveStreamReadyFollowup(
                    params: content.params ?? [:],
                    fallbackText: content.fallbackText,
                    stableSeed: stableSeed)
          }

          if let code = content.code,
               code == "IOS_BATCH_CLOSING"
          {
               return resolveBatchClosing(
                    params: content.params ?? [:],
                    fallbackText: content.fallbackText,
                    stableSeed: stableSeed)
          }

          if let code = content.code,
               let rendered = resolve(code: code, params: content.params ?? [:])
          {
               return rendered
          }

          if let fallbackText = content.fallbackText, !fallbackText.isEmpty {
               return fallbackText
          }

          if let text = content.text, !text.isEmpty {
               return text
          }

          if let fileName = content.fileName, !fileName.isEmpty {
               return fileName
          }

          return "..."
     }

     static func resolve(code: String, params: [String: String]) -> String? {
          guard let template = templates[code] else { return nil }
          return render(template: template, params: params)
     }

     private static func resolveGreeting(
          params: [String: String],
          fallbackText: String?,
          stableSeed: String?
     ) -> String {
          let firstName = normalizedFirstName(params["firstName"])

          // Seed from stable payload data so greeting text won't flicker on re-render.
          let seedBase = [
               "WS_GREETING_CONNECTED",
               stableSeed ?? "",
               firstName,
               fallbackText ?? "",
          ].joined(separator: "|")

          let template = greetingTemplates[
               stableIndex(seed: seedBase + "|template", count: greetingTemplates.count)
          ]

          let hour = Calendar.current.component(.hour, from: Date())
          let timeOptions: [String]
          if hour < 12 {
               timeOptions = morningTimePhrases
          } else if hour < 19 {
               timeOptions = afternoonTimePhrases
          } else {
               timeOptions = eveningTimePhrases
          }

          let timePhrase = timeOptions[
               stableIndex(seed: seedBase + "|time", count: timeOptions.count)
          ]

          return render(
               template: template,
               params: [
                    "time": timePhrase,
                    "firstName": firstName,
               ])
     }

     private static func resolveTip(fallbackText: String?, stableSeed: String?) -> String {
          let seedBase = [
               "WS_SYSTEM_TIP_GUIDE",
               stableSeed ?? "",
               fallbackText ?? "",
          ].joined(separator: "|")

          return tipTemplates[
               stableIndex(seed: seedBase + "|tip", count: tipTemplates.count)
          ]
     }

     private static func resolveStreamReadyFollowup(
          params: [String: String],
          fallbackText: String?,
          stableSeed: String?
     ) -> String {
          let firstName = normalizedFirstName(params["firstName"])
          let seedBase = [
               "IOS_MUX_READY_FOLLOWUP",
               stableSeed ?? "",
               firstName,
               fallbackText ?? "",
          ].joined(separator: "|")

          let template = streamReadyFollowupTemplates[
               stableIndex(seed: seedBase + "|followup", count: streamReadyFollowupTemplates.count)
          ]

          return render(template: template, params: ["firstName": firstName])
     }

     private static func resolveBatchClosing(
          params: [String: String],
          fallbackText: String?,
          stableSeed: String?
     ) -> String {
          let firstName = normalizedFirstName(params["firstName"])
          let seedBase = [
               "IOS_BATCH_CLOSING",
               stableSeed ?? "",
               firstName,
               fallbackText ?? "",
          ].joined(separator: "|")

          let template = batchClosingTemplates[
               stableIndex(seed: seedBase + "|closing", count: batchClosingTemplates.count)
          ]

          return render(template: template, params: ["firstName": firstName])
     }

     private static func normalizedFirstName(_ raw: String?) -> String {
          let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
          return (trimmed?.isEmpty == false) ? trimmed! : "there"
     }

     private static func stableIndex(seed: String, count: Int) -> Int {
          guard count > 0 else { return 0 }

          // FNV-1a 64-bit hash for deterministic selection across app launches.
          var hash: UInt64 = 0xcbf2_9ce4_8422_2325
          for byte in seed.utf8 {
               hash ^= UInt64(byte)
               hash = hash &* 0x100_0000_01b3
          }
          return Int(hash % UInt64(count))
     }

     private static func render(template: String, params: [String: String]) -> String {
          var result = template
          for (key, value) in params {
               result = result.replacingOccurrences(of: "{\(key)}", with: value)
          }
          return result
     }
}
