import Foundation
import XCTest
@testable import KonomiStreaming

final class LivePlaybackClockTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testPlaybackTimeAndDateAreInverse() {
        let clock = LivePlaybackClock(playbackTime: 0, date: origin, pts: 90_000)

        XCTAssertEqual(clock.playbackTime(forDate: origin), 0, accuracy: 0.0001)
        XCTAssertEqual(clock.playbackTime(forDate: origin.addingTimeInterval(12.5)), 12.5, accuracy: 0.0001)
        XCTAssertEqual(
            clock.date(forPlaybackTime: 12.5).timeIntervalSince1970,
            origin.timeIntervalSince1970 + 12.5,
            accuracy: 0.0001
        )
    }

    func testAnchorPlaybackTimeIsOffset() {
        // A re-anchor after a live-edge seek: libVLC is already at 42 s when
        // the segment it now serves was produced.
        let clock = LivePlaybackClock(playbackTime: 42, date: origin, pts: 900_000)

        XCTAssertEqual(clock.playbackTime(forDate: origin), 42, accuracy: 0.0001)
        XCTAssertEqual(
            clock.date(forPlaybackTime: 40).timeIntervalSince1970,
            origin.timeIntervalSince1970 - 2,
            accuracy: 0.0001
        )
    }

    func testPlaybackTimeForPTS() {
        let clock = LivePlaybackClock(playbackTime: 0, date: origin, pts: 90_000)

        // One second of 90 kHz ticks after the anchor.
        XCTAssertEqual(clock.playbackTime(forPTS: 180_000), 1.0, accuracy: 0.0001)
        // Caption PES packets can be stamped slightly before the first frame.
        XCTAssertEqual(clock.playbackTime(forPTS: 45_000), -0.5, accuracy: 0.0001)
        XCTAssertEqual(clock.playbackTime(forPTS: 900_000), 9.0, accuracy: 0.0001)
    }

    func testPlaybackTimeForPTSHandlesWrapAround() {
        let clock = LivePlaybackClock(
            playbackTime: 0,
            date: origin,
            pts: PTS.modulus - 45_000
        )

        XCTAssertEqual(clock.playbackTime(forPTS: 45_000), 1.0, accuracy: 0.0001)
        XCTAssertEqual(clock.playbackTime(forPTS: PTS.modulus - 90_000), -0.5, accuracy: 0.0001)
    }

    func testPTSForPlaybackTimeIsInverse() {
        let clock = LivePlaybackClock(playbackTime: 3, date: origin, pts: 90_000)

        XCTAssertEqual(clock.pts(forPlaybackTime: 3), 90_000)
        XCTAssertEqual(clock.pts(forPlaybackTime: 4), 180_000)
        XCTAssertEqual(clock.playbackTime(forPTS: clock.pts(forPlaybackTime: 17.25)), 17.25, accuracy: 0.0001)
    }

    func testSecondsSinceOrigin() {
        let clock = LivePlaybackClock(playbackTime: 0, date: origin, pts: 90_000)

        // The caption timeline of the live pipeline starts at the stream's
        // first segment, which is 30 s before the anchor of this load.
        XCTAssertEqual(
            clock.secondsSince(origin.addingTimeInterval(-30), forPlaybackTime: 10),
            40,
            accuracy: 0.0001
        )
    }

    func testEquatableAnchor() {
        let first = LivePlaybackClock(playbackTime: 0, date: origin, pts: 90_000)
        let second = LivePlaybackClock(playbackTime: 0, date: origin, pts: 90_000)
        let third = LivePlaybackClock(playbackTime: 0, date: origin, pts: 180_000)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, third)
    }
}
