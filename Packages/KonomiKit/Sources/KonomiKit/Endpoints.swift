import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds KonomiTV API URLs relative to a server base URL.
enum Endpoints {

    static func url(baseURL: URL, path: [String], query: [URLQueryItem] = []) -> URL {
        var url = baseURL
        url.appendPathComponent("api")
        for component in path {
            url.appendPathComponent(component)
        }
        guard !query.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = query
        return components.url ?? url
    }

    // MARK: - Basic API

    static func version(baseURL: URL) -> URL {
        url(baseURL: baseURL, path: ["version"])
    }

    static func channels(baseURL: URL) -> URL {
        url(baseURL: baseURL, path: ["channels"])
    }

    static func videos(baseURL: URL, page: Int, order: VideoListOrder) -> URL {
        url(
            baseURL: baseURL,
            path: ["videos"],
            query: [
                URLQueryItem(name: "order", value: order.rawValue),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
    }

    /// `GET /api/videos?ids=1&ids=2&...&order=ids&page=1`
    ///
    /// FastAPI expects the `ids` list to be repeated, not comma separated, so the
    /// URL has one `ids` query item per video. `order=ids` makes the server keep
    /// the requested order.
    static func videos(baseURL: URL, ids: [Int], page: Int) -> URL {
        var query: [URLQueryItem] = ids.map { URLQueryItem(name: "ids", value: String($0)) }
        query.append(URLQueryItem(name: "order", value: VideoListOrder.ids.rawValue))
        query.append(URLQueryItem(name: "page", value: String(max(page, 1))))
        return url(baseURL: baseURL, path: ["videos"], query: query)
    }

    static func searchVideos(baseURL: URL, query: String, page: Int, order: VideoListOrder) -> URL {
        url(
            baseURL: baseURL,
            path: ["videos", "search"],
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "order", value: order.rawValue),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
    }

    static func video(baseURL: URL, id: Int) -> URL {
        url(baseURL: baseURL, path: ["videos", String(id)])
    }

    static func videoDownload(baseURL: URL, id: Int) -> URL {
        url(baseURL: baseURL, path: ["videos", String(id), "download"])
    }

    static func videoReanalyze(baseURL: URL, id: Int) -> URL {
        url(baseURL: baseURL, path: ["videos", String(id), "reanalyze"])
    }

    static func videoThumbnailRegenerate(baseURL: URL, id: Int) -> URL {
        url(baseURL: baseURL, path: ["videos", String(id), "thumbnail", "regenerate"])
    }

    // MARK: - Series

    static func seriesList(baseURL: URL, page: Int, order: VideoListOrder) -> URL {
        url(
            baseURL: baseURL,
            path: ["series"],
            query: [
                URLQueryItem(name: "order", value: order.rawValue),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
    }

    static func searchSeries(baseURL: URL, query: String, page: Int, order: VideoListOrder) -> URL {
        url(
            baseURL: baseURL,
            path: ["series", "search"],
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "order", value: order.rawValue),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
    }

    static func series(baseURL: URL, id: Int) -> URL {
        url(baseURL: baseURL, path: ["series", String(id)])
    }

    // MARK: - Programs

    /// `POST /api/programs/search` (the search condition is the request body).
    static func searchPrograms(baseURL: URL) -> URL {
        url(baseURL: baseURL, path: ["programs", "search"])
    }

    /// `GET /api/programs/timetable?start_time=...&end_time=...[&channel_type=..][&pinned_channel_ids=a,b]`
    static func timetable(
        baseURL: URL,
        startTime: Date,
        endTime: Date,
        channelType: ChannelType?,
        pinnedChannelIDs: [String]
    ) -> URL {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "start_time", value: JSONCoding.formatQueryDateTime(startTime)),
            URLQueryItem(name: "end_time", value: JSONCoding.formatQueryDateTime(endTime)),
        ]
        if let channelType {
            query.append(URLQueryItem(name: "channel_type", value: channelType.rawValue))
        }
        if !pinnedChannelIDs.isEmpty {
            // The server expects a single comma separated list here.
            query.append(
                URLQueryItem(name: "pinned_channel_ids", value: pinnedChannelIDs.joined(separator: ","))
            )
        }
        return url(baseURL: baseURL, path: ["programs", "timetable"], query: query)
    }

    // MARK: - Settings

    static func clientSettings(baseURL: URL) -> URL {
        url(baseURL: baseURL, path: ["settings", "client"])
    }

    // MARK: - Users

    static func token(baseURL: URL) -> URL {
        url(baseURL: baseURL, path: ["users", "token"])
    }

    static func me(baseURL: URL) -> URL {
        url(baseURL: baseURL, path: ["users", "me"])
    }

    // MARK: - Images

    static func logo(baseURL: URL, channelID: String) -> URL {
        url(baseURL: baseURL, path: ["channels", channelID, "logo"])
    }

    static func thumbnail(baseURL: URL, videoID: Int) -> URL {
        url(baseURL: baseURL, path: ["videos", String(videoID), "thumbnail"])
    }

    /// Seek-bar tiled thumbnail sheet
    /// (`GET /api/videos/{id}/thumbnail/tiled`).
    static func tiledThumbnail(baseURL: URL, videoID: Int) -> URL {
        url(baseURL: baseURL, path: ["videos", String(videoID), "thumbnail", "tiled"])
    }

    // MARK: - Streaming

    /// `GET /api/streams/video/{video_id}/{quality}/playlist?session_id=..&type=..[&cache_key=..]`
    ///
    /// `type=master` returns the audio-group master playlist; the media
    /// playlists (`primary-audio` / `secondary-audio`) are what the master
    /// playlist points at. The segment URIs inside a media playlist are
    /// relative, so AVPlayer resolves them against this URL.
    static func videoPlaylist(
        baseURL: URL,
        videoID: Int,
        apiQuality: String,
        sessionID: String,
        playlistType: VideoPlaylistType = .master,
        cacheKey: String? = nil
    ) -> URL {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "session_id", value: sessionID),
            URLQueryItem(name: "type", value: playlistType.rawValue),
        ]
        if let cacheKey, !cacheKey.isEmpty {
            query.append(URLQueryItem(name: "cache_key", value: cacheKey))
        }
        return url(
            baseURL: baseURL,
            path: ["streams", "video", String(videoID), apiQuality, "playlist"],
            query: query
        )
    }

