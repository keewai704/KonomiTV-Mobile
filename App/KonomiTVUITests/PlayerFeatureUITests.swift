import XCTest

/// プレイヤー: 画質プロファイル、master プレイリスト、ライブ状態、チャンネル
/// パネル、シーンサムネイル。
final class PlayerFeatureUITests: KonomiTVUITestCase {
    private func statsString(_ key: String) -> String? {
        MockServerControl.stats()[key] as? String
    }

    private func openLive(in app: XCUIApplication, channelID: String = "gr011") {
        openSection(.live, in: app)
        let channel = uiElement(app, "live.channel.\(channelID)")
        XCTAssertTrue(channel.waitForExistence(timeout: TestTimeout.ui), "ライブチャンネルが表示されない")
        channel.tap()
        waitForPlaying(in: app)
    }

    private func openVideo(in app: XCUIApplication) {
        openSection(.videos, in: app)
        let item = uiElement(app, "videos.recent.1")
        XCTAssertTrue(item.waitForExistence(timeout: TestTimeout.ui), "先頭のビデオが表示されない")
        item.tap()
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

    /// Chooses an item from a SwiftUI Picker / Menu that may be shown as a
    /// button, a cell or a plain text depending on the iOS version.
    private func tapOption(_ title: String, in app: XCUIApplication) {
        let button = app.buttons[title]
        if button.waitForExistence(timeout: 3) {
            tapWhenHittable(button, in: app)
            return
        }

        let text = app.staticTexts[title]
        if text.waitForExistence(timeout: 3) {
            tapWhenHittable(text, in: app)
            return
        }

        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 3), "選択肢「\(title)」が見つからない")
        tapWhenHittable(cell, in: app)
    }

    // MARK: - Quality profile

    func testDataSaverAndQualityApplyToLiveStream() {
        let app = startApp()
        openSection(.settings, in: app)

        let qualityLink = uiElement(app, "settings.quality")
        XCTAssertTrue(qualityLink.waitForExistence(timeout: TestTimeout.ui), "画質の設定が表示されない")
        tapWhenHittable(qualityLink, in: app)

        let picker = uiElement(app, "settings.tvQuality")
        XCTAssertTrue(picker.waitForExistence(timeout: TestTimeout.ui), "テレビの画質設定が表示されない")
        tapWhenHittable(picker, in: app)
        tapOption("540p", in: app)

        let dataSaver = uiElement(app, "settings.tvDataSaver")
        XCTAssertTrue(dataSaver.waitForExistence(timeout: TestTimeout.ui), "データ節約モードが表示されない")
        tapWhenHittable(dataSaver, in: app)

        openLive(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) {
                self.statsString("last_live_quality") == "540p-hevc"
            },
            "ライブ配信の画質が 540p-hevc にならない (\(statsString("last_live_quality") ?? "nil"))"
        )
    }

    // MARK: - Recorded video

    func testRecordedVideoUsesMasterPlaylistAndSwitchesQuality() {
        let app = startApp()
        openVideo(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                self.statsString("last_video_playlist_type") == "master"
            },
            "録画ビデオが master プレイリストを要求していない (\(statsString("last_video_playlist_type") ?? "nil"))"
        )

        let qualityMenu = uiElement(app, "player.quality")
        XCTAssertTrue(qualityMenu.waitForExistence(timeout: TestTimeout.ui), "画質メニューが表示されない")
        tapWhenHittable(qualityMenu, in: app)
        tapOption("360p", in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) {
                self.statsString("last_video_quality")?.hasPrefix("360p") == true
            },
            "画質切り替え後も 360p が要求されない (\(statsString("last_video_quality") ?? "nil"))"
        )
    }

    // MARK: - Live status

    func testLiveStatusBecomesOnAir() {
        let app = startApp()
        openLive(in: app)

        let status = uiElement(app, "live.status")
        XCTAssertTrue(status.waitForExistence(timeout: TestTimeout.ui), "ライブ状態が取得できない")
        XCTAssertTrue(
            waitForLabel(status, equals: "ONAir", timeout: TestTimeout.playback),
            "ライブ状態が ONAir にならない (現在: \(status.label))"
        )
    }

    // MARK: - Channel panel

    func testChannelPanelSwitchesLiveChannel() {
        let app = startApp()
        openLive(in: app)

        let channelTab = uiElement(app, "panel.channel")
        XCTAssertTrue(channelTab.waitForExistence(timeout: TestTimeout.ui), "チャンネルタブが表示されない")
        tapWhenHittable(channelTab, in: app)

        let row = uiElement(app, "panel.channel.gr021")
        XCTAssertTrue(scrollUntilVisible(row, in: app.scrollViews.firstMatch), "チャンネル行が表示されない")
        tapWhenHittable(row, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) {
                app.navigationBars.staticTexts["NHK Eテレ"].exists
            },
            "チャンネル切り替え後にタイトルが変わらない"
        )
        waitForPlaying(in: app)
    }

    // MARK: - Scene strip

    func testSceneStripSeeksRecordedVideo() {
        let app = startApp()
        openVideo(in: app)

        let scene = uiElement(app, "video.scene.2")
        XCTAssertTrue(scene.waitForExistence(timeout: TestTimeout.ui), "シーンサムネイルが表示されない")

        let target = Double(scene.value as? String ?? "") ?? 20
        tapWhenHittable(scene, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                (intLabel(of: "playback.position", in: app) ?? -1) >= Int(target) - 2
            },
            "シーンをタップしても再生位置が \(Int(target)) 秒付近にならない (現在: \(label(of: "playback.position", in: app)) 秒)"
        )
    }
}
