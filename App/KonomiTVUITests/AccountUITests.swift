import XCTest

/// アカウント・管理・メンテナンス・番組検索・シリーズ.
///
/// The mock server records every mutation in /__mock/stats, so the tests
/// verify what actually reached the server, not only the UI state.
final class AccountUITests: KonomiTVUITestCase {

    // MARK: - Registration

    func testRegisterCreatesAccountAndLogsIn() {
        let app = startApp()
        openSection(.settings, in: app)

        let registerLink = uiElement(app, "settings.register.link")
        XCTAssertTrue(
            registerLink.waitForExistence(timeout: TestTimeout.ui),
            "アカウント作成へのリンクが表示されない"
        )
        tapWhenHittable(registerLink, in: app)

        let username = uiElement(app, "settings.register.username")
        XCTAssertTrue(
            username.waitForExistence(timeout: TestTimeout.ui),
            "アカウント作成画面が表示されない"
        )
        replaceText(in: username, with: "newuser", in: app)
        replaceText(in: uiElement(app, "settings.register.password"), with: "pass1234", in: app)
        replaceText(in: uiElement(app, "settings.register.confirm"), with: "pass1234", in: app)

        let submit = uiElement(app, "settings.register.submit")
        tapWhenHittable(submit, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                uiElement(app, "settings.userName").exists
                    && uiElement(app, "settings.userName").label.contains("newuser")
            },
            "アカウント作成後にログイン状態にならない"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("user_create_count") >= 1
            },
            "アカウントがサーバーに作成されていない"
        )
        let created = MockServerControl.stats()["created_usernames"] as? [String] ?? []
        XCTAssertEqual(created, ["newuser"], "作成されたユーザー名が想定と異なる")
    }

    // MARK: - Account settings

    func testChangeUsernameUpdatesServer() {
        let app = startApp()
        openSection(.settings, in: app)
        login(in: app)

        let accountLink = uiElement(app, "settings.account")
        XCTAssertTrue(
            accountLink.waitForExistence(timeout: TestTimeout.ui),
            "アカウント設定へのリンクが表示されない"
        )
        tapWhenHittable(accountLink, in: app)

        let username = uiElement(app, "settings.account.username")
        XCTAssertTrue(
            username.waitForExistence(timeout: TestTimeout.ui),
            "アカウント設定画面が表示されない"
        )
        replaceText(in: username, with: "renamed", in: app)

        let save = uiElement(app, "settings.account.usernameSave")
        tapWhenHittable(save, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("user_update_count") >= 1
            },
            "ユーザー名の変更がサーバーに送信されない"
        )
        let payload = MockServerControl.stats()["last_user_update"] as? [String: Any]
        XCTAssertEqual(payload?["username"] as? String, "renamed", "送信されたユーザー名が想定と異なる")
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                uiElement(app, "settings.account.name").label.contains("renamed")
            },
            "ユーザー名の変更が画面に反映されない"
        )
    }

    // MARK: - Administrator

    func testAdminUserListAndDelete() {
        let app = startApp()
        openSection(.settings, in: app)
        login(in: app)

        let adminLink = uiElement(app, "admin.users.link")
        XCTAssertTrue(
            adminLink.waitForExistence(timeout: TestTimeout.ui),
            "ユーザー管理へのリンクが表示されない"
        )
        tapWhenHittable(adminLink, in: app)

        let viewer = uiElement(app, "admin.users.item.2")
        XCTAssertTrue(
            viewer.waitForExistence(timeout: TestTimeout.ui),
            "ユーザー一覧が表示されない"
        )
        viewer.tap()

        XCTAssertTrue(
            uiElement(app, "admin.users.name").waitForExistence(timeout: TestTimeout.ui),
            "ユーザーの詳細が表示されない"
        )

        let delete = uiElement(app, "admin.users.delete")
        tapWhenHittable(delete, in: app)
        tapConfirmation("admin.users.delete.confirm", label: "削除", in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("user_delete_count") >= 1
            },
            "ユーザーがサーバーで削除されていない"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                !uiElement(app, "admin.users.item.2").exists
            },
            "削除したユーザーが一覧に残っている"
        )
    }

    // MARK: - Server settings

    func testServerSettingsChangeAndSave() {
        let app = startApp()
        openSection(.settings, in: app)
        login(in: app)

        let serverLink = uiElement(app, "settings.server.link")
        XCTAssertTrue(
            serverLink.waitForExistence(timeout: TestTimeout.ui),
            "サーバー設定へのリンクが表示されない"
        )
        tapWhenHittable(serverLink, in: app)

        let port = uiElement(app, "settings.server.port")
        XCTAssertTrue(
            port.waitForExistence(timeout: TestTimeout.ui),
            "サーバー設定画面が表示されない"
        )
        replaceText(in: port, with: "7100", in: app)

        let save = uiElement(app, "settings.server.save")
        tapWhenHittable(save, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("server_settings_put_count") >= 1
            },
            "サーバー設定が保存されていない"
        )
        let payload = MockServerControl.stats()["last_server_settings"] as? [String: Any]
        let server = payload?["server"] as? [String: Any]
        XCTAssertEqual(server?["port"] as? Int, 7100, "保存されたポートが想定と異なる")
        XCTAssertTrue(
            uiElement(app, "settings.server.saved").waitForExistence(timeout: TestTimeout.ui),
            "再起動が必要である旨が表示されない"
        )
    }

    // MARK: - Maintenance

    func testMaintenanceRunsBatchScan() {
        let app = startApp()
        openSection(.settings, in: app)
        login(in: app)

        let maintenanceLink = uiElement(app, "maintenance.link")
        XCTAssertTrue(
            maintenanceLink.waitForExistence(timeout: TestTimeout.ui),
            "メンテナンスへのリンクが表示されない"
        )
        tapWhenHittable(maintenanceLink, in: app)

        let run = uiElement(app, "maintenance.batchScan.run")
        XCTAssertTrue(
            run.waitForExistence(timeout: TestTimeout.ui),
            "一括スキャンの実行ボタンが表示されない"
        )
        tapWhenHittable(run, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                let counts = MockServerControl.stats()["maintenance_run_counts"]
                    as? [String: Any]
                return (counts?["batch-scan"] as? Int ?? 0) >= 1
            },
            "一括スキャンがサーバーで実行されていない"
        )
        XCTAssertTrue(
            uiElement(app, "maintenance.batchScan.status").waitForExistence(timeout: TestTimeout.ui),
            "一括スキャンの進捗が表示されない"
        )
    }

    // MARK: - Program search

    func testProgramSearchWithGenreFilter() {
        let app = startApp()
        openSection(.live, in: app)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: TestTimeout.ui),
            "番組検索欄が表示されない"
        )
        searchField.tap()
        searchField.typeText("ニュース")

        XCTAssertTrue(
            waitUntil(timeout: Timeout.long) {
                MockServerControl.intValue("program_search_count") >= 1
            },
            "キーワード検索がサーバーに送られていない"
        )

        dismissKeyboard(in: app)

        let filterButton = uiElement(app, "search.filter.button")
        XCTAssertTrue(
            filterButton.waitForExistence(timeout: TestTimeout.ui),
            "検索条件ボタンが表示されない"
        )
        tapWhenHittable(filterButton, in: app)

        let genres = uiElement(app, "search.filter.genres")
        XCTAssertTrue(
            genres.waitForExistence(timeout: Timeout.short),
            "ジャンル条件が表示されない"
        )
        tapWhenHittable(genres, in: app)

        let firstGenre = uiElement(app, "search.filter.genre.0")
        XCTAssertTrue(
            firstGenre.waitForExistence(timeout: TestTimeout.ui),
            "ジャンル一覧が表示されない"
        )
        tapWhenHittable(firstGenre, in: app)
        navigateBack(in: app)

        let apply = uiElement(app, "search.filter.apply")
        XCTAssertTrue(
            apply.waitForExistence(timeout: TestTimeout.ui),
            "検索条件の適用ボタンが表示されない"
        )
        tapWhenHittable(apply, in: app)

        XCTAssertTrue(
            waitUntil(timeout: Timeout.long) {
                guard let condition = MockServerControl.stats()["last_program_search_condition"]
                    as? [String: Any],
                    let ranges = condition["genre_ranges"] as? [[String: Any]] else {
                    return false
                }
                return !ranges.isEmpty
            },
            "ジャンル条件が検索リクエストに含まれていない"
        )
    }

    // MARK: - Series

    func testSeriesDetailAndMyList() {
        let app = startApp()
        openSection(.videos, in: app)

        let seriesLink = uiElement(app, "videos.seriesLink")
        XCTAssertTrue(
            seriesLink.waitForExistence(timeout: TestTimeout.ui),
            "シリーズ一覧へのリンクが表示されない"
        )
        tapWhenHittable(seriesLink, in: app)

        let firstSeries = uiElement(app, "series.item.1")
        XCTAssertTrue(
            firstSeries.waitForExistence(timeout: TestTimeout.ui),
            "シリーズ一覧が表示されない"
        )
        firstSeries.tap()

        XCTAssertTrue(
            uiElement(app, "series.detail.title").waitForExistence(timeout: TestTimeout.ui),
            "シリーズ詳細が表示されない"
        )

        let mylist = uiElement(app, "series.mylist")
        XCTAssertTrue(
            mylist.waitForExistence(timeout: TestTimeout.ui),
            "シリーズのマイリストボタンが表示されない"
        )
        XCTAssertEqual(mylist.label, "マイリストに追加", "マイリスト未登録時のラベルが想定と異なる")
        mylist.tap()
        XCTAssertTrue(
            waitForLabel(mylist, equals: "マイリストから削除"),
            "シリーズをマイリストに追加できない"
        )

        openSection(.mylist, in: app)

        XCTAssertTrue(
            uiElement(app, "mylist.series.1").waitForExistence(timeout: TestTimeout.ui),
            "追加したシリーズがマイリストに表示されない"
        )
    }

    // MARK: - Helpers

    /// Taps the destructive button of a confirmation dialog. SwiftUI applies
    /// the identifier to the button, but alert-style buttons are sometimes
    /// only reachable by their label.
    private func tapConfirmation(
        _ identifier: String,
        label: String,
        in app: XCUIApplication
    ) {
        let identified = uiElement(app, identifier)
        if identified.waitForExistence(timeout: 5), identified.isHittable {
            identified.tap()
            return
        }

        let labelled = app.buttons.matching(NSPredicate(format: "label == %@", label))
        for index in 0..<labelled.count {
            let button = labelled.element(boundBy: index)
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }

        XCTFail("確認ダイアログの「\(label)」ボタンが見つからない")
    }
}

private enum Timeout {
    static let short: TimeInterval = 5
    static let long: TimeInterval = 30
}
