import XCTest

/// 字幕: ARIB captions (字幕) and superimpose (文字スーパー) during live and
/// recorded playback, plus the on/off toggle.
///
/// The mock server injects real caption PES packets into its live transport
/// stream and into the recorded-video segments, so these tests exercise the
/// whole pipeline (extraction, libaribcaption decoding, rendering, overlay).
final class CaptionUITests: KonomiTVUITestCase {
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

    /// Number of distinct caption images the renderer has shown.
    private func renderedCount(in app: XCUIApplication) -> Int {
        intLabel(of: "captions.renderedCount", in: app) ?? 0
    }

    func testLivePlaybackRendersCaptions() {
        let app = startApp(disableAutoPiP: true)
        openLive(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) { self.renderedCount(in: app) >= 1 },
            "ライブ再生で字幕が表示されない (renderedCount=\(renderedCount(in: app)))"
        )
    }

    func testRecordedPlaybackRendersCaptionsThroughProxy() {
        let app = startApp(disableAutoPiP: true)
        openVideo(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) { self.renderedCount(in: app) >= 1 },
            "録画ビデオで字幕が表示されない (renderedCount=\(renderedCount(in: app)))"
        )

        // The loopback proxy still asks the server for type=master, so the
        // server-side request shape (and keep-alive/session handling) is
        // unchanged.
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                (MockServerControl.stats()["last_video_playlist_type"] as? String) == "master"
            },
            "録画ビデオの master プレイリスト要求がサーバーに届いていない"
        )
    }

    func testCaptionToggleHidesCaptions() {
        let app = startApp(disableAutoPiP: true)
        openLive(in: app)

        let visible = uiElement(app, "captions.visible")
        XCTAssertTrue(visible.waitForExistence(timeout: TestTimeout.ui), "字幕の表示状態が取得できない")
        XCTAssertTrue(
            waitForLabel(visible, equals: "true", timeout: TestTimeout.ui),
            "字幕が表示状態になっていない (\(visible.label))"
        )

        let toggle = uiElement(app, "player.captions.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: TestTimeout.ui), "字幕の表示切り替えボタンがない")
        tapWhenHittable(toggle, in: app)

        XCTAssertTrue(
            waitForLabel(visible, equals: "false", timeout: TestTimeout.ui),
            "字幕の表示切り替えで非表示にならない (\(visible.label))"
        )
    }
}
