import Foundation

// MARK: - Program search

/// One channel of a program search condition (`ProgramSearchConditionService`).
public struct ProgramSearchConditionService: Codable, Sendable, Hashable {
    public var networkID: Int
    public var transportStreamID: Int
    public var serviceID: Int

    public init(networkID: Int = 0, transportStreamID: Int = 0, serviceID: Int = 0) {
        self.networkID = networkID
        self.transportStreamID = transportStreamID
        self.serviceID = serviceID
    }

    private enum CodingKeys: String, CodingKey {
        case networkID = "network_id"
        case transportStreamID = "transport_stream_id"
        case serviceID = "service_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networkID = container.lenient(Int.self, forKey: .networkID) ?? 0
        transportStreamID = container.lenient(Int.self, forKey: .transportStreamID) ?? 0
        serviceID = container.lenient(Int.self, forKey: .serviceID) ?? 0
    }
}

/// One weekday/time range of a program search condition
/// (`ProgramSearchConditionDate`).
public struct ProgramSearchConditionDate: Codable, Sendable, Hashable {
    public var startDayOfWeek: Int
    public var startHour: Int
    public var startMinute: Int
    public var endDayOfWeek: Int
    public var endHour: Int
    public var endMinute: Int

    public init(
        startDayOfWeek: Int = 0,
        startHour: Int = 0,
        startMinute: Int = 0,
        endDayOfWeek: Int = 0,
        endHour: Int = 0,
        endMinute: Int = 0
    ) {
        self.startDayOfWeek = startDayOfWeek
        self.startHour = startHour
        self.startMinute = startMinute
        self.endDayOfWeek = endDayOfWeek
        self.endHour = endHour
        self.endMinute = endMinute
    }

    private enum CodingKeys: String, CodingKey {
        case startDayOfWeek = "start_day_of_week"
        case startHour = "start_hour"
        case startMinute = "start_minute"
        case endDayOfWeek = "end_day_of_week"
        case endHour = "end_hour"
        case endMinute = "end_minute"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startDayOfWeek = container.lenient(Int.self, forKey: .startDayOfWeek) ?? 0
        startHour = container.lenient(Int.self, forKey: .startHour) ?? 0
        startMinute = container.lenient(Int.self, forKey: .startMinute) ?? 0
        endDayOfWeek = container.lenient(Int.self, forKey: .endDayOfWeek) ?? 0
        endHour = container.lenient(Int.self, forKey: .endHour) ?? 0
        endMinute = container.lenient(Int.self, forKey: .endMinute) ?? 0
    }
}

/// Broadcast type filter of a program search condition.
public enum ProgramSearchBroadcastType: String, Codable, CaseIterable, Sendable, Hashable {
    case all = "All"
    case freeOnly = "FreeOnly"
    case paidOnly = "PaidOnly"
}

/// Duplicate title check scope of a program search condition.
public enum ProgramDuplicateTitleCheckScope: String, Codable, CaseIterable, Sendable, Hashable {
    case none = "None"
    case sameChannelOnly = "SameChannelOnly"
    case allChannels = "AllChannels"
}

/// Search condition of `POST /api/programs/search`.
///
/// Mirrors `schemas.ProgramSearchCondition`; every key is always sent so the
/// server sees the same shape as it does from the web client.
public struct ProgramSearchCondition: Codable, Sendable, Hashable {
    public var isEnabled: Bool
    public var keyword: String
    public var excludeKeyword: String
    public var note: String
    public var isTitleOnly: Bool
    public var isCaseSensitive: Bool
    public var isFuzzySearchEnabled: Bool
    public var isRegexSearchEnabled: Bool
    public var serviceRanges: [ProgramSearchConditionService]?
    public var genreRanges: [Genre]?
    public var isExcludeGenreRanges: Bool
    public var dateRanges: [ProgramSearchConditionDate]?
    public var isExcludeDateRanges: Bool
    public var durationRangeMin: Int?
    public var durationRangeMax: Int?
    public var broadcastType: ProgramSearchBroadcastType
    public var duplicateTitleCheckScope: ProgramDuplicateTitleCheckScope
    public var duplicateTitleCheckPeriodDays: Int

