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

    public func videos(page: Int = 1) async throws -> RecordedPrograms {
        let request = makeRequest(
            path: ["videos"],
            query: [
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
        return try await perform(request, as: RecordedPrograms.self)
    }

    public func searchVideos(query: String, page: Int = 1) async throws -> RecordedPrograms {
        let request = makeRequest(
            path: ["videos", "search"],
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "page", value: String(max(page, 1))),
            ]
        )
        return try await perform(request, as: RecordedPrograms.self)
    }

    public func video(id: Int) async throws -> RecordedProgram {
        try await perform(makeRequest(path: ["videos", String(id)]), as: RecordedProgram.self)
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

    public func keepAlive(
        videoID: Int,
        quality: StreamQuality,
        sessionID: String
    ) async throws {
        let request = makeRequest(
            path: ["streams", "video", String(videoID), quality.videoSafe.rawValue, "keep-alive"],
            query: [URLQueryItem(name: "session_id", value: sessionID)],
            method: "PUT"
        )
        _ = try await sendRaw(request)
    }

    // MARK: - URL builders

    public func logoURL(channelID: String) -> URL {
        Endpoints.logo(baseURL: baseURL, channelID: channelID)
    }

    public func thumbnailURL(videoID: Int) -> URL {
        Endpoints.thumbnail(baseURL: baseURL, videoID: videoID)
    }

    public func videoPlaylistURL(
        videoID: Int,
        quality: StreamQuality,
        sessionID: String
    ) -> URL {
        Endpoints.videoPlaylist(
            baseURL: baseURL,
            videoID: videoID,
            quality: quality,
            sessionID: sessionID
        )
    }

    public func videoKeepAliveURL(
        videoID: Int,
        quality: StreamQuality,
        sessionID: String
    ) -> URL {
        Endpoints.videoKeepAlive(
            baseURL: baseURL,
            videoID: videoID,
            quality: quality,
            sessionID: sessionID
        )
    }

    public func liveStreamURL(
        displayChannelID: String,
        quality: StreamQuality
    ) -> URL {
        Endpoints.liveStream(
            baseURL: baseURL,
            displayChannelID: displayChannelID,
            quality: quality
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
