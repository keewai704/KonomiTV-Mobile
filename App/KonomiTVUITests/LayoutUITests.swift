import UIKit
import XCTest

/// Adaptive navigation: the sidebar for large windows (short side 700pt or
/// more), the tab bar plus the マイページ hub for the others, and rotation keeps
/// the selected section. The expectations come from the size of the window, not
/// from the kind of device.
final class LayoutUITests: KonomiTVUITestCase {
    func testAdaptiveNavigationMatchesWindowSize() {
        let app = startApp()

        let sidebar = uiElement(app, "sidebar")
        let tabBar = app.tabBars.firstMatch
        let liveTab = uiElement(app, "tab.live")

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                sidebar.exists || tabBar.exists || liveTab.exists
            },
            "メイン画面のナビゲーションが表示されない"
        )
        let largeWindow = isLargeWindow(app)

        if sidebar.exists {
            XCTAssertTrue(largeWindow, "大画面ではないウインドウにサイドバーがある")
            XCTAssertFalse(liveTab.exists, "大画面ではタブ項目を表示しない")
            XCTAssertFalse(tabBar.exists, "大画面ではタブバーを表示しない")

            openSection(.videos, in: app)
            XCTAssertTrue(
                uiElement(app, "videos.home").waitForExistence(timeout: TestTimeout.ui),
                "サイドバーからビデオ画面へ移動できない"
            )
            XCTAssertTrue(
                uiElement(app, "sidebar.settings").exists,
                "サイドバーに設定がない"
            )
            XCTAssertFalse(tabBar.exists, "大画面ではタブバーを表示しない")
        } else {
            XCTAssertFalse(largeWindow, "大画面のウインドウにタブバーがある")
            XCTAssertTrue(tabBar.waitForExistence(timeout: TestTimeout.ui), "大画面ではないウインドウではタブバーを表示する")
            XCTAssertTrue(uiElement(app, "tab.mypage").exists, "大画面ではないウインドウではマイページタブを表示する")

            openSection(.videos, in: app)
            XCTAssertTrue(
                uiElement(app, "videos.home").waitForExistence(timeout: TestTimeout.ui),
                "タブからビデオ画面へ移動できない"
            )

            openSection(.settings, in: app)
            XCTAssertTrue(
                uiElement(app, "settings.serverURL").waitForExistence(timeout: TestTimeout.ui),
                "マイページから設定画面へ移動できない"
            )
        }
    }

    /// 回転しても選択中の画面が残ること。大画面 (短い辺が 700pt 以上) は
    /// 縦向きでも横向きでもサイドバーのままなので、このテストは回転で
    /// ナビゲーションが変わるウインドウ (iPhone・Split View など) でだけ動かす。
    func testRotationKeepsSelectedSectionInSmallWindow() throws {
        let app = startApp()
        let largeWindow = isLargeWindow(app)
        try XCTSkipIf(largeWindow, "大画面 (短い辺が 700pt 以上) のウインドウでは回転テストをスキップする")

        openSection(.videos, in: app)
        XCTAssertTrue(
            uiElement(app, "videos.home").waitForExistence(timeout: TestTimeout.ui),
            "ビデオ画面が表示されない"
        )

        rotate(.landscapeLeft, in: app)
        XCTAssertTrue(
            uiElement(app, "videos.home").waitForExistence(timeout: TestTimeout.ui),
            "横向きにした後でビデオ画面が失われた"
        )
        // 横向きにしても短い辺は 700pt 未満なので、タブバーのまま。
        let landscapeWindow = app.windows.firstMatch.frame.size
        XCTAssertLessThan(
            min(landscapeWindow.width, landscapeWindow.height),
            700,
            "横向きのウインドウが大画面になった (サイドバーになるはず)"
        )
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: TestTimeout.ui),
            "横向きにした後でタブバーが失われた"
        )

        rotate(.portrait, in: app)
        XCTAssertTrue(
            uiElement(app, "videos.home").waitForExistence(timeout: TestTimeout.ui),
            "縦向きに戻した後でビデオ画面が失われた"
        )
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: TestTimeout.ui),
            "縦向きに戻した後でタブバーが失われた"
        )
    }

    // MARK: - Helpers

    /// Whether the window is large (short side 700pt or more), which gets the
    /// sidebar interface: read from the frame, not from the device.
    private func isLargeWindow(_ app: XCUIApplication) -> Bool {
        let size = app.windows.firstMatch.frame.size
        return min(size.width, size.height) >= 700
    }
}
