import Foundation

// MARK: - Incoming comment session messages

/// A message of the jikkyo comment session WebSocket.
///
/// The comment session speaks the same `chat` protocol as the old Nicolive
/// comment server: after the client sends the thread request the server answers
/// with a `thread` result, streams up to 100 past comments, terminates that
/// batch with `{"ping":{"content":"rf:0"}}` and then sends every new comment as
/// its own `chat` message.
public enum JikkyoCommentSessionMessage: Sendable, Hashable {
    /// Answer to the thread request; `resultCode == 0` means success.
    case thread(JikkyoCommentThreadResult)
    /// Protocol ping ("rs:0", "ps:0", "pf:0", "rf:0").
    case ping(String)
    /// One comment.
    case chat(JikkyoChatComment)
    case unknown(JikkyoUnknownMessage)

    /// True for the `rf:0` ping that ends the batch of past comments the server
    /// sends right after the thread request.
    public var isInitialCommentsEnd: Bool {
        if case .ping(let content) = self {
            return content == "rf:0"
        }
        return false
    }

    /// Decodes one WebSocket text message.
    public static func decode(_ text: String) throws -> JikkyoCommentSessionMessage {
        guard let data = text.data(using: .utf8) else {
            throw JikkyoProtocolError.invalidUTF8
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> JikkyoCommentSessionMessage {
        let root = try JikkyoProtocol.decodeObject(data)

        if let thread = root["thread"] {
            return .thread(JikkyoCommentThreadResult(json: thread))
        }
        if let ping = root["ping"] {
            return .ping(ping["content"]?.stringValue ?? "")
        }
        if let chat = root["chat"] {
            guard let comment = JikkyoChatComment(json: chat) else {
                return .unknown(JikkyoUnknownMessage(type: "chat", data: chat))
            }
            return .chat(comment)
        }

        let keys = root.keys.sorted()
        return .unknown(JikkyoUnknownMessage(type: keys.first ?? "", data: .object(root)))
    }
}

/// `{"thread":{...}}` answer to the thread request.
public struct JikkyoCommentThreadResult: Sendable, Hashable {
    /// 0 = connected, anything else is an error code
    /// (`LiveCommentManager.ts` logs "Connection failed. (Code: …)").
    public var resultCode: Int
    public var threadID: String?
    public var raw: JSONValue?

    public init(resultCode: Int = 0, threadID: String? = nil, raw: JSONValue? = nil) {
        self.resultCode = resultCode
        self.threadID = threadID
        self.raw = raw
    }

    init(json: JSONValue?) {
        resultCode = json?["resultcode"]?.intValue ?? 0
        threadID = json?["thread"]?.stringValue
        raw = json
    }

    public var isSuccess: Bool {
        resultCode == 0
    }
}

// MARK: - Chat comment

/// One `chat` message of the comment session.
public struct JikkyoChatComment: Sendable, Hashable {
    /// Comment number on the thread (`no`).
    public var number: Int?
    public var threadID: String?
    /// Time in 10 ms units from `vposBaseTime`.
    public var vpos: Int
    /// UNIX timestamp in seconds.
    public var date: Double?
    public var dateUsec: Int?
    /// Niconico comment commands (`184 ue big red`).
    public var mail: String?
    /// "nicolive:1234567" for non-anonymous comments, a hash otherwise.
    public var userID: String
    public var content: String
    /// Niconico premium flag; "3" marks an official (運営) comment.
    public var premium: String?
    public var anonymity: Int?
    /// 1 when the comment was posted by this session's user.
    public var yourPost: Bool
    public var score: Int?
    public var raw: JSONValue?

    public init(
        number: Int? = nil,
        threadID: String? = nil,
        vpos: Int = 0,
        date: Double? = nil,
        dateUsec: Int? = nil,
        mail: String? = nil,
        userID: String = "",
        content: String = "",
        premium: String? = nil,
        anonymity: Int? = nil,
        yourPost: Bool = false,
        score: Int? = nil,
        raw: JSONValue? = nil
    ) {
        self.number = number
        self.threadID = threadID
        self.vpos = vpos
        self.date = date
        self.dateUsec = dateUsec
        self.mail = mail
        self.userID = userID
        self.content = content
        self.premium = premium
        self.anonymity = anonymity
        self.yourPost = yourPost
        self.score = score
        self.raw = raw
    }

    init?(json: JSONValue?) {
        guard let object = json?.objectValue else { return nil }
        number = object["no"]?.intValue
        threadID = object["thread"]?.stringValue
        vpos = object["vpos"]?.intValue ?? 0
        date = object["date"]?.numberValue
        dateUsec = object["date_usec"]?.intValue
        mail = object["mail"]?.stringValue
        userID = object["user_id"]?.stringValue ?? ""
        content = object["content"]?.stringValue ?? ""
        premium = JikkyoProtocol.premiumText(from: object["premium"])
        anonymity = object["anonymity"]?.intValue
        // `yourpost` is 1 (or true) for the user's own comments.
        if let flag = object["yourpost"]?.numberValue {
            yourPost = flag == 1
        } else {
            yourPost = object["yourpost"]?.boolValue ?? false
        }
        score = object["score"]?.intValue
        raw = json
    }

    /// Position on the program timeline in seconds (`vpos` is 10 ms units).
    public var time: Double {
        Double(vpos) / 100
    }

    /// The user ID without the `nicolive:` prefix non-anonymous comments carry.
    public var niconicoUserID: String {
        userID.hasPrefix("nicolive:")
            ? String(userID.dropFirst("nicolive:".count))
            : userID
    }

    /// Colour / position / size after parsing `mail`.
    public var commands: CommentCommands.Style {
        CommentCommands.parse(mail: mail)
    }
}

// MARK: - Outgoing thread request

/// The first message the comment session expects: the thread request, wrapped
/// in the `rs:0` … `rf:0` ping sandwich the web client sends.
///
/// Without it the server does not send any comment at all.
public struct JikkyoCommentSessionRequest: Sendable, Hashable {
    /// Thread to subscribe to. The web client passes the room's `threadId`
    /// (or an empty string to attach to whatever thread is active).
    public var threadID: String
    /// Thread key (`yourPostKey`), which marks the user's own comments with
    /// `yourpost`. Omitted when nil, like `JSON.stringify` omits `undefined`.
    public var threadKey: String?
    /// How many past comments to receive with the connection (negative = the
    /// last N comments).
    public var resFrom: Int

    /// Fixed protocol version of the old Nicolive comment API.
    public static let version = "20061206"

    public init(threadID: String = "", threadKey: String? = nil, resFrom: Int = -100) {
        self.threadID = threadID
        self.threadKey = threadKey
        self.resFrom = resFrom
    }

    /// The exact JSON text the web client sends: the thread request wrapped in
    /// `rs:0` … `rf:0` pings.
    public var jsonString: String {
        var thread: [(String, String)] = [
            ("version", JikkyoJSON.string(JikkyoCommentSessionRequest.version)),
            ("thread", JikkyoJSON.string(threadID)),
        ]
        if let threadKey {
            thread.append(("threadkey", JikkyoJSON.string(threadKey)))
        }
        thread.append(("user_id", JikkyoJSON.string("")))
        thread.append(("res_from", JikkyoJSON.number(resFrom)))

        func ping(_ content: String) -> String {
            JikkyoJSON.object([
                ("ping", JikkyoJSON.object([("content", JikkyoJSON.string(content))])),
            ])
        }

        return JikkyoJSON.array([
            ping("rs:0"),
            ping("ps:0"),
            JikkyoJSON.object([("thread", JikkyoJSON.object(thread))]),
            ping("pf:0"),
            ping("rf:0"),
        ])
    }

    public var jsonData: Data {
        Data(jsonString.utf8)
    }
}
