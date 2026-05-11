// May 10, 2026 - 4:06pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation
import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
     case system
     case light
     case dark

     var id: String { rawValue }

     var label: String {
          switch self {
          case .system:
               return "System"
          case .light:
               return "Light"
          case .dark:
               return "Dark"
          }
     }

     var preferredColorScheme: ColorScheme? {
          switch self {
          case .system:
               return nil
          case .light:
               return .light
          case .dark:
               return .dark
          }
     }
}

@MainActor
@Observable
final class AppearanceService {
     var mode: AppearanceMode {
          didSet {
               UserDefaults.standard.set(mode.rawValue, forKey: UserDefaultsKeys.appearanceMode)
          }
     }

     init() {
          let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.appearanceMode)
          if let stored, let parsed = AppearanceMode(rawValue: stored) {
               mode = parsed
          } else {
               mode = .dark
               UserDefaults.standard.set(mode.rawValue, forKey: UserDefaultsKeys.appearanceMode)
          }
     }

     var preferredColorScheme: ColorScheme? {
          mode.preferredColorScheme
     }
}
