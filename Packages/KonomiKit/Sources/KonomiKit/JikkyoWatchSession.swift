import Foundation

// MARK: - Timings

/// Fixed timings of the live comment connection, all taken from
/// `LiveCommentManager.ts` (the app schedules its timers from these).
///
/// The connection itself always runs in this order:
/// 1. `GET /api/channels/{display_channel_id}/jikkyo` for the two WebSocket URLs.
/// 2. Watch session socket: send `startWatching`, then wait for `seat`
///    (start the keep-alive timer) and `room` (comment session address).
/// 3. Comment session socket: send the thread request, receive the past
///    comments up to the `rf:0` ping, then one `chat` per new comment.
/// 4. Answer every `ping` on the watch session with `pong` and send
///    `keepSeat` every `seat.keepIntervalSec` seconds, or the seat is lost.
public enum JikkyoSessionTiming {
    /// The web client waits 3 s before re-creating both sessions after a
    /// socket closed, an error arrived or a `reconnect` message was received.
    public static let reconnectDelay: TimeInterval = 3

    /// Comments are handed to the UI in batches at most this often (the web
    /// client throttles its "CommentReceived" event to 333 ms).
    public static let commentEmitInterval: TimeInterval = 333.0 / 1000.0

    /// Keep-alive interval used when the server does not send a `seat`.
    public static let defaultKeepSeatInterval: TimeInterval = 30

    /// `keepIntervalSec` from a `seat` message, in seconds.
    public static func keepSeatInterval(seat: JikkyoSeat) -> TimeInterval {
        seat.keepIntervalSec > 0 ? seat.keepIntervalSec : defaultKeepSeatInterval
    }
}

// MARK: - Incoming watch session messages

/// A message of the jikkyo watch session WebSocket.
///
/// The protocol is the old Nicolive WebSocket API ("NX-Jikkyo" speaks the same
/// protocol). `LiveCommentManager.ts` only reacts to the types modelled here;
/// anything else is kept as `.unknown` so the app can log it without breaking.
public enum JikkyoWatchSessionMessage: Sendable, Hashable {
    /// Seat information. The client has to send `keepSeat` every
    /// `keepIntervalSec` seconds (`JikkyoWatchSessionMessage.seat` arrives once
    /// per watch session).
    case seat(JikkyoSeat)
    /// Keep alive request: answer with `JikkyoWatchSessionRequest.pong`, or the
    /// server closes the session.
    case ping
    /// An error the server reports. `COMMENT_POST_NOT_ALLOWED` and
    /// `INVALID_MESSAGE` are answers to a `postComment` and must not trigger a
    /// reconnect.
    case error(JikkyoWatchSessionError)
    /// The server asks the client to reconnect.
    case reconnect(JikkyoReconnect)
    /// The session was closed by the server (e.g. the 4 a.m. Nicolive reset).
    case disconnect(JikkyoDisconnect)
    /// Comment server information used by the comment session.
    case room(JikkyoRoom)
    /// Nicolive's NDGR replacement for `.room`: it carries no WebSocket
    /// address, so the comment session always connects to NX-Jikkyo.
    case messageServer(JikkyoMessageServer)
    /// The comment posted with `postComment` was accepted.
    case postCommentResult(JikkyoPostCommentResult)
    /// Viewer statistics.
    case statistics(JikkyoStatistics)
    /// A message type this client does not model.
    case unknown(JikkyoUnknownMessage)

    /// The `type` field as it arrived on the wire.
    public var rawType: String {
        switch self {
        case .seat: return "seat"
        case .ping: return "ping"
        case .error: return "error"
        case .reconnect: return "reconnect"
        case .disconnect: return "disconnect"
        case .room: return "room"
        case .messageServer: return "messageServer"
        case .postCommentResult: return "postCommentResult"
        case .statistics: return "statistics"
        case .unknown(let message): return message.type
        }
    }

