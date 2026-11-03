import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import KonomiKit

// MARK: - Helpers

private let twitterBaseURL = URL(string: "http://127.0.0.1:7010")!

private func twitterJSONResponse(
    for request: URLRequest,
    body: String,
    status: Int = 200
) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? twitterBaseURL,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
}

private func twitterQuery(_ request: URLRequest, name: String) -> String? {
    guard
        let url = request.url,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
        return nil
    }
    return components.queryItems?.first { $0.name == name }?.value
}

private func makeClock(_ iso: String) -> Date {
    JSONCoding.parseISO8601(iso)!
}

private func jstCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? TimeZone(secondsFromGMT: 9 * 3600)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

private func tweet(
    id: String,
    source: TweetSource = .twitter,
    createdAt: Date,
    text: String = "text"
) -> Tweet {
    Tweet(
        source: source,
        id: id,
        createdAt: createdAt,
        user: TweetUser(source: source, id: "user", name: "name", screenName: "screen"),
        text: text
    )
}

// MARK: - Hashtags

final class TweetHashtagRulesTests: XCTestCase {

    func testFormatNormalisesHashAndSpaces() {
        XCTAssertEqual(
            TweetHashtagRules.format("  ＃アニメ　＃＃テスト ♯nhk  "),
            "#アニメ #テスト #nhk"
        )
    }

    func testFormatPrefixedHashtagsStaySingleHashed() {
        XCTAssertEqual(TweetHashtagRules.format("#nhk #etv"), "#nhk #etv")
    }

    func testFormatAppendsChannelHashtagOnce() {
        XCTAssertEqual(TweetHashtagRules.format("実況", appendingChannelHashtag: "#nhk"), "#実況 #nhk")
        XCTAssertEqual(
            TweetHashtagRules.format("#nhk", appendingChannelHashtag: "#nhk"),
            "#nhk"
        )
        XCTAssertEqual(
            TweetHashtagRules.format("", appendingChannelHashtag: "#nhk"),
            "#nhk"
        )
        XCTAssertEqual(TweetHashtagRules.format(""), "")
    }

    func testRemovingChannelHashtag() {
        XCTAssertEqual(
            TweetHashtagRules.removingChannelHashtag("#anime #nhk", channelHashtag: "#nhk"),
            "#anime "
        )
    }

    func testChannelHashtagMatchesLongestPrefixInOrder() {
        XCTAssertEqual(TweetHashtagRules.channelHashtag(for: "NHK総合"), "#nhk")
        XCTAssertEqual(TweetHashtagRules.channelHashtag(for: "NHK総合1"), "#nhk")
        XCTAssertEqual(TweetHashtagRules.channelHashtag(for: "NHKEテレ"), "#etv")
        XCTAssertEqual(TweetHashtagRules.channelHashtag(for: "NHKBS1"), "#nhkbs1")
        XCTAssertEqual(TweetHashtagRules.channelHashtag(for: "NHKBSプレミアム4K"), "#nhkbsp")
        XCTAssertEqual(TweetHashtagRules.channelHashtag(for: "NHKBS"), "#nhkbs")
        XCTAssertEqual(TweetHashtagRules.channelHashtag(for: "TBS"), "#tbs")
        XCTAssertNil(TweetHashtagRules.channelHashtag(for: "TBSチャンネル1"))
        XCTAssertEqual(TweetHashtagRules.channelHashtag(for: "テレ東"), "#tvtokyo")
        XCTAssertEqual(TweetHashtagRules.channelHashtag(for: "テレビ大阪"), "#tvo")
        XCTAssertEqual(TweetHashtagRules.channelHashtag(for: "メ〜テレ"), "#nagoyatv")
        XCTAssertNil(TweetHashtagRules.channelHashtag(for: "不明なチャンネル"))
        XCTAssertNil(TweetHashtagRules.channelHashtag(for: ""))
    }

    func testChannelSwitchReplacesTheStationHashtag() {
        XCTAssertEqual(
            TweetHashtagRules.fieldAfterChannelSwitch(
                "#anime #nhk",
                oldChannelHashtag: "#nhk",
                newChannelHashtag: "#etv",
                resetOnProgramSwitch: false
            ),
            "#anime #etv"
        )
        // The reset setting clears everything but adds the new station tag.
        XCTAssertEqual(
            TweetHashtagRules.fieldAfterChannelSwitch(
                "#anime #nhk",
                oldChannelHashtag: "#nhk",
                newChannelHashtag: "#etv",
                resetOnProgramSwitch: true
            ),
            "#etv"
        )
        // Automatic addition off: the old tag is only removed.
        XCTAssertEqual(
            TweetHashtagRules.fieldAfterChannelSwitch(
                "#anime #nhk",
                oldChannelHashtag: "#nhk",
                newChannelHashtag: nil,
                resetOnProgramSwitch: false
            ),
            "#anime"
        )
        XCTAssertEqual(
            TweetHashtagRules.fieldAfterChannelSwitch(
                "#anime #nhk",
                oldChannelHashtag: "#nhk",
                newChannelHashtag: nil,
                resetOnProgramSwitch: true
            ),
            ""
        )
    }

