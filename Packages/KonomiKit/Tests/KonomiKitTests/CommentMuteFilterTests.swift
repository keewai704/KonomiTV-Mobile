import Foundation
import XCTest
@testable import KonomiKit

// MARK: - Mute filter

final class CommentMuteFilterTests: XCTestCase {

    private func makeChat(
        _ content: String,
        userID: String = "AbCdEfGhIjKl",
        mail: String? = nil,
        premium: String? = nil
    ) -> JikkyoChatComment {
        JikkyoChatComment(mail: mail, userID: userID, content: content, premium: premium)
    }

    private var defaults: CommentMuteFilter.Options { .webDefaults }

    // MARK: Defaults

    func testWebDefaults() {
        let options = CommentMuteFilter.Options(settings: ClientSettings())
        XCTAssertTrue(options.muteVulgarComments)
        XCTAssertTrue(options.muteAbusiveDiscriminatoryPrejudicedComments)
        XCTAssertTrue(options.muteBigSizeComments)
        XCTAssertFalse(options.muteFixedComments)
        XCTAssertFalse(options.muteColoredComments)
        XCTAssertFalse(options.muteConsecutiveSameCharactersComments)
        XCTAssertTrue(options.normalizeCommentKeywords)
        XCTAssertTrue(options.mutedCommentKeywords.isEmpty)
        XCTAssertTrue(options.mutedNiconicoUserIDs.isEmpty)
        XCTAssertEqual(options, defaults)
    }

    func testHarmlessCommentIsNotMuted() {
        XCTAssertFalse(
            CommentMuteFilter.isMuted(
                text: "こんばんは",
                userID: "AbCdEfGhIjKl",
                color: CommentCommands.defaultColor,
                position: .scroll,
                size: .medium,
                options: defaults
            )
        )
    }

    // MARK: Built-in lists

    func testVulgarListMatchesTheWebPattern() {
        // Both kana and the full width / symbol variants the web pattern lists.
        for text in ["エッチな話", "これはアダルト", "まんこ", "ＳＥＸ", "S〇X", "ｐｒｐｒ", "(i)"] {
            XCTAssertTrue(
                CommentMuteFilter.isMuted(text: text, userID: "u", options: defaults),
                "expected \(text) to be muted"
            )
        }
        XCTAssertFalse(
            CommentMuteFilter.isMuted(text: "普通のコメントです", userID: "u", options: defaults)
        )
    }

    func testVulgarListCanBeTurnedOff() {
        var options = defaults
        options.muteVulgarComments = false
        XCTAssertFalse(CommentMuteFilter.isMuted(text: "エッチ", userID: "u", options: options))
    }

    func testAbusiveListMatchesTheWebPattern() {
        for text in ["バカ", "死ね", "韓国", "つまらない", "ガイジ", "気持ち悪"] {
            XCTAssertTrue(
                CommentMuteFilter.isMuted(text: text, userID: "u", options: defaults),
                "expected \(text) to be muted"
            )
        }
        // Anchored entries only match the whole comment.
        XCTAssertTrue(CommentMuteFilter.isMuted(text: "菌", userID: "u", options: defaults))
        XCTAssertFalse(CommentMuteFilter.isMuted(text: "細菌性", userID: "u", options: defaults))

        var options = defaults
        options.muteAbusiveDiscriminatoryPrejudicedComments = false
        XCTAssertFalse(CommentMuteFilter.isMuted(text: "バカ", userID: "u", options: options))
    }

    func testPatternsAreTheWebPatternsVerbatim() {
        // Sanity check that the (very long) patterns were not truncated.
        XCTAssertTrue(CommentMuteFilter.vulgarPattern.hasPrefix("\\(i\\)|\\(U\\)|prpr|"))
        XCTAssertTrue(CommentMuteFilter.vulgarPattern.hasSuffix("●ックス"))
        XCTAssertTrue(CommentMuteFilter.abusiveDiscriminatoryPrejudicedPattern.hasPrefix("。|アニプレ|"))
        XCTAssertTrue(CommentMuteFilter.abusiveDiscriminatoryPrejudicedPattern.hasSuffix("|野郎"))
        XCTAssertEqual(
            CommentMuteFilter.abusiveDiscriminatoryPrejudicedPattern.split(separator: "|").count,
            CommentMuteFilter.abusiveDiscriminatoryPrejudicedPattern
                .components(separatedBy: "|").count
        )
    }

