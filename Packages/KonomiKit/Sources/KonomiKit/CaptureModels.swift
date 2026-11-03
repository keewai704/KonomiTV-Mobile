import Foundation

// MARK: - Enumerations

/// Sort order accepted by GET /api/captures.
///
/// Mirrors CaptureOrder in the server's CapturesRouter.py.
public enum CaptureSortOrder: String, Codable, CaseIterable, Sendable, Hashable {
    case capturedAtDesc = "CapturedAtDesc"
    case capturedAtAsc = "CapturedAtAsc"
    case broadcastAtDesc = "BroadcastAtDesc"
    case broadcastAtAsc = "BroadcastAtAsc"
    case playbackPosition = "PlaybackPosition"
}

/// Sort order accepted by GET /api/captures/programs.
public enum CaptureProgramSortOrder: String, Codable, CaseIterable, Sendable, Hashable {
    case broadcastAtDesc = "BroadcastAtDesc"
    case broadcastAtAsc = "BroadcastAtAsc"
}

/// The time axis used by the timeline and the date sections.
public enum CaptureTimelineAxis: String, Codable, CaseIterable, Sendable, Hashable {
    case capturedAt = "CapturedAt"
    case broadcastAt = "BroadcastAt"
}

/// Which of a capture's text fields a search keyword is matched against.
///
/// An empty queryTargets list means "all targets", matching the server.
public enum CaptureQueryTarget: String, Codable, CaseIterable, Sendable, Hashable {
    case captionText = "CaptionText"
    case programTitle = "ProgramTitle"
    case programDescription = "ProgramDescription"
}

/// Whether the capture image had readable metadata (EXIF) when scanned.
public enum CaptureMetadataStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case parsed = "Parsed"
    case noMetadata = "NoMetadata"
    case invalid = "Invalid"
}

/// Availability of one stored file of a capture.
public enum CaptureFileStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case available = "Available"
    case missing = "Missing"
    case invalid = "Invalid"
}

// MARK: - Filters

/// The filter menu of the web client's capture list, mapped to the query
/// parameters of GET /api/captures and GET /api/captures/sections.
///
/// nil (and empty arrays) means "not filtered", exactly like the web client's
/// buildFilterParams(). List values are sent as repeated query parameters
/// (&tag_ids=1&tag_ids=2) because FastAPI expects that form.
public struct CaptureFilters: Sendable, Hashable {
    public var captureProgramID: Int?
    public var recordedProgramID: Int?
    /// Program key. The server requires all four fields together; the client
    /// should only set them as a group (live view "show captures of this
    /// broadcast").
    public var networkID: Int?
    public var serviceID: Int?
    public var eventID: Int?
    public var startTime: Date?
    public var isFavorite: Bool?
    /// All given tags must be attached (AND).
    public var tagIDs: [Int]
    /// Any of the given channels matches (OR).
    public var channelIDs: [String]
    /// YYYY-MM-DD in JST, inclusive.
    public var startDate: String?
    /// YYYY-MM-DD in JST, inclusive (the whole day is included).
    public var endDate: String?
    public var isCaptionComposited: Bool?
    public var isCommentComposited: Bool?
    public var hasCaptionText: Bool?
    public var hasMetadata: Bool?
    public var query: String?
    /// Empty means all targets.
    public var queryTargets: [CaptureQueryTarget]