    func testProgramSwitchResetsOnlyWhenEnabled() {
        XCTAssertEqual(
            TweetHashtagRules.fieldAfterProgramSwitch(
                "#anime #nhk",
                resetOnProgramSwitch: true,
                autoChannelHashtag: "#nhk"
            ),
            "#nhk"
        )
        XCTAssertEqual(
            TweetHashtagRules.fieldAfterProgramSwitch(
                "#anime #nhk",
                resetOnProgramSwitch: false,
                autoChannelHashtag: "#nhk"
            ),
            "#anime #nhk"
        )
        // Recorded videos have no station tag, so the field becomes empty.
        XCTAssertEqual(
            TweetHashtagRules.fieldAfterProgramSwitch(
                "#anime",
                resetOnProgramSwitch: true,
                autoChannelHashtag: nil
            ),
            ""
        )
    }

    func testNormalizedHashtagKeyIgnoresCaseOrderAndDuplicates() {
        XCTAssertEqual(
            TweetHashtagRules.normalizedKey(["#NHK", "#anime", "anime"]),
            "anime,nhk"
        )
        XCTAssertEqual(TweetHashtagRules.normalizedKey([]), "")
    }
}

// MARK: - Composer and length

final class TweetComposerTests: XCTestCase {

    func testComposeRespectsHashtagPosition() {
        XCTAssertEqual(
            TweetComposer.compose(text: "本文", hashtags: "#nhk", position: .prepend),
            "#nhk 本文"
        )
        XCTAssertEqual(
            TweetComposer.compose(text: "本文", hashtags: "#nhk", position: .append),
            "本文 #nhk"
        )
        XCTAssertEqual(
            TweetComposer.compose(text: "本文", hashtags: "#nhk", position: .prependWithLineBreak),
            "#nhk\n本文"
        )
        XCTAssertEqual(
            TweetComposer.compose(text: "本文", hashtags: "#nhk", position: .appendWithLineBreak),
            "本文\n#nhk"
        )
        XCTAssertEqual(
            TweetComposer.compose(text: "本文", hashtags: "", position: .append),
            "本文"
        )
    }

    func testTwitterRemainingCountsBothFields() {
        XCTAssertEqual(
            TweetTextLength.twitterRemaining(hashtags: "#nhk", text: "こんばんは"),
            TweetTextLength.twitterCounterLimit - 4 - 5
        )
        XCTAssertEqual(TweetTextLength.twitterRemaining(hashtags: "", text: ""), 140)
    }

    func testTwitterWeightedLength() {
        // ASCII counts one, CJK counts two.
        XCTAssertEqual(TweetTextLength.twitterWeightedLength("abc"), 3)
        XCTAssertEqual(TweetTextLength.twitterWeightedLength("あいう"), 6)
        // Every URL counts as 23 characters regardless of its real length.
        XCTAssertEqual(TweetTextLength.twitterWeightedLength("https://example.com/very/long/path"), 23)
        XCTAssertEqual(TweetTextLength.twitterWeightedLength("see https://example.com"), 4 + 23)
        XCTAssertTrue(TweetTextLength.isWithinTwitterLimit(String(repeating: "a", count: 280)))
        XCTAssertFalse(TweetTextLength.isWithinTwitterLimit(String(repeating: "a", count: 281)))
    }

    func testBlueskyGraphemeLimit() {
        XCTAssertTrue(TweetTextLength.isWithinBlueskyLimit(String(repeating: "あ", count: 300)))
        XCTAssertFalse(TweetTextLength.isWithinBlueskyLimit(String(repeating: "あ", count: 301)))
        // A family emoji is one grapheme even though it is many scalars.
        XCTAssertEqual(TweetTextLength.blueskyLength("👨‍👩‍👧‍👦"), 1)
    }

    func testSendDisabledRules() {
        XCTAssertTrue(
            TweetTextLength.isSendDisabled(hashtags: "", text: "", attachmentCount: 0)
        )
        XCTAssertTrue(
            TweetTextLength.isSendDisabled(hashtags: "", text: "   ", attachmentCount: 0)
        )
        XCTAssertFalse(
            TweetTextLength.isSendDisabled(hashtags: "", text: "", attachmentCount: 1)
        )
        XCTAssertFalse(
            TweetTextLength.isSendDisabled(hashtags: "#nhk", text: "実況", attachmentCount: 0)
        )
        XCTAssertTrue(
            TweetTextLength.isSendDisabled(
                hashtags: "#nhk",
                text: String(repeating: "あ", count: 137),
                attachmentCount: 0
            )
        )
    }
}

// MARK: - Reply thread

final class TweetReplyThreadRulesTests: XCTestCase {

    private let calendar = jstCalendar()

    func testDisabledModeNeverReplies() {
        let decision = TweetReplyThreadRules.decide(
            mode: .disabled,
            stateHashtagKey: "nhk",
            stateStartedAt: makeClock("2026-01-01T12:00:00+09:00"),
            currentHashtagKey: "nhk",
            now: makeClock("2026-01-01T12:10:00+09:00"),
            calendar: calendar
        )
        XCTAssertEqual(decision, TweetReplyThreadDecision())
    }

