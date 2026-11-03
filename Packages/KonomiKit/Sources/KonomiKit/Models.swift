import Foundation

// MARK: - Channel type

/// The broadcast type of a channel, matching the keys used by KonomiTV's
/// `/api/channels` endpoint.
public enum ChannelType: String, Codable, CaseIterable, Sendable, Hashable {
    case gr = "GR"
    case bs = "BS"
    case cs = "CS"
    case catv = "CATV"
    case sky = "SKY"
    case bs4k = "BS4K"

    /// Japanese label suitable for a segmented picker.
    public var displayName: String {
        switch self {
        case .gr: return "地デジ"
        case .bs: return "BS"
        case .cs: return "CS"
        case .catv: return "CATV"
        case .sky: return "SKY"
        case .bs4k: return "BS4K"
        }
    }
}

// MARK: - Genre

public struct Genre: Codable, Sendable, Hashable {
    public var major: String
    public var middle: String

    public init(major: String = "", middle: String = "") {
        self.major = major
        self.middle = middle
    }

    private enum CodingKeys: String, CodingKey {
        case major
        case middle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        major = container.lenient(String.self, forKey: .major) ?? ""
        middle = container.lenient(String.self, forKey: .middle) ?? ""
    }
}

// MARK: - Program

public struct Program: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var channelID: String
    public var networkID: Int?
    public var serviceID: Int?
    public var eventID: Int?
    public var title: String
    public var description: String
    public var detail: [String: String]
    public var startTime: Date
    public var endTime: Date
    public var duration: Double
    public var isFree: Bool
    public var genres: [Genre]
    public var videoType: String?
    public var videoCodec: String?
    public var videoResolution: String?
    public var primaryAudioType: String?
    public var primaryAudioLanguage: String?
    public var primaryAudioSamplingRate: String?
    public var secondaryAudioType: String?
    public var secondaryAudioLanguage: String?

    public init(
        id: String = "",
        channelID: String = "",
        networkID: Int? = nil,
        serviceID: Int? = nil,
        eventID: Int? = nil,
        title: String = "",
        description: String = "",
        detail: [String: String] = [:],
        startTime: Date = Date(timeIntervalSince1970: 0),
        endTime: Date = Date(timeIntervalSince1970: 0),
        duration: Double = 0,
        isFree: Bool = true,
        genres: [Genre] = [],
        videoType: String? = nil,
        videoCodec: String? = nil,
        videoResolution: String? = nil,
        primaryAudioType: String? = nil,
        primaryAudioLanguage: String? = nil,
        primaryAudioSamplingRate: String? = nil,
        secondaryAudioType: String? = nil,
        secondaryAudioLanguage: String? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.networkID = networkID
        self.serviceID = serviceID
        self.eventID = eventID
        self.title = title
        self.description = description
        self.detail = detail
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.isFree = isFree
        self.genres = genres
        self.videoType = videoType
        self.videoCodec = videoCodec
        self.videoResolution = videoResolution
        self.primaryAudioType = primaryAudioType
        self.primaryAudioLanguage = primaryAudioLanguage
        self.primaryAudioSamplingRate = primaryAudioSamplingRate
        self.secondaryAudioType = secondaryAudioType
        self.secondaryAudioLanguage = secondaryAudioLanguage
    }

    /// Progress of the program at `date`, clamped to 0...1.
    public func progress(at date: Date) -> Double {
        let total = endTime.timeIntervalSince(startTime)
        guard total > 0 else { return 0 }
        let elapsed = date.timeIntervalSince(startTime)
        return min(max(elapsed / total, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case networkID = "network_id"
        case serviceID = "service_id"
        case eventID = "event_id"
        case title
        case description
        case detail
        case startTime = "start_time"
        case endTime = "end_time"
        case duration
        case isFree = "is_free"
        case genres
        case videoType = "video_type"
        case videoCodec = "video_codec"
        case videoResolution = "video_resolution"
        case primaryAudioType = "primary_audio_type"
        case primaryAudioLanguage = "primary_audio_language"
        case primaryAudioSamplingRate = "primary_audio_sampling_rate"
        case secondaryAudioType = "secondary_audio_type"
        case secondaryAudioLanguage = "secondary_audio_language"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(String.self, forKey: .id) ?? ""
        channelID = container.lenient(String.self, forKey: .channelID) ?? ""
        networkID = container.lenient(Int.self, forKey: .networkID)
        serviceID = container.lenient(Int.self, forKey: .serviceID)
        eventID = container.lenient(Int.self, forKey: .eventID)
        title = container.lenient(String.self, forKey: .title) ?? ""
        description = container.lenient(String.self, forKey: .description) ?? ""
        detail = container.lenient([String: String].self, forKey: .detail) ?? [:]
        startTime = container.lenient(Date.self, forKey: .startTime) ?? Date(timeIntervalSince1970: 0)
        endTime = container.lenient(Date.self, forKey: .endTime) ?? Date(timeIntervalSince1970: 0)
        duration = container.lenient(Double.self, forKey: .duration) ?? 0
        isFree = container.lenient(Bool.self, forKey: .isFree) ?? true
        genres = container.lenient([Genre].self, forKey: .genres) ?? []
        videoType = container.lenient(String.self, forKey: .videoType)
        videoCodec = container.lenient(String.self, forKey: .videoCodec)
        videoResolution = container.lenient(String.self, forKey: .videoResolution)
        primaryAudioType = container.lenient(String.self, forKey: .primaryAudioType)
        primaryAudioLanguage = container.lenient(String.self, forKey: .primaryAudioLanguage)
        primaryAudioSamplingRate = container.lenient(String.self, forKey: .primaryAudioSamplingRate)
        secondaryAudioType = container.lenient(String.self, forKey: .secondaryAudioType)
        secondaryAudioLanguage = container.lenient(String.self, forKey: .secondaryAudioLanguage)
    }
}

// MARK: - Channel

public struct Channel: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayChannelID: String
    public var networkID: Int
    public var serviceID: Int
    public var transportStreamID: Int?
    public var remoconID: Int
    public var channelNumber: String
    public var type: ChannelType
    public var name: String
    public var isSubChannel: Bool
    public var isRadioChannel: Bool
    public var isWatchable: Bool
    /// Jikkyo (real-time comment) momentum, used to sort the channel list when
    /// `tv_channel_sort_by_jikkyo_force` is enabled. `nil` when unknown.
    public var jikkyoForce: Int?

    public init(
        id: String = "",
        displayChannelID: String = "",
        networkID: Int = 0,
        serviceID: Int = 0,
        transportStreamID: Int? = nil,
        remoconID: Int = 0,
        channelNumber: String = "",
        type: ChannelType = .gr,
        name: String = "",
        isSubChannel: Bool = false,
        isRadioChannel: Bool = false,
        isWatchable: Bool = false,
        jikkyoForce: Int? = nil
    ) {
        self.id = id
        self.displayChannelID = displayChannelID
        self.networkID = networkID
        self.serviceID = serviceID
        self.transportStreamID = transportStreamID
        self.remoconID = remoconID
        self.channelNumber = channelNumber
        self.type = type
        self.name = name
        self.isSubChannel = isSubChannel
        self.isRadioChannel = isRadioChannel
        self.isWatchable = isWatchable
        self.jikkyoForce = jikkyoForce
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayChannelID = "display_channel_id"
        case networkID = "network_id"
        case serviceID = "service_id"
        case transportStreamID = "transport_stream_id"
        case remoconID = "remocon_id"
        case channelNumber = "channel_number"
        case type
        case name
        case isSubChannel = "is_subchannel"
        case isRadioChannel = "is_radiochannel"
        case isWatchable = "is_watchable"
        case jikkyoForce = "jikkyo_force"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(String.self, forKey: .id) ?? ""
        displayChannelID = container.lenient(String.self, forKey: .displayChannelID) ?? ""
        networkID = container.lenient(Int.self, forKey: .networkID) ?? 0
        serviceID = container.lenient(Int.self, forKey: .serviceID) ?? 0
        transportStreamID = container.lenient(Int.self, forKey: .transportStreamID)
        remoconID = container.lenient(Int.self, forKey: .remoconID) ?? 0
        channelNumber = container.lenient(String.self, forKey: .channelNumber) ?? ""
        let rawType = container.lenient(String.self, forKey: .type) ?? ""
        type = ChannelType(rawValue: rawType) ?? .gr
        name = container.lenient(String.self, forKey: .name) ?? ""
        isSubChannel = container.lenient(Bool.self, forKey: .isSubChannel) ?? false
        isRadioChannel = container.lenient(Bool.self, forKey: .isRadioChannel) ?? false
        isWatchable = container.lenient(Bool.self, forKey: .isWatchable) ?? false
        jikkyoForce = container.lenient(Int.self, forKey: .jikkyoForce)
    }
}

