import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Bluesky API

/// Endpoints of BlueskyRouter (POST /api/bluesky/...).
///
/// Bluesky posts are identified by their AT URI (at://did/collection/rkey),
/// which contains slashes. The router receives it as a {post_id:path} path
/// parameter, so the client sends it percent-encoded as one path segment.
extension APIClient {

    /// Links a Bluesky account with an App Password
    /// (POST /api/bluesky/auth, 204).
    public func blueskyAuth(handle: String, appPassword: String) async throws {
        let body = try encodeJSONBody(
            BlueskyAuthRequest(handle: handle, appPassword: appPassword)
        )
        var request = makeRequest(
            path: ["bluesky", "auth"],
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        request.timeoutInterval = 60
        _ = try await sendRaw(request)
    }

    /// Unlinks a Bluesky account (DELETE /api/bluesky/accounts/{handle}).
    public func deleteBlueskyAccount(handle: String) async throws {
        _ = try await sendRaw(
            makeRequest(path: ["bluesky", "accounts", handle], method: "DELETE")
        )
    }

    /// Posts to Bluesky with up to four images
    /// (POST /api/bluesky/accounts/{handle}/posts).
    ///
    /// The multipart fields are "post" for the body, "images" (repeated) for
    /// the files and the four reply_* fields that make up the StrongRef pair
    /// of a reply tree.
    public func sendBlueskyPost(
        handle: String,
        text: String,
        images: [TweetImage] = [],
        replyTo: BlueskyReplyReference? = nil
    ) async throws -> PostTweetResult {
        var form = MultipartFormData()
        form.addField(name: "post", value: text)
        if let replyTo {
            form.addField(name: "reply_root_uri", value: replyTo.rootURI)
            form.addField(name: "reply_root_cid", value: replyTo.rootCID)
            form.addField(name: "reply_parent_uri", value: replyTo.parentURI)
            form.addField(name: "reply_parent_cid", value: replyTo.parentCID)
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
            path: ["bluesky", "accounts", handle, "posts"],
            method: "POST",
            body: form.encoded(),
            contentType: form.contentType
        )
        // The server re-encodes and uploads up to four images.
        request.timeoutInterval = 180
        return try await performJSON(request, as: PostTweetResult.self)
    }

    /// Reposts a Bluesky post
    /// (PUT /api/bluesky/accounts/{handle}/posts/{post_id}/repost).
    public func repost(handle: String, postID: String) async throws -> TwitterAPIResult {
        try await blueskyPostAction(
            handle: handle,
            postID: postID,
            action: "repost",
            method: "PUT"
        )
    }

    /// Removes a repost
    /// (DELETE /api/bluesky/accounts/{handle}/posts/{post_id}/repost).
    public func cancelRepost(handle: String, postID: String) async throws -> TwitterAPIResult {
        try await blueskyPostAction(
            handle: handle,
            postID: postID,
            action: "repost",
            method: "DELETE"
        )
    }

    /// Likes a Bluesky post
    /// (PUT /api/bluesky/accounts/{handle}/posts/{post_id}/like).
    public func likePost(handle: String, postID: String) async throws -> TwitterAPIResult {
        try await blueskyPostAction(
            handle: handle,
            postID: postID,
            action: "like",
            method: "PUT"
        )
    }

    /// Removes a like
    /// (DELETE /api/bluesky/accounts/{handle}/posts/{post_id}/like).
    public func cancelLikePost(handle: String, postID: String) async throws -> TwitterAPIResult {
        try await blueskyPostAction(
            handle: handle,
            postID: postID,
            action: "like",
            method: "DELETE"
        )
    }

    /// The Bluesky home timeline
    /// (GET /api/bluesky/accounts/{handle}/timeline).
    public func blueskyTimeline(
        handle: String,
        cursorID: String? = nil
    ) async throws -> TimelineTweetsResult {
        var query: [URLQueryItem] = []
        if let cursorID, !cursorID.isEmpty {
            query.append(URLQueryItem(name: "cursor_id", value: cursorID))
        }
        var request = makeRequest(
            path: ["bluesky", "accounts", handle, "timeline"],
            query: query
        )
        request.timeoutInterval = 60
        return try await performJSON(request, as: TimelineTweetsResult.self)
    }

    /// Searches Bluesky posts
    /// (GET /api/bluesky/accounts/{handle}/search).
    public func blueskySearch(
        handle: String,
        query: String,
        cursorID: String? = nil
    ) async throws -> TimelineTweetsResult {
        var items: [URLQueryItem] = [URLQueryItem(name: "query", value: query)]
        if let cursorID, !cursorID.isEmpty {
            items.append(URLQueryItem(name: "cursor_id", value: cursorID))
        }
        var request = makeRequest(
            path: ["bluesky", "accounts", handle, "search"],
            query: items
        )
        request.timeoutInterval = 60
        return try await performJSON(request, as: TimelineTweetsResult.self)
    }

    // MARK: Helpers

    private func blueskyPostAction(
        handle: String,
        postID: String,
        action: String,
        method: String
    ) async throws -> TwitterAPIResult {
        guard let url = blueskyPostURL(handle: handle, postID: postID, action: action) else {
            throw APIError.invalidServerURL
        }
        var request = makeRequest(url: url, method: method)
        request.timeoutInterval = 60
        return try await performJSON(request, as: TwitterAPIResult.self)
    }

    /// Builds /api/bluesky/accounts/{handle}/posts/{post_id}/{action} with the
    /// AT URI percent-encoded into one path segment.
    func blueskyPostURL(handle: String, postID: String, action: String) -> URL? {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        var path = components.percentEncodedPath
        if !path.hasSuffix("/") {
            path += "/"
        }
        path += "api/bluesky/accounts/"
        path += Self.percentEncodePathSegment(handle)
        path += "/posts/"
        path += Self.percentEncodePathSegment(postID)
        path += "/"
        path += action
        components.percentEncodedPath = path
        return components.url
    }

    /// Percent-encodes one path segment, including "/" (already encoded
    /// sequences are left alone).
    static func percentEncodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;:")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
