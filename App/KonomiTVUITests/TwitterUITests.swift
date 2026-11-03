import XCTest

/// Twitter / Bluesky: account linking in the settings screen, posting from the
/// watch screen's Twitter tab (with hashtags and captures), the merged
/// timeline and the hashtag search.
final class TwitterUITests: KonomiTVUITestCase {

    // MARK: - Helpers

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

    private func openLive(in app: XCUIApplication) {
        openSection(.live, in: app)
        let channel = uiElement(app, "live.channel.gr011")
        XCTAssertTrue(channel.waitForExistence(timeout: TestTimeout.ui), "ライブチャンネルが表示されない")
        tapWhenHittable(channel, in: app)
        waitForPlaying(in: app)
    }

    /// Opens 設定 → Twitter / Bluesky, scrolling the form when needed.
    private func openTwitterSettings(in app: XCUIApplication) {
        openSection(.settings, in: app)
        let link = uiElement(app, "settings.twitter")
        if !link.waitForExistence(timeout: 3) {
            for _ in 0..<6 {
                app.swipeUp()
                if link.waitForExistence(timeout: 2) {
                    break
                }
            }
        }
        XCTAssertTrue(link.waitForExistence(timeout: TestTimeout.ui), "Twitter の設定が表示されない")
        tapWhenHittable(link, in: app)
    }

