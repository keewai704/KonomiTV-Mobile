import Foundation
import XCTest
@testable import KonomiKit

final class ServerURLTests: XCTestCase {

    func testTrimsWhitespaceAndTrailingSlash() throws {
        let server = try ServerURL(validating: "  http://127.0.0.1:7010/  ")
        XCTAssertEqual(server.absoluteString, "http://127.0.0.1:7010")
        XCTAssertEqual(server.description, "http://127.0.0.1:7010")
    }

    func testAddsHTTPSWhenSchemeIsMissing() throws {
        let server = try ServerURL(validating: "example.com")
        XCTAssertEqual(server.absoluteString, "https://example.com")
    }

    func testPreservesPathWithoutTrailingSlash() throws {
        let server = try ServerURL(validating: "https://example.com/konomitv/")
        XCTAssertEqual(server.absoluteString, "https://example.com/konomitv")
        XCTAssertEqual(server.apiURL.absoluteString, "https://example.com/konomitv/api")
    }

    func testNormalizeStaticHelper() throws {
        let url = try ServerURL.normalize(" http://localhost:8080/ ")
        XCTAssertEqual(url.absoluteString, "http://localhost:8080")
    }

    func testFailableInitializer() {
        XCTAssertNotNil(ServerURL("http://localhost:7010"))
        XCTAssertNil(ServerURL("   "))
        XCTAssertNil(ServerURL("ftp://example.com"))
    }

    func testRejectsEmptyURL() {
        XCTAssertThrowsError(try ServerURL(validating: "  ")) { error in
            XCTAssertEqual(error as? ServerURLError, .empty)
        }
    }

    func testRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try ServerURL(validating: "ftp://example.com")) { error in
            XCTAssertEqual(error as? ServerURLError, .unsupportedScheme("ftp"))
        }
    }

    func testRejectsMissingHost() {
        XCTAssertThrowsError(try ServerURL(validating: "http://"))
        XCTAssertThrowsError(try ServerURL(validating: "https:///path"))
    }

    func testRejectsWhitespaceInsideURL() {
        XCTAssertThrowsError(try ServerURL(validating: "http://exa mple.com"))
    }

    func testRejectsQueryAndFragment() {
        XCTAssertThrowsError(try ServerURL(validating: "http://example.com?x=1"))
        XCTAssertThrowsError(try ServerURL(validating: "http://example.com/#section"))
    }

    func testErrorDescriptionsAreJapanese() {
        XCTAssertTrue(ServerURLError.empty.localizedDescription.contains("URL"))
        XCTAssertTrue(ServerURLError.unsupportedScheme("ftp").localizedDescription.contains("ftp"))
    }
}

final class StreamQualityTests: XCTestCase {

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
        XCTAssertEqual(StreamQuality.p720HEVC.rawValue, "720p-hevc")
        XCTAssertEqual(StreamQuality.original.rawValue, "original")
    }

    func testHEVCFlags() {
        XCTAssertTrue(StreamQuality.p1080HEVC.isHEVC)
        XCTAssertFalse(StreamQuality.p1080.isHEVC)
        XCTAssertTrue(StreamQuality.p1080p60.isHighFrameRate)
        XCTAssertFalse(StreamQuality.p720.isHighFrameRate)
    }

    func testVideoSafeFallsBackFromOriginal() {
        XCTAssertEqual(StreamQuality.original.videoSafe, .p1080)
        XCTAssertEqual(StreamQuality.p720.videoSafe, .p720)
        XCTAssertEqual(StreamQuality.p720HEVC.videoSafe, .p720HEVC)
    }

    func testCodableRoundTrip() throws {
        let data = try JSONCoding.encode(StreamQuality.p480HEVC)
        let decoded = try JSONCoding.decode(StreamQuality.self, from: data)
        XCTAssertEqual(decoded, .p480HEVC)
    }
}