    // MARK: Size / position / colour

    func testBigSize() throws {
        let message = try JikkyoCommentSessionMessage.decode(
            #"{"chat":{"no":1,"vpos":100,"user_id":"u","content":"でかい","mail":"big red"}}"#
        )
        guard case .chat(let chat) = message else {
            return XCTFail("expected chat")
        }
        XCTAssertTrue(CommentMuteFilter.isMuted(chat, options: defaults))

        var options = defaults
        options.muteBigSizeComments = false
        XCTAssertFalse(CommentMuteFilter.isMuted(chat, options: options))
    }

    func testFixedComments() {
        let fixed = CommentDanmaku.Position.top
        XCTAssertFalse(
            CommentMuteFilter.isMuted(
                text: "固定コメント", userID: "u", position: fixed, options: defaults
            )
        )
        var options = defaults
        options.muteFixedComments = true
        XCTAssertTrue(
            CommentMuteFilter.isMuted(
                text: "固定コメント", userID: "u", position: .top, options: options
            )
        )
        XCTAssertTrue(
            CommentMuteFilter.isMuted(
                text: "固定コメント", userID: "u", position: .bottom, options: options
            )
        )
        XCTAssertFalse(
            CommentMuteFilter.isMuted(
                text: "流れるコメント", userID: "u", position: .scroll, options: options
            )
        )
    }

    func testColoredComments() {
        var options = defaults
        options.muteColoredComments = true
        XCTAssertTrue(
            CommentMuteFilter.isMuted(
                text: "あか", userID: "u", color: "#F02840", options: options
            )
        )
        XCTAssertFalse(
            CommentMuteFilter.isMuted(
                text: "しろ", userID: "u", color: "#FFEAEA", options: options
            )
        )
        XCTAssertFalse(
            CommentMuteFilter.isMuted(text: "いろなし", userID: "u", color: nil, options: options)
        )
    }

    // MARK: User mutes

    func testMutedUserIDs() {
        var options = defaults
        options.mutedNiconicoUserIDs = ["nicolive:999", "AbCdEfGhIjKl"]
        XCTAssertTrue(
            CommentMuteFilter.isMuted(text: "こんばんは", userID: "AbCdEfGhIjKl", options: options)
        )
        XCTAssertFalse(
            CommentMuteFilter.isMuted(text: "こんばんは", userID: "OtherUsuario", options: options)
        )
    }

    // MARK: Special command comments

    func testSpecialCommandComments() {
        // Operator commands are only filtered when premium marks them as 運営.
        XCTAssertFalse(
            CommentMuteFilter.isSpecialCommandComment("/nicoad テスト", premium: nil)
        )
        XCTAssertFalse(
            CommentMuteFilter.isSpecialCommandComment("/nicoad テスト", premium: "1")
        )
        XCTAssertTrue(CommentMuteFilter.isSpecialCommandComment("/nicoad テスト", premium: "3"))
        XCTAssertFalse(CommentMuteFilter.isSpecialCommandComment("/nicoadテスト", premium: "3"))
        XCTAssertFalse(CommentMuteFilter.isSpecialCommandComment("ふつう", premium: "3"))

        // A past log comment has no premium flag, so its operator command
        // comments stay visible (same as the web client).
        let past = JikkyoComment(time: 1, color: "#FFEAEA", author: "u", text: "/nicoad テスト")
        XCTAssertFalse(CommentMuteFilter.isMuted(past, options: defaults))
    }

    // MARK: Consecutive characters