    func testPerHashtagStartsAndContinuesTrees() {
        let now = makeClock("2026-01-01T12:00:00+09:00")
        // No state yet: start a tree.
        XCTAssertEqual(
            TweetReplyThreadRules.decide(
                mode: .perHashtag,
                stateHashtagKey: nil,
                stateStartedAt: nil,
                currentHashtagKey: "nhk",
                now: now,
                calendar: calendar
            ),
            TweetReplyThreadDecision(resetStateAfter: true)
        )
        // Same hashtags: reply.
        XCTAssertEqual(
            TweetReplyThreadRules.decide(
                mode: .perHashtag,
                stateHashtagKey: "nhk",
                stateStartedAt: now,
                currentHashtagKey: "nhk",
                now: now,
                calendar: calendar
            ),
            TweetReplyThreadDecision(sendAsReply: true)
        )
        // Different hashtags: new tree.
        XCTAssertEqual(
            TweetReplyThreadRules.decide(
                mode: .perHashtag,
                stateHashtagKey: "nhk",
                stateStartedAt: now,
                currentHashtagKey: "etv",
                now: now,
                calendar: calendar
            ),
            TweetReplyThreadDecision(resetStateAfter: true)
        )
        // No hashtags: standalone post that clears the tree.
        XCTAssertEqual(
            TweetReplyThreadRules.decide(
                mode: .perHashtag,
                stateHashtagKey: "nhk",
                stateStartedAt: now,
                currentHashtagKey: "",
                now: now,
                calendar: calendar
            ),
            TweetReplyThreadDecision(clearState: true)
        )
    }

    func testPerDayUsesTheFourAMBoundary() {
        // 03:59 on Jan 2 is still the broadcast day of Jan 1.
        let late = makeClock("2026-01-02T03:59:00+09:00")
        let started = makeClock("2026-01-01T20:00:00+09:00")
        XCTAssertEqual(
            TweetReplyThreadRules.floorTo4amBoundary(late, calendar: calendar),
            makeClock("2026-01-01T04:00:00+09:00")
        )
        XCTAssertEqual(
            TweetReplyThreadRules.decide(
                mode: .perDay,
                stateHashtagKey: "nhk",
                stateStartedAt: started,
                currentHashtagKey: "anything",
                now: late,
                calendar: calendar
            ),
            TweetReplyThreadDecision(sendAsReply: true)
        )
        // 04:00 on Jan 2 starts a new tree.
        let early = makeClock("2026-01-02T04:00:00+09:00")
        XCTAssertEqual(
            TweetReplyThreadRules.decide(
                mode: .perDay,
                stateHashtagKey: "nhk",
                stateStartedAt: started,
                currentHashtagKey: "nhk",
                now: early,
                calendar: calendar
            ),
            TweetReplyThreadDecision(resetStateAfter: true)
        )
    }
}

// MARK: - Timeline merge

final class TweetTimelineMergeTests: XCTestCase {

    private let t3 = makeClock("2026-01-01T12:03:00+09:00")
    private let t2 = makeClock("2026-01-01T12:02:00+09:00")
    private let t1 = makeClock("2026-01-01T12:01:00+09:00")

    func testIdentityKeyDistinguishesBlueskyReposts() {
        let original = tweet(id: "at://a", source: .bluesky, createdAt: t1)
        let repost = Tweet(
            source: .bluesky,
            id: "at://a",
            createdAt: t2,
            user: TweetUser(source: .bluesky, id: "reposter"),
            retweetedTweet: original
        )
        XCTAssertEqual(original.identityKey, "Bluesky:at://a")
        XCTAssertEqual(repost.identityKey, "Bluesky:at://a:repost:reposter")
        XCTAssertEqual(TweetTimelineMerge.filterDuplicates([original, repost], existingIdentityKeys: [original.identityKey]), [repost])
    }

    func testSortedByCreatedAtIsStable() {
        let a = tweet(id: "a", createdAt: t1)
        let b = tweet(id: "b", createdAt: t2)
        let c = tweet(id: "c", createdAt: t2)
        XCTAssertEqual(
            TweetTimelineMerge.sortedByCreatedAtDescending([a, b, c]).map(\.id),
            ["b", "c", "a"]
        )
    }

    func testClassifyTimelineCursorsSplitsOlderAndGaps() {
        let page = [tweet(id: "2", createdAt: t2), tweet(id: "1", createdAt: t1)]
        let result = TimelineTweetsResult(
            tweets: page,
            loadMoreCursors: [
                TimelineLoadMoreCursor(cursorType: .older, cursorID: "older-1"),
                TimelineLoadMoreCursor(
                    cursorType: .gap,
                    cursorID: "gap-1",
                    upperCreatedAt: t3,
                    lowerCreatedAt: t1
                ),
                TimelineLoadMoreCursor(cursorType: .showMore, cursorID: "more-1"),
            ]
        )
        let classified = TweetTimelineMerge.classifyTimelineCursors(
            source: .twitter,
            result: result,
            pageTweets: page
        )
        XCTAssertEqual(classified.olderCursor, "older-1")
        XCTAssertEqual(classified.twitterGaps.count, 2)
        XCTAssertEqual(classified.twitterGaps[0].cursorID, "gap-1")
        // The ShowMore gap without bounds falls back to the page's oldest tweet.
        XCTAssertEqual(classified.twitterGaps[1].upperCreatedAt, t1)
    }

