import Foundation

// MARK: - Series

/// A broadcast period of a series: one channel and the recorded programs of the
/// series that were recorded from it.
///
/// `start_date` / `end_date` are plain dates (e.g. `"2026-10-06"`) on the wire, so
/// they are kept as strings instead of being parsed into a `Date`.
public struct SeriesBroadcastPeriod: Codable, Sendable, Hashable {
    public var channel: Channel?
    public var startDate: String
    public var endDate: String
    public var recordedPrograms: [RecordedProgram]

    public init(
        channel: Channel? = nil,
        startDate: String = "",
        endDate: String = "",
        recordedPrograms: [RecordedProgram] = []
    ) {
        self.channel = channel
        self.startDate = startDate
        self.endDate = endDate
        self.recordedPrograms = recordedPrograms
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case startDate = "start_date"
        case endDate = "end_date"
        case recordedPrograms = "recorded_programs"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = container.lenient(Channel.self, forKey: .channel)
        startDate = container.lenient(String.self, forKey: .startDate) ?? ""
        endDate = container.lenient(String.self, forKey: .endDate) ?? ""
        recordedPrograms = container.lenient([RecordedProgram].self, forKey: .recordedPrograms) ?? []
    }
}

/// A series of recorded programs, as returned by `/api/series`.
public struct Series: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var description: String
    public var genres: [Genre]
    public var broadcastPeriods: [SeriesBroadcastPeriod]
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: Int = -1,
        title: String = "",
        description: String = "",
        genres: [Genre] = [],
        broadcastPeriods: [SeriesBroadcastPeriod] = [],
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.genres = genres
        self.broadcastPeriods = broadcastPeriods
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// All recorded programs of the series, in broadcast period order.
    public var allRecordedPrograms: [RecordedProgram] {
        broadcastPeriods.flatMap(\.recordedPrograms)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case genres
        case broadcastPeriods = "broadcast_periods"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? -1
        title = container.lenient(String.self, forKey: .title) ?? ""
        description = container.lenient(String.self, forKey: .description) ?? ""
        genres = container.lenient([Genre].self, forKey: .genres) ?? []
        broadcastPeriods = container.lenient([SeriesBroadcastPeriod].self, forKey: .broadcastPeriods) ?? []
        createdAt = container.lenient(Date.self, forKey: .createdAt)
        updatedAt = container.lenient(Date.self, forKey: .updatedAt)
    }
}

/// Response of `GET /api/series` and `GET /api/series/search`.
public struct SeriesList: Codable, Sendable, Hashable {
    public var total: Int
    public var seriesList: [Series]

    public init(total: Int = 0, seriesList: [Series] = []) {
        self.total = total
        self.seriesList = seriesList
    }

    private enum CodingKeys: String, CodingKey {
        case total
        case seriesList = "series_list"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = container.lenient(Int.self, forKey: .total) ?? 0
        seriesList = container.lenient([Series].self, forKey: .seriesList) ?? []
    }
}
