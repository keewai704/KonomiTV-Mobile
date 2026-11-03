import XCTest

/// オフライン保存: saving a recorded program, playing it without the server,
/// deleting it, the failure path of a truncated stream and the old server that
/// has no offline save stream.
final class OfflineUITests: KonomiTVUITestCase {
    // MARK: - Save and play

    func testSaveVideoAppearsInOfflineListAndPlays() {
        let app = startApp()
        saveVideo(in: app)

        // The detail screen shows the running save while it downloads.
        XCTAssertTrue(
            uiElement(app, "video.offline.progress").waitForExistence(timeout: TestTimeout.playback),
            "保存の進捗が表示されない"
        )

        openSection(.offline, in: app)

        let row = uiElement(app, "offline.video.1")
        XCTAssertTrue(
            row.waitForExistence(timeout: TestTimeout.playback),
            "保存したビデオがオフライン一覧に表示されない"
        )
        XCTAssertTrue(
            uiElement(app, "offline.storage").waitForExistence(timeout: TestTimeout.ui),
            "保存容量が表示されない"
        )

        row.tap()

        let state = uiElement(app, "player.state")
        XCTAssertTrue(
            state.waitForExistence(timeout: TestTimeout.playback),
            "オフライン再生の状態が取得できない"
        )
        XCTAssertTrue(
            waitForLabel(state, equals: "playing", timeout: TestTimeout.playback),
            "保存したビデオが再生されない (状態: \(state.label))"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) {
                (intLabel(of: "playback.position", in: app) ?? 0) >= 2
            },
            "オフライン再生の位置が進まない"
        )
    }

    // MARK: - Delete

    func testDeleteSavedVideo() {
        let app = startApp()
        saveVideo(in: app)

        openSection(.offline, in: app)

        let row = uiElement(app, "offline.video.1")
        XCTAssertTrue(
            row.waitForExistence(timeout: TestTimeout.playback),
            "保存したビデオがオフライン一覧に表示されない"
        )

        row.swipeLeft()
        // Swipe actions can lose their identifier on some iOS versions, so fall
        // back to the label of the action.
        let identifiedDelete = uiElement(app, "offline.video.1.delete")
        if waitUntil(timeout: 5, { identifiedDelete.exists && identifiedDelete.isHittable }) {
            identifiedDelete.tap()
        } else {
            let labelledDelete = app.buttons["削除"]
            XCTAssertTrue(labelledDelete.waitForExistence(timeout: TestTimeout.ui), "削除ボタンが表示されない")
            labelledDelete.tap()
        }

        tapConfirmation("offline.delete.confirm", label: "削除", in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { !uiElement(app, "offline.video.1").exists },
            "削除したビデオが一覧に残っている"
        )
    }

    // MARK: - Failure

    func testTruncatedStreamShowsFailureWithRetry() {
        XCTAssertEqual(
            MockServerControl.setOfflineStreamTruncation(true),
            200,
            "モックサーバーの切り捨て設定を変更できない"
        )
        let app = startApp()
        saveVideo(in: app)

        openSection(.offline, in: app)

        let error = uiElement(app, "video.offline.error")
        XCTAssertTrue(
            error.waitForExistence(timeout: TestTimeout.playback),
            "途中で切れた保存の失敗理由が表示されない"
        )
        XCTAssertTrue(
            uiElement(app, "video.offline.retry").waitForExistence(timeout: TestTimeout.ui),
            "失敗した保存の再試行ボタンが表示されない"
        )
        XCTAssertFalse(
            uiElement(app, "offline.video.1").exists,
            "失敗した保存が保存済みとして表示されている"
        )
    }

    // MARK: - Old server

    func testOldServerHidesOfflineSaveAction() {
        XCTAssertEqual(
            MockServerControl.setOfflineStream(false),
            200,
            "モックサーバーを 0.15 未満の挙動にできない"
        )
        let app = startApp()
        openSection(.videos, in: app)

        let item = uiElement(app, "videos.recent.1")
        XCTAssertTrue(item.waitForExistence(timeout: TestTimeout.ui), "先頭のビデオが表示されない")
        item.tap()

        let menu = uiElement(app, "video.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: TestTimeout.ui), "ビデオのメニューが表示されない")
        menu.tap()

        XCTAssertTrue(
            uiElement(app, "video.menu.download").waitForExistence(timeout: TestTimeout.ui),
            "ビデオのメニューが開かない"
        )
        XCTAssertFalse(
            uiElement(app, "video.offline.save").exists,
            "オフライン保存に対応していないサーバーで保存の項目が表示されている"
        )
    }

    // MARK: - Helpers

    /// Taps the destructive button of a confirmation dialog: by identifier
    /// when SwiftUI keeps it, by label otherwise.
    private func tapConfirmation(
        _ identifier: String,
        label: String,
        in app: XCUIApplication
    ) {
        let identified = uiElement(app, identifier)
        if identified.waitForExistence(timeout: 5), identified.isHittable {
            identified.tap()
            return
        }

        let labelled = app.buttons.matching(NSPredicate(format: "label == %@", label))
        for index in 0..<labelled.count {
            let button = labelled.element(boundBy: index)
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }

        XCTFail("確認ダイアログの「\(label)」ボタンが見つからない")
    }

    /// Opens the first recorded program, picks 720p in the offline save sheet
    /// and starts the save.
    private func saveVideo(in app: XCUIApplication) {
        openSection(.videos, in: app)

        let item = uiElement(app, "videos.recent.1")
        XCTAssertTrue(item.waitForExistence(timeout: TestTimeout.ui), "先頭のビデオが表示されない")
        item.tap()

        let menu = uiElement(app, "video.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: TestTimeout.ui), "ビデオのメニューが表示されない")
        menu.tap()

        let save = uiElement(app, "video.offline.save")
        XCTAssertTrue(save.waitForExistence(timeout: TestTimeout.ui), "オフライン保存の項目が表示されない")
        tapMenuItem(save)

        let quality = uiElement(app, "video.offline.quality.720p")
        XCTAssertTrue(quality.waitForExistence(timeout: TestTimeout.ui), "保存画質が表示されない")
        tapWhenHittable(quality, in: app)
    }
}
