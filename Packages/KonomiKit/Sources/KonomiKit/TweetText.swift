import Foundation

// MARK: - Hashtag position

/// Where the composer puts the hashtags in the posted text
/// (tweet_hashtag_position).
public enum TweetHashtagPosition: String, Codable, CaseIterable, Sendable, Hashable {
    case prepend = "Prepend"
    case append = "Append"
    case prependWithLineBreak = "PrependWithLineBreak"
    case appendWithLineBreak = "AppendWithLineBreak"

    public var displayName: String {
        switch self {
        case .prepend: return "本文の前に追加"
        case .append: return "本文の後に追加"
        case .prependWithLineBreak: return "本文の前に追加して改行"
        case .appendWithLineBreak: return "本文の後に改行して追加"
        }
    }
}

// MARK: - Hashtag rules

/// Hashtag handling of the watch screen's Twitter tab (the web client's
/// formatHashtag, ChannelUtils.getChannelHashtag and TweetUtils hashtag keys).
public enum TweetHashtagRules {

    /// One entry of the channel name to hashtag table. A nil hashtag marks a
    /// name that deliberately gets no tag (TBSチャンネル is not TBS).
    private struct ChannelHashtagEntry {
        let prefix: String
        let hashtag: String?

        init(_ prefix: String, _ hashtag: String?) {
            self.prefix = prefix
            self.hashtag = hashtag
        }
    }