    public init(
        isEnabled: Bool = true,
        keyword: String = "",
        excludeKeyword: String = "",
        note: String = "",
        isTitleOnly: Bool = false,
        isCaseSensitive: Bool = false,
        isFuzzySearchEnabled: Bool = false,
        isRegexSearchEnabled: Bool = false,
        serviceRanges: [ProgramSearchConditionService]? = nil,
        genreRanges: [Genre]? = nil,
        isExcludeGenreRanges: Bool = false,
        dateRanges: [ProgramSearchConditionDate]? = nil,
        isExcludeDateRanges: Bool = false,
        durationRangeMin: Int? = nil,
        durationRangeMax: Int? = nil,
        broadcastType: ProgramSearchBroadcastType = .all,
        duplicateTitleCheckScope: ProgramDuplicateTitleCheckScope = .none,
        duplicateTitleCheckPeriodDays: Int = 6
    ) {
        self.isEnabled = isEnabled
        self.keyword = keyword
        self.excludeKeyword = excludeKeyword
        self.note = note
        self.isTitleOnly = isTitleOnly
        self.isCaseSensitive = isCaseSensitive
        self.isFuzzySearchEnabled = isFuzzySearchEnabled
        self.isRegexSearchEnabled = isRegexSearchEnabled
        self.serviceRanges = serviceRanges
        self.genreRanges = genreRanges
        self.isExcludeGenreRanges = isExcludeGenreRanges
        self.dateRanges = dateRanges
        self.isExcludeDateRanges = isExcludeDateRanges
        self.durationRangeMin = durationRangeMin
        self.durationRangeMax = durationRangeMax
        self.broadcastType = broadcastType
        self.duplicateTitleCheckScope = duplicateTitleCheckScope
        self.duplicateTitleCheckPeriodDays = duplicateTitleCheckPeriodDays
    }

    /// A condition that only filters by a keyword.
    public static func keyword(_ keyword: String) -> ProgramSearchCondition {
        ProgramSearchCondition(keyword: keyword)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case keyword
        case excludeKeyword = "exclude_keyword"
        case note
        case isTitleOnly = "is_title_only"
        case isCaseSensitive = "is_case_sensitive"
        case isFuzzySearchEnabled = "is_fuzzy_search_enabled"
        case isRegexSearchEnabled = "is_regex_search_enabled"
        case serviceRanges = "service_ranges"
        case genreRanges = "genre_ranges"
        case isExcludeGenreRanges = "is_exclude_genre_ranges"
        case dateRanges = "date_ranges"
        case isExcludeDateRanges = "is_exclude_date_ranges"
        case durationRangeMin = "duration_range_min"
        case durationRangeMax = "duration_range_max"
        case broadcastType = "broadcast_type"
        case duplicateTitleCheckScope = "duplicate_title_check_scope"
        case duplicateTitleCheckPeriodDays = "duplicate_title_check_period_days"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = container.lenient(Bool.self, forKey: .isEnabled) ?? true
        keyword = container.lenient(String.self, forKey: .keyword) ?? ""
        excludeKeyword = container.lenient(String.self, forKey: .excludeKeyword) ?? ""
        note = container.lenient(String.self, forKey: .note) ?? ""
        isTitleOnly = container.lenient(Bool.self, forKey: .isTitleOnly) ?? false
        isCaseSensitive = container.lenient(Bool.self, forKey: .isCaseSensitive) ?? false
        isFuzzySearchEnabled = container.lenient(Bool.self, forKey: .isFuzzySearchEnabled) ?? false
        isRegexSearchEnabled = container.lenient(Bool.self, forKey: .isRegexSearchEnabled) ?? false
        serviceRanges = container.lenient([ProgramSearchConditionService].self, forKey: .serviceRanges)
        genreRanges = container.lenient([Genre].self, forKey: .genreRanges)
        isExcludeGenreRanges = container.lenient(Bool.self, forKey: .isExcludeGenreRanges) ?? false
        dateRanges = container.lenient([ProgramSearchConditionDate].self, forKey: .dateRanges)
        isExcludeDateRanges = container.lenient(Bool.self, forKey: .isExcludeDateRanges) ?? false
        durationRangeMin = container.lenient(Int.self, forKey: .durationRangeMin)
        durationRangeMax = container.lenient(Int.self, forKey: .durationRangeMax)
        let rawBroadcastType = container.lenient(String.self, forKey: .broadcastType) ?? ""
        broadcastType = ProgramSearchBroadcastType(rawValue: rawBroadcastType) ?? .all
        let rawScope = container.lenient(String.self, forKey: .duplicateTitleCheckScope) ?? ""
        duplicateTitleCheckScope = ProgramDuplicateTitleCheckScope(rawValue: rawScope) ?? .none
        duplicateTitleCheckPeriodDays = container.lenient(Int.self, forKey: .duplicateTitleCheckPeriodDays) ?? 6
    }