// MARK: - Live channel

public struct LiveChannel: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayChannelID: String
    public var networkID: Int
    public var serviceID: Int
    public var transportStreamID: Int?
    public var remoconID: Int
    public var channelNumber: String
    public var type: ChannelType
    public var name: String
    public var isSubChannel: Bool
    public var isRadioChannel: Bool
    public var isWatchable: Bool
    public var isDisplay: Bool
    public var viewerCount: Int
    public var programPresent: Program?
    public var programFollowing: Program?
    /// Jikkyo (real-time comment) momentum, used for
    /// `tv_channel_sort_by_jikkyo_force`. `nil` when unknown.
    public var jikkyoForce: Int?

    public init(
        id: String = "",
        displayChannelID: String = "",
        networkID: Int = 0,
        serviceID: Int = 0,
        transportStreamID: Int? = nil,
        remoconID: Int = 0,
        channelNumber: String = "",
        type: ChannelType = .gr,
        name: String = "",
        isSubChannel: Bool = false,
        isRadioChannel: Bool = false,
        isWatchable: Bool = false,
        isDisplay: Bool = true,
        viewerCount: Int = 0,
        programPresent: Program? = nil,
        programFollowing: Program? = nil,
        jikkyoForce: Int? = nil
    ) {
        self.id = id
        self.displayChannelID = displayChannelID
        self.networkID = networkID
        self.serviceID = serviceID
        self.transportStreamID = transportStreamID
        self.remoconID = remoconID
        self.channelNumber = channelNumber
        self.type = type
        self.name = name
        self.isSubChannel = isSubChannel
        self.isRadioChannel = isRadioChannel
        self.isWatchable = isWatchable
        self.isDisplay = isDisplay
        self.viewerCount = viewerCount
        self.programPresent = programPresent
        self.programFollowing = programFollowing
        self.jikkyoForce = jikkyoForce
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayChannelID = "display_channel_id"
        case networkID = "network_id"
        case serviceID = "service_id"
        case transportStreamID = "transport_stream_id"
        case remoconID = "remocon_id"
        case channelNumber = "channel_number"
        case type
        case name
        case isSubChannel = "is_subchannel"
        case isRadioChannel = "is_radiochannel"
        case isWatchable = "is_watchable"
        case isDisplay = "is_display"
        case viewerCount = "viewer_count"
        case programPresent = "program_present"
        case programFollowing = "program_following"
        case jikkyoForce = "jikkyo_force"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(String.self, forKey: .id) ?? ""
        displayChannelID = container.lenient(String.self, forKey: .displayChannelID) ?? ""
        networkID = container.lenient(Int.self, forKey: .networkID) ?? 0
        serviceID = container.lenient(Int.self, forKey: .serviceID) ?? 0
        transportStreamID = container.lenient(Int.self, forKey: .transportStreamID)
        remoconID = container.lenient(Int.self, forKey: .remoconID) ?? 0
        channelNumber = container.lenient(String.self, forKey: .channelNumber) ?? ""
        let rawType = container.lenient(String.self, forKey: .type) ?? ""
        type = ChannelType(rawValue: rawType) ?? .gr
        name = container.lenient(String.self, forKey: .name) ?? ""
        isSubChannel = container.lenient(Bool.self, forKey: .isSubChannel) ?? false
        isRadioChannel = container.lenient(Bool.self, forKey: .isRadioChannel) ?? false
        isWatchable = container.lenient(Bool.self, forKey: .isWatchable) ?? false
        isDisplay = container.lenient(Bool.self, forKey: .isDisplay) ?? true
        viewerCount = container.lenient(Int.self, forKey: .viewerCount) ?? 0
        programPresent = container.lenient(Program.self, forKey: .programPresent)
        programFollowing = container.lenient(Program.self, forKey: .programFollowing)
        jikkyoForce = container.lenient(Int.self, forKey: .jikkyoForce)
    }
}

