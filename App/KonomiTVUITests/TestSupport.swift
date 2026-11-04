import OSLog
import UIKit
import XCTest

// MARK: - Shared configuration

enum TestTimeout {
    /// Ordinary interface transitions (loading a list, pushing a screen).
    static let ui: TimeInterval = 15
    /// Playback needs to buffer, connect and receive media.
    static let playback: TimeInterval = 45
}

/// A section of the app, reachable from the sidebar (regular width) or from the
/// tab bar plus the マイページ hub (compact width).
enum TestSection: String, CaseIterable {
    case live
    case timetable
    case videos
    case mylist
    case history
    case captures
    case reservations
    case offline
    case settings

    var title: String {
        switch self {
        case .live: return "テレビ"
        case .timetable: return "番組表"
        case .videos: return "ビデオ"
        case .mylist: return "マイリスト"
        case .history: return "視聴履歴"
        case .captures: return "キャプチャ"
        case .reservations: return "録画予約"
        case .offline: return "オフライン"
        case .settings: return "設定"
        }
    }

    /// Compact width tab that contains the section.
    /// Title of the compact tab the section lives in.
    var compactTabTitle: String {
        switch self {
        case .live: return "テレビ"
        case .videos: return "ビデオ"
        case .timetable, .mylist, .history, .captures, .reservations, .offline, .settings: return "マイページ"
        }
    }

    var compactTab: String {
        switch self {
        case .live: return "live"
        case .videos: return "videos"
        case .timetable, .mylist, .history, .captures, .reservations, .offline, .settings: return "mypage"
        }
    }

    /// マイページ row of the section, when it is not a tab of its own.
    var mypageRowIdentifier: String? {
        switch self {
        case .timetable: return "mypage.timetable"
        case .mylist: return "mypage.mylist"
        case .history: return "mypage.history"
        case .captures: return "mypage.captures"
        case .reservations: return "mypage.reservations"
        case .offline: return "mypage.offline"
        case .settings: return "mypage.settings"
        case .live, .videos: return nil
        }
    }
}

enum TestEnvironment {
    static let defaultServerURL = "http://127.0.0.1:7010"

    /// The mock server URL provided by the test runner (CI sets
    /// `TEST_RUNNER_KONOMITV_SERVER_URL`; the `TEST_RUNNER_` prefix is stripped
    /// for the app under test), falling back to the local default.
    static var serverURL: String {
        let environment = ProcessInfo.processInfo.environment
        let raw = (environment["KONOMITV_SERVER_URL"]
            ?? environment["TEST_RUNNER_KONOMITV_SERVER_URL"]
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? defaultServerURL : raw
    }
}

// MARK: - Mock server

/// Blocking access to the mock server's test endpoints.
enum MockServerControl {
    static var baseURL: URL {
        URL(string: TestEnvironment.serverURL)
            ?? URL(string: TestEnvironment.defaultServerURL)!
    }

    /// `POST /__mock/reset`: restores the fixtures, the client settings and the
    /// counters, so every test starts from the same state.
    @discardableResult
    static func reset() -> Int {
        var request = URLRequest(url: baseURL.appendingPathComponent("__mock/reset"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        // The first request from a simulator that has just booted can fail
        // before its network is up, so retry a few times.
        var status = -1
        for attempt in 0..<4 {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 2)
            }
            status = perform(request).status
            if status == 200 {
                break
            }
        }
        return status
    }

