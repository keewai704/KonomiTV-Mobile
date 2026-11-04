import XCTest

/// キャプチャ: capturing the player's frame with the web client's EXIF
/// metadata, the captures library screens and the v0.14.1 fallback.
///
/// The mock server reads the EXIF of an uploaded capture (like the real
/// server's CaptureScanTask), so these tests check the whole pipeline: frame
/// grab, caption / comment compositing, EXIF, upload and the library views.
final class CaptureUITests: KonomiTVUITestCase {

    // MARK: - Helpers

    /// Logs in through 設定, where the login form lives.
    private func loginThroughSettings(in app: XCUIApplication) {
        openSection(.settings, in: app)
        login(in: app)
    }

    private func waitForPlaying(in app: XCUIApplication) {
        XCTAssertTrue(
            uiElement(app, "player.view").waitForExistence(timeout: TestTimeout.playback),
            "プレイヤーが表示されない"
        )
        let state = uiElement(app, "player.state")
        XCTAssertTrue(state.waitForExistence(timeout: TestTimeout.playback), "再生状態が取得できない")
        XCTAssertTrue(
            waitForLabel(state, equals: "playing", timeout: TestTimeout.playback),
            "再生が playing にならない (状態: \(state.label))"
        )
    }

    private func openLive(in app: XCUIApplication) {
        openSection(.live, in: app)
        let channel = uiElement(app, "live.channel.gr011")
        XCTAssertTrue(channel.waitForExistence(timeout: TestTimeout.ui), "ライブチャンネルが表示されない")
        channel.tap()
        waitForPlaying(in: app)
    }

    private func openVideo(in app: XCUIApplication) {
        openSection(.videos, in: app)
        let item = uiElement(app, "videos.recent.1")
        XCTAssertTrue(item.waitForExistence(timeout: TestTimeout.ui), "先頭のビデオが表示されない")
        item.tap()
        waitForPlaying(in: app)
    }

    /// Uploads the mock server has received, oldest first.
    private func uploads() -> [[String: Any]] {
        (MockServerControl.stats()["capture_uploads"] as? [[String: Any]]) ?? []
    }

    private func metadata(of upload: [String: Any]) -> [String: Any] {
        (upload["metadata"] as? [String: Any]) ?? [:]
    }

    private func captureCount(in app: XCUIApplication) -> Int {
        intLabel(of: "capture.count", in: app) ?? 0
    }

    private func tapCapture(_ identifier: String, in app: XCUIApplication) {
        let button = uiElement(app, identifier)
        XCTAssertTrue(button.waitForExistence(timeout: TestTimeout.ui), "\(identifier) が見つからない")
        tapWhenHittable(button, in: app)
    }

    private func waitForUpload(where predicate: ([String: Any]) -> Bool) -> Bool {
        waitUntil(timeout: TestTimeout.playback) {
            self.uploads().contains(where: predicate)
        }
    }