// MARK: - Live channels response

public struct LiveChannels: Codable, Sendable, Hashable {
    public var gr: [LiveChannel]
    public var bs: [LiveChannel]
    public var cs: [LiveChannel]
    public var catv: [LiveChannel]
    public var sky: [LiveChannel]
    public var bs4k: [LiveChannel]

    public init(
        gr: [LiveChannel] = [],
        bs: [LiveChannel] = [],
        cs: [LiveChannel] = [],
        catv: [LiveChannel] = [],
        sky: [LiveChannel] = [],
        bs4k: [LiveChannel] = []
    ) {
        self.gr = gr
        self.bs = bs
        self.cs = cs
        self.catv = catv
        self.sky = sky
        self.bs4k = bs4k
    }

    private enum CodingKeys: String, CodingKey {
        case gr = "GR"
        case bs = "BS"
        case cs = "CS"
        case catv = "CATV"
        case sky = "SKY"
        case bs4k = "BS4K"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gr = container.lenient([LiveChannel].self, forKey: .gr) ?? []
        bs = container.lenient([LiveChannel].self, forKey: .bs) ?? []
        cs = container.lenient([LiveChannel].self, forKey: .cs) ?? []
        catv = container.lenient([LiveChannel].self, forKey: .catv) ?? []
        sky = container.lenient([LiveChannel].self, forKey: .sky) ?? []
        bs4k = container.lenient([LiveChannel].self, forKey: .bs4k) ?? []
    }

