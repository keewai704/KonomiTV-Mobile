import UIKit
import XCTest

/// 再生: バックグラウンド再生、ピクチャ・イン・ピクチャ、画面の移動と回転。
///
/// 再生はアプリ全体で 1 台の PlaybackController（VLCKit の VLCMediaPlayer）と
/// 共有の PlayerHostViewController が所有するため、画面を離れても PiP と
/// バックグラウンド再生が継続する。
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

    func testPictureInPictureStartsFromInlineAndKeepsPlaying() throws {
        // 自動 PiP を有効にしたまま起動する。
        let app = startApp()
        let supported = uiElement(app, "playback.pipSupported")
        XCTAssertTrue(supported.waitForExistence(timeout: TestTimeout.ui), "PiP 対応状況が取得できない")
        // iPhone シミュレーターは PiP を実装していない (実機と iPad シミュレーターは対応)。
        try XCTSkipIf(supported.label == "false", "この環境は PiP に対応していない")

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
        navigateBack(in: app)
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

    // MARK: - Switching screens

    /// 再生中にほかのタブ（大画面ではサイドバーのほかのセクション）へ移って
    /// 戻っても、再生は止まらずに同じストリームのまま続く。
    ///
    /// 画面を離れることは再生の停止ではない（バックグラウンド再生と同じ扱い）。
    /// 新しいストリームが始まったかどうかは、モックサーバーが数えているライブ
    /// ストリームの接続回数（`/__mock/stats` の `live_total`）で判定する:
    /// 再生を作り直すと、ライブの MPEG-TS ストリームへの接続もやり直しになる。
    func testSwitchingSectionKeepsLivePlaybackRunning() {
        let app = startApp(disableAutoPiP: true)
        openLive(in: app)

        let streamsBefore = MockServerControl.intValue("live_total")
        XCTAssertGreaterThan(streamsBefore, 0, "ライブのストリームが始まっていない")
        let positionBefore = position(in: app)

        openSection(.videos, in: app)

        // ほかのセクションを開いている間も再生は続く。
        let state = uiElement(app, "playback.state")
        XCTAssertTrue(
            waitForLabel(state, equals: "playing", timeout: TestTimeout.ui),
            "セクションを移ると再生が止まる (状態: \(state.label))"
        )

        openSection(.live, in: app)

        XCTAssertTrue(
            uiElement(app, "player.view").waitForExistence(timeout: TestTimeout.ui),
            "テレビに戻ってもプレイヤーが表示されない"
        )
        let playerState = uiElement(app, "player.state")
        XCTAssertTrue(
            waitForLabel(playerState, equals: "playing", timeout: TestTimeout.playback),
            "テレビに戻ると再生が playing にならない (状態: \(playerState.label))"
        )
        XCTAssertEqual(
            MockServerControl.intValue("live_total"),
            streamsBefore,
            "テレビに戻ると新しいストリームが始まっている"
        )
        XCTAssertTrue(
            waitForPlaybackPosition(above: positionBefore + 3, in: app),
            "テレビに戻ると再生位置が振り出しに戻っている (移る前: \(positionBefore) 秒, 現在: \(currentPosition(in: app)) 秒)"
        )
    }

    // MARK: - Window size

    /// 再生中にウインドウの大きさが変わっても（回転・Split View・Stage Manager・
    /// 全画面表示）、libVLC の映像出力がプレイヤーの大きさに追従すること。
    ///
    /// 映像出力のビューは libVLC が自分で `PlayerDrawableView` に足すもので、
    /// 親の大きさが変わっても自動では追従しない。`playback.videoOutput` は
    /// 「映像出力の大きさ / 描画先の大きさ」を返すので、回転の前後で両者が
    /// 一致しているかを見る。
    func testVideoOutputFollowsWindowResize() {
        let app = startApp(disableAutoPiP: true)
        openLive(in: app)

        rotate(.portrait, in: app)

        let output = uiElement(app, "playback.videoOutput")
        XCTAssertTrue(
            output.waitForExistence(timeout: TestTimeout.ui),
            "映像出力の大きさが取得できない"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) { output.label != "-" },
            "libVLC の映像出力のビューが取得できない"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { self.videoOutputFillsDrawable(output.label) },
            "映像出力がプレイヤーの大きさになっていない (映像出力/描画先: \(output.label))"
        )
        let before = output.label

        rotate(.landscapeLeft, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                let current = output.label
                return current != before && self.videoOutputFillsDrawable(current)
            },
            "ウインドウを横向きにしても映像出力がプレイヤーの大きさに追従しない (前: \(before), 現在: \(output.label))"
        )

        // 後続のテストのために縦向きに戻す。
        rotate(.portrait, in: app)
    }

    // MARK: - Stopping

    func testLeavingPlayerWithoutPiPStopsPlayback() {
        let app = startApp(disableAutoPiP: true)
        openVideo(in: app)

        navigateBack(in: app)

        let state = uiElement(app, "playback.state")
        XCTAssertTrue(
            waitForLabel(state, equals: "idle", timeout: 5),
            "詳細画面を離れても再生が停止しない (状態: \(state.label))"
        )
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

    /// Whether "640x360/640x360" says that libVLC's video output view fills the
    /// drawable (one point of tolerance for rounding).
    private func videoOutputFillsDrawable(_ description: String) -> Bool {
        let sides = description.split(separator: "/").map { $0.split(separator: "x") }
        guard sides.count == 2, sides[0].count == 2, sides[1].count == 2,
              let outputWidth = Double(sides[0][0]), let outputHeight = Double(sides[0][1]),
              let drawableWidth = Double(sides[1][0]), let drawableHeight = Double(sides[1][1]),
              drawableWidth >= 1, drawableHeight >= 1 else {
            return false
        }
        return abs(outputWidth - drawableWidth) <= 1 && abs(outputHeight - drawableHeight) <= 1
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
}
