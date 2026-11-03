import Foundation

// MARK: - Niconico comment commands

/// Niconico comment commands (`mail`) and the player's danmaku vocabulary.
///
/// Ported from `client/src/utils/CommentUtils.ts`
/// (`getCommentColor` / `getCommentPosition` / `getCommentSize` /
/// `parseCommentCommand`), including the exact colour table.
public enum CommentCommands {

    /// The colour a comment gets when `mail` has no colour command.
    public static let defaultColor = "#FFEAEA"

    /// Colour parsed out of a comment, with the web client's defaults.
    public struct Style: Sendable, Hashable {
        public var color: String
        public var position: CommentDanmaku.Position
        public var size: CommentDanmaku.Size

        public init(
            color: String = CommentCommands.defaultColor,
            position: CommentDanmaku.Position = .scroll,
            size: CommentDanmaku.Size = .medium
        ) {
            self.color = color
            self.position = position
            self.size = size
        }
    }

    /// Niconico colour command → `#RRGGBB`.
    public static let colorTable: [String: String] = [
        "white": "#FFEAEA",
        "red": "#F02840",
        "pink": "#FD7E80",
        "orange": "#FDA708",
        "yellow": "#FFE133",
        "green": "#64DD17",
        "cyan": "#00D4F5",
        "blue": "#4763FF",
        "purple": "#D500F9",
        "black": "#1E1310",
        "white2": "#CCCC99",
        "niconicowhite": "#CCCC99",
        "red2": "#CC0033",
        "truered": "#CC0033",
        "pink2": "#FF33CC",
        "orange2": "#FF6600",
        "passionorange": "#FF6600",
        "yellow2": "#999900",
        "madyellow": "#999900",
        "green2": "#00CC66",
        "elementalgreen": "#00CC66",
        "cyan2": "#00CCCC",
        "blue2": "#3399FF",
        "marineblue": "#3399FF",
        "purple2": "#6633CC",
        "nobleviolet": "#6633CC",
        "black2": "#666666",
    ]

    /// Resolves one command to a `#RRGGBB` colour, or nil when it is not a
    /// colour command. A `#RRGGBB` value passes through unchanged.
    public static func color(for command: String) -> String? {
        if isHexColor(command) {
            return command
        }
        return colorTable[command]
    }

    /// Resolves one command to a position, or nil when it is not a position
    /// command (`ue` = top, `naka` = scrolling, `shita` = bottom).
    public static func position(for command: String) -> CommentDanmaku.Position? {
        switch command {
        case "ue": return .top
        case "naka": return .scroll
        case "shita": return .bottom
        default: return nil
        }
    }

    /// Resolves one command to a size, or nil when it is not a size command.
    public static func size(for command: String) -> CommentDanmaku.Size? {
        CommentDanmaku.Size(rawValue: command)
    }

    /// Parses a whole `mail` value.
    ///
    /// The web client removes the first `184` (anonymous marker) and splits on
    /// spaces; later commands win, which is why the whole list is walked here
    /// too.
    public static func parse(mail: String?) -> Style {
        var style = Style()
        guard let mail else { return style }

        var withoutAnonymity = mail
        if let range = mail.range(of: "184") {
            withoutAnonymity = mail.replacingCharacters(in: range, with: "")
        }

        for command in withoutAnonymity.split(separator: " ", omittingEmptySubsequences: false) {
            let text = String(command)
            if let color = color(for: text) {
                style.color = color
            }
            if let position = position(for: text) {
                style.position = position
            }
            if let size = size(for: text) {
                style.size = size
            }
        }
        return style
    }

    /// `^#[0-9A-Fa-f]{6}$`
    static func isHexColor(_ value: String) -> Bool {
        guard value.count == 7, value.hasPrefix("#") else { return false }
        return value.dropFirst().allSatisfy { character in
            character.isASCII && (character.isHexDigit)
        }
    }
}

// MARK: - Danmaku

/// A comment ready to be drawn by the player.
///
/// Live comments and past log comments both convert to this type, so the
/// overlay only ever deals with one shape. `time` is the position on the
/// program / video timeline in seconds; for live comments it comes from
/// `vpos`, for past log comments from the recorded timeline the server
/// already normalised.
public struct CommentDanmaku: Sendable, Hashable {
    /// Where the comment is drawn: scrolling right to left, fixed at the top,
    /// or fixed at the bottom. The raw values are DPlayer's.
    public enum Position: String, Codable, Sendable, Hashable, CaseIterable {
        case scroll = "right"
        case top
        case bottom
    }

    /// Comment text size. The raw values are both Niconico's and DPlayer's.
    public enum Size: String, Codable, Sendable, Hashable, CaseIterable {
        case big
        case medium
        case small
    }

    public var text: String
    /// `#RRGGBB`.
    public var color: String
    public var position: Position
    public var size: Size
    /// Seconds from the start of the program / video.
    public var time: Double
    /// Niconico user ID of the author ("nicolive:1234567" or a hash).
    public var authorID: String
    /// True for comments this user posted.
    public var isOwnComment: Bool
    /// Comment number on the thread, when the server sent one.
    public var commentNumber: Int?
    /// UNIX timestamp of the comment, when known.
    public var date: Double?

    public init(
        text: String,
        color: String = CommentCommands.defaultColor,
        position: Position = .scroll,
        size: Size = .medium,
        time: Double = 0,
        authorID: String = "",
        isOwnComment: Bool = false,
        commentNumber: Int? = nil,
        date: Double? = nil
    ) {
        self.text = text
        self.color = color
        self.position = position
        self.size = size
        self.time = time
        self.authorID = authorID
        self.isOwnComment = isOwnComment
        self.commentNumber = commentNumber
        self.date = date
    }

    /// A past log comment (`GET /api/videos/{id}/jikkyo`). The server already
    /// resolved colour / position / size.
    public init(pastComment: JikkyoComment, isOwnComment: Bool = false) {
        self.init(
            text: pastComment.text,
            color: pastComment.color,
            position: pastComment.type,
            size: pastComment.size,
            time: pastComment.time,
            authorID: pastComment.author,
            isOwnComment: isOwnComment
        )
    }

    /// A live `chat` message. `isOwnComment` defaults to the `yourpost` flag
    /// the comment server sets on the session user's own comments.
    public init(chat: JikkyoChatComment, isOwnComment: Bool? = nil) {
        let style = chat.commands
        self.init(
            text: chat.content,
            color: style.color,
            position: style.position,
            size: style.size,
            time: chat.time,
            authorID: chat.userID,
            isOwnComment: isOwnComment ?? chat.yourPost,
            commentNumber: chat.number,
            date: chat.date
        )
    }

    /// A comment this user just posted. The watch session does not echo the
    /// posted comment back reliably, so the web client builds the entry from
    /// the values it sent (with the current time as the ID).
    public static func ownComment(
        text: String,
        color: String,
        position: Position,
        size: Size,
        time: Double,
        authorID: String,
        commentNumber: Int? = nil,
        date: Double? = nil
    ) -> CommentDanmaku {
        CommentDanmaku(
            text: text,
            color: color,
            position: position,
            size: size,
            time: time,
            authorID: authorID,
            isOwnComment: true,
            commentNumber: commentNumber,
            date: date
        )
    }
}