    public subscript(type: ChannelType) -> [LiveChannel] {
        switch type {
        case .gr: return gr
        case .bs: return bs
        case .cs: return cs
        case .catv: return catv
        case .sky: return sky
        case .bs4k: return bs4k
        }
    }

    public func channels(for type: ChannelType) -> [LiveChannel] {
        self[type]
    }

    public var allChannels: [LiveChannel] {
        gr + bs + cs + catv + sky + bs4k
    }

    public var isEmpty: Bool {
        allChannels.isEmpty
    }

    /// Non-empty channel groups in display order: GR, BS, CS, CATV, SKY, BS4K.
    public func nonEmptyGroups() -> [(type: ChannelType, channels: [LiveChannel])] {
        ChannelType.allCases.compactMap { type in
            let channels = self[type]
            guard !channels.isEmpty else { return nil }
            return (type, channels)
        }
    }
}

// MARK: - Recorded video / program

/// A CM (commercial) section of a recorded video, in seconds.
public struct CMSection: Codable, Sendable, Hashable {
    public var startTime: Double
    public var endTime: Double

    public init(startTime: Double = 0, endTime: Double = 0) {
        self.startTime = startTime
        self.endTime = endTime
    }

    private enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startTime = container.lenient(Double.self, forKey: .startTime) ?? 0
        endTime = container.lenient(Double.self, forKey: .endTime) ?? 0
    }
}

/// Representative thumbnail image information.
public struct ThumbnailImageInfo: Codable, Sendable, Hashable {
    public var format: String
    public var width: Int
    public var height: Int
    /// Monotonically increasing revision, appended to the thumbnail URL as a
    /// cache buster.
    public var revision: Int

    public init(format: String = "", width: Int = 0, height: Int = 0, revision: Int = 0) {
        self.format = format
        self.width = width
        self.height = height
        self.revision = revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = container.lenient(String.self, forKey: .format) ?? ""
        width = container.lenient(Int.self, forKey: .width) ?? 0
        height = container.lenient(Int.self, forKey: .height) ?? 0
        revision = container.lenient(Int.self, forKey: .revision) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case width
        case height
        case revision
    }
}

/// Seek-bar tiled thumbnail information.
public struct ThumbnailTileInfo: Codable, Sendable, Hashable {
    public var format: String
    public var imageWidth: Int
    public var imageHeight: Int
    public var tileWidth: Int
    public var tileHeight: Int
    public var totalTiles: Int
    public var columnCount: Int
    public var rowCount: Int
    public var intervalSec: Double

    public init(
        format: String = "",
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        tileWidth: Int = 0,
        tileHeight: Int = 0,
        totalTiles: Int = 0,
        columnCount: Int = 0,
        rowCount: Int = 0,
        intervalSec: Double = 0
    ) {
        self.format = format
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.totalTiles = totalTiles
        self.columnCount = columnCount
        self.rowCount = rowCount
        self.intervalSec = intervalSec
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case tileWidth = "tile_width"
        case tileHeight = "tile_height"
        case totalTiles = "total_tiles"
        case columnCount = "column_count"
        case rowCount = "row_count"
        case intervalSec = "interval_sec"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = container.lenient(String.self, forKey: .format) ?? ""
        imageWidth = container.lenient(Int.self, forKey: .imageWidth) ?? 0
        imageHeight = container.lenient(Int.self, forKey: .imageHeight) ?? 0
        tileWidth = container.lenient(Int.self, forKey: .tileWidth) ?? 0
        tileHeight = container.lenient(Int.self, forKey: .tileHeight) ?? 0
        totalTiles = container.lenient(Int.self, forKey: .totalTiles) ?? 0
        columnCount = container.lenient(Int.self, forKey: .columnCount) ?? 0
        rowCount = container.lenient(Int.self, forKey: .rowCount) ?? 0
        intervalSec = container.lenient(Double.self, forKey: .intervalSec) ?? 0
    }
}

/// Thumbnail information of a recorded video.
public struct ThumbnailInfo: Codable, Sendable, Hashable {
    public var version: Int
    public var representative: ThumbnailImageInfo?
    public var tile: ThumbnailTileInfo?

    public init(
        version: Int = 0,
        representative: ThumbnailImageInfo? = nil,
        tile: ThumbnailTileInfo? = nil
    ) {
        self.version = version
        self.representative = representative
        self.tile = tile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = container.lenient(Int.self, forKey: .version) ?? 0
        representative = container.lenient(ThumbnailImageInfo.self, forKey: .representative)
        tile = container.lenient(ThumbnailTileInfo.self, forKey: .tile)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case representative
        case tile
    }
}

