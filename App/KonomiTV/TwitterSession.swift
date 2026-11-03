import Foundation
import KonomiKit
import Observation

/// One selectable account of the watch screen's Twitter tab.
///
/// Linked pairs come first, then the accounts that are not part of a pair, like
/// the web client's buildSelectableAccounts.
enum TwitterAccountItem: Identifiable, Hashable {
    case twitter(TwitterAccount)
    case bluesky(BlueskyAccount)
    case linked(AccountLink)

    var account: TwitterPanelAccount {
        switch self {
        case .twitter(let account):
            return TwitterPanelAccount(kind: .twitter, id: account.id)
        case .bluesky(let account):
            return TwitterPanelAccount(kind: .bluesky, id: account.id)
        case .linked(let link):
            return TwitterPanelAccount(kind: .linked, id: link.id)
        }
    }

    var id: String { account.key }

    var twitter: TwitterAccount? {
        switch self {
        case .twitter(let account): return account
        case .linked(let link): return link.twitterAccount
        case .bluesky: return nil
        }
    }

    var bluesky: BlueskyAccount? {
        switch self {
        case .bluesky(let account): return account
        case .linked(let link): return link.blueskyAccount
        case .twitter: return nil
        }
    }

    var displayName: String {
        switch self {
        case .twitter(let account): return account.name
        case .bluesky(let account): return account.name
        case .linked(let link): return link.twitterAccount.name
        }
    }

    var screenName: String {
        switch self {
        case .twitter(let account): return account.screenName
        case .bluesky(let account): return account.handle
        case .linked(let link): return link.twitterAccount.screenName
        }
    }

