import XCTest

/// データ放送 (BML): the WKWebView page, the toolbar toggle and the remote.
final class DataBroadcastingUITests: KonomiTVUITestCase {

    // MARK: - Helpers

    /// Opens the live player of the first 地上波 channel.
    private func openLive(in app: XCUIApplication) {
        openSection(.live, in: app)
        let channel = uiElement(app, "live.channel.gr011")
        XCTAssertTrue(
            channel.waitForExistence(timeout: TestTimeout.ui),
            "地上波チャンネルが表示されない"
        )
        channel.tap()

        let player = uiElement(app, "player.view")
        XCTAssertTrue(
            player.waitForExistence(timeout: TestTimeout.playback),
            "プレイヤーが表示されない"
        )
    }

    /// 設定 → テレビ → データ放送.
    private func openDataBroadcastingSettings(in app: XCUIApplication) {
        openSection(.settings, in: app)

        let link = uiElement(app, "settings.dataBroadcasting")
        if !link.waitForExistence(timeout: 3) {
            let container: XCUIElement
            if app.collectionViews.firstMatch.exists {
                container = app.collectionViews.firstMatch
            } else if app.scrollViews.firstMatch.exists {
                container = app.scrollViews.firstMatch
            } else {
                container = app
            }
            _ = scrollUntilVisible(link, in: container)
        }
        XCTAssertTrue(link.waitForExistence(timeout: TestTimeout.ui), "データ放送の設定が表示されない")
        tapWhenHittable(link, in: app)
    }

    private func bmlState(in app: XCUIApplication) -> String {
        label(of: "bml.state", in: app)
    }

    // MARK: - Tests

    /// A channel without a data component: the page reports unavailable and the
    /// app hides the whole feature.
    func testChannelWithoutBMLBecomesUnavailable() {
        let app = startApp()
        openLive(in: app)

        let state = uiElement(app, "bml.state")
        XCTAssertTrue(state.waitForExistence(timeout: TestTimeout.playback), "データ放送の状態が取得できない")
        XCTAssertTrue(
            waitForLabel(state, equals: "unavailable", timeout: TestTimeout.playback),
            "データ放送のないチャンネルで unavailable にならない (現在: \(state.label))"
        )

        XCTAssertFalse(
            uiElement(app, "player.dataBroadcasting").exists,
            "データ放送のないチャンネルでデータ放送ボタンが表示されている"
        )
        XCTAssertFalse(
            uiElement(app, "bml.remote").exists,
            "データ放送のないチャンネルでリモコンが表示されている"
        )

        // The page did request the PSI/SI archived data stream (the channel has
        // no BML, which is only known after the PMT arrived).
        XCTAssertGreaterThan(
            MockServerControl.intValue("psi_archived_data_count"),
            0,
            "PSI/SI アーカイブデータが取得されていない"
        )
    }

    /// With the mock server's data component switch the page finds BML in the
    /// PMT: the app keeps its loading state (the mock has no carousel) and
    /// offers the toggle and the remote.
    func testDataComponentChannelShowsToggleAndRemote() {
        MockServerControl.setConfig(["data_component": true])

        let app = startApp()
        openLive(in: app)

        let state = uiElement(app, "bml.state")
        XCTAssertTrue(state.waitForExistence(timeout: TestTimeout.playback), "データ放送の状態が取得できない")
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) {
                ["loading", "ready", "visible"].contains(self.bmlState(in: app))
            },
            "データ放送のあるチャンネルで読み込みが始まらない (現在: \(bmlState(in: app)))"
        )

        let toggle = uiElement(app, "player.dataBroadcasting")
        XCTAssertTrue(
            toggle.waitForExistence(timeout: TestTimeout.ui),
            "データ放送ボタンが表示されない"
        )

        // The toggle also opens the remote so the BML screen can be operated.
        tapWhenHittable(toggle, in: app)
        XCTAssertTrue(
            uiElement(app, "bml.remote").waitForExistence(timeout: TestTimeout.ui),
            "リモコンが表示されない"
        )
        for key in ["d", "enter", "back", "up", "blue", "1"] {
            XCTAssertTrue(
                uiElement(app, "bml.key.\(key)").exists,
                "リモコンのキー \(key) が表示されない"
            )
        }
    }

    /// Turning the setting off stops the app from loading anything: the page is
    /// never created, so the server sees no PSI/SI archived data request.
    func testTurningTheSettingOffLoadsNothing() {
        let app = startApp()
        openDataBroadcastingSettings(in: app)

        let isEnabled = uiElement(app, "settings.dataBroadcasting.enabled")
        XCTAssertTrue(isEnabled.waitForExistence(timeout: TestTimeout.ui), "データ放送の設定が表示されない")
        XCTAssertTrue(
            flipSwitch(isEnabled, in: app) && (isEnabled.value as? String) == "0",
            "データ放送の設定をオフにできない (\(isEnabled.value ?? "nil"))"
        )

        navigateBack(in: app)
        openLive(in: app)

        let state = uiElement(app, "bml.state")
        XCTAssertTrue(state.waitForExistence(timeout: TestTimeout.playback), "データ放送の状態が取得できない")
        XCTAssertTrue(
            waitForLabel(state, equals: "off", timeout: TestTimeout.playback),
            "設定をオフにしてもデータ放送が止まらない (現在: \(state.label))"
        )
        XCTAssertFalse(
            uiElement(app, "player.dataBroadcasting").exists,
            "設定がオフのときにデータ放送ボタンが表示されている"
        )

        // Give a late request the chance to show up before asserting.
        waitSeconds(2)
        XCTAssertEqual(
            MockServerControl.intValue("psi_archived_data_count"),
            0,
            "設定がオフなのに PSI/SI アーカイブデータが取得されている"
        )
    }
}
