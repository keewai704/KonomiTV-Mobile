import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import KonomiKit

// MARK: - Fixtures

private enum CaptureFixtures {
    static let captureJSON = """
    {
      "id": 42,
      "file_hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "file_size": 34567,
      "captured_at": "2026-11-03T21:05:09+09:00",
      "broadcast_at": "2026-11-03T21:00:00+09:00",
      "image_width": 1920,
      "image_height": 1080,
      "metadata_status": "Parsed",
      "playback_position": 309.5,
      "caption_text": "今日のニュースです",
      "is_caption_composited": true,
      "is_comment_composited": false,
      "capture_program_id": 7,
      "is_favorite": true,
      "tag_ids": [3, 5]
    }
    """

    static let programJSON = """
    {
      "id": 7,
      "network_id": 32736,
      "service_id": 1024,
      "event_id": 10001,
      "start_time": "2026-11-03T21:00:00+09:00",
      "end_time": "2026-11-03T21:45:00+09:00",
      "duration": 2700.0,
      "title": "ニュース7",
      "description": "今日のニュース",
      "channel": {
        "id": "NID32736-SID1024",
        "display_channel_id": "gr011",
        "name": "NHK総合",
        "type": "GR"
      },
      "recorded_program_ids": [1]
    }
    """

    static let capturesJSON = """
    {
      "captures": [
        {
          "id": 42,
          "file_hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "file_size": 34567,
          "captured_at": "2026-11-03T21:05:09+09:00",
          "broadcast_at": "2026-11-03T21:00:00+09:00",
          "image_width": 1920,
          "image_height": 1080,
          "metadata_status": "Parsed",
          "playback_position": 309.5,
          "caption_text": "今日のニュースです",
          "is_caption_composited": true,
          "is_comment_composited": false,
          "capture_program_id": 7,
          "is_favorite": true,
          "tag_ids": [3, 5]
        },
        {
          "id": 43,
          "file_hash": "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
          "file_size": 100,
          "captured_at": "2026-11-02T12:00:00+09:00",
          "broadcast_at": null,
          "image_width": 1280,
          "image_height": 720,
          "metadata_status": "NoMetadata",
          "playback_position": null,
          "caption_text": null,
          "is_caption_composited": false,
          "is_comment_composited": true,
          "capture_program_id": null,
          "is_favorite": null,
          "tag_ids": null
        }
      ],
      "programs": [\(programJSON)],
      "next_cursor": "curl",
      "unknown_future_field": true
    }
    """

    static let sectionsJSON = """
    {"sections": [{"date": "2026-11-03", "count": 5}, {"date": "2026-11-02", "count": 2}], "total": 7}
    """

    static let programsJSON = """
    {
      "programs": [
        {
          "id": 7,
          "network_id": 32736,
          "service_id": 1024,
          "event_id": 10001,
          "start_time": "2026-11-03T21:00:00+09:00",
          "end_time": null,
          "duration": null,
          "title": "ニュース7",
          "description": "今日のニュース",
          "channel": null,
          "recorded_program_ids": [],
          "capture_count": 3,
          "cover_capture": \(captureJSON)
        }
      ],
      "next_cursor": null
    }
    """

    static let tagsJSON = """
    [{"id": 1, "name": "お気に入り", "capture_count": 4,
      "created_at": "2026-11-01T10:00:00+09:00", "updated_at": "2026-11-01T10:00:00+09:00"}]
    """

    static let detailJSON = """
    {
      "id": 42,
      "file_hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "file_size": 34567,
      "captured_at": "2026-11-03T21:05:09+09:00",
      "broadcast_at": "2026-11-03T21:00:00+09:00",
      "image_width": 1920,
      "image_height": 1080,
      "metadata_status": "Parsed",
      "playback_position": 309.5,
      "caption_text": "今日のニュースです",
      "is_caption_composited": true,
      "is_comment_composited": false,
      "capture_program_id": 7,
      "is_favorite": true,
      "tag_ids": [3, 5],
      "program": \(programJSON),
      "files": [{"file_name": "Capture_20261103-210509.jpg", "file_path": "/captures/Capture_20261103-210509.jpg", "status": "Available"}]
    }
    """
}

private let capturesBaseURL = URL(string: "http://127.0.0.1:7010")!

