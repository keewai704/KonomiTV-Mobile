import XCTest

/// プレイヤー画面のレイアウトのスクリーンショット: 端末の縦・横それぞれで、
/// 通常表示と全画面表示。
///
/// レイアウトは端末の種類ではなくウインドウの大きさと縦横比で決まる。短い辺が
/// 700pt 未満の横長のウインドウ (iPhone の横向き) ではプレイヤーが常に全画面に
/// なり、全画面ボタンもない。撮った画像はテスト結果に残し (keepAlways)、CI が
/// アーティファクト `screenshots-<端末>` に書き出す。レイアウトそのものの確認は
/// 画像を見て行い、ここでは各状態で情報パネルと全画面ボタンの有無だけを確かめる。
final class LayoutScreenshotUITests: KonomiTVUITestCase {
    override func tearDown() async throws {
        await MainActor.run {
            XCUIDevice.shared.orientation = .portrait
        }
        try await super.tearDown()
    }

    func testLivePlayerLayouts() {
        let app = startApp(keepControls: true)
        openSection(.live, in: app)
        let channel = uiElement(app, "live.channel.gr011")
        XCTAssertTrue(channel.waitForExistence(timeout: TestTimeout.ui), "地上波チャンネルが表示されない")
        channel.tap()
        waitForPlaying(in: app)

        captureLayouts(of: "live", panel: uiElement(app, "panel.program"), in: app)
    }

    func testVideoPlayerLayouts() {
        let app = startApp(keepControls: true)
        openSection(.videos, in: app)
        let item = uiElement(app, "videos.recent.1")
        XCTAssertTrue(item.waitForExistence(timeout: TestTimeout.ui), "先頭のビデオが表示されない")
        item.tap()
        waitForPlaying(in: app)

        captureLayouts(of: "video", panel: uiElement(app, "video.menu"), in: app)
    }

    // MARK: - Helpers

    private func captureLayouts(of screen: String, panel: XCUIElement, in app: XCUIApplication) {
        let orientations: [(String, UIDeviceOrientation)] = [
            ("portrait", .portrait), ("landscape", .landscapeLeft),
        ]
        for (name, orientation) in orientations {
            XCUIDevice.shared.orientation = orientation
            waitSeconds(2)
            let window = app.windows.firstMatch.frame.size
            // 短い辺が 700pt 未満の横長のウインドウ (iPhone の横向き) は常に全画面
            // (WindowLayout.Shape.landscape)。
            let isForcedFullscreen = min(window.width, window.height) < 700 && window.width > window.height

            if isForcedFullscreen {
                XCTAssertTrue(waitUntil(timeout: TestTimeout.ui) { !panel.exists }, "\(name): 常に全画面のウインドウでプレイヤーが全画面にならない")
                XCTAssertFalse(uiElement(app, "player.fullscreen").exists, "\(name): 常に全画面のウインドウに全画面ボタンがある")
                XCTAssertTrue(uiElement(app, "player.back").exists, "\(name): 常に全画面のウインドウに戻るボタンがない")
                attachScreenshot("\(screen)-\(name)-fullscreen", of: app)
                continue
            }

            XCTAssertTrue(panel.waitForExistence(timeout: TestTimeout.ui), "\(name): 通常表示で情報が表示されない")
            attachScreenshot("\(screen)-\(name)-normal", of: app)

            tapFullscreen(in: app) { !panel.exists }
            XCTAssertTrue(waitUntil(timeout: TestTimeout.ui) { !panel.exists }, "\(name): 全画面表示で情報が隠れない")
            waitSeconds(1)
            attachScreenshot("\(screen)-\(name)-fullscreen", of: app)

            tapFullscreen(in: app) { panel.exists }
            XCTAssertTrue(panel.waitForExistence(timeout: TestTimeout.ui), "\(name): 全画面表示を終了できない")
        }
    }

    private func waitForPlaying(in app: XCUIApplication) {
        let state = uiElement(app, "player.state")
        XCTAssertTrue(state.waitForExistence(timeout: TestTimeout.playback), "再生状態が取得できない")
        XCTAssertTrue(
            waitForLabel(state, equals: "playing", timeout: TestTimeout.playback),
            "再生が playing にならない (状態: \(state.label))"
        )
    }

    /// Taps the fullscreen button at its frame (the controls stay on screen
    /// with keepControls) until `done` holds.
    private func tapFullscreen(in app: XCUIApplication, until done: () -> Bool) {
        let button = uiElement(app, "player.fullscreen")
        for _ in 0..<4 {
            if !button.exists {
                uiElement(app, "player.surface").tap()
            }
            guard button.waitForExistence(timeout: 3),
                  let frame = try? button.snapshot().frame, !frame.isEmpty else { continue }
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                .tap()
            if waitUntil(timeout: 5, done) {
                return
            }
        }
    }

    private func attachScreenshot(_ name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