    /// Links the mock Twitter account through the cookies.txt sheet.
    private func linkTwitterAccount(in app: XCUIApplication) {
        openTwitterSettings(in: app)

        let add = uiElement(app, "settings.twitter.addTwitter")
        XCTAssertTrue(add.waitForExistence(timeout: TestTimeout.ui), "Twitter アカウントの追加ボタンがない")
        tapWhenHittable(add, in: app)

        let cookies = uiElement(app, "settings.twitter.cookies")
        XCTAssertTrue(cookies.waitForExistence(timeout: TestTimeout.ui), "Cookie 入力欄が表示されない")
        replaceText(
            in: cookies,
            with: "x.com TRUE / FALSE 0 auth_token mock",
            in: app
        )

        let login = uiElement(app, "settings.twitter.cookies.login")
        XCTAssertTrue(login.waitForExistence(timeout: TestTimeout.ui), "ログインボタンがない")
        tapWhenHittable(login, in: app)

        XCTAssertTrue(
            uiElement(app, "settings.twitter.account.twitter.1").waitForExistence(timeout: TestTimeout.ui),
            "連携した Twitter アカウントが表示されない"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("twitter_auth_count") >= 1
            },
            "Twitter アカウントがサーバーで連携されていない"
        )
    }

    /// Links the mock Bluesky account through the App Password sheet.
    private func linkBlueskyAccount(in app: XCUIApplication) {
        openTwitterSettings(in: app)

        let add = uiElement(app, "settings.twitter.addBluesky")
        XCTAssertTrue(add.waitForExistence(timeout: TestTimeout.ui), "Bluesky アカウントの追加ボタンがない")
        tapWhenHittable(add, in: app)

        let handle = uiElement(app, "settings.twitter.bluesky.handle")
        XCTAssertTrue(handle.waitForExistence(timeout: TestTimeout.ui), "Bluesky ハンドル欄が表示されない")
        replaceText(in: handle, with: "mock.bsky.social", in: app)

        let password = uiElement(app, "settings.twitter.bluesky.appPassword")
        XCTAssertTrue(password.waitForExistence(timeout: TestTimeout.ui), "App Password 欄が表示されない")
        replaceText(in: password, with: "app-password", in: app)

        let login = uiElement(app, "settings.twitter.bluesky.login")
        XCTAssertTrue(login.waitForExistence(timeout: TestTimeout.ui), "ログインボタンがない")
        tapWhenHittable(login, in: app)

        XCTAssertTrue(
            uiElement(app, "settings.twitter.account.bluesky.1").waitForExistence(timeout: TestTimeout.ui),
            "連携した Bluesky アカウントが表示されない"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("bluesky_auth_count") >= 1
            },
            "Bluesky アカウントがサーバーで連携されていない"
        )
    }

    /// Opens the Twitter tab of the live player's panel.
    private func openTwitterPanel(in app: XCUIApplication) {
        let tab = uiElement(app, "panel.twitter")
        XCTAssertTrue(tab.waitForExistence(timeout: TestTimeout.ui), "Twitter タブが表示されない")
        tapWhenHittable(tab, in: app)

        XCTAssertTrue(
            uiElement(app, "twitter.panel").waitForExistence(timeout: TestTimeout.ui),
            "Twitter パネルが表示されない"
        )
    }

    private func selectSubTab(_ identifier: String, in app: XCUIApplication) {
        let button = uiElement(app, identifier)
        XCTAssertTrue(button.waitForExistence(timeout: TestTimeout.ui), "\(identifier) がない")
        tapWhenHittable(button, in: app)
    }

    private func compose(in app: XCUIApplication, text: String) {
        let field = uiElement(app, "twitter.compose.text")
        XCTAssertTrue(field.waitForExistence(timeout: TestTimeout.ui), "ツイート本文欄が表示されない")
        replaceText(in: field, with: text, in: app)
    }

    private func send(in app: XCUIApplication) {
        let send = uiElement(app, "twitter.compose.send")
        XCTAssertTrue(send.waitForExistence(timeout: TestTimeout.ui), "送信ボタンがない")
        tapWhenHittable(send, in: app)
    }

    private func postedTweets() -> [[String: Any]] {
        (MockServerControl.stats()["twitter_posted_tweets"] as? [[String: Any]]) ?? []
    }

    // MARK: - Settings

    func testAddAndRemoveBlueskyAccountInSettings() {
        let app = startApp()
        openSection(.settings, in: app)
        login(in: app)

        linkBlueskyAccount(in: app)

        // The account can be unlinked again from the same screen.
        let remove = uiElement(app, "settings.twitter.account.bluesky.1.delete")
        XCTAssertTrue(remove.waitForExistence(timeout: TestTimeout.ui), "連携解除ボタンがない")
        tapWhenHittable(remove, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("bluesky_account_delete_count") >= 1
            },
            "Bluesky アカウントの連携が解除されていない"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                !uiElement(app, "settings.twitter.account.bluesky.1").exists
            },
            "連携解除後もアカウントが表示されている"
        )
    }

    // MARK: - Posting

    func testPostTweetWithChannelHashtag() {
        let app = startApp(disableAutoPiP: true)
        openSection(.settings, in: app)
        login(in: app)
        linkTwitterAccount(in: app)

        openLive(in: app)
        openTwitterPanel(in: app)

        // The station hashtag of NHK総合 is added automatically.
        let hashtag = uiElement(app, "twitter.compose.hashtag")
        XCTAssertTrue(hashtag.waitForExistence(timeout: TestTimeout.ui), "ハッシュタグ欄がない")
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                ((hashtag.value as? String) ?? "").contains("#nhk")
            },
            "局タグが自動で入力されていない (\(hashtag.value ?? "nil"))"
        )

        compose(in: app, text: "tweet-test")
        send(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) { !self.postedTweets().isEmpty },
            "ツイートがサーバーに届いていない"
        )
        let posted = postedTweets().last
        XCTAssertEqual(posted?["text"] as? String, "tweet-test #nhk")
        XCTAssertEqual(posted?["image_count"] as? Int, 0)
    }

    func testPostTweetWithCaptureAttached() {
        let app = startApp(disableAutoPiP: true)
        openSection(.settings, in: app)
        login(in: app)
        linkTwitterAccount(in: app)

        openLive(in: app)

        // Take a capture first; the panel offers this session's captures.
        let capture = uiElement(app, "player.capture")
        XCTAssertTrue(capture.waitForExistence(timeout: TestTimeout.ui), "キャプチャボタンがない")
        tapWhenHittable(capture, in: app)
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) {
                (intLabel(of: "capture.count", in: app) ?? 0) >= 1
            },
            "キャプチャが生成されない"
        )

        openTwitterPanel(in: app)
        selectSubTab("twitter.tab.capture", in: app)

        let cell = uiElement(app, "twitter.capture.0")
        XCTAssertTrue(cell.waitForExistence(timeout: TestTimeout.ui), "キャプチャが一覧に表示されない")
        tapWhenHittable(cell, in: app)

        compose(in: app, text: "capture-test")
        send(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) { !self.postedTweets().isEmpty },
            "ツイートがサーバーに届いていない"
        )
        let posted = postedTweets().last
        XCTAssertEqual(posted?["image_count"] as? Int, 1, "キャプチャが 1 枚添付されていない")
        let imageSizes = (posted?["image_sizes"] as? [Any]) ?? []
        XCTAssertEqual(imageSizes.count, 1, "画像が 1 枚だけ送られていない")
        XCTAssertGreaterThan(
            (imageSizes.first as? NSNumber)?.intValue ?? 0,
            0,
            "画像のバイト列が送られていない"
        )
    }

    // MARK: - Timeline and search

    func testTimelineShowsTweetsAndFavoriteToggles() {
        let app = startApp(disableAutoPiP: true)
        openSection(.settings, in: app)
        login(in: app)
        linkTwitterAccount(in: app)

        openLive(in: app)
        openTwitterPanel(in: app)
        selectSubTab("twitter.tab.timeline", in: app)

        let row = uiElement(app, "twitter.tweet.tweet-1001")
        XCTAssertTrue(row.waitForExistence(timeout: TestTimeout.ui), "タイムラインにツイートが表示されない")

        let favorite = uiElement(app, "twitter.tweet.tweet-1001.favorite")
        XCTAssertTrue(favorite.waitForExistence(timeout: TestTimeout.ui), "いいねボタンがない")
        XCTAssertEqual(favorite.value as? String, "false")
        tapWhenHittable(favorite, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("twitter_favorite_count") >= 1
            },
            "いいねがサーバーに送られていない"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                (uiElement(app, "twitter.tweet.tweet-1001.favorite").value as? String) == "true"
            },
            "いいねの状態が変わらない"
        )
    }

    func testSearchTabSearchesTheChannelHashtag() {
        let app = startApp(disableAutoPiP: true)
        openSection(.settings, in: app)
        login(in: app)
        linkTwitterAccount(in: app)

        openLive(in: app)
        openTwitterPanel(in: app)
        selectSubTab("twitter.tab.search", in: app)

        let field = uiElement(app, "twitter.search.field")
        XCTAssertTrue(field.waitForExistence(timeout: TestTimeout.ui), "検索欄が表示されない")
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                ((field.value as? String) ?? "").contains("#nhk")
            },
            "チャンネルのハッシュタグが検索欄に入っていない (\(field.value ?? "nil"))"
        )

        // The mock returns the #nhk fixtures.
        XCTAssertTrue(
            uiElement(app, "twitter.tweet.tweet-1001").waitForExistence(timeout: TestTimeout.ui),
            "検索結果が表示されない"
        )
    }
}
