import Foundation
import Observation
import KonomiKit

/// Top level navigation sections of the app.
enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case live
    case timetable
    case videos
    case mylist
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "テレビ"
        case .timetable: return "番組表"
        case .videos: return "ビデオ"
        case .mylist: return "マイリスト"
        case .history: return "視聴履歴"
        case .settings: return "設定"
        }
    }

    var systemImage: String {
        switch self {
        case .live: return "tv"
        case .timetable: return "calendar"
        case .videos: return "film.stack"
        case .mylist: return "bookmark"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// Tabs of the compact (iPhone) layout.
///
/// マイページ collects the sections that the regular width layout shows in the
/// sidebar but the tab bar has no room for.
enum CompactTab: String, CaseIterable, Hashable, Sendable {
    case live
    case videos
    case mypage

    var title: String {
        switch self {
        case .live: return "テレビ"
        case .videos: return "ビデオ"
        case .mypage: return "マイページ"
        }
    }

    var systemImage: String {
        switch self {
        case .live: return "tv"
        case .videos: return "film.stack"
        case .mypage: return "person.crop.circle"
        }
    }
}

/// A row of the compact マイページ hub, which pushes a section that has no tab
/// of its own.
enum MypageRow: String, CaseIterable, Identifiable, Hashable, Sendable {
    case timetable
    case mylist
    case history
    case settings

    var id: String { rawValue }

    var section: AppSection {
        switch self {
        case .timetable: return .timetable
        case .mylist: return .mylist
        case .history: return .history
        case .settings: return .settings
        }
    }

    var route: SectionRoute {
        switch self {
        case .timetable: return .timetable
        case .mylist: return .mylist
        case .history: return .history
        case .settings: return .settings
        }
    }

    var title: String { section.title }

    var systemImage: String { section.systemImage }
}

/// Screens a section's navigation stack can push.
///
/// The same route type is used by every section, so a screen (the timetable
/// from the TV screen, a series episode from a video detail) can push another
/// screen wherever it is shown.
enum SectionRoute: Hashable, Sendable {
    case live(LiveChannel)
    case video(RecordedProgram)
    case videoList
    case timetable
    case mylist
    case history
    case settings
    case pinnedChannels
}

/// Broadcast type (or the pinned channels) selected by the channel pickers.
enum ChannelSelection: Hashable, Sendable {
    case pinned
    case type(ChannelType)

    var title: String {
        switch self {
        case .pinned: return "ピン留め"
        case .type(let type): return type.displayName
        }
    }
}

/// `UserDefaults` keys shared by the views' `@AppStorage` properties.
enum PreferenceKeys {
    static let serverURL = "serverURL"
    /// Client settings (My List, watch history, pinned channels, ...) as JSON.
    static let clientSettings = "clientSettings"
    /// Whether the client settings are synced with the server. Local only: the
    /// web client has the same switch as a non-synced `sync_settings` key.
    static let syncSettings = "syncSettings"

    // Streaming quality profile keys, named like the web client's local-only
    // settings (they are deliberately not part of ClientSettings).
    static let tvStreamingQuality = "tv_streaming_quality"
    static let tvStreamingQualityCellular = "tv_streaming_quality_cellular"
    static let tvDataSaverMode = "tv_data_saver_mode"
    static let tvDataSaverModeCellular = "tv_data_saver_mode_cellular"
    static let tvLowLatencyMode = "tv_low_latency_mode"
    static let tvLowLatencyModeCellular = "tv_low_latency_mode_cellular"
    static let tv24fpsMode = "tv_24fps_mode"
    static let tv24fpsModeCellular = "tv_24fps_mode_cellular"

    static let videoStreamingQuality = "video_streaming_quality"
    static let videoStreamingQualityCellular = "video_streaming_quality_cellular"
    static let videoDataSaverMode = "video_data_saver_mode"
    static let videoDataSaverModeCellular = "video_data_saver_mode_cellular"
    static let video24fpsMode = "video_24fps_mode"
    static let video24fpsModeCellular = "video_24fps_mode_cellular"

    /// Keys of the quality picker that older builds stored under different
    /// names. Migrated once by `QualityPreferences.migrate`.
    static let legacyLiveQuality = "liveQuality"
    static let legacyVideoQuality = "videoQuality"
}

/// Application wide state: configured server, session user, client settings and
/// navigation.
@MainActor
@Observable
final class AppModel {
    private(set) var serverURL: URL?
    private(set) var version: VersionInfo?
    private(set) var user: User?
    private(set) var token: String?

    /// Section shown by the regular width sidebar.
    var section: AppSection = .live
    /// Tab shown by the compact width tab bar.
    var compactTab: CompactTab = .live

    /// Navigation paths, so picture in picture restore (and anything else) can
    /// open a screen programmatically.
    var livePath: [SectionRoute] = []
    var videosPath: [SectionRoute] = []
    var mylistPath: [SectionRoute] = []
    var historyPath: [SectionRoute] = []
    var timetablePath: [SectionRoute] = []
    var settingsPath: [SectionRoute] = []
    /// Path of the compact マイページ hub.
    var mypagePath: [SectionRoute] = []

    /// Client settings (My List, watch history, pinned channels and the other
    /// typed keys). Persisted locally; synced with the server when logged in and
    /// `syncSettings` is on.
    private(set) var settings = ClientSettings()

    /// Whether settings are synced with the server. Local only, like the web
    /// client's `sync_settings` key.
    private(set) var syncSettings = true

    /// UI tests replace the system `ASWebAuthenticationSession` sheet with a
    /// plain URLSession round trip (`-UITestingDisableASWebAuth`).
    let disablesASWebAuthentication: Bool

    /// Recorded programs deleted in this session, so lists can drop them without
    /// waiting for a reload.
    private(set) var deletedVideoIDs: Set<Int> = []

    /// App-wide playback. Owned here so it survives view transitions.
    let playback = PlaybackController()

    /// App-wide network path monitor: playback starts with the cellular
    /// quality profile when the device is on a cellular connection.
    let networkMonitor = NetworkMonitor()

    @ObservationIgnored private let defaults: UserDefaults
    /// Seconds of continuous playback before a video enters the watch history.
    @ObservationIgnored private let watchedHistoryThresholdSeconds: Double
    /// Seconds between position updates of an existing history entry.
    @ObservationIgnored private let watchedHistoryUpdateIntervalSeconds: Double = 10
    @ObservationIgnored private var pendingSettingsUpload: Task<Void, Never>?

    // Watch history bookkeeping for the video that is currently playing.
    @ObservationIgnored private var watchedVideoID: Int?
    @ObservationIgnored private var watchedStartedAt: Date?
    @ObservationIgnored private var hasRecordedWatchedHistory = false
    @ObservationIgnored private var watchedLastUpdateAt: Date?

    init(defaults: UserDefaults = .standard, options: LaunchOptions = LaunchOptions()) {
        self.defaults = defaults
        self.disablesASWebAuthentication = options.disablesASWebAuthentication
        self.watchedHistoryThresholdSeconds = options.usesShortWatchedHistoryThreshold ? 2 : 30

        if let raw = defaults.string(forKey: PreferenceKeys.serverURL),
           let url = try? ServerURL(validating: raw).url {
            self.serverURL = url
        }
        self.token = KeychainStore.read(account: KeychainStore.tokenAccount)

        if let json = defaults.string(forKey: PreferenceKeys.clientSettings),
           let loaded = try? ClientSettings(json: json) {
            self.settings = loaded
        }
        if defaults.object(forKey: PreferenceKeys.syncSettings) != nil {
            self.syncSettings = defaults.bool(forKey: PreferenceKeys.syncSettings)
        }

        playback.onRestore = { [weak self] item in
            self?.restore(item)
        }
        playback.onVideoProgress = { [weak self] video, position in
            self?.handleVideoProgress(video: video, position: position)
        }
        playback.onVideoPlaybackStopped = { [weak self] video, position in
            self?.finishVideoProgress(video: video, position: position)
        }
    }

    /// Brings the screen that owns `item` back to the front, used when the
    /// user taps the picture-in-picture restore button.
    func restore(_ item: PlaybackItem) {
        switch item {
        case .video(let video):
            section = .videos
            compactTab = .videos
            mypagePath = []
            videosPath = [.video(video)]
        case .live(let channel):
            section = .live
            compactTab = .live
            mypagePath = []
            livePath = [.live(channel)]
        }
    }

    var isConfigured: Bool { serverURL != nil }

    var serverURLString: String { serverURL?.absoluteString ?? "" }

    /// Client for the configured server, including the bearer token when the
    /// user is logged in.
    var client: APIClient? {
        guard let serverURL else { return nil }
        return APIClient(baseURL: serverURL, token: token)
    }

    // MARK: - Server

    /// Validates the URL, probes `/api/version` and stores the server on
    /// success.
    func connect(rawURL: String) async throws {
        let url = try ServerURL(validating: rawURL).url
        let probe = APIClient(baseURL: url, token: token)
        let info = try await probe.version()
        serverURL = url
        version = info
        defaults.set(url.absoluteString, forKey: PreferenceKeys.serverURL)
    }

    func refreshVersion() async {
        guard let client else { return }
        version = try? await client.version()
    }

    func disconnect() {
        logout()
        defaults.removeObject(forKey: PreferenceKeys.serverURL)
        serverURL = nil
        version = nil
        resetNavigation()
    }

    private func resetNavigation() {
        section = .live
        compactTab = .live
        livePath = []
        videosPath = []
        mylistPath = []
        historyPath = []
        timetablePath = []
        settingsPath = []
        mypagePath = []
    }

    // MARK: - Session

    /// Restores the saved version information and, when a token is present,
    /// the logged in user, then syncs the client settings.
    func restoreSession() async {
        guard let client else { return }
        if version == nil {
            version = try? await client.version()
        }
        if user == nil, let token, !token.isEmpty {
            user = try? await client.withToken(token).me()
        }
        if user != nil {
            await syncSettingsFromServer()
        }
    }

    func login(username: String, password: String) async throws {
        guard let client else { throw APIError.invalidServerURL }
        let result = try await client.login(username: username, password: password)
        guard !result.accessToken.isEmpty else { throw APIError.invalidResponse }

        token = result.accessToken
        KeychainStore.save(result.accessToken, account: KeychainStore.tokenAccount)
        user = try await client.withToken(result.accessToken).me()
        await syncSettingsFromServer()
    }

    /// Reloads `/api/users/me`, e.g. after linking or unlinking a Niconico
    /// account.
    func refreshUser() async {
        guard let token, !token.isEmpty, let client else { return }
        if let refreshed = try? await client.withToken(token).me() {
            user = refreshed
        }
    }

    /// Adds a Niconico user ID to the mute list (comment context menu).
    func addMutedNiconicoUser(_ userID: String) {
        guard !userID.isEmpty else { return }
        mutateSettings { settings in
            guard !settings.mutedNiconicoUserIDs.contains(userID) else { return }
            settings.mutedNiconicoUserIDs.append(userID)
        }
    }

    func logout() {
        pendingSettingsUpload?.cancel()
        pendingSettingsUpload = nil
        token = nil
        user = nil
        KeychainStore.delete(account: KeychainStore.tokenAccount)
    }

    // MARK: - Client settings

    /// Applies a local change, persists it and schedules the (debounced)
    /// upload when settings are synced.
    func mutateSettings(_ body: (inout ClientSettings) -> Void) {
        var updated = settings
        body(&updated)
        guard updated != settings else { return }
        settings = updated
        persistSettings()
        scheduleSettingsUpload()
    }

    /// Turns settings syncing on or off (local only).
    func setSyncSettings(_ enabled: Bool) {
        guard enabled != syncSettings else { return }
        syncSettings = enabled
        defaults.set(enabled, forKey: PreferenceKeys.syncSettings)
        guard enabled else {
            pendingSettingsUpload?.cancel()
            pendingSettingsUpload = nil
            return
        }
        Task { await self.syncSettingsFromServer() }
    }

    private func persistSettings() {
        guard let data = try? JSONCoding.encode(settings) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: PreferenceKeys.clientSettings)
    }

    /// Uploads the settings after a short debounce, so a burst of changes
    /// (toggling several switches) becomes one PUT.
    private func scheduleSettingsUpload() {
        guard syncSettings, token != nil else { return }
        pendingSettingsUpload?.cancel()
        pendingSettingsUpload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await self?.uploadSettings()
        }
    }

    /// Pushes the local settings to the server. Failures keep the local copy.
    func uploadSettings() async {
        guard syncSettings, token != nil, let client else { return }

        var payload = settings
        payload.lastSyncedAt = ClientSettingsRules.nextLastSyncedAt(
            now: Date().timeIntervalSince1970,
            serverLastSyncedAt: settings.lastSyncedAt
        )

        do {
            try await client.updateClientSettings(payload)
        } catch {
            return
        }

        // Only a successful upload advances the local sync timestamp.
        settings.lastSyncedAt = payload.lastSyncedAt
        persistSettings()
    }

    /// Pulls the server settings (or uploads the local ones when they are the
    /// newer copy). Silently keeps the local copy on failure.
    func syncSettingsFromServer() async {
        guard syncSettings, token != nil, let client else { return }
        guard let server = try? await client.clientSettings() else { return }

        switch ClientSettingsRules.syncDirection(
            localLastSyncedAt: settings.lastSyncedAt,
            serverLastSyncedAt: server.lastSyncedAt
        ) {
        case .server:
            guard server != settings else { return }
            settings = server
            persistSettings()
        case .local:
            await uploadSettings()
        }
    }

    // MARK: - My List

    /// IDs of the My List entries that point at recorded programs, newest
    /// added first (like the web client's マイリスト).
    var mylistVideoIDs: [Int] {
        settings.mylist
            .filter { $0.type == .recordedProgram }
            .sorted { $0.createdAt > $1.createdAt }
            .map(\.id)
    }

    func isInMylist(videoID: Int) -> Bool {
        settings.isInMylist(type: .recordedProgram, id: videoID)
    }

    /// Adds or removes the video and returns the new membership.
    @discardableResult
    func toggleMylist(videoID: Int) -> Bool {
        var isMember = false
        mutateSettings { settings in
            isMember = settings.toggleMylistItem(
                type: .recordedProgram,
                id: videoID,
                now: Date().timeIntervalSince1970
            )
        }
        return isMember
    }

    func removeFromMylist(videoID: Int) {
        mutateSettings { settings in
            settings.removeMylistItem(type: .recordedProgram, id: videoID)
        }
    }

    // MARK: - Watch history

    /// IDs of the watch history, last watched first.
    var historyVideoIDs: [Int] {
        settings.watchedHistory
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.videoID)
    }

    func watchedHistoryEntry(videoID: Int) -> WatchedHistoryItem? {
        settings.watchedHistoryEntry(videoID: videoID)
    }

    /// Where playback of `video` should start: the last position of its watch
    /// history entry, unless there is none or it is effectively the end.
    func resumePosition(for video: RecordedProgram) -> Double {
        guard let entry = watchedHistoryEntry(videoID: video.id) else { return 0 }
        guard entry.lastPlaybackPosition >= 1 else { return 0 }
        let limit = max(video.duration - 10, 0)
        return min(entry.lastPlaybackPosition, limit)
    }

    func removeWatchedHistory(videoID: Int) {
        mutateSettings { settings in
            settings.removeWatchedHistory(videoID: videoID)
        }
    }

    private func recordWatched(videoID: Int, position: Double) {
        let now = Date().timeIntervalSince1970
        mutateSettings { settings in
            settings.recordWatchedHistory(
                videoID: videoID,
                position: max(position, 0),
                now: now
            )
        }
    }

    /// Called for every playback position tick: adds the entry after the
    /// threshold (the web client's WATCHED_HISTORY_THRESHOLD_SECONDS) and
    /// updates it every WATCHED_HISTORY_UPDATE_INTERVAL seconds.
    func handleVideoProgress(video: RecordedProgram, position: Double) {
        if watchedVideoID != video.id {
            watchedVideoID = video.id
            watchedStartedAt = Date()
            hasRecordedWatchedHistory = false
            watchedLastUpdateAt = nil
        }

        guard let startedAt = watchedStartedAt else { return }

        if !hasRecordedWatchedHistory {
            guard Date().timeIntervalSince(startedAt) >= watchedHistoryThresholdSeconds else {
                return
            }
            hasRecordedWatchedHistory = true
            watchedLastUpdateAt = Date()
            recordWatched(videoID: video.id, position: position)
            return
        }

        guard let lastUpdate = watchedLastUpdateAt,
              Date().timeIntervalSince(lastUpdate) >= watchedHistoryUpdateIntervalSeconds else {
            return
        }
        watchedLastUpdateAt = Date()
        recordWatched(videoID: video.id, position: position)
    }

    /// Called when playback stops: stores the final position once and resets
    /// the bookkeeping.
    func finishVideoProgress(video: RecordedProgram, position: Double) {
        if watchedVideoID == video.id, hasRecordedWatchedHistory, position > 0 {
            recordWatched(videoID: video.id, position: position)
        }
        watchedVideoID = nil
        watchedStartedAt = nil
        hasRecordedWatchedHistory = false
        watchedLastUpdateAt = nil
    }

    // MARK: - Pinned channels

    var pinnedChannelIDs: [String] { settings.pinnedChannelIDs }

    func isPinned(_ channel: LiveChannel) -> Bool {
        settings.pinnedChannelIDs.contains(channel.id)
    }

    func togglePin(_ channel: LiveChannel) {
        mutateSettings { settings in
            var ids = settings.pinnedChannelIDs
            if let index = ids.firstIndex(of: channel.id) {
                ids.remove(at: index)
            } else {
                ids.append(channel.id)
            }
            settings.pinnedChannelIDs = ids
        }
    }

    func removePinnedChannel(id: String) {
        mutateSettings { settings in
            settings.pinnedChannelIDs = settings.pinnedChannelIDs.filter { $0 != id }
        }
    }

    /// Reorders the pinned channels, matching `List.onMove` semantics.
    func movePinnedChannels(fromOffsets source: IndexSet, toOffset destination: Int) {
        mutateSettings { settings in
            var ids = settings.pinnedChannelIDs
            let moving = source.sorted().compactMap { index in
                ids.indices.contains(index) ? ids[index] : nil
            }
            for index in source.sorted(by: >) where ids.indices.contains(index) {
                ids.remove(at: index)
            }
            let removedBefore = source.filter { $0 < destination }.count
            let insertAt = min(max(destination - removedBefore, 0), ids.count)
            ids.insert(contentsOf: moving, at: insertAt)
            settings.pinnedChannelIDs = ids
        }
    }

    /// The pinned channels of a channel list, in the user's order.
    func pinnedChannels(in channels: LiveChannels) -> [LiveChannel] {
        let all = channels.allChannels
        return settings.pinnedChannelIDs.compactMap { id in
            all.first { $0.id == id } ?? all.first { $0.displayChannelID == id }
        }
    }

    /// Sorts channels by jikkyo momentum when `tv_channel_sort_by_jikkyo_force`
    /// is on (unknown momentum last, channel order otherwise).
    func sortedChannels(_ channels: [LiveChannel]) -> [LiveChannel] {
        guard settings.tvChannelSortByJikkyoForce else { return channels }
        return channels.enumerated()
            .sorted { left, right in
                switch (left.element.jikkyoForce, right.element.jikkyoForce) {
                case let (leftForce?, rightForce?):
                    if leftForce != rightForce {
                        return leftForce > rightForce
                    }
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                case (nil, nil):
                    break
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    // MARK: - Recorded programs

    func markVideoDeleted(id: Int) {
        deletedVideoIDs.insert(id)
    }

    func isVideoDeleted(id: Int) -> Bool {
        deletedVideoIDs.contains(id)
    }
}
