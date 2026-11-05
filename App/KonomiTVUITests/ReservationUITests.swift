import XCTest

/// 録画予約: the reservation list, the detail screen, the keyword conditions and
/// the reserve actions of the timetable and the live program panel.
final class ReservationUITests: KonomiTVUITestCase {
    // MARK: - List

    func testReservationsListShowsFixtureReservations() {
        let app = startApp()
        openSection(.reservations, in: app)

        XCTAssertTrue(
            uiElement(app, "reservations.list").waitForExistence(timeout: TestTimeout.ui),
            "録画予約の一覧が表示されない"
        )
        XCTAssertTrue(
            uiElement(app, "reservation.1").waitForExistence(timeout: TestTimeout.ui),
            "放送が近い録画予約が表示されない"
        )

        // すべての録画予約 (録画中・チューナー不足・無効を含む) も一覧に並ぶ。
        let all = uiElement(app, "reservations.all")
        XCTAssertTrue(scrollTo(all, in: app), "「すべての録画予約」が表示されない")
        all.tap()

        XCTAssertTrue(
            uiElement(app, "reservations.all.list").waitForExistence(timeout: TestTimeout.ui),
            "録画予約一覧 (すべて) が表示されない"
        )
        // 一覧はページングせずに全件を並べるので、スクロールしながら
        // フィクスチャの予約がすべて出ていることを確認する。
        var seen: Set<String> = []
        let prefix = "reservation."
        for _ in 0..<4 {
            let rows = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", prefix)
            )
            for index in 0..<rows.count {
                let identifier = rows.element(boundBy: index).identifier
                guard identifier.hasPrefix(prefix) else { continue }
                if Int(identifier.dropFirst(prefix.count)) != nil {
                    seen.insert(identifier)
                }
            }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        for fixtureID in 1...4 {
            XCTAssertTrue(
                seen.contains("\(prefix)\(fixtureID)"),
                "録画予約一覧に \(prefix)\(fixtureID) が表示されない (見つかった: \(seen.sorted()))"
            )
        }
    }

    // MARK: - Detail

