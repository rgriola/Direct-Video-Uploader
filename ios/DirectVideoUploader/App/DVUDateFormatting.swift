import Foundation

/// Shared date formatters — avoids creating new instances on every call.
enum DVUDateFormatting {
    // MARK: - Cached Formatters

    nonisolated(unsafe) private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoBasic = ISO8601DateFormatter()

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy h:mm a"
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    // MARK: - ISO → Date

    /// Parse an ISO 8601 string (with or without fractional seconds).
    static func parseISO(_ string: String) -> Date? {
        isoFull.date(from: string) ?? isoBasic.date(from: string)
    }

    /// Format a `Date` as an ISO 8601 string (no fractional seconds).
    static func isoString(from date: Date) -> String {
        isoBasic.string(from: date)
    }

    // MARK: - Display Formats

    /// "Mar 5, 2026 3:42 PM" — from an ISO 8601 string
    static func longDate(_ isoString: String) -> String {
        guard let date = parseISO(isoString) else { return isoString }
        return longFormatter.string(from: date)
    }

    /// "Mar 5, 2026 3:42 PM" — from a Date directly
    static func longDate(from date: Date) -> String {
        longFormatter.string(from: date)
    }

    /// "03/05/26"
    static func shortDate(_ isoString: String) -> String {
        guard let date = parseISO(isoString) else { return isoString }
        return shortFormatter.string(from: date)
    }

    /// "3:42 PM"
    static func timeOnly(_ isoString: String) -> String? {
        guard let date = parseISO(isoString) else { return nil }
        return timeFormatter.string(from: date)
    }

    // MARK: - Duration / File Size

    /// 125 → "2:05"
    static func duration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Bytes string → "12.3 MB"
    static func fileSize(_ sizeStr: String) -> String {
        guard let bytes = Double(sizeStr) else { return sizeStr }
        if bytes > 1_000_000_000 {
            return String(format: "%.1f GB", bytes / 1_000_000_000)
        } else if bytes > 1_000_000 {
            return String(format: "%.1f MB", bytes / 1_000_000)
        } else if bytes > 1_000 {
            return String(format: "%.0f KB", bytes / 1_000)
        }
        return "\(Int(bytes)) B"
    }
}