    func testConsecutiveSameCharacters() {
        var options = defaults
        options.muteConsecutiveSameCharactersComments = true

        // 8 in a row is muted, 7 is not (the web regex is {7,} after the first).
        XCTAssertTrue(CommentMuteFilter.hasConsecutiveSameCharacters("ああああああああ"))
        XCTAssertFalse(CommentMuteFilter.hasConsecutiveSameCharacters("あああああああ"))
        XCTAssertTrue(CommentMuteFilter.hasConsecutiveSameCharacters("きたwwwwwwww"))
        XCTAssertTrue(
            CommentMuteFilter.isMuted(
                text: "ああああああああ", userID: "u", options: options
            )
        )
        XCTAssertFalse(
            CommentMuteFilter.isMuted(
                text: "ああああああああ", userID: "u", options: defaults
            )
        )
    }

    // MARK: Keywords

    func testKeywordMatchTypes() {
        var options = defaults
        options.mutedCommentKeywords = [
            MutedCommentKeyword(match: .partial, pattern: "あほ"),
            MutedCommentKeyword(match: .forward, pattern: "きた"),
            MutedCommentKeyword(match: .backward, pattern: "です"),
            MutedCommentKeyword(match: .exact, pattern: "まるごと"),
            MutedCommentKeyword(match: .regex, pattern: "^[0-9]+$"),
        ]

        XCTAssertTrue(CommentMuteFilter.isMuted(text: "それはあほだ", userID: "u", options: options))
        XCTAssertTrue(CommentMuteFilter.isMuted(text: "きたあああ", userID: "u", options: options))
        XCTAssertFalse(CommentMuteFilter.isMuted(text: "ああきた", userID: "u", options: options))
        XCTAssertTrue(CommentMuteFilter.isMuted(text: "そうですねです", userID: "u", options: options))
        XCTAssertFalse(
            CommentMuteFilter.isMuted(text: "ですよね", userID: "u", options: options)
        )
        XCTAssertTrue(CommentMuteFilter.isMuted(text: "まるごと", userID: "u", options: options))
        // Exact match does not fire on a longer comment (and this one is not
        // caught by the other keywords either).
        XCTAssertFalse(
            CommentMuteFilter.isMuted(text: "まるごとでした", userID: "u", options: options)
        )
        XCTAssertTrue(CommentMuteFilter.isMuted(text: "12345", userID: "u", options: options))
        XCTAssertFalse(
            CommentMuteFilter.isMuted(text: "abc", userID: "u", options: options)
        )
    }

    func testEmptyAndInvalidKeywordPatternsNeverMatch() {
        var options = defaults
        options.mutedCommentKeywords = [
            MutedCommentKeyword(match: .partial, pattern: ""),
            MutedCommentKeyword(match: .regex, pattern: "([unclosed"),
        ]
        XCTAssertFalse(
            CommentMuteFilter.isMuted(text: "こんばんは", userID: "u", options: options)
        )
    }

    func testRegexKeywordIsNotAnchored() {
        var options = defaults
        options.mutedCommentKeywords = [MutedCommentKeyword(match: .regex, pattern: "[0-9]{3}")]
        XCTAssertTrue(CommentMuteFilter.isMuted(text: "abc123def", userID: "u", options: options))
        XCTAssertFalse(CommentMuteFilter.isMuted(text: "abc12def", userID: "u", options: options))
    }

    // MARK: Normalisation

