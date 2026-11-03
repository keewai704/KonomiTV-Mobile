import Foundation
import XCTest
@testable import KonomiStreaming

// MARK: - PROGRAM-DATE-TIME anchor

final class LiveProgramDateTimeTests: XCTestCase {
    func testAnchorMapsPTSOntoDates() {
        let anchor = LiveProgramDateTimeAnchor(
            anchorDate: Date(timeIntervalSince1970: 1_700_000_000),
            anchorPTS: 100_000
        )

        XCTAssertEqual(anchor.seconds(forPTS: 190_000), 1.0, accuracy: 0.0001)
        XCTAssertEqual(anchor.seconds(forPTS: 10_000), -1.0, accuracy: 0.0001)
        XCTAssertEqual(
            anchor.date(forPTS: 190_000).timeIntervalSince1970,
            1_700_000_001,
            accuracy: 0.0001
        )
    }

    func testAnchorHandlesPTSWrapAround() {
        let anchor = LiveProgramDateTimeAnchor(
            anchorDate: Date(timeIntervalSince1970: 1_700_000_000),
            anchorPTS: PTS.modulus - 45_000
        )
        XCTAssertEqual(anchor.seconds(forPTS: 45_000), 1.0, accuracy: 0.0001)
        XCTAssertEqual(
            anchor.date(forPTS: 45_000).timeIntervalSince1970,
            1_700_000_001,
            accuracy: 0.0001
        )
    }

    func testStringIsISODateTimeInUTC() {
        XCTAssertEqual(
            LiveProgramDateTimeAnchor.string(from: Date(timeIntervalSince1970: 1_700_000_000)),
            "2023-11-14T22:13:20.000Z"
        )
        // Sub-second precision is kept (HLS only needs milliseconds).
        XCTAssertEqual(
            LiveProgramDateTimeAnchor.string(
                from: Date(timeIntervalSince1970: 1_700_000_000.25)
            ),
            "2023-11-14T22:13:20.250Z"
        )
    }

    func testPlaylistRendersProgramDateTimeForEverySegment() throws {
        let anchor = LiveProgramDateTimeAnchor(
            anchorDate: Date(timeIntervalSince1970: 1_700_000_000),
            anchorPTS: 90_000
        )
        let segments = [
            TSSegment(sequence: 0, duration: 1, data: Data(), firstVideoPTS: 90_000),
            TSSegment(sequence: 1, duration: 1, data: Data(), firstVideoPTS: 180_000),
            // A segment without a known first PTS simply gets no PDT tag.
            TSSegment(sequence: 2, duration: 1, data: Data()),
        ]

        let playlist = TSSegmentMediaPlaylist.render(
            segments: segments,
            programDateTimeAnchor: anchor
        )

        XCTAssertTrue(
            playlist.contains("#EXT-X-PROGRAM-DATE-TIME:2023-11-14T22:13:20.000Z"),
            playlist
        )
        XCTAssertTrue(
            playlist.contains("#EXT-X-PROGRAM-DATE-TIME:2023-11-14T22:13:21.000Z"),
            playlist
        )
        // Each PDT belongs to the segment directly below it.
        let lines = playlist.split(separator: "\n").map(String.init)
        let firstDate = try XCTUnwrap(lines.firstIndex(of: "#EXT-X-PROGRAM-DATE-TIME:2023-11-14T22:13:20.000Z"))
        XCTAssertEqual(lines[firstDate + 1], "#EXTINF:1.000,")
        XCTAssertEqual(lines[firstDate + 2], "seg/0.ts")
    }

    func testPlaylistWithoutAnchorHasNoProgramDateTime() {
        let playlist = TSSegmentMediaPlaylist.render(
            segments: [TSSegment(sequence: 0, duration: 1, data: Data(), firstVideoPTS: 90_000)]
        )
        XCTAssertFalse(playlist.contains("#EXT-X-PROGRAM-DATE-TIME"))
    }

    func testSegmentStorePublishesAnchorAndPlaylistDate() async throws {
        let store = SegmentStore(capacity: 4)
        await store.append(TSSegment(
            sequence: 0,
            duration: 1,
            data: Data(),
            firstVideoPTS: 90_000
        ))

        let storedAnchor = await store.programDateTimeAnchor
        let anchor = try XCTUnwrap(storedAnchor)
        XCTAssertEqual(anchor.anchorPTS, 90_000)
        XCTAssertLessThan(abs(anchor.anchorDate.timeIntervalSinceNow), 5)

        let playlist = await store.playlist()
        XCTAssertTrue(playlist.contains("#EXT-X-PROGRAM-DATE-TIME:"), playlist)
    }

    func testSegmentStoreClearsAnchor() async throws {
        let store = SegmentStore(capacity: 4)
        await store.append(TSSegment(
            sequence: 0,
            duration: 1,
            data: Data(),
            firstVideoPTS: 90_000
        ))
        await store.clear()
        let clearedAnchor = await store.programDateTimeAnchor
        XCTAssertNil(clearedAnchor)
    }
}

// MARK: - Segment probe (recorded-video proxy)

final class TSSegmentProbeTests: XCTestCase {
    private func makeSegment(
        videoPTS: Int64,
        captionPTS: Int64?
    ) -> Data {
        let pmtPID = 0x1000
        let videoPID = 0x0100
        let captionPID = 0x0130

        var bytes: [UInt8] = []
        bytes += makeTSPacket(
            pid: 0,
            payloadUnitStart: true,
            payload: sectionPayload(makePATSection(programNumber: 1, pmtPID: pmtPID))
        )
        bytes += makeTSPacket(
            pid: pmtPID,
            payloadUnitStart: true,
            payload: sectionPayload(makeDescriptorPMTSection(
                pcrPID: videoPID,
                streams: [
                    (0x1B, videoPID, []),
                    (0x06, captionPID, [0x52, 0x01, 0x30]),
                ]
            ))
        )
        bytes += makeTSPacket(
            pid: videoPID,
            payloadUnitStart: true,
            payload: makePES(
                pts: videoPTS,
                payload: [0x00, 0x00, 0x00, 0x01, 0x65, 0x88]
            ),
            randomAccess: true
        )
        if let captionPTS {
            let pes = makeCaptionPESBytes(
                pts: captionPTS,
                payload: [0x80, 0xFF, 0xF0, 0x01, 0x02]
            )
            for packet in packetizePES(pid: captionPID, pes: pes) {
                bytes += packet
            }
        }
        return Data(bytes)
    }

    func testProbeFindsFirstVideoPTSAndPMT() throws {
        let data = makeSegment(videoPTS: 123_456, captionPTS: 130_000)
        let result = TSSegmentProbe.probe(data)
        XCTAssertEqual(result.firstVideoPTS, 123_456)
        XCTAssertEqual(result.pmt?.captionPID, 0x0130)
        XCTAssertEqual(TSSegmentProbe.firstVideoPTS(in: data), 123_456)
    }

    func testProbeExtractsCaptionPES() throws {
        let data = makeSegment(videoPTS: 90_000, captionPTS: 92_000)
        let events = TSSegmentProbe.captionPES(in: data)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .caption)
        XCTAssertEqual(events.first?.pts, 92_000)
    }

    func testProbeHandlesDataWithoutPAT() {
        let result = TSSegmentProbe.probe(Data(repeating: 0x00, count: 400))
        XCTAssertNil(result.firstVideoPTS)
        XCTAssertNil(result.pmt)
    }
}
