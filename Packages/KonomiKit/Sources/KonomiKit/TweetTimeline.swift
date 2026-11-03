import Foundation

// MARK: - Reply thread

/// Reply tree mode of the composer (twitter_reply_thread_mode /
/// bluesky_reply_thread_mode).
public enum TweetReplyThreadMode: String, Codable, CaseIterable, Sendable, Hashable {
    case perHashtag = "PerHashtag"
    case perDay = "PerDay"
    case disabled = "Disabled"

    public var displayName: String {
        switch self {
        case .perHashtag: return "ハッシュタグごとにリプライツリーを切り替える"
        case .perDay: return "1日ごとにリプライツリーを切り替える"
        case .disabled: return "リプライツリー実況を行わない"
        }
    }
}

/// Reply tree state of one Twitter account (twitter_reply_thread_states).
public struct TwitterReplyThreadState: Codable, Sendable, Hashable {
    public var lastTweetID: String
    public var startedAt: Date
    public var hashtagKey: String

    public init(lastTweetID: String, startedAt: Date, hashtagKey: String) {
        self.lastTweetID = lastTweetID
        self.startedAt = startedAt
        self.hashtagKey = hashtagKey
    }

    private enum CodingKeys: String, CodingKey {
        case lastTweetID = "last_tweet_id"
        case startedAt = "started_at"
        case hashtagKey = "hashtag_key"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastTweetID = container.lenient(String.self, forKey: .lastTweetID) ?? ""
        startedAt = container.lenient(Date.self, forKey: .startedAt)
            ?? Date(timeIntervalSince1970: 0)
        hashtagKey = container.lenient(String.self, forKey: .hashtagKey) ?? ""
    }
}

/// Reply tree state of one Bluesky account (bluesky_reply_thread_states).
public struct BlueskyReplyThreadState: Codable, Sendable, Hashable {
    public var rootURI: String
    public var rootCID: String
    public var parentURI: String
    public var parentCID: String
    public var startedAt: Date
    public var hashtagKey: String

    public init(
        rootURI: String,
        rootCID: String,
        parentURI: String,
        parentCID: String,
        startedAt: Date,
        hashtagKey: String
    ) {
        self.rootURI = rootURI
        self.rootCID = rootCID
        self.parentURI = parentURI
        self.parentCID = parentCID
        self.startedAt = startedAt
        self.hashtagKey = hashtagKey
    }

    private enum CodingKeys: String, CodingKey {
        case rootURI = "root_uri"
        case rootCID = "root_cid"
        case parentURI = "parent_uri"
        case parentCID = "parent_cid"
        case startedAt = "started_at"
        case hashtagKey = "hashtag_key"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootURI = container.lenient(String.self, forKey: .rootURI) ?? ""
        rootCID = container.lenient(String.self, forKey: .rootCID) ?? ""
        parentURI = container.lenient(String.self, forKey: .parentURI) ?? ""
        parentCID = container.lenient(String.self, forKey: .parentCID) ?? ""
        startedAt = container.lenient(Date.self, forKey: .startedAt)
            ?? Date(timeIntervalSince1970: 0)
        hashtagKey = container.lenient(String.self, forKey: .hashtagKey) ?? ""
    }

    /// The StrongRef pair the Bluesky post API expects for a reply.
    public var replyReference: BlueskyReplyReference {
        BlueskyReplyReference(
            rootURI: rootURI,
            rootCID: rootCID,
            parentURI: parentURI,
            parentCID: parentCID
        )
    }
}

/// What to do with the reply tree state around one post.
public struct TweetReplyThreadDecision: Sendable, Hashable {
    /// Send the post as a reply to the stored parent.
    public var sendAsReply: Bool
    /// Start a new tree with this post after a successful send.
    public var resetStateAfter: Bool
    /// Forget the stored tree after a successful send.
    public var clearState: Bool

    public init(sendAsReply: Bool = false, resetStateAfter: Bool = false, clearState: Bool = false) {
        self.sendAsReply = sendAsReply
        self.resetStateAfter = resetStateAfter
        self.clearState = clearState
    }
}

