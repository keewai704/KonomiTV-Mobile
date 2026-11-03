import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import KonomiKit

// MARK: - Base qualities and API names

final class StreamQualityTests: XCTestCase {

    func testQualityOrderMatchesServerConstants() {
        XCTAssertEqual(
            StreamQuality.allCases.map(\.rawValue),
            [
                "original",
                "1080p-60fps",
                "1080p",
                "810p",
                "720p",
                "540p",
                "480p",
                "360p",
                "240p",
            ]
        )
    }

    func testLiveAndVideoQualityLists() {
        XCTAssertEqual(StreamQuality.liveQualities, StreamQuality.allCases)
        XCTAssertEqual(StreamQuality.videoQualities.first, .p1080p60)
        XCTAssertFalse(StreamQuality.videoQualities.contains(.original))
        XCTAssertEqual(StreamQuality.videoQualities.count, StreamQuality.allCases.count - 1)
    }

    func testVideoSafeFallsBackTo1080p() {
        XCTAssertEqual(StreamQuality.original.videoSafe, .p1080)
        XCTAssertEqual(StreamQuality.p810.videoSafe, .p810)
    }

    func testDisplayName() {
        XCTAssertEqual(StreamQuality.p1080p60.displayName, "1080p (60fps)")
        XCTAssertEqual(StreamQuality.p810.displayName, "810p")
        XCTAssertTrue(StreamQuality.p1080p60.isHighFrameRate)
        XCTAssertFalse(StreamQuality.p1080.isHighFrameRate)
    }

    func testAPIQualityForEveryCombination() {
        // Mirrors build_api_quality in PlayerController.ts: <base>[-hevc][-24fps],
        // never -24fps for 1080p-60fps, never any suffix for original.
        var combinations = 0
        for quality in StreamQuality.allCases {
            for dataSaver in [false, true] {
                for use24fps in [false, true] {
                    let profile = StreamingProfile(
                        quality: quality,
                        dataSaver: dataSaver,
                        use24fps: use24fps
                    )

                    let expected: String
                    if quality == .original {
                        expected = "original"
                    } else {
                        var name = quality.rawValue
                        if dataSaver {
                            name += "-hevc"
                        }
                        if use24fps, quality != .p1080p60 {
                            name += "-24fps"
                        }
                        expected = name
                    }

                    XCTAssertEqual(
                        profile.apiQuality(),
                        expected,
                        "quality=\(quality.rawValue) dataSaver=\(dataSaver) use24fps=\(use24fps)"
                    )
                    combinations += 1
                }
            }
        }
        XCTAssertEqual(combinations, 36)
    }

    func testConcreteAPINames() {
        XCTAssertEqual(StreamingProfile(quality: .p1080p60).apiQuality(), "1080p-60fps")
        XCTAssertEqual(
            StreamingProfile(quality: .p1080p60, dataSaver: true, use24fps: true).apiQuality(),
            "1080p-60fps-hevc"
        )
        XCTAssertEqual(
            StreamingProfile(quality: .p810, dataSaver: true, use24fps: true).apiQuality(),
            "810p-hevc-24fps"
        )
        XCTAssertEqual(StreamingProfile(quality: .p540).apiQuality(), "540p")
        XCTAssertEqual(
            StreamingProfile(quality: .p240, use24fps: true).apiQuality(),
            "240p-24fps"
        )
        XCTAssertEqual(
            StreamingProfile(quality: .original, dataSaver: true, use24fps: true).apiQuality(),
            "original"
        )
    }

    func testRadioChannelsAlwaysUse1080p() {
        XCTAssertEqual(
            StreamingProfile(quality: .p720, dataSaver: true, use24fps: true)
                .apiQuality(isRadioChannel: true),
            "1080p"
        )
        XCTAssertEqual(
            StreamingProfile(quality: .original).apiQuality(isRadioChannel: true),
            "1080p"
        )
    }

    func testLowLatencyIsNotPartOfTheAPIName() {
        XCTAssertEqual(
            StreamingProfile(quality: .p1080, lowLatency: true).apiQuality(),
            StreamingProfile(quality: .p1080).apiQuality()
        )
    }

