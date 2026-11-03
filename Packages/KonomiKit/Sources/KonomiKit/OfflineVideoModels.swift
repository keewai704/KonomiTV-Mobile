import Foundation

// MARK: - Container

/// Segment container of a saved video.
///
/// KonomiTV 0.15 writes MPEG-TS segments. Fragmented MP4 is accepted by the
/// stored format and the playlist builder (it needs an init segment), so a
/// future server that switches container does not invalidate the library.
public enum OfflineSegmentContainer: String, Codable, Sendable, Hashable {
    case mpegTS = "mpegts"
    case fragmentedMP4 = "fmp4"

    /// File extension of the stored segments.
    public var fileExtension: String {
        switch self {
        case .mpegTS: return "ts"
        case .fragmentedMP4: return "m4s"
        }
    }

    /// Content type the loopback server answers segment requests with.
    public var contentType: String {
        switch self {
        case .mpegTS: return "video/mp2t"
        case .fragmentedMP4: return "video/iso.segment"
        }
    }

    /// fMP4 playback needs `#EXT-X-MAP` and an init segment before the media.
    public var requiresInitSegment: Bool {
        self == .fragmentedMP4
    }
}

// MARK: - Segments

/// One stored segment: its index, duration and size on disk.
public struct OfflineSegmentInfo: Codable, Sendable, Hashable {
    public var sequence: Int
    public var durationMilliseconds: Int
    public var byteLength: Int

    public init(sequence: Int, durationMilliseconds: Int, byteLength: Int) {
        self.sequence = sequence
        self.durationMilliseconds = durationMilliseconds
        self.byteLength = byteLength
    }

    public var durationSeconds: Double {
        Double(durationMilliseconds) / 1000
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case durationMilliseconds = "duration_milliseconds"
        case byteLength = "byte_length"
    }
}

// MARK: - Saved video

/// A recorded program saved for offline playback.
///
/// The record is the playlist's source of truth: the program snapshot (so the
/// list renders without the server), the save metadata and the segment list.
/// Segment bytes live next to the manifest in
/// `Application Support/OfflineVideos/<video_id>/`.
public struct OfflineVideo: Codable, Sendable, Hashable, Identifiable {
    public var videoID: Int
    /// Identifies this save; a re-save gets a new value.
    public var generationID: String
    /// Recording file hash of the saved snapshot.
    public var fileHash: String
    /// API quality of the saved segments.
    public var quality: String
    /// Snapshot of the recorded program at save time.
    public var program: RecordedProgram
    public var segments: [OfflineSegmentInfo]
    public var container: OfflineSegmentContainer
    /// Init segment file name for fMP4 saves (nil for MPEG-TS).
    public var initSegmentFile: String?
    public var savedAt: Date

    public init(
        videoID: Int,
        generationID: String,
        fileHash: String,
        quality: String,
        program: RecordedProgram,
        segments: [OfflineSegmentInfo],
        container: OfflineSegmentContainer = .mpegTS,
        initSegmentFile: String? = nil,
        savedAt: Date = Date()
    ) {
        self.videoID = videoID
        self.generationID = generationID
        self.fileHash = fileHash
        self.quality = quality
        self.program = program
        self.segments = segments
        self.container = container
        self.initSegmentFile = initSegmentFile
        self.savedAt = savedAt
    }

    public var id: Int { videoID }

    public var sizeBytes: Int {
        segments.reduce(0) { $0 + $1.byteLength }
    }

    public var segmentCount: Int { segments.count }

    /// Saved length: the sum of the segments, falling back to the program
    /// duration for an empty list.
    public var durationSeconds: Double {
        let total = segments.reduce(0.0) { $0 + $1.durationSeconds }
        return total > 0 ? total : program.recordedVideo.duration
    }

    public var qualityLabel: String {
        OfflineQualityEstimate.formatQualityLabel(apiQuality: quality)
    }

    public var sizeLabel: String {
        OfflineQualityEstimate.formatOfflineSize(bytes: sizeBytes, approximate: false)
    }

