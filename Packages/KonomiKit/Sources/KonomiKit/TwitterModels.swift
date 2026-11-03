import Foundation

// MARK: - Accounts

/// A Twitter account linked to the logged in user (GET /api/users/me).
public struct TwitterAccount: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    /// Screen name without the leading "@".
    public var screenName: String
    /// Absolute URL of the profile icon (Twitter serves a default icon too).
    public var iconURL: String
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: Int = 0,
        name: String = "",
        screenName: String = "",
        iconURL: String = "",
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.screenName = screenName
        self.iconURL = iconURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case screenName = "screen_name"
        case iconURL = "icon_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? 0
        name = container.lenient(String.self, forKey: .name) ?? ""
        screenName = container.lenient(String.self, forKey: .screenName) ?? ""
        iconURL = container.lenient(String.self, forKey: .iconURL) ?? ""
        createdAt = container.lenient(Date.self, forKey: .createdAt)
        updatedAt = container.lenient(Date.self, forKey: .updatedAt)
    }
}

/// A Bluesky account linked to the logged in user.
public struct BlueskyAccount: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    /// Decentralised identifier (did:plc:...).
    public var did: String
    public var handle: String
    public var name: String
    public var iconURL: String
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: Int = 0,
        did: String = "",
        handle: String = "",
        name: String = "",
        iconURL: String = "",
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.did = did
        self.handle = handle
        self.name = name
        self.iconURL = iconURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case did
        case handle
        case name
        case iconURL = "icon_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? 0
        did = container.lenient(String.self, forKey: .did) ?? ""
        handle = container.lenient(String.self, forKey: .handle) ?? ""
        name = container.lenient(String.self, forKey: .name) ?? ""
        iconURL = container.lenient(String.self, forKey: .iconURL) ?? ""
        createdAt = container.lenient(Date.self, forKey: .createdAt)
        updatedAt = container.lenient(Date.self, forKey: .updatedAt)
    }
}

/// A Twitter account paired with a Bluesky account
/// (POST /api/users/me/account-links).
///
/// A linked account posts to both services and merges both timelines.
public struct AccountLink: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var twitterAccount: TwitterAccount
    public var blueskyAccount: BlueskyAccount
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: Int = 0,
        twitterAccount: TwitterAccount = TwitterAccount(),
        blueskyAccount: BlueskyAccount = BlueskyAccount(),
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.twitterAccount = twitterAccount
        self.blueskyAccount = blueskyAccount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case twitterAccount = "twitter_account"
        case blueskyAccount = "bluesky_account"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? 0
        twitterAccount = container.lenient(TwitterAccount.self, forKey: .twitterAccount)
            ?? TwitterAccount()
        blueskyAccount = container.lenient(BlueskyAccount.self, forKey: .blueskyAccount)
            ?? BlueskyAccount()
        createdAt = container.lenient(Date.self, forKey: .createdAt)
        updatedAt = container.lenient(Date.self, forKey: .updatedAt)
    }
}

// MARK: - Panel account

/// The account chosen by the watch screen's Twitter tab.
///
/// Local UI state (the web client's selected_twitter_panel_account): it holds
/// database IDs, which mean different things on another server, so it is
/// deliberately not part of the synced client settings.
public struct TwitterPanelAccount: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case twitter = "Twitter"
        case bluesky = "Bluesky"
        case linked = "Linked"
    }

    public var kind: Kind
    public var id: Int

    public init(kind: Kind, id: Int) {
        self.kind = kind
        self.id = id
    }

    /// Stable key of the account (the web client's getSelectableAccountKey).
    public var key: String { "\(kind.rawValue)-\(id)" }
}

/// Which services of a linked account a post goes to.
public struct TwitterPanelPostTarget: Codable, Sendable, Hashable {
    public var isPostToTwitter: Bool
    public var isPostToBluesky: Bool