public struct RecordedVideo: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var status: String
    public var duration: Double
    public var videoResolutionWidth: Int
    public var videoResolutionHeight: Int
    public var videoCodec: String
    public var fileSize: Int?
    public var containerFormat: String?
    public var videoFrameRate: Double?
    public var primaryAudioCodec: String?
    public var primaryAudioChannel: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    // Fields shown in the web client's "録画ファイル情報" dialog.
    public var filePath: String?
    public var fileHash: String?
    public var fileCreatedAt: Date?
    public var fileModifiedAt: Date?
    public var recordingStartTime: Date?
    public var recordingEndTime: Date?
    public var videoCodecProfile: String?
    public var videoScanType: String?
    public var hasVideoStreamChanges: Bool
    public var primaryAudioSamplingRate: Int?
    public var secondaryAudioCodec: String?
    public var secondaryAudioChannel: String?
    public var secondaryAudioSamplingRate: Int?
    public var cmSections: [CMSection]?
    public var thumbnailInfo: ThumbnailInfo?

    public init(
        id: Int = -1,
        status: String = "",
        duration: Double = 0,
        videoResolutionWidth: Int = 0,
        videoResolutionHeight: Int = 0,
        videoCodec: String = "",
        fileSize: Int? = nil,
        containerFormat: String? = nil,
        videoFrameRate: Double? = nil,
        primaryAudioCodec: String? = nil,
        primaryAudioChannel: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        filePath: String? = nil,
        fileHash: String? = nil,
        fileCreatedAt: Date? = nil,
        fileModifiedAt: Date? = nil,
        recordingStartTime: Date? = nil,
        recordingEndTime: Date? = nil,
        videoCodecProfile: String? = nil,
        videoScanType: String? = nil,
        hasVideoStreamChanges: Bool = false,
        primaryAudioSamplingRate: Int? = nil,
        secondaryAudioCodec: String? = nil,
        secondaryAudioChannel: String? = nil,
        secondaryAudioSamplingRate: Int? = nil,
        cmSections: [CMSection]? = nil,
        thumbnailInfo: ThumbnailInfo? = nil
    ) {
        self.id = id
        self.status = status
        self.duration = duration
        self.videoResolutionWidth = videoResolutionWidth
        self.videoResolutionHeight = videoResolutionHeight
        self.videoCodec = videoCodec
        self.fileSize = fileSize
        self.containerFormat = containerFormat
        self.videoFrameRate = videoFrameRate
        self.primaryAudioCodec = primaryAudioCodec
        self.primaryAudioChannel = primaryAudioChannel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.filePath = filePath
        self.fileHash = fileHash
        self.fileCreatedAt = fileCreatedAt
        self.fileModifiedAt = fileModifiedAt
        self.recordingStartTime = recordingStartTime
        self.recordingEndTime = recordingEndTime
        self.videoCodecProfile = videoCodecProfile
        self.videoScanType = videoScanType
        self.hasVideoStreamChanges = hasVideoStreamChanges
        self.primaryAudioSamplingRate = primaryAudioSamplingRate
        self.secondaryAudioCodec = secondaryAudioCodec
        self.secondaryAudioChannel = secondaryAudioChannel
        self.secondaryAudioSamplingRate = secondaryAudioSamplingRate
        self.cmSections = cmSections
        self.thumbnailInfo = thumbnailInfo
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case duration
        case videoResolutionWidth = "video_resolution_width"
        case videoResolutionHeight = "video_resolution_height"
        case videoCodec = "video_codec"
        case fileSize = "file_size"
        case containerFormat = "container_format"
        case videoFrameRate = "video_frame_rate"
        case primaryAudioCodec = "primary_audio_codec"
        case primaryAudioChannel = "primary_audio_channel"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case filePath = "file_path"
        case fileHash = "file_hash"
        case fileCreatedAt = "file_created_at"
        case fileModifiedAt = "file_modified_at"
        case recordingStartTime = "recording_start_time"
        case recordingEndTime = "recording_end_time"
        case videoCodecProfile = "video_codec_profile"
        case videoScanType = "video_scan_type"
        case hasVideoStreamChanges = "has_video_stream_changes"
        case primaryAudioSamplingRate = "primary_audio_sampling_rate"
        case secondaryAudioCodec = "secondary_audio_codec"
        case secondaryAudioChannel = "secondary_audio_channel"
        case secondaryAudioSamplingRate = "secondary_audio_sampling_rate"
        case cmSections = "cm_sections"
        case thumbnailInfo = "thumbnail_info"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? -1
        status = container.lenient(String.self, forKey: .status) ?? ""
        duration = container.lenient(Double.self, forKey: .duration) ?? 0
        videoResolutionWidth = container.lenient(Int.self, forKey: .videoResolutionWidth) ?? 0
        videoResolutionHeight = container.lenient(Int.self, forKey: .videoResolutionHeight) ?? 0
        videoCodec = container.lenient(String.self, forKey: .videoCodec) ?? ""
        fileSize = container.lenient(Int.self, forKey: .fileSize)
        containerFormat = container.lenient(String.self, forKey: .containerFormat)
        videoFrameRate = container.lenient(Double.self, forKey: .videoFrameRate)
        primaryAudioCodec = container.lenient(String.self, forKey: .primaryAudioCodec)
        primaryAudioChannel = container.lenient(String.self, forKey: .primaryAudioChannel)
        createdAt = container.lenient(Date.self, forKey: .createdAt)
        updatedAt = container.lenient(Date.self, forKey: .updatedAt)
        filePath = container.lenient(String.self, forKey: .filePath)
        fileHash = container.lenient(String.self, forKey: .fileHash)
        fileCreatedAt = container.lenient(Date.self, forKey: .fileCreatedAt)
        fileModifiedAt = container.lenient(Date.self, forKey: .fileModifiedAt)
        recordingStartTime = container.lenient(Date.self, forKey: .recordingStartTime)
        recordingEndTime = container.lenient(Date.self, forKey: .recordingEndTime)
        videoCodecProfile = container.lenient(String.self, forKey: .videoCodecProfile)
        videoScanType = container.lenient(String.self, forKey: .videoScanType)
        hasVideoStreamChanges = container.lenient(Bool.self, forKey: .hasVideoStreamChanges) ?? false
        primaryAudioSamplingRate = container.lenient(Int.self, forKey: .primaryAudioSamplingRate)
        secondaryAudioCodec = container.lenient(String.self, forKey: .secondaryAudioCodec)
        secondaryAudioChannel = container.lenient(String.self, forKey: .secondaryAudioChannel)
        secondaryAudioSamplingRate = container.lenient(Int.self, forKey: .secondaryAudioSamplingRate)
        cmSections = container.lenient([CMSection].self, forKey: .cmSections)
        thumbnailInfo = container.lenient(ThumbnailInfo.self, forKey: .thumbnailInfo)
    }
}