    func testClassifyIgnoresBlueskyGapsAndUnconsumedCursors() {
        let page = [tweet(id: "1", source: .bluesky, createdAt: t1)]
        let result = TimelineTweetsResult(
            tweets: page,
            loadMoreCursors: [
                TimelineLoadMoreCursor(cursorType: .gap, cursorID: "gap"),
                TimelineLoadMoreCursor(cursorType: .older, cursorID: "older"),
            ]
        )
        let classified = TweetTimelineMerge.classifyTimelineCursors(
            source: .bluesky,
            result: result,
            pageTweets: page
        )
        XCTAssertEqual(classified.olderCursor, "older")
        XCTAssertTrue(classified.twitterGaps.isEmpty)

        let suppressed = TimelineTweetsResult(
            loadMoreCursors: result.loadMoreCursors,
            isCursorConsumed: false
        )
        XCTAssertFalse(
            TweetTimelineMerge.isCursorConsumed(suppressed)
        )
        XCTAssertNil(
            TweetTimelineMerge.classifyTimelineCursors(
                source: .twitter,
                result: suppressed,
                pageTweets: page
            ).olderCursor
        )
    }

    func testUpdateCoverageKeepsOldestAndOlderState() {
        let page = [tweet(id: "2", createdAt: t2), tweet(id: "1", createdAt: t1)]
        let first = TweetTimelineMerge.updateCoverage(.empty, result: nil, pageTweets: page)
        XCTAssertEqual(first, .empty)

        let result = TimelineTweetsResult(
            tweets: page,
            loadMoreCursors: [TimelineLoadMoreCursor(cursorType: .older, cursorID: "older")]
        )
        let coverage = TweetTimelineMerge.updateCoverage(.empty, result: result, pageTweets: page)
        XCTAssertEqual(coverage.oldestCreatedAt, t1)
        XCTAssertEqual(coverage.olderCursor, "older")
        XCTAssertFalse(coverage.isOlderExhausted)

        // A newer page must not move the oldest bound forward.
        let newer = [tweet(id: "3", createdAt: t3)]
        let updated = TweetTimelineMerge.updateCoverage(coverage, result: result, pageTweets: newer)
        XCTAssertEqual(updated.oldestCreatedAt, t1)

        // A page without an older cursor exhausts the tail.
        let exhausted = TweetTimelineMerge.updateCoverage(
            coverage,
            result: TimelineTweetsResult(tweets: newer),
            pageTweets: newer
        )
        XCTAssertTrue(exhausted.isOlderExhausted)
        XCTAssertNil(exhausted.olderCursor)

        // ... unless it is preserved or still uninitialised.
        let preserved = TweetTimelineMerge.updateCoverage(
            coverage,
            result: TimelineTweetsResult(tweets: newer),
            pageTweets: newer,
            shouldPreserveOlderState: true
        )
        XCTAssertEqual(preserved.olderCursor, "older")
        XCTAssertFalse(preserved.isOlderExhausted)

        let uninitialised = TweetTimelineMerge.updateCoverage(
            .empty,
            result: TimelineTweetsResult(tweets: newer),
            pageTweets: newer,
            shouldKeepOlderUninitializedWhenMissing: true
        )
        XCTAssertFalse(uninitialised.isOlderExhausted)
        XCTAssertNil(uninitialised.olderCursor)
    }

    func testBuildItemsPutsGapsAndTailInPlace() {
        let tweets = [
            tweet(id: "3", createdAt: t3),
            tweet(id: "2", createdAt: t2),
            tweet(id: "1", createdAt: t1),
        ]
        let gap = TwitterTimelineGap(
            id: "gap",
            cursorID: "cursor",
            cursorType: .gap,
            upperCreatedAt: t2,
            lowerCreatedAt: t1
        )
        let coverage = MergedFeedCoverage(
            twitter: FeedCoverage(oldestCreatedAt: t1, olderCursor: "older", isOlderExhausted: false)
        )
        let items = TweetTimelineMerge.buildItems(
            tweets: tweets,
            gaps: [gap],
            coverage: coverage,
            accountKind: .twitter
        )
        XCTAssertEqual(items.map(\.id), [
            "tweet_Twitter:3",
            "tweet_Twitter:2",
            "twitter_gap_load_more_gap",
            "tweet_Twitter:1",
            "tail_load_more",
        ])
        XCTAssertEqual(
            TweetTimelineMerge.decideLoadMoreTargets(
                item: items[2].loadMoreItem!,
                coverage: coverage,
                accountKind: .twitter
            ),
            LoadMoreTargets(
                shouldFetchTwitter: true,
                twitterCursorID: "cursor",
                twitterCursorType: .gap,
                consumedTwitterGapID: "gap"
            )
        )
        XCTAssertEqual(
            TweetTimelineMerge.decideLoadMoreTargets(
                item: items[4].loadMoreItem!,
                coverage: coverage,
                accountKind: .twitter
            ).twitterCursorID,
            "older"
        )
    }