    func testParsingAPIQuality() {
        XCTAssertEqual(StreamQuality(apiQuality: "720p"), .p720)
        XCTAssertEqual(StreamQuality(apiQuality: "720p-hevc"), .p720)
        XCTAssertEqual(StreamQuality(apiQuality: "720p-24fps"), .p720)
        XCTAssertEqual(StreamQuality(apiQuality: "720p-hevc-24fps"), .p720)
        XCTAssertEqual(StreamQuality(apiQuality: "720p-hevc-10bit-24fps"), .p720)
        XCTAssertEqual(StreamQuality(apiQuality: "1080p-60fps-hevc"), .p1080p60)
        XCTAssertEqual(StreamQuality(apiQuality: "original"), .original)
        XCTAssertNil(StreamQuality(apiQuality: "2160p"))
        XCTAssertNil(StreamQuality(apiQuality: ""))
    }

    func testEveryConcreteAPINameParsesBack() {
        for quality in StreamQuality.allCases where quality != .original {
            for dataSaver in [false, true] {
                for use24fps in [false, true] {
                    let name = StreamingProfile(
                        quality: quality,
                        dataSaver: dataSaver,
                        use24fps: use24fps
                    ).apiQuality()
                    XCTAssertEqual(StreamQuality(apiQuality: name), quality, name)
                }
            }
        }
    }

    // MARK: - Moved from ServerURLTests.swift

    func testLiveQualitiesIncludeOriginal() {
        XCTAssertTrue(StreamQuality.liveQualities.contains(.original))
        XCTAssertEqual(StreamQuality.liveQualities.first, .original)
    }

    func testVideoQualitiesExcludeOriginal() {
        XCTAssertFalse(StreamQuality.videoQualities.contains(.original))
        XCTAssertTrue(StreamQuality.videoQualities.contains(.p1080))
        XCTAssertEqual(StreamQuality.videoQualities.count, StreamQuality.allCases.count - 1)
    }

    func testRawValues() {
        XCTAssertEqual(StreamQuality.p1080p60.rawValue, "1080p-60fps")
        XCTAssertEqual(StreamQuality.p810.rawValue, "810p")
        XCTAssertEqual(StreamQuality.p540.rawValue, "540p")
        XCTAssertEqual(StreamQuality.original.rawValue, "original")
    }

    func testCodableRoundTrip() throws {
        for quality in StreamQuality.allCases {
            let data = try JSONCoding.encode(quality)
            let decoded = try JSONCoding.decode(StreamQuality.self, from: data)
            XCTAssertEqual(decoded, quality)
        }
    }

    func testStreamingProfileCodableRoundTrip() throws {
        let profile = StreamingProfile(
            quality: .p540,
            dataSaver: true,
            use24fps: true,
            lowLatency: true
        )
        let data = try JSONCoding.encode(profile)
        XCTAssertEqual(try JSONCoding.decode(StreamingProfile.self, from: data), profile)
    }
}

// MARK: - Streaming URLs

final class StreamingEndpointTests: XCTestCase {

    private let baseURL = URL(string: "http://127.0.0.1:7010")!

