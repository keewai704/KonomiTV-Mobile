import XCTest

/// ニコニコ実況: live comments, mute settings, posting, past log comments and
/// Niconico account linking.
final class CommentUITests: KonomiTVUITestCase {

    // MARK: - Helpers

    private func openLive(in app: XCUIApplication, channelID: String = "gr011") {
        openSection(.live, in: app)
        let channel = uiElement(app, "live.channel.\(channelID)")
        XCTAssertTrue(channel.waitForExistence(timeout: TestTimeout.ui), "ライブチャンネルが表示されない")
        tapWhenHittable(channel, in: app)
        waitForPlaying(in: app)
    }

    private func openVideo(in app: XCUIApplication) {
        openSection(.videos, in: app)
        let item = uiElement(app, "videos.recent.1")
        XCTAssertTrue(item.waitForExistence(timeout: TestTimeout.ui), "先頭のビデオが表示されない")
        tapWhenHittable(item, in: app)
        waitForPlaying(in: app)
    }

    private func waitForPlaying(in app: XCUIApplication) {
        XCTAssertTrue(
            uiElement(app, "player.view").waitForExistence(timeout: TestTimeout.playback),
            "プレイヤーが表示されない"
        )
        let state = uiElement(app, "player.state")
        XCTAssertTrue(state.waitForExistence(timeout: TestTimeout.playback), "再生状態が取得できない")
        XCTAssertTrue(
            waitForLabel(state, equals: "playing", timeout: TestTimeout.playback),
            "再生が playing にならない (状態: \(state.label))"
        )
    }

    private func openCommentPanel(in app: XCUIApplication) {
        let tab = uiElement(app, "panel.comment")
        XCTAssertTrue(tab.waitForExistence(timeout: TestTimeout.ui), "コメントタブが表示されない")
        tapWhenHittable(tab, in: app)
    }

    private func commentRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "comment.row."))
    }

    private func drawnCount(in app: XCUIApplication) -> Int {
        intLabel(of: "comments.drawnCount", in: app) ?? 0
    }

    private func postedComments() -> [String] {
        (MockServerControl.stats()["jikkyo_posted_comments"] as? [String]) ?? []
    }

    /// Opens 設定 → ニコニコ実況, scrolling the form until the row is visible.
    private func openJikkyoSettings(in app: XCUIApplication) {
        openSection(.settings, in: app)
        let link = uiElement(app, "settings.jikkyo")
        if !link.waitForExistence(timeout: 3) {
            for _ in 0..<6 {
                app.swipeUp()
                if link.waitForExistence(timeout: 2) {
                    break
                }
            }
        }
        XCTAssertTrue(link.waitForExistence(timeout: TestTimeout.ui), "ニコニコ実況の設定が表示されない")
        tapWhenHittable(link, in: app)
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        if element.exists, element.isHittable {
            return
        }
        let container: XCUIElement
        if app.collectionViews.firstMatch.exists {
            container = app.collectionViews.firstMatch
        } else if app.scrollViews.firstMatch.exists {
            container = app.scrollViews.firstMatch
        } else {
            container = app
        }
        _ = scrollUntilVisible(element, in: container)
    }

    // MARK: - Live comments

    func testLiveCommentsAreDrawnAndListed() {
        let app = startApp()
        openLive(in: app)

        XCTAssertTrue(
            waitUntil(timeout: 20) { self.drawnCount(in: app) >= 3 },
            "ライブコメントが映像に描画されない (drawn: \(drawnCount(in: app)))"
        )

        openCommentPanel(in: app)
        XCTAssertTrue(
            commentRows(in: app).firstMatch.waitForExistence(timeout: TestTimeout.ui),
            "コメント一覧に行が表示されない"
        )
    }

    // MARK: - Mute

    func testMuteKeywordHidesCommentFromList() {
        let app = startApp()
        openJikkyoSettings(in: app)

        let addKeyword = uiElement(app, "settings.mute.addKeyword")
        scrollTo(addKeyword, in: app)
        tapWhenHittable(addKeyword, in: app)

        let keywordField = uiElement(app, "settings.mute.keyword.0")
        scrollTo(keywordField, in: app)
        // ASCII template comment of the mock; the default match type is 部分一致.
        replaceText(in: keywordField, with: "88888888", in: app)

        navigateBack(in: app)
        openLive(in: app)
        openCommentPanel(in: app)

        XCTAssertTrue(
            commentRows(in: app).firstMatch.waitForExistence(timeout: TestTimeout.ui),
            "コメント一覧が表示されない"
        )

        waitSeconds(8)

        let mutedRows = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "comment.row.",
                "88888888"
            )
        )
        XCTAssertEqual(mutedRows.count, 0, "ミュートしたキーワードのコメントが一覧に残っている")
    }

    // MARK: - Posting

    func testPostedCommentReachesServerAndList() {
        let app = startApp()
        openSection(.settings, in: app)
        login(in: app)

        openLive(in: app)
        openCommentPanel(in: app)

        // A row means the watch room is known and sending is possible.
        XCTAssertTrue(
            commentRows(in: app).firstMatch.waitForExistence(timeout: TestTimeout.ui),
            "コメント一覧が表示されない"
        )

        let text = "comment-test-123"
        let input = uiElement(app, "comment.input")
        replaceText(in: input, with: text, in: app)
        tapWhenHittable(uiElement(app, "comment.send"), in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { self.postedComments().contains(text) },
            "投稿したコメントがサーバーに届いていない (\(postedComments()))"
        )

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                self.commentRows(in: app).matching(
                    NSPredicate(format: "label CONTAINS %@", text)
                ).count > 0
            },
            "投稿したコメントが一覧に表示されない"
        )
    }

    // MARK: - Past log

    func testPastLogCommentsAppearForRecordedVideo() {
        let app = startApp()
        openVideo(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) { self.drawnCount(in: app) >= 1 },
            "録画番組の過去ログコメントが描画されない (drawn: \(drawnCount(in: app)))"
        )
    }

    // MARK: - Niconico account linking

    func testNiconicoLinkAndUnlink() {
        let app = startApp(disableASWebAuth: true)
        openSection(.settings, in: app)
        login(in: app)

        openJikkyoSettings(in: app)

        let link = uiElement(app, "settings.niconico.link")
        XCTAssertTrue(link.waitForExistence(timeout: TestTimeout.ui), "連携するボタンが表示されない")
        tapWhenHittable(link, in: app)

        let name = uiElement(app, "settings.niconico.name")
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                name.exists && name.label.contains("モックニコニコ")
            },
            "連携後のアカウント名が表示されない (\(name.label))"
        )

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("niconico_link_count") == 1
            },
            "サーバー側でニコニコアカウントが連携されていない"
        )

        let unlink = uiElement(app, "settings.niconico.unlink")
        XCTAssertTrue(unlink.waitForExistence(timeout: TestTimeout.ui), "連携を解除ボタンが表示されない")
        tapWhenHittable(unlink, in: app)

        XCTAssertTrue(
            uiElement(app, "settings.niconico.link").waitForExistence(timeout: TestTimeout.ui),
            "連携解除後に連携するボタンが戻らない"
        )
    }
}
