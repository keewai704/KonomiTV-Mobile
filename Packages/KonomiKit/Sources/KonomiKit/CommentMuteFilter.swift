import Foundation

// MARK: - Muted keywords

/// One entry of the web client's `muted_comment_keywords` list.
public struct MutedCommentKeyword: Codable, Sendable, Hashable {
    /// How the pattern is compared with the comment.
    public enum MatchType: String, Codable, Sendable, Hashable, CaseIterable {
        /// Substring match (`String.contains`).
        case partial
        /// Prefix match.
        case forward
        /// Suffix match.
        case backward
        /// Whole comment match.
        case exact
        /// Regular expression (ICU syntax; an invalid pattern never matches).
        case regex
    }

    public var match: MatchType
    public var pattern: String

    public init(match: MatchType = .partial, pattern: String = "") {
        self.match = match
        self.pattern = pattern
    }

    private enum CodingKeys: String, CodingKey {
        case match
        case pattern
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        match = MatchType(rawValue: container.lenient(String.self, forKey: .match) ?? "")
            ?? .partial
        pattern = container.lenient(String.self, forKey: .pattern) ?? ""
    }
}

// MARK: - Mute filter

/// Decides whether a comment is hidden, ported from
/// `client/src/utils/CommentUtils.ts` (`isMutedComment`) and the mute settings in
/// `client/src/stores/SettingsStore.ts`.
///
/// The check order matters and is the same as the web client's:
/// user ID → Niconico command comment → fixed → coloured → big → vulgar →
/// abusive → repeated characters → user keywords → spam statistics.
public enum CommentMuteFilter {

    /// The settings the filter needs, so it can be used without a full
    /// `ClientSettings` (and tested with hand written values).
    public struct Options: Sendable, Hashable {
        public var muteVulgarComments: Bool
        public var muteAbusiveDiscriminatoryPrejudicedComments: Bool
        public var muteBigSizeComments: Bool
        public var muteFixedComments: Bool
        public var muteColoredComments: Bool
        public var muteConsecutiveSameCharactersComments: Bool
        /// Normalise full/half width and letter case before matching keywords.
        public var normalizeCommentKeywords: Bool
        public var mutedCommentKeywords: [MutedCommentKeyword]
        public var mutedNiconicoUserIDs: [String]

        public init(
            muteVulgarComments: Bool = true,
            muteAbusiveDiscriminatoryPrejudicedComments: Bool = true,
            muteBigSizeComments: Bool = true,
            muteFixedComments: Bool = false,
            muteColoredComments: Bool = false,
            muteConsecutiveSameCharactersComments: Bool = false,
            normalizeCommentKeywords: Bool = true,
            mutedCommentKeywords: [MutedCommentKeyword] = [],
            mutedNiconicoUserIDs: [String] = []
        ) {
            self.muteVulgarComments = muteVulgarComments
            self.muteAbusiveDiscriminatoryPrejudicedComments =
                muteAbusiveDiscriminatoryPrejudicedComments
            self.muteBigSizeComments = muteBigSizeComments
            self.muteFixedComments = muteFixedComments
            self.muteColoredComments = muteColoredComments
            self.muteConsecutiveSameCharactersComments = muteConsecutiveSameCharactersComments
            self.normalizeCommentKeywords = normalizeCommentKeywords
            self.mutedCommentKeywords = mutedCommentKeywords
            self.mutedNiconicoUserIDs = mutedNiconicoUserIDs
        }

        public init(settings: ClientSettings) {
            self.init(
                muteVulgarComments: settings.muteVulgarComments,
                muteAbusiveDiscriminatoryPrejudicedComments:
                    settings.muteAbusiveDiscriminatoryPrejudicedComments,
                muteBigSizeComments: settings.muteBigSizeComments,
                muteFixedComments: settings.muteFixedComments,
                muteColoredComments: settings.muteColoredComments,
                muteConsecutiveSameCharactersComments:
                    settings.muteConsecutiveSameCharactersComments,
                normalizeCommentKeywords:
                    settings.muteCommentKeywordsNormalizeAlphanumericWidthCase,
                mutedCommentKeywords: settings.mutedCommentKeywords,
                mutedNiconicoUserIDs: settings.mutedNiconicoUserIDs
            )
        }

        /// The web client's defaults with no user keywords.
        public static let webDefaults = Options()
    }

    // MARK: Built-in patterns

