import Foundation

// MARK: - Service

/// Which jikkyo service a watch session is talking to.
///
/// The web client decides this from the watch session URL
/// (`this.watch_session.type = url.includes('nicovideo.jp') ? …`) and puts the
/// name in front of every message it shows.
public enum JikkyoService: Sendable, Hashable, CaseIterable {
    /// NX-Jikkyo, KonomiTV's own Nicolive compatible service (the default).
    case nxjikkyo
    /// ニコニコ生放送 (only used when `prefer_posting_to_nicolive` is on and the
    /// user is linked to a Niconico account).
    case nicolive

    /// `watch_session_url` containing `nicovideo.jp` means Nicolive.
    public init(watchSessionURL: String?) {
        self = watchSessionURL?.contains("nicovideo.jp") == true ? .nicolive : .nxjikkyo
    }

    /// The name as it appears in the middle of a sentence.
    public var displayName: String {
        switch self {
        case .nxjikkyo: return "NX-Jikkyo"
        case .nicolive: return "ニコニコ実況"
        }
    }

    /// The prefix the web client interpolates into its messages. NX-Jikkyo
    /// keeps a trailing space on purpose so the English name and the following
    /// Japanese text do not run together (see `LiveCommentManager.ts`).
    public var noticePrefix: String {
        switch self {
        case .nxjikkyo: return "NX-Jikkyo "
        case .nicolive: return "ニコニコ実況"
        }
    }

    /// True when the session posts to Nicolive, which needs a premium account
    /// for fixed / big comments.
    public var isNicolive: Bool {
        self == .nicolive
    }
}

// MARK: - User facing messages

/// Every user facing text the live comment code shows, copied verbatim from
/// `client/src/services/player/managers/LiveCommentManager.ts`.
///
/// The messages are part of the app's behaviour (the web client shows the same
/// strings in its player notice bar), so they are kept exactly, including
/// punctuation and the missing space in `(Code: …)`.
public enum JikkyoMessages {

    // MARK: Session setup

    /// Shown when `GET /api/channels/{id}/jikkyo` failed.
    public static let webSocketInfoUnavailable = "コメント受信用 WebSocket API の情報を取得できませんでした。"

    /// Shown when the channel has no Niconico Jikkyo channel
    /// (`watch_session_url` is null).
    public static let channelNotSupported = "このチャンネルはニコニコ実況に対応していません。"

    /// `IWatchSessionInfo.detail` of a successful watch session.
    public static let watchSessionEstablished = "視聴セッションを取得しました。"

    /// Nicolive watch session URL could not be fetched; the session silently
    /// falls back to NX-Jikkyo.
    public static func nicoliveFallbackNotice(error: String) -> String {
        "\(error)代わりに NX-Jikkyo にコメントします。"
    }

    // MARK: Connection state

    /// The watch session socket closed by itself (network loss).
    public static func watchSessionClosed(service: JikkyoService, code: String) -> String {
        "\(service.noticePrefix)との接続が切断されました。(Code: \(code))"
    }

    /// The comment session socket closed.
    public static func commentSessionClosed(code: String) -> String {
        "NX-Jikkyo との接続が切断されました。(Code: \(code))"
    }

    /// Shown while reconnecting.
    public static func reconnecting(service: JikkyoService) -> String {
        "\(service.noticePrefix)に再接続しています…"
    }

    // MARK: Watch session errors