    /// The web client's channel_list, in its declaration order: the first
    /// prefix match wins, so longer names must come before their prefixes.
    private static let channelHashtags: [ChannelHashtagEntry] = [
        // NHK
        .init("NHK総合", "#nhk"),
        .init("NHKEテレ", "#etv"),
        // 民放
        .init("HBC", "#hbc"),
        .init("札幌テレビ", "#stv"),
        .init("HTB", "#htb"),
        .init("TVh", "#tvh"),
        .init("北海道文化放送", "#uhb"),
        .init("RAB青森放送", "#rab"),
        .init("青森朝日放送", "#aba"),
        .init("ATV青森テレビ", "#atv"),
        .init("テレビ岩手", "#tvi"),
        .init("岩手朝日テレビ", "#iat"),
        .init("IBCテレビ", "#ibc"),
        .init("めんこいテレビ", "#mit"),
        .init("TBCテレビ", "#tbc"),
        .init("ミヤギテレビ", "#mmt"),
        .init("東日本放送", "#khb"),
        .init("仙台放送", "#oxtv"),
        .init("ABS秋田放送", "#abs"),
        .init("秋田朝日放送", "#aab"),
        .init("AKT秋田テレビ", "#akt"),
        .init("山形放送", "#ybc"),
        .init("山形テレビ", "#yts"),
        .init("TUY", "#tuy"),
        .init("さくらんぼテレビ", "#say"),
        .init("福島中央テレビ", "#fct"),
        .init("KFB福島放送", "#kfb"),
        .init("テレビユー福島", "#tuf"),
        .init("FTV福島テレビ", "#ftv"),
        .init("TeNY", "#TeNY"),
        .init("新潟テレビ21", "#uxtv"),
        .init("BSN", "#bsn"),
        .init("NST", "#nst"),
        .init("KNBテレビ", "#knb"),
        .init("チューリップテレビ", "#tut"),
        .init("富山テレビ放送", "#toyamatv"),
        .init("テレビ金沢", "#tv_kanazawa"),
        .init("HAB", "#hab"),
        .init("MRO", "#mro"),
        .init("石川テレビ", "#ishikawatv"),
        .init("福井放送", "#fbc"),
        .init("福井テレビ", "#fukuitv"),
        .init("山梨放送", "#ybs"),
        .init("UTYテレビ山梨", "#uty"),
        .init("テレビ信州", "#tsb"),
        .init("長野朝日放送", "#abn"),
        .init("SBC信越放送", "#sbc"),
        .init("長野放送", "#nbs"),
        .init("Daiichi-TV", "#sdt"),
        .init("静岡朝日テレビ", "#satv"),
        .init("SBS", "#sbs"),
        .init("テレビ静岡", "#sut"),
        .init("三重テレビ", "#mietv"),
        .init("ぎふチャン", "#gifuchan"),
        .init("BBCびわ湖放送", "#BBC_biwako"),
        .init("奈良テレビ", "#tvn"),
        .init("WTV", "#telewaka"),
        .init("RNC西日本テレビ", "#rnc"),
        .init("瀬戸内海放送", "#ksb"),
        .init("RSKテレビ", "#rsk"),
        .init("TSCテレビせとうち", "#tvsetouchi"),
        .init("OHK", "#ohk"),
        .init("RCCテレビ", "#rcc"),
        .init("広島テレビ", "#htv"),
        .init("広島ホームテレビ", "#hometv"),
        .init("テレビ新広島", "#tss"),
        .init("日本海テレビ", "#nkt"),
        .init("BSSテレビ", "#bss"),
        .init("さんいん中央テレビ", "#tsk"),
        .init("tysテレビ山口", "#tys"),
        .init("山口放送", "#kry"),
        .init("yab山口朝日", "#yab"),
        .init("四国放送", "#jrt"),
        .init("高知放送", "#rkc"),
        .init("テレビ高知", "#kutv"),
        .init("高知さんさんテレビ", "#kss"),
        .init("南海放送", "#rnb"),
        .init("愛媛朝日テレビ", "#eat"),
        .init("あいテレビ", "#itv"),
        .init("テレビ愛媛", "#ebc"),
        .init("KBCテレビ", "#kbc"),
        .init("RKB毎日放送", "#rkb"),
        .init("FBS福岡放送", "#fbs"),
        .init("TVQ九州放送", "#tvq"),
        .init("テレビ西日本", "#tnc"),
        .init("STSサガテレビ", "#sagatv"),
        .init("NBC長崎放送", "#nbc"),
        .init("長崎国際テレビ", "#nib"),
        .init("NCC長崎文化放送", "#ncc"),
        .init("テレビ長崎", "#ktn"),
        .init("RKK熊本放送", "#rkk"),
        .init("くまもと県民", "#kkt"),
        .init("KAB熊本朝日放送", "#kab"),
        .init("テレビ熊本", "#tku"),
        .init("OBS大分放送", "#obs"),
        .init("TOSテレビ大分", "#tos"),
        .init("OAB大分朝日放送", "#oab"),
        .init("MRT宮崎放送", "#mrt"),
        .init("テレビ宮崎", "#umk"),
        .init("MBC南日本放送", "#mbc"),
        .init("鹿児島讀賣テレビ", "#kyt"),
        .init("KKB鹿児島放送", "#kkb"),
        .init("鹿児島テレビ放送", "#kts"),
        .init("RBCテレビ", "#rbc"),
        .init("琉球朝日放送", "#qab"),
        .init("沖縄テレビ", "#otv"),
        // 三大首都圏
        .init("日テレ", "#ntv"),
        .init("読売テレビ", "#ytv"),
        .init("中京テレビ", "#chukyotv"),
        .init("テレビ朝日", "#tvasahi"),
        .init("ABCテレビ", "#abc"),
        .init("メ~テレ", "#nagoyatv"),
        .init("メ〜テレ", "#nagoyatv"),
        .init("TBSチャンネル", nil),
        .init("TBS", "#tbs"),
        .init("MBS", "#mbs"),
        .init("CBC", "#cbc"),
        .init("テレビ東京", "#tvtokyo"),
        .init("テレ東", "#tvtokyo"),
        .init("テレビ大阪", "#tvo"),
        .init("テレビ愛知", "#tva"),
        .init("フジテレビ", "#fujitv"),
        .init("関西テレビ", "#kantele"),
        .init("東海テレビ", "#tokaitv"),
        // 独立局
        .init("TOKYO MX", "#tokyomx"),
        .init("tvk", "#tvk"),
        .init("チバテレ", "#chibatv"),
        .init("テレ玉", "#teletama"),
        .init("群馬テレビ", "#gtv"),
        .init("とちぎテレビ", "#tochitere"),
        .init("とちテレ", "#tochitere"),
        .init("サンテレビ", "#suntv"),
        .init("KBS京都", "#kbs"),
        // BS・CS
        .init("NHKBS1", "#nhkbs1"),
        .init("NHKBSプレミアム", "#nhkbsp"),
        .init("NHKBS", "#nhkbs"),
        .init("BS日テレ", "#bsntv"),
        .init("BS朝日", "#bsasahi"),
        .init("BS-TBS", "#bstbs"),
        .init("BSテレ東", "#bstvtokyo"),
        .init("BSフジ", "#bsfuji"),
        .init("BS10スターチャンネル", "#bs10スターチャンネル"),
        .init("BS10", "#bs10"),
        .init("BS11", "#bs11"),
        .init("BS12", "#bs12"),
        .init("BS松竹東急", "#bs260ch"),
        .init("BSJapanext", "#bsjapanext"),
        .init("BSよしもと", "#bsyoshimoto"),
        .init("AT-X", "#at_x"),
    ]

