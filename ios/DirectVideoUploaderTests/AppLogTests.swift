// May 14, 2026 - 9:55am - GitHub Copilot (Claude Opus 4.7)
import XCTest

@testable import DirectVideoUploader

final class AppLogTests: XCTestCase {
    func test_allCategoriesExist() {
        // Smoke test: verify every AppLog category is reachable so a typo
        // in the enum surface fails the test target instead of leaking to runtime.
        _ = AppLog.auth
        _ = AppLog.chat
        _ = AppLog.network
        _ = AppLog.persistence
        _ = AppLog.transcription
        _ = AppLog.ui
        _ = AppLog.upload
        _ = AppLog.workflow
        _ = AppLog.ws
    }
}