private func captureResponse(
    for request: URLRequest,
    body: String,
    status: Int = 200
) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? capturesBaseURL,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
}

private func captureQueryValues(_ request: URLRequest, name: String) -> [String] {
    guard
        let url = request.url,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
        return []
    }
    return components.queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
}

private func captureQuery(_ request: URLRequest, name: String) -> String? {
    captureQueryValues(request, name: name).first
}

// MARK: - Models

final class CaptureModelsTests: XCTestCase {

    func testDecodesCaptureListPage() throws {
        let page = try JSONCoding.decode(Captures.self, from: CaptureFixtures.capturesJSON)
        XCTAssertEqual(page.captures.count, 2)
        XCTAssertEqual(page.nextCursor, "curl")
        XCTAssertEqual(page.programs.count, 1)
        XCTAssertEqual(page.programs.first?.title, "ニュース7")
        XCTAssertEqual(page.programs.first?.recordedProgramIDs, [1])

        let capture = page.captures[0]
        XCTAssertEqual(capture.id, 42)
        XCTAssertEqual(capture.fileHash.count, 64)
        XCTAssertEqual(capture.fileSize, 34567)
        XCTAssertEqual(capture.imageWidth, 1920)
        XCTAssertEqual(capture.metadataStatus, .parsed)
        XCTAssertEqual(capture.playbackPosition ?? -1, 309.5, accuracy: 0.001)
        XCTAssertEqual(capture.captionText, "今日のニュースです")
        XCTAssertTrue(capture.isCaptionComposited)
        XCTAssertFalse(capture.isCommentComposited)
        XCTAssertEqual(capture.captureProgramID, 7)
        XCTAssertEqual(capture.isFavorite, true)
        XCTAssertEqual(capture.tagIDs, [3, 5])

        // 2026-11-03T21:05:09+09:00 == 12:05:09Z
        XCTAssertEqual(capture.capturedAt.timeIntervalSince1970, 1793707509, accuracy: 0.5)

        let anonymous = page.captures[1]
        XCTAssertNil(anonymous.broadcastAt)
        XCTAssertNil(anonymous.playbackPosition)
        XCTAssertNil(anonymous.captionText)
        XCTAssertNil(anonymous.captureProgramID)
        XCTAssertNil(anonymous.isFavorite)
        XCTAssertNil(anonymous.tagIDs)
        XCTAssertEqual(anonymous.metadataStatus, .noMetadata)
    }

    func testDecodesSectionsProgramsTagsAndDetail() throws {
        let sections = try JSONCoding.decode(CaptureSections.self, from: CaptureFixtures.sectionsJSON)
        XCTAssertEqual(sections.total, 7)
        XCTAssertEqual(sections.sections.map(\.date), ["2026-11-03", "2026-11-02"])
        XCTAssertEqual(sections.sections.first?.count, 5)

        let programs = try JSONCoding.decode(CapturePrograms.self, from: CaptureFixtures.programsJSON)
        XCTAssertNil(programs.nextCursor)
        let album = try XCTUnwrap(programs.programs.first)
        XCTAssertEqual(album.id, 7)
        XCTAssertEqual(album.captureCount, 3)
        XCTAssertEqual(album.coverCapture.id, 42)
        XCTAssertNil(album.program.endTime)
        XCTAssertNil(album.program.duration)
        XCTAssertNil(album.program.channel)

        let tags = try JSONCoding.decode([CaptureTag].self, from: CaptureFixtures.tagsJSON)
        XCTAssertEqual(tags.first?.name, "お気に入り")
        XCTAssertEqual(tags.first?.captureCount, 4)

        let detail = try JSONCoding.decode(CaptureDetail.self, from: CaptureFixtures.detailJSON)
        XCTAssertEqual(detail.capture.id, 42)
        XCTAssertEqual(detail.program?.channel?.displayChannelID, "gr011")
        XCTAssertEqual(detail.files.first?.status, .available)
        XCTAssertEqual(detail.files.first?.fileName, "Capture_20261103-210509.jpg")
    }

    func testCaptureRoundTripsAndTolerantDefaults() throws {
        let capture = try JSONCoding.decode(Capture.self, from: CaptureFixtures.captureJSON)
        let data = try JSONCoding.encode(capture)
        let decoded = try JSONCoding.decode(Capture.self, from: data)
        XCTAssertEqual(capture, decoded)

        let empty = try JSONCoding.decode(Capture.self, from: "{}")
        XCTAssertEqual(empty.id, 0)
        XCTAssertEqual(empty.metadataStatus, .noMetadata)
        XCTAssertFalse(empty.isCaptionComposited)
    }
}