    private func queryItem(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    func testLiveStreamPathUsesAPIQuality() {
        let client = APIClient(baseURL: baseURL)
        let profile = StreamingProfile(quality: .p810, dataSaver: true, use24fps: true)
        XCTAssertEqual(
            client.liveStreamURL(displayChannelID: "gr011", profile: profile).absoluteString,
            "http://127.0.0.1:7010/api/streams/live/gr011/810p-hevc-24fps/mpegts"
        )
        XCTAssertEqual(
            client.liveStreamURL(displayChannelID: "gr011", quality: .original).absoluteString,
            "http://127.0.0.1:7010/api/streams/live/gr011/original/mpegts"
        )
        XCTAssertEqual(
            client.liveStreamURL(
                displayChannelID: "r001",
                profile: profile,
                isRadioChannel: true
            ).absoluteString,
            "http://127.0.0.1:7010/api/streams/live/r001/1080p/mpegts"
        )
    }

    func testLiveEventsPath() {
        let client = APIClient(baseURL: baseURL)
        XCTAssertEqual(
            client.liveEventsURL(displayChannelID: "bs101", quality: .p540).absoluteString,
            "http://127.0.0.1:7010/api/streams/live/bs101/540p/events"
        )
        XCTAssertEqual(
            client.liveEventsURL(
                displayChannelID: "bs101",
                profile: StreamingProfile(quality: .p1080p60, use24fps: true)
            ).absoluteString,
            "http://127.0.0.1:7010/api/streams/live/bs101/1080p-60fps/events"
        )
    }

    func testVideoPlaylistDefaultsToMaster() {
        let client = APIClient(baseURL: baseURL)
        let url = client.videoPlaylistURL(videoID: 7, quality: .p720, sessionID: "sid")
        XCTAssertEqual(url.path, "/api/streams/video/7/720p/playlist")
        XCTAssertEqual(queryItem(url, "session_id"), "sid")
        XCTAssertEqual(queryItem(url, "type"), "master")
        XCTAssertNil(queryItem(url, "cache_key"))
    }

    func testVideoPlaylistTypes() {
        let client = APIClient(baseURL: baseURL)
        let profile = StreamingProfile(quality: .p1080, dataSaver: true, use24fps: true)
        XCTAssertEqual(VideoPlaylistType.allCases.map(\.rawValue), [
            "master", "primary-audio", "secondary-audio",
        ])
        for playlistType in VideoPlaylistType.allCases {
            let url = client.videoPlaylistURL(
                videoID: 3,
                profile: profile,
                sessionID: "sid",
                playlistType: playlistType,
                cacheKey: "42"
            )
            XCTAssertEqual(url.path, "/api/streams/video/3/1080p-hevc-24fps/playlist")
            XCTAssertEqual(queryItem(url, "type"), playlistType.rawValue)
            XCTAssertEqual(queryItem(url, "session_id"), "sid")
            XCTAssertEqual(queryItem(url, "cache_key"), "42")
        }
    }

    func testVideoPlaylistFallsBackFromOriginal() {
        let client = APIClient(baseURL: baseURL)
        let url = client.videoPlaylistURL(videoID: 9, quality: .original, sessionID: "sid")
        XCTAssertEqual(url.path, "/api/streams/video/9/1080p/playlist")
    }

    func testVideoSegmentURL() {
        let client = APIClient(baseURL: baseURL)
        let url = client.videoSegmentURL(
            videoID: 4,
            profile: StreamingProfile(quality: .p480),
            sessionID: "sid",
            sequence: 12,
            audio: .secondary,
            cacheKey: "k"
        )
        XCTAssertEqual(url.path, "/api/streams/video/4/480p/segment")
        XCTAssertEqual(queryItem(url, "sequence"), "12")
        XCTAssertEqual(queryItem(url, "audio"), "secondary")
        XCTAssertEqual(queryItem(url, "cache_key"), "k")
        XCTAssertEqual(queryItem(url, "session_id"), "sid")
    }

    func testVideoKeepAliveURLWithProfile() {
        let client = APIClient(baseURL: baseURL)
        let url = client.videoKeepAliveURL(
            videoID: 42,
            profile: StreamingProfile(quality: .p720, dataSaver: true),
            sessionID: "sid"
        )
        XCTAssertEqual(url.path, "/api/streams/video/42/720p-hevc/keep-alive")
        XCTAssertEqual(queryItem(url, "session_id"), "sid")
    }

    func testKeepAliveRequestUsesProfileQuality() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/streams/video/5/540p-24fps/keep-alive")
            let components = request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)
            }
            XCTAssertEqual(
                components?.queryItems?.first { $0.name == "session_id" }?.value,
                "sid"
            )
            return (Data(), HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!)
        }
        let client = APIClient(baseURL: baseURL, transport: transport)
        try await client.keepAlive(
            videoID: 5,
            profile: StreamingProfile(quality: .p540, use24fps: true),
            sessionID: "sid"
        )
        let count = await transport.requestCount()
        XCTAssertEqual(count, 1)
    }
}