    /// Decodes one WebSocket text message.
    public static func decode(_ text: String) throws -> JikkyoWatchSessionMessage {
        guard let data = text.data(using: .utf8) else {
            throw JikkyoProtocolError.invalidUTF8
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> JikkyoWatchSessionMessage {
        let root = try JikkyoProtocol.decodeObject(data)
        guard let type = root["type"]?.stringValue, !type.isEmpty else {
            throw JikkyoProtocolError.missingType
        }
        let payload = root["data"]

        switch type {
        case "seat":
            return .seat(JikkyoSeat(json: payload))
        case "ping":
            return .ping
        case "error":
            let code = payload?["code"]?.stringValue ?? ""
            return .error(JikkyoWatchSessionError(code: code, message: payload?["message"]?.stringValue))
        case "reconnect":
            return .reconnect(
                JikkyoReconnect(
                    waitTimeSec: payload?["waitTimeSec"]?.numberValue ?? 0,
                    audienceToken: payload?["audienceToken"]?.stringValue
                )
            )
        case "disconnect":
            return .disconnect(
                JikkyoDisconnect(reason: payload?["reason"]?.stringValue ?? "")
            )
        case "room":
            return .room(JikkyoRoom(json: payload))
        case "messageServer":
            return .messageServer(JikkyoMessageServer(json: payload))
        case "postCommentResult":
            return .postCommentResult(JikkyoPostCommentResult(json: payload))
        case "statistics":
            return .statistics(JikkyoStatistics(json: payload))
        default:
            return .unknown(JikkyoUnknownMessage(type: type, data: payload))
        }
    }
}

// MARK: - Watch session payloads

/// `seat` payload.
public struct JikkyoSeat: Sendable, Hashable {
    /// Seconds between `keepSeat` messages. The web client sends `keepSeat`
    /// every `keepIntervalSec * 1000` ms; the server closes the seat otherwise.
    public var keepIntervalSec: Double
    /// Raw payload, for logging and for fields this client does not model.
    public var raw: JSONValue?

    public init(keepIntervalSec: Double = 30, raw: JSONValue? = nil) {
        self.keepIntervalSec = keepIntervalSec
        self.raw = raw
    }

    init(json: JSONValue?) {
        let object = json?.objectValue
        let interval = object?["keepIntervalSec"]?.numberValue ?? 30
        keepIntervalSec = interval > 0 ? interval : 30
        raw = json
    }
}

/// `error` payload.
public struct JikkyoWatchSessionError: Sendable, Hashable {
    /// Protocol error code (e.g. `CONNECT_ERROR`).
    public var code: String
    /// Human readable text the server sometimes adds.
    public var message: String?

    public init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }

    /// Codes that answer a `postComment` and must be handled by the comment
    /// posting code path instead of the session error path.
    public var isCommentPostError: Bool {
        code == "COMMENT_POST_NOT_ALLOWED" || code == "INVALID_MESSAGE"
    }
}

/// `reconnect` payload.
public struct JikkyoReconnect: Sendable, Hashable {
    /// Seconds the server suggests waiting before reconnecting.
    public var waitTimeSec: Double
    /// Token the official protocol asks to be sent when reconnecting. The web
    /// client ignores it (it simply re-creates the whole session).
    public var audienceToken: String?

    public init(waitTimeSec: Double = 0, audienceToken: String? = nil) {
        self.waitTimeSec = waitTimeSec
        self.audienceToken = audienceToken
    }
}

/// `disconnect` payload.
public struct JikkyoDisconnect: Sendable, Hashable {
    /// Disconnect reason code (e.g. `END_PROGRAM`).
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// `room` payload: everything needed to open the comment session.
public struct JikkyoRoom: Sendable, Hashable {
    /// Time `vpos` counts from (the start of the current program).
    public var vposBaseTime: Date?
    /// Thread ID the comment session has to request; empty means "whatever
    /// thread is currently active".
    public var threadID: String
    /// Comment server WebSocket address.
    public var messageServerURL: String?
    /// Key that marks the user's own comments with `yourpost`.
    public var yourPostKey: String?
    public var raw: JSONValue?