// MARK: - Endpoints

final class CaptureEndpointTests: XCTestCase {

    func testListBuildsFilterQuery() async throws {
        var filter = CaptureFilters()
        filter.captureProgramID = 7
        filter.recordedProgramID = 1
        filter.networkID = 32736
        filter.serviceID = 1024
        filter.eventID = 10001
        filter.startTime = Date(timeIntervalSince1970: 1793700000)
        filter.isFavorite = true
        filter.tagIDs = [3, 5]
        filter.channelIDs = ["NID32736-SID1024", "NID32737-SID1024"]
        filter.startDate = "2026-11-01"
        filter.endDate = "2026-11-30"
        filter.isCaptionComposited = false
        filter.isCommentComposited = true
        filter.hasCaptionText = true
        filter.hasMetadata = false
        filter.query = "ニュース"
        filter.queryTargets = [.captionText, .programTitle]

        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/captures")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(captureQuery(request, name: "capture_program_id"), "7")
            XCTAssertEqual(captureQuery(request, name: "recorded_program_id"), "1")
            XCTAssertEqual(captureQuery(request, name: "network_id"), "32736")
            XCTAssertEqual(captureQuery(request, name: "service_id"), "1024")
            XCTAssertEqual(captureQuery(request, name: "event_id"), "10001")
            XCTAssertEqual(captureQuery(request, name: "start_time"), "2026-11-03T10:00:00Z")
            XCTAssertEqual(captureQuery(request, name: "is_favorite"), "true")
            XCTAssertEqual(captureQueryValues(request, name: "tag_ids"), ["3", "5"])
            XCTAssertEqual(
                captureQueryValues(request, name: "channel_ids"),
                ["NID32736-SID1024", "NID32737-SID1024"]
            )
            XCTAssertEqual(captureQuery(request, name: "start_date"), "2026-11-01")
            XCTAssertEqual(captureQuery(request, name: "end_date"), "2026-11-30")
            XCTAssertEqual(captureQuery(request, name: "is_caption_composited"), "false")
            XCTAssertEqual(captureQuery(request, name: "is_comment_composited"), "true")
            XCTAssertEqual(captureQuery(request, name: "has_caption_text"), "true")
            XCTAssertEqual(captureQuery(request, name: "has_metadata"), "false")
            XCTAssertEqual(captureQuery(request, name: "query"), "ニュース")
            XCTAssertEqual(
                captureQueryValues(request, name: "query_targets"),
                ["CaptionText", "ProgramTitle"]
            )
            XCTAssertEqual(captureQuery(request, name: "order"), "CapturedAtAsc")
            XCTAssertEqual(captureQuery(request, name: "limit"), "200")
            XCTAssertEqual(captureQuery(request, name: "cursor"), "next-page")
            XCTAssertEqual(captureQuery(request, name: "date"), "2026-11-03")
            XCTAssertEqual(captureQuery(request, name: "day_start_hour"), "4")
            return captureResponse(for: request, body: CaptureFixtures.capturesJSON)
        }
        let client = APIClient(baseURL: capturesBaseURL, transport: transport, token: "token")
        let page = try await client.captures(
            filter: filter,
            order: .capturedAtAsc,
            cursor: "next-page",
            limit: 500,
            date: "2026-11-03",
            dayStartHour: 4
        )
        XCTAssertEqual(page.captures.count, 2)

