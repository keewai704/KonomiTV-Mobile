import Foundation

/// Maps libVLC's timeline of a live HLS stream onto the wall clock (and the
/// PTS clock) the stream was produced on.
///
/// libVLC numbers its own timeline from zero for every input it opens, so a
/// playback position cannot be compared across a reload, and a caption's PTS
/// says nothing about where the player currently is. The loopback server does
/// know what it served: the first segment libVLC asks for after a load is the
/// segment the player starts at, so its `#EXT-X-PROGRAM-DATE-TIME` and its
/// first video PTS are one anchor point:
///
///     playbackTime 0  ↔  segment date  ↔  segment first PTS
///
/// Everything else is derived from that single anchor: a wall clock for the
/// Now Playing info and the comment timeline, and a PTS → playback position
/// mapping for the caption renderer. `PlaybackController` builds one of these
/// from what `LocalHLSServer` actually served and replaces it after every
/// reload or live-edge seek, which keeps the values pure and testable.
public struct LivePlaybackClock: Sendable, Hashable {
    /// One fixed point of the mapping.
    public struct Anchor: Sendable, Hashable {
        /// Playback position in seconds on libVLC's timeline.
        public let playbackTime: Double
        /// Wall-clock date of that position (the segment's
        /// `#EXT-X-PROGRAM-DATE-TIME`).
        public let date: Date
        /// Raw 33-bit PTS (90 kHz) of the first video frame at that position.
        public let pts: Int64

        public init(playbackTime: Double, date: Date, pts: Int64) {
            self.playbackTime = playbackTime
            self.date = date
            self.pts = pts
        }
    }

    public let anchor: Anchor

    public init(anchor: Anchor) {
        self.anchor = anchor
    }

    /// Convenience initializer for the usual "segment start" anchor.
    public init(playbackTime: Double = 0, date: Date, pts: Int64) {
        self.init(anchor: Anchor(playbackTime: playbackTime, date: date, pts: pts))
    }

    /// Playback position of a wall-clock date.
    public func playbackTime(forDate date: Date) -> Double {
        anchor.playbackTime + date.timeIntervalSince(anchor.date)
    }

    /// Wall-clock date of a playback position.
    public func date(forPlaybackTime playbackTime: Double) -> Date {
        anchor.date.addingTimeInterval(playbackTime - anchor.playbackTime)
    }

    /// Playback position of a PTS, handling the 33-bit wrap-around.
    public func playbackTime(forPTS pts: Int64) -> Double {
        let ticks = HLSMediaPlaylist.signedTicks(from: anchor.pts, to: pts)
        return anchor.playbackTime + Double(ticks) / PTS.clockRate
    }

    /// PTS of a playback position.
    public func pts(forPlaybackTime playbackTime: Double) -> Int64 {
        anchor.pts + Int64(((playbackTime - anchor.playbackTime) * PTS.clockRate).rounded())
    }

    /// Seconds since `origin` of a playback position. Used for caption
    /// timelines that are stamped relative to the stream's first segment.
    public func secondsSince(_ origin: Date, forPlaybackTime playbackTime: Double) -> Double {
        date(forPlaybackTime: playbackTime).timeIntervalSince(origin)
    }
}
