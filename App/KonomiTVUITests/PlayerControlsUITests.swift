import XCTest

/// プレイヤーの操作パネル: タップでの表示切り替えと自動非表示、再生／一時停止、
/// シークバー、ライブのライブボタン。
///
/// 再生はアプリ全体で 1 台の PlaybackController（VLCKit）が所有する。
final class PlayerControlsUITests: KonomiTVUITestCase {
    // MARK: - Visibility

    func testControlsAppearOnTapAndHideWhilePlaying() {
        let app = startApp()
        openVideo(in: app)

        let controls = uiElement(app, "player.controls")
        // The controls hide themselves a few seconds after playback starts
        // (8 s under UI testing).
        XCTAssertTrue(
            waitUntil(timeout: 15) { !controls.exists },
            "再生中にコントロールが自動的に隠れない"
        )

        tapSurface(in: app)
        XCTAssertTrue(
            controls.waitForExistence(timeout: TestTimeout.ui),
            "映像をタップしてもコントロールが表示されない"
        )

        XCTAssertTrue(
            waitUntil(timeout: 15) { !controls.exists },
            "表示したコントロールが自動的に隠れない"
        )
    }

    func testControlsStayVisibleWhilePaused() {
        let app = startApp()
        openVideo(in: app)
        revealControls(in: app)

        tapControl("player.playPause", in: app)

        let state = uiElement(app, "player.state")
        XCTAssertTrue(
            waitForLabel(state, equals: "paused", timeout: TestTimeout.ui),
            "一時停止しても状態が paused にならない (状態: \(state.label))"
        )
        waitSeconds(10)
        XCTAssertTrue(
            uiElement(app, "player.controls").exists,
            "一時停止中にコントロールが隠れた"
        )
    }

    // MARK: - Transport

    func testPlayPauseTogglesPlaybackState() {
        let app = startApp()
        openVideo(in: app)
        revealControls(in: app)

        let state = uiElement(app, "player.state")

        tapControl("player.playPause", in: app)
        XCTAssertTrue(
            waitForLabel(state, equals: "paused", timeout: TestTimeout.ui),
            "再生／一時停止ボタンで paused にならない (状態: \(state.label))"
        )

        revealControls(in: app)
        tapControl("player.playPause", in: app)
        XCTAssertTrue(
            waitForLabel(state, equals: "playing", timeout: TestTimeout.playback),
            "再生／一時停止ボタンで playing に戻らない (状態: \(state.label))"
        )
    }

    func testSeekBarMovesPlaybackPosition() {
        let app = startApp()
        openVideo(in: app)

        // The seek bar spans the whole recording, so its length has to be known
        // before the normalized position means anything.
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) {
                (intLabel(of: "playback.duration", in: app) ?? 0) >= 60
            },
            "録画ビデオの長さが取得できない (長さ: \(label(of: "playback.duration", in: app)) 秒)"
        )

        revealControls(in: app)
        let seekBar = uiElement(app, "player.seekBar")
        XCTAssertTrue(seekBar.waitForExistence(timeout: TestTimeout.ui), "シークバーが表示されない")

        seekBar.adjust(toNormalizedSliderPosition: 0.5)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) {
                (intLabel(of: "playback.position", in: app) ?? -1) >= 30
            },
            "シークバーを動かしても再生位置が進まない (現在: \(label(of: "playback.position", in: app)) 秒)"
        )
    }

    func testSkipButtonsMoveRecordedVideo() {
        let app = startApp()
        openVideo(in: app)
        revealControls(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) {
                (intLabel(of: "playback.position", in: app) ?? 0) >= 3
            },
            "再生位置が進まない"
        )
        let before = intLabel(of: "playback.position", in: app) ?? 0

        tapControl("player.skipForward", in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                (intLabel(of: "playback.position", in: app) ?? -1) >= before + 8
            },
            "10秒進むボタンで再生位置が進まない (前: \(before) 秒, 現在: \(label(of: "playback.position", in: app)) 秒)"
        )
    }

    // MARK: - Live

    func testLiveShowsLiveEdgeButtonInsteadOfSeekBar() {
        let app = startApp()
        openLive(in: app)
        revealControls(in: app)

        XCTAssertTrue(
            uiElement(app, "player.liveEdge").waitForExistence(timeout: TestTimeout.ui),
            "ライブにライブボタンがない"
        )
        XCTAssertFalse(uiElement(app, "player.seekBar").exists, "ライブにシークバーがある")
        XCTAssertFalse(uiElement(app, "player.skipForward").exists, "ライブにスキップボタンがある")
    }

    // MARK: - Helpers

    private func openVideo(in app: XCUIApplication) {
        openSection(.videos, in: app)

        let item = uiElement(app, "videos.recent.1")
        XCTAssertTrue(item.waitForExistence(timeout: TestTimeout.ui), "先頭のビデオが表示されない")
        item.tap()

        waitForPlaying(in: app)
    }

    private func openLive(in app: XCUIApplication) {
        openSection(.live, in: app)

        let channel = uiElement(app, "live.channel.gr011")
        XCTAssertTrue(channel.waitForExistence(timeout: TestTimeout.ui), "地上波チャンネルが表示されない")
        channel.tap()

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

    /// Brings the controls up with a fresh auto-hide timer. Controls already
    /// on screen may be about to hide (the timer started when playback began),
    /// so they are hidden first; a tap on the picture toggles them.
    private func revealControls(in app: XCUIApplication) {
        let controls = uiElement(app, "player.controls")
        if controls.exists {
            tapSurface(in: app)
            _ = waitUntil(timeout: 2) { !controls.exists }
        }
        for _ in 0..<3 {
            if !controls.exists {
                tapSurface(in: app)
            }
            if controls.waitForExistence(timeout: 2) {
                return
            }
        }
        XCTAssertTrue(controls.exists, "再生コントロールが表示されない")
    }

    /// Shows the controls and taps one of them straight away, before they hide
    /// themselves again.
    private func tapControl(_ identifier: String, in app: XCUIApplication) {
        let control = uiElement(app, identifier)
        for _ in 0..<3 {
            revealControls(in: app)
            if control.exists, control.isHittable {
                control.tap()
                return
            }
        }
        XCTFail("\(identifier) をタップできない")
    }

    /// Taps the middle of the picture; the controls only occupy the top and the
    /// bottom rows, so the centre stays free.
    private func tapSurface(in app: XCUIApplication) {
        let surface = uiElement(app, "player.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: TestTimeout.ui), "映像のタップ領域がない")
        surface.tap()
    }
}