        let last = await transport.lastRequest()
        XCTAssertEqual(last?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testListOmitsEmptyFiltersAndClampsLimit() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(captureQuery(request, name: "limit"), "1")
            XCTAssertEqual(captureQuery(request, name: "order"), "CapturedAtDesc")
            XCTAssertNil(captureQuery(request, name: "tag_ids"))
            XCTAssertNil(captureQuery(request, name: "day_start_hour"))
            XCTAssertNil(captureQuery(request, name: "cursor"))
            return captureResponse(for: request, body: CaptureFixtures.capturesJSON)
        }
        let client = APIClient(baseURL: capturesBaseURL, transport: transport)
        _ = try await client.captures(limit: 0)
    }

    func testSectionsQuery() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/captures/sections")
            XCTAssertEqual(captureQuery(request, name: "axis"), "BroadcastAt")
            XCTAssertEqual(captureQuery(request, name: "day_start_hour"), "4")
            XCTAssertEqual(captureQuery(request, name: "channel_ids"), "gr011")
            return captureResponse(for: request, body: CaptureFixtures.sectionsJSON)
        }
        let client = APIClient(baseURL: capturesBaseURL, transport: transport)
        var filter = CaptureFilters()
        filter.channelIDs = ["gr011"]
        let sections = try await client.captureSections(
            filter: filter,
            axis: .broadcastAt,
            dayStartHour: 4
        )
        XCTAssertEqual(sections.total, 7)
    }

    func testChannelsAndProgramsQueries() async throws {
        let transport = StubTransport { request in
            if request.url?.path == "/api/captures/channels" {
                return captureResponse(
                    for: request,
                    body: """
                    [{"id": "NID32736-SID1024", "display_channel_id": "gr011",
                      "name": "NHK総合", "type": "GR"}]
                    """
                )
            }
            XCTAssertEqual(request.url?.path, "/api/captures/programs")
            XCTAssertEqual(captureQuery(request, name: "order"), "BroadcastAtAsc")
            XCTAssertEqual(captureQuery(request, name: "limit"), "60")
            XCTAssertEqual(captureQuery(request, name: "cursor"), "c1")
            XCTAssertEqual(captureQuery(request, name: "query"), "ニュース 特集")
            XCTAssertEqual(captureQuery(request, name: "has_recorded_program"), "true")
            return captureResponse(for: request, body: CaptureFixtures.programsJSON)
        }
        let client = APIClient(baseURL: capturesBaseURL, transport: transport)
        let channels = try await client.captureChannels()
        XCTAssertEqual(channels.first?.displayChannelID, "gr011")
        let programs = try await client.capturePrograms(
            cursor: "c1",
            query: "ニュース 特集",
            hasRecordedProgram: true,
            order: .broadcastAtAsc
        )
        XCTAssertEqual(programs.programs.first?.captureCount, 3)
    }

    func testProgramDetailAndCaptureDetailPaths() async throws {
        let transport = StubTransport { request in
            if request.url?.path == "/api/captures/programs/7" {
                return captureResponse(for: request, body: """
                {
                  "id": 7, "network_id": 32736, "service_id": 1024, "event_id": 10001,
                  "start_time": "2026-11-03T21:00:00+09:00", "end_time": null,
                  "duration": null, "title": "ニュース7", "description": "",
                  "channel": null, "recorded_program_ids": [],
                  "capture_count": 3, "cover_capture": \(CaptureFixtures.captureJSON)
                }
                """)
            }
            XCTAssertEqual(request.url?.path, "/api/captures/42")
            return captureResponse(for: request, body: CaptureFixtures.detailJSON)
        }
        let client = APIClient(baseURL: capturesBaseURL, transport: transport)
        let album = try await client.captureProgram(id: 7)
        XCTAssertEqual(album.id, 7)
        let detail = try await client.capture(id: 42)
        XCTAssertEqual(detail.capture.captionText, "今日のニュースです")
    }

    func testImageURLIncludesHash() {
        let client = APIClient(baseURL: capturesBaseURL)
        let url = client.captureImageURL(id: 42, fileHash: "abc123")
        XCTAssertEqual(url.path, "/api/captures/42/image")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "hash", value: "abc123")])
    }

    func testFavoritesAndTagItemBodies() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(object["capture_ids"] as? [Int], [42, 43])
            if request.url?.path == "/api/captures/favorites" {
                return captureResponse(for: request, body: "{}", status: 204)
            }
            XCTAssertEqual(request.url?.path, "/api/captures/tags/5/items")
            return captureResponse(for: request, body: "{}", status: 204)
        }
        let client = APIClient(baseURL: capturesBaseURL, transport: transport, token: "token")
        try await client.addCaptureFavorites(ids: [42, 43])
        try await client.addCaptureTagItems(tagID: 5, captureIDs: [42, 43])
    }

    func testRemoveFavoritesAndTagItemsUseDeleteWithBody() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(object["capture_ids"] as? [Int], [7])
            return captureResponse(for: request, body: "{}", status: 204)
        }
        let client = APIClient(baseURL: capturesBaseURL, transport: transport)
        try await client.removeCaptureFavorites(ids: [7])
        try await client.removeCaptureTagItems(tagID: 5, captureIDs: [7])
    }

    func testDeleteCapturesBodyAndResult() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/captures")
            XCTAssertEqual(request.httpMethod, "DELETE")
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(object["capture_ids"] as? [Int], [42, 43])
            return captureResponse(
                for: request,
                body: """
                {"deleted_capture_ids": [42], "failed_capture_ids": [43]}
                """
            )
        }
        let client = APIClient(baseURL: capturesBaseURL, transport: transport, token: "admin")
        let result = try await client.deleteCaptures(ids: [42, 43])
        XCTAssertEqual(result.deletedCaptureIDs, [42])
        XCTAssertEqual(result.failedCaptureIDs, [43])
    }

    func testTagCRUD() async throws {
        let transport = StubTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/captures/tags"):
                return captureResponse(for: request, body: CaptureFixtures.tagsJSON)
            case ("POST", "/api/captures/tags"):
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
                        as? [String: Any]
                )
                XCTAssertEqual(object["name"] as? String, "新タグ")
                return captureResponse(for: request, body: """
                {"id": 9, "name": "新タグ", "capture_count": 0,
                 "created_at": "2026-11-03T21:00:00+09:00",
                 "updated_at": "2026-11-03T21:00:00+09:00"}
                """, status: 201)
            case ("PUT", "/api/captures/tags/9"):
                return captureResponse(for: request, body: """
                {"id": 9, "name": "改名", "capture_count": 0,
                 "created_at": "2026-11-03T21:00:00+09:00",
                 "updated_at": "2026-11-03T21:00:00+09:00"}
                """)
            case ("DELETE", "/api/captures/tags/9"):
                return captureResponse(for: request, body: "", status: 204)
            default:
                XCTFail("unexpected request \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return captureResponse(for: request, body: "{}", status: 500)
            }
        }
        let client = APIClient(baseURL: capturesBaseURL, transport: transport, token: "token")
        let tags = try await client.captureTags()
        XCTAssertEqual(tags.first?.id, 1)
        let created = try await client.createCaptureTag(name: "新タグ")
        XCTAssertEqual(created.id, 9)
        let renamed = try await client.renameCaptureTag(id: 9, name: "改名")
        XCTAssertEqual(renamed.name, "改名")
        try await client.deleteCaptureTag(id: 9)
    }

    func testUploadSendsMultipartImageAndModifiedAt() async throws {
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let modifiedAt = Date(timeIntervalSince1970: 1_793_700_000)
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/captures")
            XCTAssertEqual(request.httpMethod, "POST")
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            let boundary = contentType.replacingOccurrences(
                of: "multipart/form-data; boundary=",
                with: ""
            )
            let body = try XCTUnwrap(request.httpBody)
            let string = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(string.hasPrefix("--\(boundary)\r\n"))
            XCTAssertTrue(string.contains("name=\"image\"; filename=\"Capture_20261103-210509.jpg\""))
            XCTAssertTrue(string.contains("Content-Type: image/jpeg\r\n"))
            XCTAssertTrue(string.contains("name=\"file_modified_at\"\r\n\r\n1793700000000\r\n"))
            XCTAssertTrue(string.hasSuffix("--\(boundary)--\r\n"))
            return captureResponse(for: request, body: CaptureFixtures.captureJSON, status: 201)
        }
        let client = APIClient(baseURL: capturesBaseURL, transport: transport, token: "token")
        let capture = try await client.uploadCapture(
            image: image,
            filename: "Capture_20261103-210509.jpg",
            fileModifiedAt: modifiedAt
        )
        XCTAssertEqual(capture?.id, 42)
        let last = await transport.lastRequest()
        XCTAssertEqual(last?.timeoutInterval, 60)
        XCTAssertEqual(last?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testUploadToleratesOldServer204() async throws {
        let transport = StubTransport { request in
            captureResponse(for: request, body: "", status: 204)
        }
        let client = APIClient(baseURL: capturesBaseURL, transport: transport)
        let capture = try await client.uploadCapture(
            image: Data([0x89, 0x50, 0x4E, 0x47]),
            filename: "Capture.png",
            contentType: "image/png"
        )
        XCTAssertNil(capture)
    }

    func testCapturesLibraryAvailability() async throws {
        let unavailable = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/api/captures")
            XCTAssertEqual(captureQuery(request, name: "limit"), "1")
            return captureResponse(for: request, body: "{\"detail\": \"Not Found\"}", status: 404)
        }
        let oldClient = APIClient(baseURL: capturesBaseURL, transport: unavailable)
        let oldAvailable = try await oldClient.capturesLibraryAvailable()
        XCTAssertFalse(oldAvailable)

        let available = StubTransport { request in
            captureResponse(for: request, body: CaptureFixtures.capturesJSON)
        }
        let newClient = APIClient(baseURL: capturesBaseURL, transport: available)
        let newAvailable = try await newClient.capturesLibraryAvailable()
        XCTAssertTrue(newAvailable)
    }
}

