import XCTest

/// First-run setup: a valid server URL opens the main interface, an
/// unreachable one shows `setup.error` and keeps the user on the setup screen.
final class SetupUITests: KonomiTVUITestCase {
    func testSetupConnectsToServerAndShowsMainInterface() {
        let app = startApp(showSetup: true)

        let urlField = uiElement(app, "setup.urlField")
        XCTAssertTrue(urlField.waitForExistence(timeout: TestTimeout.ui), "セットアップ画面が表示されない")

        replaceText(in: urlField, with: TestEnvironment.serverURL, in: app)
        submitSetupConnection(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { !urlField.exists },
            "接続後もセットアップ画面が表示されている"
        )
        XCTAssertTrue(mainNavigationExists(in: app), "接続後にメイン画面が表示されない")
    }

    func testSetupShowsErrorForUnreachableServer() {
        let app = startApp(showSetup: true)

        let urlField = uiElement(app, "setup.urlField")
        XCTAssertTrue(urlField.waitForExistence(timeout: TestTimeout.ui), "セットアップ画面が表示されない")

        // Port 9 (discard) is closed, so the connection fails immediately.
        replaceText(in: urlField, with: "http://127.0.0.1:9", in: app)
        submitSetupConnection(in: app)

        let error = uiElement(app, "setup.error")
        XCTAssertTrue(error.waitForExistence(timeout: TestTimeout.ui), "接続失敗時のエラーが表示されない")
        XCTAssertFalse(error.label.isEmpty, "エラーメッセージが空")
        XCTAssertTrue(urlField.exists, "接続失敗後もセットアップ画面に留まらない")
    }
}
