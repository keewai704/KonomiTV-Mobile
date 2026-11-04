import SwiftUI
import KonomiKit

/// The Search and Timeline sub tabs of the Twitter panel.
///
/// Both show the merged Twitter + Bluesky feed: tweets newest first, Twitter's
/// middle gaps and the tail as load-more rows.
struct TwitterFeedView: View {
    let model: AppModel
    @Bindable var session: TwitterSession
    let kind: FeedKind
    @Binding var query: String
    @Binding var previewImage: PreviewImage?

    private var feed: FeedState {
        kind == .timeline ? session.timelineFeed : session.searchFeed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let message = feed.errorMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(kind == .timeline ? "twitter.timeline.status" : "twitter.search.status")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(feed.items) { item in
                        switch item {
                        case .tweet(let tweet):
                            TwitterTweetRow(
                                session: session,
                                tweet: tweet,
                                previewImage: $previewImage
                            )
                            Divider()
                        case .twitterGap, .tail:
                            loadMoreRow(item)
                        }
                    }

                    if feed.items.isEmpty, !feed.isLoading {
                        Text(kind == .timeline
                            ? "ツイートがありません"
                            : "検索結果がありません")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                            .accessibilityIdentifier(kind == .timeline
                                ? "twitter.timeline.empty"
                                : "twitter.search.empty")
                    }

                    if feed.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 420)
        }
        .task {
            switch kind {
            case .search:
                await session.ensureSearchQuery()
            case .timeline:
                if !session.timelineFeed.hasLoaded {
                    await session.loadTimeline()
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        switch kind {
        case .search:
            HStack(spacing: 8) {
                TextField("検索キーワード", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await session.search() }
                    }
                    .accessibilityIdentifier("twitter.search.field")
                    .accessibilityLabel("検索キーワード")

                Button {
                    Task { await session.search() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(feed.isLoading || query.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("twitter.search.refresh")
                .accessibilityLabel("検索結果を更新")
            }
            // Without a container the identifier replaces the field's and
            // the button's own.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("twitter.search")
        case .timeline:
            HStack(spacing: 8) {
                Text("タイムライン")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("twitter.timeline")
                Spacer(minLength: 0)
                Button {
                    Task { await session.loadTimeline() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(feed.isLoading)
                .accessibilityIdentifier("twitter.timeline.refresh")
                .accessibilityLabel("タイムラインを更新")
            }
        }
    }

    // MARK: - Load more

    private func loadMoreRow(_ item: TimelineDisplayItem) -> some View {
        Button {
            guard let loadMore = item.loadMoreItem else { return }
            Task { await session.loadMore(feed: kind, item: loadMore) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                Text("さらに読み込む")
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 6)
        .accessibilityIdentifier("twitter.loadMore.\(item.id)")
    }
}

/// One tweet of a feed (Twitter quote tweets and Bluesky posts included).
struct TwitterTweetRow: View {
    let session: TwitterSession
    let tweet: Tweet
    @Binding var previewImage: PreviewImage?

    private var displayed: Tweet { tweet.displayedTweet }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tweet.retweetedTweet != nil {
                Label(
                    "\(tweet.user.name) さんがリツイートしました",
                    systemImage: "arrow.2.squarepath"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("twitter.tweet.\(tweet.id).repostedBy")
            }

            HStack(alignment: .top, spacing: 8) {
                avatar

                VStack(alignment: .leading, spacing: 4) {
                    authorLine
                    textView
                    images
                    quotedTweet
                    actions
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("twitter.tweet.\(tweet.id)")
    }

    private var avatar: some View {
        AsyncImage(url: URL(string: displayed.user.iconURL)) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private var authorLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(displayed.user.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Text("@\(displayed.user.screenName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(Formatters.dateTime(displayed.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var textView: some View {
        Text(TweetTextFormatter.attributed(displayed.text, source: displayed.source))
            .font(.footnote)
            .tint(.accentColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var images: some View {
        let urls = displayed.imageURLs.compactMap { URL(string: $0) }
        if !urls.isEmpty {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 4),
                    count: min(urls.count, 2)
                ),
                spacing: 4
            ) {
                ForEach(urls.indices, id: \.self) { index in
                    Button {
                        previewImage = PreviewImage(
                            id: "\(tweet.id)-\(index)",
                            url: urls[index]
                        )
                    } label: {
                        AsyncImage(url: urls[index]) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Color.secondary.opacity(0.12)
                            }
                        }
                        .frame(height: 90)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("twitter.tweet.\(tweet.id).image.\(index)")
                    .accessibilityLabel("画像 \(index + 1)")
                }
            }
        }
    }

    @ViewBuilder
    private var quotedTweet: some View {
        if let quoted = displayed.quotedTweet {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(quoted.user.name) @\(quoted.user.screenName)")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Text(quoted.text)
                    .font(.caption)
                    .lineLimit(3)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("twitter.tweet.\(tweet.id).quoted")
        }
    }

    private var actions: some View {
        HStack(spacing: 22) {
            Button {
                Task { await session.toggleRetweet(tweet) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.2.squarepath")
                    Text("\(displayed.retweetCount)")
                        .monospacedDigit()
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(displayed.retweeted ? Color.green : Color.secondary)
            .accessibilityIdentifier("twitter.tweet.\(tweet.id).retweet")
            .accessibilityLabel("リツイート")
            .accessibilityValue(displayed.retweeted ? "true" : "false")

            Button {
                Task { await session.toggleFavorite(tweet) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: displayed.favorited ? "heart.fill" : "heart")
                    Text("\(displayed.favoriteCount)")
                        .monospacedDigit()
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(displayed.favorited ? Color.pink : Color.secondary)
            .accessibilityIdentifier("twitter.tweet.\(tweet.id).favorite")
            .accessibilityLabel("いいね")
            .accessibilityValue(displayed.favorited ? "true" : "false")
        }
        .padding(.top, 2)
    }
}

/// Turns tweet text into an attributed string with links to URLs, mentions and
/// hashtags (the web client's formatText).
enum TweetTextFormatter {
    static func attributed(_ text: String, source: TweetSource) -> AttributedString {
        var result = AttributedString(text)
        apply(pattern: "https?://[^\\s]+", to: &result, in: text) { match in
            URL(string: match)
        }
        let mentionPattern = source == .bluesky
            ? "@([a-zA-Z0-9][a-zA-Z0-9.-]*\\.[a-zA-Z][a-zA-Z0-9.-]*)"
            : "@(\\w+)"
        apply(pattern: mentionPattern, to: &result, in: text) { match in
            let name = match.dropFirst()
            if source == .bluesky {
                return URL(string: "https://bsky.app/profile/\(name)")
            }
            return URL(string: "https://x.com/\(name)")
        }
        apply(
            pattern: "[#＃]([\\w\\p{Script=Hiragana}\\p{Script=Katakana}\\p{Script=Han}ー]+)",
            to: &result,
            in: text
        ) { match in
            let tag = match.dropFirst()
            let encoded = tag.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? String(tag)
            if source == .bluesky {
                return URL(string: "https://bsky.app/hashtag/\(encoded)")
            }
            return URL(string: "https://x.com/hashtag/\(encoded)")
        }
        return result
    }

    private static func apply(
        pattern: String,
        to attributed: inout AttributedString,
        in text: String,
        url: (String) -> URL?
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(text.startIndex..., in: text)
        for match in expression.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text),
                  let lower = AttributedString.Index(matchRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(matchRange.upperBound, within: attributed),
                  let link = url(String(text[matchRange])) else {
                continue
            }
            attributed[lower..<upper].link = link
        }
    }
}
