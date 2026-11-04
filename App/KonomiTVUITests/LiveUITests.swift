import XCTest

/// テレビ: channel list, broadcast-type picker and live playback.
final class LiveUITests: KonomiTVUITestCase {
    func testLiveListShowsChannelsAndPickerSwitchesToBS() {
        let app = startApp()
        openSection(.live, in: app)

        let picker = uiElement(app, "live.typePicker")
        XCTAssertTrue(picker.waitForExistence(timeout: TestTimeout.ui), "チャンネル種別ピッカーが表示されない")

        let grChannel = uiElement(app, "live.channel.gr011")
        XCTAssertTrue(grChannel.waitForExistence(timeout: TestTimeout.ui), "地上波チャンネルが表示されない")
        // gr012 is a subchannel with nothing on air (is_display: false).
        XCTAssertFalse(uiElement(app, "live.channel.gr012").exists, "放送していないサブチャンネルが表示されている")

        selectChannelType("BS", in: app)

        let bsChannel = uiElement(app, "live.channel.bs101")
        XCTAssertTrue(bsChannel.waitForExistence(timeout: TestTimeout.ui), "BS 切替後に BS チャンネルが表示されない")
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { !grChannel.exists },
            "BS 切替後も地上波チャンネルが表示されている"
        )
    }

    func testLivePlaybackReachesPlayingState() {
        let app = startApp()
        openSection(.live, in: app)

        let channel = uiElement(app, "live.channel.gr011")
        XCTAssertTrue(channel.waitForExistence(timeout: TestTimeout.ui), "地上波チャンネルが表示されない")
        channel.tap()

        let player = uiElement(app, "player.view")
        XCTAssertTrue(player.waitForExistence(timeout: TestTimeout.playback), "プレイヤーが表示されない")

        let state = uiElement(app, "player.state")
        XCTAssertTrue(state.waitForExistence(timeout: TestTimeout.playback), "再生状態が取得できない")
        XCTAssertTrue(
            waitForLabel(state, equals: "playing", timeout: TestTimeout.playback),
            "ライブ再生が playing にならない (現在: \(state.label) / \(state.value as? String ?? ""))"
        )
    }
}