    /// Always encodes every key, writing `null` for unset ranges, exactly like the
    /// web client's request body.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(keyword, forKey: .keyword)
        try container.encode(excludeKeyword, forKey: .excludeKeyword)
        try container.encode(note, forKey: .note)
        try container.encode(isTitleOnly, forKey: .isTitleOnly)
        try container.encode(isCaseSensitive, forKey: .isCaseSensitive)
        try container.encode(isFuzzySearchEnabled, forKey: .isFuzzySearchEnabled)
        try container.encode(isRegexSearchEnabled, forKey: .isRegexSearchEnabled)
        if let serviceRanges {
            try container.encode(serviceRanges, forKey: .serviceRanges)
        } else {
            try container.encodeNil(forKey: .serviceRanges)
        }
        if let genreRanges {
            try container.encode(genreRanges, forKey: .genreRanges)
        } else {
            try container.encodeNil(forKey: .genreRanges)
        }
        try container.encode(isExcludeGenreRanges, forKey: .isExcludeGenreRanges)
        if let dateRanges {
            try container.encode(dateRanges, forKey: .dateRanges)
        } else {
            try container.encodeNil(forKey: .dateRanges)
        }
        try container.encode(isExcludeDateRanges, forKey: .isExcludeDateRanges)
        if let durationRangeMin {
            try container.encode(durationRangeMin, forKey: .durationRangeMin)
        } else {
            try container.encodeNil(forKey: .durationRangeMin)
        }
        if let durationRangeMax {
            try container.encode(durationRangeMax, forKey: .durationRangeMax)
        } else {
            try container.encodeNil(forKey: .durationRangeMax)
        }
        try container.encode(broadcastType, forKey: .broadcastType)
        try container.encode(duplicateTitleCheckScope, forKey: .duplicateTitleCheckScope)
        try container.encode(duplicateTitleCheckPeriodDays, forKey: .duplicateTitleCheckPeriodDays)
    }
}

/// Response of `POST /api/programs/search`.
public struct Programs: Codable, Sendable, Hashable {
    public var total: Int
    public var programs: [Program]

    public init(total: Int = 0, programs: [Program] = []) {
        self.total = total
        self.programs = programs
    }

    private enum CodingKeys: String, CodingKey {
        case total
        case programs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = container.lenient(Int.self, forKey: .total) ?? 0
        programs = container.lenient([Program].self, forKey: .programs) ?? []
    }
}

// MARK: - Timetable

