import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Twitter API

/// Endpoints of TwitterRouter (POST /api/twitter/...).
///
/// Every request except the video proxy needs the bearer token and an account
/// linked by /api/twitter/auth.
extension APIClient {

    /// Links a Twitter account with exported Netscape cookies
    /// (POST /api/twitter/auth, 204).
    ///
    /// The server drives a headless browser, so the request can take a while.
    public func twitterAuth(
        cookiesTxt: String,
        browserInfo: BrowserEnvironmentInfoRequest? = nil
    ) async throws {
        let body = try encodeJSONBody(
            TwitterCookieAuthRequest(cookiesTxt: cookiesTxt, browserInfo: browserInfo)
        )
        var request = makeRequest(
            path: ["twitter", "auth"],
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        request.timeoutInterval = 60
        _ = try await sendRaw(request)
    }

    /// Unlinks a Twitter account (DELETE /api/twitter/accounts/{screen_name}).
    public func deleteTwitterAccount(screenName: String) async throws {
        _ = try await sendRaw(
            makeRequest(
                path: ["twitter", "accounts", screenName],
                method: "DELETE"
            )
        )
    }

    /// Keeps the server's headless browser alive while the panel is used
    /// (POST /api/twitter/accounts/{screen_name}/keep-alive, 204).
    public func twitterKeepAlive(screenName: String) async throws {
        var request = makeRequest(
            path: ["twitter", "accounts", screenName, "keep-alive"],
            method: "POST"
        )
        request.timeoutInterval = 30
        _ = try await sendRaw(request)
    }

    /// Posts a tweet with up to four images
    /// (POST /api/twitter/accounts/{screen_name}/tweets).
    ///
    /// The multipart fields are the ones TwitterRouter.TwitterTweetAPI reads:
    /// "tweet" for the body, "images" (repeated) for the files and
    /// "in_reply_to_status_id" for a reply tree parent.
    public func sendTweet(
        screenName: String,
        text: String,
        images: [TweetImage] = [],
        inReplyToStatusID: String? = nil
    ) async throws -> PostTweetResult {
        var form = MultipartFormData()
        form.addField(name: "tweet", value: text)
        if let inReplyToStatusID, !inReplyToStatusID.isEmpty {
            form.addField(name: "in_reply_to_status_id", value: inReplyToStatusID)
        }
        for image in images {
            form.addFile(
                name: "images",
                filename: image.filename,
                contentType: image.contentType,
                data: image.data
            )
        }
        var request = makeRequest(
            path: ["twitter", "accounts", screenName, "tweets"],
            method: "POST",
            body: form.encoded(),
            contentType: form.contentType
        )
        // Posting can queue behind Twitter's own rate limits.
        request.timeoutInterval = 600
        return try await performJSON(request, as: PostTweetResult.self)
    }

    /// Retweets a tweet
    /// (PUT /api/twitter/accounts/{screen_name}/tweets/{id}/retweet).
    public func retweet(screenName: String, tweetID: String) async throws -> TwitterAPIResult {
        var request = makeRequest(
            path: ["twitter", "accounts", screenName, "tweets", tweetID, "retweet"],
            method: "PUT"
        )
        request.timeoutInterval = 60
        return try await performJSON(request, as: TwitterAPIResult.self)
    }

    /// Removes a retweet
    /// (DELETE /api/twitter/accounts/{screen_name}/tweets/{id}/retweet).
    public func cancelRetweet(screenName: String, tweetID: String) async throws -> TwitterAPIResult {
        var request = makeRequest(
            path: ["twitter", "accounts", screenName, "tweets", tweetID, "retweet"],
            method: "DELETE"
        )
        request.timeoutInterval = 60
        return try await performJSON(request, as: TwitterAPIResult.self)
    }

    /// Likes a tweet
    /// (PUT /api/twitter/accounts/{screen_name}/tweets/{id}/favorite).
    public func favorite(screenName: String, tweetID: String) async throws -> TwitterAPIResult {
        var request = makeRequest(
            path: ["twitter", "accounts", screenName, "tweets", tweetID, "favorite"],
            method: "PUT"
        )
        request.timeoutInterval = 60
        return try await performJSON(request, as: TwitterAPIResult.self)
    }

    /// Removes a like
    /// (DELETE /api/twitter/accounts/{screen_name}/tweets/{id}/favorite).
    public func cancelFavorite(screenName: String, tweetID: String) async throws -> TwitterAPIResult {
        var request = makeRequest(
            path: ["twitter", "accounts", screenName, "tweets", tweetID, "favorite"],
            method: "DELETE"
        )
        request.timeoutInterval = 60
        return try await performJSON(request, as: TwitterAPIResult.self)
    }

    /// The home timeline
    /// (GET /api/twitter/accounts/{screen_name}/timeline).
    public func twitterTimeline(
        screenName: String,
        cursorID: String? = nil,
        cursorType: TwitterTimelineCursorType = .top,
        seenTweetIDs: [String] = []
    ) async throws -> TimelineTweetsResult {
        var query: [URLQueryItem] = [URLQueryItem(name: "cursor_type", value: cursorType.rawValue)]
        if let cursorID, !cursorID.isEmpty {
            query.append(URLQueryItem(name: "cursor_id", value: cursorID))
        }
        if !seenTweetIDs.isEmpty {
            query.append(
                URLQueryItem(name: "seen_tweet_ids", value: seenTweetIDs.joined(separator: ","))
            )
        }
        var request = makeRequest(
            path: ["twitter", "accounts", screenName, "timeline"],
            query: query
        )
        request.timeoutInterval = 60
        return try await performJSON(request, as: TimelineTweetsResult.self)
    }

    /// Searches tweets
    /// (GET /api/twitter/accounts/{screen_name}/search).
    public func twitterSearch(
        screenName: String,
        query: String,
        searchType: TwitterSearchType = .latest,
        cursorID: String? = nil,
        cursorType: TwitterTimelineCursorType = .top
    ) async throws -> TimelineTweetsResult {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "search_type", value: searchType.rawValue),
            URLQueryItem(name: "cursor_type", value: cursorType.rawValue),
        ]
        if let cursorID, !cursorID.isEmpty {
            items.append(URLQueryItem(name: "cursor_id", value: cursorID))
        }
        var request = makeRequest(
            path: ["twitter", "accounts", screenName, "search"],
            query: items
        )
        request.timeoutInterval = 60
        return try await performJSON(request, as: TimelineTweetsResult.self)
    }

    /// URL of the Twitter video proxy (GET /api/twitter/video-proxy?url=...).
    ///
    /// Twitter rejects video requests from other origins with 403, so tweets
    /// carrying a video must play it through the server.
    public func twitterVideoProxyURL(url: String) -> URL? {
        guard var components = URLComponents(
            url: Endpoints.url(baseURL: baseURL, path: ["twitter", "video-proxy"]),
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        return components.url
    }

    // MARK: Helpers

    func encodeJSONBody<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONCoding.encode(value)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    /// Sends a request and decodes its JSON body.
    func performJSON<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, _) = try await sendRaw(request)
        do {
            return try JSONCoding.makeDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }
}