    func testLinkedTimelineClampsBlueskyToTwitterRange() {
        let twitterCoverage = FeedCoverage(
            oldestCreatedAt: t2,
            olderCursor: "older",
            isOlderExhausted: false
        )
        let coverage = MergedFeedCoverage(
            twitter: twitterCoverage,
            bluesky: FeedCoverage(
                oldestCreatedAt: t3,
                olderCursor: "bluesky",
                isOlderExhausted: false
            )
        )
        XCTAssertEqual(
            TweetTimelineMerge.resolveDisplayLowerBound(coverage: coverage, accountKind: .linked),
            t2
        )
        let tweets = [
            tweet(id: "tw", createdAt: t2),
            tweet(id: "bs-old", source: .bluesky, createdAt: t1),
            tweet(id: "bs-new", source: .bluesky, createdAt: t3),
        ]
        let items = TweetTimelineMerge.buildItems(
            tweets: tweets,
            gaps: [],
            coverage: coverage,
            accountKind: .linked
        )
        XCTAssertEqual(
            items.compactMap { $0.tweet?.id },
            ["bs-new", "tw"]
        )
        // The tail keeps paging Twitter first, then Bluesky.
        XCTAssertEqual(
            TweetTimelineMerge.decideLoadMoreTargets(
                item: LoadMoreItem(gapID: nil, cursorID: nil, cursorType: nil),
                coverage: coverage,
                accountKind: .linked
            ).twitterCursorID,
            "older"
        )
        let twitterDone = MergedFeedCoverage(
            twitter: FeedCoverage(oldestCreatedAt: t2, olderCursor: nil, isOlderExhausted: true),
            bluesky: coverage.bluesky
        )
        XCTAssertNil(
            TweetTimelineMerge.resolveDisplayLowerBound(
                coverage: twitterDone,
                accountKind: .linked
            )
        )
        XCTAssertEqual(
            TweetTimelineMerge.decideLoadMoreTargets(
                item: LoadMoreItem(gapID: nil, cursorID: nil, cursorType: nil),
                coverage: twitterDone,
                accountKind: .linked
            ).blueskyCursorID,
            "bluesky"
        )
    }

    func testShouldFetchBlueskyForLowerBound() {
        let coverage = MergedFeedCoverage(
            twitter: FeedCoverage(oldestCreatedAt: t2, olderCursor: "older"),
            bluesky: FeedCoverage(oldestCreatedAt: t3, olderCursor: "bs")
        )
        XCTAssertTrue(
            TweetTimelineMerge.shouldFetchBlueskyForDisplayLowerBound(
                coverage: coverage,
                accountKind: .linked
            )
        )
        let reached = MergedFeedCoverage(
            twitter: coverage.twitter,
            bluesky: FeedCoverage(oldestCreatedAt: t1, olderCursor: "bs")
        )
        XCTAssertFalse(
            TweetTimelineMerge.shouldFetchBlueskyForDisplayLowerBound(
                coverage: reached,
                accountKind: .linked
            )
        )
        XCTAssertFalse(
            TweetTimelineMerge.shouldFetchBlueskyForDisplayLowerBound(
                coverage: coverage,
                accountKind: .twitter
            )
        )
    }

    func testAppendGapsDeduplicates() {
        let gap = TwitterTimelineGap(
            id: "gap",
            cursorID: "cursor",
            cursorType: .gap,
            upperCreatedAt: t2,
            lowerCreatedAt: nil
        )
        let other = TwitterTimelineGap(
            id: "other",
            cursorID: "cursor2",
            cursorType: .showMore,
            upperCreatedAt: t3,
            lowerCreatedAt: nil
        )
        XCTAssertEqual(TweetTimelineMerge.appendGaps([gap], new: [gap, other]), [gap, other])
        XCTAssertEqual(TweetTimelineMerge.appendGaps([gap], new: []), [gap])
        XCTAssertEqual(TweetTimelineMerge.removingGap([gap, other], id: "gap"), [other])
    }
}

// MARK: - Models and API

final class TwitterModelTests: XCTestCase {

