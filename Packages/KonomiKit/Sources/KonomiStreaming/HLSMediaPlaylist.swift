import Foundation

/// One media segment of an HLS media playlist.
public struct HLSMediaSegment: Sendable, Hashable {
    /// `#EXT-X-MEDIA-SEQUENCE` + index.
    public let sequence: Int
    public let duration: Double
    /// Segment URI resolved against the playlist URL.
    public let url: URL
    /// True when `#EXT-X-DISCONTINUITY` precedes this segment.
    public let discontinuity: Bool

    public init(sequence: Int, duration: Double, url: URL, discontinuity: Bool) {
        self.sequence = sequence
        self.duration = duration
        self.url = url
        self.discontinuity = discontinuity
    }
}

/// A parsed HLS media playlist.
///
/// Only the tags needed to map caption PTS values onto the playback timeline
/// are interpreted: `#EXTINF`, `#EXT-X-DISCONTINUITY`,
/// `#EXT-X-MEDIA-SEQUENCE`, `#EXT-X-TARGETDURATION` and
/// `#EXT-X-ENDLIST`. Other tags are ignored.
public struct HLSMediaPlaylist: Sendable, Hashable {
    public let targetDuration: Int?
    public let mediaSequence: Int
    public let discontinuitySequence: Int
    public let isEndList: Bool
    public let segments: [HLSMediaSegment]
    /// URL the playlist was loaded from, used to resolve relative segment URIs.
    public let url: URL

    public init?(text: String, url: URL) {
        var targetDuration: Int?
        var mediaSequence = 0
        var discontinuitySequence = 0
        var isEndList = false
        var segments: [HLSMediaSegment] = []
        var pendingDuration: Double?
        var pendingDiscontinuity = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:") {
                    let value = line.dropFirst("#EXTINF:".count)
                    let durationText = value.split(separator: ",", maxSplits: 1).first ?? ""
                    pendingDuration = Double(durationText)
                } else if line == "#EXT-X-DISCONTINUITY" {
                    pendingDiscontinuity = true
                } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                    mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
                    discontinuitySequence = Int(line.dropFirst("#EXT-X-DISCONTINUITY-SEQUENCE:".count)) ?? 0
                } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                    targetDuration = Int(line.dropFirst("#EXT-X-TARGETDURATION:".count))
                } else if line == "#EXT-X-ENDLIST" {
                    isEndList = true
                }
                continue
            }

            guard let duration = pendingDuration,
                  let segmentURL = URL(string: line, relativeTo: url)?.absoluteURL
            else { continue }
            segments.append(HLSMediaSegment(
                sequence: mediaSequence + segments.count,
                duration: duration,
                url: segmentURL,
                discontinuity: pendingDiscontinuity
            ))
            pendingDuration = nil
            pendingDiscontinuity = false
        }

        guard !segments.isEmpty else { return nil }
        self.targetDuration = targetDuration
        self.mediaSequence = mediaSequence
        self.discontinuitySequence = discontinuitySequence
        self.isEndList = isEndList
        self.segments = segments
        self.url = url
    }

    /// Playback time of a PTS inside a segment.
    ///
    /// - Parameters:
    ///   - segmentIndex: Index into `segments`.
    ///   - pts: Raw 33-bit PTS (90 kHz) of the caption.
    ///   - firstPTS: Raw 33-bit PTS (90 kHz) of the first video frame in the
    ///     same segment (see `TSSegment.firstVideoPTS`).
    /// - Returns: Sum of the previous `#EXTINF` durations plus the offset of
    ///   `pts` from `firstPTS`, in seconds. The 33-bit PTS wrap-around is
    ///   handled.
    public func playbackTime(
        segmentIndex: Int,
        pts: Int64,
        firstPTS: Int64
    ) -> Double? {
        guard segments.indices.contains(segmentIndex) else { return nil }
        let previousDuration = segments[0..<segmentIndex].reduce(0.0) { $0 + $1.duration }
        let delta = Self.signedTicks(from: firstPTS, to: pts)
        return previousDuration + Double(delta) / PTS.clockRate
    }

    /// Signed difference between two 33-bit PTS values, in 90 kHz ticks.
    public static func signedTicks(from first: Int64, to value: Int64) -> Int64 {
        var delta = (value - first) % PTS.modulus
        if delta < 0 {
            delta += PTS.modulus
        }
        if delta >= PTS.modulus / 2 {
            delta -= PTS.modulus
        }
        return delta
    }
}
