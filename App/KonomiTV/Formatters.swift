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

    /// `HH:mm:ss` for comment lists. With `use28HourClock`, hours 0–3 are
    /// shown as 24–27, like the web client's `Utils.apply28HourClock()`.
    static func clock(_ date: Date, use28HourClock: Bool = false) -> String {
        let text = formatter("HH:mm:ss").string(from: date)
        guard use28HourClock else { return text }
        let parts = text.split(separator: ":")
        guard parts.count == 3, let hour = Int(parts[0]), hour >= 0, hour <= 3 else {
            return text
        }
        return "\(hour + 24):\(parts[1]):\(parts[2])"
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

    /// `90` → `01:30`. Used for comment times when the recording start time
    /// is unknown.
    static func offset(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// `1000001000` → `953.67 MB`.
    static func bytes(_ value: Int?) -> String {
        guard let value, value > 0 else { return "不明" }

        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        if index == 0 {
            return "\(Int(amount)) \(units[index])"
        }
        return String(format: "%.2f %@", amount, units[index])
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
