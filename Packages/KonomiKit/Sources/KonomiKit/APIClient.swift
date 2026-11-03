import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstraction over URLSession so API behaviour can be tested without a
/// network. Implementations must be safe to call from any task.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport backed by `URLSession.shared`.
public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return (data, httpResponse)
    }
}

/// Sort order accepted by the recorded program / series list endpoints.
///
/// `ids` is only used with the `ids` query parameter of `/api/videos`, where it
/// tells the server to keep the requested order.
public enum VideoListOrder: String, Codable, CaseIterable, Sendable, Hashable {
    case desc
    case asc
    case ids
}

/// Async client for the KonomiTV HTTP API.
public struct APIClient: Sendable {
    public let baseURL: URL
    public let token: String?
    private let transport: any HTTPTransport

    public init(
        baseURL: URL,
        transport: any HTTPTransport = URLSessionTransport(),
        token: String? = nil
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.token = token
    }

    /// Returns a copy of the client with a different bearer token.
    public func withToken(_ token: String?) -> APIClient {
        APIClient(baseURL: baseURL, transport: transport, token: token)
    }

    // MARK: - Basic API

    public func version() async throws -> VersionInfo {
        try await perform(makeRequest(path: ["version"]), as: VersionInfo.self)
    }

    public func channels() async throws -> LiveChannels {
        try await perform(makeRequest(path: ["channels"]), as: LiveChannels.self)
    }