// MARK: - Multipart

final class MultipartFormDataTests: XCTestCase {

    func testEncodedBodyBytes() {
        var form = MultipartFormData(boundary: "TESTBOUNDARY")
        form.addFile(
            name: "image",
            filename: "Capture.jpg",
            contentType: "image/jpeg",
            data: Data("abc".utf8)
        )
        form.addField(name: "file_modified_at", value: "1793700000000")
        let expected = [
            "--TESTBOUNDARY\r\n",
            "Content-Disposition: form-data; name=\"image\"; filename=\"Capture.jpg\"\r\n",
            "Content-Type: image/jpeg\r\n",
            "\r\n",
            "abc\r\n",
            "--TESTBOUNDARY\r\n",
            "Content-Disposition: form-data; name=\"file_modified_at\"\r\n",
            "\r\n",
            "1793700000000\r\n",
            "--TESTBOUNDARY--\r\n",
        ].joined()
        XCTAssertEqual(String(decoding: form.encoded(), as: UTF8.self), expected)
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=TESTBOUNDARY")
        XCTAssertEqual(form.partsForTesting.count, 2)
    }

    func testEscapesQuotesAndNewlinesInNames() {
        var form = MultipartFormData(boundary: "B")
        form.addFile(
            name: "im\"age",
            filename: "a\r\nb.jpg",
            contentType: "image/jpeg",
            data: Data()
        )
        let body = String(decoding: form.encoded(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"im_age\"; filename=\"a__b.jpg\""))
    }