    public init(
        captureProgramID: Int? = nil,
        recordedProgramID: Int? = nil,
        networkID: Int? = nil,
        serviceID: Int? = nil,
        eventID: Int? = nil,
        startTime: Date? = nil,
        isFavorite: Bool? = nil,
        tagIDs: [Int] = [],
        channelIDs: [String] = [],
        startDate: String? = nil,
        endDate: String? = nil,
        isCaptionComposited: Bool? = nil,
        isCommentComposited: Bool? = nil,
        hasCaptionText: Bool? = nil,
        hasMetadata: Bool? = nil,
        query: String? = nil,
        queryTargets: [CaptureQueryTarget] = []
    ) {
        self.captureProgramID = captureProgramID
        self.recordedProgramID = recordedProgramID
        self.networkID = networkID
        self.serviceID = serviceID
        self.eventID = eventID
        self.startTime = startTime
        self.isFavorite = isFavorite
        self.tagIDs = tagIDs
        self.channelIDs = channelIDs
        self.startDate = startDate
        self.endDate = endDate
        self.isCaptionComposited = isCaptionComposited
        self.isCommentComposited = isCommentComposited
        self.hasCaptionText = hasCaptionText
        self.hasMetadata = hasMetadata
        self.query = query
        self.queryTargets = queryTargets
    }

    /// Query items for the server. Empty values are omitted.
    public func queryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        func add(_ name: String, _ value: Int?) {
            if let value { items.append(URLQueryItem(name: name, value: String(value))) }
        }
        func add(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            items.append(URLQueryItem(name: name, value: value))
        }
        func add(_ name: String, _ value: Bool?) {
            if let value { items.append(URLQueryItem(name: name, value: value ? "true" : "false")) }
        }

        add("capture_program_id", captureProgramID)
        add("recorded_program_id", recordedProgramID)
        add("network_id", networkID)
        add("service_id", serviceID)
        add("event_id", eventID)
        if let startTime {
            add("start_time", JSONCoding.formatQueryDateTime(startTime))
        }
        add("is_favorite", isFavorite)
        for tagID in tagIDs {
            items.append(URLQueryItem(name: "tag_ids", value: String(tagID)))
        }
        for channelID in channelIDs where !channelID.isEmpty {
            items.append(URLQueryItem(name: "channel_ids", value: channelID))
        }
        add("start_date", startDate)
        add("end_date", endDate)
        add("is_caption_composited", isCaptionComposited)
        add("is_comment_composited", isCommentComposited)
        add("has_caption_text", hasCaptionText)
        add("has_metadata", hasMetadata)
        add("query", query)
        for target in queryTargets {
            items.append(URLQueryItem(name: "query_targets", value: target.rawValue))
        }
        return items
    }
}

// MARK: - Capture