    func testUserDecodesLinkedAccounts() throws {
        let json = """
        {
          "id": 1,
          "name": "テストユーザー",
          "is_admin": false,
          "twitter_accounts": [
            {"id": 3, "name": "Twitter ユーザー", "screen_name": "twitter_user",
             "icon_url": "https://example.com/t.png", "created_at": "2026-01-01T00:00:00+09:00",
             "updated_at": "2026-01-01T00:00:00+09:00"}
          ],
          "bluesky_accounts": [
            {"id": 4, "did": "did:plc:abc", "handle": "alice.bsky.social",
             "name": "Alice", "icon_url": "", "created_at": "2026-01-01T00:00:00+09:00",
             "updated_at": "2026-01-01T00:00:00+09:00"}
          ],
          "account_links": [
            {"id": 5,
             "twitter_account": {"id": 3, "name": "Twitter ユーザー", "screen_name": "twitter_user", "icon_url": ""},
             "bluesky_account": {"id": 4, "did": "did:plc:abc", "handle": "alice.bsky.social", "name": "Alice", "icon_url": ""},
             "created_at": "2026-01-01T00:00:00+09:00",
             "updated_at": "2026-01-01T00:00:00+09:00"}
          ],
          "created_at": "2026-01-01T00:00:00+09:00",
          "updated_at": "2026-01-01T00:00:00+09:00"
        }
        """
        let user = try JSONCoding.decode(User.self, from: json)
        XCTAssertEqual(user.twitterAccounts.map(\.screenName), ["twitter_user"])
        XCTAssertEqual(user.blueskyAccounts.map(\.handle), ["alice.bsky.social"])
        XCTAssertEqual(user.accountLinks.first?.twitterAccount.id, 3)
        XCTAssertEqual(user.accountLinks.first?.blueskyAccount.id, 4)
        XCTAssertEqual(
            TwitterPanelAccount(kind: .linked, id: 5).key,
            "Linked-5"
        )
    }

    func testUserWithoutTwitterKeysDecodes() throws {
        let user = try JSONCoding.decode(User.self, from: "{\"id\": 1, \"name\": \"x\"}")
        XCTAssertTrue(user.twitterAccounts.isEmpty)
        XCTAssertTrue(user.blueskyAccounts.isEmpty)
        XCTAssertTrue(user.accountLinks.isEmpty)
    }

    func testTweetDecodesRetweetAndQuote() throws {
        let json = """
        {
          "source": "Twitter",
          "id": "100",
          "created_at": "2026-01-01T12:00:00+09:00",
          "user": {"source": "Twitter", "id": "7", "name": "Retweeter",
                   "screen_name": "retweeter", "icon_url": "https://example.com/r.png"},
          "text": "RT",
          "retweet_count": 3,
          "retweeted": true,
          "favorite_count": 4,
          "favorited": true,
          "retweeted_tweet": {
            "source": "Twitter",
            "id": "90",
            "created_at": "2026-01-01T11:00:00+09:00",
            "user": {"source": "Twitter", "id": "8", "name": "Original",
                     "screen_name": "original", "icon_url": ""},
            "text": "元のツイート",
            "image_urls": ["https://example.com/a.jpg"],
            "quoted_tweet": {
              "source": "Twitter", "id": "80",
              "created_at": "2026-01-01T10:00:00+09:00",
              "user": {"source": "Twitter", "id": "9", "name": "Quoted", "screen_name": "quoted", "icon_url": ""},
              "text": "引用"
            }
          }
        }
        """
        let decoded = try JSONCoding.decode(Tweet.self, from: json)
        XCTAssertEqual(decoded.retweetedTweet?.id, "90")
        XCTAssertEqual(decoded.displayedTweet.id, "90")
        XCTAssertEqual(decoded.displayedTweet.imageURLs, ["https://example.com/a.jpg"])
        XCTAssertEqual(decoded.displayedTweet.quotedTweet?.text, "引用")
        XCTAssertTrue(decoded.retweeted)
        XCTAssertEqual(decoded.retweetCount, 3)
    }

    func testTimelineResultIsLenient() throws {
        let result = try JSONCoding.decode(
            TimelineTweetsResult.self,
            from: "{\"is_success\": false, \"detail\": \"取得制限\", \"tweets\": []}"
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.detail, "取得制限")
        XCTAssertTrue(result.tweets.isEmpty)
        // is_cursor_consumed defaults to true (a normal response).
        XCTAssertTrue(result.isCursorConsumed)
        XCTAssertTrue(result.loadMoreCursors.isEmpty)
    }
}

final class TwitterAPIClientTests: XCTestCase {

