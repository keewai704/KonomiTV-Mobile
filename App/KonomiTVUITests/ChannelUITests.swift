import XCTest

/// テレビ: pinned channels via the channel context menu.
final class ChannelUITests: KonomiTVUITestCase {
    func testPinnedChannelAppearsInPinnedSegment() {
        let app = startApp()
        openSection(.live, in: app)

        let channel = uiElement(app, "live.channel.gr011")
        XCTAssertTrue(channel.waitForExistence(timeout: TestTimeout.ui), "地上波チャンネルが表示されない")

        channel.press(forDuration: 1.2)

        let pin = app.buttons["ピン留めする"]
        XCTAssertTrue(pin.waitForExistence(timeout: TestTimeout.ui), "ピン留めメニューが表示されない")
        pin.tap()

        let picker = uiElement(app, "live.typePicker")
        XCTAssertTrue(picker.waitForExistence(timeout: TestTimeout.ui), "チャンネル種別ピッカーが表示されない")

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                picker.descendants(matching: .button)["ピン留め"].exists
                    || app.buttons["ピン留め"].exists
            },
            "ピン留めセグメントが表示されない"
        )

        selectChannelType("ピン留め", in: app)

        XCTAssertTrue(
            uiElement(app, "live.channel.gr011").waitForExistence(timeout: TestTimeout.ui),
            "ピン留めしたチャンネルが表示されない"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { !uiElement(app, "live.channel.gr021").exists },
            "ピン留めセグメントにピン留めしていないチャンネルが表示されている"
        )
    }
}