    public init(isPostToTwitter: Bool = true, isPostToBluesky: Bool = true) {
        self.isPostToTwitter = isPostToTwitter
        self.isPostToBluesky = isPostToBluesky
    }

    private enum CodingKeys: String, CodingKey {
        case isPostToTwitter = "is_post_to_twitter"
        case isPostToBluesky = "is_post_to_bluesky"
    }

    /// Cycle both, Twitter, Bluesky, both, like the web client's post target
    /// button. Never produces an empty target.
    public mutating func cycle() {
        if isPostToTwitter && isPostToBluesky {
            isPostToBluesky = false
        } else if isPostToTwitter {
            isPostToTwitter = false
            isPostToBluesky = true
        } else {
            isPostToTwitter = true
            isPostToBluesky = true
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPostToTwitter = container.lenient(Bool.self, forKey: .isPostToTwitter) ?? true
        isPostToBluesky = container.lenient(Bool.self, forKey: .isPostToBluesky) ?? true
    }
}

// MARK: - Tweet

/// Which service a tweet or post comes from.
public enum TweetSource: String, Codable, Sendable, Hashable {
    case twitter = "Twitter"
    case bluesky = "Bluesky"
}

/// Author of a tweet (ITweetUser on the web client).
public struct TweetUser: Codable, Sendable, Hashable {
    public var source: TweetSource
    public var id: String
    public var name: String
    /// Screen name (Twitter) or handle (Bluesky), without the leading "@".
    public var screenName: String
    public var iconURL: String

    public init(
        source: TweetSource = .twitter,
        id: String = "",
        name: String = "",
        screenName: String = "",
        iconURL: String = ""
    ) {
        self.source = source
        self.id = id
        self.name = name
        self.screenName = screenName
        self.iconURL = iconURL
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case id
        case name
        case screenName = "screen_name"
        case iconURL = "icon_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSource = container.lenient(String.self, forKey: .source) ?? ""
        source = TweetSource(rawValue: rawSource) ?? .twitter
        id = container.lenient(String.self, forKey: .id) ?? ""
        name = container.lenient(String.self, forKey: .name) ?? ""
        screenName = container.lenient(String.self, forKey: .screenName) ?? ""
        iconURL = container.lenient(String.self, forKey: .iconURL) ?? ""
    }
}

/// A tweet (Twitter) or post (Bluesky) as returned by the timeline, search and
/// post endpoints.
///
/// A class rather than a struct because a retweet / quoted tweet is again a
/// tweet, and Swift structs cannot store themselves recursively. All properties
/// are immutable, so the type is safely Sendable; reaction toggles create a new
/// value with replacing(...).
public final class Tweet: Decodable, Sendable, Hashable {
    public let source: TweetSource
    /// Twitter status ID or Bluesky AT URI. This is the ID the API expects.
    public let id: String
    public let createdAt: Date
    public let user: TweetUser
    public let text: String
    public let lang: String
    public let via: String
    public let imageURLs: [String]
    public let movieURL: String?
    public let retweetCount: Int
    public let retweeted: Bool
    public let favoriteCount: Int
    public let favorited: Bool
    /// Set when this row is a retweet / repost; the original tweet is inner.
    public let retweetedTweet: Tweet?
    /// Set when this tweet quotes another one.
    public let quotedTweet: Tweet?