/// Reply tree decision rules (the web client's TweetUtils.decideReplyThread).
public enum TweetReplyThreadRules {

    /// Decides how the next post relates to the stored tree.
    ///
    /// - Parameters:
    ///   - mode: The service's reply tree mode.
    ///   - stateHashtagKey: Hashtag key stored with the tree, nil when there is
    ///     no tree.
    ///   - stateStartedAt: When the tree started, nil when there is no tree.
    ///   - currentHashtagKey: Hashtag key of the post about to be sent.
    ///   - now: Current time.
    ///   - calendar: Calendar the 4 am day boundary is computed in (the device's
    ///     local calendar by default, like the web client).
    public static func decide(
        mode: TweetReplyThreadMode,
        stateHashtagKey: String?,
        stateStartedAt: Date?,
        currentHashtagKey: String,
        now: Date,
        calendar: Calendar = .current
    ) -> TweetReplyThreadDecision {
        let hasState = stateHashtagKey != nil && stateStartedAt != nil

        switch mode {
        case .disabled:
            return TweetReplyThreadDecision()

        case .perHashtag:
            // A post without hashtags has no context: send it standalone and
            // explicitly end any tree.
            if currentHashtagKey.isEmpty {
                return TweetReplyThreadDecision(clearState: true)
            }
            guard hasState, stateHashtagKey == currentHashtagKey else {
                return TweetReplyThreadDecision(resetStateAfter: true)
            }
            return TweetReplyThreadDecision(sendAsReply: true)

        case .perDay:
            guard hasState, let startedAt = stateStartedAt else {
                return TweetReplyThreadDecision(resetStateAfter: true)
            }
            // One tree per day: only the 4 am boundary matters, hashtags may
            // change within it.
            if floorTo4amBoundary(startedAt, calendar: calendar)
                != floorTo4amBoundary(now, calendar: calendar) {
                return TweetReplyThreadDecision(resetStateAfter: true)
            }
            return TweetReplyThreadDecision(sendAsReply: true)
        }
    }

    /// Rounds a date down to the last 4:00 boundary (the web client's
    /// floorTo4amBoundary): before 4 am the broadcast day has not changed yet.
    public static func floorTo4amBoundary(_ value: Date, calendar: Calendar = .current) -> Date {
        var day = value
        if calendar.component(.hour, from: value) < 4 {
            day = calendar.date(byAdding: .day, value: -1, to: value) ?? value
        }
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        var boundary = DateComponents()
        boundary.year = components.year
        boundary.month = components.month
        boundary.day = components.day
        boundary.hour = 4
        boundary.minute = 0
        boundary.second = 0
        return calendar.date(from: boundary) ?? value
    }
}

// MARK: - Timeline merge

/// Per-service range of a loaded timeline (TweetTimelineMergeUtils feed
/// coverage). oldestCreatedAt is the oldest loaded post; it does not guarantee
/// a contiguous range down to it.
public struct FeedCoverage: Codable, Sendable, Hashable {
    public var oldestCreatedAt: Date?
    public var olderCursor: String?
    public var isOlderExhausted: Bool

    public init(
        oldestCreatedAt: Date? = nil,
        olderCursor: String? = nil,
        isOlderExhausted: Bool = false
    ) {
        self.oldestCreatedAt = oldestCreatedAt
        self.olderCursor = olderCursor
        self.isOlderExhausted = isOlderExhausted
    }

    public static let empty = FeedCoverage()
}

/// Loaded range of a merged (Twitter + Bluesky) timeline.
public struct MergedFeedCoverage: Codable, Sendable, Hashable {
    public var twitter: FeedCoverage
    public var bluesky: FeedCoverage

    public init(twitter: FeedCoverage = .empty, bluesky: FeedCoverage = .empty) {
        self.twitter = twitter
        self.bluesky = bluesky
    }

    public static let empty = MergedFeedCoverage()
}

/// Which service a timeline row came from.
public enum TimelineSource: String, Sendable, Hashable {
    case twitter = "Twitter"
    case bluesky = "Bluesky"
}

