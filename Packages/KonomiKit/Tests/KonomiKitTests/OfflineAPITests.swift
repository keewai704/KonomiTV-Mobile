import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import KonomiKit

private let offlineBaseURL = URL(string: "http://127.0.0.1:7010")!

private func offlineResponse(
    for request: URLRequest,
    status: Int
) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? offlineBaseURL,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(#"{"detail":"x"}"#.utf8), response)
}

final class OfflineAPITests: XCTestCase {
    private let baseURL = offlineBaseURL

    func testOfflineStreamsAvailableIsFalseOnA404Server() async throws {
        let transport = StubTransport { request in
            offlineResponse(for: request, status: 404)
        }
        let client = APIClient(baseURL: baseURL, transport: transport)
        let available = try await client.offlineStreamsAvailable()
        XCTAssertFalse(available)

        let request = await transport.lastRequest()
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(
            request?.url?.path,
            "/api/streams/video/0/invalid/offline-stream"
        )
        // The probe must not start an encode with a real quality or video.
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
    }

    func testOfflineStreamsAvailableIsTrueWhenTheRouteValidatesThePath() async throws {
        let transport = StubTransport { request in
            offlineResponse(for: request, status: 422)
        }
        let client = APIClient(baseURL: baseURL, transport: transport)
        let available = try await client.offlineStreamsAvailable()
        XCTAssertTrue(available)
    }

    func testOfflineStreamsAvailablePropagatesNetworkErrors() async {
        let transport = StubTransport { _ in
            throw URLError(.cannotConnectToHost)
        }
        let client = APIClient(baseURL: baseURL, transport: transport)
        do {
            _ = try await client.offlineStreamsAvailable()
            XCTFail("a network failure must not be reported as supported")
        } catch {
            XCTAssertNotNil(error as? APIError)
        }
    }

    func testOfflineStreamURLContainsTheQuality() {
        let client = APIClient(baseURL: baseURL)
        let url = client.offlineStreamURL(videoID: 42, apiQuality: "720p-hevc-24fps")
        XCTAssertEqual(
            url.path,
            "/api/streams/video/42/720p-hevc-24fps/offline-stream"
        )
    }
}
