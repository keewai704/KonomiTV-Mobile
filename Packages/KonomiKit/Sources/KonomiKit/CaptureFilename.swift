import Foundation

/// Values available to the capture filename pattern.
///
/// The web client (CaptureManager.generateCaptureFilename) expands the pattern
/// with the current time, the channel and the program on air / being played.
/// The app fills this from the live channel or the recorded program.
public struct CaptureFilenameContext: Sendable, Hashable {
    /// Capture time. Formatted in JST, like the web client.
    public var capturedAt: Date
    public var channelName: String
    public var serviceID: Int
    public var remoconID: Int
    public var eventID: Int
    public var eventTitle: String
    public var eventStartTime: Date
    /// nil when the program end is unknown (放送時間未定).
    public var eventEndTime: Date?
    /// Used for %event-duration-*%. When nil the difference between the start
    /// and end times is used (the web client always derives it that way).
    public var eventDuration: TimeInterval?

    public init(
        capturedAt: Date,
        channelName: String,
        serviceID: Int,
        remoconID: Int,
        eventID: Int,
        eventTitle: String,
        eventStartTime: Date,
        eventEndTime: Date? = nil,
        eventDuration: Double? = nil
    ) {
        self.capturedAt = capturedAt
        self.channelName = channelName
        self.serviceID = serviceID
        self.remoconID = remoconID
        self.eventID = eventID
        self.eventTitle = eventTitle
        self.eventStartTime = eventStartTime
        self.eventEndTime = eventEndTime
        self.eventDuration = eventDuration
    }
}

/// Expands the web client's capture_filename_pattern placeholders.
///
/// Implemented macros are the subset of TVTest's filename macros that the web
/// client supports (see CaptureManager.ts); unknown macros are left untouched.
/// Times are always formatted in JST, matching the web client's fixed JST
/// day.js instance.
///
/// The web client does not sanitise the expanded name; the server replaces
/// Windows-invalid characters with "_" when saving. The iOS app also builds a
/// local filename (Browser save mode / share sheet), so this implementation
/// sanitises the result the same way and additionally replaces path separators
/// and ":" so the name can never escape the save directory.
public enum CaptureFilename {

    /// The web client's default pattern (SettingsStore.ts).
    public static let defaultPattern = "Capture_%date%-%time%"

    public static let jst = TimeZone(secondsFromGMT: 9 * 60 * 60) ?? TimeZone(identifier: "Asia/Tokyo")!

    public static func make(pattern: String, context: CaptureFilenameContext) -> String {
        let resolved = expand(pattern: pattern, context: context)
        return sanitize(resolved)
    }

