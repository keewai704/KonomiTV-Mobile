import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import KonomiKit

// MARK: - Stub transport

actor JikkyoTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    private let handler: Handler
    private var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try handler(request)
    }

    func lastRequest() -> URLRequest? { requests.last }
    func requestCount() -> Int { requests.count }
}

private let jikkyoBaseURL = URL(string: "http://127.0.0.1:7010")!

private func jikkyoJSON(_ request: URLRequest, _ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? jikkyoBaseURL,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
}

private func noContent(_ request: URLRequest) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? jikkyoBaseURL,
        statusCode: 204,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
    return (Data(), response)
}

// MARK: - Realistic payloads

enum JikkyoFixtures {

    /// schemas.JikkyoWebSocketInfo, as the real server answers for gr011 with a
    /// logged in, Niconico linked user.
    static let webSocketInfoJSON = """
    {
      "watch_session_url": "wss://nx-jikkyo.konomi.tv/api/v1/sessions/gr011/watch",
      "nicolive_watch_session_url": "wss://a.live.nicovideo.jp/api/v1/watch/123456789/watch",
      "nicolive_watch_session_error": null,
      "comment_session_url": "wss://nx-jikkyo.konomi.tv/api/v1/sessions/gr011/comment",
      "is_nxjikkyo_exclusive": false
    }
    """

    /// A channel that only exists in NX-Jikkyo (no Nicolive program at all).
    static let webSocketInfoExclusiveJSON = """
    {
      "watch_session_url": "wss://nx-jikkyo.konomi.tv/api/v1/sessions/bs103/watch",
      "nicolive_watch_session_url": null,
      "nicolive_watch_session_error": null,
      "comment_session_url": "wss://nx-jikkyo.konomi.tv/api/v1/sessions/bs103/comment",
      "is_nxjikkyo_exclusive": true
    }
    """

    /// A channel without a Niconico Jikkyo channel at all.
    static let webSocketInfoUnsupportedJSON = """
    {
      "watch_session_url": null,
      "nicolive_watch_session_url": null,
      "nicolive_watch_session_error": null,
      "comment_session_url": null,
      "is_nxjikkyo_exclusive": false
    }
    """

    /// schemas.JikkyoComments with a spread of colours / sizes / positions.
    static let pastCommentsJSON = """
    {
      "is_success": true,
      "comments": [
        {
          "time": 0.0,
          "type": "right",
          "size": "medium",
          "color": "#FFEAEA",
          "author": "nicolive:1234567",
          "text": "こんばんは"
        },
        {
          "time": 12.34,
          "type": "top",
          "size": "big",
          "color": "#F02840",
          "author": "AbCdEfGhIjKl",
          "text": "テストコメント"
        },
        {
          "time": 1087.5,
          "type": "bottom",
          "size": "small",
          "color": "#4763FF",
          "author": "nicolive:7654321",
          "text": "きたああああ"
        }
      ],
      "detail": "Success"
    }
    """

    static let roomJSON = """
    {
      "type": "room",
      "data": {
        "vposBaseTime": "2026-11-03T21:00:00+09:00",
        "threadId": "1762174800",
        "messageServer": {
          "uri": "wss://a.live.nicovideo.jp/api/v1/watch/1762174800/",
          "type": "websocket"
        },
        "yourPostKey": "nicolive:12345",
        "roomId": "gr011",
        "threadKeyRequired": false
      }
    }
    """

    static let messageServerJSON = """
    {
      "type": "messageServer",
      "data": {
        "vposBaseTime": "2026-11-03T21:00:00+09:00",
        "hashedUserId": "zGFhYmMxMjM0NQ==",
        "messageServer": {
          "uri": "https://mpn.live.nicovideo.jp/api/v1/watch/hls/xxx",
          "type": "ndgr"
        }
      }
    }
    """

    static let chatJSON = """
    {
      "chat": {
        "no": 4021,
        "thread": "1762174800",
        "vpos": 123456,
        "date": 1762174900,
        "date_usec": 123456,
        "mail": "184 ue red",
        "user_id": "nicolive:1234567",
        "content": "こんばんは",
        "premium": null,
        "anonymity": 1,
        "yourpost": 0,
        "score": 0
      }
    }
    """

    static let ownChatJSON = """
    {
      "chat": {
        "no": 4022,
        "thread": "1762174800",
        "vpos": 130000,
        "date": 1762174903,
        "date_usec": 0,
        "mail": "184",
        "user_id": "nicolive:12345",
        "content": "自分のコメント",
        "premium": null,
        "anonymity": 1,
        "yourpost": 1,
        "score": 0
      }
    }
    """

    static let threadJSON = """
    {"thread":{"resultcode":0,"thread":"1762174800","revision":1,"server_time":1762174999,"last_res":4021,"ticket":"abcdef","comment_count":4212}}
    """

