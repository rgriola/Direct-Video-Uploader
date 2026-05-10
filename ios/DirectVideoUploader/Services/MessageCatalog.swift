// May 10, 2026 - 10:15am - GitHub Copilot (GPT-5.3-Codex)
import Foundation

/// Centralized chat copy catalog.
///
/// Server sends message codes + params, while iOS resolves final display text.
/// This keeps rendering style and copy behavior in one iOS-owned code path.
enum MessageCatalog {
     static let schemaVersion = 1

     private static let templates: [String: String] = [
          // Server-driven codes
          "WS_GREETING_CONNECTED": "Hey {firstName}. I am ready for your video.",
          "WS_SYSTEM_TIP_GUIDE": "The guide dog in the top right opens how Fixer works.",
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
               "{firstName}, your video is confirmed. Go ahead and Slack this.",
          "IOS_UPLOAD_CANCELLED": "Upload cancelled.",
     ]

     static func resolve(content: MessageContent) -> String {
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

     private static func render(template: String, params: [String: String]) -> String {
          var result = template
          for (key, value) in params {
               result = result.replacingOccurrences(of: "{\(key)}", with: value)
          }
          return result
     }
}