    /// `type: "error"` mapped to the web client's Japanese text.
    ///
    /// `COMMENT_POST_NOT_ALLOWED` and `INVALID_MESSAGE` are not session errors;
    /// they are the answer to a `postComment` and belong to
    /// `commentPostError(code:)`. Use `JikkyoWatchSessionError.isCommentPostError`
    /// to tell them apart.
    public static func watchSessionError(service: JikkyoService, code: String) -> String {
        switch code {
        case "CONNECT_ERROR":
            return "\(service.noticePrefix)のコメントサーバーに接続できません。"
        case "CONTENT_NOT_READY":
            return "\(service.noticePrefix)が配信できない状態です。"
        case "NO_THREAD_AVAILABLE":
            return "\(service.noticePrefix)のコメントスレッドを取得できません。"
        case "NO_ROOM_AVAILABLE":
            return "\(service.noticePrefix)のコメント部屋を取得できません。"
        case "NO_PERMISSION":
            return "\(service.noticePrefix)の API にアクセスする権限がありません。"
        case "NOT_ON_AIR":
            return "\(service.noticePrefix)が放送中ではありません。"
        case "BROADCAST_NOT_FOUND":
            return "\(service.noticePrefix)の配信情報を取得できません。"
        case "INTERNAL_SERVERERROR":
            return "\(service.noticePrefix)でサーバーエラーが発生しています。"
        case "COMMENT_POST_NOT_ALLOWED":
            return commentPostError(code: code)
        case "INVALID_MESSAGE":
            return commentPostError(code: code)
        default:
            return "\(service.noticePrefix)でエラーが発生しています。(Code: \(code))"
        }
    }

    // MARK: Disconnect reasons

    /// `type: "disconnect"` mapped to the web client's Japanese text. A
    /// disconnect message means the server closes the socket on purpose, so the
    /// client must not run its own close handling.
    public static func disconnectReason(service: JikkyoService, reason: String) -> String {
        switch reason {
        case "TAKEOVER":
            return "\(service.noticePrefix)の番組から追い出されました。"
        case "NO_PERMISSION":
            return "\(service.noticePrefix)の番組の座席を取得できませんでした。"
        case "END_PROGRAM":
            return "\(service.noticePrefix)がリセットされたか、実況枠番組が終了しました。"
        case "PING_TIMEOUT":
            return "コメントサーバーとの接続生存確認に失敗しました。"
        case "TOO_MANY_CONNECTIONS":
            return "\(service.noticePrefix)の同一ユーザからの接続数上限を越えています。"
        case "TOO_MANY_WATCHINGS":
            return "\(service.noticePrefix)の同一ユーザからの視聴番組数上限を越えています。"
        case "CROWDED":
            return "\(service.noticePrefix)の番組が満席です。"
        case "MAINTENANCE_IN":
            return "\(service.noticePrefix)はメンテナンス中です。"
        case "SERVICE_TEMPORARILY_UNAVAILABLE":
            return "\(service.noticePrefix)で一時的にサーバーエラーが発生しています。"
        default:
            return "\(service.noticePrefix)との接続が切断されました。(\(reason))"
        }
    }

    // MARK: Comment posting

    /// Shown when the socket is not open while posting.
    public static let commentPostNotConnected = "コメントの送信に失敗しました。WebSocket 接続が確立されていません。"

    /// `type: "error"` right after a `postComment`.
    public static func commentPostError(code: String) -> String {
        switch code {
        case "COMMENT_POST_NOT_ALLOWED":
            return "コメントが許可されていません。"
        case "INVALID_MESSAGE":
            return "コメント内容が無効です。"
        default:
            return "コメントの送信に失敗しました。(\(code))"
        }
    }

    /// Nicolive rejects fixed comments for non-premium accounts.
    public static let premiumRequiredForPosition =
        "ニコニコ実況でコメントを上下に固定するには、ニコニコアカウントのプレミアム会員登録が必要です。"

    /// Nicolive rejects big comments for non-premium accounts.
    public static let premiumRequiredForSize =
        "ニコニコ実況でコメントサイズを大きめに設定するには、ニコニコアカウントのプレミアム会員登録が必要です。"

    /// `prefer_posting_to_nicolive` is on but the user is not logged in.
    public static let loginRequiredForNicolive =
        "ニコニコ実況にコメントするには、KonomiTV アカウントにログインしてください。代わりに NX-Jikkyo にコメントします。"

    /// `prefer_posting_to_nicolive` is on but no Niconico account is linked.
    public static let niconicoLinkRequiredForNicolive =
        "ニコニコ実況にコメントするには、ニコニコアカウントと連携してください。代わりに NX-Jikkyo にコメントします。"
}