    func testGeneratedBoundariesAreUniqueAndSafe() {
        let first = MultipartFormData().boundary
        let second = MultipartFormData().boundary
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("KonomiTVBoundary-"))
        XCTAssertFalse(first.contains("\r"))
        XCTAssertFalse(first.contains("\n"))
    }
}

// MARK: - Filename

final class CaptureFilenameTests: XCTestCase {

    private func context(
        capturedAt: Date = CaptureFilenameTests.date("2026-11-03T21:05:09+09:00"),
        title: String = "[二][字]今日のニュース"
    ) -> CaptureFilenameContext {
        CaptureFilenameContext(
            capturedAt: capturedAt,
            channelName: "NHK総合",
            serviceID: 1024,
            remoconID: 1,
            eventID: 10001,
            eventTitle: title,
            eventStartTime: CaptureFilenameTests.date("2026-11-03T20:00:00+09:00"),
            eventEndTime: CaptureFilenameTests.date("2026-11-03T20:45:00+09:00")
        )
    }

    private static func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }

    func testDefaultPattern() {
        XCTAssertEqual(CaptureFilename.defaultPattern, "Capture_%date%-%time%")
        XCTAssertEqual(
            CaptureFilename.make(pattern: CaptureFilename.defaultPattern, context: context()),
            "Capture_20261103-210509"
        )
    }

    func testAllDateAndChannelPlaceholders() {
        let pattern = [
            "%year%-%year2%-%month%-%month2%-%day%-%day2%",
            "%hour%-%hour2%-%minute%-%minute2%-%second%-%second2%",
            "%day-of-week%",
            "%channel-name%_%channel-no%_%channel-no2%_%channel-no3%",
            "%event-id%_%event-name%_%service-name%_%service-id%",
        ].joined(separator: "_")
        XCTAssertEqual(
            CaptureFilename.make(pattern: pattern, context: context()),
            "2026-26-11-11-3-03_21-21-5-05-9-09_火_NHK総合_1_01_001_10001_"
                + "[二][字]今日のニュース_NHK総合_1024"
        )
    }

    func testProgramTimeAndDurationPlaceholders() {
        let pattern = "%start-date%_%start-time%_%end-date%_%end-time%_"
            + "%start-hour2%%start-minute2%%start-second2%_"
            + "%end-hour2%%end-minute2%%end-second2%_"
            + "%event-duration-hour%:%event-duration-min%:%event-duration-sec%_"
            + "%event-duration-hour2%%event-duration-min2%%event-duration-sec2%_"
            + "%start-day-of-week%%end-day-of-week%"
        XCTAssertEqual(
            CaptureFilename.make(pattern: pattern, context: context()),
            "20261103_200000_20261103_204500_200000_204500_0_45_0_004500_火火"
        )
    }

    func testJSTDateBoundary() {
        // 15:30Z is 00:30 on the next day in JST.
        let context = context(capturedAt: CaptureFilenameTests.date("2026-11-03T15:30:00Z"))
        XCTAssertEqual(
            CaptureFilename.make(pattern: "%date%-%time%-%day-of-week%", context: context),
            "20261104-003000-水"
        )
    }

    func testUnknownMacrosStayAndReplacementsAreNotRescanned() {
        let context = context(title: "%time%")
        XCTAssertEqual(
            CaptureFilename.make(pattern: "%event-name%_%unknown-macro%", context: context),
            "%time%_%unknown-macro%"
        )
    }

    func testSanitizesInvalidCharacters() {
        let context = context(title: "a/b:c*d?e\"f<g>h|i")
        let name = CaptureFilename.make(pattern: "%event-name%", context: context)
        XCTAssertEqual(name, "a_b_c_d_e_f_g_h_i")
        XCTAssertFalse(name.contains("/"))
    }

    func testSanitizeEmptyAndTrailingDots() {
        XCTAssertEqual(CaptureFilename.sanitize(""), "Capture")
        XCTAssertEqual(CaptureFilename.sanitize("   "), "Capture")
        XCTAssertEqual(CaptureFilename.sanitize("foo..."), "foo")
        XCTAssertEqual(CaptureFilename.sanitize("a\u{0001}b"), "a_b")
    }

    func testExplicitDurationOverridesDates() {
        var context = context()
        context.eventDuration = 3_725 // 1:02:05
        XCTAssertEqual(
            CaptureFilename.make(
                pattern: "%event-duration-hour2%%event-duration-min2%%event-duration-sec2%",
                context: context
            ),
            "010205"
        )
    }
}