    /// 「露骨な表現を含むコメントをミュートする」. Copied verbatim (base64 decoded,
    /// split on the alternation so it can be reviewed) from `CommentUtils.ts`.
    public static let vulgarPattern =
        "\\(i\\)|\\(U\\)|prpr|ｐｒｐｒ|SEX|S〇X|S◯X|S○X|S●X|ＳＥＸ|Ｓ〇Ｘ|Ｓ◯Ｘ|Ｓ○Ｘ|"
        + "Ｓ●Ｘ|アダルト|アソコ|アナゥ|アナル|イカ臭|イく|インポ|うんこ|ウンコ|うんち|ウンチ|エキホ|えちえち|えっち|"
        + "エッチ|えっろ|エッロ|^えろ|えろい|エロ|工口|オカズ|おさわりまん|おしっこ|オシッコ|オッサン|おっぱい|オッパイ|"
        + "オナニー|おなほ|オナホ|おぱい|オパイ|ｵﾊﾟｲ|おまた|オマタ|ｵﾏﾀ|おめこ|オメコ|ｵﾒｺ|おp|おｐ|オフパコ|"
        + "ガチムチ|キメセク|キンタマ|くぱあ|くぱぁ|クリトリス|クンニ|ごくごくごくごく|コンドーム|けつあな|ケツアナ|ケツ穴|"
        + "ザーメン|シコ|しこしこ|シコ|すけすけ|せいえき|せいり|せーり|すぅぅぅ|すううう|セクロス|セックス|セフレ|"
        + "ちっぱい|ちっパイ|チッパイ|ちんこ|ち〇こ|ち◯こ|ち○こ|ち●こ|チンコ|チ〇コ|チ◯コ|チ○コ|チ●コ|ちんぽ|"
        + "ち〇ぽ|ち◯ぽ|ち○ぽ|ち●ぽ|チンポ|チ〇ポ|チ◯ポ|チ○ポ|チ●ポ|ちんちん|チンチン|ちーん|ち〜ん|チ〜ン|"
        + "てぃんてぃん|ティンティン|てぃんぽ|ティンポ|デカい|デカチン|デリヘル|ずるむけ|ズルムケ|なかだし|なか〇し|"
        + "なか◯し|なか○し|なか●し|脱げ|ヌい|ヌか|ヌカ|ヌき|ヌキ|ヌく|ヌク|ヌけ|ヌケ|ヌこ|ヌコ|ぱいもみ|ぱいずり|"
        + "パンティ|パイズリ|パイパン|バイブ|パパ活|ハメ|ピストン|ビッチ|ふう・|ふう…|ふぅ|ﾌｩ|ふくらみ|ふくらんで|"
        + "ぺった|ぺろぺろ|ペロペロ|ﾍﾟﾛﾍﾟﾛ|フェラ|ほうけい|ぼっき|ポルノ|ぼろん|ボロン|ﾎﾞﾛﾝ|ぽろり|ポロリ|"
        + "ﾎﾟﾛﾘ|まーん|ま〜ん|マ〜ン|マンきつ|マンキツ|まんこ|ま〇こ|ま◯こ|ま○こ|ま●こ|マンコ|マ〇コ|マ◯コ|"
        + "マ○コ|マ●コ|まんさん|もっこり|モッコリ|もみもみ|モミモミ|ヤった|ヤって|ヤら|やらせろ|ヤり|ヤリ|ヤリチン|"
        + "ヤリマン|ヤる|ヤれ|ヤろ|ラブホ|ワレメ|愛液|咥|喘|陰核|陰茎|陰唇|淫|隠毛|陰毛|産める|女の子の日|汚っさん|"
        + "貝合|姦|貫通|騎乗位|巨乳|巨根|巨尻|巨チン|巨珍|金玉|月経|後背位|子種|子作り|射精|潮吹|信者|精液|透け|"
        + "性交|精子|正常位|性徴|性的|生理|絶倫|寸止め|素材|抱い|抱か|抱き|抱く|抱け|抱こ|体液|乳首|恥垢|珍棒|"
        + "中だし|中出し|尿|抜い|抜けない|抜ける|抜けれ|排便|犯珍|膨ら|包茎|勃起|膜|摩羅|魔羅|揉ま|揉み|揉む|揉め|"
        + "漫湖|〇～|◯～|○～|●～|〇~|◯~|○~|●~|〇ックス|◯ックス|○ックス|●ックス"

