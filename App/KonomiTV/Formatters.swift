import Foundation

/// Japanese date, time and duration formatting.
///
/// Formatters are created per call so that no non-`Sendable` state is shared
/// between tasks (Swift 6 strict concurrency).
enum Formatters {
    static func dateTime(_ date: Date) -> String {
        formatter("M/d(E) HH:mm").string(from: date)
    }

    static func date(_ date: Date) -> String {
        formatter("M/d(E)").string(from: date)
    }

    static func time(_ date: Date) -> String {
        formatter("HH:mm").string(from: date)
    }

    static func timeRange(start: Date, end: Date) -> String {
        "\(time(start))〜\(time(end))"
    }

    /// `5400` → `1時間30分`, `150` → `2分`, `30` → `30秒`.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total > 0 else { return "0分" }

        let hours = total / 3600
        let minutes = (total % 3600) / 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)時間\(minutes)分" : "\(hours)時間"
        }
        if minutes > 0 {
            return "\(minutes)分"
        }
        return "\(total)秒"
    }

    /// `0.42` → `42%`.
    static func percent(_ progress: Double) -> String {
        let clamped = min(max(progress, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}