// MARK: - Settings

final class CaptureSettingsTests: XCTestCase {

    func testDefaults() {
        let settings = ClientSettings()
        XCTAssertEqual(settings.captureSaveMode, .uploadServer)
        XCTAssertEqual(settings.captureCaptionMode, .both)
        XCTAssertEqual(settings.captureFilenamePattern, "Capture_%date%-%time%")
        XCTAssertFalse(settings.captureCopyToClipboard)
    }

    func testRoundTripAndPreservesUnknownKeys() throws {
        var settings = ClientSettings()
        settings.captureSaveMode = .both
        settings.captureCaptionMode = .compositingCaption
        settings.captureFilenamePattern = "%channel-name%_%date%"
        settings.captureCopyToClipboard = true
        settings["some_future_key"] = .object(["a": .number(1)])

        let data = try JSONCoding.encode(settings)
        let decoded = try JSONCoding.decode(ClientSettings.self, from: data)
        XCTAssertEqual(decoded.captureSaveMode, .both)
        XCTAssertEqual(decoded.captureCaptionMode, .compositingCaption)
        XCTAssertEqual(decoded.captureFilenamePattern, "%channel-name%_%date%")
        XCTAssertTrue(decoded.captureCopyToClipboard)
        XCTAssertEqual(decoded["some_future_key"], .object(["a": .number(1)]))
    }

    func testUnknownRawValuesFallBackToDefaults() {
        var settings = ClientSettings()
        settings["capture_save_mode"] = .string("Bogus")
        settings["capture_caption_mode"] = .string("Bogus")
        XCTAssertEqual(settings.captureSaveMode, .uploadServer)
        XCTAssertEqual(settings.captureCaptionMode, .both)
    }
}