    /// 「ネガティブな表現、差別的な表現、政治的に偏った表現を含むコメントをミュートする」.
    /// Copied verbatim (base64 decoded, split on the alternation so it can be
    /// reviewed) from `CommentUtils.ts`.
    public static let abusiveDiscriminatoryPrejudicedPattern =
        "。|アニプレ|アスペ|あほ|アホ|阿呆|イカれ|いまいち|イマイチ|イラつく|ウジ|ウーヨ|ウヨ|ウヨク|ウヲ|うるせえ|"
        + "ギスギス|ｷﾞｽｷﾞｽ|きったねえ|きったねぇ|きたねえ|きたねぇ|汚ねえ|汚ねぇ|きもい|キモイ|キモい|キ/ム/チ|"
        + "ガイジ|ｶﾞｲｼﾞ|ガイジン|ガキ|カス|キッズ|きちがい|キチガイ|キムチ|きらい|キライ|嫌い|^菌$|クソ|糞|シナ|"
        + "ステマ|つまらな|つまらん|チョッパリ|チョン|千ョン|つまらな|つんぼ|ツンボ|ネトウヨ|にだああ|ニダ|二ダ|ﾆﾀﾞ|"
        + "パーヨ|パヨ|パヨク|ヒドい|ヒドイ|^ぴー$|^ピー$|ぶっさ|ブッサ|ぶさい|ブサイ|ヘイトスピーチ|ホモ|まぬけ|"
        + "メクラ|バカ|パク|ムカつく|荒らし|麻生セメント|右翼|汚物|面白くな|慰安婦|害児|外字|姦国|韓国|韓中|韓日|"
        + "基地外|気狂い|気違い|切った|切って|気持ち悪|臭|屑|工作員|国交断絶|国籍|国に帰れ|国へ帰れ|左翼|殺|頃|頃し|"
        + "頃す|頃せ|^在|在日|在日特権|在特会|参政権|精神異常者|死ね|氏ね|ﾀﾋ|歹匕|歹ヒ|死刑|シケイ|しけい|失速|"
        + "障害|ステマ|大東亜|断交|通名|中韓|朝鮮|徴用工|壺|壷|壼|日韓|日帝|粘着|半島|反日|反民族|馬鹿|発狂|発達|"
        + "朴|売国|微妙|不快|併合|間抜け|ﾑｸﾑｸ|ムクムク|無能|漏ら|漏れ|文句|靖国|野郎"

    /// 「8文字以上同じ文字が連続しているコメントをミュートする」.
    public static let consecutiveSameCharactersPattern = "(.)\\1{7,}"

    /// Niconico operator command comments (`/nicoad`, `/emotion`, …).
    public static let specialCommandPattern = "^/[a-z][a-z0-9_-]*(?:\\s|$)"

    /// Spam statistics comments such as
    /// 「ＮHK→計1447ＩＤ／内プレ425ＩＤ／総33372米」. Always muted.
    public static let annoyingStatisticalCommentPattern = "最高\\d+米\\/|計\\d+ＩＤ|総\\d+米"

    // MARK: Isolation entry points

    /// The mute decision for a past log comment.
    ///
    /// `GET /api/videos/{id}/jikkyo` carries no `premium` flag, so operator
    /// command comments are not filtered for past logs (same as the web client,
    /// which calls `isMutedComment()` without the premium argument there).
    public static func isMuted(_ comment: JikkyoComment, options: Options) -> Bool {
        isMuted(
            text: comment.text,
            userID: comment.author,
            color: comment.color,
            position: comment.type,
            size: comment.size,
            premium: nil,
            options: options
        )
    }

    /// The mute decision for a live `chat` comment.
    public static func isMuted(_ chat: JikkyoChatComment, options: Options) -> Bool {
        let style = chat.commands
        return isMuted(
            text: chat.content,
            userID: chat.userID,
            color: style.color,
            position: style.position,
            size: style.size,
            premium: chat.premium,
            options: options
        )
    }