    var iconURL: URL? {
        let raw: String
        switch self {
        case .twitter(let account): raw = account.iconURL
        case .bluesky(let account): raw = account.iconURL
        case .linked(let link): raw = link.twitterAccount.iconURL
        }
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

/// One of the two merged feeds of the Twitter panel.
enum FeedKind {
    case timeline
    case search
}

/// Loaded state of one feed (timeline or search).
struct FeedState {
    var tweets: [String: Tweet] = [:]
    var gaps: [TwitterTimelineGap] = []
    var coverage = MergedFeedCoverage()
    var newerCursor: String?
    var isLoading = false
    var hasLoaded = false
    var items: [TimelineDisplayItem] = []
    var errorMessage: String?
}

/// One service's post result, normalised for the two-service notification.
private struct PostOutcome {
    var source: TweetSource
    var message: String
    var isError: Bool
    var tweetID: String?
    var postURI: String?
    var postCID: String?
}

/// State and actions of the watch screen's Twitter tab.
///
/// Mirrors the web client's Panel/Twitter.vue, TwitterStore and the per-tab
/// (Search / Timeline) components: account selection, the composer with
/// hashtags and captures, reply trees, the merged timeline / search feeds and
/// the reaction toggles.
@MainActor
@Observable
final class TwitterSession {
    /// Seconds between keep-alive pings while the panel is visible.
    private static let keepAliveInterval: Duration = .seconds(10)
    /// How many Bluesky pages are fetched to reach Twitter's loaded range.
    private static let maxBlueskyCatchUpPages = 5
    /// How many captures the panel offers for attaching.
    static let maxSessionCaptures = 100

    let model: AppModel
    private let playback: PlaybackController

    // MARK: Watch context

    /// Name of the watched channel (nil for recorded video playback).
    private(set) var channelName: String?
    /// Title of the current program / recorded video (the capture watermark).
    private(set) var programTitle = ""
    /// Program ID (live) so switch detection does not depend on the title.
    private(set) var programID: String?

    // MARK: Accounts

    private(set) var accountItems: [TwitterAccountItem] = []
    private(set) var selectedItem: TwitterAccountItem?
    private(set) var isRefreshingAccounts = false

    // MARK: Composer

    var text = ""
    var hashtagField = ""
    private(set) var selectedCaptureIndices: Set<Int> = []
    private(set) var isSending = false
    private(set) var notice: String?
    private(set) var noticeIsError = false
    var onFoldPanel: (() -> Void)?

    // MARK: Feeds

    private(set) var timelineFeed = FeedState()
    private(set) var searchFeed = FeedState()
    var searchQuery = ""

    // MARK: Observation ignored

    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(model: AppModel, playback: PlaybackController) {
        self.model = model
        self.playback = playback
    }

    // MARK: - Context

    var isLive: Bool { channelName != nil }

    /// Channel hashtag that is added automatically, when enabled.
    var autoChannelHashtag: String? {
        guard isLive, model.settings.autoAddWatchingChannelHashtag else { return nil }
        return TweetHashtagRules.channelHashtag(for: channelName ?? "")
    }

    /// The hashtag field after normalising and adding the station hashtag.
    var formattedHashtag: String {
        TweetHashtagRules.format(hashtagField, appendingChannelHashtag: autoChannelHashtag)
    }

    /// Updates the watch context and applies the station hashtag / reset rules
    /// of the web client's channel and program watchers.
    func updateContext(channelName: String?, programTitle: String, programID: String?) {
        let oldChannel = self.channelName
        let oldProgram = self.programID
        self.channelName = channelName
        self.programTitle = programTitle
        self.programID = programID

        let oldHashtag = oldChannel.flatMap { TweetHashtagRules.channelHashtag(for: $0) }
        let newHashtag = channelName.flatMap { TweetHashtagRules.channelHashtag(for: $0) }

        if channelName != nil, oldChannel != channelName {
            hashtagField = TweetHashtagRules.fieldAfterChannelSwitch(
                hashtagField,
                oldChannelHashtag: oldHashtag,
                newChannelHashtag: autoChannelHashtag,
                resetOnProgramSwitch: model.settings.resetHashtagWhenProgramSwitches
            )
            let previousQuery = searchQuery
            if searchQuery.isEmpty || searchQuery == (oldHashtag ?? "") {
                searchQuery = newHashtag ?? ""
            }
            // The search tab searches the station hashtag; follow the channel
            // switch once its results are already on screen.
            if searchQuery != previousQuery, searchFeed.hasLoaded, !searchQuery.isEmpty {
                Task { [weak self] in
                    await self?.search()
                }
            }
        } else if oldProgram != programID {
            hashtagField = TweetHashtagRules.fieldAfterProgramSwitch(
                hashtagField,
                resetOnProgramSwitch: model.settings.resetHashtagWhenProgramSwitches,
                autoChannelHashtag: autoChannelHashtag
            )
        }
    }

    // MARK: - Accounts

    func load() async {
        await refreshAccounts()
        await ensureSearchQuery()
    }

    func refreshAccounts() async {
        isRefreshingAccounts = true
        defer { isRefreshingAccounts = false }

        if model.user == nil, model.token != nil {
            await model.refreshUser()
        }
        rebuildAccountItems()
    }

    private func rebuildAccountItems() {
        guard let user = model.user else {
            accountItems = []
            selectedItem = nil
            return
        }

        // Accounts that are part of a pair are not offered on their own, so a
        // post cannot be duplicated by picking both rows.
        let linkedTwitterIDs = Set(user.accountLinks.map(\.twitterAccount.id))
        let linkedBlueskyIDs = Set(user.accountLinks.map(\.blueskyAccount.id))

        var items: [TwitterAccountItem] = user.accountLinks.map { .linked($0) }
        items += user.twitterAccounts
            .filter { !linkedTwitterIDs.contains($0.id) }
            .map { .twitter($0) }
        items += user.blueskyAccounts
            .filter { !linkedBlueskyIDs.contains($0.id) }
            .map { .bluesky($0) }
        accountItems = items

        if let saved = model.selectedTwitterPanelAccount,
           let match = items.first(where: { $0.account == saved }) {
            selectedItem = match
        } else if let first = items.first {
            select(first)
        } else {
            selectedItem = nil
            model.setSelectedTwitterPanelAccount(nil)
        }
    }

    func select(_ item: TwitterAccountItem) {
        guard item.account != selectedItem?.account else { return }
        selectedItem = item
        model.setSelectedTwitterPanelAccount(item.account)

        timelineFeed = FeedState()
        searchFeed = FeedState()
        if searchQuery.isEmpty {
            searchQuery = TweetHashtagRules.channelHashtag(for: channelName ?? "") ?? ""
        }
    }

    var accountKind: TimelineAccountKind {
        guard let selectedItem else { return .twitter }
        switch selectedItem {
        case .twitter: return .twitter
        case .bluesky: return .bluesky
        case .linked: return .linked
        }
    }

    var postTarget: TwitterPanelPostTarget {
        guard let selectedItem else {
            return TwitterPanelPostTarget(isPostToTwitter: false, isPostToBluesky: false)
        }
        switch selectedItem {
        case .twitter:
            return TwitterPanelPostTarget(isPostToTwitter: true, isPostToBluesky: false)
        case .bluesky:
            return TwitterPanelPostTarget(isPostToTwitter: false, isPostToBluesky: true)
        case .linked:
            return model.twitterPanelPostTarget(for: selectedItem.account.key)
        }
    }

    /// Cycles the post target of a linked account (both, Twitter, Bluesky).
    func cyclePostTarget() {
        guard let item = selectedItem, case .linked = item else { return }
        var target = postTarget
        target.cycle()
        model.setTwitterPanelPostTarget(target, for: item.account.key)
    }

    // MARK: - Keep-alive

    /// Starts pinging the server's headless browser while the panel is shown.
    func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pingKeepAlive()
                do {
                    try await Task.sleep(for: Self.keepAliveInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    private func pingKeepAlive() async {
        guard let client = model.client,
              let screenName = selectedItem?.twitter?.screenName else {
            return
        }
        try? await client.twitterKeepAlive(screenName: screenName)
    }

    // MARK: - Composer

    /// Captures produced since the app launched.
    var captures: [ProducedCapture] { playback.capture.sessionCaptures }

    var selectedCaptureCount: Int { selectedCaptureIndices.count }

    func isCaptureSelected(_ index: Int) -> Bool {
        selectedCaptureIndices.contains(index)
    }

    func toggleCapture(_ index: Int) {
        if selectedCaptureIndices.contains(index) {
            selectedCaptureIndices.remove(index)
        } else if selectedCaptureIndices.count < 4 {
            selectedCaptureIndices.insert(index)
        }
    }

    /// Remaining characters shown by the meter (the web client's count).
    var remainingCharacters: Int {
        TweetTextLength.twitterRemaining(hashtags: hashtagField, text: text)
    }

    /// Whether the account's length limit is exceeded for the given services.
    var isOverLimit: Bool {
        let target = postTarget
        let posted = TweetComposer.compose(
            text: text,
            hashtags: formattedHashtag,
            position: model.settings.tweetHashtagPosition
        )
        var over = false
        if target.isPostToTwitter, remainingCharacters < 0 {
            over = true
        }
        if target.isPostToBluesky, !TweetTextLength.isWithinBlueskyLimit(posted) {
            over = true
        }
        return over
    }

    var canSend: Bool {
        guard !isSending, selectedItem != nil else { return false }
        let target = postTarget
        guard target.isPostToTwitter || target.isPostToBluesky else { return false }
        if isOverLimit { return false }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !selectedCaptureIndices.isEmpty
    }

    /// Applies a saved hashtag to the field (the web client's hashtag list).
    func applySavedHashtag(_ hashtag: String) {
        hashtagField = TweetHashtagRules.format(hashtag)
    }

    /// Saves the current hashtags to the saved list (saved_twitter_hashtags).
    func saveCurrentHashtags() {
        let tags = TweetHashtagRules.hashtags(in: formattedHashtag)
        guard !tags.isEmpty else { return }
        model.mutateSettings { settings in
            var saved = settings.savedTwitterHashtags
            for tag in tags where !saved.contains(tag) {
                saved.append(tag)
            }
            settings.savedTwitterHashtags = saved
        }
    }

    func removeSavedHashtag(_ hashtag: String) {
        model.mutateSettings { settings in
            settings.savedTwitterHashtags.removeAll { $0 == hashtag }
        }
    }

    // MARK: - Posting

    func send() {
        guard canSend, let item = selectedItem, let client = model.client else { return }

        let target = postTarget
        let hashtags = TweetHashtagRules.hashtags(in: formattedHashtag)
        let hashtagKey = TweetHashtagRules.normalizedKey(hashtags)
        let postedText = TweetComposer.compose(
            text: text,
            hashtags: formattedHashtag,
            position: model.settings.tweetHashtagPosition
        )
        let images = attachableImages()

        // Prevent a double post: the fields are cleared before the requests.
        text = ""
        selectedCaptureIndices = []
        hashtagField = formattedHashtag
        isSending = true

        let snapshot = (
            twitter: target.isPostToTwitter ? item.twitter?.screenName : nil,
            bluesky: target.isPostToBluesky ? item.bluesky?.handle : nil
        )

        Task { [weak self] in
            guard let self else { return }
            defer { self.isSending = false }

            async let twitterOutcome = self.postToTwitter(
                client: client,
                screenName: snapshot.twitter,
                text: postedText,
                images: images,
                hashtagKey: hashtagKey
            )
            async let blueskyOutcome = self.postToBluesky(
                client: client,
                handle: snapshot.bluesky,
                text: postedText,
                images: images,
                hashtagKey: hashtagKey
            )
            let (twitterResult, blueskyResult) = await (twitterOutcome, blueskyOutcome)
            let outcomes = [twitterResult, blueskyResult].compactMap { $0 }
            self.showPostOutcome(outcomes)
            if outcomes.contains(where: { !$0.isError }),
               self.model.settings.foldPanelAfterSendingTweet {
                self.onFoldPanel?()
            }
        }
    }

    /// The selected captures as upload images, with the program title watermark
    /// when enabled.
    private func attachableImages() -> [TweetImage] {
        let captures = self.captures
        var images: [TweetImage] = []
        let position = model.settings.tweetCaptureWatermarkPosition
        for index in selectedCaptureIndices.sorted() {
            guard captures.indices.contains(index) else { continue }
            let capture = captures[index]
            var data = capture.data
            if position != .none, !programTitle.isEmpty,
               let watermarked = CaptureController.watermarked(
                   capture.data,
                   title: programTitle,
                   position: position
               ) {
                data = watermarked
            }
            images.append(TweetImage(filename: capture.filename, data: data))
        }
        return images
    }

    private func postToTwitter(
        client: APIClient,
        screenName: String?,
        text: String,
        images: [TweetImage],
        hashtagKey: String
    ) async -> PostOutcome? {
        guard let screenName else { return nil }

        let state = model.twitterReplyThreadState(for: screenName)
        let now = Date()
        let decision = TweetReplyThreadRules.decide(
            mode: model.settings.twitterReplyThreadMode,
            stateHashtagKey: state?.hashtagKey,
            stateStartedAt: state?.startedAt,
            currentHashtagKey: hashtagKey,
            now: now
        )

        do {
            let result = try await client.sendTweet(
                screenName: screenName,
                text: text,
                images: images,
                inReplyToStatusID: decision.sendAsReply ? state?.lastTweetID : nil
            )
            guard result.isSuccess else {
                return PostOutcome(
                    source: .twitter,
                    message: result.detail,
                    isError: true
                )
            }
            if let tweetID = result.tweetID {
                applyTwitterReplyState(
                    decision: decision,
                    screenName: screenName,
                    tweetID: tweetID,
                    hashtagKey: hashtagKey,
                    now: now
                )
            }
            return PostOutcome(
                source: .twitter,
                message: result.detail,
                isError: false,
                tweetID: result.tweetID
            )
        } catch {
            return PostOutcome(
                source: .twitter,
                message: "Twitter へのツイートに失敗しました。(\(ErrorText.message(for: error)))",
                isError: true
            )
        }
    }

    private func applyTwitterReplyState(
        decision: TweetReplyThreadDecision,
        screenName: String,
        tweetID: String,
        hashtagKey: String,
        now: Date
    ) {
        if decision.sendAsReply, var state = model.twitterReplyThreadState(for: screenName) {
            state.lastTweetID = tweetID
            model.setTwitterReplyThreadState(state, for: screenName)
        } else if decision.resetStateAfter {
            model.setTwitterReplyThreadState(
                TwitterReplyThreadState(
                    lastTweetID: tweetID,
                    startedAt: now,
                    hashtagKey: hashtagKey
                ),
                for: screenName
            )
        } else if decision.clearState {
            model.setTwitterReplyThreadState(nil, for: screenName)
        }
    }

    private func postToBluesky(
        client: APIClient,
        handle: String?,
        text: String,
        images: [TweetImage],
        hashtagKey: String
    ) async -> PostOutcome? {
        guard let handle else { return nil }

        let state = model.blueskyReplyThreadState(for: handle)
        let now = Date()
        let decision = TweetReplyThreadRules.decide(
            mode: model.settings.blueskyReplyThreadMode,
            stateHashtagKey: state?.hashtagKey,
            stateStartedAt: state?.startedAt,
            currentHashtagKey: hashtagKey,
            now: now
        )

        do {
            let result = try await client.sendBlueskyPost(
                handle: handle,
                text: text,
                images: images,
                replyTo: decision.sendAsReply ? state?.replyReference : nil
            )
            guard result.isSuccess,
                  let postURI = result.postURI,
                  let postCID = result.postCID else {
                return PostOutcome(
                    source: .bluesky,
                    message: result.detail,
                    isError: true
                )
            }
            applyBlueskyReplyState(
                decision: decision,
                handle: handle,
                postURI: postURI,
                postCID: postCID,
                hashtagKey: hashtagKey,
                now: now
            )
            return PostOutcome(
                source: .bluesky,
                message: result.detail,
                isError: false,
                postURI: postURI,
                postCID: postCID
            )
        } catch {
            return PostOutcome(
                source: .bluesky,
                message: "Bluesky へのポストに失敗しました。(\(ErrorText.message(for: error)))",
                isError: true
            )
        }
    }

    private func applyBlueskyReplyState(
        decision: TweetReplyThreadDecision,
        handle: String,
        postURI: String,
        postCID: String,
        hashtagKey: String,
        now: Date
    ) {
        if decision.sendAsReply, var state = model.blueskyReplyThreadState(for: handle) {
            state.parentURI = postURI
            state.parentCID = postCID
            model.setBlueskyReplyThreadState(state, for: handle)
        } else if decision.resetStateAfter {
            model.setBlueskyReplyThreadState(
                BlueskyReplyThreadState(
                    rootURI: postURI,
                    rootCID: postCID,
                    parentURI: postURI,
                    parentCID: postCID,
                    startedAt: now,
                    hashtagKey: hashtagKey
                ),
                for: handle
            )
        } else if decision.clearState {
            model.setBlueskyReplyThreadState(nil, for: handle)
        }
    }

    private func showPostOutcome(_ outcomes: [PostOutcome]) {
        guard !outcomes.isEmpty else { return }

        if outcomes.count == 1 {
            let outcome = outcomes[0]
            showNotice(
                message: outcome.isError
                    ? outcome.message
                    : (outcome.source == .twitter
                        ? "Twitter にツイートしました。"
                        : "Bluesky にポストしました。"),
                isError: outcome.isError
            )
            return
        }

        let twitter = outcomes.first { $0.source == .twitter }
        let bluesky = outcomes.first { $0.source == .bluesky }
        let twitterFailed = twitter?.isError ?? true
        let blueskyFailed = bluesky?.isError ?? true
        if !twitterFailed, !blueskyFailed {
            showNotice(message: "Twitter と Bluesky に同時ツイートしました。", isError: false)
        } else if twitterFailed, !blueskyFailed {
            showNotice(
                message: "Bluesky にポストしました。Twitter へのツイートは失敗しました。(\(twitter?.message ?? ""))",
                isError: true
            )
        } else if !twitterFailed, blueskyFailed {
            showNotice(
                message: "Twitter にツイートしました。Bluesky へのポストは失敗しました。(\(bluesky?.message ?? ""))",
                isError: true
            )
        } else {
            let details = outcomes.map(\.message).joined(separator: " / ")
            showNotice(
                message: "Twitter と Bluesky へのツイートに失敗しました。(\(details))",
                isError: true
            )
        }
    }

    private func showNotice(message: String, isError: Bool) {
        notice = message
        noticeIsError = isError
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Timeline

    /// Loads the home timeline of the selected account (first page).
    func loadTimeline() async {
        guard let client = model.client, let item = selectedItem else { return }
        guard !timelineFeed.isLoading else { return }
        timelineFeed.isLoading = true
        timelineFeed.errorMessage = nil
        defer { timelineFeed.isLoading = false }
        timelineFeed.tweets = [:]
        timelineFeed.gaps = []
        timelineFeed.coverage = .empty
        timelineFeed.newerCursor = nil
        timelineFeed.items = []

        async let twitterTask = Self.fetchTwitterPage(
            client: client,
            screenName: item.twitter?.screenName,
            query: nil,
            cursorID: nil,
            cursorType: .top
        )
        async let blueskyTask = Self.fetchBlueskyPage(
            client: client,
            handle: item.bluesky?.handle,
            query: nil,
            cursorID: nil
        )
        let (twitterResult, blueskyResult) = await (twitterTask, blueskyTask)

        var feed = timelineFeed
        applyPage(&feed, source: .twitter, result: twitterResult, isInitial: true)
        applyPage(&feed, source: .bluesky, result: blueskyResult, isInitial: true)
        timelineFeed = feed
        await catchUpBluesky(feed: .timeline)
    }

    /// Loads the first page of the search results for the search query.
    func search() async {
        guard let client = model.client, let item = selectedItem else { return }
        let query = normalizedSearchQuery
        guard !query.isEmpty else {
            showNotice(message: "検索キーワードを入力してください。", isError: true)
            return
        }
        guard !searchFeed.isLoading else { return }
        searchFeed.isLoading = true
        searchFeed.errorMessage = nil
        defer { searchFeed.isLoading = false }
        searchFeed.tweets = [:]
        searchFeed.gaps = []
        searchFeed.coverage = .empty
        searchFeed.newerCursor = nil
        searchFeed.items = []

        async let twitterTask = Self.fetchTwitterPage(
            client: client,
            screenName: item.twitter?.screenName,
            query: query,
            cursorID: nil,
            cursorType: .top
        )
        async let blueskyTask = Self.fetchBlueskyPage(
            client: client,
            handle: item.bluesky?.handle,
            query: query,
            cursorID: nil
        )
        let (twitterResult, blueskyResult) = await (twitterTask, blueskyTask)

        var feed = searchFeed
        applyPage(&feed, source: .twitter, result: twitterResult, isInitial: true)
        applyPage(&feed, source: .bluesky, result: blueskyResult, isInitial: true)
        searchFeed = feed
        await catchUpBluesky(feed: .search)
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fills the search field with the watched channel's hashtag when it is
    /// still empty, then searches.
    func ensureSearchQuery() async {
        if searchQuery.isEmpty {
            searchQuery = autoChannelHashtag ?? ""
        }
        if !normalizedSearchQuery.isEmpty, !searchFeed.hasLoaded {
            await search()
        }
    }

    private func catchUpBluesky(feed kind: FeedKind) async {
        guard let client = model.client, let handle = selectedItem?.bluesky?.handle else { return }
        let query = kind == .search ? normalizedSearchQuery : nil

        for _ in 0..<Self.maxBlueskyCatchUpPages {
            var feed = kind == .timeline ? timelineFeed : searchFeed
            guard TweetTimelineMerge.shouldFetchBlueskyForDisplayLowerBound(
                coverage: feed.coverage,
                accountKind: accountKind
            ), let cursorID = feed.coverage.bluesky.olderCursor else {
                return
            }
            guard let result = await Self.fetchBlueskyPage(
                client: client,
                handle: handle,
                query: query,
                cursorID: cursorID
            ) else {
                return
            }
            applyPage(&feed, source: .bluesky, result: result, isInitial: false)
            if kind == .timeline {
                timelineFeed = feed
            } else {
                searchFeed = feed
            }
        }
    }

    /// Continues a feed from a load-more row.
    func loadMore(feed kind: FeedKind, item: LoadMoreItem) async {
        guard let client = model.client, let account = selectedItem else { return }
        var feed = kind == .timeline ? timelineFeed : searchFeed
        guard !feed.isLoading else { return }

        let targets = TweetTimelineMerge.decideLoadMoreTargets(
            item: item,
            coverage: feed.coverage,
            accountKind: accountKind
        )
        guard targets.shouldFetchTwitter || targets.shouldFetchBluesky else { return }

        feed.isLoading = true
        if kind == .timeline { timelineFeed = feed } else { searchFeed = feed }
        defer {
            if kind == .timeline {
                timelineFeed.isLoading = false
            } else {
                searchFeed.isLoading = false
            }
        }

        let query = kind == .search ? normalizedSearchQuery : nil
        async let twitterTask = Self.fetchTwitterPage(
            client: client,
            screenName: targets.shouldFetchTwitter ? account.twitter?.screenName : nil,
            query: query,
            cursorID: targets.twitterCursorID,
            cursorType: TwitterTimelineCursorType.forTimelineCursor(
                targets.twitterCursorType ?? .older
            )
        )
        async let blueskyTask = Self.fetchBlueskyPage(
            client: client,
            handle: targets.shouldFetchBluesky ? account.bluesky?.handle : nil,
            query: query,
            cursorID: targets.blueskyCursorID
        )
        let (twitterResult, blueskyResult) = await (twitterTask, blueskyTask)

        feed = kind == .timeline ? timelineFeed : searchFeed
        applyPage(
            &feed,
            source: .twitter,
            result: twitterResult,
            isInitial: false,
            shouldPreserveOlderState: targets.consumedTwitterGapID != nil
        )
        applyPage(&feed, source: .bluesky, result: blueskyResult, isInitial: false)
        feed.gaps = TweetTimelineMerge.removingGap(feed.gaps, id: targets.consumedTwitterGapID)
        rebuild(&feed)
        if kind == .timeline { timelineFeed = feed } else { searchFeed = feed }

        if kind == .timeline, item.gapID == nil {
            await catchUpBluesky(feed: .timeline)
        }
    }

    private func applyPage(
        _ feed: inout FeedState,
        source: TimelineSource,
        result: TimelineTweetsResult?,
        isInitial: Bool,
        shouldPreserveOlderState: Bool = false
    ) {
        guard let result else { return }
        guard result.isSuccess else {
            // A rate-limited (is_success = false) Twitter response is reported
            // but the existing content and cursors are kept.
            feed.errorMessage = result.detail
            return
        }
        guard TweetTimelineMerge.isCursorConsumed(result) else {
            feed.errorMessage = result.detail
            return
        }

        let existing = Set(feed.tweets.keys)
        let unique = TweetTimelineMerge.filterDuplicates(
            result.tweets,
            existingIdentityKeys: existing
        )
        for tweet in unique {
            feed.tweets[tweet.identityKey] = tweet
        }

        let classified = TweetTimelineMerge.classifyTimelineCursors(
            source: source,
            result: result,
            pageTweets: result.tweets
        )
        feed.gaps = TweetTimelineMerge.appendGaps(feed.gaps, new: classified.twitterGaps)

        switch source {
        case .twitter:
            feed.coverage.twitter = TweetTimelineMerge.updateCoverage(
                feed.coverage.twitter,
                result: result,
                pageTweets: result.tweets,
                shouldPreserveOlderState: shouldPreserveOlderState,
                shouldKeepOlderUninitializedWhenMissing: isInitial
            )
            if let newer = result.newerCursorID {
                feed.newerCursor = newer
            }
        case .bluesky:
            feed.coverage.bluesky = TweetTimelineMerge.updateCoverage(
                feed.coverage.bluesky,
                result: result,
                pageTweets: result.tweets
            )
        }

        feed.hasLoaded = true
        rebuild(&feed)
    }

    private func rebuild(_ feed: inout FeedState) {
        feed.items = TweetTimelineMerge.buildItems(
            tweets: Array(feed.tweets.values),
            gaps: feed.gaps,
            coverage: feed.coverage,
            accountKind: accountKind
        )
    }

    // MARK: - Reactions

    func toggleRetweet(_ tweet: Tweet) async {
        await react(tweet: tweet, isRetweet: true)
    }

    func toggleFavorite(_ tweet: Tweet) async {
        await react(tweet: tweet, isRetweet: false)
    }

    private func react(tweet: Tweet, isRetweet: Bool) async {
        guard let client = model.client, let account = selectedItem else { return }
        let target = tweet.displayedTweet
        let active = isRetweet ? target.retweeted : target.favorited

        let updated: Tweet
        do {
            switch target.source {
            case .bluesky:
                guard let handle = account.bluesky?.handle else {
                    showNotice(
                        message: "Bluesky 投稿を操作するには、Bluesky アカウントまたは紐付けアカウントを選択してください。",
                        isError: true
                    )
                    return
                }
                let result: TwitterAPIResult
                if isRetweet {
                    result = active
                        ? try await client.cancelRepost(handle: handle, postID: target.id)
                        : try await client.repost(handle: handle, postID: target.id)
                } else {
                    result = active
                        ? try await client.cancelLikePost(handle: handle, postID: target.id)
                        : try await client.likePost(handle: handle, postID: target.id)
                }
                guard result.isSuccess else {
                    showNotice(message: result.detail, isError: true)
                    return
                }
            case .twitter:
                guard let screenName = account.twitter?.screenName else {
                    showNotice(
                        message: "Twitter 投稿を操作するには、Twitter アカウントまたは紐付けアカウントを選択してください。",
                        isError: true
                    )
                    return
                }
                let result: TwitterAPIResult
                if isRetweet {
                    result = active
                        ? try await client.cancelRetweet(screenName: screenName, tweetID: target.id)
                        : try await client.retweet(screenName: screenName, tweetID: target.id)
                } else {
                    result = active
                        ? try await client.cancelFavorite(screenName: screenName, tweetID: target.id)
                        : try await client.favorite(screenName: screenName, tweetID: target.id)
                }
                guard result.isSuccess else {
                    showNotice(message: result.detail, isError: true)
                    return
                }
            }

            updated = isRetweet
                ? target.replacing(
                    retweeted: !active,
                    retweetCount: max(target.retweetCount + (active ? -1 : 1), 0)
                )
                : target.replacing(
                    favorited: !active,
                    favoriteCount: max(target.favoriteCount + (active ? -1 : 1), 0)
                )
        } catch {
            showNotice(message: ErrorText.message(for: error), isError: true)
            return
        }

        replace(tweet: target, with: updated)
    }

    /// Replaces a tweet (or the original of a retweet row) in both feeds.
    private func replace(tweet: Tweet, with updated: Tweet) {
        for kind in [FeedKind.timeline, .search] {
            var feed = kind == .timeline ? timelineFeed : searchFeed
            var didChange = false
            for (key, current) in Array(feed.tweets) {
                if current.source == tweet.source, current.id == tweet.id {
                    feed.tweets[key] = updated
                    didChange = true
                } else if let inner = current.retweetedTweet,
                          inner.source == tweet.source,
                          inner.id == tweet.id {
                    feed.tweets[key] = current.withRetweetedTweet(updated)
                    didChange = true
                }
            }
            guard didChange else { continue }
            rebuild(&feed)
            if kind == .timeline { timelineFeed = feed } else { searchFeed = feed }
        }
    }

    // MARK: - API helpers

    private nonisolated static func fetchTwitterPage(
        client: APIClient,
        screenName: String?,
        query: String?,
        cursorID: String?,
        cursorType: TwitterTimelineCursorType
    ) async -> TimelineTweetsResult? {
        guard let screenName else { return nil }
        if let query {
            return try? await client.twitterSearch(
                screenName: screenName,
                query: query,
                cursorID: cursorID,
                cursorType: cursorType
            )
        }
        return try? await client.twitterTimeline(
            screenName: screenName,
            cursorID: cursorID,
            cursorType: cursorType
        )
    }

    private nonisolated static func fetchBlueskyPage(
        client: APIClient,
        handle: String?,
        query: String?,
        cursorID: String?
    ) async -> TimelineTweetsResult? {
        guard let handle else { return nil }
        if let query {
            return try? await client.blueskySearch(
                handle: handle,
                query: query,
                cursorID: cursorID
            )
        }
        return try? await client.blueskyTimeline(handle: handle, cursorID: cursorID)
    }
}
