import XCTest

/// 設定: login with the mock account, show the user name, then log out.
final class SettingsUITests: KonomiTVUITestCase {
    func testLoginShowsUserNameAndLogoutRestoresForm() {
        let app = startApp()
        openSection(.settings, in: app)

        let serverURL = uiElement(app, "settings.serverURL")
        XCTAssertTrue(serverURL.waitForExistence(timeout: TestTimeout.ui), "設定画面が表示されない")

        login(in: app)

        let userName = uiElement(app, "settings.userName")
        let displayedName = "\(userName.label) \(userName.value as? String ?? "")"
        XCTAssertTrue(
            displayedName.contains("テストユーザー"),
            "ユーザー名が想定と異なる: \(displayedName)"
        )

        let logoutButton = uiElement(app, "settings.logoutButton")
        XCTAssertTrue(logoutButton.waitForExistence(timeout: TestTimeout.ui), "ログアウトボタンが表示されない")
        tapWhenHittable(logoutButton, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { !userName.exists },
            "ログアウト後もユーザー名が表示されている"
        )
        XCTAssertTrue(
            uiElement(app, "settings.loginButton").waitForExistence(timeout: TestTimeout.ui),
            "ログアウト後にログインフォームが戻らない"
        )
    }
}
