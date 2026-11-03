import Foundation
import XCTest
@testable import KonomiKit

final class ClientSettingsTests: XCTestCase {

    private func makeSettings() throws -> ClientSettings {
        try JSONCoding.decode(ClientSettings.self, from: Fixtures.clientSettingsJSON)
    }

    // MARK: Decoding / encoding

    func testTypedAccessorsReadWebClientKeys() throws {
        let settings = try makeSettings()

        XCTAssertEqual(settings.lastSyncedAt, 1762174800.25)
        XCTAssertEqual(settings.pinnedChannelIDs, ["gr011", "bs101"])
        XCTAssertEqual(settings.videoWatchedHistoryMaxCount, 50)
        XCTAssertFalse(settings.tvChannelSortByJikkyoForce)
        XCTAssertFalse(settings.use28HourClock)
        XCTAssertTrue(settings.timetableDimShoppingPrograms)

        XCTAssertEqual(settings.mylist.count, 2)
        XCTAssertEqual(settings.mylist[0].type, .series)
        XCTAssertEqual(settings.mylist[0].id, 1)
        XCTAssertEqual(settings.mylist[0].createdAt, 1762174800)
        XCTAssertEqual(settings.mylist[1].type, .recordedProgram)
        XCTAssertEqual(settings.mylist[1].id, 4)

        XCTAssertEqual(settings.watchedHistory.count, 1)
        let history = try XCTUnwrap(settings.watchedHistory.first)
        XCTAssertEqual(history.videoID, 4)
        XCTAssertEqual(history.lastPlaybackPosition, 123.5)
        XCTAssertEqual(history.createdAt, 1762174800)
        XCTAssertEqual(history.updatedAt, 1762175100)
        XCTAssertEqual(history.id, 4)

        // A key the app does not understand is still there.
        XCTAssertNotNil(settings.value(forKey: "unknown_future_key"))
        XCTAssertEqual(settings["unknown_future_key"]?["flag"]?.boolValue, false)
    }

    func testTypedAccessorsFallBackToWebClientDefaults() throws {
        let settings = ClientSettings()
        XCTAssertEqual(settings.lastSyncedAt, 0)
        XCTAssertEqual(settings.pinnedChannelIDs, [])
        XCTAssertTrue(settings.mylist.isEmpty)
        XCTAssertTrue(settings.watchedHistory.isEmpty)
        XCTAssertEqual(settings.videoWatchedHistoryMaxCount, 50)
        XCTAssertFalse(settings.tvChannelSortByJikkyoForce)
        XCTAssertFalse(settings.use28HourClock)
        XCTAssertTrue(settings.timetableDimShoppingPrograms)
        XCTAssertTrue(settings.values.isEmpty)
    }

