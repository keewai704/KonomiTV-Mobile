import Foundation

// MARK: - My List / watched history items

/// One entry of the web client's My List (`mylist`).
public struct MylistItem: Codable, Sendable, Hashable, Identifiable {
    /// What the entry points at.
    public enum Kind: String, Codable, CaseIterable, Sendable, Hashable {
        case series = "Series"
        case recordedProgram = "RecordedProgram"
    }

    public var type: Kind
    public var id: Int
    /// UNIX timestamp in seconds (`Utils.time()` on the web client).
    public var createdAt: Double

    public init(type: Kind = .recordedProgram, id: Int = -1, createdAt: Double = 0) {
        self.type = type
        self.id = id
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = container.lenient(String.self, forKey: .type) ?? ""
        type = Kind(rawValue: rawType) ?? .recordedProgram
        id = container.lenient(Int.self, forKey: .id) ?? -1
        createdAt = container.lenient(Double.self, forKey: .createdAt) ?? 0
    }
}

/// One entry of the web client's watch history (`watched_history`).
public struct WatchedHistoryItem: Codable, Sendable, Hashable, Identifiable {
    public var videoID: Int
    /// Last playback position in seconds.
    public var lastPlaybackPosition: Double
    /// UNIX timestamps in seconds.
    public var createdAt: Double
    public var updatedAt: Double

    public var id: Int { videoID }

    public init(
        videoID: Int = -1,
        lastPlaybackPosition: Double = 0,
        createdAt: Double = 0,
        updatedAt: Double = 0
    ) {
        self.videoID = videoID
        self.lastPlaybackPosition = lastPlaybackPosition
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
        case lastPlaybackPosition = "last_playback_position"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoID = container.lenient(Int.self, forKey: .videoID) ?? -1
        lastPlaybackPosition = container.lenient(Double.self, forKey: .lastPlaybackPosition) ?? 0
        createdAt = container.lenient(Double.self, forKey: .createdAt) ?? 0
        updatedAt = container.lenient(Double.self, forKey: .updatedAt) ?? 0
    }
}

// MARK: - Client settings

/// The current user's client settings, as stored by the server
/// (`GET`/`PUT /api/settings/client`).
///
/// The iOS client only understands a handful of the keys the web client syncs,
/// but it must never drop the keys it does not understand: the whole JSON object
/// is kept in `values` and re-encoded as-is, so a PUT from this app cannot
/// destroy settings written by other clients. Typed accessors read and write the
/// keys the app cares about.
public struct ClientSettings: Codable, Sendable, Hashable {

    /// The full settings object. Unknown keys are preserved verbatim.
    public private(set) var values: [String: JSONValue]

    public init(values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public init(json: String) throws {
        self = try JSONCoding.decode(ClientSettings.self, from: json)
    }

    // MARK: Raw access

    public subscript(key: String) -> JSONValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// Raw value for a key, if present.
    public func value(forKey key: String) -> JSONValue? {
        values[key]
    }

    /// Sets (or removes, when `value` is nil) a raw value.
    public mutating func setValue(_ value: JSONValue?, forKey key: String) {
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }

    /// Decoded typed value for a key.
    public func typedValue<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        values[key]?.decode(type)
    }