/// Which services the selected panel account uses.
public enum TimelineAccountKind: String, Sendable, Hashable {
    case twitter = "Twitter"
    case bluesky = "Bluesky"
    case linked = "Linked"
}

/// A gap Twitter reported in the middle of the timeline.
public struct TwitterTimelineGap: Sendable, Hashable, Identifiable {
    public var id: String
    public var cursorID: String
    public var cursorType: TimelineCursorType
    public var upperCreatedAt: Date
    public var lowerCreatedAt: Date?

    public init(
        id: String,
        cursorID: String,
        cursorType: TimelineCursorType,
        upperCreatedAt: Date,
        lowerCreatedAt: Date?
    ) {
        self.id = id
        self.cursorID = cursorID
        self.cursorType = cursorType
        self.upperCreatedAt = upperCreatedAt
        self.lowerCreatedAt = lowerCreatedAt
    }
}

/// Load-more button of a gap in the middle of the timeline.
public struct TwitterGapLoadMoreItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var gapID: String
    public var cursorID: String
    public var cursorType: TimelineCursorType
    public var upperCreatedAt: Date
    public var lowerCreatedAt: Date?

    public init(
        gapID: String,
        cursorID: String,
        cursorType: TimelineCursorType,
        upperCreatedAt: Date,
        lowerCreatedAt: Date?
    ) {
        self.id = "twitter_gap_load_more_\(gapID)"
        self.gapID = gapID
        self.cursorID = cursorID
        self.cursorType = cursorType
        self.upperCreatedAt = upperCreatedAt
        self.lowerCreatedAt = lowerCreatedAt
    }
}

/// Load-more button at the end of the timeline.
public struct TailLoadMoreItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var upperCreatedAt: Date

    public init(upperCreatedAt: Date) {
        self.id = "tail_load_more"
        self.upperCreatedAt = upperCreatedAt
    }
}

/// One row of the merged timeline: a tweet or a load-more button.
public enum TimelineDisplayItem: Sendable, Hashable, Identifiable {
    case tweet(Tweet)
    case twitterGap(TwitterGapLoadMoreItem)
    case tail(TailLoadMoreItem)

    public var id: String {
        switch self {
        case .tweet(let tweet): return "tweet_" + tweet.identityKey
        case .twitterGap(let item): return item.id
        case .tail(let item): return item.id
        }
    }

    public var tweet: Tweet? {
        if case .tweet(let tweet) = self { return tweet }
        return nil
    }

    public var loadMoreItem: LoadMoreItem? {
        switch self {
        case .tweet: return nil
        case .twitterGap(let item):
            return LoadMoreItem(
                gapID: item.gapID,
                cursorID: item.cursorID,
                cursorType: item.cursorType
            )
        case .tail:
            return LoadMoreItem(gapID: nil, cursorID: nil, cursorType: nil)
        }
    }
}

/// A pressed load-more button, normalised for
/// TweetTimelineMerge.decideLoadMoreTargets.
public struct LoadMoreItem: Sendable, Hashable {
    /// Set when the button fills a Twitter gap (nil for the tail button).
    public var gapID: String?
    public var cursorID: String?
    public var cursorType: TimelineCursorType?

    public init(gapID: String?, cursorID: String?, cursorType: TimelineCursorType?) {
        self.gapID = gapID
        self.cursorID = cursorID
        self.cursorType = cursorType
    }
}

/// Cursors classified from one timeline page.
public struct ClassifiedTimelineCursors: Sendable, Hashable {
    public var olderCursor: String?
    public var twitterGaps: [TwitterTimelineGap]

    public init(olderCursor: String? = nil, twitterGaps: [TwitterTimelineGap] = []) {
        self.olderCursor = olderCursor
        self.twitterGaps = twitterGaps
    }
}

/// Which service a load-more button should fetch next.
public struct LoadMoreTargets: Sendable, Hashable {
    public var shouldFetchTwitter: Bool
    public var shouldFetchBluesky: Bool
    public var twitterCursorID: String?
    public var twitterCursorType: TimelineCursorType?
    public var blueskyCursorID: String?
    public var consumedTwitterGapID: String?

