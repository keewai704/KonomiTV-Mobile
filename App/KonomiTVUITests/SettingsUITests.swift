import XCTest

/// 設定: login with the mock account, show the user name, then log out.
final class SettingsUITests: KonomiTVUITestCase {
    func testLoginShowsUserNameAndLogoutRestoresForm() {
        let app = startApp()
        navigate(to: .settings, in: app)

        let serverURL = uiElement(app, "settings.serverURL")
        XCTAssertTrue(serverURL.waitForExistence(timeout: TestTimeout.ui), "設定画面が表示されない")

        let username = uiElement(app, "settings.username")
        XCTAssertTrue(username.waitForExistence(timeout: TestTimeout.ui), "ユーザー名欄が表示されない")
        replaceText(in: username, with: "test", in: app)

        let password = uiElement(app, "settings.password")
        replaceText(in: password, with: "test", in: app)

        let loginButton = uiElement(app, "settings.loginButton")
        tapWhenHittable(loginButton, in: app)

        let userName = uiElement(app, "settings.userName")
        XCTAssertTrue(userName.waitForExistence(timeout: TestTimeout.ui), "ログイン後にユーザー名が表示されない")
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