    func testNormalization() {
        // 全角英数字 → 半角, 大文字 → 小文字 (NFKC + ASCII lowercase)
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("ＡＢＣ１２３"), "abc123")
        // 全角スペース
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("あ　い"), "あ い")
        // ハイフン・ダッシュ・長音系はすべて "-"
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("３３ー４"), "33-4")
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("３３−４"), "33-4")
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("33–4"), "33-4")
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("33〜4"), "33-4")
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("33～4"), "33-4")
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("33~4"), "33-4")
        // 丸囲み数字 / ローマ数字 / 上付き数字 / 合字 / 単位記号
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("①Ⅲ²"), "1iii2")
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("…"), "...")
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("㎡"), "m2")
        // カタカナはそのまま
        XCTAssertEqual(CommentMuteFilter.normalizeKeyword("カタカナ"), "カタカナ")
    }

    func testKeywordMatchingNormalizesBothSides() {
        var options = defaults
        options.mutedCommentKeywords = [
            MutedCommentKeyword(match: .partial, pattern: "ａｂｃ１２３")
        ]
        XCTAssertTrue(
            CommentMuteFilter.isMuted(text: "これはABC123です", userID: "u", options: options)
        )

        // With normalisation off the full width keyword no longer matches.
        options.normalizeCommentKeywords = false
        XCTAssertFalse(
            CommentMuteFilter.isMuted(text: "これはABC123です", userID: "u", options: options)
        )
        XCTAssertTrue(
            CommentMuteFilter.isMuted(text: "これはａｂｃ１２３です", userID: "u", options: options)
        )
    }

    func testHyphenNormalizationPreventsBypass() {
        // 「33-4」を弾くキーワードが、似た文字を使った表記も弾く
        var options = defaults
        options.mutedCommentKeywords = [MutedCommentKeyword(match: .partial, pattern: "33-4")]
        for text in ["33-4", "３３ー４", "３３−４", "33～4", "33—4"] {
            XCTAssertTrue(
                CommentMuteFilter.isMuted(text: text, userID: "u", options: options),
                "expected \(text) to be muted"
            )
        }
    }

    // MARK: Spam statistics

    func testAnnoyingStatisticalComments() {
        let spam = "ＮHK→計1447ＩＤ／内プレ425ＩＤ／総33372米 ◆ Ｅﾃﾚ → 計73ＩＤ／内プレ19ＩＤ／総941米"
        XCTAssertTrue(CommentMuteFilter.isAnnoyingStatisticalComment(spam))
        XCTAssertTrue(CommentMuteFilter.isMuted(text: spam, userID: "u", options: defaults))

        XCTAssertTrue(CommentMuteFilter.isAnnoyingStatisticalComment("計123ＩＤ"))
        XCTAssertTrue(CommentMuteFilter.isAnnoyingStatisticalComment("総456米"))
        XCTAssertFalse(CommentMuteFilter.isAnnoyingStatisticalComment("最高です"))
        // Always on, even with every mute setting turned off.
        var options = defaults
        options.muteVulgarComments = false
        options.muteAbusiveDiscriminatoryPrejudicedComments = false
        options.muteBigSizeComments = false
        XCTAssertTrue(CommentMuteFilter.isMuted(text: spam, userID: "u", options: options))
    }

    // MARK: Past log comments

    func testPastLogCommentUsesItsOwnFields() {
        var options = defaults
        options.muteColoredComments = true
        let colored = JikkyoComment(
            time: 1, type: .scroll, size: .medium, color: "#F02840", author: "u", text: "あか"
        )
        XCTAssertTrue(CommentMuteFilter.isMuted(colored, options: options))

        let plain = JikkyoComment(
            time: 1, type: .scroll, size: .medium, color: "#FFEAEA", author: "u", text: "しろ"
        )
        XCTAssertFalse(CommentMuteFilter.isMuted(plain, options: options))

        options.muteBigSizeComments = true
        let big = JikkyoComment(
            time: 1, type: .scroll, size: .big, color: "#FFEAEA", author: "u", text: "でかい"
        )
        XCTAssertTrue(CommentMuteFilter.isMuted(big, options: options))
    }
}

// MARK: - Comment settings accessors

final class CommentSettingsTests: XCTestCase {

    private func makeSettings() throws -> ClientSettings {
        try JSONCoding.decode(ClientSettings.self, from: Fixtures.clientSettingsJSON)
    }

    func testCommentAccessorsReadFixture() throws {
        let settings = try makeSettings()
        XCTAssertTrue(settings.preferPostingToNicolive)
        XCTAssertEqual(settings.commentSpeedRate, 1)
        XCTAssertEqual(settings.commentFontSize, 34)
        XCTAssertTrue(settings.closeCommentFormAfterSending)
        XCTAssertTrue(settings.muteVulgarComments)
        XCTAssertTrue(settings.muteAbusiveDiscriminatoryPrejudicedComments)
        XCTAssertTrue(settings.muteBigSizeComments)
        XCTAssertFalse(settings.muteFixedComments)
        XCTAssertFalse(settings.muteColoredComments)
        XCTAssertFalse(settings.muteConsecutiveSameCharactersComments)
        XCTAssertTrue(settings.muteCommentKeywordsNormalizeAlphanumericWidthCase)
        XCTAssertTrue(settings.mutedCommentKeywords.isEmpty)
        XCTAssertTrue(settings.mutedNiconicoUserIDs.isEmpty)
    }