    /// The mute decision itself (`CommentUtils.isMutedComment`).
    public static func isMuted(
        text: String,
        userID: String,
        color: String? = nil,
        position: CommentDanmaku.Position? = nil,
        size: CommentDanmaku.Size? = nil,
        premium: String? = nil,
        options: Options
    ) -> Bool {
        // 1. Muted Niconico user IDs.
        if options.mutedNiconicoUserIDs.contains(userID) {
            return true
        }

        // 2. Niconico operator commands (`/nicoad` …) are always dropped.
        if isSpecialCommandComment(text, premium: premium) {
            return true
        }

        // 3. Comments fixed above / below the video.
        if options.muteFixedComments, position == .top || position == .bottom {
            return true
        }

        // 4. Coloured comments (anything but the exact default colour, like the
        // web client's `color !== '#FFEAEA'`).
        if options.muteColoredComments,
           let color,
           color != CommentCommands.defaultColor {
            return true
        }

        // 5. Big comments.
        if options.muteBigSizeComments, size == .big {
            return true
        }

        // 6. Vulgar comments.
        if options.muteVulgarComments,
           matches(vulgarPattern, text) {
            return true
        }

        // 7. Abusive / discriminatory / prejudiced comments.
        if options.muteAbusiveDiscriminatoryPrejudicedComments,
           matches(abusiveDiscriminatoryPrejudicedPattern, text) {
            return true
        }

        // 8. Eight or more of the same character in a row.
        if options.muteConsecutiveSameCharactersComments,
           matches(consecutiveSameCharactersPattern, text) {
            return true
        }

        // 9. The user's own keyword list.
        let textForKeywords = options.normalizeCommentKeywords ? normalizeKeyword(text) : text
        for keyword in options.mutedCommentKeywords {
            if keyword.pattern.isEmpty { continue }
            if matchesKeyword(keyword, text: text, textForKeywords: textForKeywords, options: options) {
                return true
            }
        }

        // 10. Spam statistics comments are always dropped.
        if matches(annoyingStatisticalCommentPattern, text) {
            return true
        }

        return false
    }

    // MARK: Helpers

    /// True for a Niconico operator command comment. `premium` must be "3"
    /// (運営コメント) for the comment to count as one, and a comment without the
    /// flag is never treated as an operator command.
    public static func isSpecialCommandComment(_ text: String, premium: String?) -> Bool {
        guard matches(specialCommandPattern, text) else { return false }
        guard let premium else { return false }
        return premium == "3"
    }

    /// 「8文字以上同じ文字が連続しているコメント」 (`(.)\1{7,}`).
    public static func hasConsecutiveSameCharacters(_ text: String) -> Bool {
        matches(consecutiveSameCharactersPattern, text)
    }

    /// 迷惑な統計コメント (`最高\d+米\/|計\d+ＩＤ|総\d+米`), which the web client
    /// always mutes.
    public static func isAnnoyingStatisticalComment(_ text: String) -> Bool {
        matches(annoyingStatisticalCommentPattern, text)
    }

    /// `CommentUtils.normalizeCommentKeyword()`: NFKC first (full width → half
    /// width, ① → 1, Ⅲ → III, ² → 2, … → ..., ﬁ → fi, ㎡ → m2), then per
    /// character the full width space → space, hyphen / dash / prolonged sound
    /// mark look-alikes → "-", and finally ASCII upper case → lower case.
    public static func normalizeKeyword(_ text: String) -> String {
        let compatibilityNormalized = text.precomposedStringWithCompatibilityMapping

        var mapped = ""
        mapped.reserveCapacity(compatibilityNormalized.count)
        for scalar in compatibilityNormalized.unicodeScalars {
            switch scalar.value {
            case 0x3000:
                // 全角スペース → 半角スペース
                mapped.unicodeScalars.append(" ")
            case 0xFF01...0xFF5D:
                // 全角英数字・記号 → 半角 (NFKC covers most of this already,
                // this is the web client's fallback)
                if let replacement = UnicodeScalar(scalar.value - 0xFEE0) {
                    mapped.unicodeScalars.append(replacement)
                } else {
                    mapped.unicodeScalars.append(scalar)
                }
            default:
                if let replacement = hyphenLikeCharacters[scalar.value] {
                    mapped.unicodeScalars.append(replacement)
                } else {
                    mapped.unicodeScalars.append(scalar)
                }
            }
        }

        // The web client only lowercases ASCII A-Z.
        var lowered = ""
        lowered.reserveCapacity(mapped.count)
        for scalar in mapped.unicodeScalars {
            if scalar.value >= 0x41, scalar.value <= 0x5A,
               let replacement = UnicodeScalar(scalar.value + 0x20) {
                lowered.unicodeScalars.append(replacement)
            } else {
                lowered.unicodeScalars.append(scalar)
            }
        }
        return lowered
    }

