import XCTest

/// ビデオ: home sections, My List, watch history, settings sync and the admin
/// recording operations.
final class LibraryUITests: KonomiTVUITestCase {
    // MARK: - Videos home

    func testVideosHomeSectionsAndSortMenu() {
        let app = startApp()
        openSection(.videos, in: app)

        XCTAssertTrue(
            uiElement(app, "videos.home").waitForExistence(timeout: TestTimeout.ui),
            "ビデオホームが表示されない"
        )
        XCTAssertTrue(
            uiElement(app, "videos.recent.1").waitForExistence(timeout: TestTimeout.ui),
            "新着の録画番組が表示されない"
        )
        XCTAssertFalse(
            uiElement(app, "videos.more.history").exists,
            "視聴履歴が空なのにセクションが表示されている"
        )
        XCTAssertFalse(
            uiElement(app, "videos.more.mylist").exists,
            "マイリストが空なのにセクションが表示されている"
        )

        let more = uiElement(app, "videos.more.recent")
        XCTAssertTrue(more.waitForExistence(timeout: TestTimeout.ui), "もっと見るが表示されない")
        more.tap()

        XCTAssertTrue(
            uiElement(app, "videos.grid").waitForExistence(timeout: TestTimeout.ui),
            "もっと見るで録画番組一覧が開かない"
        )
        XCTAssertTrue(
            uiElement(app, "videos.item.1").waitForExistence(timeout: TestTimeout.ui),
            "新しい順の先頭のビデオが表示されない"
        )

        let sortMenu = uiElement(app, "videos.sort")
        XCTAssertTrue(sortMenu.waitForExistence(timeout: TestTimeout.ui), "並び順メニューが表示されない")
        sortMenu.tap()

        let oldest = app.buttons["古い順"]
        XCTAssertTrue(oldest.waitForExistence(timeout: TestTimeout.ui), "「古い順」の項目が表示されない")
        oldest.tap()

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                uiElement(app, "videos.item.35").exists && !uiElement(app, "videos.item.1").exists
            },
            "古い順に切り替えても先頭のビデオが変わらない"
        )
    }

    // MARK: - My List

    func testMylistToggleAddsAndRemovesVideo() {
        let app = startApp()
        openSection(.videos, in: app)

        let recent = uiElement(app, "videos.recent.1")
        XCTAssertTrue(recent.waitForExistence(timeout: TestTimeout.ui), "新着の録画番組が表示されない")
        recent.tap()

        let mylistButton = uiElement(app, "video.mylist")
        XCTAssertTrue(mylistButton.waitForExistence(timeout: TestTimeout.ui), "マイリストボタンが表示されない")
        XCTAssertEqual(mylistButton.label, "マイリストに追加", "マイリスト未登録時のラベルが想定と異なる")
        mylistButton.tap()

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                uiElement(app, "video.mylist").label == "マイリストから削除"
            },
            "マイリストに追加できない"
        )

        openSection(.mylist, in: app)

        let item = uiElement(app, "mylist.item.1")
        XCTAssertTrue(item.waitForExistence(timeout: TestTimeout.ui), "追加したビデオがマイリストに表示されない")
        item.tap()

        let toggle = uiElement(app, "video.mylist")
        XCTAssertTrue(toggle.waitForExistence(timeout: TestTimeout.ui), "詳細画面のマイリストボタンが表示されない")
        XCTAssertEqual(toggle.label, "マイリストから削除", "マイリスト登録済みのラベルが想定と異なる")
        toggle.tap()

        navigateBack(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { !uiElement(app, "mylist.item.1").exists },
            "マイリストから削除しても一覧に残っている"
        )
    }

    // MARK: - Watch history

    func testWatchedHistoryRecordsPlayback() {
        let app = startApp(disableAutoPiP: true, shortHistoryThreshold: true)
        openSection(.videos, in: app)

        let recent = uiElement(app, "videos.recent.1")
        XCTAssertTrue(recent.waitForExistence(timeout: TestTimeout.ui), "新着の録画番組が表示されない")
        recent.tap()

        let state = uiElement(app, "player.state")
        XCTAssertTrue(state.waitForExistence(timeout: TestTimeout.playback), "再生状態が取得できない")
        XCTAssertTrue(
            waitForLabel(state, equals: "playing", timeout: TestTimeout.playback),
            "再生が playing にならない (状態: \(state.label))"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) {
                (intLabel(of: "playback.position", in: app) ?? 0) >= 4
            },
            "再生位置が進まない"
        )

        navigateBack(in: app)

        // Leaving the player stops playback, which stores the final position in
        // the watch history before the history screen is opened.
        XCTAssertTrue(
            waitForLabel(
                uiElement(app, "playback.state"),
                equals: "idle",
                timeout: TestTimeout.ui
            ),
            "詳細画面を離れても再生が停止しない"
        )

        openSection(.history, in: app)
        XCTAssertTrue(
            uiElement(app, "history.item.1").waitForExistence(timeout: TestTimeout.ui),
            "再生したビデオが視聴履歴に表示されない"
        )
    }

    // MARK: - Settings sync

    func testSettingsSyncUploadsMylistChange() {
        let app = startApp()
        openSection(.settings, in: app)
        login(in: app)

        openSection(.videos, in: app)

        let recent = uiElement(app, "videos.recent.1")
        XCTAssertTrue(recent.waitForExistence(timeout: TestTimeout.ui), "新着の録画番組が表示されない")
        recent.tap()

        let mylistButton = uiElement(app, "video.mylist")
        XCTAssertTrue(mylistButton.waitForExistence(timeout: TestTimeout.ui), "マイリストボタンが表示されない")
        mylistButton.tap()

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("settings_put_count") >= 1
            },
            "マイリストの変更がサーバーに同期されない"
        )
    }

    // MARK: - Admin

    func testAdminDeletesRecordingFromVideoDetail() {
        let app = startApp()
        openSection(.settings, in: app)
        login(in: app)

        openSection(.videos, in: app)

        let recent = uiElement(app, "videos.recent.1")
        XCTAssertTrue(recent.waitForExistence(timeout: TestTimeout.ui), "新着の録画番組が表示されない")
        recent.tap()

        XCTAssertTrue(
            uiElement(app, "video.detail.title").waitForExistence(timeout: TestTimeout.ui),
            "詳細画面が表示されない"
        )

        let menu = uiElement(app, "video.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: TestTimeout.ui), "メニューが表示されない")
        menu.tap()

        let deleteItem = uiElement(app, "video.menu.delete")
        XCTAssertTrue(deleteItem.waitForExistence(timeout: TestTimeout.ui), "削除メニューが表示されない")
        tapMenuItem(deleteItem)

        tapDeleteConfirmation(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { !uiElement(app, "video.detail.title").exists },
            "削除後に詳細画面が閉じない"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("video_delete_count") >= 1
            },
            "録画ファイルがサーバーで削除されていない"
        )
    }

    /// Taps the destructive button of the delete confirmation dialog (the
    /// identifier is applied to the SwiftUI button; alert-style buttons are
    /// found by their label).
    private func tapDeleteConfirmation(in app: XCUIApplication) {
        let identified = uiElement(app, "video.delete.confirm")
        if identified.waitForExistence(timeout: 5), identified.isHittable {
            identified.tap()
            return
        }

        let labelled = app.buttons.matching(
            NSPredicate(format: "label == %@", "録画ファイルを削除")
        )
        for index in 0..<labelled.count {
            let button = labelled.element(boundBy: index)
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }

        XCTFail("録画ファイル削除の確認ボタンが見つからない")
    }
}
