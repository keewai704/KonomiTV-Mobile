import UIKit
import XCTest

/// Adaptive navigation: sidebar for regular widths (iPad), tab bar plus the
/// マイページ hub for compact widths (iPhone), and rotation on iPhone keeps the
/// selection.
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

        if sidebar.exists {
            XCTAssertFalse(liveTab.exists, "レギュラー幅ではタブ項目を表示しない")
            XCTAssertFalse(tabBar.exists, "レギュラー幅ではタブバーを表示しない")

            openSection(.videos, in: app)
            XCTAssertTrue(
                uiElement(app, "videos.home").waitForExistence(timeout: TestTimeout.ui),
                "サイドバーからビデオ画面へ移動できない"
            )
            XCTAssertTrue(
                uiElement(app, "sidebar.settings").exists,
                "サイドバーに設定がない"
            )
            XCTAssertFalse(tabBar.exists, "レギュラー幅ではタブバーを表示しない")
        } else {
            XCTAssertTrue(tabBar.waitForExistence(timeout: TestTimeout.ui), "コンパクト幅ではタブバーを表示する")
            XCTAssertTrue(uiElement(app, "tab.mypage").exists, "コンパクト幅ではマイページタブを表示する")

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

    func testRotationKeepsSelectedSectionOnIPhone() throws {
        let app = startApp()
        let regularLayout = isRegularLayout(app)
        try XCTSkipIf(regularLayout, "レギュラー幅 (iPad) では回転テストをスキップする")

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
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                app.tabBars.firstMatch.exists || uiElement(app, "sidebar").exists
            },
            "横向きにした後でナビゲーションが失われた"
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
}
