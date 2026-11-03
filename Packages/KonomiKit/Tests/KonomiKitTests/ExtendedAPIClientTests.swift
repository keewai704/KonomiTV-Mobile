import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import KonomiKit

// MARK: - Stub transport (self-contained so the file has no ordering deps)

actor RecordingTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    private let handler: Handler
    private var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try handler(request)
    }

    func lastRequest() -> URLRequest? { requests.last }
    func requestCount() -> Int { requests.count }
}

private let extendedBaseURL = URL(string: "http://127.0.0.1:7010")!

private func extendedJSONResponse(
    for request: URLRequest,
    body: String,
    status: Int = 200
) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? extendedBaseURL,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
}

private func noContentResponse(for request: URLRequest) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? extendedBaseURL,
        statusCode: 204,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
    return (Data(), response)
}

private func queryItems(_ request: URLRequest) -> [URLQueryItem] {
    guard
        let url = request.url,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
        return []
    }
    return components.queryItems ?? []
}

private func queryValue(_ request: URLRequest, name: String) -> String? {
    queryItems(request).first { $0.name == name }?.value
}

private func queryValues(_ request: URLRequest, name: String) -> [String] {
    queryItems(request).filter { $0.name == name }.compactMap { $0.value }
}

private func decodedBody<T: Decodable>(_ request: URLRequest, as type: T.Type) throws -> T {
    let body = try XCTUnwrap(request.httpBody)
    return try JSONCoding.decode(type, from: body)
}

private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
    let body = try XCTUnwrap(request.httpBody)
    let object = try JSONSerialization.jsonObject(with: body)
    return try XCTUnwrap(object as? [String: Any])
}

// MARK: - Tests

final class ExtendedAPIClientTests: XCTestCase {

    // MARK: Videos