    /// The station hashtag of a channel (ChannelUtils.getChannelHashtag).
    ///
    /// A prefix match, in declaration order; nil when the channel has no tag.
    public static func channelHashtag(for channelName: String) -> String? {
        guard !channelName.isEmpty else { return nil }
        return channelHashtags.first { channelName.hasPrefix($0.prefix) }?.hashtag
    }

    /// Normalises a hashtag field (the web client's formatHashtag): unifies
    /// the hash and space variants, collapses duplicates, prefixes a "#" to
    /// every entry and optionally appends the station hashtag of the channel
    /// being watched.
    ///
    /// - Parameters:
    ///   - raw: The field's text.
    ///   - appendingChannelHashtag: Station hashtag of the watched channel, or
    ///     nil (video playback, or the setting turned off, or a value from the
    ///     saved hashtag list, which the web client does not auto-append to).
    public static func format(_ raw: String, appendingChannelHashtag channelHashtag: String? = nil) -> String {
        var tags = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "＃", with: "#")
            .replacingOccurrences(of: "#{2,}", with: "#", options: .regularExpression)
            .replacingOccurrences(of: "　", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        for index in tags.indices where !tags[index].hasPrefix("#") {
            tags[index] = "#" + tags[index]
        }
        if let channelHashtag, !channelHashtag.isEmpty, !tags.contains(channelHashtag) {
            tags.append(channelHashtag)
        }
        return tags.joined(separator: " ")
    }

    /// Removes a station hashtag from the field, used when the watched channel
    /// changes so the old station's tag does not stay behind.
    public static func removingChannelHashtag(_ field: String, channelHashtag: String?) -> String {
        guard let channelHashtag, !channelHashtag.isEmpty else { return field }
        return field.replacingOccurrences(of: channelHashtag, with: "")
    }

    /// The hashtag field after the watched channel changed
    /// (Panel/Twitter.vue's channel watcher): the old station tag is removed,
    /// the field is cleared when the setting asks for it, and the new station
    /// tag is added when automatic addition is on.
    ///
    /// - Parameters:
    ///   - oldChannelHashtag: Station hashtag of the channel that was watched.
    ///   - newChannelHashtag: Station hashtag that is added automatically, nil
    ///     when automatic addition is off (or playback is a recording).
    public static func fieldAfterChannelSwitch(
        _ field: String,
        oldChannelHashtag: String?,
        newChannelHashtag: String?,
        resetOnProgramSwitch: Bool
    ) -> String {
        var value = removingChannelHashtag(field, channelHashtag: oldChannelHashtag)
        if resetOnProgramSwitch {
            value = ""
        }
        return format(value, appendingChannelHashtag: newChannelHashtag)
    }

    /// The hashtag field after the program of the same channel changed.
    ///
    /// Only the reset setting matters: the station tag is added again when the
    /// field is cleared.
    public static func fieldAfterProgramSwitch(
        _ field: String,
        resetOnProgramSwitch: Bool,
        autoChannelHashtag: String?
    ) -> String {
        guard resetOnProgramSwitch else { return field }
        return format("", appendingChannelHashtag: autoChannelHashtag)
    }

    /// The individual hashtags of a normalised field.
    public static func hashtags(in field: String) -> [String] {
        field.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// Case and order insensitive key of a hashtag set, used as the reply tree
    /// boundary (TweetUtils.normalizeHashtagKey).
    public static func normalizedKey(_ hashtags: [String]) -> String {
        var seen: Set<String> = []
        var keys: [String] = []
        for hashtag in hashtags {
            var value = hashtag
            if value.hasPrefix("#") {
                value.removeFirst()
            }
            value = value.lowercased()
            if seen.insert(value).inserted {
                keys.append(value)
            }
        }
        return keys.sorted().joined(separator: ",")
    }
}

// MARK: - Composer

/// Builds the posted text from the composer's body and hashtag fields.
public enum TweetComposer {