    /// `POST /__mock/config`: changes one or more mock server switches.
    @discardableResult
    static func setConfig(_ values: [String: Any]) -> Int {
        var request = URLRequest(url: baseURL.appendingPathComponent("__mock/config"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: values)
        return perform(request).status
    }

    /// `POST /__mock/config {"captures_library": false}`: makes the mock
    /// behave like KonomiTV v0.14.1, which has no captures library.
    @discardableResult
    static func setCapturesLibrary(_ available: Bool) -> Int {
        setConfig(["captures_library": available])
    }

    /// `POST /__mock/config {"offline_stream": false}`: makes the mock behave
    /// like KonomiTV v0.14.1, which has no offline save stream.
    @discardableResult
    static func setOfflineStream(_ available: Bool) -> Int {
        setConfig(["offline_stream": available])
    }

    /// `POST /__mock/config {"offline_stream_truncate": true}`: drops the save
    /// stream after two segments, without its terminator record.
    @discardableResult
    static func setOfflineStreamTruncation(_ truncate: Bool) -> Int {
        setConfig(["offline_stream_truncate": truncate])
    }

    /// `GET /__mock/stats`.
    static func stats() -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent("__mock/stats"))
        request.timeoutInterval = 10
        return perform(request).json ?? [:]
    }

    static func intValue(_ key: String) -> Int {
        guard let value = stats()[key] else { return 0 }
        if let number = value as? NSNumber { return number.intValue }
        if let intValue = value as? Int { return intValue }
        return 0
    }

    private static func perform(_ request: URLRequest) -> (status: Int, json: [String: Any]?) {
        let semaphore = DispatchSemaphore(value: 0)
        var status = -1
        var json: [String: Any]?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let data, let object = try? JSONSerialization.jsonObject(with: data) {
                json = object as? [String: Any]
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 15)
        return (status, json)
    }
}

// MARK: - Launching

/// Launches the app in UI-testing mode.
///
/// `-UITesting` resets persisted settings and keychain state, and the
/// `KONOMITV_SERVER_URL` launch environment value configures the saved server
/// unless `-UITestingShowSetup` forces the first-run screen.
@MainActor
func launchApp(
    showSetup: Bool = false,
    disableAutoPiP: Bool = false,
    shortHistoryThreshold: Bool = false,
    disableASWebAuth: Bool = false,
    keepControls: Bool = false
) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITesting"]
    if showSetup {
        app.launchArguments.append("-UITestingShowSetup")
    }
    if disableAutoPiP {
        // Keeps playback inline so background playback can be tested on its
        // own, without picture in picture taking over the player.
        app.launchArguments.append("-UITestingDisableAutoPiP")
    }
    if shortHistoryThreshold {
        // Adds the watch history after 2 s instead of 30 s of playback.
        app.launchArguments.append("-UITestingShortHistoryThreshold")
    }
    if disableASWebAuth {
        // Links the Niconico account with URLSession instead of showing the
        // system ASWebAuthenticationSession sheet (CI has no user to tap it).
        app.launchArguments.append("-UITestingDisableASWebAuth")
    }
    if keepControls {
        // The player controls stay until the picture is tapped, so a test can
        // query a control and then operate it without the controls hiding in
        // between (a query alone can take seconds on CI).
        app.launchArguments.append("-UITestingKeepControls")
    }
    app.launchEnvironment["KONOMITV_SERVER_URL"] = TestEnvironment.serverURL
    app.launch()
    return app
}