    private enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
        case generationID = "generation_id"
        case fileHash = "file_hash"
        case quality
        case program
        case segments
        case container
        case initSegmentFile = "init_segment"
        case savedAt = "saved_at"
    }
}

// MARK: - Jobs

/// Lifecycle of an offline save job (the web client's
/// `OfflineDownloadState`).
public enum OfflineDownloadState: String, Codable, Sendable, Hashable, CaseIterable {
    case waiting
    case downloading
    case finalizing
    case completed
    case failed
    case cancelled

    /// Waiting, downloading or finalizing: the job owns the program.
    public var isActive: Bool {
        switch self {
        case .waiting, .downloading, .finalizing: return true
        case .completed, .failed, .cancelled: return false
        }
    }
}

/// A save that is running, failed or finished.
public struct OfflineDownloadJob: Codable, Sendable, Hashable, Identifiable {
    public var jobID: String
    public var videoID: Int
    public var generationID: String
    /// Program snapshot the job was started with.
    public var program: RecordedProgram
    /// API quality being saved.
    public var quality: String
    public var state: OfflineDownloadState
    /// Estimated final size (progress bar denominator).
    public var estimatedSizeBytes: Int
    public var downloadedBytes: Int
    public var receivedSegments: Int
    /// Program duration / segment duration, refreshed as segments arrive.
    public var expectedSegments: Int
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        jobID: String = UUID().uuidString,
        videoID: Int,
        generationID: String = UUID().uuidString,
        program: RecordedProgram,
        quality: String,
        state: OfflineDownloadState = .waiting,
        estimatedSizeBytes: Int = 0,
        downloadedBytes: Int = 0,
        receivedSegments: Int = 0,
        expectedSegments: Int = 0,
        error: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.jobID = jobID
        self.videoID = videoID
        self.generationID = generationID
        self.program = program
        self.quality = quality
        self.state = state
        self.estimatedSizeBytes = estimatedSizeBytes
        self.downloadedBytes = downloadedBytes
        self.receivedSegments = receivedSegments
        self.expectedSegments = expectedSegments
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var id: String { jobID }

    public var qualityLabel: String {
        OfflineQualityEstimate.formatQualityLabel(apiQuality: quality)
    }

    /// 0...0.99 while running, 1 once finished.
    public var progress: Double {
        guard state != .completed else { return 1 }
        return OfflineDownloadProgress.fraction(
            receivedSegments: receivedSegments,
            expectedSegments: expectedSegments,
            downloadedBytes: downloadedBytes,
            estimatedSizeBytes: estimatedSizeBytes
        )
    }

    private enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case videoID = "video_id"
        case generationID = "generation_id"
        case program
        case quality
        case state
        case estimatedSizeBytes = "estimated_size_bytes"
        case downloadedBytes = "downloaded_bytes"
        case receivedSegments = "received_segments"
        case expectedSegments = "expected_segments"
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Progress

/// Progress rules of an offline save.
///
/// The web client counts received segments against the expected count
/// (duration / segment duration). The segment duration is not known before the
/// first segment, so the byte estimate is the fallback. Both stay below 1 until
/// the playlist is written, which is what tells the user the save is usable.
public enum OfflineDownloadProgress {
    /// `ceil(duration / segmentDuration)`, at least 1.
    public static func expectedSegmentCount(
        durationSeconds: Double,
        segmentDurationSeconds: Double
    ) -> Int {
        guard durationSeconds > 0, segmentDurationSeconds > 0 else { return 0 }
        return max(Int((durationSeconds / segmentDurationSeconds).rounded(.up)), 1)
    }

    public static func fraction(
        receivedSegments: Int,
        expectedSegments: Int,
        downloadedBytes: Int,
        estimatedSizeBytes: Int
    ) -> Double {
        if expectedSegments > 0, receivedSegments > 0 {
            return min(Double(receivedSegments) / Double(expectedSegments), 0.99)
        }
        if estimatedSizeBytes > 0 {
            return min(Double(downloadedBytes) / Double(estimatedSizeBytes), 0.99)
        }
        return 0
    }
}