    /// `GET /api/streams/video/{video_id}/{quality}/segment?session_id=..&sequence=..&cache_key=..&audio=..`
    ///
    /// Only needed when a segment URL is built by hand; the media playlist
    /// already contains relative segment URIs.
    static func videoSegment(
        baseURL: URL,
        videoID: Int,
        apiQuality: String,
        sessionID: String,
        sequence: Int,
        audio: AudioSelection = .primary,
        cacheKey: String? = nil
    ) -> URL {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "session_id", value: sessionID),
            URLQueryItem(name: "sequence", value: String(max(sequence, 0))),
            URLQueryItem(name: "audio", value: audio.rawValue),
        ]
        if let cacheKey, !cacheKey.isEmpty {
            query.append(URLQueryItem(name: "cache_key", value: cacheKey))
        }
        return url(
            baseURL: baseURL,
            path: ["streams", "video", String(videoID), apiQuality, "segment"],
            query: query
        )
    }

    /// `PUT /api/streams/video/{video_id}/{quality}/keep-alive?session_id=..`
    static func videoKeepAlive(
        baseURL: URL,
        videoID: Int,
        apiQuality: String,
        sessionID: String
    ) -> URL {
        url(
            baseURL: baseURL,
            path: ["streams", "video", String(videoID), apiQuality, "keep-alive"],
            query: [URLQueryItem(name: "session_id", value: sessionID)]
        )
    }

    /// `GET /api/streams/live/{display_channel_id}/{quality}/mpegts`
    static func liveStream(
        baseURL: URL,
        displayChannelID: String,
        apiQuality: String
    ) -> URL {
        url(
            baseURL: baseURL,
            path: ["streams", "live", displayChannelID, apiQuality, "mpegts"]
        )
    }

    /// `GET /api/streams/live/{display_channel_id}/{quality}/events`
    ///
    /// A Server-Sent Events stream. KonomiKit only builds the URL; the app
    /// reads it with `URLSession.bytes` and feeds the bytes to
    /// `ServerSentEventParser`.
    static func liveEvents(
        baseURL: URL,
        displayChannelID: String,
        apiQuality: String
    ) -> URL {
        url(
            baseURL: baseURL,
            path: ["streams", "live", displayChannelID, apiQuality, "events"]
        )
    }
}