/// Base class for all UI tests: resets the mock server and fails fast, and
/// attaches a screenshot to the test result whenever a test fails.
@MainActor
class KonomiTVUITestCase: XCTestCase, @unchecked Sendable {
    private(set) var app: XCUIApplication?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        // Marks where this test's lines start in the app log CI streams from
        // the simulator (scripts/report-ui-tests.py splits the log on it).
        Self.log.notice("test-start \(self.testIdentifier, privacy: .public)")
        // Every test starts from the mock server's initial state (settings,
        // deleted recordings and counters).
        XCTAssertEqual(MockServerControl.reset(), 200, "モックサーバーをリセットできない")
    }

    override func tearDown() async throws {
        attachFailureScreenshot()
        app = nil
        try await super.tearDown()
    }

    private static let log = Logger(subsystem: "com.github.keewai704.KonomiTV", category: "test")

    /// "CommentUITests/testPastLogCommentsAppearForRecordedVideo", from the
    /// XCTest name "-[KonomiTVUITests.CommentUITests testPast…]".
    private var testIdentifier: String {
        let parts = name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]")).split(separator: " ")
        let type = parts.first?.split(separator: ".").last ?? ""
        return "\(type)/\(parts.last ?? "")"
    }

    /// Logs what was on screen when the test failed, so the CI report shows
    /// it with the test's app log (the screenshot is only in the result
    /// bundle). The status labels (`player.state`, `playback.position`, ...)
    /// are part of it. One log line per hierarchy line: a unified log message
    /// is cut off at about 1 KB.
    private func printAccessibilityHierarchy(of app: XCUIApplication) {
        guard app.state == .runningForeground else {
            Self.log.notice("ui at failure: app state \(app.state.rawValue, privacy: .public)")
            return
        }
        let lines = app.debugDescription.split(separator: "\n", omittingEmptySubsequences: false)
        Self.log.notice("ui at failure (\(lines.count, privacy: .public) lines)")
        for line in lines.prefix(300) {
            Self.log.notice("ui | \(String(line), privacy: .public)")
        }
    }

    /// Launches the app and remembers it so `tearDown` can capture failures.
    @discardableResult
    func startApp(
        showSetup: Bool = false,
        disableAutoPiP: Bool = false,
        shortHistoryThreshold: Bool = false,
        disableASWebAuth: Bool = false,
        keepControls: Bool = false
    ) -> XCUIApplication {
        // Also set here so fast-fail behavior does not depend on the
        // test runner invoking the async setUp override.
        continueAfterFailure = false
        let application = launchApp(
            showSetup: showSetup,
            disableAutoPiP: disableAutoPiP,
            shortHistoryThreshold: shortHistoryThreshold,
            disableASWebAuth: disableASWebAuth,
            keepControls: keepControls
        )
        app = application
        return application
    }

    /// Logs in with the mock account (test / test).
    func login(in app: XCUIApplication) {
        let username = uiElement(app, "settings.username")
        XCTAssertTrue(username.waitForExistence(timeout: TestTimeout.ui), "ユーザー名欄が表示されない")
        replaceText(in: username, with: "test", in: app)

        let password = uiElement(app, "settings.password")
        replaceText(in: password, with: "test", in: app)

        tapWhenHittable(uiElement(app, "settings.loginButton"), in: app)

        XCTAssertTrue(
            uiElement(app, "settings.userName").waitForExistence(timeout: TestTimeout.ui),
            "ログイン後にユーザー名が表示されない"
        )
    }

    private func attachFailureScreenshot() {
        guard let app,
              let testRun,
              !testRun.hasSucceeded,
              !testRun.hasBeenSkipped else {
            return
        }

        printAccessibilityHierarchy(of: app)

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
    // SwiftUI can expose one identifier on several nested elements (for
    // example a sidebar List cell and its Label), so resolve the first match.
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
}

/// Accessibility label of the first element with the given identifier.
@MainActor
func label(of identifier: String, in app: XCUIApplication) -> String {
    uiElement(app, identifier).label
}

/// Parsed integer value of the first element with the given identifier.
@MainActor
func intLabel(of identifier: String, in app: XCUIApplication) -> Int? {
    Int(label(of: identifier, in: app))
}

/// Waits for a fixed amount of time while keeping the run loop serviced, so
/// XCTest can update its snapshot of the app.
@MainActor
func waitSeconds(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { break }
        RunLoop.current.run(until: Date().addingTimeInterval(min(remaining, 0.1)))
    }
}

