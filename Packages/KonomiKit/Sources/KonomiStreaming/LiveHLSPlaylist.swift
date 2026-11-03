import Foundation

/// Fixed reference point that maps raw 90 kHz PTS values onto wall-clock
/// dates, so a live playlist can carry `#EXT-X-PROGRAM-DATE-TIME`.
///
/// The app sets the anchor when the first segment is produced
/// (`anchorDate` = the wall-clock time of that moment, `anchorPTS` =
/// `TSSegment.firstVideoPTS`). The playlist's PROGRAM-DATE-TIME and the caption
/// PTS values share this clock; `LivePlaybackClock` maps the player's own
/// timeline onto it, which is what lets the caption renderer line up with the
/// video.
public struct LiveProgramDateTimeAnchor: Sendable, Hashable {
    public let anchorDate: Date
    public let anchorPTS: Int64

    public init(anchorDate: Date, anchorPTS: Int64) {
        self.anchorDate = anchorDate
        self.anchorPTS = anchorPTS
    }

    /// Wall-clock date of a PTS. Handles the 33-bit PTS wrap-around.
    public func date(forPTS pts: Int64) -> Date {
        anchorDate.addingTimeInterval(seconds(forPTS: pts))
    }

    /// Seconds from the anchor to a PTS. Handles the 33-bit PTS wrap-around.
    public func seconds(forPTS pts: Int64) -> Double {
        Double(HLSMediaPlaylist.signedTicks(from: anchorPTS, to: pts)) / PTS.clockRate
    }

    /// `YYYY-MM-DDThh:mm:ss.SSSZ` in UTC, the form HLS PROGRAM-DATE-TIME uses.
    public static func string(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let milliseconds = max(0, min(999, (components.nanosecond ?? 0) / 1_000_000))
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            milliseconds
        )
    }
}

/// Builds a live HLS media playlist (sliding window, no end list).
public enum TSSegmentMediaPlaylist {

    public static let version = 3

    public static func render(
        segments: [TSSegment],
        windowSize: Int = 6,
        discontinuitySequence: Int? = nil,
        minimumTargetDuration: Int = 1,
        programDateTimeAnchor: LiveProgramDateTimeAnchor? = nil
    ) -> String {
        let sorted = segments.sorted { $0.sequence < $1.sequence }
        let count = min(max(windowSize, 1), sorted.count)
        let window = count > 0 ? Array(sorted.suffix(count)) : []

        let mediaSequence = window.first?.sequence ?? 0
        // A live playlist must not lower its target duration once published.
        let target = max(targetDuration(for: window), minimumTargetDuration)
        let discontinuity: Int
        if let discontinuitySequence {
            discontinuity = max(discontinuitySequence, 0)
        } else if count == 0 {
            discontinuity = 0
        } else {
            discontinuity = sorted
                .prefix(sorted.count - count)
                .filter(\.discontinuity)
                .count
        }

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:\(version)",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)",
            "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuity)",
        ]

        for segment in sorted.suffix(count) {
            if segment.discontinuity {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            if let programDateTimeAnchor, let firstVideoPTS = segment.firstVideoPTS {
                let date = programDateTimeAnchor.date(forPTS: firstVideoPTS)
                lines.append(
                    "#EXT-X-PROGRAM-DATE-TIME:\(LiveProgramDateTimeAnchor.string(from: date))"
                )
            }
            lines.append("#EXTINF:\(format(segment.duration)),")
            lines.append("\(segmentPath(for: segment.sequence))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public static func targetDuration(for segments: [TSSegment]) -> Int {
        let longest = segments.map(\.duration).max() ?? 0
        let rounded = Int((longest - 0.000_001).rounded(.up))
        return max(1, rounded)
    }

    public static func segmentPath(for sequence: Int) -> String {
        "seg/\(sequence).ts"
    }

    private static func format(_ duration: Double) -> String {
        String(format: "%.3f", duration)
    }
}

/// Convenience alias matching the name used by the app layer.
public typealias LiveHLSPlaylist = TSSegmentMediaPlaylist
