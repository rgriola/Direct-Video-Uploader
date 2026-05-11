// May 10, 2026 - 3:34pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

struct OnboardingStepDefinition: Identifiable {
     let id: String
     let title: String
     let summary: String
     let icon: String
     let bullets: [String]
}

/// Centralized onboarding copy/state for first-run walkthrough.
enum OnboardingCatalog {
     static let completionKey = "hasCompletedOnboarding"
     static let legacyInstructionsKey = "hasSeenInstructions"

     static let steps: [OnboardingStepDefinition] = [
          OnboardingStepDefinition(
               id: "pick-upload",
               title: "Pick and Upload",
               summary: "Tap plus, choose one video, then send it.",
               icon: "video.badge.plus",
               bullets: [
                    "Fixer shows video-only selection.",
                    "You can trim before sending.",
                    "Keep Fixer open until upload reaches 100%.",
               ]
          ),
          OnboardingStepDefinition(
               id: "add-details",
               title: "Add Details",
               summary: "Complete the metadata form when it appears.",
               icon: "square.and.pencil",
               bullets: [
                    "Slug and Description are required.",
                    "Fixer preserves capture metadata automatically.",
                    "If interrupted, you can finish details from Archive.",
               ]
          ),
          OnboardingStepDefinition(
               id: "share-archive",
               title: "Share and Archive",
               summary: "Wait for Video Ready, then Slack and archive.",
               icon: "archivebox.fill",
               bullets: [
                    "Ready summary confirms Mediasource processing.",
                    "Use #channel or @name in chat to send Slack updates.",
                    "Archive keeps clip metadata, link, and follow-up actions.",
               ]
          ),
     ]

     static var isCompleted: Bool {
          UserDefaults.standard.bool(forKey: completionKey)
     }

     static func markCompleted() {
          UserDefaults.standard.set(true, forKey: completionKey)
          UserDefaults.standard.set(true, forKey: legacyInstructionsKey)
     }

     static func resetForQA() {
          UserDefaults.standard.set(false, forKey: completionKey)
          UserDefaults.standard.set(false, forKey: legacyInstructionsKey)
     }
}