/// One capture (one image), as returned by GET /api/captures.
///
/// is_favorite and tag_ids are nil when the request was not authenticated:
/// the server cannot know the viewer's favourites then.
public struct Capture: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    /// Lowercase hex SHA-256 of the image contents. Part of the image URL so
    /// the URL changes when the file changes (the server caches images for a
    /// year).
    public var fileHash: String
    public var fileSize: Int
    public var capturedAt: Date
    /// nil when the capture has no program metadata.
    public var broadcastAt: Date?
    public var imageWidth: Int
    public var imageHeight: Int
    public var metadataStatus: CaptureMetadataStatus
    /// Playback position in seconds from the start of the program (live) or
    /// from the start of the recording (video), when known.
    public var playbackPosition: Double?
    /// The caption shown when the capture was taken, whether or not it was
    /// composited into the image.
    public var captionText: String?
    public var isCaptionComposited: Bool
    public var isCommentComposited: Bool
    public var captureProgramID: Int?
    public var isFavorite: Bool?
    public var tagIDs: [Int]?

    public init(
        id: Int = 0,
        fileHash: String = "",
        fileSize: Int = 0,
        capturedAt: Date = Date(timeIntervalSince1970: 0),
        broadcastAt: Date? = nil,
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        metadataStatus: CaptureMetadataStatus = .noMetadata,
        playbackPosition: Double? = nil,
        captionText: String? = nil,
        isCaptionComposited: Bool = false,
        isCommentComposited: Bool = false,
        captureProgramID: Int? = nil,
        isFavorite: Bool? = nil,
        tagIDs: [Int]? = nil
    ) {
        self.id = id
        self.fileHash = fileHash
        self.fileSize = fileSize
        self.capturedAt = capturedAt
        self.broadcastAt = broadcastAt
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.metadataStatus = metadataStatus
        self.playbackPosition = playbackPosition
        self.captionText = captionText
        self.isCaptionComposited = isCaptionComposited
        self.isCommentComposited = isCommentComposited
        self.captureProgramID = captureProgramID
        self.isFavorite = isFavorite
        self.tagIDs = tagIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fileHash = "file_hash"
        case fileSize = "file_size"
        case capturedAt = "captured_at"
        case broadcastAt = "broadcast_at"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case metadataStatus = "metadata_status"
        case playbackPosition = "playback_position"
        case captionText = "caption_text"
        case isCaptionComposited = "is_caption_composited"
        case isCommentComposited = "is_comment_composited"
        case captureProgramID = "capture_program_id"
        case isFavorite = "is_favorite"
        case tagIDs = "tag_ids"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? 0
        fileHash = container.lenient(String.self, forKey: .fileHash) ?? ""
        fileSize = container.lenient(Int.self, forKey: .fileSize) ?? 0
        capturedAt = container.lenient(Date.self, forKey: .capturedAt) ?? Date(timeIntervalSince1970: 0)
        broadcastAt = container.lenient(Date.self, forKey: .broadcastAt)
        imageWidth = container.lenient(Int.self, forKey: .imageWidth) ?? 0
        imageHeight = container.lenient(Int.self, forKey: .imageHeight) ?? 0
        let rawStatus = container.lenient(String.self, forKey: .metadataStatus) ?? ""
        metadataStatus = CaptureMetadataStatus(rawValue: rawStatus) ?? .noMetadata
        playbackPosition = container.lenient(Double.self, forKey: .playbackPosition)
        captionText = container.lenient(String.self, forKey: .captionText)
        isCaptionComposited = container.lenient(Bool.self, forKey: .isCaptionComposited) ?? false
        isCommentComposited = container.lenient(Bool.self, forKey: .isCommentComposited) ?? false
        captureProgramID = container.lenient(Int.self, forKey: .captureProgramID)
        isFavorite = container.lenient(Bool.self, forKey: .isFavorite)
        tagIDs = container.lenient([Int].self, forKey: .tagIDs)
    }
}

/// A broadcast episode (放送回) that captures belong to.
public struct CaptureProgram: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var networkID: Int
    public var serviceID: Int
    public var eventID: Int
    public var startTime: Date
    /// nil for a program whose end was unknown (放送時間未定).
    public var endTime: Date?
    public var duration: Double?
    public var title: String
    public var description: String
    public var channel: CaptureChannel?
    /// Recorded programs whose program key matches this episode.
    public var recordedProgramIDs: [Int]

    public init(
        id: Int = 0,
        networkID: Int = 0,
        serviceID: Int = 0,
        eventID: Int = 0,
        startTime: Date = Date(timeIntervalSince1970: 0),
        endTime: Date? = nil,
        duration: Double? = nil,
        title: String = "",
        description: String = "",
        channel: CaptureChannel? = nil,
        recordedProgramIDs: [Int] = []
    ) {
        self.id = id
        self.networkID = networkID
        self.serviceID = serviceID
        self.eventID = eventID
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.title = title
        self.description = description
        self.channel = channel
        self.recordedProgramIDs = recordedProgramIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case networkID = "network_id"
        case serviceID = "service_id"
        case eventID = "event_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case duration
        case title
        case description
        case channel
        case recordedProgramIDs = "recorded_program_ids"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? 0
        networkID = container.lenient(Int.self, forKey: .networkID) ?? 0
        serviceID = container.lenient(Int.self, forKey: .serviceID) ?? 0
        eventID = container.lenient(Int.self, forKey: .eventID) ?? 0
        startTime = container.lenient(Date.self, forKey: .startTime) ?? Date(timeIntervalSince1970: 0)
        endTime = container.lenient(Date.self, forKey: .endTime)
        duration = container.lenient(Double.self, forKey: .duration)
        title = container.lenient(String.self, forKey: .title) ?? ""
        description = container.lenient(String.self, forKey: .description) ?? ""
        channel = container.lenient(CaptureChannel.self, forKey: .channel)
        recordedProgramIDs = container.lenient([Int].self, forKey: .recordedProgramIDs) ?? []
    }
}

