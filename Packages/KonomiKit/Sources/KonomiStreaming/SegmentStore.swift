import Foundation

/// Thread-safe store of recent live segments, keyed by sequence number.
public actor SegmentStore {
    public let capacity: Int

    private var storage: [TSSegment] = []
    private var evictedDiscontinuities = 0
    private var publishedTargetDuration = 1

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

    public func snapshot() -> [TSSegment] {
        storage
    }

    public func clear() {
        storage.removeAll(keepingCapacity: true)
        evictedDiscontinuities = 0
        publishedTargetDuration = 1
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
            minimumTargetDuration: publishedTargetDuration
        )
    }
}