    public func videos(page: Int = 1, order: VideoListOrder = .desc) async throws -> RecordedPrograms {
        let request = makeRequest(
            path: ["videos"],
            query: [
                URLQueryItem(name: "order", value: order.rawValue),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
        return try await perform(request, as: RecordedPrograms.self)
    }

    /// Recorded programs for the given IDs, in the order requested.
    ///
    /// Used for My List and the watch history, which store IDs rather than
    /// programs. Sends `GET /api/videos?ids=1&ids=2&...&order=ids`.
    public func videos(ids: [Int], page: Int = 1) async throws -> RecordedPrograms {
        // An empty list would be sent as "no ids filter", which the server answers
        // with every recorded program; an empty My List must stay empty.
        guard !ids.isEmpty else {
            return RecordedPrograms(total: 0, recordedPrograms: [])
        }
        let request = makeRequest(
            path: ["videos"],
            query: {
                var query = ids.map { URLQueryItem(name: "ids", value: String($0)) }
                query.append(URLQueryItem(name: "order", value: VideoListOrder.ids.rawValue))
                query.append(URLQueryItem(name: "page", value: String(max(page, 1))))
                return query
            }()
        )
        return try await perform(request, as: RecordedPrograms.self)
    }

    public func searchVideos(
        query: String,
        page: Int = 1,
        order: VideoListOrder = .desc
    ) async throws -> RecordedPrograms {
        let request = makeRequest(
            path: ["videos", "search"],
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "order", value: order.rawValue),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
        return try await perform(request, as: RecordedPrograms.self)
    }

    public func video(id: Int) async throws -> RecordedProgram {
        try await perform(makeRequest(path: ["videos", String(id)]), as: RecordedProgram.self)
    }

    /// Deletes a recorded program and its file (`DELETE /api/videos/{id}`).
    ///
    /// Requires an admin account on the server.
    public func deleteVideo(id: Int) async throws {
        let request = makeRequest(path: ["videos", String(id)], method: "DELETE")
        _ = try await sendRaw(request)
    }

    /// Re-analyzes the metadata of a recorded program
    /// (`POST /api/videos/{id}/reanalyze`). Requires an admin account.
    public func reanalyzeVideo(id: Int) async throws {
        let request = makeRequest(path: ["videos", String(id), "reanalyze"], method: "POST")
        _ = try await sendRaw(request)
    }

    /// Regenerates the thumbnails of a recorded program
    /// (`POST /api/videos/{id}/thumbnail/regenerate`). Requires an admin account.
    public func regenerateThumbnail(id: Int) async throws {
        let request = makeRequest(
            path: ["videos", String(id), "thumbnail", "regenerate"],
            method: "POST"
        )
        _ = try await sendRaw(request)
    }

    // MARK: - Series

    public func seriesList(
        page: Int = 1,
        order: VideoListOrder = .desc
    ) async throws -> SeriesList {
        let request = makeRequest(
            path: ["series"],
            query: [
                URLQueryItem(name: "order", value: order.rawValue),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
        return try await perform(request, as: SeriesList.self)
    }

    public func searchSeries(
        query: String,
        page: Int = 1,
        order: VideoListOrder = .desc
    ) async throws -> SeriesList {
        let request = makeRequest(
            path: ["series", "search"],
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "order", value: order.rawValue),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
        return try await perform(request, as: SeriesList.self)
    }

    public func series(id: Int) async throws -> Series {
        try await perform(makeRequest(path: ["series", String(id)]), as: Series.self)
    }

    // MARK: - Programs

    /// Searches the EPG with a program search condition.
    ///
    /// The server exposes this as `POST /api/programs/search` with the condition
    /// as the JSON body (see `ProgramsRouter.ProgramSearchAPI`); the web client
    /// calls it the same way.
    public func searchPrograms(_ condition: ProgramSearchCondition) async throws -> Programs {
        let body: Data
        do {
            body = try JSONCoding.encode(condition)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
        let request = makeRequest(
            path: ["programs", "search"],
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        return try await perform(request, as: Programs.self)
    }

    /// Programs of every channel (or of one channel type / of the pinned
    /// channels) in the given time range.
    ///
    /// `pinnedChannelIDs` takes precedence over `channelType` on the server, and
    /// also fixes the column order.
    public func timetable(
        startTime: Date,
        endTime: Date,
        channelType: ChannelType? = nil,
        pinnedChannelIDs: [String] = []
    ) async throws -> TimeTable {
        let request = makeRequest(
            path: ["programs", "timetable"],
            query: {
                var query: [URLQueryItem] = [
                    URLQueryItem(
                        name: "start_time",
                        value: JSONCoding.formatQueryDateTime(startTime)
                    ),
                    URLQueryItem(
                        name: "end_time",
                        value: JSONCoding.formatQueryDateTime(endTime)
                    ),
                ]
                if let channelType {
                    query.append(
                        URLQueryItem(name: "channel_type", value: channelType.rawValue)
                    )
                }
                if !pinnedChannelIDs.isEmpty {
                    query.append(
                        URLQueryItem(
                            name: "pinned_channel_ids",
                            value: pinnedChannelIDs.joined(separator: ",")
                        )
                    )
                }
                return query
            }()
        )
        return try await perform(request, as: TimeTable.self)
    }

    // MARK: - Client settings

    /// The client settings stored for the logged in user.
    ///
    /// Unknown keys are preserved in `ClientSettings.values`, so feeding the
    /// result back into `updateClientSettings` never drops other clients'
    /// settings.
    public func clientSettings() async throws -> ClientSettings {
        try await perform(makeRequest(path: ["settings", "client"]), as: ClientSettings.self)
    }

    /// Stores the client settings (`PUT /api/settings/client`).
    ///
    /// The server answers 422 when `last_synced_at` is older than the stored
    /// value; use `ClientSettingsRules.nextLastSyncedAt(now:serverLastSyncedAt:)`
    /// to build a timestamp that cannot be rejected.
    public func updateClientSettings(_ settings: ClientSettings) async throws {
        let body: Data
        do {
            body = try JSONCoding.encode(settings)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
        let request = makeRequest(
            path: ["settings", "client"],
            method: "PUT",
            body: body,
            contentType: "application/json"
        )
        _ = try await sendRaw(request)
    }

    // MARK: - Users

    public func login(username: String, password: String) async throws -> UserAccessToken {
        let body = "username=\(Self.formEncode(username))&password=\(Self.formEncode(password))"
        let request = makeRequest(
            path: ["users", "token"],
            method: "POST",
            body: Data(body.utf8),
            contentType: "application/x-www-form-urlencoded",
            authorized: false
        )
        return try await perform(request, as: UserAccessToken.self)
    }

    public func me() async throws -> User {
        try await perform(makeRequest(path: ["users", "me"]), as: User.self)
    }

    // MARK: - Recorded playback

    /// Keeps a recorded-playback session alive (`PUT .../keep-alive`).
    public func keepAlive(
        videoID: Int,
        profile: StreamingProfile,
        sessionID: String
    ) async throws {
        let request = makeRequest(
            path: [
                "streams", "video", String(videoID),
                profile.apiQuality(), "keep-alive",
            ],
            query: [URLQueryItem(name: "session_id", value: sessionID)],
            method: "PUT"
        )
        _ = try await sendRaw(request)
    }

    /// Convenience overload for callers that only pick a base quality.
    public func keepAlive(
        videoID: Int,
        quality: StreamQuality,
        sessionID: String
    ) async throws {
        try await keepAlive(
            videoID: videoID,
            profile: StreamingProfile(quality: quality.videoSafe),
            sessionID: sessionID
        )
    }

    // MARK: - URL builders

    public func logoURL(channelID: String) -> URL {
        Endpoints.logo(baseURL: baseURL, channelID: channelID)
    }

    public func thumbnailURL(videoID: Int) -> URL {
        Endpoints.thumbnail(baseURL: baseURL, videoID: videoID)
    }

    /// Download URL of a recorded program's file (`GET /api/videos/{id}/download`).
    public func videoDownloadURL(id: Int) -> URL {
        Endpoints.videoDownload(baseURL: baseURL, id: id)
    }

    /// Recorded-video HLS playlist URL.
    ///
    /// The default `playlistType` is `master`, whose `EXT-X-MEDIA` audio
    /// group exposes 主音声 / 副音声 to AVPlayer natively.
    public func videoPlaylistURL(
        videoID: Int,
        profile: StreamingProfile,
        sessionID: String,
        playlistType: VideoPlaylistType = .master,
        cacheKey: String? = nil
    ) -> URL {
        Endpoints.videoPlaylist(
            baseURL: baseURL,
            videoID: videoID,
            apiQuality: profile.apiQuality(),
            sessionID: sessionID,
            playlistType: playlistType,
            cacheKey: cacheKey
        )
    }

    /// Convenience overload for callers that only pick a base quality.
    public func videoPlaylistURL(
        videoID: Int,
        quality: StreamQuality,
        sessionID: String,
        playlistType: VideoPlaylistType = .master,
        cacheKey: String? = nil
    ) -> URL {
        videoPlaylistURL(
            videoID: videoID,
            profile: StreamingProfile(quality: quality.videoSafe),
            sessionID: sessionID,
            playlistType: playlistType,
            cacheKey: cacheKey
        )
    }

    /// Recorded-video HLS segment URL (normally read from the media playlist).
    public func videoSegmentURL(
        videoID: Int,
        profile: StreamingProfile,
        sessionID: String,
        sequence: Int,
        audio: AudioSelection = .primary,
        cacheKey: String? = nil
    ) -> URL {
        Endpoints.videoSegment(
            baseURL: baseURL,
            videoID: videoID,
            apiQuality: profile.apiQuality(),
            sessionID: sessionID,
            sequence: sequence,
            audio: audio,
            cacheKey: cacheKey
        )
    }

    public func videoKeepAliveURL(
        videoID: Int,
        profile: StreamingProfile,
        sessionID: String
    ) -> URL {
        Endpoints.videoKeepAlive(
            baseURL: baseURL,
            videoID: videoID,
            apiQuality: profile.apiQuality(),
            sessionID: sessionID
        )
    }

    /// Convenience overload for callers that only pick a base quality.
    public func videoKeepAliveURL(
        videoID: Int,
        quality: StreamQuality,
        sessionID: String
    ) -> URL {
        videoKeepAliveURL(
            videoID: videoID,
            profile: StreamingProfile(quality: quality.videoSafe),
            sessionID: sessionID
        )
    }

    /// Live MPEG-TS stream URL.
    public func liveStreamURL(
        displayChannelID: String,
        profile: StreamingProfile,
        isRadioChannel: Bool = false
    ) -> URL {
        Endpoints.liveStream(
            baseURL: baseURL,
            displayChannelID: displayChannelID,
            apiQuality: profile.apiQuality(isRadioChannel: isRadioChannel)
        )
    }

    /// Convenience overload for callers that only pick a base quality.
    public func liveStreamURL(
        displayChannelID: String,
        quality: StreamQuality,
        isRadioChannel: Bool = false
    ) -> URL {
        liveStreamURL(
            displayChannelID: displayChannelID,
            profile: StreamingProfile(quality: quality),
            isRadioChannel: isRadioChannel
        )
    }

    /// Live stream event stream (Server-Sent Events) URL.
    ///
    /// Read it with `URLSession.bytes(for:)` and feed the bytes to
    /// `ServerSentEventParser`; `LiveStreamEvent.decode(_:)` turns each event
    /// into a model.
    public func liveEventsURL(
        displayChannelID: String,
        profile: StreamingProfile,
        isRadioChannel: Bool = false
    ) -> URL {
        Endpoints.liveEvents(
            baseURL: baseURL,
            displayChannelID: displayChannelID,
            apiQuality: profile.apiQuality(isRadioChannel: isRadioChannel)
        )
    }

    /// Convenience overload for callers that only pick a base quality.
    public func liveEventsURL(
        displayChannelID: String,
        quality: StreamQuality,
        isRadioChannel: Bool = false
    ) -> URL {
        liveEventsURL(
            displayChannelID: displayChannelID,
            profile: StreamingProfile(quality: quality),
            isRadioChannel: isRadioChannel
        )
    }

    // MARK: - Requests

    private func makeRequest(
        path: [String],
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        authorized: Bool = true
    ) -> URLRequest {
        let url = Endpoints.url(baseURL: baseURL, path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if authorized, let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    @discardableResult
    private func sendRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.send(request)
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw APIError.network(error.localizedDescription)
        } catch {
            throw APIError.network(error.localizedDescription)
        }

        let (data, response) = result
        guard (200..<300).contains(response.statusCode) else {
            let message = Self.errorDetail(from: data)
            if response.statusCode == 401 {
                throw APIError.unauthorized(message)
            }
            throw APIError.httpStatus(response.statusCode, message)
        }
        return (data, response)
    }

    private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, _) = try await sendRaw(request)
        do {
            return try JSONCoding.makeDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    /// KonomiTV (FastAPI) reports errors as `{"detail": "..."}`; validation
    /// errors use a list there, which is not useful to show, so only a string
    /// detail is returned.
    static func errorDetail(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = object["detail"] as? String,
            !detail.isEmpty
        else {
            return nil
        }
        return detail
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
