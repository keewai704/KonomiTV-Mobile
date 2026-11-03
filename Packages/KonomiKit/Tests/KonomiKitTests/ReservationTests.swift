import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import KonomiKit

private let reservationBaseURL = URL(string: "http://127.0.0.1:7010")!

private func reservationResponse(
    for request: URLRequest,
    body: String,
    status: Int = 200
) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? reservationBaseURL,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
}

private func emptyResponse(for request: URLRequest, status: Int = 204) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? reservationBaseURL,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
    return (Data(), response)
}

private func bodyObject(_ request: URLRequest) throws -> [String: Any] {
    let data = try XCTUnwrap(request.httpBody)
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Any])
}

private func nestedObject(_ object: [String: Any], _ key: String) throws -> [String: Any] {
    try XCTUnwrap(object[key] as? [String: Any])
}

enum ReservationFixtures {
    static let recordSettingsJSON = """
    {
      "is_enabled": false,
      "priority": 4,
      "recording_folders": [
        {
          "recording_folder_path": "/records/anime",
          "recording_file_name_template": "$ZtoH(Title)$.ts",
          "is_oneseg_separate_recording_folder": false
        }
      ],
      "recording_start_margin": 8,
      "recording_end_margin": null,
      "recording_mode": "AllServicesWithoutDecoding",
      "caption_recording_mode": "Enable",
      "data_broadcasting_recording_mode": "Disable",
      "post_recording_mode": "StandbyAndReboot",
      "post_recording_bat_file_path": "/usr/local/bin/transcode.sh",
      "is_event_relay_follow_enabled": false,
      "is_exact_recording_enabled": true,
      "is_oneseg_separate_output_enabled": true,
      "is_sequential_recording_in_single_file_enabled": true,
      "forced_tuner_id": 3
    }
    """

    static let reservationJSON = """
    {
      "id": 12,
      "channel": {
        "id": "gr011",
        "display_channel_id": "gr011",
        "network_id": 32736,
        "service_id": 1024,
        "transport_stream_id": 32736,
        "remocon_id": 1,
        "channel_number": "011",
        "type": "GR",
        "name": "NHK総合",
        "is_subchannel": false,
        "is_radiochannel": false,
        "is_watchable": true
      },
      "program": {
        "id": "NID32736-SID1024-EID20000",
        "channel_id": "gr011",
        "network_id": 32736,
        "service_id": 1024,
        "event_id": 20000,
        "title": "モーニングニュース",
        "description": "今日のニュースと天気をお伝えします。",
        "detail": {"出演者": "キャスター"},
        "start_time": "2026-11-04T06:00:00+09:00",
        "end_time": "2026-11-04T07:00:00+09:00",
        "duration": 3600,
        "is_free": true,
        "genres": [{"major": "ニュース・報道", "middle": "定時・総合"}],
        "primary_audio_type": "2/0モード(ステレオ)",
        "primary_audio_language": "日本語"
      },
      "is_recording_in_progress": true,
      "recording_availability": "Partial",
      "comment": "EPG自動予約",
      "scheduled_recording_file_name": "$ZtoH(Title)$.ts",
      "estimated_recording_file_size": 6200000000,
      "record_settings": \(recordSettingsJSON)
    }
    """

    static let reservationsJSON = """
    {"total": 1, "reservations": [\(reservationJSON)]}
    """

    static let presetsJSON = """
    {
      "global_defaults": {
        "recording_start_margin": 5,
        "recording_end_margin": 2,
        "caption_recording_mode": "Enable",
        "data_broadcasting_recording_mode": "Disable",
        "post_recording_mode": "Nothing"
      },
      "presets": [
        {"id": 0, "name": "デフォルト", "record_settings": \(recordSettingsJSON)},
        {"id": 2, "name": "アニメ", "record_settings": {"is_enabled": true, "priority": 5}}
      ]
    }
    """