    public init(
        vposBaseTime: Date? = nil,
        threadID: String = "",
        messageServerURL: String? = nil,
        yourPostKey: String? = nil,
        raw: JSONValue? = nil
    ) {
        self.vposBaseTime = vposBaseTime
        self.threadID = threadID
        self.messageServerURL = messageServerURL
        self.yourPostKey = yourPostKey
        self.raw = raw
    }

    init(json: JSONValue?) {
        let object = json?.objectValue
        vposBaseTime = JikkyoProtocol.date(from: object?["vposBaseTime"])
        threadID = object?["threadId"]?.stringValue ?? ""
        messageServerURL = object?["messageServer"]?["uri"]?.stringValue
        yourPostKey = object?["yourPostKey"]?.stringValue
        raw = json
    }
}

/// `messageServer` payload (Nicolive only, from 2024/08/05 on).
public struct JikkyoMessageServer: Sendable, Hashable {
    public var vposBaseTime: Date?
    /// Anonymous user ID of the logged in user; own comments carry it.
    public var hashedUserID: String?
    public var raw: JSONValue?

    public init(vposBaseTime: Date? = nil, hashedUserID: String? = nil, raw: JSONValue? = nil) {
        self.vposBaseTime = vposBaseTime
        self.hashedUserID = hashedUserID
        self.raw = raw
    }

    init(json: JSONValue?) {
        let object = json?.objectValue
        vposBaseTime = JikkyoProtocol.date(from: object?["vposBaseTime"])
        hashedUserID = object?["hashedUserId"]?.stringValue
        raw = json
    }
}

/// `postCommentResult` payload.
public struct JikkyoPostCommentResult: Sendable, Hashable {
    /// The comment as the server stored it, when it echoes one back.
    public var chat: JikkyoChatComment?
    public var raw: JSONValue?

    public init(chat: JikkyoChatComment? = nil, raw: JSONValue? = nil) {
        self.chat = chat
        self.raw = raw
    }

    init(json: JSONValue?) {
        chat = json?["chat"].flatMap(JikkyoChatComment.init(json:))
        raw = json
    }
}

/// `statistics` payload.
public struct JikkyoStatistics: Sendable, Hashable {
    public var raw: JSONValue?

    public init(raw: JSONValue? = nil) {
        self.raw = raw
    }

    init(json: JSONValue?) {
        raw = json
    }
}

/// A watch session message type this client does not model.
public struct JikkyoUnknownMessage: Sendable, Hashable {
    public var type: String
    public var data: JSONValue?

    public init(type: String, data: JSONValue? = nil) {
        self.type = type
        self.data = data
    }
}

// MARK: - Outgoing watch session messages

/// A request sent on the jikkyo watch session WebSocket.
public enum JikkyoWatchSessionRequest: Sendable, Hashable {
    /// Must be the first message after the socket opens. The web client always
    /// sends `reconnect: false` (it re-creates the whole session instead of
    /// resuming it) and never sends the optional `stream` field.
    case startWatching(reconnect: Bool)
    /// Sent every `seat.keepIntervalSec` seconds to hold the seat.
    case keepSeat
    /// Answer to `.ping`.
    case pong
    /// Posts a comment.
    case postComment(JikkyoPostComment)

    /// The web client's initial `startWatching` message.
    public static var startWatching: JikkyoWatchSessionRequest {
        .startWatching(reconnect: false)
    }

    /// The exact JSON text the web client sends.
    public var jsonString: String {
        switch self {
        case .startWatching(let reconnect):
            return JikkyoJSON.object([
                ("type", JikkyoJSON.string("startWatching")),
                ("data", JikkyoJSON.object([("reconnect", JikkyoJSON.bool(reconnect))])),
            ])
        case .keepSeat:
            return JikkyoJSON.object([("type", JikkyoJSON.string("keepSeat"))])
        case .pong:
            return JikkyoJSON.object([("type", JikkyoJSON.string("pong"))])
        case .postComment(let comment):
            return comment.jsonString
        }
    }