    func testCommentAccessorsFallBackToWebDefaults() {
        let settings = ClientSettings()
        XCTAssertTrue(settings.preferPostingToNicolive)
        XCTAssertEqual(settings.commentSpeedRate, 1)
        XCTAssertEqual(settings.commentFontSize, 34)
        XCTAssertTrue(settings.closeCommentFormAfterSending)
        XCTAssertTrue(settings.muteVulgarComments)
        XCTAssertTrue(settings.muteAbusiveDiscriminatoryPrejudicedComments)
        XCTAssertTrue(settings.muteBigSizeComments)
        XCTAssertFalse(settings.muteFixedComments)
        XCTAssertFalse(settings.muteColoredComments)
        XCTAssertFalse(settings.muteConsecutiveSameCharactersComments)
        XCTAssertTrue(settings.muteCommentKeywordsNormalizeAlphanumericWidthCase)
        XCTAssertTrue(settings.mutedCommentKeywords.isEmpty)
        XCTAssertTrue(settings.mutedNiconicoUserIDs.isEmpty)
    }

    func testMutedKeywordListRoundTrips() throws {
        var settings = ClientSettings()
        settings.mutedCommentKeywords = [
            MutedCommentKeyword(match: .exact, pattern: "まるごと"),
            MutedCommentKeyword(match: .regex, pattern: "^[0-9]+$"),
        ]
        settings.mutedNiconicoUserIDs = ["nicolive:999"]

        let data = try JSONCoding.encode(settings)
        let decoded = try JSONCoding.decode(ClientSettings.self, from: data)
        XCTAssertEqual(decoded.mutedCommentKeywords.count, 2)
        XCTAssertEqual(decoded.mutedCommentKeywords[0].match, .exact)
        XCTAssertEqual(decoded.mutedCommentKeywords[0].pattern, "まるごと")
        XCTAssertEqual(decoded.mutedCommentKeywords[1].match, .regex)
        XCTAssertEqual(decoded.mutedCommentKeywords[1].pattern, "^[0-9]+$")
        XCTAssertEqual(decoded.mutedNiconicoUserIDs, ["nicolive:999"])
    }

    func testMutedKeywordUnknownMatchFallsBackToPartial() throws {
        let settings = try JSONCoding.decode(
            ClientSettings.self,
            from: #"{"muted_comment_keywords":[{"match":"future_kind","pattern":"x"}]}"#
        )
        XCTAssertEqual(settings.mutedCommentKeywords.first?.match, .partial)
        XCTAssertEqual(settings.mutedCommentKeywords.first?.pattern, "x")
    }

    func testOptionsFollowSettings() throws {
        let settings = try JSONCoding.decode(
            ClientSettings.self,
            from: """
            {
              "mute_vulgar_comments": false,
              "mute_fixed_comments": true,
              "muted_comment_keywords": [{"match": "forward", "pattern": "%%%"}],
              "muted_niconico_user_ids": ["nicolive:1"]
            }
            """
        )
        let options = CommentMuteFilter.Options(settings: settings)
        XCTAssertFalse(options.muteVulgarComments)
        XCTAssertTrue(options.muteFixedComments)
        XCTAssertEqual(options.mutedCommentKeywords.first?.match, .forward)
        XCTAssertEqual(options.mutedNiconicoUserIDs, ["nicolive:1"])

        XCTAssertFalse(
            CommentMuteFilter.isMuted(text: "エッチ", userID: "u", options: options)
        )
        XCTAssertTrue(
            CommentMuteFilter.isMuted(
                text: "固定", userID: "u", position: .top, options: options
            )
        )
        XCTAssertTrue(
            CommentMuteFilter.isMuted(text: "%%% テスト", userID: "u", options: options)
        )
        XCTAssertTrue(
            CommentMuteFilter.isMuted(text: "こんばんは", userID: "nicolive:1", options: options)
        )
    }
}