    func testTypedSettersWriteWebClientKeys() throws {
        var settings = try makeSettings()
        settings.lastSyncedAt = 1762180000
        settings.pinnedChannelIDs = ["gr021"]
        settings.videoWatchedHistoryMaxCount = 12
        settings.tvChannelSortByJikkyoForce = true
        settings.use28HourClock = true
        settings.timetableDimShoppingPrograms = false

        XCTAssertEqual(settings["last_synced_at"]?.numberValue, 1762180000)
        XCTAssertEqual(settings["pinned_channel_ids"]?.arrayValue?.first?.stringValue, "gr021")
        XCTAssertEqual(settings["video_watched_history_max_count"]?.intValue, 12)
        XCTAssertEqual(settings["tv_channel_sort_by_jikkyo_force"]?.boolValue, true)
        XCTAssertEqual(settings["use_28hour_clock"]?.boolValue, true)
        XCTAssertEqual(settings["timetable_dim_shopping_programs"]?.boolValue, false)

        let data = try JSONCoding.encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["last_synced_at"] as? NSNumber)?.doubleValue, 1762180000)
        XCTAssertEqual(object["video_watched_history_max_count"] as? Int, 12)
        XCTAssertEqual(object["tv_channel_sort_by_jikkyo_force"] as? Bool, true)
    }

    func testUnknownKeysRoundTripUnchanged() throws {
        let original = try makeSettings()
        let data = try JSONCoding.encode(original)
        let decoded = try JSONCoding.decode(ClientSettings.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.keys, original.keys)
        XCTAssertEqual(
            decoded["unknown_future_key"],
            JSONValue.object([
                "nested": .array([.number(1), .string("two"), .bool(true), .null]),
                "flag": .bool(false),
            ])
        )
        // Keys the app knows nothing about (the web client syncs them) survive too.
        for key in ["timetable_genre_colors", "muted_comment_keywords", "saved_twitter_hashtags"] {
            XCTAssertNotNil(decoded.value(forKey: key), "missing \(key)")
            XCTAssertEqual(decoded.value(forKey: key), original.value(forKey: key))
        }
    }

    func testUnknownKeysArePreservedWhenUpdatingOneValue() throws {
        let original = try makeSettings()
        var settings = original
        settings.pinnedChannelIDs = ["bs101"]

        let data = try JSONCoding.encode(settings)
        let decoded = try JSONCoding.decode(ClientSettings.self, from: data)
        XCTAssertEqual(decoded.pinnedChannelIDs, ["bs101"])
        XCTAssertEqual(decoded["unknown_future_key"], original["unknown_future_key"])
        XCTAssertEqual(decoded["timetable_genre_colors"], original["timetable_genre_colors"])
        XCTAssertEqual(decoded.keys.count, original.keys.count)
    }

    func testJSONValueDistinguishesKinds() throws {
        let json = #"{"b":true,"i":50,"d":1.5,"s":"x","a":[1],"o":{"k":null},"n":null}"#
        let value = try JSONCoding.decode(JSONValue.self, from: json)
        XCTAssertEqual(value["b"], .bool(true))
        XCTAssertEqual(value["i"], .number(50))
        XCTAssertEqual(value["i"]?.intValue, 50)
        XCTAssertEqual(value["d"]?.numberValue, 1.5)
        XCTAssertEqual(value["s"]?.stringValue, "x")
        XCTAssertEqual(value["a"]?.arrayValue?.count, 1)
        XCTAssertEqual(value["o"]?["k"], JSONValue.null)
        XCTAssertEqual(value["n"], JSONValue.null)

        // Round trip keeps integers as integers.
        let data = try JSONCoding.encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["i"] as? Int, 50)
        XCTAssertEqual(object["b"] as? Bool, true)
        XCTAssertEqual(try JSONCoding.decode(JSONValue.self, from: data), value)
    }

    // MARK: My List rules

    func testMylistAddRemoveToggle() {
        let first = MylistItem(type: .recordedProgram, id: 4, createdAt: 100)
        let second = MylistItem(type: .series, id: 4, createdAt: 200)

        var list = ClientSettingsRules.addMylistItem(first, to: [])
        XCTAssertEqual(list, [first])
        // Adding twice is a no-op (the web client checks membership first).
        list = ClientSettingsRules.addMylistItem(first, to: list)
        XCTAssertEqual(list, [first])

        // The same numeric ID on a different type is a different entry.
        list = ClientSettingsRules.addMylistItem(second, to: list)
        XCTAssertEqual(list, [first, second])

        var settings = ClientSettings()
        settings.addMylistItem(first)
        settings.addMylistItem(second)
        XCTAssertTrue(settings.isInMylist(type: .recordedProgram, id: 4))
        XCTAssertTrue(settings.isInMylist(type: .series, id: 4))

        settings.removeMylistItem(type: .recordedProgram, id: 4)
        XCTAssertFalse(settings.isInMylist(type: .recordedProgram, id: 4))
        XCTAssertTrue(settings.isInMylist(type: .series, id: 4))

        // Toggling adds when missing and removes when present.
        XCTAssertTrue(settings.toggleMylistItem(type: .recordedProgram, id: 9, now: 300))
        XCTAssertTrue(settings.isInMylist(type: .recordedProgram, id: 9))
        XCTAssertFalse(settings.toggleMylistItem(type: .recordedProgram, id: 9, now: 400))
        XCTAssertFalse(settings.isInMylist(type: .recordedProgram, id: 9))
        XCTAssertEqual(settings.mylist.map { $0.id }, [4])
    }

    func testMylistToggleOnExistingFixture() throws {
        var settings = try makeSettings()
        XCTAssertTrue(settings.isInMylist(type: .series, id: 1))
        XCTAssertFalse(settings.toggleMylistItem(type: .series, id: 1, now: 1762175000))
        XCTAssertEqual(settings.mylist.count, 1)
        XCTAssertEqual(settings.mylist.first?.type, .recordedProgram)
    }

    // MARK: Watched history rules

    func testWatchedHistoryInsertsNewEntryAtFront() {
        let existing = [
            WatchedHistoryItem(videoID: 1, lastPlaybackPosition: 10, createdAt: 100, updatedAt: 100),
            WatchedHistoryItem(videoID: 2, lastPlaybackPosition: 20, createdAt: 200, updatedAt: 200),
        ]
        let updated = ClientSettingsRules.recordWatchedHistory(
            existing,
            videoID: 3,
            position: 30,
            now: 300,
            maxCount: 50
        )
        XCTAssertEqual(updated.map { $0.videoID }, [3, 1, 2])
        XCTAssertEqual(updated.first?.lastPlaybackPosition, 30)
        XCTAssertEqual(updated.first?.createdAt, 300)
        XCTAssertEqual(updated.first?.updatedAt, 300)
    }

    func testWatchedHistoryUpdatesExistingEntry() {
        let existing = [
            WatchedHistoryItem(videoID: 1, lastPlaybackPosition: 10, createdAt: 100, updatedAt: 100),
            WatchedHistoryItem(videoID: 2, lastPlaybackPosition: 20, createdAt: 200, updatedAt: 200),
        ]
        let updated = ClientSettingsRules.recordWatchedHistory(
            existing,
            videoID: 2,
            position: 99,
            now: 500,
            maxCount: 50
        )
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(updated.map { $0.videoID }, [1, 2])
        XCTAssertEqual(updated[1].lastPlaybackPosition, 99)
        XCTAssertEqual(updated[1].updatedAt, 500)
        XCTAssertEqual(updated[1].createdAt, 200)
    }

    func testWatchedHistoryTrimKeepsNewestByCreatedAt() {
        var list: [WatchedHistoryItem] = []
        for index in 1...6 {
            list.append(
                WatchedHistoryItem(
                    videoID: index,
                    lastPlaybackPosition: 0,
                    createdAt: Double(index * 100),
                    updatedAt: Double(index * 100)
                )
            )
        }
        let trimmed = ClientHistoryTestHelper.trim(list, maxCount: 3)
        XCTAssertEqual(trimmed.map { $0.videoID }, [4, 5, 6])

        // Recording a new entry with a small max count keeps the newest entries.
        let recorded = ClientSettingsRules.recordWatchedHistory(
            list,
            videoID: 7,
            position: 1,
            now: 700,
            maxCount: 3
        )
        XCTAssertEqual(recorded.count, 3)
        XCTAssertEqual(recorded.map { $0.videoID }, [7, 5, 6])
    }

    func testWatchedHistoryUsesSettingsMaxCount() throws {
        var settings = try makeSettings()
        settings.videoWatchedHistoryMaxCount = 2
        settings.watchedHistory = [
            WatchedHistoryItem(videoID: 1, lastPlaybackPosition: 1, createdAt: 100, updatedAt: 100),
            WatchedHistoryItem(videoID: 2, lastPlaybackPosition: 2, createdAt: 200, updatedAt: 200),
        ]
        settings.recordWatchedHistory(videoID: 3, position: 3, now: 300)
        XCTAssertEqual(settings.watchedHistory.map { $0.videoID }, [3, 2])
        XCTAssertEqual(settings.watchedHistory.first?.lastPlaybackPosition, 3)
    }

    func testNormalizedWatchedHistoryMaxCount() {
        XCTAssertEqual(ClientSettingsRules.normalizedWatchedHistoryMaxCount(nil), 1)
        XCTAssertEqual(ClientSettingsRules.normalizedWatchedHistoryMaxCount(0), 1)
        XCTAssertEqual(ClientSettingsRules.normalizedWatchedHistoryMaxCount(-5), 1)
        XCTAssertEqual(ClientSettingsRules.normalizedWatchedHistoryMaxCount(50), 50)
        XCTAssertEqual(ClientSettingsRules.normalizedWatchedHistoryMaxCount(12.9), 12)
    }

    // MARK: Settings sync rules

    func testSyncDirectionMirrorsSettingsStore() {
        // Server copy is older than the client: the web client keeps the local
        // settings and skips pulling.
        XCTAssertEqual(
            ClientSettingsRules.syncDirection(localLastSyncedAt: 200, serverLastSyncedAt: 100),
            .local
        )
        // Equal timestamps: the server settings are adopted (a no-op).
        XCTAssertEqual(
            ClientSettingsRules.syncDirection(localLastSyncedAt: 200, serverLastSyncedAt: 200),
            .server
        )
        // Newer server copy wins.
        XCTAssertEqual(
            ClientSettingsRules.syncDirection(localLastSyncedAt: 100, serverLastSyncedAt: 200),
            .server
        )
        // A brand new client (0) always takes the server copy.
        XCTAssertEqual(
            ClientSettingsRules.syncDirection(localLastSyncedAt: 0, serverLastSyncedAt: 0),
            .server
        )
    }

    func testUploadAcceptanceMatchesServerRule() {
        // SettingsRouter rejects a PUT older than the stored last_synced_at.
        XCTAssertTrue(
            ClientSettingsRules.isUploadAccepted(uploadedLastSyncedAt: 200, serverLastSyncedAt: 100)
        )
        XCTAssertTrue(
            ClientSettingsRules.isUploadAccepted(uploadedLastSyncedAt: 100, serverLastSyncedAt: 100)
        )
        XCTAssertFalse(
            ClientSettingsRules.isUploadAccepted(uploadedLastSyncedAt: 99, serverLastSyncedAt: 100)
        )
    }

    func testNextLastSyncedAtIsStrictlyNewerThanServer() {
        XCTAssertEqual(
            ClientSettingsRules.nextLastSyncedAt(now: 500, serverLastSyncedAt: 400),
            500
        )
        XCTAssertGreaterThan(
            ClientSettingsRules.nextLastSyncedAt(now: 400, serverLastSyncedAt: 400),
            400
        )
        XCTAssertGreaterThan(
            ClientSettingsRules.nextLastSyncedAt(now: 100, serverLastSyncedAt: 400),
            400
        )
    }
}

/// Local helper so the trim rule can be exercised on its own.
private enum ClientHistoryTestHelper {
    static func trim(_ list: [WatchedHistoryItem], maxCount: Int) -> [WatchedHistoryItem] {
        ClientSettingsRules.trimWatchedHistory(list, maxCount: maxCount)
    }
}
