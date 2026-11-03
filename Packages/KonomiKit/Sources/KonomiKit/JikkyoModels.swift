import Foundation

// MARK: - Jikkyo WebSocket info

/// WebSocket endpoints for a channel's live comments
/// (`GET /api/channels/{display_channel_id}/jikkyo`, schemas.JikkyoWebSocketInfo).
///
/// The watch session is the long lived connection that keeps a comment "seat"
/// and sends comments. The comment session is the separate connection that
/// streams the comments themselves. Both are plain `ws://` / `wss://` URLs the
/// server hands out; KonomiKit only carries them, the app opens them with
/// `URLSessionWebSocketTask`.
public struct JikkyoWebSocketInfo: Codable, Sendable, Hashable {
    /// Watch session WebSocket URL (NX-Jikkyo, compatible with the old
    /// Nicolive WebSocket API). `nil` when the channel has no Niconico Jikkyo
    /// channel at all — the web client then shows
    /// "このチャンネルはニコニコ実況に対応していません。".
    public var watchSessionURL: String?
    /// Nicolive watch session URL. Only set when the KonomiTV user is linked to
    /// a Niconico account and a Nicolive program is on air.
    public var nicoliveWatchSessionURL: String?
    /// Error Niconico returned while fetching the Nicolive watch session URL.
    public var nicoliveWatchSessionError: String?
    /// Comment session WebSocket URL (always NX-Jikkyo: the Nicolive NDGR
    /// message server is not a WebSocket and cannot be used from the browser).
    public var commentSessionURL: String?
    /// True when the channel only exists in NX-Jikkyo (e.g. BS日テレ), so the
    /// Nicolive fallback warning can be skipped.
    public var isNXJikkyoExclusive: Bool

    public init(
        watchSessionURL: String? = nil,
        nicoliveWatchSessionURL: String? = nil,
        nicoliveWatchSessionError: String? = nil,
        commentSessionURL: String? = nil,
        isNXJikkyoExclusive: Bool = false
    ) {
        self.watchSessionURL = watchSessionURL
        self.nicoliveWatchSessionURL = nicoliveWatchSessionURL
        self.nicoliveWatchSessionError = nicoliveWatchSessionError
        self.commentSessionURL = commentSessionURL
        self.isNXJikkyoExclusive = isNXJikkyoExclusive
    }

    private enum CodingKeys: String, CodingKey {
        case watchSessionURL = "watch_session_url"
        case nicoliveWatchSessionURL = "nicolive_watch_session_url"
        case nicoliveWatchSessionError = "nicolive_watch_session_error"
        case commentSessionURL = "comment_session_url"
        case isNXJikkyoExclusive = "is_nxjikkyo_exclusive"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watchSessionURL = container.lenient(String.self, forKey: .watchSessionURL)
        nicoliveWatchSessionURL = container.lenient(String.self, forKey: .nicoliveWatchSessionURL)
        nicoliveWatchSessionError = container.lenient(String.self, forKey: .nicoliveWatchSessionError)
        commentSessionURL = container.lenient(String.self, forKey: .commentSessionURL)
        isNXJikkyoExclusive =
            container.lenient(Bool.self, forKey: .isNXJikkyoExclusive) ?? false
    }

    /// Watch session URL as a `URL`, when the server returned one.
    public var watchSessionURLValue: URL? {
        watchSessionURL.flatMap(Self.url(from:))
    }

    /// Nicolive watch session URL as a `URL`, when the server returned one.
    public var nicoliveWatchSessionURLValue: URL? {
        nicoliveWatchSessionURL.flatMap(Self.url(from:))
    }

    /// Comment session URL as a `URL`, when the server returned one.
    public var commentSessionURLValue: URL? {
        commentSessionURL.flatMap(Self.url(from:))
    }

    private static func url(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }
}

// MARK: - Past log comments

/// One comment of a recorded program's past log
/// (`GET /api/videos/{id}/jikkyo`, schemas.JikkyoComment).
///
/// `time` is the offset in seconds from the start of the recording; the server
/// already converts Nicolive's `vpos` and shifts the times when the recording
/// was cut.
public struct JikkyoComment: Codable, Sendable, Hashable {
    public var time: Double
    public var type: CommentDanmaku.Position
    public var size: CommentDanmaku.Size
    /// `#RRGGBB` colour, already resolved from the Niconico colour command.
    public var color: String
    /// Niconico user ID ("nicolive:1234567" for non-anonymous comments).
    public var author: String
    public var text: String

    public init(
        time: Double = 0,
        type: CommentDanmaku.Position = .scroll,
        size: CommentDanmaku.Size = .medium,
        color: String = CommentCommands.defaultColor,
        author: String = "",
        text: String = ""
    ) {
        self.time = time
        self.type = type
        self.size = size
        self.color = color
        self.author = author
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = container.lenient(Double.self, forKey: .time) ?? 0
        type = CommentDanmaku.Position(
            rawValue: container.lenient(String.self, forKey: .type) ?? ""
        ) ?? .scroll
        size = CommentDanmaku.Size(
            rawValue: container.lenient(String.self, forKey: .size) ?? ""
        ) ?? .medium
        color = container.lenient(String.self, forKey: .color) ?? CommentCommands.defaultColor
        author = container.lenient(String.self, forKey: .author) ?? ""
        text = container.lenient(String.self, forKey: .text) ?? ""
    }
}

/// The past log of one recorded program (schemas.JikkyoComments).
public struct JikkyoComments: Codable, Sendable, Hashable {
    public var isSuccess: Bool
    public var comments: [JikkyoComment]
    public var detail: String

    public init(
        isSuccess: Bool = true,
        comments: [JikkyoComment] = [],
        detail: String = ""
    ) {
        self.isSuccess = isSuccess
        self.comments = comments
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case isSuccess = "is_success"
        case comments
        case detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSuccess = container.lenient(Bool.self, forKey: .isSuccess) ?? false
        comments = container.lenient([JikkyoComment].self, forKey: .comments) ?? []
        detail = container.lenient(String.self, forKey: .detail) ?? ""
    }
}

// MARK: - Niconico account linking

/// `GET /api/niconico/auth` (schemas.ThirdpartyAuthURL).
///
/// Open `authorizationURL` in a browser (or `ASWebAuthenticationSession`) and
/// Niconico sends the user back to the server's `/api/niconico/callback`, which
/// links the account and then redirects to `{client}/settings/jikkyo`.
public struct NiconicoAuthURL: Codable, Sendable, Hashable {
    public var authorizationURL: URL?

    public init(authorizationURL: URL? = nil) {
        self.authorizationURL = authorizationURL
    }

    private enum CodingKeys: String, CodingKey {
        case authorizationURL = "authorization_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authorizationURL = (container.lenient(String.self, forKey: .authorizationURL))
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
