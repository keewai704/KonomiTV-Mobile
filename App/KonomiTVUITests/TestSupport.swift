import UIKit
import XCTest

// MARK: - Shared configuration

enum TestTimeout {
    /// Ordinary interface transitions (loading a list, pushing a screen).
    static let ui: TimeInterval = 15
    /// Playback needs to buffer, connect and receive media.
    static let playback: TimeInterval = 45
}

enum TestSection: String, CaseIterable {
    case live
    case videos
    case settings

    var title: String {
        switch self {
        case .live: return "テレビ"
        case .videos: return "ビデオ"
        case .settings: return "設定"
        }
    }

    var tabIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

enum TestEnvironment {
    static let defaultServerURL = "http://127.0.0.1:7010"

    /// The mock server URL provided by the test runner (CI sets
    /// `TEST_RUNNER_KONOMITV_SERVER_URL`), falling back to the local default.
    static var serverURL: String {
        let raw = ProcessInfo.processInfo.environment["KONOMITV_SERVER_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? defaultServerURL : raw
    }
}

// MARK: - Launching

/// Launches the app in UI-testing mode.
///
/// `-UITesting` resets persisted settings and keychain state, and the
/// `KONOMITV_SERVER_URL` launch environment value configures the saved server
/// unless `-UITestingShowSetup` forces the first-run screen.
@MainActor
func launchApp(showSetup: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITesting"]
    if showSetup {
        app.launchArguments.append("-UITestingShowSetup")
    }
    app.launchEnvironment["KONOMITV_SERVER_URL"] = TestEnvironment.serverURL
    app.launch()
    return app
}

/// Base class for all UI tests: fails fast, and attaches a screenshot to the
/// test result whenever a test fails.
@MainActor
class KonomiTVUITestCase: XCTestCase, @unchecked Sendable {
    private(set) var app: XCUIApplication?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        attachFailureScreenshot()
        app = nil
        try await super.tearDown()
    }

    /// Launches the app and remembers it so `tearDown` can capture failures.
    @discardableResult
    func startApp(showSetup: Bool = false) -> XCUIApplication {
        // Also set here so fast-fail behavior does not depend on the
        // test runner invoking the async setUp override.
        continueAfterFailure = false
        let application = launchApp(showSetup: showSetup)
        app = application
        return application
    }

    private func attachFailureScreenshot() {
        guard let app,
              let testRun,
              !testRun.hasSucceeded,
              !testRun.hasBeenSkipped else {
            return
        }

        let screenshot: XCUIScreenshot
        if app.state == .notRunning || app.state == .unknown {
            screenshot = XCUIScreen.main.screenshot()
        } else {
            screenshot = app.screenshot()
        }

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "failure-\(name)"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Failure screenshot") { activity in
            activity.add(attachment)
        }
    }
}

// MARK: - Queries and waits

@MainActor
func uiElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
}

/// Polls the condition while servicing the run loop. This avoids fixed sleeps
/// and works for compound conditions that `waitForExistence` cannot express.
@MainActor
@discardableResult
func waitUntil(timeout: TimeInterval = TestTimeout.ui, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
}

/// Waits until the element's accessibility label equals `expected`.
@MainActor
func waitForLabel(
    _ element: XCUIElement,
    equals expected: String,
    timeout: TimeInterval = TestTimeout.ui
) -> Bool {
    let predicate = NSPredicate(format: "label == %@", expected)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
}

/// Whether the app is showing the regular-width sidebar layout.
@MainActor
func isRegularLayout(_ app: XCUIApplication, timeout: TimeInterval = TestTimeout.ui) -> Bool {
    let sidebar = uiElement(app, "sidebar")
    let tabBar = app.tabBars.firstMatch
    let tabItem = uiElement(app, "tab.live")

    var regular = false
    _ = waitUntil(timeout: timeout) {
        if sidebar.exists {
            regular = true
            return true
        }
        if tabBar.exists || tabItem.exists {
            regular = false
            return true
        }
        return false
    }
    return regular
}

/// Whether the main interface (setup finished) is visible.
@MainActor
func mainNavigationExists(in app: XCUIApplication, timeout: TimeInterval = TestTimeout.ui) -> Bool {
    let sidebar = uiElement(app, "sidebar")
    let tabBar = app.tabBars.firstMatch
    let livePicker = uiElement(app, "live.typePicker")

    return waitUntil(timeout: timeout) {
        sidebar.exists || tabBar.exists || livePicker.exists
    }
}

// MARK: - Navigation and interaction

/// Selects a top-level section, using the tab bar on compact widths and the
/// sidebar on regular widths. Falls back to positional tab taps when the
/// per-tab accessibility identifiers are not exposed by the tab bar.
@MainActor
func navigate(to section: TestSection, in app: XCUIApplication, timeout: TimeInterval = TestTimeout.ui) {
    let tabBar = app.tabBars.firstMatch
    let tabItem = uiElement(app, "tab.\(section.rawValue)")
    let sidebarRow = uiElement(app, "sidebar.\(section.rawValue)")

    let ready = waitUntil(timeout: timeout) {
        if tabBar.exists {
            return tabItem.exists || tabBar.buttons.count > section.tabIndex
        }
        return sidebarRow.exists
    }
    XCTAssertTrue(ready, "セクション「\(section.title)」へのナビゲーションが見つからない")

    if tabBar.exists, tabItem.exists {
        tabItem.tap()
        return
    }
    if sidebarRow.exists {
        sidebarRow.tap()
        return
    }
    if tabBar.exists {
        let button = tabBar.buttons.element(boundBy: section.tabIndex)
        if button.exists {
            button.tap()
            return
        }
    }
    XCTFail("セクション「\(section.title)」を選択できない")
}

