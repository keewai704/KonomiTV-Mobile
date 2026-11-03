import Foundation
import XCTest
@testable import KonomiStreaming

final class LiveSegmenterTests: XCTestCase {

    func testSegmenterOnRealSampleTS() throws {
        let data = try loadSampleTS()
        var segmenter = LiveSegmenter(targetDuration: 1.0)
        var segments: [TSSegment] = []

        var random: UInt64 = 0x9E37_79B9_7F4A_7C15
        var offset = 0
        while offset < data.count {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let chunkSize = Int((random >> 33) % 7_000) + 1
            let end = min(offset + chunkSize, data.count)
            segments.append(contentsOf: segmenter.append(data.subdata(in: offset..<end)))
            offset = end
        }
        if let final = segmenter.flush() {
            segments.append(final)
        }

        XCTAssertEqual(segments.count, 12, "Expected roughly one segment per keyframe")
        XCTAssertEqual(segments.map(\.sequence), Array(0..<segments.count))
        XCTAssertTrue(segments.allSatisfy { $0.packetCount > 0 })
        for segment in segments {
            assertSegmentStartsWithPSI(segment)
        }

        let totalDuration = segments.reduce(0.0) { $0 + $1.duration }
        XCTAssertEqual(totalDuration, 12.0, accuracy: 0.5)
        XCTAssertTrue(segments.allSatisfy { $0.duration > 0.5 && $0.duration <= 1.5 })
        XCTAssertFalse(segments.contains { $0.discontinuity })
    }

    func testSegmenterFlagsDiscontinuityWhenFileLoops() throws {
        let data = try loadSampleTS()
        var segmenter = LiveSegmenter(targetDuration: 1.0)
        var segments: [TSSegment] = []

        segments.append(contentsOf: segmenter.append(data))
        segments.append(contentsOf: segmenter.append(data))
        if let final = segmenter.flush() {
            segments.append(final)
        }

        let flagged = segments.filter(\.discontinuity)
        XCTAssertEqual(flagged.count, 1, "Exactly the first segment after the loop must be flagged")
        XCTAssertEqual(flagged.first?.sequence, 12)
        XCTAssertEqual(segments.map(\.sequence), Array(0..<segments.count))
        for segment in segments {
            assertSegmentStartsWithPSI(segment)
        }
    }

    func testSegmenterHandlesByteByByteInput() throws {
        let data = try loadSampleTS()
        var segmenter = LiveSegmenter(targetDuration: 1.0)
        var segments: [TSSegment] = []
        for byte in data {
            segments.append(contentsOf: segmenter.append(Data([byte])))
        }
        if let final = segmenter.flush() {
            segments.append(final)
        }
        XCTAssertEqual(segments.count, 12)
        XCTAssertEqual(segments.reduce(0.0) { $0 + $1.duration }, 12.0, accuracy: 0.5)
    }

    func testResetClearsState() {
        var segmenter = LiveSegmenter(targetDuration: 1.0)
        _ = segmenter.append([0x47, 0x00, 0x00])
        XCTAssertEqual(segmenter.currentSequence, 0)
        segmenter.reset()
        XCTAssertNil(segmenter.programAssociationTable)
        XCTAssertNil(segmenter.programMapTable)
        XCTAssertEqual(segmenter.currentSequence, 0)
    }

    func testSyntheticKeyframeCut() throws {
        let pmtPID = 0x1000
        let videoPID = 0x0100
        let audioPID = 0x0101

        let pat = sectionPayload(makePATSection(programNumber: 1, pmtPID: pmtPID))
        let pmt = sectionPayload(
            makePMTSection(
                pcrPID: videoPID,
                streams: [(0x1B, videoPID), (0x0F, audioPID)]
            )
        )

        var stream: [UInt8] = []
        stream += makeTSPacket(pid: 0, payloadUnitStart: true, payload: pat)
        stream += makeTSPacket(pid: pmtPID, payloadUnitStart: true, payload: pmt)

        let keyframes: [Int64] = [0, 90_000, 180_000]
        for (index, pts) in keyframes.enumerated() {
            let idrPayload = makePES(
                pts: pts,
                payload: [0x00, 0x00, 0x00, 0x01, 0x65, 0x88]
            )
            stream += makeTSPacket(
                pid: videoPID,
                payloadUnitStart: true,
                payload: idrPayload,
                randomAccess: true,
                continuityCounter: UInt8(index % 16)
            )
            stream += makeTSPacket(
                pid: audioPID,
                payloadUnitStart: true,
                payload: makePES(streamID: 0xC0, pts: pts, payload: [0x11, 0x22]),
                continuityCounter: UInt8(index % 16)
            )
        }

        var segmenter = LiveSegmenter(targetDuration: 1.0)
        var segments = segmenter.append(Data(stream))
        if let final = segmenter.flush() {
            segments.append(final)
        }

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(segments[0].duration, 1.0, accuracy: 0.0001)
        XCTAssertEqual(segments[1].duration, 1.0, accuracy: 0.0001)
        XCTAssertEqual(segments[2].duration, 0.001, accuracy: 0.0001)
        for segment in segments {
            assertSegmentStartsWithPSI(segment)
        }
    }
}

final class PlaylistTests: XCTestCase {

    private func segment(
        _ sequence: Int,
        duration: Double = 1.0,
        discontinuity: Bool = false
    ) -> TSSegment {
        TSSegment(
            sequence: sequence,
            duration: duration,
            data: Data([0x47]),
            discontinuity: discontinuity
        )
    }