    public init(
        shouldFetchTwitter: Bool = false,
        shouldFetchBluesky: Bool = false,
        twitterCursorID: String? = nil,
        twitterCursorType: TimelineCursorType? = nil,
        blueskyCursorID: String? = nil,
        consumedTwitterGapID: String? = nil
    ) {
        self.shouldFetchTwitter = shouldFetchTwitter
        self.shouldFetchBluesky = shouldFetchBluesky
        self.twitterCursorID = twitterCursorID
        self.twitterCursorType = twitterCursorType
        self.blueskyCursorID = blueskyCursorID
        self.consumedTwitterGapID = consumedTwitterGapID
    }
}

/// Merging Twitter and Bluesky timelines into one display list.
///
/// A port of the web client's TweetTimelineMergeUtils: tweets are kept in a
/// dictionary keyed by identity, the loaded range of each service is tracked
/// separately, and Twitter's middle gaps become load-more rows.
public enum TweetTimelineMerge {

    // MARK: Deduplication and ordering

    /// Drops the tweets whose identity is already loaded.
    public static func filterDuplicates(
        _ tweets: [Tweet],
        existingIdentityKeys: Set<String>
    ) -> [Tweet] {
        tweets.filter { !existingIdentityKeys.contains($0.identityKey) }
    }