public struct RecordedProgram: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var description: String
    public var startTime: Date
    public var endTime: Date
    public var duration: Double
    public var isFree: Bool
    public var genres: [Genre]
    public var channel: Channel?
    public var seriesTitle: String?
    public var episodeNumber: String?
    public var subtitle: String?
    public var recordedVideo: RecordedVideo
    public var networkID: Int?
    public var serviceID: Int?
    public var eventID: Int?
    public var createdAt: Date?
    public var updatedAt: Date?

    // Series linkage. Both are nil unless the program title could be parsed
    // and the series exists on the server.
    public var seriesID: Int?
    public var seriesBroadcastPeriodID: Int?
    public var recordingStartMargin: Double
    public var recordingEndMargin: Double
    public var isPartiallyRecorded: Bool
    public var detail: [String: String]
    public var primaryAudioType: String?
    public var primaryAudioLanguage: String?
    public var secondaryAudioType: String?
    public var secondaryAudioLanguage: String?

    public init(
        id: Int = -1,
        title: String = "",
        description: String = "",
        startTime: Date = Date(timeIntervalSince1970: 0),
        endTime: Date = Date(timeIntervalSince1970: 0),
        duration: Double = 0,
        isFree: Bool = true,
        genres: [Genre] = [],
        channel: Channel? = nil,
        seriesTitle: String? = nil,
        episodeNumber: String? = nil,
        subtitle: String? = nil,
        recordedVideo: RecordedVideo = RecordedVideo(),
        networkID: Int? = nil,
        serviceID: Int? = nil,
        eventID: Int? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        seriesID: Int? = nil,
        seriesBroadcastPeriodID: Int? = nil,
        recordingStartMargin: Double = 0,
        recordingEndMargin: Double = 0,
        isPartiallyRecorded: Bool = false,
        detail: [String: String] = [:],
        primaryAudioType: String? = nil,
        primaryAudioLanguage: String? = nil,
        secondaryAudioType: String? = nil,
        secondaryAudioLanguage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.isFree = isFree
        self.genres = genres
        self.channel = channel
        self.seriesTitle = seriesTitle
        self.episodeNumber = episodeNumber
        self.subtitle = subtitle
        self.recordedVideo = recordedVideo
        self.networkID = networkID
        self.serviceID = serviceID
        self.eventID = eventID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.seriesID = seriesID
        self.seriesBroadcastPeriodID = seriesBroadcastPeriodID
        self.recordingStartMargin = recordingStartMargin
        self.recordingEndMargin = recordingEndMargin
        self.isPartiallyRecorded = isPartiallyRecorded
        self.detail = detail
        self.primaryAudioType = primaryAudioType
        self.primaryAudioLanguage = primaryAudioLanguage
        self.secondaryAudioType = secondaryAudioType
        self.secondaryAudioLanguage = secondaryAudioLanguage
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case startTime = "start_time"
        case endTime = "end_time"
        case duration
        case isFree = "is_free"
        case genres
        case channel
        case seriesTitle = "series_title"
        case episodeNumber = "episode_number"
        case subtitle
        case recordedVideo = "recorded_video"
        case networkID = "network_id"
        case serviceID = "service_id"
        case eventID = "event_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case seriesID = "series_id"
        case seriesBroadcastPeriodID = "series_broadcast_period_id"
        case recordingStartMargin = "recording_start_margin"
        case recordingEndMargin = "recording_end_margin"
        case isPartiallyRecorded = "is_partially_recorded"
        case detail
        case primaryAudioType = "primary_audio_type"
        case primaryAudioLanguage = "primary_audio_language"
        case secondaryAudioType = "secondary_audio_type"
        case secondaryAudioLanguage = "secondary_audio_language"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? -1
        title = container.lenient(String.self, forKey: .title) ?? ""
        description = container.lenient(String.self, forKey: .description) ?? ""
        startTime = container.lenient(Date.self, forKey: .startTime) ?? Date(timeIntervalSince1970: 0)
        endTime = container.lenient(Date.self, forKey: .endTime) ?? Date(timeIntervalSince1970: 0)
        duration = container.lenient(Double.self, forKey: .duration) ?? 0
        isFree = container.lenient(Bool.self, forKey: .isFree) ?? true
        genres = container.lenient([Genre].self, forKey: .genres) ?? []
        channel = container.lenient(Channel.self, forKey: .channel)
        seriesTitle = container.lenient(String.self, forKey: .seriesTitle)
        episodeNumber = container.lenient(String.self, forKey: .episodeNumber)
        subtitle = container.lenient(String.self, forKey: .subtitle)
        recordedVideo = container.lenient(RecordedVideo.self, forKey: .recordedVideo) ?? RecordedVideo()
        networkID = container.lenient(Int.self, forKey: .networkID)
        serviceID = container.lenient(Int.self, forKey: .serviceID)
        eventID = container.lenient(Int.self, forKey: .eventID)
        createdAt = container.lenient(Date.self, forKey: .createdAt)
        updatedAt = container.lenient(Date.self, forKey: .updatedAt)
        seriesID = container.lenient(Int.self, forKey: .seriesID)
        seriesBroadcastPeriodID = container.lenient(Int.self, forKey: .seriesBroadcastPeriodID)
        recordingStartMargin = container.lenient(Double.self, forKey: .recordingStartMargin) ?? 0
        recordingEndMargin = container.lenient(Double.self, forKey: .recordingEndMargin) ?? 0
        isPartiallyRecorded = container.lenient(Bool.self, forKey: .isPartiallyRecorded) ?? false
        detail = container.lenient([String: String].self, forKey: .detail) ?? [:]
        primaryAudioType = container.lenient(String.self, forKey: .primaryAudioType)
        primaryAudioLanguage = container.lenient(String.self, forKey: .primaryAudioLanguage)
        secondaryAudioType = container.lenient(String.self, forKey: .secondaryAudioType)
        secondaryAudioLanguage = container.lenient(String.self, forKey: .secondaryAudioLanguage)
    }
}

