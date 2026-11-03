import Foundation

/// Builds a live HLS media playlist (sliding window, no end list).
public enum TSSegmentMediaPlaylist {

    public static let version = 3

    public static func render(
        segments: [TSSegment],
        windowSize: Int = 6,
        discontinuitySequence: Int? = nil,
        minimumTargetDuration: Int = 1
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