    static let conditionJSON = """
    {
      "id": 3,
      "reservation_count": 7,
      "program_search_condition": {
        "is_enabled": false,
        "keyword": "アニメ",
        "exclude_keyword": "再放送",
        "note": "毎週",
        "is_title_only": true,
        "is_case_sensitive": true,
        "is_fuzzy_search_enabled": true,
        "is_regex_search_enabled": false,
        "service_ranges": [
          {"network_id": 32736, "transport_stream_id": 32736, "service_id": 1024}
        ],
        "genre_ranges": [{"major": "アニメ・特撮", "middle": "国内アニメ"}],
        "is_exclude_genre_ranges": true,
        "date_ranges": [
          {
            "start_day_of_week": 1,
            "start_hour": 22,
            "start_minute": 30,
            "end_day_of_week": 1,
            "end_hour": 23,
            "end_minute": 0
          }
        ],
        "is_exclude_date_ranges": false,
        "duration_range_min": 15,
        "duration_range_max": 60,
        "broadcast_type": "FreeOnly",
        "duplicate_title_check_scope": "SameChannelOnly",
        "duplicate_title_check_period_days": 3
      },
      "record_settings": \(recordSettingsJSON)
    }
    """

    static let conditionsJSON = """
    {"total": 1, "reservation_conditions": [\(conditionJSON)]}
    """
}

// MARK: - Decoding

final class ReservationModelTests: XCTestCase {

    func testReservationDecodesEveryField() throws {
        let reservation = try JSONCoding.decode(
            Reservation.self,
            from: ReservationFixtures.reservationJSON
        )

        XCTAssertEqual(reservation.id, 12)
        XCTAssertEqual(reservation.channel.displayChannelID, "gr011")
        XCTAssertEqual(reservation.program.title, "モーニングニュース")
        XCTAssertEqual(reservation.program.detail["出演者"], "キャスター")
        XCTAssertTrue(reservation.isRecordingInProgress)
        XCTAssertEqual(reservation.recordingAvailability, .partial)
        XCTAssertEqual(reservation.recordingAvailability.displayName, "一部のみ録画可能")
        XCTAssertEqual(reservation.comment, "EPG自動予約")
        XCTAssertTrue(reservation.isKeywordAutoReservation)
        XCTAssertEqual(reservation.scheduledRecordingFileName, "$ZtoH(Title)$.ts")
        XCTAssertEqual(reservation.estimatedRecordingFileSize, 6_200_000_000)

        let settings = reservation.recordSettings
        XCTAssertFalse(settings.isEnabled)
        XCTAssertTrue(reservation.isDisabled)
        XCTAssertEqual(reservation.priority, 4)
        XCTAssertEqual(settings.recordingFolders.count, 1)
        XCTAssertEqual(settings.recordingFolders[0].recordingFolderPath, "/records/anime")
        XCTAssertEqual(settings.recordingFolders[0].recordingFileNameTemplate, "$ZtoH(Title)$.ts")
        XCTAssertEqual(settings.recordingStartMargin, 8)
        XCTAssertNil(settings.recordingEndMargin)
        XCTAssertEqual(settings.recordingMode, .allServicesWithoutDecoding)
        XCTAssertEqual(settings.captionRecordingMode, .enable)
        XCTAssertEqual(settings.dataBroadcastingRecordingMode, .disable)
        XCTAssertEqual(settings.postRecordingMode, .standbyAndReboot)
        XCTAssertEqual(settings.postRecordingBatFilePath, "/usr/local/bin/transcode.sh")
        XCTAssertFalse(settings.isEventRelayFollowEnabled)
        XCTAssertTrue(settings.isExactRecordingEnabled)
        XCTAssertTrue(settings.isOnesegSeparateOutputEnabled)
        XCTAssertTrue(settings.isSequentialRecordingInSingleFileEnabled)
        XCTAssertEqual(settings.forcedTunerID, 3)
    }

    func testReservationsListDecodesTotal() throws {
        let list = try JSONCoding.decode(
            Reservations.self,
            from: ReservationFixtures.reservationsJSON
        )
        XCTAssertEqual(list.total, 1)
        XCTAssertEqual(list.reservations.map(\.id), [12])
    }

    func testReservationIsLenientAboutMissingFields() throws {
        let reservation = try JSONCoding.decode(Reservation.self, from: "{\"id\": 4}")
        XCTAssertEqual(reservation.id, 4)
        XCTAssertEqual(reservation.program.title, "")
        XCTAssertEqual(reservation.recordingAvailability, .full)
        XCTAssertTrue(reservation.recordSettings.isEnabled)
        XCTAssertEqual(reservation.recordSettings.priority, 3)
        XCTAssertTrue(reservation.recordSettings.recordingFolders.isEmpty)

        let settings = try JSONCoding.decode(
            RecordSettings.self,
            from: "{\"priority\": 99, \"recording_mode\": \"Unknown\"}"
        )
        // The server only accepts 1...5 and the five known modes.
        XCTAssertEqual(settings.priority, 5)
        XCTAssertEqual(settings.recordingMode, .specifiedService)
    }