public struct RecordedPrograms: Codable, Sendable, Hashable {
    public var total: Int
    public var recordedPrograms: [RecordedProgram]

    public init(total: Int = 0, recordedPrograms: [RecordedProgram] = []) {
        self.total = total
        self.recordedPrograms = recordedPrograms
    }

    private enum CodingKeys: String, CodingKey {
        case total
        case recordedPrograms = "recorded_programs"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = container.lenient(Int.self, forKey: .total) ?? 0
        recordedPrograms = container.lenient([RecordedProgram].self, forKey: .recordedPrograms) ?? []
    }
}

// MARK: - Server information

public struct VersionInfo: Codable, Sendable, Hashable {
    public var version: String
    public var latestVersion: String?
    public var environment: String
    public var backend: String
    public var encoder: String

    public init(
        version: String = "",
        latestVersion: String? = nil,
        environment: String = "",
        backend: String = "",
        encoder: String = ""
    ) {
        self.version = version
        self.latestVersion = latestVersion
        self.environment = environment
        self.backend = backend
        self.encoder = encoder
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case latestVersion = "latest_version"
        case environment
        case backend
        case encoder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = container.lenient(String.self, forKey: .version) ?? ""
        latestVersion = container.lenient(String.self, forKey: .latestVersion)
        environment = container.lenient(String.self, forKey: .environment) ?? ""
        backend = container.lenient(String.self, forKey: .backend) ?? ""
        encoder = container.lenient(String.self, forKey: .encoder) ?? ""
    }