    /// Stores a typed value for a key.
    public mutating func setTypedValue<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value else {
            values.removeValue(forKey: key)
            return
        }
        values[key] = JSONValue.encode(value)
    }

    public var keys: [String] {
        values.keys.sorted()
    }

    // MARK: Typed accessors

    /// UNIX timestamp (seconds) of the last successful sync. The web client
    /// stores `Date.now() / 1000`, so this is fractional seconds.
    public var lastSyncedAt: Double {
        get { values["last_synced_at"]?.numberValue ?? 0 }
        set { values["last_synced_at"] = .number(newValue) }
    }

    /// IDs (`display_channel_id`, e.g. `gr011`) of the pinned channels, in the
    /// user's order.
    public var pinnedChannelIDs: [String] {
        get { typedValue([String].self, forKey: "pinned_channel_ids") ?? [] }
        set { setTypedValue(newValue, forKey: "pinned_channel_ids") }
    }

    public var mylist: [MylistItem] {
        get { typedValue([MylistItem].self, forKey: "mylist") ?? [] }
        set { setTypedValue(newValue, forKey: "mylist") }
    }

    public var watchedHistory: [WatchedHistoryItem] {
        get { typedValue([WatchedHistoryItem].self, forKey: "watched_history") ?? [] }
        set { setTypedValue(newValue, forKey: "watched_history") }
    }

    /// How many watch history entries are kept. The web client's default is 50.
    public var videoWatchedHistoryMaxCount: Int {
        get { values["video_watched_history_max_count"]?.intValue ?? ClientSettingsDefaults.videoWatchedHistoryMaxCount }
        set { values["video_watched_history_max_count"] = .number(Double(newValue)) }
    }

    public var tvChannelSortByJikkyoForce: Bool {
        get { values["tv_channel_sort_by_jikkyo_force"]?.boolValue ?? false }
        set { values["tv_channel_sort_by_jikkyo_force"] = .bool(newValue) }
    }

    public var use28HourClock: Bool {
        get { values["use_28hour_clock"]?.boolValue ?? false }
        set { values["use_28hour_clock"] = .bool(newValue) }
    }

    /// Dim shopping programs on the timetable. The web client's default is on.
    public var timetableDimShoppingPrograms: Bool {
        get { values["timetable_dim_shopping_programs"]?.boolValue ?? ClientSettingsDefaults.timetableDimShoppingPrograms }
        set { values["timetable_dim_shopping_programs"] = .bool(newValue) }
    }

    // MARK: My List / history mutation

    public func isInMylist(type: MylistItem.Kind, id: Int) -> Bool {
        mylist.contains { $0.type == type && $0.id == id }
    }

    public func watchedHistoryEntry(videoID: Int) -> WatchedHistoryItem? {
        watchedHistory.first { $0.videoID == videoID }
    }

    public mutating func addMylistItem(_ item: MylistItem) {
        mylist = ClientSettingsRules.addMylistItem(item, to: mylist)
    }

    public mutating func removeMylistItem(type: MylistItem.Kind, id: Int) {
        mylist = ClientSettingsRules.removeMylistItem(type: type, id: id, from: mylist)
    }

    /// Adds the item when missing, removes it when present, and returns the new
    /// list membership.
    @discardableResult
    public mutating func toggleMylistItem(type: MylistItem.Kind, id: Int, now: Double) -> Bool {
        let item = MylistItem(type: type, id: id, createdAt: now)
        mylist = ClientSettingsRules.toggleMylistItem(item, in: mylist)
        return isInMylist(type: type, id: id)
    }

    public mutating func recordWatchedHistory(videoID: Int, position: Double, now: Double) {
        watchedHistory = ClientSettingsRules.recordWatchedHistory(
            watchedHistory,
            videoID: videoID,
            position: position,
            now: now,
            maxCount: videoWatchedHistoryMaxCount
        )
    }

    public mutating func removeWatchedHistory(videoID: Int) {
        watchedHistory.removeAll { $0.videoID == videoID }
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = try container.decode([String: JSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// Web client defaults for the settings keys the iOS app reads.
public enum ClientSettingsDefaults {
    public static let lastSyncedAt: Double = 0
    public static let pinnedChannelIDs: [String] = []
    public static let mylist: [MylistItem] = []
    public static let watchedHistory: [WatchedHistoryItem] = []
    public static let videoWatchedHistoryMaxCount = 50
    public static let tvChannelSortByJikkyoForce = false
    public static let use28HourClock = false
    public static let timetableDimShoppingPrograms = true
}

// MARK: - Sync decision

/// Which side wins when the client and the server settings are compared.
public enum ClientSettingsSyncDirection: String, Sendable, Hashable {
    /// The server copy is older than this client's: keep the local settings and
    /// skip pulling (the web client logs "Server has older settings than this
    /// client. Skipping sync.").
    case local
    /// The server copy is the same age or newer: adopt the server settings.
    case server
}

// MARK: - Pure rules

/// Pure functions mirroring the web client's My List, watch history and settings
/// sync rules. No I/O so they can be unit tested directly.
public enum ClientSettingsRules {

    // MARK: My List

    public static func addMylistItem(_ item: MylistItem, to list: [MylistItem]) -> [MylistItem] {
        if list.contains(where: { $0.type == item.type && $0.id == item.id }) {
            return list
        }
        return list + [item]
    }

    public static func removeMylistItem(
        type: MylistItem.Kind,
        id: Int,
        from list: [MylistItem]
    ) -> [MylistItem] {
        list.filter { !($0.type == type && $0.id == id) }
    }

    /// Toggles membership. Adding appends (the web client pushes to the end and
    /// sorts by `created_at` when displaying).
    public static func toggleMylistItem(_ item: MylistItem, in list: [MylistItem]) -> [MylistItem] {
        if list.contains(where: { $0.type == item.type && $0.id == item.id }) {
            return removeMylistItem(type: item.type, id: item.id, from: list)
        }
        return addMylistItem(item, to: list)
    }

    // MARK: Watch history

    /// Records a playback position.
    ///
    /// - When the video already has an entry, only its position and
    ///   `updated_at` change (the entry keeps its position in the list).
    /// - Otherwise a new entry is inserted at the front, and the oldest entries
    ///   (by `created_at`, like the web client) are dropped so that at most
    ///   `maxCount` entries remain.
    public static func recordWatchedHistory(
        _ list: [WatchedHistoryItem],
        videoID: Int,
        position: Double,
        now: Double,
        maxCount: Int
    ) -> [WatchedHistoryItem] {
        var entries = list
        if let index = entries.firstIndex(where: { $0.videoID == videoID }) {
            entries[index].lastPlaybackPosition = position
            entries[index].updatedAt = now
            return entries
        }
        entries.insert(
            WatchedHistoryItem(
                videoID: videoID,
                lastPlaybackPosition: position,
                createdAt: now,
                updatedAt: now
            ),
            at: 0
        )
        return trimWatchedHistory(entries, maxCount: maxCount)
    }

    /// Keeps at most `maxCount` entries, dropping the ones with the oldest
    /// `created_at` first (matching the web client's trim rule).
    public static func trimWatchedHistory(
        _ list: [WatchedHistoryItem],
        maxCount: Int
    ) -> [WatchedHistoryItem] {
        let limit = max(maxCount, 0)
        guard list.count > limit else { return list }
        let removeCount = list.count - limit
        let removeIDs = Set(
            list.sorted { $0.createdAt < $1.createdAt }
                .prefix(removeCount)
                .map { $0.videoID }
        )
        return list.filter { !removeIDs.contains($0.videoID) }
    }

    /// The web client's `video_watched_history_max_count` is forced to at least
    /// 1 (`Math.max(1, Math.floor(value))`).
    public static func normalizedWatchedHistoryMaxCount(_ rawValue: Double?) -> Int {
        guard let rawValue, rawValue.isFinite else { return 1 }
        return max(1, Int(rawValue.rounded(.down)))
    }

    // MARK: Settings sync

    /// Decides which side wins, mirroring `syncClientSettingsFromServer()` in
    /// `SettingsStore.ts`: a server copy older than the local one is ignored,
    /// otherwise the server copy is adopted (equal timestamps also adopt the
    /// server, which is a no-op).
    public static func syncDirection(
        localLastSyncedAt: Double,
        serverLastSyncedAt: Double
    ) -> ClientSettingsSyncDirection {
        serverLastSyncedAt < localLastSyncedAt ? .local : .server
    }

    /// The server rejects a PUT whose `last_synced_at` is older than the stored
    /// one with HTTP 422 (`ClientSettingsUpdateAPI`), so an upload must never go
    /// backwards.
    public static func isUploadAccepted(
        uploadedLastSyncedAt: Double,
        serverLastSyncedAt: Double
    ) -> Bool {
        uploadedLastSyncedAt >= serverLastSyncedAt
    }

    /// `last_synced_at` to stamp on an upload. The web client uses
    /// `Date.now() / 1000` and only records the value locally once the upload
    /// succeeded; this helper makes the value strictly newer than the server copy
    /// so a rapid re-upload cannot be rejected as outdated.
    public static func nextLastSyncedAt(now: Double, serverLastSyncedAt: Double) -> Double {
        now > serverLastSyncedAt ? now : serverLastSyncedAt + 0.001
    }
}