    public init(
        source: TweetSource = .twitter,
        id: String = "",
        createdAt: Date = Date(timeIntervalSince1970: 0),
        user: TweetUser = TweetUser(),
        text: String = "",
        lang: String = "",
        via: String = "",
        imageURLs: [String] = [],
        movieURL: String? = nil,
        retweetCount: Int = 0,
        retweeted: Bool = false,
        favoriteCount: Int = 0,
        favorited: Bool = false,
        retweetedTweet: Tweet? = nil,
        quotedTweet: Tweet? = nil
    ) {
        self.source = source
        self.id = id
        self.createdAt = createdAt
        self.user = user
        self.text = text
        self.lang = lang
        self.via = via
        self.imageURLs = imageURLs
        self.movieURL = movieURL
        self.retweetCount = retweetCount
        self.retweeted = retweeted
        self.favoriteCount = favoriteCount
        self.favorited = favorited
        self.retweetedTweet = retweetedTweet
        self.quotedTweet = quotedTweet
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case id
        case createdAt = "created_at"
        case user
        case text
        case lang
        case via
        case imageURLs = "image_urls"
        case movieURL = "movie_url"
        case retweetCount = "retweet_count"
        case retweeted
        case favoriteCount = "favorite_count"
        case favorited
        case retweetedTweet = "retweeted_tweet"
        case quotedTweet = "quoted_tweet"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSource = container.lenient(String.self, forKey: .source) ?? ""
        source = TweetSource(rawValue: rawSource) ?? .twitter
        id = container.lenient(String.self, forKey: .id) ?? ""
        createdAt = container.lenient(Date.self, forKey: .createdAt)
            ?? Date(timeIntervalSince1970: 0)
        user = container.lenient(TweetUser.self, forKey: .user) ?? TweetUser()
        text = container.lenient(String.self, forKey: .text) ?? ""
        lang = container.lenient(String.self, forKey: .lang) ?? ""
        via = container.lenient(String.self, forKey: .via) ?? ""
        imageURLs = container.lenient([String].self, forKey: .imageURLs) ?? []
        movieURL = container.lenient(String.self, forKey: .movieURL)
        retweetCount = container.lenient(Int.self, forKey: .retweetCount) ?? 0
        retweeted = container.lenient(Bool.self, forKey: .retweeted) ?? false
        favoriteCount = container.lenient(Int.self, forKey: .favoriteCount) ?? 0
        favorited = container.lenient(Bool.self, forKey: .favorited) ?? false
        retweetedTweet = container.lenient(Tweet.self, forKey: .retweetedTweet)
        quotedTweet = container.lenient(Tweet.self, forKey: .quotedTweet)
    }

    // MARK: Derived values

    /// The tweet whose text and media are shown: the original of a retweet,
    /// otherwise the tweet itself.
    public var displayedTweet: Tweet { retweetedTweet ?? self }

    /// Identity used to deduplicate timeline rows (the web client's
    /// getTweetIdentityKey). Bluesky reposts share the AT URI of the original
    /// post, so the reposting user is part of the key.
    public var identityKey: String {
        if source == .bluesky, retweetedTweet != nil {
            return "\(source.rawValue):\(id):repost:\(user.id)"
        }
        return "\(source.rawValue):\(id)"
    }

    /// Copy with new reaction state (and count), keeping everything else.
    public func replacing(
        retweeted: Bool? = nil,
        retweetCount: Int? = nil,
        favorited: Bool? = nil,
        favoriteCount: Int? = nil
    ) -> Tweet {
        Tweet(
            source: source,
            id: id,
            createdAt: createdAt,
            user: user,
            text: text,
            lang: lang,
            via: via,
            imageURLs: imageURLs,
            movieURL: movieURL,
            retweetCount: retweetCount ?? self.retweetCount,
            retweeted: retweeted ?? self.retweeted,
            favoriteCount: favoriteCount ?? self.favoriteCount,
            favorited: favorited ?? self.favorited,
            retweetedTweet: retweetedTweet,
            quotedTweet: quotedTweet
        )
    }

    /// Copy with a different original tweet (used when a reaction is toggled
    /// on a retweet row, which changes the inner tweet, not the row).
    public func withRetweetedTweet(_ tweet: Tweet) -> Tweet {
        Tweet(
            source: source,
            id: id,
            createdAt: createdAt,
            user: user,
            text: text,
            lang: lang,
            via: via,
            imageURLs: imageURLs,
            movieURL: movieURL,
            retweetCount: retweetCount,
            retweeted: retweeted,
            favoriteCount: favoriteCount,
            favorited: favorited,
            retweetedTweet: tweet,
            quotedTweet: quotedTweet
        )
    }