/// The channel of a broadcast episode, as embedded in capture responses.
public struct CaptureChannel: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayChannelID: String
    public var name: String
    /// GR / BS / CS / CATV / SKY / BS4K.
    public var type: String

    public init(
        id: String = "",
        displayChannelID: String = "",
        name: String = "",
        type: String = ""
    ) {
        self.id = id
        self.displayChannelID = displayChannelID
        self.name = name
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayChannelID = "display_channel_id"
        case name
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(String.self, forKey: .id) ?? ""
        displayChannelID = container.lenient(String.self, forKey: .displayChannelID) ?? ""
        name = container.lenient(String.self, forKey: .name) ?? ""
        type = container.lenient(String.self, forKey: .type) ?? ""
    }
}

/// One page of GET /api/captures.
public struct Captures: Codable, Sendable, Hashable {
    public var captures: [Capture]
    /// The broadcast episodes referenced by the captures in this page.
    public var programs: [CaptureProgram]
    /// Cursor for the next page; nil on the last page.
    public var nextCursor: String?

    public init(
        captures: [Capture] = [],
        programs: [CaptureProgram] = [],
        nextCursor: String? = nil
    ) {
        self.captures = captures
        self.programs = programs
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case captures
        case programs
        case nextCursor = "next_cursor"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captures = container.lenient([Capture].self, forKey: .captures) ?? []
        programs = container.lenient([CaptureProgram].self, forKey: .programs) ?? []
        nextCursor = container.lenient(String.self, forKey: .nextCursor)
    }
}

// MARK: - Sections

/// Daily capture counts for the timeline scrubber
/// (GET /api/captures/sections).
public struct CaptureSections: Codable, Sendable, Hashable {
    /// Newest date first.
    public var sections: [CaptureSection]
    public var total: Int

    public init(sections: [CaptureSection] = [], total: Int = 0) {
        self.sections = sections
        self.total = total
    }

    private enum CodingKeys: String, CodingKey {
        case sections
        case total
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sections = container.lenient([CaptureSection].self, forKey: .sections) ?? []
        total = container.lenient(Int.self, forKey: .total) ?? 0
    }
}

/// One day of the capture timeline. date is YYYY-MM-DD in JST.
public struct CaptureSection: Codable, Sendable, Hashable, Identifiable {
    public var date: String
    public var count: Int

    public var id: String { date }

    public init(date: String = "", count: Int = 0) {
        self.date = date
        self.count = count
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = container.lenient(String.self, forKey: .date) ?? ""
        count = container.lenient(Int.self, forKey: .count) ?? 0
    }
}

// MARK: - Programs (albums)

/// One page of GET /api/captures/programs.
public struct CapturePrograms: Codable, Sendable, Hashable {
    public var programs: [CaptureProgramAlbum]
    public var nextCursor: String?

    public init(programs: [CaptureProgramAlbum] = [], nextCursor: String? = nil) {
        self.programs = programs
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case programs
        case nextCursor = "next_cursor"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        programs = container.lenient([CaptureProgramAlbum].self, forKey: .programs) ?? []
        nextCursor = container.lenient(String.self, forKey: .nextCursor)
    }
}

/// A broadcast episode together with its capture count and a representative
/// capture (the one in the middle of the episode's captures, ordered by
/// playback position).
public struct CaptureProgramAlbum: Codable, Sendable, Hashable {
    public var program: CaptureProgram
    public var captureCount: Int
    public var coverCapture: Capture

    public var id: Int { program.id }