    /// Newest first, stable for equal timestamps.
    public static func sortedByCreatedAtDescending(_ tweets: [Tweet]) -> [Tweet] {
        tweets.enumerated()
            .sorted { left, right in
                if left.element.createdAt != right.element.createdAt {
                    return left.element.createdAt > right.element.createdAt
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// Oldest tweet of a page, nil for an empty page.
    public static func oldestTweet(_ tweets: [Tweet]) -> Tweet? {
        tweets.min { $0.createdAt < $1.createdAt }
    }

    // MARK: Cursors

    /// Whether the response consumed its cursors (false for a rate-limited,
    /// suppressed response whose cursors must not be used).
    public static func isCursorConsumed(_ result: TimelineTweetsResult?) -> Bool {
        result?.isCursorConsumed == true
    }

    /// Splits a page's cursors into the older-direction cursor and Twitter's
    /// middle gaps.
    public static func classifyTimelineCursors(
        source: TimelineSource,
        result: TimelineTweetsResult?,
        pageTweets: [Tweet]
    ) -> ClassifiedTimelineCursors {
        guard let result, isCursorConsumed(result) else {
            return ClassifiedTimelineCursors()
        }

        let older = result.loadMoreCursors.first { $0.cursorType == .older }
        guard source == .twitter else {
            return ClassifiedTimelineCursors(olderCursor: older?.cursorID)
        }

        let oldest = oldestTweet(pageTweets)
        let fallbackUpper = oldest?.createdAt
        var gaps: [TwitterTimelineGap] = []
        for cursor in result.loadMoreCursors
        where cursor.cursorType == .gap || cursor.cursorType == .showMore {
            guard let upper = cursor.upperCreatedAt ?? fallbackUpper else { continue }
            // The upper bound moves between requests, so the ID is anchored on
            // the cursor itself and the lower bound.
            let stableBoundary = cursor.lowerCreatedAt.map { "\($0.timeIntervalSince1970)" } ?? "tail"
            gaps.append(
                TwitterTimelineGap(
                    id: "twitter_gap_\(cursor.cursorID)_\(cursor.cursorType.rawValue)_\(stableBoundary)",
                    cursorID: cursor.cursorID,
                    cursorType: cursor.cursorType,
                    upperCreatedAt: upper,
                    lowerCreatedAt: cursor.lowerCreatedAt
                )
            )
        }
        return ClassifiedTimelineCursors(olderCursor: older?.cursorID, twitterGaps: gaps)
    }

    /// Updates a service's loaded range from one fetched page.
    ///
    /// - Parameters:
    ///   - shouldPreserveOlderState: New-tweets and gap fetches do not consume
    ///     the tail cursor, so the existing tail state is kept.
    ///   - shouldKeepOlderUninitializedWhenMissing: Right after the first load
    ///     a missing older cursor means "not established yet", not "exhausted".
    public static func updateCoverage(
        _ previous: FeedCoverage,
        result: TimelineTweetsResult?,
        pageTweets: [Tweet],
        shouldPreserveOlderState: Bool = false,
        shouldKeepOlderUninitializedWhenMissing: Bool = false
    ) -> FeedCoverage {
        guard let result, isCursorConsumed(result) else {
            return previous
        }

        let pageOldest = oldestTweet(pageTweets)?.createdAt
        let older = result.loadMoreCursors.first { $0.cursorType == .older }

        // Only ever move the oldest bound further into the past.
        let oldestCreatedAt: Date?
        if let previousOldest = previous.oldestCreatedAt {
            if let pageOldest, pageOldest < previousOldest {
                oldestCreatedAt = pageOldest
            } else {
                oldestCreatedAt = previousOldest
            }
        } else {
            oldestCreatedAt = pageOldest
        }

        if shouldPreserveOlderState {
            return FeedCoverage(
                oldestCreatedAt: oldestCreatedAt,
                olderCursor: previous.olderCursor,
                isOlderExhausted: previous.isOlderExhausted
            )
        }

        let keepUninitialized = shouldKeepOlderUninitializedWhenMissing
            && previous.olderCursor == nil
            && !previous.isOlderExhausted
            && older == nil

        return FeedCoverage(
            oldestCreatedAt: oldestCreatedAt,
            olderCursor: older?.cursorID,
            isOlderExhausted: keepUninitialized ? false : (older == nil)
        )
    }

    // MARK: Display

    /// Lowest timestamp a merged timeline may show. A mixed timeline is clamped
    /// to Twitter's loaded range so Bluesky does not run further into the past
    /// than Twitter; once Twitter is exhausted the clamp is lifted.
    public static func resolveDisplayLowerBound(
        coverage: MergedFeedCoverage,
        accountKind: TimelineAccountKind
    ) -> Date? {
        if accountKind == .linked,
           !coverage.twitter.isOlderExhausted,
           let oldest = coverage.twitter.oldestCreatedAt {
            return oldest
        }
        return nil
    }

    private static func shouldShow(_ tweet: Tweet, lowerBound: Date?) -> Bool {
        guard let lowerBound else { return true }
        guard tweet.source == .bluesky else { return true }
        return tweet.createdAt >= lowerBound
    }

    private static func hasTailCursor(
        _ coverage: MergedFeedCoverage,
        accountKind: TimelineAccountKind
    ) -> Bool {
        switch accountKind {
        case .twitter:
            return !coverage.twitter.isOlderExhausted && coverage.twitter.olderCursor != nil
        case .bluesky:
            return !coverage.bluesky.isOlderExhausted && coverage.bluesky.olderCursor != nil
        case .linked:
            if !coverage.twitter.isOlderExhausted {
                return coverage.twitter.olderCursor != nil
            }
            return !coverage.bluesky.isOlderExhausted && coverage.bluesky.olderCursor != nil
        }
    }

    private static func tailUpperCreatedAt(
        sortedTweets: [Tweet],
        coverage: MergedFeedCoverage,
        accountKind: TimelineAccountKind
    ) -> Date? {
        if let lowerBound = resolveDisplayLowerBound(coverage: coverage, accountKind: accountKind) {
            return lowerBound
        }
        return oldestTweet(sortedTweets)?.createdAt
    }

    /// Builds the display rows: tweets newest first, Twitter's middle gaps at
    /// their place, and a tail load-more row while a cursor remains.
    public static func buildItems(
        tweets: [Tweet],
        gaps: [TwitterTimelineGap],
        coverage: MergedFeedCoverage,
        accountKind: TimelineAccountKind
    ) -> [TimelineDisplayItem] {
        let lowerBound = resolveDisplayLowerBound(coverage: coverage, accountKind: accountKind)
        let sortedTweets = sortedByCreatedAtDescending(tweets)
            .filter { shouldShow($0, lowerBound: lowerBound) }
        let sortedGaps = gaps.sorted { $0.upperCreatedAt > $1.upperCreatedAt }

        var items: [TimelineDisplayItem] = []
        var index = 0
        for gap in sortedGaps {
            while index < sortedTweets.count, sortedTweets[index].createdAt >= gap.upperCreatedAt {
                items.append(.tweet(sortedTweets[index]))
                index += 1
            }
            items.append(.twitterGap(TwitterGapLoadMoreItem(
                gapID: gap.id,
                cursorID: gap.cursorID,
                cursorType: gap.cursorType,
                upperCreatedAt: gap.upperCreatedAt,
                lowerCreatedAt: gap.lowerCreatedAt
            )))
        }
        while index < sortedTweets.count {
            items.append(.tweet(sortedTweets[index]))
            index += 1
        }

        if let tailUpper = tailUpperCreatedAt(
            sortedTweets: sortedTweets,
            coverage: coverage,
            accountKind: accountKind
        ), hasTailCursor(coverage, accountKind: accountKind) {
            items.append(.tail(TailLoadMoreItem(upperCreatedAt: tailUpper)))
        }
        return items
    }

    /// Decides which service a load-more row must fetch.
    public static func decideLoadMoreTargets(
        item: LoadMoreItem,
        coverage: MergedFeedCoverage,
        accountKind: TimelineAccountKind
    ) -> LoadMoreTargets {
        if let gapID = item.gapID, let cursorID = item.cursorID, let cursorType = item.cursorType {
            return LoadMoreTargets(
                shouldFetchTwitter: true,
                twitterCursorID: cursorID,
                twitterCursorType: cursorType,
                consumedTwitterGapID: gapID
            )
        }

        switch accountKind {
        case .twitter:
            return LoadMoreTargets(
                shouldFetchTwitter: coverage.twitter.olderCursor != nil,
                twitterCursorID: coverage.twitter.olderCursor,
                twitterCursorType: .older
            )
        case .bluesky:
            return LoadMoreTargets(
                shouldFetchBluesky: coverage.bluesky.olderCursor != nil,
                blueskyCursorID: coverage.bluesky.olderCursor
            )
        case .linked:
            if !coverage.twitter.isOlderExhausted {
                return LoadMoreTargets(
                    shouldFetchTwitter: coverage.twitter.olderCursor != nil,
                    twitterCursorID: coverage.twitter.olderCursor,
                    twitterCursorType: .older
                )
            }
            return LoadMoreTargets(
                shouldFetchBluesky: coverage.bluesky.olderCursor != nil,
                blueskyCursorID: coverage.bluesky.olderCursor
            )
        }
    }

    /// Whether Bluesky has to be paged further to reach the merged timeline's
    /// lower bound.
    public static func shouldFetchBlueskyForDisplayLowerBound(
        coverage: MergedFeedCoverage,
        accountKind: TimelineAccountKind
    ) -> Bool {
        guard let lowerBound = resolveDisplayLowerBound(
            coverage: coverage,
            accountKind: accountKind
        ) else {
            return false
        }
        guard coverage.bluesky.olderCursor != nil, !coverage.bluesky.isOlderExhausted else {
            return false
        }
        guard let blueskyOldest = coverage.bluesky.oldestCreatedAt else {
            return true
        }
        return blueskyOldest > lowerBound
    }

    /// Appends gaps without duplicating an existing one.
    public static func appendGaps(
        _ current: [TwitterTimelineGap],
        new gaps: [TwitterTimelineGap]
    ) -> [TwitterTimelineGap] {
        guard !gaps.isEmpty else { return current }
        var ids = Set(current.map(\.id))
        var result = current
        for gap in gaps where !ids.contains(gap.id) {
            ids.insert(gap.id)
            result.append(gap)
        }
        return result
    }

    /// Removes a gap after its load-more button was used.
    public static func removingGap(_ gaps: [TwitterTimelineGap], id: String?) -> [TwitterTimelineGap] {
        guard let id else { return gaps }
        return gaps.filter { $0.id != id }
    }
}
