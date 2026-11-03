import XCTest

/// ビデオ: grid paging, search, detail and playback.
final class VideosUITests: KonomiTVUITestCase {
    func testVideosGridLoadsSecondPageWhenScrolled() {
        let app = startApp()
        navigate(to: .videos, in: app)

        let grid = uiElement(app, "videos.grid")
        XCTAssertTrue(grid.waitForExistence(timeout: TestTimeout.ui), "ビデオ一覧が表示されない")
        let firstItem = uiElement(app, "videos.item.1")
        XCTAssertTrue(firstItem.waitForExistence(timeout: TestTimeout.ui), "先頭のビデオが表示されない")

        // The mock server serves ids 1-30 on page 1 and 31-35 on page 2.
        let pageTwoItem = uiElement(app, "videos.item.31")
        XCTAssertTrue(
            scrollUntilVisible(pageTwoItem, in: grid),
            "スクロールしても 2 ページ目のビデオが読み込まれない"
        )
    }

    func testSearchNarrowsResults() {
        let app = startApp()
        navigate(to: .videos, in: app)

        let grid = uiElement(app, "videos.grid")
        XCTAssertTrue(grid.waitForExistence(timeout: TestTimeout.ui), "ビデオ一覧が表示されない")

        let match = uiElement(app, "videos.item.1") // ニュース7
        let nonMatch = uiElement(app, "videos.item.2") // ニュースウオッチ9
        XCTAssertTrue(match.waitForExistence(timeout: TestTimeout.ui), "検索対象のビデオが表示されない")
        XCTAssertTrue(nonMatch.waitForExistence(timeout: TestTimeout.ui), "検索対象外のビデオが表示されない")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: TestTimeout.ui), "検索フィールドが表示されない")
        searchField.tap()
        // ASCII query keeps the test independent of the simulator keyboard
        // layout; the fixture ニュース7 is the only matching title.
        searchField.typeText("7")

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { !nonMatch.exists && match.exists },
            "検索後に表示されるビデオが想定と異なる"
        )
        XCTAssertFalse(nonMatch.exists, "検索後も対象外のビデオが表示されている")
        XCTAssertTrue(match.exists, "検索結果に対象のビデオが表示されない")
    }

    func testVideoDetailShowsTitleAndPlaybackStarts() {
        let app = startApp()
        navigate(to: .videos, in: app)

        let item = uiElement(app, "videos.item.1")
        XCTAssertTrue(item.waitForExistence(timeout: TestTimeout.ui), "先頭のビデオが表示されない")
        item.tap()

        let title = uiElement(app, "video.detail.title")
        XCTAssertTrue(title.waitForExistence(timeout: TestTimeout.ui), "詳細画面のタイトルが表示されない")
        XCTAssertTrue(title.label.contains("ニュース"), "詳細タイトルが想定と異なる: \(title.label)")

        let player = uiElement(app, "player.view")
        XCTAssertTrue(player.waitForExistence(timeout: TestTimeout.playback), "プレイヤーが表示されない")

        let state = uiElement(app, "player.state")
        XCTAssertTrue(state.waitForExistence(timeout: TestTimeout.playback), "再生状態が取得できない")
        XCTAssertTrue(
            waitForLabel(state, equals: "playing", timeout: TestTimeout.playback),
            "ビデオ再生が playing にならない (現在: \(state.label))"
        )
    }
}