    func testPresetsDecodeGlobalDefaultsAndDefaultPreset() throws {
        let presets = try JSONCoding.decode(
            RecordSettingsPresets.self,
            from: ReservationFixtures.presetsJSON
        )
        XCTAssertEqual(presets.presets.count, 2)
        XCTAssertEqual(presets.defaultPreset?.name, "デフォルト")
        XCTAssertEqual(presets.globalDefaults.recordingStartMargin, 5)
        XCTAssertEqual(presets.globalDefaults.captionRecordingMode, .enable)
        XCTAssertEqual(presets.globalDefaults.dataBroadcastingRecordingMode, .disable)
        XCTAssertEqual(presets.globalDefaults.postRecordingMode, .nothing)
        // A preset with only a few keys still decodes (the server always sends
        // every key, but the model must not fail on a partial fixture).
        XCTAssertEqual(presets.presets[1].recordSettings.priority, 5)
        XCTAssertEqual(presets.presets[1].recordSettings.recordingMode, .specifiedService)
    }

    func testConditionDecodesSearchConditionAndCount() throws {
        let condition = try JSONCoding.decode(
            ReservationCondition.self,
            from: ReservationFixtures.conditionJSON
        )
        XCTAssertEqual(condition.id, 3)
        XCTAssertEqual(condition.reservationCount, 7)
        let search = condition.programSearchCondition
        XCTAssertFalse(search.isEnabled)
        XCTAssertEqual(search.keyword, "アニメ")
        XCTAssertEqual(search.excludeKeyword, "再放送")
        XCTAssertEqual(search.note, "毎週")
        XCTAssertTrue(search.isTitleOnly)
        XCTAssertTrue(search.isCaseSensitive)
        XCTAssertTrue(search.isFuzzySearchEnabled)
        XCTAssertFalse(search.isRegexSearchEnabled)
        XCTAssertEqual(search.serviceRanges?.count, 1)
        XCTAssertEqual(search.serviceRanges?.first?.serviceID, 1024)
        XCTAssertEqual(search.genreRanges?.first?.major, "アニメ・特撮")
        XCTAssertTrue(search.isExcludeGenreRanges)
        XCTAssertEqual(search.dateRanges?.first?.startHour, 22)
        XCTAssertEqual(search.dateRanges?.first?.startMinute, 30)
        XCTAssertEqual(search.durationRangeMin, 15)
        XCTAssertEqual(search.durationRangeMax, 60)
        XCTAssertEqual(search.broadcastType, .freeOnly)
        XCTAssertEqual(search.duplicateTitleCheckScope, .sameChannelOnly)
        XCTAssertEqual(search.duplicateTitleCheckPeriodDays, 3)
        XCTAssertFalse(condition.recordSettings.isEnabled)
    }

    func testConditionsListDecodes() throws {
        let list = try JSONCoding.decode(
            ReservationConditions.self,
            from: ReservationFixtures.conditionsJSON
        )
        XCTAssertEqual(list.total, 1)
        XCTAssertEqual(list.reservationConditions.first?.id, 3)
    }

    // MARK: Request bodies

    func testRecordSettingsEncodesEveryKeyIncludingNulls() throws {
        let data = try JSONCoding.encode(RecordSettings.fallback)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let expectedKeys: Set<String> = [
            "is_enabled", "priority", "recording_folders", "recording_start_margin",
            "recording_end_margin", "recording_mode", "caption_recording_mode",
            "data_broadcasting_recording_mode", "post_recording_mode",
            "post_recording_bat_file_path", "is_event_relay_follow_enabled",
            "is_exact_recording_enabled", "is_oneseg_separate_output_enabled",
            "is_sequential_recording_in_single_file_enabled", "forced_tuner_id",
        ]
        XCTAssertEqual(Set(object.keys), expectedKeys)
        XCTAssertEqual(object["priority"] as? Int, 2)
        XCTAssertEqual(object["recording_mode"] as? String, "SpecifiedService")
        XCTAssertEqual(object["caption_recording_mode"] as? String, "Default")
        XCTAssertEqual(object["post_recording_mode"] as? String, "Default")
        XCTAssertTrue(object["recording_start_margin"] is NSNull)
        XCTAssertTrue(object["recording_end_margin"] is NSNull)
        XCTAssertTrue(object["forced_tuner_id"] is NSNull)
        XCTAssertTrue(object["post_recording_bat_file_path"] is NSNull)
        XCTAssertEqual((object["recording_folders"] as? [Any])?.count, 0)
    }