    func testPlaylistWindowAndDiscontinuity() {
        var segments: [TSSegment] = []
        for index in 0..<8 {
            segments.append(
                segment(index, duration: index.isMultiple(of: 2) ? 1.0 : 1.5, discontinuity: index == 6)
            )
        }

        let playlist = LiveHLSPlaylist.render(segments: segments, windowSize: 6)
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertTrue(playlist.hasPrefix("#EXTM3U\n"))
        XCTAssertTrue(playlist.contains("#EXT-X-VERSION:3"))
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:2"))
        XCTAssertTrue(playlist.contains("#EXT-X-MEDIA-SEQUENCE:2"))
        XCTAssertTrue(playlist.contains("#EXT-X-DISCONTINUITY-SEQUENCE:0"))
        XCTAssertFalse(playlist.contains("#EXT-X-ENDLIST"))
        XCTAssertFalse(playlist.contains("seg/0.ts"))
        XCTAssertFalse(playlist.contains("seg/1.ts"))
        XCTAssertTrue(playlist.contains("seg/2.ts"))
        XCTAssertTrue(playlist.contains("seg/7.ts"))
        XCTAssertTrue(playlist.contains("#EXTINF:2.000,") || playlist.contains("#EXTINF:1.500,"))

        guard let discontinuityIndex = lines.firstIndex(of: "#EXT-X-DISCONTINUITY") else {
            return XCTFail("Missing discontinuity tag")
        }
        XCTAssertTrue(lines[discontinuityIndex + 1].hasPrefix("#EXTINF:"))
        XCTAssertEqual(lines[discontinuityIndex + 2], "seg/6.ts")
    }

    func testPlaylistDiscontinuitySequenceAcrossEviction() {
        let segments = [
            segment(10, discontinuity: true),
            segment(11),
            segment(12),
            segment(13),
        ]
        let playlist = LiveHLSPlaylist.render(
            segments: segments,
            windowSize: 2,
            discontinuitySequence: 1
        )
        XCTAssertTrue(playlist.contains("#EXT-X-MEDIA-SEQUENCE:12"))
        XCTAssertTrue(playlist.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1"))
        XCTAssertTrue(playlist.contains("seg/12.ts"))
        XCTAssertTrue(playlist.contains("seg/13.ts"))
        XCTAssertFalse(playlist.contains("seg/10.ts"))
    }

    func testPlaylistComputesDiscontinuitySequenceFromSegments() {
        let segments = [
            segment(0, discontinuity: true),
            segment(1),
            segment(2),
            segment(3),
        ]
        let playlist = LiveHLSPlaylist.render(segments: segments, windowSize: 2)
        XCTAssertTrue(playlist.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1"))
        XCTAssertTrue(playlist.contains("#EXT-X-MEDIA-SEQUENCE:2"))
    }

    func testEmptyPlaylist() {
        let playlist = LiveHLSPlaylist.render(segments: [], windowSize: 6)
        XCTAssertTrue(playlist.contains("#EXTM3U"))
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:1"))
        XCTAssertFalse(playlist.contains("#EXT-X-ENDLIST"))
    }

    func testTargetDurationRoundsUp() {
        XCTAssertEqual(TSSegmentMediaPlaylist.targetDuration(for: [segment(0, duration: 0.8)]), 1)
        XCTAssertEqual(TSSegmentMediaPlaylist.targetDuration(for: [segment(0, duration: 1.01)]), 2)
        XCTAssertEqual(TSSegmentMediaPlaylist.targetDuration(for: [segment(0, duration: 2.0)]), 2)
        XCTAssertEqual(TSSegmentMediaPlaylist.targetDuration(for: []), 1)
    }
}

final class SegmentStoreTests: XCTestCase {

    private func segment(
        _ sequence: Int,
        discontinuity: Bool = false
    ) -> TSSegment {
        TSSegment(
            sequence: sequence,
            duration: 1.0,
            data: Data(repeating: 0x47, count: 188),
            discontinuity: discontinuity
        )
    }

    func testStoreKeepsCapacityAndLooksUpBySequence() async {
        let store = SegmentStore(capacity: 3)
        await store.append(contentsOf: (0..<5).map { segment($0) })

        let count = await store.count
        XCTAssertEqual(count, 3)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.map(\.sequence), [2, 3, 4])

        let found = await store.segment(sequence: 3)
        XCTAssertEqual(found?.sequence, 3)
        let missing = await store.segment(sequence: 0)
        XCTAssertNil(missing)

        let latest = await store.latestSequence
        XCTAssertEqual(latest, 4)
    }

    func testStorePlaylistTracksDiscontinuitySequence() async {
        let store = SegmentStore(capacity: 3)
        await store.append(segment(0, discontinuity: true))
        await store.append(segment(1))
        await store.append(segment(2))
        await store.append(segment(3))
        await store.append(segment(4))

        let playlist = await store.playlist(windowSize: 2)
        XCTAssertTrue(playlist.contains("#EXT-X-MEDIA-SEQUENCE:3"))
        XCTAssertTrue(playlist.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1"))
        XCTAssertTrue(playlist.contains("seg/3.ts"))
        XCTAssertTrue(playlist.contains("seg/4.ts"))
    }

    func testStoreAppendReplacesOnSequenceRestart() async {
        let store = SegmentStore(capacity: 4)
        await store.append(segment(5))
        await store.append(segment(6))
        await store.append(segment(0))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.map(\.sequence), [0])
    }

    func testStoreClear() async {
        let store = SegmentStore(capacity: 4)
        await store.append(segment(0))
        await store.clear()
        let count = await store.count
        XCTAssertEqual(count, 0)
        let latest = await store.latestSegment
        XCTAssertNil(latest)
    }
}