    /// Capture_20261104-003657.jpg (the web client's default filename pattern).
    private func matchesDefaultPattern(_ filename: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^Capture_\\d{8}-\\d{6}\\.jpg$") else {
            return false
        }
        let range = NSRange(filename.startIndex..., in: filename)
        return regex.firstMatch(in: filename, range: range) != nil
    }

    private func selectCaptureTab(_ title: String, in app: XCUIApplication) {
        let picker = uiElement(app, "captures.tabs")
        XCTAssertTrue(picker.waitForExistence(timeout: TestTimeout.ui), "キャプチャのタブが表示されない")

        let inPicker = picker.descendants(matching: .button)[title]
        let fallback = app.buttons[title]
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { inPicker.exists || fallback.exists },
            "タブ「\(title)」が見つからない"
        )
        tapWhenHittable(inPicker.exists ? inPicker : fallback, in: app)
    }

    // MARK: - Player capture

    func testVideoCaptureUploadsNormalImageWithProgramMetadata() {
        let app = startApp(disableAutoPiP: true)
        openVideo(in: app)

        tapCapture("player.capture", in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) { self.captureCount(in: app) >= 1 },
            "キャプチャが生成されない (capture.count=\(captureCount(in: app)))"
        )

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) { !self.uploads().isEmpty },
            "キャプチャがアップロードされない"
        )

        let normal = uploads().first { matchesDefaultPattern($0["filename"] as? String ?? "") }
        guard let normal else {
            XCTFail("既定のファイル名パターンのキャプチャがない: \(uploads().map { $0["filename"] ?? "?" })")
            return
        }

        // The EXIF metadata must carry the program of the recorded video and
        // say that no comment was composited into the image.
        let values = metadata(of: normal)
        XCTAssertEqual(values["title"] as? String, "ニュース7")
        XCTAssertEqual(values["network_id"] as? Int, 32736)
        XCTAssertEqual(values["service_id"] as? Int, 1024)
        XCTAssertEqual(values["event_id"] as? Int, 10001)
        XCTAssertEqual(values["is_comment_composited"] as? Bool, false)
        XCTAssertNotNil(normal["date_time_original"] as? String, "DateTimeOriginal が書かれていない")
        XCTAssertTrue(
            (normal["filename"] as? String ?? "").contains(".jpg"),
            "JPEG でない"
        )
    }

    func testCommentCaptureMarksCommentsAsComposited() {
        let app = startApp(disableAutoPiP: true)
        openVideo(in: app)

        let capture = uiElement(app, "player.capture")
        XCTAssertTrue(capture.waitForExistence(timeout: TestTimeout.ui), "player.capture が見つからない")
        capture.press(forDuration: 1.2)
        let withComments = uiElement(app, "player.capture.comments")
        XCTAssertTrue(withComments.waitForExistence(timeout: TestTimeout.ui), "コメント付きキャプチャのメニューが表示されない")
        tapMenuItem(withComments)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) { self.captureCount(in: app) >= 1 },
            "コメント付きキャプチャが生成されない (capture.count=\(captureCount(in: app)))"
        )

        XCTAssertTrue(
            waitForUpload { self.metadata(of: $0)["is_comment_composited"] as? Bool == true },
            "コメントが合成されたキャプチャがアップロードされない"
        )
    }

    func testLiveCaptureIsOfferedForTelevisionChannels() {
        let app = startApp(disableAutoPiP: true)
        openLive(in: app)
        // libVLC can only snapshot a decoded picture; a live stream takes longer
        // to show its first one than a recorded video.
        waitForPlaying(in: app)

        tapCapture("player.capture", in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) { self.captureCount(in: app) >= 1 },
            "ライブのキャプチャが生成されない"
        )
        XCTAssertTrue(
            waitForUpload(where: { upload in
                let values = self.metadata(of: upload)
                return (values["title"] as? String)?.isEmpty == false
                    && (values["start_time"] as? String) != nil
            }),
            "ライブのキャプチャがアップロードされない"
        )
    }

    // MARK: - Library

    func testCapturesTimelineOpensViewerAndTogglesFavorite() {
        let app = startApp(disableAutoPiP: true)
        loginThroughSettings(in: app)
        openSection(.captures, in: app)

        let timeline = uiElement(app, "captures.timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: TestTimeout.ui), "タイムラインが表示されない")

        // Capture 2 is not in the fixture's favorite list.
        let item = uiElement(app, "captures.item.2")
        XCTAssertTrue(item.waitForExistence(timeout: TestTimeout.ui), "キャプチャが表示されない")
        tapWhenHittable(item, in: app)

        let viewer = uiElement(app, "capture.viewer")
        let favorite = uiElement(app, "capture.favorite")
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { viewer.exists || favorite.exists },
            "ビューアが開かない"
        )
        XCTAssertTrue(favorite.waitForExistence(timeout: TestTimeout.ui), "お気に入りボタンがない")
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { (favorite.value as? String) == "false" },
            "お気に入りでないキャプチャのお気に入り状態が false でない (\(favorite.value ?? "nil"))"
        )
        tapWhenHittable(favorite, in: app)

        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) { (favorite.value as? String) == "true" },
            "お気に入りにできない (\(favorite.value ?? "nil"))"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.ui) {
                MockServerControl.intValue("capture_favorite_add_count") >= 1
            },
            "お気に入りがサーバーに送られていない"
        )
    }

    func testProgramsTabShowsAlbumsAndTheirCaptures() {
        let app = startApp(disableAutoPiP: true)
        loginThroughSettings(in: app)
        openSection(.captures, in: app)

        selectCaptureTab("番組", in: app)

        let programs = uiElement(app, "captures.programs")
        XCTAssertTrue(programs.waitForExistence(timeout: TestTimeout.ui), "番組の一覧が表示されない")

        let album = uiElement(app, "captures.program.1")
        XCTAssertTrue(album.waitForExistence(timeout: TestTimeout.ui), "番組のアルバムが表示されない")
        tapWhenHittable(album, in: app)

        XCTAssertTrue(
            uiElement(app, "captures.item.1").waitForExistence(timeout: TestTimeout.ui),
            "番組のキャプチャが表示されない"
        )
    }

    func testTagsTabListsTags() {
        let app = startApp(disableAutoPiP: true)
        loginThroughSettings(in: app)
        openSection(.captures, in: app)

        selectCaptureTab("タグ", in: app)

        XCTAssertTrue(
            uiElement(app, "captures.tags").waitForExistence(timeout: TestTimeout.ui),
            "タグの一覧が表示されない"
        )
        XCTAssertTrue(
            uiElement(app, "captures.tag.1").waitForExistence(timeout: TestTimeout.ui),
            "タグが表示されない"
        )
    }

    // MARK: - v0.14.1 fallback

    func testCapturesSectionHiddenWithoutLibraryButUploadStillWorks() {
        XCTAssertEqual(MockServerControl.setCapturesLibrary(false), 200)

        let app = startApp(disableAutoPiP: true)
        XCTAssertTrue(mainNavigationExists(in: app), "ナビゲーションが表示されない")

        if isRegularLayout(app, timeout: TestTimeout.ui) {
            XCTAssertFalse(
                waitUntil(timeout: 3) { uiElement(app, "sidebar.captures").exists },
                "キャプチャのライブラリがないサーバーでサイドバーにキャプチャが表示されている"
            )
        } else {
            let tab = uiElement(app, "tab.mypage")
            XCTAssertTrue(tab.waitForExistence(timeout: TestTimeout.ui), "マイページのタブがない")
            tab.tap()
            XCTAssertFalse(
                waitUntil(timeout: 3) { uiElement(app, "mypage.captures").exists },
                "キャプチャのライブラリがないサーバーでマイページにキャプチャが表示されている"
            )
        }

        // Capturing still works: v0.14.1 has the upload endpoint.
        openVideo(in: app)
        tapCapture("player.capture", in: app)
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) { self.captureCount(in: app) >= 1 },
            "キャプチャが生成されない"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestTimeout.playback) {
                MockServerControl.intValue("capture_upload_count") >= 1
            },
            "v0.14.1 相当のサーバーにキャプチャがアップロードされない"
        )

        // Restore the default for the next test.
        MockServerControl.reset()
    }
}