/// Recording reservation attached to a timetable program (EDCB backend only).
public struct TimeTableProgramReservation: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable {
        case reserved = "Reserved"
        case recording = "Recording"
        case disabled = "Disabled"
    }

    public enum RecordingAvailability: String, Codable, Sendable, Hashable {
        case full = "Full"
        case partial = "Partial"
        case unavailable = "Unavailable"
    }

    public var id: Int
    public var status: Status
    public var recordingAvailability: RecordingAvailability

    public init(
        id: Int = 0,
        status: Status = .reserved,
        recordingAvailability: RecordingAvailability = .full
    ) {
        self.id = id
        self.status = status
        self.recordingAvailability = recordingAvailability
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case recordingAvailability = "recording_availability"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? 0
        let rawStatus = container.lenient(String.self, forKey: .status) ?? ""
        status = Status(rawValue: rawStatus) ?? .reserved
        let rawAvailability = container.lenient(String.self, forKey: .recordingAvailability) ?? ""
        recordingAvailability = RecordingAvailability(rawValue: rawAvailability) ?? .full
    }
}

/// A program of the timetable: `Program` plus optional reservation information.
public struct TimeTableProgram: Codable, Sendable, Hashable, Identifiable {
    public var program: Program
    public var reservation: TimeTableProgramReservation?

    public var id: String { program.id }

    public init(program: Program = Program(), reservation: TimeTableProgramReservation? = nil) {
        self.program = program
        self.reservation = reservation
    }

    private enum CodingKeys: String, CodingKey {
        case reservation
    }

    public init(from decoder: Decoder) throws {
        program = try Program(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reservation = container.lenient(TimeTableProgramReservation.self, forKey: .reservation)
    }

    public func encode(to encoder: Encoder) throws {
        try program.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reservation, forKey: .reservation)
    }
}

/// A subchannel of a timetable channel (subchannels that are not shown as an
/// independent column).
public struct TimeTableSubchannel: Codable, Sendable, Hashable {
    public var channel: Channel
    public var programs: [TimeTableProgram]

    public init(channel: Channel = Channel(), programs: [TimeTableProgram] = []) {
        self.channel = channel
        self.programs = programs
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case programs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = container.lenient(Channel.self, forKey: .channel) ?? Channel()
        programs = container.lenient([TimeTableProgram].self, forKey: .programs) ?? []
    }
}

/// One channel column of the timetable.
public struct TimeTableChannel: Codable, Sendable, Hashable, Identifiable {
    public var channel: Channel
    public var programs: [TimeTableProgram]
    public var subchannels: [TimeTableSubchannel]?

    public var id: String { channel.id }

    public init(
        channel: Channel = Channel(),
        programs: [TimeTableProgram] = [],
        subchannels: [TimeTableSubchannel]? = nil
    ) {
        self.channel = channel
        self.programs = programs
        self.subchannels = subchannels
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case programs
        case subchannels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = container.lenient(Channel.self, forKey: .channel) ?? Channel()
        programs = container.lenient([TimeTableProgram].self, forKey: .programs) ?? []
        subchannels = container.lenient([TimeTableSubchannel].self, forKey: .subchannels)
    }
}

/// Date range of the program data on the server (for the date selector).
public struct TimeTableDateRange: Codable, Sendable, Hashable {
    public var earliest: Date
    public var latest: Date

    public init(earliest: Date = Date(timeIntervalSince1970: 0), latest: Date = Date(timeIntervalSince1970: 0)) {
        self.earliest = earliest
        self.latest = latest
    }

    private enum CodingKeys: String, CodingKey {
        case earliest
        case latest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        earliest = container.lenient(Date.self, forKey: .earliest) ?? Date(timeIntervalSince1970: 0)
        latest = container.lenient(Date.self, forKey: .latest) ?? Date(timeIntervalSince1970: 0)
    }
}

/// Response of `GET /api/programs/timetable`.
public struct TimeTable: Codable, Sendable, Hashable {
    public var channels: [TimeTableChannel]
    public var dateRange: TimeTableDateRange

    public init(channels: [TimeTableChannel] = [], dateRange: TimeTableDateRange = TimeTableDateRange()) {
        self.channels = channels
        self.dateRange = dateRange
    }

    private enum CodingKeys: String, CodingKey {
        case channels
        case dateRange = "date_range"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channels = container.lenient([TimeTableChannel].self, forKey: .channels) ?? []
        dateRange = container.lenient(TimeTableDateRange.self, forKey: .dateRange) ?? TimeTableDateRange()
    }
}