    public init(
        program: CaptureProgram = CaptureProgram(),
        captureCount: Int = 0,
        coverCapture: Capture = Capture()
    ) {
        self.program = program
        self.captureCount = captureCount
        self.coverCapture = coverCapture
    }

    private enum CodingKeys: String, CodingKey {
        case captureCount = "capture_count"
        case coverCapture = "cover_capture"
    }

    public init(from decoder: Decoder) throws {
        program = try CaptureProgram(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureCount = container.lenient(Int.self, forKey: .captureCount) ?? 0
        coverCapture = container.lenient(Capture.self, forKey: .coverCapture) ?? Capture()
    }

    public func encode(to encoder: Encoder) throws {
        try program.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureCount, forKey: .captureCount)
        try container.encode(coverCapture, forKey: .coverCapture)
    }
}

// MARK: - Tags

/// A personal capture tag (GET/POST/PUT /api/captures/tags).
public struct CaptureTag: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    /// Number of captures that carry this tag and still have an available file.
    public var captureCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int = 0,
        name: String = "",
        captureCount: Int = 0,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.name = name
        self.captureCount = captureCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case captureCount = "capture_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? 0
        name = container.lenient(String.self, forKey: .name) ?? ""
        captureCount = container.lenient(Int.self, forKey: .captureCount) ?? 0
        createdAt = container.lenient(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = container.lenient(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }
}

// MARK: - Delete

/// Result of DELETE /api/captures.
public struct CaptureDeleteResult: Codable, Sendable, Hashable {
    public var deletedCaptureIDs: [Int]
    public var failedCaptureIDs: [Int]

    public init(deletedCaptureIDs: [Int] = [], failedCaptureIDs: [Int] = []) {
        self.deletedCaptureIDs = deletedCaptureIDs
        self.failedCaptureIDs = failedCaptureIDs
    }

    private enum CodingKeys: String, CodingKey {
        case deletedCaptureIDs = "deleted_capture_ids"
        case failedCaptureIDs = "failed_capture_ids"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deletedCaptureIDs = container.lenient([Int].self, forKey: .deletedCaptureIDs) ?? []
        failedCaptureIDs = container.lenient([Int].self, forKey: .failedCaptureIDs) ?? []
    }
}

// MARK: - Detail

/// One stored file of a capture. file_path is a server-side path.
public struct CaptureFile: Codable, Sendable, Hashable, Identifiable {
    public var fileName: String
    public var filePath: String
    public var status: CaptureFileStatus

    public var id: String { filePath + "/" + fileName }

    public init(
        fileName: String = "",
        filePath: String = "",
        status: CaptureFileStatus = .available
    ) {
        self.fileName = fileName
        self.filePath = filePath
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case filePath = "file_path"
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = container.lenient(String.self, forKey: .fileName) ?? ""
        filePath = container.lenient(String.self, forKey: .filePath) ?? ""
        let rawStatus = container.lenient(String.self, forKey: .status) ?? ""
        status = CaptureFileStatus(rawValue: rawStatus) ?? .available
    }
}

/// GET /api/captures/{id}: the capture plus its episode and stored files.
public struct CaptureDetail: Codable, Sendable, Hashable {
    public var capture: Capture
    public var program: CaptureProgram?
    public var files: [CaptureFile]

    public var id: Int { capture.id }

    public init(
        capture: Capture = Capture(),
        program: CaptureProgram? = nil,
        files: [CaptureFile] = []
    ) {
        self.capture = capture
        self.program = program
        self.files = files
    }

    private enum CodingKeys: String, CodingKey {
        case program
        case files
    }

    public init(from decoder: Decoder) throws {
        capture = try Capture(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        program = container.lenient(CaptureProgram.self, forKey: .program)
        files = container.lenient([CaptureFile].self, forKey: .files) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        try capture.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(program, forKey: .program)
        try container.encode(files, forKey: .files)
    }
}
