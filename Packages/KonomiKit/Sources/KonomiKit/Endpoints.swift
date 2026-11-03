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

    static func videos(baseURL: URL, page: Int) -> URL {
        url(
            baseURL: baseURL,
            path: ["videos"],
            query: [
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
    }

    static func searchVideos(baseURL: URL, query: String, page: Int) -> URL {
        url(
            baseURL: baseURL,
            path: ["videos", "search"],
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
    }

    static func video(baseURL: URL, id: Int) -> URL {
        url(baseURL: baseURL, path: ["videos", String(id)])
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

    // MARK: - Streaming

    static func videoPlaylist(
        baseURL: URL,
        videoID: Int,
        quality: StreamQuality,
        sessionID: String
    ) -> URL {
        url(
            baseURL: baseURL,
            path: ["streams", "video", String(videoID), quality.videoSafe.rawValue, "playlist"],
            query: [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "type", value: "master"),
            ]
        )
    }

    static func videoKeepAlive(
        baseURL: URL,
        videoID: Int,
        quality: StreamQuality,
        sessionID: String
    ) -> URL {
        url(
            baseURL: baseURL,
            path: ["streams", "video", String(videoID), quality.videoSafe.rawValue, "keep-alive"],
            query: [URLQueryItem(name: "session_id", value: sessionID)]
        )
    }

    static func liveStream(
        baseURL: URL,
        displayChannelID: String,
        quality: StreamQuality
    ) -> URL {
        url(
            baseURL: baseURL,
            path: ["streams", "live", displayChannelID, quality.rawValue, "mpegts"]
        )
    }
}