    static let threadErrorJSON = """
    {"thread":{"resultcode":2,"thread":"1762174800"}}
    """
}

// MARK: - API

final class JikkyoAPITests: XCTestCase {

    func testJikkyoWebSocketInfoUsesDisplayChannelID() async throws {
        let transport = JikkyoTransport { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/channels/gr011/jikkyo")
            return jikkyoJSON(request, JikkyoFixtures.webSocketInfoJSON)
        }
        let client = APIClient(baseURL: jikkyoBaseURL, transport: transport, token: "token")
        let info = try await client.jikkyoWebSocketInfo(channelID: "gr011")

        XCTAssertEqual(
            info.watchSessionURL,
            "wss://nx-jikkyo.konomi.tv/api/v1/sessions/gr011/watch"
        )
        XCTAssertEqual(
            info.commentSessionURL,
            "wss://nx-jikkyo.konomi.tv/api/v1/sessions/gr011/comment"
        )
        XCTAssertEqual(
            info.nicoliveWatchSessionURL,
            "wss://a.live.nicovideo.jp/api/v1/watch/123456789/watch"
        )
        XCTAssertNil(info.nicoliveWatchSessionError)
        XCTAssertFalse(info.isNXJikkyoExclusive)
        XCTAssertNotNil(info.watchSessionURLValue)
        XCTAssertNotNil(info.commentSessionURLValue)
        XCTAssertEqual(
            info.nicoliveWatchSessionURLValue?.host,
            "a.live.nicovideo.jp"
        )

        // The bearer token is what makes the server add the Nicolive URL.
        let sent = await transport.lastRequest()
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testJikkyoWebSocketInfoExclusiveAndUnsupported() async throws {
        let transport = JikkyoTransport { request in
            if request.url?.path.contains("bs103") == true {
                return jikkyoJSON(request, JikkyoFixtures.webSocketInfoExclusiveJSON)
            }
            return jikkyoJSON(request, JikkyoFixtures.webSocketInfoUnsupportedJSON)
        }
        let client = APIClient(baseURL: jikkyoBaseURL, transport: transport)

        let exclusive = try await client.jikkyoWebSocketInfo(channelID: "bs103")
        XCTAssertTrue(exclusive.isNXJikkyoExclusive)
        XCTAssertNil(exclusive.nicoliveWatchSessionURL)
        XCTAssertNotNil(exclusive.watchSessionURL)

        let unsupported = try await client.jikkyoWebSocketInfo(channelID: "gr999")
        XCTAssertNil(unsupported.watchSessionURL)
        XCTAssertNil(unsupported.watchSessionURLValue)
        XCTAssertNil(unsupported.commentSessionURLValue)
    }

    func testPastComments() async throws {
        let transport = JikkyoTransport { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/videos/4/jikkyo")
            return jikkyoJSON(request, JikkyoFixtures.pastCommentsJSON)
        }
        let client = APIClient(baseURL: jikkyoBaseURL, transport: transport)
        let comments = try await client.pastComments(videoID: 4)

        XCTAssertTrue(comments.isSuccess)
        XCTAssertEqual(comments.detail, "Success")
        XCTAssertEqual(comments.comments.count, 3)

        XCTAssertEqual(comments.comments[0].time, 0)
        XCTAssertEqual(comments.comments[0].type, .scroll)
        XCTAssertEqual(comments.comments[0].color, "#FFEAEA")
        XCTAssertEqual(comments.comments[0].author, "nicolive:1234567")
        XCTAssertEqual(comments.comments[0].text, "こんばんは")

        XCTAssertEqual(comments.comments[1].time, 12.34)
        XCTAssertEqual(comments.comments[1].type, .top)
        XCTAssertEqual(comments.comments[1].size, .big)
        XCTAssertEqual(comments.comments[1].color, "#F02840")

        XCTAssertEqual(comments.comments[2].type, .bottom)
        XCTAssertEqual(comments.comments[2].size, .small)
    }

    func testNiconicoAuthURLAndUnlink() async throws {
        let transport = JikkyoTransport { request in
            switch request.httpMethod {
            case "DELETE":
                return noContent(request)
            default:
                return jikkyoJSON(
                    request,
                    #"{"authorization_url":"https://oauth.nicovideo.jp/oauth2/authorize?response_type=code&client_id=test"}"#
                )
            }
        }
        let client = APIClient(baseURL: jikkyoBaseURL, transport: transport, token: "token")

        let auth = try await client.niconicoAuthURL(origin: "konomitv://")
        XCTAssertEqual(auth.authorizationURL?.host, "oauth.nicovideo.jp")
        XCTAssertEqual(auth.authorizationURL?.path, "/oauth2/authorize")
        let authRequest = await transport.lastRequest()
        XCTAssertEqual(authRequest?.url?.path, "/api/niconico/auth")
        XCTAssertEqual(authRequest?.httpMethod, "GET")
        XCTAssertEqual(
            authRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer token"
        )
        // The native app tells the server its own callback URL scheme.
        XCTAssertEqual(
            authRequest?.value(forHTTPHeaderField: "Origin"),
            "konomitv://"
        )

        try await client.unlinkNiconico()
        let unlinkRequest = await transport.lastRequest()
        XCTAssertEqual(unlinkRequest?.url?.path, "/api/niconico/logout")
        XCTAssertEqual(unlinkRequest?.httpMethod, "DELETE")
        XCTAssertEqual(
            unlinkRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer token"
        )
        let count = await transport.requestCount()
        XCTAssertEqual(count, 2)
    }

    func testNiconicoAuthURLRequiresToken() async throws {
        let transport = JikkyoTransport { request in
            jikkyoJSON(request, #"{"detail":"Unauthorized"}"#, status: 401)
        }
        let client = APIClient(baseURL: jikkyoBaseURL, transport: transport)
        do {
            _ = try await client.niconicoAuthURL()
            XCTFail("expected an unauthorized error")
        } catch let error as APIError {
            guard case .unauthorized = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testUserNiconicoFields() throws {
        let linked = try JSONCoding.decode(
            User.self,
            from: """
            {
              "id": 1,
              "name": "テストユーザー",
              "is_admin": true,
              "niconico_user_id": 1234567,
              "niconico_user_name": "テスト",
              "niconico_user_premium": true,
              "created_at": "2025-11-03T21:00:00+09:00",
              "updated_at": "2026-11-03T21:00:00+09:00"
            }
            """
        )
        XCTAssertEqual(linked.niconicoUserID, 1234567)
        XCTAssertEqual(linked.niconicoUserName, "テスト")
        XCTAssertEqual(linked.niconicoUserPremium, true)
        XCTAssertTrue(linked.isNiconicoLinked)

        let unlinked = try JSONCoding.decode(
            User.self,
            from: """
            {
              "id": 1,
              "name": "テストユーザー",
              "is_admin": false,
              "niconico_user_id": null,
              "niconico_user_name": null,
              "niconico_user_premium": null
            }
            """
        )
        XCTAssertNil(unlinked.niconicoUserID)
        XCTAssertNil(unlinked.niconicoUserPremium)
        XCTAssertFalse(unlinked.isNiconicoLinked)
    }
}

// MARK: - Watch session

final class JikkyoWatchSessionTests: XCTestCase {

    func testSeat() throws {
        let message = try JikkyoWatchSessionMessage.decode(
            #"{"type":"seat","data":{"keepIntervalSec":30}}"#
        )
        guard case .seat(let seat) = message else {
            return XCTFail("expected seat, got \(message.rawType)")
        }
        XCTAssertEqual(seat.keepIntervalSec, 30)
        XCTAssertEqual(message.rawType, "seat")
    }

    func testSeatFallsBackToDefaultInterval() throws {
        let message = try JikkyoWatchSessionMessage.decode(#"{"type":"seat","data":{}}"#)
        guard case .seat(let seat) = message else {
            return XCTFail("expected seat")
        }
        XCTAssertEqual(seat.keepIntervalSec, 30)
    }

    func testPing() throws {
        let message = try JikkyoWatchSessionMessage.decode(#"{"type":"ping"}"#)
        XCTAssertEqual(message, .ping)
        XCTAssertEqual(message.rawType, "ping")
    }

    func testError() throws {
        let message = try JikkyoWatchSessionMessage.decode(
            #"{"type":"error","data":{"code":"NOT_ON_AIR"}}"#
        )
        guard case .error(let error) = message else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(error.code, "NOT_ON_AIR")
        XCTAssertFalse(error.isCommentPostError)

        let post = try JikkyoWatchSessionMessage.decode(
            #"{"type":"error","data":{"code":"COMMENT_POST_NOT_ALLOWED"}}"#
        )
        guard case .error(let postError) = post else {
            return XCTFail("expected error")
        }
        XCTAssertTrue(postError.isCommentPostError)
    }

    func testReconnect() throws {
        let message = try JikkyoWatchSessionMessage.decode(
            #"{"type":"reconnect","data":{"waitTimeSec":5,"audienceToken":"token"}}"#
        )
        guard case .reconnect(let reconnect) = message else {
            return XCTFail("expected reconnect")
        }
        XCTAssertEqual(reconnect.waitTimeSec, 5)
        XCTAssertEqual(reconnect.audienceToken, "token")
    }

    func testDisconnect() throws {
        let message = try JikkyoWatchSessionMessage.decode(
            #"{"type":"disconnect","data":{"reason":"END_PROGRAM"}}"#
        )
        guard case .disconnect(let disconnect) = message else {
            return XCTFail("expected disconnect")
        }
        XCTAssertEqual(disconnect.reason, "END_PROGRAM")
    }

    func testRoom() throws {
        let message = try JikkyoWatchSessionMessage.decode(JikkyoFixtures.roomJSON)
        guard case .room(let room) = message else {
            return XCTFail("expected room")
        }
        XCTAssertEqual(room.threadID, "1762174800")
        XCTAssertEqual(
            room.messageServerURL,
            "wss://a.live.nicovideo.jp/api/v1/watch/1762174800/"
        )
        XCTAssertEqual(room.yourPostKey, "nicolive:12345")
        let base = try XCTUnwrap(room.vposBaseTime)
        let expected = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-03T21:00:00+09:00"))
        XCTAssertEqual(base, expected)
    }

    func testMessageServer() throws {
        let message = try JikkyoWatchSessionMessage.decode(JikkyoFixtures.messageServerJSON)
        guard case .messageServer(let server) = message else {
            return XCTFail("expected messageServer")
        }
        XCTAssertEqual(server.hashedUserID, "zGFhYmMxMjM0NQ==")
        XCTAssertNotNil(server.vposBaseTime)
    }

    func testPostCommentResult() throws {
        let message = try JikkyoWatchSessionMessage.decode(
            """
            {"type":"postCommentResult","data":{"chat":{"no":4022,"thread":"1762174800",
            "vpos":130000,"date":1762174903,"mail":"184","user_id":"nicolive:12345",
            "content":"自分のコメント","yourpost":1}}}
            """
        )
        guard case .postCommentResult(let result) = message else {
            return XCTFail("expected postCommentResult")
        }
        let chat = try XCTUnwrap(result.chat)
        XCTAssertEqual(chat.number, 4022)
        XCTAssertEqual(chat.content, "自分のコメント")
        XCTAssertTrue(chat.yourPost)
    }

    func testStatisticsAndUnknown() throws {
        let statistics = try JikkyoWatchSessionMessage.decode(
            #"{"type":"statistics","data":{"viewers":42,"comments":1337}}"#
        )
        guard case .statistics(let payload) = statistics else {
            return XCTFail("expected statistics")
        }
        XCTAssertEqual(payload.raw?["viewers"]?.intValue, 42)

        let unknown = try JikkyoWatchSessionMessage.decode(
            #"{"type":"somethingNew","data":{"a":1}}"#
        )
        guard case .unknown(let message) = unknown else {
            return XCTFail("expected unknown")
        }
        XCTAssertEqual(message.type, "somethingNew")
        XCTAssertEqual(message.data?["a"]?.intValue, 1)
    }

    func testMalformedMessagesThrow() {
        XCTAssertThrowsError(try JikkyoWatchSessionMessage.decode("not json"))
        XCTAssertThrowsError(try JikkyoWatchSessionMessage.decode("[1,2,3]"))
        XCTAssertThrowsError(try JikkyoWatchSessionMessage.decode(#"{"data":{}}"#))
    }

    // MARK: Outgoing

    func testStartWatchingMatchesWebClient() {
        XCTAssertEqual(
            JikkyoWatchSessionRequest.startWatching.jsonString,
            #"{"type":"startWatching","data":{"reconnect":false}}"#
        )
        XCTAssertEqual(
            JikkyoWatchSessionRequest.startWatching(reconnect: true).jsonString,
            #"{"type":"startWatching","data":{"reconnect":true}}"#
        )
    }

    func testKeepSeatAndPongMatchWebClient() {
        XCTAssertEqual(
            JikkyoWatchSessionRequest.keepSeat.jsonString,
            #"{"type":"keepSeat"}"#
        )
        XCTAssertEqual(JikkyoWatchSessionRequest.pong.jsonString, #"{"type":"pong"}"#)
    }

    func testPostCommentMatchesWebClient() {
        let comment = JikkyoPostComment(
            text: "こんばんは",
            color: "white",
            position: "naka",
            size: .medium,
            vpos: 12345
        )
        XCTAssertEqual(
            JikkyoWatchSessionRequest.postComment(comment).jsonString,
            #"{"type":"postComment","data":{"text":"こんばんは","color":"white","position":"naka","size":"medium","vpos":12345,"isAnonymous":true}}"#
        )
    }

    func testPostCommentOmitsUnknownColourAndPosition() {
        // The web client's tables have no entry for these values, and
        // JSON.stringify drops undefined keys.
        let comment = JikkyoPostComment(
            text: "test",
            color: nil,
            position: nil,
            size: .big,
            vpos: 0
        )
        XCTAssertEqual(
            JikkyoWatchSessionRequest.postComment(comment).jsonString,
            #"{"type":"postComment","data":{"text":"test","size":"big","vpos":0,"isAnonymous":true}}"#
        )
    }

    func testPostCommentEscapesJSONText() {
        let comment = JikkyoPostComment(text: "quote\"back\\slash\n改行", vpos: 1)
        let json = comment.jsonString
        XCTAssertTrue(json.contains(#""text":"quote\"back\\slash\n改行""#))
        // And it still parses back.
        let decoded = try? JSONCoding.decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(decoded?["data"]?["text"]?.stringValue, "quote\"back\\slash\n改行")
    }

    func testPostCommentFromPlayerValues() {
        let comment = JikkyoPostComment(
            text: "テスト",
            hexColor: "#F02840",
            danmakuPosition: .top,
            size: .medium,
            vpos: 100
        )
        XCTAssertEqual(comment.color, "red")
        XCTAssertEqual(comment.position, "ue")

        // A colour outside the send table is dropped, like the web client.
        let unknown = JikkyoPostComment(
            text: "テスト",
            hexColor: "#123456",
            danmakuPosition: .bottom,
            size: .small,
            vpos: 100
        )
        XCTAssertNil(unknown.color)
        XCTAssertEqual(unknown.position, "shita")
    }

    func testSessionTimings() throws {
        XCTAssertEqual(JikkyoSessionTiming.reconnectDelay, 3)
        XCTAssertEqual(JikkyoSessionTiming.commentEmitInterval, 0.333, accuracy: 0.0001)
        XCTAssertEqual(JikkyoSessionTiming.defaultKeepSeatInterval, 30)

        let seat = try JikkyoWatchSessionMessage.decode(
            #"{"type":"seat","data":{"keepIntervalSec":15}}"#
        )
        guard case .seat(let payload) = seat else {
            return XCTFail("expected seat")
        }
        XCTAssertEqual(JikkyoSessionTiming.keepSeatInterval(seat: payload), 15)
        XCTAssertEqual(
            JikkyoSessionTiming.keepSeatInterval(seat: JikkyoSeat(keepIntervalSec: 0)),
            JikkyoSessionTiming.defaultKeepSeatInterval
        )
    }

    func testVposRounding() throws {
        let base = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-03T21:00:00+09:00"))
        let now = base.addingTimeInterval(123.456)
        // 123.456 s = 12345.6 vpos, rounded to 12346 (Math.round in the web client).
        XCTAssertEqual(JikkyoPostComment.vpos(now: now, vposBaseTime: base), 12346)
        XCTAssertEqual(
            JikkyoPostComment.vpos(now: base.addingTimeInterval(-1), vposBaseTime: base),
            -100
        )
    }
}

// MARK: - Comment session

final class JikkyoCommentSessionTests: XCTestCase {

    func testThreadRequestMatchesWebClient() {
        let request = JikkyoCommentSessionRequest(
            threadID: "1762174800",
            threadKey: "nicolive:12345"
        )
        XCTAssertEqual(
            request.jsonString,
            #"[{"ping":{"content":"rs:0"}},{"ping":{"content":"ps:0"}},{"thread":{"version":"20061206","thread":"1762174800","threadkey":"nicolive:12345","user_id":"","res_from":-100}},{"ping":{"content":"pf:0"}},{"ping":{"content":"rf:0"}}]"#
        )
    }

    func testThreadRequestOmitsMissingThreadKey() {
        let request = JikkyoCommentSessionRequest()
        XCTAssertEqual(
            request.jsonString,
            #"[{"ping":{"content":"rs:0"}},{"ping":{"content":"ps:0"}},{"thread":{"version":"20061206","thread":"","user_id":"","res_from":-100}},{"ping":{"content":"pf:0"}},{"ping":{"content":"rf:0"}}]"#
        )
    }

    func testThreadResult() throws {
        let ok = try JikkyoCommentSessionMessage.decode(JikkyoFixtures.threadJSON)
        guard case .thread(let result) = ok else {
            return XCTFail("expected thread")
        }
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.resultCode, 0)
        XCTAssertEqual(result.threadID, "1762174800")

        let failed = try JikkyoCommentSessionMessage.decode(JikkyoFixtures.threadErrorJSON)
        guard case .thread(let failedResult) = failed else {
            return XCTFail("expected thread")
        }
        XCTAssertFalse(failedResult.isSuccess)
        XCTAssertEqual(failedResult.resultCode, 2)
    }

    func testPingMarksInitialCommentsEnd() throws {
        let finished = try JikkyoCommentSessionMessage.decode(#"{"ping":{"content":"rf:0"}}"#)
        XCTAssertEqual(finished, .ping("rf:0"))
        XCTAssertTrue(finished.isInitialCommentsEnd)

        let other = try JikkyoCommentSessionMessage.decode(#"{"ping":{"content":"ps:0"}}"#)
        XCTAssertFalse(other.isInitialCommentsEnd)
    }

    func testChat() throws {
        let message = try JikkyoCommentSessionMessage.decode(JikkyoFixtures.chatJSON)
        guard case .chat(let chat) = message else {
            return XCTFail("expected chat")
        }
        XCTAssertEqual(chat.number, 4021)
        XCTAssertEqual(chat.threadID, "1762174800")
        XCTAssertEqual(chat.vpos, 123456)
        XCTAssertEqual(chat.time, 1234.56, accuracy: 0.0001)
        XCTAssertEqual(chat.date, 1762174900)
        XCTAssertEqual(chat.dateUsec, 123456)
        XCTAssertEqual(chat.mail, "184 ue red")
        XCTAssertEqual(chat.userID, "nicolive:1234567")
        XCTAssertEqual(chat.niconicoUserID, "1234567")
        XCTAssertEqual(chat.content, "こんばんは")
        XCTAssertNil(chat.premium)
        XCTAssertEqual(chat.anonymity, 1)
        XCTAssertFalse(chat.yourPost)
        XCTAssertEqual(chat.score, 0)

        // 184 を消したうえで ue → top, red → #F02840
        XCTAssertEqual(chat.commands.position, .top)
        XCTAssertEqual(chat.commands.color, "#F02840")
        XCTAssertEqual(chat.commands.size, .medium)
    }

    func testOwnChat() throws {
        let message = try JikkyoCommentSessionMessage.decode(JikkyoFixtures.ownChatJSON)
        guard case .chat(let chat) = message else {
            return XCTFail("expected chat")
        }
        XCTAssertTrue(chat.yourPost)
        XCTAssertEqual(chat.niconicoUserID, "12345")
    }

    func testPremiumDecoding() throws {
        let message = try JikkyoCommentSessionMessage.decode(
            #"{"chat":{"no":1,"user_id":"nicolive:1","content":"公式","premium":3}}"#
        )
        guard case .chat(let chat) = message else {
            return XCTFail("expected chat")
        }
        XCTAssertEqual(chat.premium, "3")
        // 運営コマンド (/nicoad など) は premium=3 のときだけミュート対象
        XCTAssertTrue(
            CommentMuteFilter.isSpecialCommandComment("/nicoad テスト", premium: chat.premium)
        )
    }

    func testUnknownCommentSessionMessage() throws {
        let message = try JikkyoCommentSessionMessage.decode(#"{"foo":{"a":1}}"#)
        guard case .unknown(let unknown) = message else {
            return XCTFail("expected unknown")
        }
        XCTAssertEqual(unknown.type, "foo")
    }
}

// MARK: - Danmaku conversion

final class CommentDanmakuTests: XCTestCase {

    func testPastCommentConversion() {
        let comment = JikkyoComment(
            time: 12.34,
            type: .top,
            size: .big,
            color: "#F02840",
            author: "AbCdEfGhIjKl",
            text: "テストコメント"
        )
        let danmaku = CommentDanmaku(pastComment: comment)
        XCTAssertEqual(danmaku.text, "テストコメント")
        XCTAssertEqual(danmaku.color, "#F02840")
        XCTAssertEqual(danmaku.position, .top)
        XCTAssertEqual(danmaku.size, .big)
        XCTAssertEqual(danmaku.time, 12.34)
        XCTAssertEqual(danmaku.authorID, "AbCdEfGhIjKl")
        XCTAssertFalse(danmaku.isOwnComment)
        XCTAssertNil(danmaku.commentNumber)
    }

    func testChatConversion() throws {
        let message = try JikkyoCommentSessionMessage.decode(JikkyoFixtures.chatJSON)
        guard case .chat(let chat) = message else {
            return XCTFail("expected chat")
        }
        let danmaku = CommentDanmaku(chat: chat)
        XCTAssertEqual(danmaku.text, "こんばんは")
        XCTAssertEqual(danmaku.position, .top)
        XCTAssertEqual(danmaku.color, "#F02840")
        XCTAssertEqual(danmaku.time, 1234.56, accuracy: 0.0001)
        XCTAssertEqual(danmaku.authorID, "nicolive:1234567")
        XCTAssertFalse(danmaku.isOwnComment)
        XCTAssertEqual(danmaku.commentNumber, 4021)
        XCTAssertEqual(danmaku.date, 1762174900)
    }

    func testOwnCommentConversion() throws {
        let own = CommentDanmaku.ownComment(
            text: "自分のコメント",
            color: CommentCommands.defaultColor,
            position: .scroll,
            size: .medium,
            time: 42,
            authorID: "12345"
        )
        XCTAssertTrue(own.isOwnComment)
        XCTAssertEqual(own.authorID, "12345")
        XCTAssertEqual(own.time, 42)
        XCTAssertEqual(own.position, .scroll)
    }

    func testColorTableMatchesWebClient() {
        XCTAssertEqual(CommentCommands.color(for: "white"), "#FFEAEA")
        XCTAssertEqual(CommentCommands.color(for: "red"), "#F02840")
        XCTAssertEqual(CommentCommands.color(for: "pink"), "#FD7E80")
        XCTAssertEqual(CommentCommands.color(for: "orange"), "#FDA708")
        XCTAssertEqual(CommentCommands.color(for: "yellow"), "#FFE133")
        XCTAssertEqual(CommentCommands.color(for: "green"), "#64DD17")
        XCTAssertEqual(CommentCommands.color(for: "cyan"), "#00D4F5")
        XCTAssertEqual(CommentCommands.color(for: "blue"), "#4763FF")
        XCTAssertEqual(CommentCommands.color(for: "purple"), "#D500F9")
        XCTAssertEqual(CommentCommands.color(for: "black"), "#1E1310")
        XCTAssertEqual(CommentCommands.color(for: "white2"), "#CCCC99")
        XCTAssertEqual(CommentCommands.color(for: "niconicowhite"), "#CCCC99")
        XCTAssertEqual(CommentCommands.color(for: "truered"), "#CC0033")
        XCTAssertEqual(CommentCommands.color(for: "passionorange"), "#FF6600")
        XCTAssertEqual(CommentCommands.color(for: "madyellow"), "#999900")
        XCTAssertEqual(CommentCommands.color(for: "elementalgreen"), "#00CC66")
        XCTAssertEqual(CommentCommands.color(for: "marineblue"), "#3399FF")
        XCTAssertEqual(CommentCommands.color(for: "nobleviolet"), "#6633CC")
        XCTAssertEqual(CommentCommands.color(for: "black2"), "#666666")

        // A raw #RRGGBB passes through, anything else is not a colour.
        XCTAssertEqual(CommentCommands.color(for: "#12AB34"), "#12AB34")
        XCTAssertNil(CommentCommands.color(for: "#12ab3"))
        XCTAssertNil(CommentCommands.color(for: "notacolor"))
        XCTAssertNil(CommentCommands.color(for: ""))
    }

    func testPositionAndSizeCommands() {
        XCTAssertEqual(CommentCommands.position(for: "ue"), .top)
        XCTAssertEqual(CommentCommands.position(for: "naka"), .scroll)
        XCTAssertEqual(CommentCommands.position(for: "shita"), .bottom)
        XCTAssertNil(CommentCommands.position(for: "right"))

        XCTAssertEqual(CommentCommands.size(for: "big"), .big)
        XCTAssertEqual(CommentCommands.size(for: "medium"), .medium)
        XCTAssertEqual(CommentCommands.size(for: "small"), .small)
        XCTAssertNil(CommentCommands.size(for: "huge"))
    }

    func testParseCommandDefaults() {
        let defaults = CommentCommands.parse(mail: nil)
        XCTAssertEqual(defaults.color, "#FFEAEA")
        XCTAssertEqual(defaults.position, .scroll)
        XCTAssertEqual(defaults.size, .medium)

        XCTAssertEqual(CommentCommands.parse(mail: "").position, .scroll)

        // 184 は匿名コメントのマーカーで、色・位置・サイズではない
        let styled = CommentCommands.parse(mail: "184 shita big blue2")
        XCTAssertEqual(styled.position, .bottom)
        XCTAssertEqual(styled.size, .big)
        XCTAssertEqual(styled.color, "#3399FF")
    }

    func testParseCommandLastValueWins() {
        let style = CommentCommands.parse(mail: "red ue big blue shita small")
        XCTAssertEqual(style.color, "#4763FF")
        XCTAssertEqual(style.position, .bottom)
        XCTAssertEqual(style.size, .small)
    }
}

// MARK: - User facing messages

final class JikkyoMessagesTests: XCTestCase {

    func testServiceDetection() {
        XCTAssertEqual(
            JikkyoService(watchSessionURL: "wss://a.live.nicovideo.jp/api/v1/watch/x/watch"),
            .nicolive
        )
        XCTAssertEqual(
            JikkyoService(watchSessionURL: "wss://nx-jikkyo.konomi.tv/api/v1/sessions/gr011/watch"),
            .nxjikkyo
        )
        XCTAssertEqual(JikkyoService(watchSessionURL: nil), .nxjikkyo)

        XCTAssertEqual(JikkyoService.nicolive.displayName, "ニコニコ実況")
        XCTAssertEqual(JikkyoService.nxjikkyo.displayName, "NX-Jikkyo")
        // The trailing space of "NX-Jikkyo " is intentional in the web client.
        XCTAssertEqual(JikkyoService.nxjikkyo.noticePrefix, "NX-Jikkyo ")
        XCTAssertEqual(JikkyoService.nicolive.noticePrefix, "ニコニコ実況")
    }

    func testWatchSessionErrorMessages() {
        XCTAssertEqual(
            JikkyoMessages.watchSessionError(service: .nxjikkyo, code: "CONNECT_ERROR"),
            "NX-Jikkyo のコメントサーバーに接続できません。"
        )
        XCTAssertEqual(
            JikkyoMessages.watchSessionError(service: .nicolive, code: "NO_PERMISSION"),
            "ニコニコ実況の API にアクセスする権限がありません。"
        )
        XCTAssertEqual(
            JikkyoMessages.watchSessionError(service: .nxjikkyo, code: "INTERNAL_SERVERERROR"),
            "NX-Jikkyo でサーバーエラーが発生しています。"
        )
        XCTAssertEqual(
            JikkyoMessages.watchSessionError(service: .nxjikkyo, code: "SOMETHING_NEW"),
            "NX-Jikkyo でエラーが発生しています。(Code: SOMETHING_NEW)"
        )
        // Comment posting errors belong to the posting code path.
        XCTAssertEqual(
            JikkyoMessages.watchSessionError(service: .nxjikkyo, code: "INVALID_MESSAGE"),
            "コメント内容が無効です。"
        )
    }

    func testDisconnectReasonMessages() {
        XCTAssertEqual(
            JikkyoMessages.disconnectReason(service: .nxjikkyo, reason: "END_PROGRAM"),
            "NX-Jikkyo がリセットされたか、実況枠番組が終了しました。"
        )
        XCTAssertEqual(
            JikkyoMessages.disconnectReason(service: .nicolive, reason: "TAKEOVER"),
            "ニコニコ実況の番組から追い出されました。"
        )
        XCTAssertEqual(
            JikkyoMessages.disconnectReason(service: .nxjikkyo, reason: "PING_TIMEOUT"),
            "コメントサーバーとの接続生存確認に失敗しました。"
        )
        XCTAssertEqual(
            JikkyoMessages.disconnectReason(service: .nxjikkyo, reason: "WHATEVER"),
            "NX-Jikkyo との接続が切断されました。(WHATEVER)"
        )
    }

    func testConnectionMessages() {
        XCTAssertEqual(
            JikkyoMessages.watchSessionClosed(service: .nxjikkyo, code: "1006"),
            "NX-Jikkyo との接続が切断されました。(Code: 1006)"
        )
        XCTAssertEqual(
            JikkyoMessages.commentSessionClosed(code: "1006"),
            "NX-Jikkyo との接続が切断されました。(Code: 1006)"
        )
        XCTAssertEqual(
            JikkyoMessages.reconnecting(service: .nxjikkyo),
            "NX-Jikkyo に再接続しています…"
        )
        XCTAssertEqual(
            JikkyoMessages.commentPostError(code: "COMMENT_POST_NOT_ALLOWED"),
            "コメントが許可されていません。"
        )
        XCTAssertEqual(
            JikkyoMessages.commentPostError(code: "X"),
            "コメントの送信に失敗しました。(X)"
        )
        XCTAssertEqual(
            JikkyoMessages.nicoliveFallbackNotice(error: "エラーです。"),
            "エラーです。代わりに NX-Jikkyo にコメントします。"
        )
        XCTAssertEqual(
            JikkyoMessages.channelNotSupported,
            "このチャンネルはニコニコ実況に対応していません。"
        )
    }

    func testCommentAcceptance() throws {
        let message = try JikkyoCommentSessionMessage.decode(JikkyoFixtures.chatJSON)
        guard case .chat(let chat) = message else {
            return XCTFail("expected chat")
        }
        XCTAssertTrue(
            JikkyoCommentAcceptance.accepts(chat, isInitialComments: false, ownNiconicoUserID: 12345)
        )
        XCTAssertTrue(
            JikkyoCommentAcceptance.accepts(chat, isInitialComments: true)
        )

        // Own comment: dropped after the initial batch, kept while it streams in.
        let ownMessage = try JikkyoCommentSessionMessage.decode(JikkyoFixtures.ownChatJSON)
        guard case .chat(let own) = ownMessage else {
            return XCTFail("expected chat")
        }
        XCTAssertTrue(JikkyoCommentAcceptance.accepts(own, isInitialComments: true))
        XCTAssertFalse(JikkyoCommentAcceptance.accepts(own, isInitialComments: false))

        // Empty comments never count.
        var empty = chat
        empty.content = ""
        XCTAssertFalse(JikkyoCommentAcceptance.accepts(empty, isInitialComments: true))

        // Non-anonymous own comments are dropped by user ID too.
        XCTAssertFalse(
            JikkyoCommentAcceptance.accepts(chat, isInitialComments: true, ownNiconicoUserID: 1234567)
        )
    }
}
