import Foundation
import KonomiKit

/// Thread-safe store of recent live segments, keyed by sequence number.
public actor SegmentStore {
    public let capacity: Int

    private var storage: [TSSegment] = []
    private var evictedDiscontinuities = 0
    private var publishedTargetDuration = 1
    /// Wall-clock anchor of the first produced segment, published as
    /// `#EXT-X-PROGRAM-DATE-TIME` and used to map caption PTS values onto the
    /// player's `currentDate()`.
    private var anchor: LiveProgramDateTimeAnchor?

    public init(capacity: Int = 12) {
        self.capacity = max(1, capacity)
    }

    public var count: Int {
        storage.count
    }

    public var latestSequence: Int? {
        storage.last?.sequence
    }

    public var latestSegment: TSSegment? {
        storage.last
    }

    public func append(_ segment: TSSegment) {
        if let last = storage.last, segment.sequence <= last.sequence {
            // The upstream stream restarted its sequence numbering.
            storage.removeAll(keepingCapacity: true)
            evictedDiscontinuities = 0
            publishedTargetDuration = 1
            anchor = nil
        }
        if anchor == nil, let firstVideoPTS = segment.firstVideoPTS {
            anchor = LiveProgramDateTimeAnchor(anchorDate: Date(), anchorPTS: firstVideoPTS)
        }
        storage.append(segment)
        publishedTargetDuration = max(
            publishedTargetDuration,
            TSSegmentMediaPlaylist.targetDuration(for: [segment])
        )
        while storage.count > capacity {
            let evicted = storage.removeFirst()
            if evicted.discontinuity {
                evictedDiscontinuities += 1
            }
        }
    }

    public func append(contentsOf segments: [TSSegment]) {
        for segment in segments {
            append(segment)
        }
    }

    public func segment(sequence: Int) -> TSSegment? {
        storage.first { $0.sequence == sequence }
    }

    /// Segment as it should be served for the given audio track.
    ///
    /// Segments are stored once and unfiltered; the 主音声 / 副音声 filter is
    /// applied here so switching takes effect with the next request without
    /// restarting the upstream stream. With a single audio stream the stored
    /// segment is returned unchanged.
    public func segment(sequence: Int, audio: AudioSelection) -> TSSegment? {
        storage.first { $0.sequence == sequence }?.filtered(audio: audio)
    }

    /// Audio tracks of the most recent segment, if its PMT is known.
    public var audioTrackInfo: LiveAudioTrackInfo? {
        storage.last?.audioTrackInfo
    }

    /// True when the app should offer 主音声 / 副音声 for this stream.
    public var hasSecondaryAudio: Bool {
        audioTrackInfo?.hasSecondaryAudio ?? false
    }

    public func snapshot() -> [TSSegment] {
        storage
    }

    public func clear() {
        storage.removeAll(keepingCapacity: true)
        evictedDiscontinuities = 0
        publishedTargetDuration = 1
        anchor = nil
    }

    /// Wall-clock anchor of the first produced segment, if one has arrived.
    public var programDateTimeAnchor: LiveProgramDateTimeAnchor? {
        anchor
    }

    /// Renders the current sliding-window playlist.
    public func playlist(windowSize: Int = 6) -> String {
        let count = min(max(windowSize, 1), storage.count)
        let firstIndex = storage.count - count
        let prior = evictedDiscontinuities
            + storage.prefix(firstIndex).filter(\.discontinuity).count
        return TSSegmentMediaPlaylist.render(
            segments: storage,
            windowSize: windowSize,
            discontinuitySequence: prior,
            minimumTargetDuration: publishedTargetDuration,
            programDateTimeAnchor: anchor
        )
    }
}