/// Taps a segment of the live channel-type picker (e.g. "BS").
@MainActor
func selectChannelType(
    _ displayName: String,
    in app: XCUIApplication,
    timeout: TimeInterval = TestTimeout.ui
) {
    let picker = uiElement(app, "live.typePicker")
    XCTAssertTrue(picker.waitForExistence(timeout: timeout), "チャンネル種別ピッカーが表示されない")

    let buttonInPicker = picker.descendants(matching: .button)[displayName]
    let fallbackButton = app.buttons[displayName]

    let ready = waitUntil(timeout: timeout) {
        buttonInPicker.exists || fallbackButton.exists
    }
    XCTAssertTrue(ready, "チャンネル種別「\(displayName)」のボタンが見つからない")

    if buttonInPicker.exists {
        buttonInPicker.tap()
    } else {
        fallbackButton.tap()
    }
}

/// Replaces the contents of a text field without relying on selection menus.
@MainActor
func replaceText(
    in element: XCUIElement,
    with text: String,
    in app: XCUIApplication,
    timeout: TimeInterval = TestTimeout.ui
) {
    XCTAssertTrue(element.waitForExistence(timeout: timeout), "入力欄が表示されない")

    var attempts = 0
    while !element.isHittable, attempts < 4 {
        if app.keyboards.firstMatch.exists {
            dismissKeyboard(in: app)
        } else {
            app.swipeUp()
        }
        attempts += 1
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    element.tap()

    let current = (element.value as? String) ?? ""
    if !current.isEmpty {
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    element.typeText(text)
}

/// Dismisses the software keyboard (return-style key first, then a neutral
/// tap). The return key's label changes with the field's submit label (for
/// example "Go" for the setup URL field).
@MainActor
func dismissKeyboard(in app: XCUIApplication) {
    let keyboard = app.keyboards.firstMatch
    guard keyboard.exists else { return }

    let returnKeys: Set<String> = ["return", "go", "done", "next", "改行", "完了", "次へ"]
    let keys = keyboard.buttons
    for index in 0..<keys.count {
        let key = keys.element(boundBy: index)
        guard key.exists, key.isHittable else { continue }
        if returnKeys.contains(key.label.lowercased()) {
            key.tap()
            _ = waitUntil(timeout: 3) { !app.keyboards.firstMatch.exists }
            return
        }
    }

    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
}

/// Taps an element once it is hittable. Scrolls the content or dismisses the
/// keyboard while waiting, instead of sleeping for a fixed duration.
@MainActor
func tapWhenHittable(
    _ element: XCUIElement,
    in app: XCUIApplication,
    timeout: TimeInterval = TestTimeout.ui
) {
    XCTAssertTrue(element.waitForExistence(timeout: timeout), "タップ対象が表示されない")

    let deadline = Date().addingTimeInterval(timeout)
    var keyboardDismissAttempts = 0
    while Date() < deadline {
        if element.exists, element.isHittable {
            element.tap()
            return
        }
        if app.keyboards.firstMatch.exists, keyboardDismissAttempts < 2 {
            keyboardDismissAttempts += 1
            dismissKeyboard(in: app)
        } else {
            app.swipeUp()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    XCTAssertTrue(element.isHittable, "タップ対象が操作可能にならない")
    if element.exists {
        element.tap()
    }
}

/// Taps the setup screen's connect button, submitting via the keyboard's
/// return key when it is obscured.
@MainActor
func submitSetupConnection(in app: XCUIApplication, timeout: TimeInterval = TestTimeout.ui) {
    let connectButton = uiElement(app, "setup.connectButton")
    XCTAssertTrue(connectButton.waitForExistence(timeout: timeout), "接続ボタンが表示されない")

    if !connectButton.isHittable {
        if app.keyboards.firstMatch.exists {
            dismissKeyboard(in: app)
        }
        if !connectButton.isHittable {
            app.swipeUp()
        }
    }

    if connectButton.exists, connectButton.isHittable {
        connectButton.tap()
    }
}

/// Scrolls a container until the target exists (lazy grids only materialize
/// their off-screen rows as they are scrolled into range).
@MainActor
@discardableResult
func scrollUntilVisible(
    _ target: XCUIElement,
    in container: XCUIElement,
    maxSwipes: Int = 20
) -> Bool {
    if target.exists {
        return true
    }
    for _ in 0..<maxSwipes {
        container.swipeUp()
        if target.waitForExistence(timeout: 2) {
            return true
        }
    }
    return target.exists
}

/// Rotates the simulator and waits (best effort) for the app window to match.
@MainActor
func rotate(
    _ orientation: UIDeviceOrientation,
    in app: XCUIApplication,
    timeout: TimeInterval = TestTimeout.ui
) {
    XCUIDevice.shared.orientation = orientation

    let landscape = orientation.isLandscape
    let window = app.windows.firstMatch
    _ = waitUntil(timeout: timeout) {
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return false }
        return (frame.width > frame.height) == landscape
    }
}