    public static func == (lhs: Tweet, rhs: Tweet) -> Bool {
        lhs === rhs || (
            lhs.source == rhs.source
                && lhs.id == rhs.id
                && lhs.createdAt == rhs.createdAt
                && lhs.user == rhs.user
                && lhs.text == rhs.text
                && lhs.lang == rhs.lang
                && lhs.via == rhs.via
                && lhs.imageURLs == rhs.imageURLs
                && lhs.movieURL == rhs.movieURL
                && lhs.retweetCount == rhs.retweetCount
                && lhs.retweeted == rhs.retweeted
                && lhs.favoriteCount == rhs.favoriteCount
                && lhs.favorited == rhs.favorited
                && lhs.retweetedTweet == rhs.retweetedTweet
                && lhs.quotedTweet == rhs.quotedTweet
        )
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(id)
        hasher.combine(identityKey)
    }
}

// MARK: - API results

/// The TwitterAPIResult of a reaction, keep-alive or auth request.
public struct TwitterAPIResult: Codable, Sendable, Hashable {
    public var isSuccess: Bool
    public var detail: String

    public init(isSuccess: Bool = true, detail: String = "") {
        self.isSuccess = isSuccess
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case isSuccess = "is_success"
        case detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSuccess = container.lenient(Bool.self, forKey: .isSuccess) ?? true
        detail = container.lenient(String.self, forKey: .detail) ?? ""
    }
}

/// Result of posting a tweet (Twitter) or a post (Bluesky).
public struct PostTweetResult: Codable, Sendable, Hashable {
    public var isSuccess: Bool
    public var detail: String
    public var tweetURL: String
    /// Set for Twitter posts.
    public var tweetID: String?
    /// Set for Bluesky posts.
    public var postURI: String?
    public var postCID: String?

    public init(
        isSuccess: Bool = true,
        detail: String = "",
        tweetURL: String = "",
        tweetID: String? = nil,
        postURI: String? = nil,
        postCID: String? = nil
    ) {
        self.isSuccess = isSuccess
        self.detail = detail
        self.tweetURL = tweetURL
        self.tweetID = tweetID
        self.postURI = postURI
        self.postCID = postCID
    }

    private enum CodingKeys: String, CodingKey {
        case isSuccess = "is_success"
        case detail
        case tweetURL = "tweet_url"
        case tweetID = "tweet_id"
        case postURI = "post_uri"
        case postCID = "post_cid"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSuccess = container.lenient(Bool.self, forKey: .isSuccess) ?? true
        detail = container.lenient(String.self, forKey: .detail) ?? ""
        tweetURL = container.lenient(String.self, forKey: .tweetURL) ?? ""
        tweetID = container.lenient(String.self, forKey: .tweetID)
        postURI = container.lenient(String.self, forKey: .postURI)
        postCID = container.lenient(String.self, forKey: .postCID)
    }
}

/// How a load-more cursor continues a timeline.
public enum TimelineCursorType: String, Codable, Sendable, Hashable {
    /// Older tweets, used by the tail "load more" button.
    case older = "Older"
    /// A gap Twitter reported in the middle of the timeline.
    case gap = "Gap"
    case showMore = "ShowMore"
}

/// One load_more_cursor of a timeline response.
public struct TimelineLoadMoreCursor: Codable, Sendable, Hashable {
    public var cursorType: TimelineCursorType
    public var cursorID: String
    public var entryID: String?
    public var upperCreatedAt: Date?
    public var lowerCreatedAt: Date?