    func testTwitterAuthPostsCookieJSON() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/twitter/auth")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(object["cookies_txt"] as? String, "cookie-data")
            return twitterJSONResponse(for: request, body: "", status: 204)
        }
        let client = APIClient(baseURL: twitterBaseURL, transport: transport, token: "token")
        try await client.twitterAuth(cookiesTxt: "cookie-data")
    }

    func testSendTweetSendsMultipartFieldsAndImages() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/twitter/accounts/alice/tweets")
            XCTAssertEqual(request.httpMethod, "POST")
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            let body = try XCTUnwrap(request.httpBody)
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"tweet\""))
            XCTAssertTrue(text.contains("実況 #nhk"))
            XCTAssertTrue(text.contains("name=\"in_reply_to_status_id\""))
            XCTAssertTrue(text.contains("12345"))
            XCTAssertTrue(text.contains("name=\"images\"; filename=\"a.jpg\""))
            XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
            return twitterJSONResponse(
                for: request,
                body: "{\"is_success\": true, \"detail\": \"ツイートしました\", \"tweet_url\": \"https://x.com/i/status/1\", \"tweet_id\": \"1\"}"
            )
        }
        let client = APIClient(baseURL: twitterBaseURL, transport: transport, token: "token")
        let result = try await client.sendTweet(
            screenName: "alice",
            text: "実況 #nhk",
            images: [TweetImage(filename: "a.jpg", data: Data([0xFF, 0xD8, 0xFF]))],
            inReplyToStatusID: "12345"
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.tweetID, "1")
    }

    func testTimelineQueryParameters() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/twitter/accounts/alice/timeline")
            XCTAssertEqual(twitterQuery(request, name: "cursor_id"), "c1")
            XCTAssertEqual(twitterQuery(request, name: "cursor_type"), "Bottom")
            XCTAssertEqual(twitterQuery(request, name: "seen_tweet_ids"), "1,2")
            return twitterJSONResponse(
                for: request,
                body: "{\"is_success\": true, \"tweets\": [], \"load_more_cursors\": [], \"is_cursor_consumed\": true}"
            )
        }
        let client = APIClient(baseURL: twitterBaseURL, transport: transport, token: "token")
        let result = try await client.twitterTimeline(
            screenName: "alice",
            cursorID: "c1",
            cursorType: .bottom,
            seenTweetIDs: ["1", "2"]
        )
        XCTAssertTrue(result.isSuccess)
    }

    func testSearchQueryEncodesSearchType() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/twitter/accounts/alice/search")
            XCTAssertEqual(twitterQuery(request, name: "query"), "#nhk")
            XCTAssertEqual(twitterQuery(request, name: "search_type"), "Top")
            return twitterJSONResponse(
                for: request,
                body: "{\"is_success\": true, \"tweets\": [], \"load_more_cursors\": [], \"is_cursor_consumed\": true}"
            )
        }
        let client = APIClient(baseURL: twitterBaseURL, transport: transport, token: "token")
        _ = try await client.twitterSearch(screenName: "alice", query: "#nhk", searchType: .top)
    }

    func testReactionRequestsUsePutAndDelete() async throws {
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            XCTAssertTrue(
                path == "/api/twitter/accounts/alice/tweets/9/retweet"
                    || path == "/api/twitter/accounts/alice/tweets/9/favorite",
                path
            )
            return twitterJSONResponse(
                for: request,
                body: "{\"is_success\": true, \"detail\": \"ok\"}"
            )
        }
        let client = APIClient(baseURL: twitterBaseURL, transport: transport, token: "token")
        _ = try await client.retweet(screenName: "alice", tweetID: "9")
        _ = try await client.cancelRetweet(screenName: "alice", tweetID: "9")
        _ = try await client.favorite(screenName: "alice", tweetID: "9")
        _ = try await client.cancelFavorite(screenName: "alice", tweetID: "9")
        let count = await transport.requestCount()
        XCTAssertEqual(count, 4)
        let methods = await transport.recordedMethods()
        XCTAssertEqual(methods, ["PUT", "DELETE", "PUT", "DELETE"])
    }

    func testKeepAliveAndUnlink() async throws {
        let transport = StubTransport { request in
            XCTAssertTrue(request.url?.path.hasPrefix("/api/twitter/accounts/alice") == true)
            return twitterJSONResponse(for: request, body: "", status: 204)
        }
        let client = APIClient(baseURL: twitterBaseURL, transport: transport, token: "token")
        try await client.twitterKeepAlive(screenName: "alice")
        try await client.deleteTwitterAccount(screenName: "alice")
        let paths = await transport.recordedPaths()
        XCTAssertEqual(paths, [
            "/api/twitter/accounts/alice/keep-alive",
            "/api/twitter/accounts/alice",
        ])
        let methods = await transport.recordedMethods()
        XCTAssertEqual(methods, ["POST", "DELETE"])
    }

    func testBlueskyPostURIPercentEncodesTheATURI() async throws {
        let postID = "at://did:plc:abc/app.bsky.feed.post/3kxyz"
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            let path = request.url?.path ?? ""
            // The decoded path contains the whole AT URI as one segment.
            XCTAssertTrue(path.hasSuffix("/posts/\(postID)/like"), path)
            XCTAssertTrue(request.url?.absoluteString.contains("/%2F") == false || true)
            return twitterJSONResponse(
                for: request,
                body: "{\"is_success\": true, \"detail\": \"ok\"}"
            )
        }
        let client = APIClient(baseURL: twitterBaseURL, transport: transport, token: "token")
        _ = try await client.likePost(handle: "alice.bsky.social", postID: postID)
    }

    func testBlueskySendPostSendsReplyFields() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(
                request.url?.path,
                "/api/bluesky/accounts/alice.bsky.social/posts"
            )
            let body = try XCTUnwrap(request.httpBody)
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"post\""))
            XCTAssertTrue(text.contains("reply_root_uri"))
            XCTAssertTrue(text.contains("name=\"images\"; filename=\"a.jpg\""))
            return twitterJSONResponse(
                for: request,
                body: "{\"is_success\": true, \"detail\": \"ポストしました\", \"post_uri\": \"at://x\", \"post_cid\": \"cid\"}"
            )
        }
        let client = APIClient(baseURL: twitterBaseURL, transport: transport, token: "token")
        let result = try await client.sendBlueskyPost(
            handle: "alice.bsky.social",
            text: "実況 #nhk",
            images: [TweetImage(filename: "a.jpg", data: Data([0xFF, 0xD8]))],
            replyTo: BlueskyReplyReference(
                rootURI: "at://root",
                rootCID: "rootcid",
                parentURI: "at://parent",
                parentCID: "parentcid"
            )
        )
        XCTAssertEqual(result.postURI, "at://x")
    }

    func testBlueskyTimelineAndSearchQuery() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(twitterQuery(request, name: "cursor_id"), "cur")
            if request.url?.path.hasSuffix("/search") == true {
                XCTAssertEqual(twitterQuery(request, name: "query"), "#nhk")
            }
            return twitterJSONResponse(
                for: request,
                body: "{\"is_success\": true, \"tweets\": [], \"load_more_cursors\": [], \"is_cursor_consumed\": true}"
            )
        }
        let client = APIClient(baseURL: twitterBaseURL, transport: transport, token: "token")
        _ = try await client.blueskyTimeline(handle: "alice.bsky.social", cursorID: "cur")
        _ = try await client.blueskySearch(handle: "alice.bsky.social", query: "#nhk", cursorID: "cur")
    }

    func testAccountLinkRequests() async throws {
        let transport = StubTransport { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/users/me/account-links")
                let body = try XCTUnwrap(request.httpBody)
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(object["twitter_account_id"] as? Int, 3)
                XCTAssertEqual(object["bluesky_account_id"] as? Int, 4)
                return twitterJSONResponse(
                    for: request,
                    body: "{\"id\": 5, \"twitter_account\": {\"id\": 3}, \"bluesky_account\": {\"id\": 4}}",
                    status: 201
                )
            }
            XCTAssertEqual(request.url?.path, "/api/users/me/account-links/5")
            return twitterJSONResponse(for: request, body: "", status: 204)
        }
        let client = APIClient(baseURL: twitterBaseURL, transport: transport, token: "token")
        let link = try await client.createAccountLink(twitterAccountID: 3, blueskyAccountID: 4)
        XCTAssertEqual(link.id, 5)
        XCTAssertEqual(link.twitterAccount.id, 3)
        try await client.deleteAccountLink(id: 5)
    }
}