    /// Whether a newer release exists, with the web client's rule
    /// (`VersionStore.is_update_available`): a release server is outdated when
    /// it differs from the latest tag, a `-dev` build when its base version
    /// equals the latest tag.
    public var isUpdateAvailable: Bool {
        guard let latestVersion, !latestVersion.isEmpty else { return false }
        if version.contains("-dev") {
            return version.replacingOccurrences(of: "-dev", with: "") == latestVersion
        }
        return version != latestVersion
    }
}

// MARK: - Users

public struct UserAccessToken: Codable, Sendable, Hashable {
    public var accessToken: String
    public var tokenType: String

    public init(accessToken: String = "", tokenType: String = "bearer") {
        self.accessToken = accessToken
        self.tokenType = tokenType
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = container.lenient(String.self, forKey: .accessToken) ?? ""
        tokenType = container.lenient(String.self, forKey: .tokenType) ?? "bearer"
    }
}

public struct User: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var isAdmin: Bool
    /// Niconico user ID, set once the user linked a Niconico account
    /// (`/api/niconico/auth`). `nil` means "not linked".
    public var niconicoUserID: Int?
    /// Niconico nickname of the linked account.
    public var niconicoUserName: String?
    /// Whether the linked account is a Niconico premium member. Premium is
    /// required to post fixed (top / bottom) and big comments to Nicolive.
    public var niconicoUserPremium: Bool?
    /// Twitter accounts linked to the user (the watch screen's Twitter tab).
    public var twitterAccounts: [TwitterAccount]
    /// Bluesky accounts linked to the user.
    public var blueskyAccounts: [BlueskyAccount]
    /// Twitter / Bluesky pairs that post and read both services together.
    public var accountLinks: [AccountLink]
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: Int = 0,
        name: String = "",
        isAdmin: Bool = false,
        niconicoUserID: Int? = nil,
        niconicoUserName: String? = nil,
        niconicoUserPremium: Bool? = nil,
        twitterAccounts: [TwitterAccount] = [],
        blueskyAccounts: [BlueskyAccount] = [],
        accountLinks: [AccountLink] = [],
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isAdmin = isAdmin
        self.niconicoUserID = niconicoUserID
        self.niconicoUserName = niconicoUserName
        self.niconicoUserPremium = niconicoUserPremium
        self.twitterAccounts = twitterAccounts
        self.blueskyAccounts = blueskyAccounts
        self.accountLinks = accountLinks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isAdmin = "is_admin"
        case niconicoUserID = "niconico_user_id"
        case niconicoUserName = "niconico_user_name"
        case niconicoUserPremium = "niconico_user_premium"
        case twitterAccounts = "twitter_accounts"
        case blueskyAccounts = "bluesky_accounts"
        case accountLinks = "account_links"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? 0
        name = container.lenient(String.self, forKey: .name) ?? ""
        isAdmin = container.lenient(Bool.self, forKey: .isAdmin) ?? false
        niconicoUserID = container.lenient(Int.self, forKey: .niconicoUserID)
        niconicoUserName = container.lenient(String.self, forKey: .niconicoUserName)
        niconicoUserPremium = container.lenient(Bool.self, forKey: .niconicoUserPremium)
        twitterAccounts = container.lenient([TwitterAccount].self, forKey: .twitterAccounts) ?? []
        blueskyAccounts = container.lenient([BlueskyAccount].self, forKey: .blueskyAccounts) ?? []
        accountLinks = container.lenient([AccountLink].self, forKey: .accountLinks) ?? []
        createdAt = container.lenient(Date.self, forKey: .createdAt)
        updatedAt = container.lenient(Date.self, forKey: .updatedAt)
    }

    /// True when a Niconico account is linked.
    public var isNiconicoLinked: Bool {
        niconicoUserID != nil
    }
}

// MARK: - Lenient decoding helper

extension KeyedDecodingContainer {
    /// Decodes a value if the key is present and the value is well-formed;
    /// otherwise returns `nil`. Used to keep the client resilient to server
    /// fields that are missing, null, or of an unexpected shape.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}
