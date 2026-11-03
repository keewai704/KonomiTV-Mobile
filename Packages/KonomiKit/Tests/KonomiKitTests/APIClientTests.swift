import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import KonomiKit

// MARK: - Stub transport

actor StubTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    private let handler: Handler
    private var recordedRequests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        return try handler(request)
    }

    func lastRequest() -> URLRequest? {
        recordedRequests.last
    }

    func requestCount() -> Int {
        recordedRequests.count
    }
}

private let serverBaseURL = URL(string: "http://127.0.0.1:7010")!

private func jsonResponse(
    for request: URLRequest,
    body: String,
    status: Int = 200
) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? serverBaseURL,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
}

private func queryValue(_ request: URLRequest, name: String) -> String? {
    guard
        let url = request.url,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
        return nil
    }
    return components.queryItems?.first { $0.name == name }?.value
}

// MARK: - Tests

final class APIClientTests: XCTestCase {

    func testVersionRequest() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/version")
            XCTAssertEqual(request.httpMethod, "GET")
            return jsonResponse(for: request, body: Fixtures.versionJSON)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)

        let version = try await client.version()
        XCTAssertEqual(version.version, "v2.0.0")
        XCTAssertEqual(version.backend, "EDCB")
        let count = await transport.requestCount()
        XCTAssertEqual(count, 1)
    }

    func testChannelsRequest() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/channels")
            return jsonResponse(for: request, body: Fixtures.channelsJSON)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        let channels = try await client.channels()
        XCTAssertEqual(channels.gr.first?.displayChannelID, "gr011")
        XCTAssertEqual(channels.nonEmptyGroups().map { $0.type }, [.gr, .bs])
    }

    func testVideosPagination() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/videos")
            XCTAssertEqual(queryValue(request, name: "order"), "desc")
            XCTAssertEqual(queryValue(request, name: "page"), "2")
            return jsonResponse(for: request, body: Fixtures.recordedProgramsJSON)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        let programs = try await client.videos(page: 2)
        XCTAssertEqual(programs.total, 35)
        XCTAssertEqual(programs.recordedPrograms.first?.title, "テスト番組")
    }

    func testSearchEncodesQuery() async throws {
        let expectedQuery = "ニュース & 天気"
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/videos/search")
            XCTAssertEqual(queryValue(request, name: "query"), expectedQuery)
            XCTAssertEqual(queryValue(request, name: "page"), "1")
            let rawURL = request.url?.absoluteString ?? ""
            XCTAssertFalse(rawQueryContainsRawAmpersand(request))
            XCTAssertTrue(rawURL.contains("page=1"))
            return jsonResponse(for: request, body: Fixtures.recordedProgramsJSON)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        let result = try await client.searchVideos(query: expectedQuery, page: 1)
        XCTAssertEqual(result.total, 35)
    }

    func testVideoDetail() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/videos/101")
            return jsonResponse(for: request, body: Fixtures.recordedProgramJSON)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        let program = try await client.video(id: 101)
        XCTAssertEqual(program.title, "テスト番組")
        XCTAssertEqual(program.recordedVideo.videoResolutionWidth, 1920)
    }

    func testBearerTokenIsSent() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            return jsonResponse(for: request, body: Fixtures.versionJSON)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport, token: "secret-token")
        _ = try await client.version()
        let last = await transport.lastRequest()
        XCTAssertEqual(last?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testWithTokenProducesAuthorizedClient() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
            return jsonResponse(for: request, body: Fixtures.userJSON)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
            .withToken("new-token")
        let user = try await client.me()
        XCTAssertEqual(user.name, "テストユーザー")
    }

    func testLoginSendsFormBody() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/users/token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/x-www-form-urlencoded"
            )
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8)
            XCTAssertEqual(body, "username=test&password=test")
            return jsonResponse(for: request, body: Fixtures.loginJSON)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        let token = try await client.login(username: "test", password: "test")
        XCTAssertEqual(token.accessToken, "test-access-token")
        XCTAssertEqual(token.tokenType, "bearer")
    }

    func testLoginEncodesSpecialCharacters() async throws {
        let transport = StubTransport { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8)
            XCTAssertEqual(body, "username=a%26b&password=p%20w")
            return jsonResponse(for: request, body: Fixtures.loginJSON)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        _ = try await client.login(username: "a&b", password: "p w")
    }

    func testMe() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/users/me")
            return jsonResponse(for: request, body: Fixtures.userJSON)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport, token: "abc")
        let user = try await client.me()
        XCTAssertEqual(user.id, 1)
        XCTAssertEqual(user.name, "テストユーザー")
    }

    func testKeepAliveUsesPUTAndSessionID() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/streams/video/42/720p/keep-alive")
            XCTAssertEqual(queryValue(request, name: "session_id"), "abcd1234")
            let response = HTTPURLResponse(
                url: request.url ?? serverBaseURL,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), response)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        try await client.keepAlive(videoID: 42, quality: .p720, sessionID: "abcd1234")
        let count = await transport.requestCount()
        XCTAssertEqual(count, 1)
    }

    func testUnauthorizedMapsToAPIError() async throws {
        let transport = StubTransport { request in
            jsonResponse(for: request, body: #"{"detail":"invalid credentials"}"#, status: 401)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        do {
            _ = try await client.me()
            XCTFail("Expected an error")
        } catch let error as APIError {
            guard case .unauthorized(let body) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(body?.contains("invalid credentials") ?? false)
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertTrue(error.localizedDescription.contains("認証"))
        }
    }

    func testHTTPErrorMapsToAPIError() async throws {
        let transport = StubTransport { request in
            jsonResponse(for: request, body: "server broke", status: 500)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        do {
            _ = try await client.version()
            XCTFail("Expected an error")
        } catch let error as APIError {
            guard case .httpStatus(let code, let body) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(code, 500)
            // Only a FastAPI `{"detail": "..."}` string is surfaced, never a raw body.
            XCTAssertNil(body)
            XCTAssertTrue(error.localizedDescription.contains("500"))
        }
    }

    func testDecodingErrorMapsToAPIError() async throws {
        let transport = StubTransport { request in
            jsonResponse(for: request, body: "not json")
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        do {
            _ = try await client.version()
            XCTFail("Expected an error")
        } catch let error as APIError {
            guard case .decoding = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("読み取れません"))
        }
    }

    func testTransportErrorMapsToNetworkError() async throws {
        let transport = StubTransport { _ in
            throw URLError(.cannotConnectToHost)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        do {
            _ = try await client.version()
            XCTFail("Expected an error")
        } catch let error as APIError {
            guard case .network = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("接続"))
        }
    }

    func testRecoveringFromEmptyPrograms() async throws {
        let transport = StubTransport { request in
            jsonResponse(for: request, body: Fixtures.emptyProgramsJSON)
        }
        let client = APIClient(baseURL: serverBaseURL, transport: transport)
        let programs = try await client.videos(page: 3)
        XCTAssertEqual(programs.total, 0)
        XCTAssertTrue(programs.recordedPrograms.isEmpty)
    }

    // MARK: - URL builders

    func testLogoURL() {
        let client = APIClient(baseURL: serverBaseURL)
        XCTAssertEqual(
            client.logoURL(channelID: "gr011").absoluteString,
            "http://127.0.0.1:7010/api/channels/gr011/logo"
        )
    }

    func testThumbnailURL() {
        let client = APIClient(baseURL: serverBaseURL)
        XCTAssertEqual(
            client.thumbnailURL(videoID: 101).absoluteString,
            "http://127.0.0.1:7010/api/videos/101/thumbnail"
        )
    }

    func testVideoPlaylistURL() {
        let client = APIClient(baseURL: serverBaseURL)
        let url = client.videoPlaylistURL(videoID: 101, quality: .p1080, sessionID: "abcd1234")
        XCTAssertEqual(url.path, "/api/streams/video/101/1080p/playlist")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "session_id" }?.value, "abcd1234")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "type" }?.value, "master")
    }

    func testVideoPlaylistRejectsOriginalQuality() {
        let client = APIClient(baseURL: serverBaseURL)
        let url = client.videoPlaylistURL(videoID: 7, quality: .original, sessionID: "sid")
        XCTAssertEqual(url.path, "/api/streams/video/7/1080p/playlist")
    }

    func testVideoKeepAliveURL() {
        let client = APIClient(baseURL: serverBaseURL)
        let url = client.videoKeepAliveURL(
            videoID: 42,
            profile: StreamingProfile(quality: .p720, dataSaver: true),
            sessionID: "sid"
        )
        XCTAssertEqual(url.path, "/api/streams/video/42/720p-hevc/keep-alive")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "session_id" }?.value, "sid")
    }

    func testLiveStreamURL() {
        let client = APIClient(baseURL: serverBaseURL)
        XCTAssertEqual(
            client.liveStreamURL(displayChannelID: "gr011", quality: .original).absoluteString,
            "http://127.0.0.1:7010/api/streams/live/gr011/original/mpegts"
        )
        XCTAssertEqual(
            client.liveStreamURL(displayChannelID: "bs101", quality: .p720).absoluteString,
            "http://127.0.0.1:7010/api/streams/live/bs101/720p/mpegts"
        )
    }

    func testBaseURLWithPath() {
        let base = URL(string: "https://example.com/konomitv")!
        let client = APIClient(baseURL: base)
        XCTAssertEqual(
            client.thumbnailURL(videoID: 1).absoluteString,
            "https://example.com/konomitv/api/videos/1/thumbnail"
        )
    }
}

private func rawQueryContainsRawAmpersand(_ request: URLRequest) -> Bool {
    guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return false
    }
    guard let encoded = components.percentEncodedQuery else { return false }
    // There should be exactly two separators (query, order, page) and no raw
    // ampersand inside the encoded query value.
    return encoded.components(separatedBy: "&").count != 3
}