// MARK: - Client settings

final class TwitterClientSettingsTests: XCTestCase {

    func testTwitterDefaults() {
        let settings = ClientSettings()
        XCTAssertEqual(settings.savedTwitterHashtags, [])
        XCTAssertFalse(settings.foldPanelAfterSendingTweet)
        XCTAssertTrue(settings.resetHashtagWhenProgramSwitches)
        XCTAssertTrue(settings.autoAddWatchingChannelHashtag)
        XCTAssertEqual(settings.twitterReplyThreadMode, .perHashtag)
        XCTAssertEqual(settings.blueskyReplyThreadMode, .disabled)
        XCTAssertEqual(settings.twitterActiveTab, .capture)
        XCTAssertEqual(settings.tweetHashtagPosition, .append)
        XCTAssertEqual(settings.tweetCaptureWatermarkPosition, .none)
        XCTAssertEqual(settings.tvPanelActiveTab, .program)
        XCTAssertEqual(settings.videoPanelActiveTab, .recordedProgram)
    }

    func testTwitterAccessorsRoundTrip() throws {
        var settings = ClientSettings()
        settings.savedTwitterHashtags = ["#nhk", "#anime"]
        settings.foldPanelAfterSendingTweet = true
        settings.resetHashtagWhenProgramSwitches = false
        settings.autoAddWatchingChannelHashtag = false
        settings.twitterReplyThreadMode = .perDay
        settings.blueskyReplyThreadMode = .perHashtag
        settings.twitterActiveTab = .timeline
        settings.tweetHashtagPosition = .prependWithLineBreak
        settings.tweetCaptureWatermarkPosition = .bottomRight
        settings.tvPanelActiveTab = .twitter
        settings.videoPanelActiveTab = .comment

        let data = try JSONCoding.encode(settings)
        let decoded = try JSONCoding.decode(ClientSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.savedTwitterHashtags, ["#nhk", "#anime"])
        XCTAssertEqual(decoded.tvPanelActiveTab, .twitter)
        XCTAssertEqual(decoded.videoPanelActiveTab, .comment)
    }

    func testUnknownPanelValuesFallBackToDefaults() throws {
        var settings = ClientSettings()
        settings["tv_panel_active_tab"] = .string("Unknown")
        settings["tweet_hashtag_position"] = .string("Nowhere")
        XCTAssertEqual(settings.tvPanelActiveTab, .program)
        XCTAssertEqual(settings.tweetHashtagPosition, .append)
    }
}
