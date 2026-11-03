import Foundation
import KonomiStreaming
import QuartzCore

/// One clock for everything that has to follow the picture: the caption
/// renderer, the danmaku timing, the watch history, the transport controls and
/// the Now Playing info.
///
/// libVLC reports the position through `mediaPlayerTimeChanged` (every 250 ms
/// here) and the length through `mediaPlayerLengthChanged`. Between two
/// callbacks the position is interpolated with `CACurrentMediaTime()`, so
/// captions and comments glide instead of stepping once per callback.
///
/// Live playback needs more than a position: a caption PES carries a PTS and
/// the Now Playing info wants a wall clock. `liveMapping` holds the
/// `LivePlaybackClock` built from the first segment the loopback server served
/// after the current load (see `PlaybackController`), which is replaced after
/// every reload and live-edge seek.
@MainActor
final class PlaybackClock {
    /// Last position libVLC reported, in seconds.
    private(set) var position: Double = 0
    /// Media length in seconds; 0 while unknown and for live streams.
    private(set) var length: Double = 0
    /// libVLC is playing (not paused, not buffering).
    private(set) var isPlaying = false
    /// The current media can seek (recorded and saved videos, not live).
    private(set) var isSeekable = false
    /// Live only: libVLC time ↔ wall clock / PTS.
    private(set) var liveMapping: LivePlaybackClock?

    private var pendingSeek: Double?
    private var lastCallbackHostTime: CFTimeInterval = CACurrentMediaTime()

    // MARK: - Reading

    /// Position to use right now, interpolated between VLC callbacks.
    var currentTime: Double {
        guard isPlaying, pendingSeek == nil else { return clamped(position) }
        let elapsed = CACurrentMediaTime() - lastCallbackHostTime
        return clamped(position + min(max(elapsed, 0), 1))
    }

    /// Position without interpolation, for logging and the UI test label.
    var settledTime: Double { clamped(position) }

    /// Wall clock of a playback position (live only).
    func date(forPlaybackTime playbackTime: Double) -> Date? {
        liveMapping?.date(forPlaybackTime: playbackTime)
    }

    /// Playback position of a caption PTS (live only).
    func playbackTime(forPTS pts: Int64) -> Double? {
        liveMapping?.playbackTime(forPTS: pts)
    }

    // MARK: - Writing

    /// Starts a new media. `startAt` is where playback resumes (0 for live).
    func begin(startAt: Double, isSeekable: Bool, length: Double = 0) {
        position = max(startAt, 0)
        pendingSeek = startAt > 0 ? startAt : nil
        self.length = max(length, 0)
        self.isSeekable = isSeekable
        isPlaying = false
        liveMapping = nil
        lastCallbackHostTime = CACurrentMediaTime()
    }

    /// libVLC reported a new position / length / state.
    func update(position seconds: Double, length mediaLength: Double? = nil, isPlaying: Bool? = nil) {
        if let isPlaying {
            self.isPlaying = isPlaying
            if isPlaying {
                lastCallbackHostTime = CACurrentMediaTime()
            }
        }
        if let mediaLength, mediaLength.isFinite, mediaLength > 0 {
            length = mediaLength
        }
        guard seconds.isFinite, seconds >= 0 else { return }

        // A callback that still carries the pre-seek position must not pull
        // the playhead back to where the user left it.
        if let pendingSeek {
            guard abs(seconds - pendingSeek) <= 3 else { return }
            self.pendingSeek = nil
        }
        position = seconds
        lastCallbackHostTime = CACurrentMediaTime()
    }

    /// The user asked to jump; show the target immediately.
    func noteSeek(to seconds: Double) {
        let target = clamped(max(seconds, 0))
        position = target
        pendingSeek = target
        lastCallbackHostTime = CACurrentMediaTime()
    }

    /// Live only: anchor the mapping to the segment libVLC started from.
    func setLiveMapping(_ mapping: LivePlaybackClock?) {
        liveMapping = mapping
    }

    func reset() {
        position = 0
        length = 0
        isPlaying = false
        isSeekable = false
        liveMapping = nil
        pendingSeek = nil
        lastCallbackHostTime = CACurrentMediaTime()
    }

    private func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        var result = max(value, 0)
        if length > 0 {
            result = min(result, length)
        }
        return result
    }
}