/// Sends the app to the home screen, waits, and brings it back. The playback
/// status elements are then waited for, so callers can read them immediately.
@MainActor
func sendToBackgroundAndReturn(app: XCUIApplication, after seconds: TimeInterval) {
    XCUIDevice.shared.press(.home)
    waitSeconds(seconds)
    app.activate()
    _ = uiElement(app, "playback.state").waitForExistence(timeout: TestTimeout.ui)
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

/// Opens a section on both layouts: the sidebar row on regular widths, the tab
/// (plus a マイページ row for the sections without a tab) on compact widths.
@MainActor
func openSection(
    _ section: TestSection,
    in app: XCUIApplication,
    timeout: TimeInterval = TestTimeout.ui
) {
    let navigationReady = waitUntil(timeout: timeout) {
        uiElement(app, "sidebar").exists
            || app.tabBars.firstMatch.exists
            || uiElement(app, "tab.live").exists
    }
    XCTAssertTrue(navigationReady, "ナビゲーションが表示されない")

    if isRegularLayout(app, timeout: timeout) {
        let row = uiElement(app, "sidebar.\(section.rawValue)")
        XCTAssertTrue(
            row.waitForExistence(timeout: timeout),
            "サイドバーの「\(section.title)」が見つからない"
        )
        row.tap()
        return
    }

    // The tab bar does not always carry the label's identifier over to its
    // buttons (seen on the first launch in a fresh simulator), so the button
    // is also looked up by its title.
    let tab = uiElement(app, "tab.\(section.compactTab)")
    let titled = app.tabBars.buttons[section.compactTabTitle]
    XCTAssertTrue(
        waitUntil(timeout: timeout) { tab.exists || titled.exists },
        "タブ「\(section.compactTab)」が見つからない"
    )
    (tab.exists ? tab : titled).tap()

    guard let rowIdentifier = section.mypageRowIdentifier else { return }

    let row = uiElement(app, rowIdentifier)
    if !row.waitForExistence(timeout: 3) {
        // 別の画面を開いたままのマイページは、タブを選び直すと先頭に戻る。
        tab.tap()
    }
    XCTAssertTrue(
        row.waitForExistence(timeout: timeout),
        "マイページの「\(section.title)」が見つからない"
    )
    row.tap()
}

/// Taps the navigation bar back button (compact and regular widths).
@MainActor
func navigateBack(in app: XCUIApplication, timeout: TimeInterval = TestTimeout.ui) {
    let identified = app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch
    if identified.waitForExistence(timeout: 3), identified.isHittable {
        identified.tap()
        return
    }

    let fallback = app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(fallback.waitForExistence(timeout: timeout), "戻るボタンが表示されない")
    fallback.tap()
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

    // Screens with a multi-line field put a 完了 button above the keyboard.
    let done = app.buttons["keyboard.done"]
    if done.exists, done.isHittable {
        done.tap()
        _ = waitUntil(timeout: 3) { !app.keyboards.firstMatch.exists }
        return
    }

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

/// Taps an item of an open SwiftUI `Menu`. Right after the menu opens its
/// items can still be animating and report an invalid activation point, so
/// wait for them to settle and fall back to tapping the frame's center (a
/// swipe, as `tapWhenHittable` does, would close the menu).
@MainActor
func tapMenuItem(_ element: XCUIElement, timeout: TimeInterval = 3) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if element.exists, element.isHittable {
            element.tap()
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
}

/// Flips a SwiftUI Toggle and returns whether its value changed.
///
/// Tapping the middle of a Toggle row does not flip it, so the switch inside
/// is tapped. A tap right after the screen appears can be dropped (the value
/// stays as it was), so the tap is repeated until the value changes.
@MainActor
func flipSwitch(_ toggle: XCUIElement, in app: XCUIApplication) -> Bool {
    XCTAssertTrue(toggle.waitForExistence(timeout: TestTimeout.ui), "スイッチが表示されない")
    let before = toggle.value as? String
    let inner = toggle.switches.firstMatch
    for _ in 0..<3 {
        tapWhenHittable(inner.exists ? inner : toggle, in: app)
        if waitUntil(timeout: 3, { (toggle.value as? String) != before }) {
            return true
        }
    }
    return false
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