    public var jsonData: Data {
        Data(jsonString.utf8)
    }
}

/// A comment to post on the watch session.
///
/// The web client maps DPlayer's colour/position back to the Niconico command
/// names and drops the field when the colour is unknown (`JSON.stringify`
/// skips `undefined`), which is what `color == nil` / `position == nil` does.
public struct JikkyoPostComment: Sendable, Hashable {
    public var text: String
    /// Niconico colour command (`white`, `red`, …) or `nil` to let the server
    /// use the default colour.
    public var color: String?
    /// Niconico position command (`ue`, `naka`, `shita`) or `nil`.
    public var position: String?
    public var size: CommentDanmaku.Size
    /// Time in 10 ms units from `vposBaseTime`.
    public var vpos: Int
    /// The web client always posts anonymous (184) comments.
    public var isAnonymous: Bool

    public init(
        text: String,
        color: String? = nil,
        position: String? = nil,
        size: CommentDanmaku.Size = .medium,
        vpos: Int = 0,
        isAnonymous: Bool = true
    ) {
        self.text = text
        self.color = color
        self.position = position
        self.size = size
        self.vpos = vpos
        self.isAnonymous = isAnonymous
    }

    /// Builds a comment from the values the player UI has (a `#RRGGBB` colour
    /// and a danmaku position) instead of the Niconico command names.
    public init(
        text: String,
        hexColor: String?,
        danmakuPosition: CommentDanmaku.Position,
        size: CommentDanmaku.Size,
        vpos: Int,
        isAnonymous: Bool = true
    ) {
        self.text = text
        self.color = hexColor.flatMap(JikkyoPostComment.niconicoColor(forHex:))
        self.position = JikkyoPostComment.niconicoPosition(for: danmakuPosition)
        self.size = size
        self.vpos = vpos
        self.isAnonymous = isAnonymous
    }

    /// `{"type":"postComment","data":{...}}` exactly as the web client sends it.
    public var jsonString: String {
        var members: [(String, String)] = [("text", JikkyoJSON.string(text))]
        if let color {
            members.append(("color", JikkyoJSON.string(color)))
        }
        if let position {
            members.append(("position", JikkyoJSON.string(position)))
        }
        members.append(("size", JikkyoJSON.string(size.rawValue)))
        members.append(("vpos", JikkyoJSON.number(vpos)))
        members.append(("isAnonymous", JikkyoJSON.bool(isAnonymous)))
        return JikkyoJSON.object([
            ("type", JikkyoJSON.string("postComment")),
            ("data", JikkyoJSON.object(members)),
        ])
    }

    public var jsonData: Data {
        Data(jsonString.utf8)
    }

    /// `vpos` from a wall clock time, like the web client's
    /// `Math.round((Date.now() - vposBaseTime) / 10)`: 10 ms units, rounded.
    ///
    /// `Math.round()` is `floor(x + 0.5)`, which is reproduced here so negative
    /// values round the same way too.
    public static func vpos(now: Date, vposBaseTime: Date) -> Int {
        Int((now.timeIntervalSince(vposBaseTime) * 100 + 0.5).rounded(.down))
    }

    /// DPlayer colour code → Niconico colour command, copied from
    /// `LiveCommentManager.sendComment()`.
    public static func niconicoColor(forHex hex: String) -> String? {
        niconicoColorTable[hex.uppercased()]
    }

    /// Niconico position command → DPlayer position.
    public static func niconicoPosition(for position: CommentDanmaku.Position) -> String {
        switch position {
        case .top: return "ue"
        case .scroll: return "naka"
        case .bottom: return "shita"
        }
    }

    /// DPlayer colour code → Niconico colour command.
    public static let niconicoColorTable: [String: String] = [
        "#FFEAEA": "white",
        "#F02840": "red",
        "#FD7E80": "pink",
        "#FDA708": "orange",
        "#FFE133": "yellow",
        "#64DD17": "green",
        "#00D4F5": "cyan",
        "#4763FF": "blue",
    ]

    /// The colours the player offers, in the order the web client lists them.
    public static var palette: [String] {
        ["#FFEAEA", "#F02840", "#FD7E80", "#FDA708", "#FFE133", "#64DD17", "#00D4F5", "#4763FF"]
    }
}
