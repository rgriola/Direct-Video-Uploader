// May 14, 2026 - 4:00pm - GitHub Copilot (Claude Opus 4.7)
//
// AppLog — single namespace exposing categorized `os.Logger` instances.
// Replaces ad-hoc `print(...)` statements across the iOS app so output is
// filterable / redactable / off in production builds.
//
// Usage:
//   AppLog.upload.info("Starting upload \(assetId)")
//   AppLog.ws.error("Socket disconnected: \(error.localizedDescription)")
//
// Levels mapping from old emoji conventions:
//   ⚠️ → .warning
//   ❌ → .error
//   ✅ / 📡 / 🔌 / 📦 → .info or .debug

import Foundation
import os

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.fixer.app"

    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let chat = Logger(subsystem: subsystem, category: "chat")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let upload = Logger(subsystem: subsystem, category: "upload")
    static let workflow = Logger(subsystem: subsystem, category: "workflow")
    static let ws = Logger(subsystem: subsystem, category: "ws")
}