    func testVideosDefaultOrderIsDescending() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/videos")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(queryValue(request, name: "order"), "desc")
            XCTAssertEqual(queryValue(request, name: "page"), "1")
            return extendedJSONResponse(for: request, body: Fixtures.recordedProgramsJSON)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        let programs = try await client.videos()
        XCTAssertEqual(programs.total, 35)
    }

    func testVideosAcceptsExplicitAscendingOrder() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(queryValue(request, name: "order"), "asc")
            XCTAssertEqual(queryValue(request, name: "page"), "2")
            return extendedJSONResponse(for: request, body: Fixtures.recordedProgramsJSON)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        _ = try await client.videos(page: 2, order: .asc)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 1)
    }

    func testVideosByIDsRepeatsIDsAndUsesIDsOrder() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/videos")
            // FastAPI expects &ids=1&ids=2, not ids=1,2
            XCTAssertEqual(queryValues(request, name: "ids"), ["5", "1", "4"])
            XCTAssertEqual(queryValue(request, name: "order"), "ids")
            XCTAssertEqual(queryValue(request, name: "page"), "1")
            return extendedJSONResponse(for: request, body: Fixtures.recordedProgramsJSON)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        let programs = try await client.videos(ids: [5, 1, 4])
        XCTAssertEqual(programs.recordedPrograms.first?.id, 101)
    }

    func testVideosByEmptyIDsDoesNotHitTheServer() async throws {
        let transport = RecordingTransport { request in
            XCTFail("No request expected")
            return extendedJSONResponse(for: request, body: Fixtures.emptyProgramsJSON)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        let programs = try await client.videos(ids: [])
        XCTAssertEqual(programs.total, 0)
        XCTAssertTrue(programs.recordedPrograms.isEmpty)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 0)
    }

    func testDeleteVideoUsesDELETE() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/videos/101")
            XCTAssertEqual(request.httpMethod, "DELETE")
            return noContentResponse(for: request)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport, token: "abc")
        try await client.deleteVideo(id: 101)
        let last = await transport.lastRequest()
        XCTAssertEqual(last?.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
    }

    func testReanalyzeVideoUsesPOST() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/videos/101/reanalyze")
            XCTAssertEqual(request.httpMethod, "POST")
            return noContentResponse(for: request)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        try await client.reanalyzeVideo(id: 101)
    }

    func testRegenerateThumbnailUsesPOST() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/videos/101/thumbnail/regenerate")
            XCTAssertEqual(request.httpMethod, "POST")
            return noContentResponse(for: request)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        try await client.regenerateThumbnail(id: 101)
    }

    func testDeleteVideoSurfacesUnauthorized() async throws {
        let transport = RecordingTransport { request in
            extendedJSONResponse(for: request, body: #"{"detail":"Unauthorized"}"#, status: 401)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        do {
            try await client.deleteVideo(id: 101)
            XCTFail("Expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
        }
    }

    func testVideoDownloadURL() {
        let client = APIClient(baseURL: extendedBaseURL)
        XCTAssertEqual(
            client.videoDownloadURL(id: 7).absoluteString,
            "http://127.0.0.1:7010/api/videos/7/download"
        )
    }

    // MARK: Series

    func testSeriesListRequest() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/series")
            XCTAssertEqual(queryValue(request, name: "order"), "desc")
            XCTAssertEqual(queryValue(request, name: "page"), "2")
            return extendedJSONResponse(for: request, body: Fixtures.seriesListJSON)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        let series = try await client.seriesList(page: 2)
        XCTAssertEqual(series.total, 3)
        XCTAssertEqual(series.seriesList.count, 3)
    }

    func testSearchSeriesEncodesQuery() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/series/search")
            XCTAssertEqual(queryValue(request, name: "query"), "フリーレン")
            XCTAssertEqual(queryValue(request, name: "order"), "asc")
            XCTAssertEqual(queryValue(request, name: "page"), "1")
            return extendedJSONResponse(for: request, body: Fixtures.seriesListJSON)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        _ = try await client.searchSeries(query: "フリーレン", order: .asc)
    }

    func testSeriesDetailRequest() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/series/1")
            return extendedJSONResponse(for: request, body: Fixtures.seriesDetailJSON)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        let series = try await client.series(id: 1)
        XCTAssertEqual(series.title, "アニメ 鬼滅の刃")
    }

    // MARK: Programs

    func testSearchProgramsPostsConditionBody() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/programs/search")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )
            let object = try jsonObject(request)
            // Every field of schemas.ProgramSearchCondition is sent.
            for key in [
                "is_enabled", "keyword", "exclude_keyword", "note", "is_title_only",
                "is_case_sensitive", "is_fuzzy_search_enabled", "is_regex_search_enabled",
                "service_ranges", "genre_ranges", "is_exclude_genre_ranges", "date_ranges",
                "is_exclude_date_ranges", "duration_range_min", "duration_range_max",
                "broadcast_type", "duplicate_title_check_scope",
                "duplicate_title_check_period_days",
            ] {
                XCTAssertTrue(object.keys.contains(key), "missing \(key)")
            }
            XCTAssertEqual(object["keyword"] as? String, "ショッピング")
            XCTAssertEqual(object["is_title_only"] as? Bool, true)
            XCTAssertEqual(object["broadcast_type"] as? String, "All")
            let condition = try decodedBody(request, as: ProgramSearchCondition.self)
            XCTAssertEqual(condition.keyword, "ショッピング")
            XCTAssertTrue(condition.isTitleOnly)
            return extendedJSONResponse(for: request, body: Fixtures.programsJSON)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        let result = try await client.searchPrograms(
            ProgramSearchCondition(keyword: "ショッピング", isTitleOnly: true)
        )
        XCTAssertEqual(result.total, 7)
        XCTAssertEqual(result.programs.first?.title, "NHK BS ショッピング・通販")
    }

    func testTimetableQueryParameters() async throws {
        let start = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-03T00:00:00+09:00"))
        let end = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-04T00:00:00+09:00"))
        let transport = RecordingTransport { request in
            extendedJSONResponse(for: request, body: Fixtures.timetableJSON)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        let timetable = try await client.timetable(
            startTime: start,
            endTime: end,
            channelType: .gr,
            pinnedChannelIDs: ["gr011", "bs101"]
        )

        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.path, "/api/programs/timetable")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(queryValue(request, name: "channel_type"), "GR")
        // pinned_channel_ids is a single comma separated parameter.
        XCTAssertEqual(queryValue(request, name: "pinned_channel_ids"), "gr011,bs101")

        // start_time / end_time are ISO 8601 datetimes the server can parse.
        let startValue = try XCTUnwrap(queryValue(request, name: "start_time"))
        let endValue = try XCTUnwrap(queryValue(request, name: "end_time"))
        let parsedStart = try XCTUnwrap(JSONCoding.parseISO8601(startValue))
        let parsedEnd = try XCTUnwrap(JSONCoding.parseISO8601(endValue))
        XCTAssertEqual(parsedStart.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(parsedEnd.timeIntervalSince1970, end.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(startValue.contains("T"))

        XCTAssertEqual(timetable.channels.count, 1)
        XCTAssertEqual(timetable.channels.first?.channel.displayChannelID, "gr011")
    }

    func testTimetableWithoutOptionalParameters() async throws {
        let start = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-03T00:00:00+09:00"))
        let end = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-03T06:00:00+09:00"))
        let transport = RecordingTransport { request in
            extendedJSONResponse(for: request, body: Fixtures.timetableJSON)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        _ = try await client.timetable(startTime: start, endTime: end)

        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.path, "/api/programs/timetable")
        XCTAssertNil(queryValue(request, name: "channel_type"))
        XCTAssertNil(queryValue(request, name: "pinned_channel_ids"))
        XCTAssertNotNil(queryValue(request, name: "start_time"))
        XCTAssertNotNil(queryValue(request, name: "end_time"))
    }

    // MARK: Client settings

    func testClientSettingsRequiresBearerTokenAndDecodes() async throws {
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/settings/client")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer secret-token"
            )
            return extendedJSONResponse(for: request, body: Fixtures.clientSettingsJSON)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport, token: "secret-token")
        let settings = try await client.clientSettings()
        XCTAssertEqual(settings.pinnedChannelIDs, ["gr011", "bs101"])
        XCTAssertEqual(settings.mylist.count, 2)
    }

    func testUpdateClientSettingsPutsFullObject() async throws {
        let original = try JSONCoding.decode(ClientSettings.self, from: Fixtures.clientSettingsJSON)
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.path, "/api/settings/client")
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )
            let object = try jsonObject(request)
            XCTAssertNotNil(object["unknown_future_key"])
            XCTAssertNotNil(object["saved_twitter_hashtags"])
            let sent = try decodedBody(request, as: ClientSettings.self)
            XCTAssertEqual(sent.keys, original.keys)
            return noContentResponse(for: request)
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport, token: "abc")
        var settings = original
        settings.lastSyncedAt = 1762176000
        settings.use28HourClock = true
        try await client.updateClientSettings(settings)
        let last = await transport.lastRequest()
        XCTAssertEqual(last?.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
    }

    func testUpdateClientSettingsSurfacesOutdatedError() async throws {
        let transport = RecordingTransport { request in
            extendedJSONResponse(
                for: request,
                body: #"{"detail":"The client settings are outdated."}"#,
                status: 422
            )
        }
        let client = APIClient(baseURL: extendedBaseURL, transport: transport)
        let settings = try JSONCoding.decode(ClientSettings.self, from: Fixtures.clientSettingsJSON)
        do {
            try await client.updateClientSettings(settings)
            XCTFail("Expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 422)
        }
    }
}