    public init(
        cursorType: TimelineCursorType = .older,
        cursorID: String = "",
        entryID: String? = nil,
        upperCreatedAt: Date? = nil,
        lowerCreatedAt: Date? = nil
    ) {
        self.cursorType = cursorType
        self.cursorID = cursorID
        self.entryID = entryID
        self.upperCreatedAt = upperCreatedAt
        self.lowerCreatedAt = lowerCreatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case cursorType = "cursor_type"
        case cursorID = "cursor_id"
        case entryID = "entry_id"
        case upperCreatedAt = "upper_created_at"
        case lowerCreatedAt = "lower_created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = container.lenient(String.self, forKey: .cursorType) ?? ""
        cursorType = TimelineCursorType(rawValue: rawType) ?? .older
        cursorID = container.lenient(String.self, forKey: .cursorID) ?? ""
        entryID = container.lenient(String.self, forKey: .entryID)
        upperCreatedAt = container.lenient(Date.self, forKey: .upperCreatedAt)
        lowerCreatedAt = container.lenient(Date.self, forKey: .lowerCreatedAt)
    }
}

/// A timeline or search response.
public struct TimelineTweetsResult: Decodable, Sendable, Hashable {
    public var isSuccess: Bool
    public var detail: String
    public var tweets: [Tweet]
    public var newerCursorID: String?
    public var loadMoreCursors: [TimelineLoadMoreCursor]
    /// False when Twitter answered with an empty, rate-limited page; the
    /// cursors then must not be consumed.
    public var isCursorConsumed: Bool

    public init(
        isSuccess: Bool = true,
        detail: String = "",
        tweets: [Tweet] = [],
        newerCursorID: String? = nil,
        loadMoreCursors: [TimelineLoadMoreCursor] = [],
        isCursorConsumed: Bool = true
    ) {
        self.isSuccess = isSuccess
        self.detail = detail
        self.tweets = tweets
        self.newerCursorID = newerCursorID
        self.loadMoreCursors = loadMoreCursors
        self.isCursorConsumed = isCursorConsumed
    }

    private enum CodingKeys: String, CodingKey {
        case isSuccess = "is_success"
        case detail
        case tweets
        case newerCursorID = "newer_cursor_id"
        case loadMoreCursors = "load_more_cursors"
        case isCursorConsumed = "is_cursor_consumed"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSuccess = container.lenient(Bool.self, forKey: .isSuccess) ?? true
        detail = container.lenient(String.self, forKey: .detail) ?? ""
        tweets = container.lenient([Tweet].self, forKey: .tweets) ?? []
        newerCursorID = container.lenient(String.self, forKey: .newerCursorID)
        loadMoreCursors = container.lenient([TimelineLoadMoreCursor].self, forKey: .loadMoreCursors) ?? []
        isCursorConsumed = container.lenient(Bool.self, forKey: .isCursorConsumed) ?? true
    }
}

// MARK: - Search / timeline request options

/// Which tweets a Twitter search returns (search_type query parameter).
public enum TwitterSearchType: String, Sendable, Hashable {
    case latest = "Latest"
    case top = "Top"
}

/// The cursor_type query parameter of the Twitter timeline and search APIs.
public enum TwitterTimelineCursorType: String, Sendable, Hashable {
    /// Newer tweets (the first page of a search).
    case top = "Top"
    /// Older tweets (KonomiTV's Older).
    case bottom = "Bottom"
    /// Fills a gap Twitter reported in the middle of the timeline.
    case gap = "Gap"
    case showMore = "ShowMore"

    /// The query parameter for a timeline cursor type.
    ///
    /// KonomiTV's Older cursor is Twitter's Bottom, so it is converted here.
    public static func forTimelineCursor(_ cursor: TimelineCursorType) -> TwitterTimelineCursorType {
        switch cursor {
        case .older: return .bottom
        case .gap: return .gap
        case .showMore: return .showMore
        }
    }
}

/// One image attached to a tweet or Bluesky post.
public struct TweetImage: Sendable, Hashable {
    public var filename: String
    public var contentType: String
    public var data: Data