    func testReservationDetailTogglesEnabledAndSaves() {
        let app = startApp()
        openSection(.reservations, in: app)

        let row = uiElement(app, "reservation.1")
        XCTAssertTrue(scrollTo(row, in: app), "録画予約が表示されない")
        row.tap()

        XCTAssertTrue(
            uiElement(app, "reservation.detail").waitForExistence(timeout: TestTimeout.ui),
            "録画予約の詳細が表示されない"
        )

        let enabled = uiElement(app, "reservation.enabled")
        XCTAssertTrue(scrollTo(enabled, in: app), "有効スイッチが表示されない")
        XCTAssertTrue(flipSwitch(enabled, in: app), "有効スイッチを切り替えられない")

        let save = uiElement(app, "reservation.save")
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { save.exists && save.isEnabled },
            "設定を変更しても保存ボタンが有効にならない"
        )
        save.tap()

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("reservation_update_count") >= 1
            },
            "録画設定の更新がサーバーに届いていない"
        )
        XCTAssertEqual(
            statsIntArray("reservation_updated_ids").last,
            1,
            "更新された録画予約の ID が想定と異なる"
        )
        if let isEnabled = statsSettings()["is_enabled"] as? Bool {
            XCTAssertFalse(isEnabled, "無効にしたのに有効のまま保存されている")
        }
    }

    func testReservationDeleteWithConfirmation() {
        let app = startApp()
        openSection(.reservations, in: app)

        let row = uiElement(app, "reservation.4")
        XCTAssertTrue(scrollTo(row, in: app), "無効な予約が表示されない")
        row.tap()

        let delete = uiElement(app, "reservation.delete")
        XCTAssertTrue(scrollTo(delete, in: app), "削除ボタンが表示されない")
        tapWhenHittable(delete, in: app)

        tapDeleteConfirmation(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("reservation_delete_count") >= 1
            },
            "録画予約の削除がサーバーに届いていない"
        )
        XCTAssertEqual(
            statsIntArray("reservation_deleted_ids").last,
            4,
            "削除された録画予約の ID が想定と異なる"
        )

        // 削除後は同じ番組をもう一度予約できる。
        XCTAssertTrue(
            scrollTo(uiElement(app, "reservation.add"), in: app),
            "削除後に予約の追加ボタンが表示されない"
        )
    }

    // MARK: - Timetable

    func testReserveProgramFromTimetable() {
        let app = startApp()
        openSection(.timetable, in: app)

        let grid = uiElement(app, "timetable.grid")
        XCTAssertTrue(grid.waitForExistence(timeout: TestTimeout.ui), "番組表が表示されない")

        // 翌日の番組は必ず未来なので、放送終了で操作が隠れることがない。
        let nextDay = uiElement(app, "timetable.nextDay")
        XCTAssertTrue(nextDay.waitForExistence(timeout: TestTimeout.ui), "翌日ボタンが表示されない")
        nextDay.tap()

        // The next day's cells load (and settle) after the tap.
        let reserved = reservedProgramIDs()
        var found: String?
        _ = waitUntil(timeout: TestTimeout.ui) {
            found = self.firstUnreservedProgramID(in: app, reserved: reserved)
            return found != nil
        }
        guard let programID = found else {
            XCTFail("予約していない番組セルが見つからない")
            return
        }
        uiElement(app, "timetable.program.\(programID)").tap()

        let reserve = uiElement(app, "timetable.program.reserve")
        XCTAssertTrue(
            reserve.waitForExistence(timeout: TestTimeout.ui),
            "番組詳細に録画予約ボタンが表示されない"
        )
        reserve.tap()

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("reservation_add_count") >= 1
            },
            "録画予約の追加がサーバーに届いていない"
        )
        XCTAssertEqual(
            statsStringArray("reservation_added_program_ids").last,
            programID,
            "予約した番組 ID が想定と異なる"
        )
    }

    // MARK: - Keyword conditions

    func testCreateKeywordCondition() {
        let app = startApp()
        openSection(.reservations, in: app)

        let link = uiElement(app, "conditions.link")
        XCTAssertTrue(scrollTo(link, in: app), "キーワード条件の入口が表示されない")
        tapWhenHittable(link, in: app)

        XCTAssertTrue(
            uiElement(app, "conditions.list").waitForExistence(timeout: TestTimeout.ui),
            "キーワード条件の一覧が表示されない"
        )

        let add = uiElement(app, "condition.add")
        XCTAssertTrue(add.waitForExistence(timeout: TestTimeout.ui), "条件の追加ボタンが表示されない")
        add.tap()

        let keyword = uiElement(app, "condition.keyword")
        XCTAssertTrue(keyword.waitForExistence(timeout: TestTimeout.ui), "キーワード欄が表示されない")
        replaceText(in: keyword, with: "アニメ", in: app)
        dismissKeyboard(in: app)

        let save = uiElement(app, "condition.save")
        XCTAssertTrue(save.waitForExistence(timeout: TestTimeout.ui), "保存ボタンが表示されない")
        tapWhenHittable(save, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("reservation_condition_add_count") >= 1
            },
            "キーワード条件の登録がサーバーに届いていない"
        )
        let condition = MockServerControl.stats()["last_reservation_condition"] as? [String: Any]
        let search = condition?["program_search_condition"] as? [String: Any]
        XCTAssertEqual(search?["keyword"] as? String, "アニメ", "登録されたキーワードが想定と異なる")
    }

    // MARK: - Live program panel

    func testReserveAndCancelFromLivePanel() {
        let app = startApp()
        openSection(.live, in: app)

        let channel = uiElement(app, "live.channel.gr011")
        XCTAssertTrue(channel.waitForExistence(timeout: TestTimeout.ui), "地上波チャンネルが表示されない")
        channel.tap()

        let reserve = uiElement(app, "panel.program.reserve")
        XCTAssertTrue(
            reserve.waitForExistence(timeout: TestTimeout.playback),
            "番組パネルに録画予約ボタンが表示されない"
        )
        tapWhenHittable(reserve, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("reservation_add_count") >= 1
            },
            "番組パネルからの録画予約がサーバーに届いていない"
        )

        let cancel = uiElement(app, "panel.program.reservation.cancel")
        XCTAssertTrue(
            cancel.waitForExistence(timeout: TestTimeout.ui),
            "予約後に予約の削除ボタンが表示されない"
        )
        tapWhenHittable(cancel, in: app)

        tapReservationCancelConfirmation(in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("reservation_delete_count") >= 1
            },
            "番組パネルからの予約削除がサーバーに届いていない"
        )
    }

    // MARK: - Scrolling

    /// Scrolls the form until the element exists and is hittable (lazy list rows
    /// are only created once they are close to the viewport).
    @discardableResult
    private func scrollTo(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 10
    ) -> Bool {
        if element.exists, element.isHittable {
            return true
        }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if element.exists, element.isHittable {
                return true
            }
        }
        return element.exists && element.isHittable
    }

    // MARK: - Mock server helpers

    /// Program IDs that already have a reservation in the mock server.
    private func reservedProgramIDs() -> Set<String> {
        guard let object = mockJSON(path: "api/recording/reservations"),
              let reservations = object["reservations"] as? [[String: Any]] else {
            return []
        }
        var ids: Set<String> = []
        for reservation in reservations {
            if let program = reservation["program"] as? [String: Any],
               let id = program["id"] as? String {
                ids.insert(id)
            }
        }
        return ids
    }

    /// A visible program cell of the timetable that has no reservation yet.
    private func firstUnreservedProgramID(
        in app: XCUIApplication,
        reserved: Set<String>
    ) -> String? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "timetable.program.")
        let cells = app.descendants(matching: .any).matching(predicate)

        for index in 0..<min(cells.count, 40) {
            let cell = cells.element(boundBy: index)
            guard cell.exists, cell.isHittable else { continue }
            let identifier = cell.identifier
            let prefix = "timetable.program."
            guard identifier.hasPrefix(prefix) else { continue }
            let programID = String(identifier.dropFirst(prefix.count))
            // The action identifiers of the detail sheet share the prefix.
            if programID.hasPrefix("reserve") || programID.hasPrefix("reservation") {
                continue
            }
            if reserved.contains(programID) {
                continue
            }
            return programID
        }
        return nil
    }

    private func mockJSON(path: String) -> [String: Any]? {
        var request = URLRequest(
            url: MockServerControl.baseURL.appendingPathComponent(path)
        )
        request.timeoutInterval = 10

        let semaphore = DispatchSemaphore(value: 0)
        var object: [String: Any]?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object = json
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 15)
        return object
    }

    private func statsStringArray(_ key: String) -> [String] {
        guard let values = MockServerControl.stats()[key] as? [Any] else { return [] }
        return values.compactMap { $0 as? String }
    }

    private func statsIntArray(_ key: String) -> [Int] {
        guard let values = MockServerControl.stats()[key] as? [Any] else { return [] }
        return values.compactMap { ($0 as? NSNumber)?.intValue }
    }

    private func statsSettings() -> [String: Any] {
        MockServerControl.stats()["last_reservation_settings"] as? [String: Any] ?? [:]
    }

    // MARK: - Confirmation dialogs

    /// Taps the destructive button of the reservation delete dialog (the
    /// identifier is applied to the SwiftUI button, alert-style buttons are
    /// found by their label).
    private func tapDeleteConfirmation(in app: XCUIApplication) {
        let identified = uiElement(app, "reservation.delete.confirm")
        if identified.waitForExistence(timeout: 5), identified.isHittable {
            identified.tap()
            return
        }
        tapButton(labelled: "予約を削除", in: app)
    }

    private func tapReservationCancelConfirmation(in app: XCUIApplication) {
        let identified = uiElement(app, "panel.program.reservation.cancel.confirm")
        if identified.waitForExistence(timeout: 5), identified.isHittable {
            identified.tap()
            return
        }
        tapButton(labelled: "予約をキャンセル", in: app)
    }

    private func tapButton(labelled label: String, in app: XCUIApplication) {
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", label))
        for index in 0..<buttons.count {
            let button = buttons.element(boundBy: index)
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }
        XCTFail("確認ボタン「\(label)」が見つからない")
    }
}