    /// Hyphen / dash / prolonged sound mark look-alikes that all become
    /// `-` (U+002D), from `CommentUtils.hyphen_like_char_map`.
    public static let hyphenLikeCharacters: [UInt32: Unicode.Scalar] = { () in
        let hyphen = Unicode.Scalar(0x002D)
        let codePoints: [UInt32] = [
            0x02D7,  // ˗ Modifier Letter Minus Sign
            0x2010,  // ‐ Hyphen
            0x2011,  // ‑ Non-Breaking Hyphen
            0x2012,  // ‒ Figure Dash
            0x2013,  // – En Dash
            0x2014,  // — Em Dash
            0x2015,  // ― Horizontal Bar
            0x2043,  // ⁃ Hyphen Bullet
            0x2212,  // − Minus Sign
            0x23AF,  // ⎯ Horizontal Line Extension
            0x23E4,  // ⏤ Straightness
            0x2500,  // ─ Box Drawings Light Horizontal
            0x2501,  // ━ Box Drawings Heavy Horizontal
            0x2E3A,  // ⸺ Two-Em Dash
            0x2E3B,  // ⸻ Three-Em Dash
            0x30FC,  // ー Katakana-Hiragana Prolonged Sound Mark
            0xFF70,  // ｰ Halfwidth Katakana-Hiragana Prolonged Sound Mark
            0x007E,  // ~ Tilde
            0xFF5E,  // ～ Fullwidth Tilde
            0x301C,  // 〜 Wave Dash
        ]
        var table: [UInt32: Unicode.Scalar] = [:]
        for codePoint in codePoints {
            table[codePoint] = hyphen
        }
        return table
    }()

    // MARK: Regex plumbing

    private static func matchesKeyword(
        _ keyword: MutedCommentKeyword,
        text: String,
        textForKeywords: String,
        options: Options
    ) -> Bool {
        let pattern = options.normalizeCommentKeywords
            ? normalizeKeyword(keyword.pattern)
            : keyword.pattern

        switch keyword.match {
        case .partial:
            return textForKeywords.contains(pattern)
        case .forward:
            return textForKeywords.hasPrefix(pattern)
        case .backward:
            return textForKeywords.hasSuffix(pattern)
        case .exact:
            return textForKeywords == pattern
        case .regex:
            // The web client compiles the pattern on every comment and would
            // throw on an invalid one; here an invalid pattern simply never
            // matches.
            guard let regex = try? NSRegularExpression(pattern: keyword.pattern) else {
                return false
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    /// `RegExp.test(comment)` equivalent. Patterns are compiled once; invalid
    /// patterns never match.
    private static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = regexCache.regex(for: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Compiled built-in patterns, keyed by source. NSRegularExpression is
    /// immutable, so sharing instances between tasks is safe; the class just
    /// predates `Sendable`.
    private static let regexCache = RegexCache()

    final class RegexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: NSRegularExpression] = [:]

        func regex(for pattern: String) -> NSRegularExpression? {
            lock.lock()
            if let cached = storage[pattern] {
                lock.unlock()
                return cached
            }
            lock.unlock()

            guard let compiled = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            lock.lock()
            storage[pattern] = compiled
            lock.unlock()
            return compiled
        }
    }
}

// MARK: - Comment acceptance

/// The "should this comment be shown at all" checks from
/// `LiveCommentManager.initCommentSession()`, before any mute rule runs.
public enum JikkyoCommentAcceptance {

    /// Rejects empty comments and the user's own comments.
    ///
    /// The web client drops comments with `yourpost == 1` only after the batch
    /// of past comments that the server sends on connect has been received
    /// (`initial_comments_received`), and it also drops non-anonymous comments
    /// whose Niconico user ID equals the logged in user's (the server echoes
    /// those back as `nicolive:1234567`).
    ///
    /// - Parameters:
    ///   - isInitialComments: true while the past comments of a fresh comment
    ///     session are still coming in.
    ///   - ownNiconicoUserID: `User.niconicoUserID` of the logged in user.
    public static func accepts(
        _ chat: JikkyoChatComment,
        isInitialComments: Bool,
        ownNiconicoUserID: Int? = nil
    ) -> Bool {
        if chat.content.isEmpty {
            return false
        }
        if chat.yourPost, !isInitialComments {
            return false
        }
        if let ownNiconicoUserID,
           String(ownNiconicoUserID) == chat.niconicoUserID {
            return false
        }
        return true
    }
}
