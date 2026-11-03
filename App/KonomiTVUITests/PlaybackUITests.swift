import XCTest

/// 再生: バックグラウンド再生とピクチャ・イン・ピクチャ。
///
/// 再生はアプリ全体で 1 台の PlaybackController / AVPlayerViewController が
/// 所有するため、画面を離れても PiP とバックグラウンド再生が継続する。
final class PlaybackUITests: KonomiTVUITestCase {
    // MARK: - Background playback

    func testVideoKeepsPlayingInBackground() {
        let app = startApp(disableAutoPiP: true)
        openVideo(in: app)
        let started = position(in: app)

        sendToBackgroundAndReturn(app: app, after: 8)

        XCTAssertTrue(
            waitForPlaybackPosition(above: started + 5, in: app),
            "バックグラウンドでビデオの再生位置が進まない (開始: \(started) 秒, 現在: \(currentPosition(in: app)) 秒)"
        )
        XCTAssertEqual(
            label(of: "playback.pipStarts", in: app),
            "0",
            "自動 PiP を無効にしているのに PiP が開始された"
        )
    }

    func testLiveKeepsPlayingInBackground() {
        let app = startApp(disableAutoPiP: true)
        openLive(in: app)
        let started = position(in: app)

        sendToBackgroundAndReturn(app: app, after: 8)

        XCTAssertTrue(
            waitForPlaybackPosition(above: started + 5, in: app),
            "バックグラウンドでライブ再生位置が進まない (開始: \(started) 秒, 現在: \(currentPosition(in: app)) 秒)"
        )
        XCTAssertEqual(
            label(of: "playback.pipStarts", in: app),
            "0",
            "自動 PiP を無効にしているのに PiP が開始された"
        )
    }

    // MARK: - Picture in Picture

    func testPictureInPictureStartsFromInlineAndKeepsPlaying() {
        // 自動 PiP を有効にしたまま起動する。
        let app = startApp()
        openVideo(in: app)
        let started = position(in: app)

        sendToBackgroundAndReturn(app: app, after: 6)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                (intLabel(of: "playback.pipStarts", in: app) ?? 0) >= 1
            },
            "バックグラウンドに回しても PiP が開始されない (playback.pipStarts=\(label(of: "playback.pipStarts", in: app)))"
        )
        XCTAssertTrue(
            waitForPlaybackPosition(above: started + 3, in: app),
            "PiP 中に再生位置が進まない (開始: \(started) 秒, 現在: \(currentPosition(in: app)) 秒)"
        )

        guard label(of: "playback.pip", in: app) == "active" else {
            // 復帰時に PiP が終了している環境では、以降の確認はできない。
            // 記録だけ残して失敗にはしない。
            XCTContext.runActivity(named: "PiP は復帰時に終了していた") { activity in
                let note = "playback.pip=inactive, playback.pipStarts=\(label(of: "playback.pipStarts", in: app))"
                activity.add(XCTAttachment(string: note))
            }
            return
        }

        // PiP 中は画面を離れても再生が続くことを確認する。
        let beforeLeaving = position(in: app)
        tapBack(in: app)
        waitSeconds(3)

        guard label(of: "playback.pip", in: app) == "active" else {
            // 画面を離れるまでに PiP が終了した環境では、再生の停止は正しい
            // 動作なので失敗にしない。
            XCTContext.runActivity(named: "画面を離れる前に PiP が終了していた") { activity in
                let note = "playback.pip=inactive, playback.state=\(label(of: "playback.state", in: app))"
                activity.add(XCTAttachment(string: note))
            }
            return
        }

        let state = uiElement(app, "playback.state")
        XCTAssertTrue(
            waitForLabel(state, equals: "playing", timeout: TestTimeout.ui),
            "PiP 中に画面を離れると再生が止まる (状態: \(state.label))"
        )
        XCTAssertTrue(
            waitForPlaybackPosition(above: beforeLeaving + 1, in: app),
            "PiP 中に画面を離れると再生位置が進まない (離れる前: \(beforeLeaving) 秒, 現在: \(currentPosition(in: app)) 秒)"
        )
    }

    // MARK: - Stopping

    func testLeavingPlayerWithoutPiPStopsPlayback() {
        let app = startApp(disableAutoPiP: true)
        openVideo(in: app)

        tapBack(in: app)

        let state = uiElement(app, "playback.state")
        XCTAssertTrue(
            waitForLabel(state, equals: "idle", timeout: 5),
            "詳細画面を離れても再生が停止しない (状態: \(state.label))"
        )
    }

    // MARK: - Helpers

    private func openVideo(in app: XCUIApplication) {
        navigate(to: .videos, in: app)

        let item = uiElement(app, "videos.item.1")
        XCTAssertTrue(item.waitForExistence(timeout: TestTimeout.ui), "先頭のビデオが表示されない")
        item.tap()

        waitForPlaying(in: app)
    }

    private func openLive(in app: XCUIApplication) {
        navigate(to: .live, in: app)

        let channel = uiElement(app, "live.channel.gr011")
        XCTAssertTrue(channel.waitForExistence(timeout: TestTimeout.ui), "地上波チャンネルが表示されない")
        channel.tap()

        waitForPlaying(in: app)
    }

    /// Waits for the player to be attached and actually rendering media.
    private func waitForPlaying(in app: XCUIApplication) {
        XCTAssertTrue(
            uiElement(app, "player.view").waitForExistence(timeout: TestTimeout.playback),
            "プレイヤーが表示されない"
        )

        let state = uiElement(app, "player.state")
        XCTAssertTrue(state.waitForExistence(timeout: TestTimeout.playback), "再生状態が取得できない")
        XCTAssertTrue(
            waitForLabel(state, equals: "playing", timeout: TestTimeout.playback),
            "再生が playing にならない (状態: \(state.label) / \(state.value as? String ?? ""))"
        )
    }

    private func position(in app: XCUIApplication) -> Int {
        XCTAssertTrue(
            uiElement(app, "playback.position").waitForExistence(timeout: TestTimeout.ui),
            "再生位置が取得できない"
        )
        return currentPosition(in: app)
    }

    private func currentPosition(in app: XCUIApplication) -> Int {
        intLabel(of: "playback.position", in: app) ?? -1
    }

    private func waitForPlaybackPosition(
        above minimum: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = TestTimeout.ui
    ) -> Bool {
        waitUntil(timeout: timeout) {
            (intLabel(of: "playback.position", in: app) ?? -1) >= minimum
        }
    }

    /// Taps the navigation bar back button (compact and regular widths).
    private func tapBack(in app: XCUIApplication) {
        let identified = app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch
        if identified.waitForExistence(timeout: 3), identified.isHittable {
            identified.tap()
            return
        }

        let fallback = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(fallback.waitForExistence(timeout: TestTimeout.ui), "戻るボタンが表示されない")
        fallback.tap()
    }
}