    func testAddRequestEncodesProgramIDSettingsAndNullProgram() throws {
        let request = ReservationAddRequest(
            programID: "NID32736-SID1024-EID20000",
            recordSettings: RecordSettings(priority: 1)
        )
        let data = try JSONCoding.encode(request)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["program_id"] as? String, "NID32736-SID1024-EID20000")
        XCTAssertTrue(object["program"] is NSNull)
        let settings = try nestedObject(object, "record_settings")
        XCTAssertEqual(settings["priority"] as? Int, 1)
    }

    func testAddRequestEncodesProgramPayload() throws {
        var program = Program()
        program.id = "NID32736-SID1024-EID65535"
        program.channelID = "gr011"
        program.networkID = 32736
        program.serviceID = 1024
        program.eventID = 65535
        program.title = "放送中の番組"
        program.startTime = Date(timeIntervalSince1970: 1_800_000_000)
        program.duration = 1800

        let request = ReservationAddRequest(
            programID: program.id,
            recordSettings: RecordSettings(),
            program: ReservationAddProgram(program: program)
        )
        let data = try JSONCoding.encode(request)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let payload = try nestedObject(object, "program")
        XCTAssertEqual(payload["id"] as? String, program.id)
        XCTAssertEqual(payload["channel_id"] as? String, "gr011")
        XCTAssertEqual(payload["network_id"] as? Int, 32736)
        XCTAssertEqual(payload["service_id"] as? Int, 1024)
        XCTAssertEqual(payload["event_id"] as? Int, 65535)
        XCTAssertEqual(payload["title"] as? String, "放送中の番組")
        XCTAssertEqual(payload["duration"] as? Double, 1800)
        XCTAssertNotNil(payload["start_time"] as? String)
    }

    func testConditionRequestEncodesSearchConditionAndSettings() throws {
        let request = ReservationConditionRequest(
            programSearchCondition: ProgramSearchCondition(keyword: "ニュース"),
            recordSettings: RecordSettings(priority: 5)
        )
        let data = try JSONCoding.encode(request)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let search = try nestedObject(object, "program_search_condition")
        XCTAssertEqual(search["keyword"] as? String, "ニュース")
        XCTAssertEqual(search["broadcast_type"] as? String, "All")
        let settings = try nestedObject(object, "record_settings")
        XCTAssertEqual(settings["priority"] as? Int, 5)
    }
}

// MARK: - Client

final class ReservationAPIClientTests: XCTestCase {