    public init(filename: String, contentType: String = "image/jpeg", data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

// MARK: - Request bodies

/// Body of POST /api/twitter/auth.
public struct TwitterCookieAuthRequest: Encodable, Sendable, Hashable {
    public var cookiesTxt: String
    public var browserInfo: BrowserEnvironmentInfoRequest?

    public init(cookiesTxt: String, browserInfo: BrowserEnvironmentInfoRequest? = nil) {
        self.cookiesTxt = cookiesTxt
        self.browserInfo = browserInfo
    }

    private enum CodingKeys: String, CodingKey {
        case cookiesTxt = "cookies_txt"
        case browserInfo = "browser_info"
    }
}

/// High-entropy user agent data collected by the web client's browser.
///
/// The native client cannot provide it, so the fields are optional and nil
/// means "no browser environment information", which the server accepts.
public struct BrowserEnvironmentInfoRequest: Codable, Sendable, Hashable {
    public var userAgentData: BrowserEnvironmentUserAgentData
    public var navigatorPlatform: String
    public var locale: String
    public var timezone: String

    public init(
        userAgentData: BrowserEnvironmentUserAgentData = BrowserEnvironmentUserAgentData(),
        navigatorPlatform: String = "",
        locale: String = "",
        timezone: String = ""
    ) {
        self.userAgentData = userAgentData
        self.navigatorPlatform = navigatorPlatform
        self.locale = locale
        self.timezone = timezone
    }

    private enum CodingKeys: String, CodingKey {
        case userAgentData = "user_agent_data"
        case navigatorPlatform = "navigator_platform"
        case locale
        case timezone
    }
}

/// navigator.userAgentData high entropy values, as the web client sends them.
public struct BrowserEnvironmentUserAgentData: Codable, Sendable, Hashable {
    public var platform: String
    public var platformVersion: String
    public var architecture: String
    public var bitness: String
    public var mobile: Bool
    public var model: String
    public var wow64: Bool

    public init(
        platform: String = "",
        platformVersion: String = "",
        architecture: String = "",
        bitness: String = "",
        mobile: Bool = false,
        model: String = "",
        wow64: Bool = false
    ) {
        self.platform = platform
        self.platformVersion = platformVersion
        self.architecture = architecture
        self.bitness = bitness
        self.mobile = mobile
        self.model = model
        self.wow64 = wow64
    }

    private enum CodingKeys: String, CodingKey {
        case platform
        case platformVersion = "platform_version"
        case architecture
        case bitness
        case mobile
        case model
        case wow64
    }
}

/// Body of POST /api/bluesky/auth.
public struct BlueskyAuthRequest: Encodable, Sendable, Hashable {
    public var handle: String
    public var appPassword: String

    public init(handle: String, appPassword: String) {
        self.handle = handle
        self.appPassword = appPassword
    }

    private enum CodingKeys: String, CodingKey {
        case handle
        case appPassword = "app_password"
    }
}

/// Body of POST /api/users/me/account-links.
public struct AccountLinkCreateRequest: Encodable, Sendable, Hashable {
    public var twitterAccountID: Int
    public var blueskyAccountID: Int

    public init(twitterAccountID: Int, blueskyAccountID: Int) {
        self.twitterAccountID = twitterAccountID
        self.blueskyAccountID = blueskyAccountID
    }

    private enum CodingKeys: String, CodingKey {
        case twitterAccountID = "twitter_account_id"
        case blueskyAccountID = "bluesky_account_id"
    }
}

/// The reply reference of a Bluesky post (root and parent strong refs).
public struct BlueskyReplyReference: Codable, Sendable, Hashable {
    public var rootURI: String
    public var rootCID: String
    public var parentURI: String
    public var parentCID: String

    public init(rootURI: String, rootCID: String, parentURI: String, parentCID: String) {
        self.rootURI = rootURI
        self.rootCID = rootCID
        self.parentURI = parentURI
        self.parentCID = parentCID
    }

    private enum CodingKeys: String, CodingKey {
        case rootURI = "root_uri"
        case rootCID = "root_cid"
        case parentURI = "parent_uri"
        case parentCID = "parent_cid"
    }
}
