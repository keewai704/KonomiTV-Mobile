import Foundation

/// Centralised JSON coding for KonomiTV API payloads.
///
/// KonomiTV returns ISO 8601 timestamps with a timezone offset, sometimes
/// with fractional seconds and sometimes without. A single shared decoder is
/// deliberately not used here: `JSONDecoder` and the date formatters are not
/// `Sendable`, so each call creates its own instance.
public enum JSONCoding {

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                if let date = parseISO8601(string) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO 8601 date: \(string)"
                )
            }
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 date string or a Unix timestamp"
            )
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatISO8601(date))
        }
        return encoder
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "String is not valid UTF-8")
            )
        }
        return try decode(type, from: data)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    // MARK: - Date helpers

    public static func parseISO8601(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = isoFormatter(fractionalSeconds: true).date(from: trimmed) {
            return date
        }
        if let date = isoFormatter(fractionalSeconds: false).date(from: trimmed) {
            return date
        }

        // Fallback for unusual fractional-second lengths (e.g. six digits).
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    public static func formatISO8601(_ date: Date) -> String {
        isoFormatter(fractionalSeconds: true).string(from: date)
    }

    /// Formats a date for an ISO 8601 query parameter (e.g.
    /// `2026-11-03T12:00:00Z`), the format the KonomiTV API accepts for
    /// `start_time` / `end_time`.
    ///
    /// UTC is used unless a time zone is given explicitly: the web client sends
    /// the browser's local offset, but both are the same instant.
    public static func formatQueryDateTime(_ date: Date, timeZone: TimeZone? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let timeZone {
            formatter.timeZone = timeZone
        }
        return formatter.string(from: date)
    }

    private static func isoFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}