    /// Expands placeholders without sanitising (exposed for tests).
    public static func expand(pattern: String, context: CaptureFilenameContext) -> String {
        let replacements = replacementTable(context: context)
        // Longest first, so %start-time% wins over %time% and %start-month2%
        // over %start-month%. The single left-to-right pass means replacement
        // text is never expanded again, matching the web client's one regex
        // replacement.
        let macros = replacements.keys.sorted { $0.count > $1.count }
        var result = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            var matched: String?
            for macro in macros where pattern[index...].hasPrefix(macro) {
                matched = macro
                break
            }
            if let macro = matched, let value = replacements[macro] {
                result += value
                index = pattern.index(index, offsetBy: macro.count)
            } else {
                result.append(pattern[index])
                index = pattern.index(after: index)
            }
        }
        return result
    }

    /// Replaces characters that cannot be used in file names (and path
    /// separators) with "_". An empty result falls back to "Capture".
    public static func sanitize(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", "\\", ":", "*", "?", "\"", "<", ">", "|":
                result.append("_")
            case "\u{0000}"..."\u{001F}":
                result.append("_")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") {
            result.removeLast()
        }
        return result.isEmpty ? "Capture" : result
    }

    // MARK: - Placeholders

    private static func replacementTable(context: CaptureFilenameContext) -> [String: String] {
        let now = Components(date: context.capturedAt)
        let start = Components(date: context.eventStartTime)
        let end = Components(date: context.eventEndTime ?? context.eventStartTime)
        let duration = context.eventDuration
            ?? (context.eventEndTime?.timeIntervalSince(context.eventStartTime) ?? 0)
        let totalSeconds = max(Int(duration.rounded(.towardZero)), 0)
        // dayjs.duration().hours()/minutes()/seconds() are the components after
        // whole days, so a 25 hour program reports 1 hour.
        let hours = (totalSeconds / 3600) % 24
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        let serviceName = context.channelName
        return [
            // 現在日時
            "%date%": now.string("yyyyMMdd"),
            "%year%": now.string("yyyy"),
            "%year2%": now.string("yy"),
            "%month%": String(now.month),
            "%month2%": now.string("MM"),
            "%day%": String(now.day),
            "%day2%": now.string("dd"),
            "%time%": now.string("HHmmss"),
            "%hour%": String(now.hour),
            "%hour2%": now.string("HH"),
            "%minute%": String(now.minute),
            "%minute2%": now.string("mm"),
            "%second%": String(now.second),
            "%second2%": now.string("ss"),
            "%day-of-week%": now.japaneseWeekday,
            // 番組開始日時
            "%start-date%": start.string("yyyyMMdd"),
            "%start-year%": start.string("yyyy"),
            "%start-year2%": start.string("yy"),
            "%start-month%": String(start.month),
            "%start-month2%": start.string("MM"),
            "%start-day%": String(start.day),
            "%start-day2%": start.string("dd"),
            "%start-time%": start.string("HHmmss"),
            "%start-hour%": String(start.hour),
            "%start-hour2%": start.string("HH"),
            "%start-minute%": String(start.minute),
            "%start-minute2%": start.string("mm"),
            "%start-second%": String(start.second),
            "%start-second2%": start.string("ss"),
            "%start-day-of-week%": start.japaneseWeekday,
            // 番組終了日時
            "%end-date%": end.string("yyyyMMdd"),
            "%end-year%": end.string("yyyy"),
            "%end-year2%": end.string("yy"),
            "%end-month%": String(end.month),
            "%end-month2%": end.string("MM"),
            "%end-day%": String(end.day),
            "%end-day2%": end.string("dd"),
            "%end-time%": end.string("HHmmss"),
            "%end-hour%": String(end.hour),
            "%end-hour2%": end.string("HH"),
            "%end-minute%": String(end.minute),
            "%end-minute2%": end.string("mm"),
            "%end-second%": String(end.second),
            "%end-second2%": end.string("ss"),
            "%end-day-of-week%": end.japaneseWeekday,
            // 番組長
            "%event-duration-hour%": String(hours),
            "%event-duration-hour2%": String(format: "%02d", hours),
            "%event-duration-min%": String(minutes),
            "%event-duration-min2%": String(format: "%02d", minutes),
            "%event-duration-sec%": String(seconds),
            "%event-duration-sec2%": String(format: "%02d", seconds),
            // チャンネル名
            "%channel-name%": context.channelName,
            // リモコン番号
            "%channel-no%": String(context.remoconID),
            "%channel-no2%": String(format: "%02d", context.remoconID),
            "%channel-no3%": String(format: "%03d", context.remoconID),
            // 番組名
            "%event-name%": context.eventTitle,
            // イベント ID
            "%event-id%": String(context.eventID),
            // サービス名
            "%service-name%": serviceName,
            // サービス ID
            "%service-id%": String(context.serviceID),
        ]
    }

    /// JST calendar components of a date.
    private struct Components {
        var year = 1970
        var month = 1
        var day = 1
        var hour = 0
        var minute = 0
        var second = 0
        var weekday = 1

        init(date: Date) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = CaptureFilename.jst
            let parts = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .weekday],
                from: date
            )
            year = parts.year ?? 1970
            month = parts.month ?? 1
            day = parts.day ?? 1
            hour = parts.hour ?? 0
            minute = parts.minute ?? 0
            second = parts.second ?? 0
            weekday = parts.weekday ?? 1
        }

        var japaneseWeekday: String {
            let names = ["日", "月", "火", "水", "木", "金", "土"]
            return names[(weekday - 1 + 7) % 7]
        }

        func string(_ format: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = CaptureFilename.jst
            formatter.dateFormat = format
            // Build the date from the JST components so the formatter does not
            // shift the value again.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = CaptureFilename.jst
            let date = calendar.date(
                from: DateComponents(
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute,
                    second: second
                )
            ) ?? Date(timeIntervalSince1970: 0)
            return formatter.string(from: date)
        }
    }
}