    func testReservationsList() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/recording/reservations")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return reservationResponse(for: request, body: ReservationFixtures.reservationsJSON)
        }
        let client = APIClient(baseURL: reservationBaseURL, transport: transport, token: "token")
        let list = try await client.reservations()
        XCTAssertEqual(list.total, 1)
    }

    func testReservationDetail() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/recording/reservations/12")
            return reservationResponse(for: request, body: ReservationFixtures.reservationJSON)
        }
        let client = APIClient(baseURL: reservationBaseURL, transport: transport)
        let reservation = try await client.reservation(id: 12)
        XCTAssertEqual(reservation.id, 12)
    }

    func testAddReservationPostsBody() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/recording/reservations")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return emptyResponse(for: request, status: 201)
        }
        let client = APIClient(baseURL: reservationBaseURL, transport: transport)
        try await client.addReservation(
            programID: "NID32736-SID1024-EID20000",
            recordSettings: RecordSettings(priority: 4)
        )
        let request = await transport.lastRequest()
        let object = try bodyObject(try XCTUnwrap(request))
        XCTAssertEqual(object["program_id"] as? String, "NID32736-SID1024-EID20000")
        XCTAssertEqual(
            (try nestedObject(object, "record_settings"))["priority"] as? Int,
            4
        )
        XCTAssertTrue(object["program"] is NSNull)
    }

    func testUpdateReservationPutsSettings() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/recording/reservations/12")
            XCTAssertEqual(request.httpMethod, "PUT")
            return reservationResponse(for: request, body: ReservationFixtures.reservationJSON)
        }
        let client = APIClient(baseURL: reservationBaseURL, transport: transport)
        let updated = try await client.updateReservation(
            id: 12,
            recordSettings: RecordSettings(isEnabled: false)
        )
        XCTAssertEqual(updated.id, 12)

        let request = await transport.lastRequest()
        let object = try bodyObject(try XCTUnwrap(request))
        let settings = try nestedObject(object, "record_settings")
        XCTAssertEqual(settings["is_enabled"] as? Bool, false)
    }

    func testDeleteReservation() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/recording/reservations/12")
            XCTAssertEqual(request.httpMethod, "DELETE")
            return emptyResponse(for: request)
        }
        let client = APIClient(baseURL: reservationBaseURL, transport: transport)
        try await client.deleteReservation(id: 12)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 1)
    }

    func testReservationConditionsListAndDetail() async throws {
        let transport = RecordingTransport { request in
            switch request.url?.path {
            case "/api/recording/conditions":
                return reservationResponse(for: request, body: ReservationFixtures.conditionsJSON)
            case "/api/recording/conditions/3":
                return reservationResponse(for: request, body: ReservationFixtures.conditionJSON)
            default:
                XCTFail("unexpected path: \(request.url?.path ?? "nil")")
                return reservationResponse(for: request, body: "{}")
            }
        }
        let client = APIClient(baseURL: reservationBaseURL, transport: transport)
        let list = try await client.reservationConditions()
        XCTAssertEqual(list.total, 1)
        let condition = try await client.reservationCondition(id: 3)
        XCTAssertEqual(condition.reservationCount, 7)
    }

    func testAddReservationConditionPostsBothParts() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/recording/conditions")
            XCTAssertEqual(request.httpMethod, "POST")
            return emptyResponse(for: request, status: 201)
        }
        let client = APIClient(baseURL: reservationBaseURL, transport: transport)
        try await client.addReservationCondition(
            programSearchCondition: ProgramSearchCondition(keyword: "アニメ"),
            recordSettings: RecordSettings()
        )
        let request = await transport.lastRequest()
        let object = try bodyObject(try XCTUnwrap(request))
        XCTAssertEqual(
            (try nestedObject(object, "program_search_condition"))["keyword"] as? String,
            "アニメ"
        )
        XCTAssertNotNil(object["record_settings"])
    }

    func testUpdateAndDeleteReservationCondition() async throws {
        let transport = RecordingTransport { request in
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.url?.path, "/api/recording/conditions/3")
                return reservationResponse(for: request, body: ReservationFixtures.conditionJSON)
            }
            XCTAssertEqual(request.url?.path, "/api/recording/conditions/3")
            XCTAssertEqual(request.httpMethod, "DELETE")
            return emptyResponse(for: request)
        }
        let client = APIClient(baseURL: reservationBaseURL, transport: transport)
        let updated = try await client.updateReservationCondition(
            id: 3,
            programSearchCondition: ProgramSearchCondition(keyword: "ドラマ"),
            recordSettings: RecordSettings()
        )
        XCTAssertEqual(updated.id, 3)
        try await client.deleteReservationCondition(id: 3)
    }

    func testRecordingPresets() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/recording/presets")
            return reservationResponse(for: request, body: ReservationFixtures.presetsJSON)
        }
        let client = APIClient(baseURL: reservationBaseURL, transport: transport)
        let presets = try await client.recordingPresets()
        XCTAssertEqual(presets.presets.count, 2)
        XCTAssertEqual(presets.defaultPreset?.id, 0)
    }

    func testDefaultRecordSettingsUsesPresetZero() async throws {
        let transport = RecordingTransport { request in
            return reservationResponse(for: request, body: ReservationFixtures.presetsJSON)
        }
        let client = APIClient(baseURL: reservationBaseURL, transport: transport)
        let settings = await client.defaultRecordSettings()
        // The id == 0 preset of the fixture has priority 4.
        XCTAssertEqual(settings.priority, 4)
        XCTAssertEqual(settings.recordingFolders.first?.recordingFolderPath, "/records/anime")
    }

    func testDefaultRecordSettingsFallsBackWhenPresetsFail() async throws {
        let transport = RecordingTransport { request in
            reservationResponse(
                for: request,
                body: "{\"detail\": \"Failed to get EpgTimerSrv.ini from EDCB\"}",
                status: 500
            )
        }
        let client = APIClient(baseURL: reservationBaseURL, transport: transport)
        let settings = await client.defaultRecordSettings()
        XCTAssertEqual(settings, RecordSettings.fallback)
    }
}