    /// The text that is actually posted (the web client's sendTweet).
    public static func compose(
        text: String,
        hashtags: String,
        position: TweetHashtagPosition
    ) -> String {
        guard !hashtags.isEmpty else { return text }
        switch position {
        case .prepend:
            return hashtags + " " + text
        case .append:
            return text + " " + hashtags
        case .prependWithLineBreak:
            return hashtags + "\n" + text
        case .appendWithLineBreak:
            return text + "\n" + hashtags
        }
    }
}

// MARK: - Character counting

/// Character counting rules of the composer.
///
/// The web client's meter subtracts the number of user-perceived characters
/// (code points in JavaScript) from 140. The posted text additionally has to
/// fit Twitter's weighted length and Bluesky's 300 grapheme limit.
public enum TweetTextLength {
    /// Limit shown by the Twitter composer.
    public static let twitterCounterLimit = 140
    /// Bluesky's post limit (graphemes).
    public static let blueskyLimit = 300
    /// Weight of every URL under Twitter's weighted length.
    public static let twitterURLWeight = 23

    /// Remaining characters shown by the web client's Twitter meter.
    public static func twitterRemaining(hashtags: String, text: String) -> Int {
        twitterCounterLimit - characterCount(hashtags) - characterCount(text)
    }

    /// Number of user-perceived characters (Swift grapheme clusters, matching
    /// the web client's spread-operator count for the text it receives).
    public static func characterCount(_ value: String) -> Int {
        value.count
    }

    /// Twitter's weighted length (twitter-text v3): every URL counts as 23,
    /// CJK and emoji count as two, everything else as one.
    public static func twitterWeightedLength(_ value: String) -> Int {
        let (withoutURLs, urlCount) = strippingURLs(value)
        var total = urlCount * twitterURLWeight
        for scalar in withoutURLs.unicodeScalars {
            total += twitterScalarWeight(scalar)
        }
        return total
    }

    public static func isWithinTwitterLimit(_ value: String) -> Bool {
        twitterWeightedLength(value) <= 280
    }

    /// Bluesky counts graphemes and allows 300.
    public static func blueskyLength(_ value: String) -> Int {
        value.count
    }

    public static func isWithinBlueskyLimit(_ value: String) -> Bool {
        blueskyLength(value) <= blueskyLimit
    }

    /// Whether the send button is disabled for the given fields (the web
    /// client's is_tweet_button_disabled).
    public static func isSendDisabled(
        hashtags: String,
        text: String,
        attachmentCount: Int
    ) -> Bool {
        let remaining = twitterRemaining(hashtags: hashtags, text: text)
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return remaining < 0 || ((!hasText || remaining == twitterCounterLimit) && attachmentCount == 0)
    }

    // MARK: Internals

    /// Replaces URLs with the empty string and returns how many were found.
    private static func strippingURLs(_ value: String) -> (String, Int) {
        var result = ""
        var rest = Substring(value)
        var count = 0
        while let range = rest.range(
            of: "https?://[^\\s]+",
            options: .regularExpression
        ) {
            result += rest[rest.startIndex..<range.lowerBound]
            count += 1
            rest = rest[range.upperBound...]
        }
        result += rest
        return (result, count)
    }

    /// twitter-text's weighted scalar rules.
    private static func twitterScalarWeight(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        switch value {
        case 0x0000...0x10FF,
             0x2000...0x200D,
             0x2010...0x201F,
             0x2032...0x2037:
            return 1
        case 0x1100...0x115F,
             0x2E80...0x303E,
             0x3041...0x33FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xA000...0xA4CF,
             0xA960...0xA97F,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x1F000...0x1FAFF,
             0x2600...0x27BF:
            return 2
        default:
            return 2
        }
    }
}

// MARK: - Panel tabs

/// Sub tabs of the watch screen's Twitter panel (twitter_active_tab).
public enum TwitterPanelTab: String, Codable, CaseIterable, Sendable, Hashable {
    case search = "Search"
    case timeline = "Timeline"
    case capture = "Capture"

    public var displayName: String {
        switch self {
        case .search: return "検索"
        case .timeline: return "タイムライン"
        case .capture: return "キャプチャ"
        }
    }
}

/// Where the attachment step draws the program title onto a capture
/// (tweet_capture_watermark_position).
public enum TweetCaptureWatermarkPosition: String, Codable, CaseIterable, Sendable, Hashable {
    case none = "None"
    case topLeft = "TopLeft"
    case topRight = "TopRight"
    case bottomLeft = "BottomLeft"
    case bottomRight = "BottomRight"

    public var displayName: String {
        switch self {
        case .none: return "描画しない"
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        }
    }
}

