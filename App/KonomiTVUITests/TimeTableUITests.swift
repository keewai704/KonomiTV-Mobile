import XCTest

/// 番組表: the grid is rendered and a program cell opens its detail.
final class TimeTableUITests: KonomiTVUITestCase {
    func testTimeTableShowsGridAndProgramDetail() {
        let app = startApp()
        openSection(.timetable, in: app)

        let grid = uiElement(app, "timetable.grid")
        XCTAssertTrue(grid.waitForExistence(timeout: TestTimeout.ui), "番組表が表示されない")

        let cell = firstHittableProgramCell(in: app)
        XCTAssertNotNil(cell, "番組表のセルが見つからない")
        guard let cell else { return }
        cell.tap()

        let title = uiElement(app, "timetable.detail.title")
        XCTAssertTrue(title.waitForExistence(timeout: TestTimeout.ui), "番組詳細のタイトルが表示されない")
        XCTAssertFalse(title.label.isEmpty, "番組詳細のタイトルが空")
    }

    /// A program cell on screen. The grid is scrolled to the current time on
    /// appearance, so a cell is normally visible right away; the day may have
    /// no programs around the current hour (for example when the server serves
    /// a different time zone), so the top of the day is checked as well.
    private func firstHittableProgramCell(in app: XCUIApplication) -> XCUIElement? {
        if let cell = visibleProgramCell(in: app) {
            return cell
        }

        let grid = uiElement(app, "timetable.grid")
        for _ in 0..<4 {
            grid.swipeDown()
            if let cell = visibleProgramCell(in: app) {
                return cell
            }
        }
        return nil
    }

    private func visibleProgramCell(in app: XCUIApplication) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "timetable.program.")
        let cells = app.descendants(matching: .any).matching(predicate)

        for index in 0..<min(cells.count, 40) {
            let cell = cells.element(boundBy: index)
            if cell.exists, cell.isHittable {
                return cell
            }
        }
        return nil
    }
}
