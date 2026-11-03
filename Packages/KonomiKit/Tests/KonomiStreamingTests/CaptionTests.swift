import Foundation
import XCTest
@testable import KonomiStreaming

// MARK: - Helpers

/// Builds a TS packet whose payload is exactly `payload` bytes, using an
/// adaptation field for stuffing instead of 0xFF padding. This keeps the
/// payload intact when reassembling PES packets.
func makeExactTSPacket(
    pid: Int,
    payloadUnitStart: Bool,
    payload: [UInt8],
    continuityCounter: UInt8 = 0
) -> [UInt8] {
    precondition(payload.count <= 184)
    guard payload.count < 184 else {
        return makeTSPacket(
            pid: pid,
            payloadUnitStart: payloadUnitStart,
            payload: payload,
            continuityCounter: continuityCounter
        )
    }

    var bytes = [UInt8](repeating: 0xFF, count: TSPacket.packetSize)
    bytes[0] = 0x47
    bytes[1] = (payloadUnitStart ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F)
    bytes[2] = UInt8(pid & 0xFF)
    bytes[3] = 0x30 | (continuityCounter & 0x0F)
    let adaptationLength = 183 - payload.count
    bytes[4] = UInt8(adaptationLength)
    if adaptationLength > 0 {
        bytes[5] = 0x00
    }
    let start = 5 + adaptationLength
    for (index, byte) in payload.enumerated() {
        bytes[start + index] = byte
    }
    return bytes
}

func packetizePES(
    pid: Int,
    pes: [UInt8],
    continuityStart: UInt8 = 0
) -> [[UInt8]] {
    var packets: [[UInt8]] = []
    var offset = 0
    var continuity = continuityStart
    while offset < pes.count {
        let end = min(offset + 184, pes.count)
        let chunk = Array(pes[offset..<end])
        packets.append(makeExactTSPacket(
            pid: pid,
            payloadUnitStart: offset == 0,
            payload: chunk,
            continuityCounter: continuity
        ))
        offset = end
        continuity = (continuity &+ 1) & 0x0F
    }
    return packets
}

func makeCaptionPESBytes(
    streamID: UInt8 = 0xBD,
    pts: Int64?,
    payload: [UInt8],
    packetLength: Int? = nil
) -> [UInt8] {
    let headerData: [UInt8] = pts == nil ? [] : encodePTS(pts!)
    let flags: UInt8 = pts == nil ? 0x00 : 0x80
    let length = packetLength ?? (3 + headerData.count + payload.count)
    return [
        0x00, 0x00, 0x01, streamID,
        UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
        0x80,
        flags,
        UInt8(headerData.count),
    ] + headerData + payload
}

func makeDescriptorPMTSection(
    programNumber: Int = 1,
    pcrPID: Int,
    streams: [(streamType: UInt8, pid: Int, descriptors: [UInt8])]
) -> [UInt8] {
    var body: [UInt8] = [
        UInt8((programNumber >> 8) & 0xFF),
        UInt8(programNumber & 0xFF),
        0xC1, 0x00, 0x00,
        0xE0 | UInt8((pcrPID >> 8) & 0x1F),
        UInt8(pcrPID & 0xFF),
        0xF0, 0x00,
    ]
    for stream in streams {
        let descriptors = stream.descriptors
        body.append(contentsOf: [
            stream.streamType,
            0xE0 | UInt8((stream.pid >> 8) & 0x1F),
            UInt8(stream.pid & 0xFF),
            0xF0 | UInt8((descriptors.count >> 8) & 0x0F),
            UInt8(descriptors.count & 0xFF),
        ])
        body.append(contentsOf: descriptors)
    }
    let sectionLength = body.count + 4
    return [
        0x02,
        0xB0 | UInt8((sectionLength >> 8) & 0x0F),
        UInt8(sectionLength & 0xFF),
    ] + body + [0x00, 0x00, 0x00, 0x00]
}

// MARK: - PMT descriptor tests

final class CaptionPMTTests: XCTestCase {
    func testComponentTagDescriptorsIdentifyCaptionAndSuperimpose() throws {
        let section = makeDescriptorPMTSection(
            pcrPID: 0x0100,
            streams: [
                (0x1B, 0x0100, []),
                (0x0F, 0x0101, []),
                (0x06, 0x0130, [0x52, 0x01, 0x30]),
                (0x06, 0x0138, [0x52, 0x01, 0x38]),
            ]
        )
        let pmt = try XCTUnwrap(PMT(section: section))
        XCTAssertEqual(pmt.captionPID, 0x0130)
        XCTAssertEqual(pmt.superimposePID, 0x0138)
        XCTAssertEqual(pmt.captionStream?.componentTag, 0x30)
        XCTAssertEqual(pmt.superimposeStream?.componentTag, 0x38)
        XCTAssertEqual(pmt.videoPID, 0x0100)
    }

    func testAllComponentTagRanges() throws {
        let section = makeDescriptorPMTSection(
            pcrPID: 0x0100,
            streams: [
                (0x06, 0x0130, [0x52, 0x01, 0x37]),
                (0x06, 0x0138, [0x52, 0x01, 0x3F]),
            ]
        )
        let pmt = try XCTUnwrap(PMT(section: section))
        XCTAssertEqual(pmt.captionPID, 0x0130)
        XCTAssertEqual(pmt.superimposePID, 0x0138)
    }

    func testDataComponentDescriptorIsAcceptedAsCaption() throws {
        // data_component_descriptor: tag 0xFD, length 2, data_component_id 0x0008
        let section = makeDescriptorPMTSection(
            pcrPID: 0x0100,
            streams: [
                (0x1B, 0x0100, []),
                (0x06, 0x0140, [0xFD, 0x02, 0x00, 0x08]),
            ]
        )
        let pmt = try XCTUnwrap(PMT(section: section))
        XCTAssertEqual(pmt.captionPID, 0x0140)
        XCTAssertNil(pmt.superimposePID)
    }

    func testComponentTagWinsOverDataComponentID() throws {
        let section = makeDescriptorPMTSection(
            pcrPID: 0x0100,
            streams: [
                (0x06, 0x0138, [0x52, 0x01, 0x38, 0xFD, 0x02, 0x00, 0x08]),
            ]
        )
        let pmt = try XCTUnwrap(PMT(section: section))
        XCTAssertTrue(pmt.superimposeStream?.isSuperimpose == true)
        XCTAssertNil(pmt.captionPID)
        XCTAssertEqual(pmt.superimposePID, 0x0138)
    }

    func testDataComponentIDOnNonCaptionStreamIsIgnored() throws {
        let section = makeDescriptorPMTSection(
            pcrPID: 0x0100,
            streams: [
                (0x1B, 0x0100, [0xFD, 0x02, 0x00, 0x08]),
            ]
        )
        let pmt = try XCTUnwrap(PMT(section: section))
        XCTAssertNil(pmt.captionPID)
    }
}

// MARK: - PES extraction tests

final class CaptionPESExtractorTests: XCTestCase {
    private let pmtPID = 0x1000
    private let captionPID = 0x0130
    private let superimposePID = 0x0138

    private func makeStream() -> [UInt8] {
        let pat = sectionPayload(makePATSection(programNumber: 1, pmtPID: pmtPID))
        let pmt = sectionPayload(makeDescriptorPMTSection(
            pcrPID: 0x0100,
            streams: [
                (0x1B, 0x0100, []),
                (0x06, captionPID, [0x52, 0x01, 0x30]),
                (0x06, superimposePID, [0x52, 0x01, 0x38]),
            ]
        ))
        return makeTSPacket(pid: 0, payloadUnitStart: true, payload: pat)
            + makeTSPacket(pid: pmtPID, payloadUnitStart: true, payload: pmt)
    }

    func testReassemblesMultiPacketCaptionPES() throws {
        let payload = [UInt8](repeating: 0x55, count: 300)
        let captionPayload: [UInt8] = [0x80, 0xFF, 0xF0] + payload
        let pes = makeCaptionPESBytes(pts: 0x1234_5678, payload: captionPayload)
        var stream = makeStream()
        stream += packetizePES(pid: captionPID, pes: pes).flatMap { $0 }

        var extractor = CaptionPESExtractor()
        let events = extractor.append(Data(stream)) + extractor.flush()

        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.kind, .caption)
        XCTAssertEqual(event.pts, 0x1234_5678)
        XCTAssertEqual([UInt8](event.payload.prefix(3)), [0x80, 0xFF, 0xF0])
        XCTAssertEqual(event.payload.count, captionPayload.count)
    }

    func testZeroLengthPESEndsAtNextPayloadUnitStart() throws {
        let firstPayload: [UInt8] = [0x80, 0xFF, 0xF0, 0xAA, 0xBB]
        let first = makeCaptionPESBytes(
            pts: 9000,
            payload: firstPayload,
            packetLength: 0
        )
        let second = makeCaptionPESBytes(
            pts: 18000,
            payload: [0x80, 0xFF, 0xF0, 0xCC]
        )

        var stream = makeStream()
        stream += packetizePES(pid: captionPID, pes: first).flatMap { $0 }
        stream += packetizePES(pid: captionPID, pes: second, continuityStart: 4).flatMap { $0 }

        var extractor = CaptionPESExtractor()
        let events = extractor.append(Data(stream))
        // The zero-length PES is emitted when the second PES starts, and the
        // second one is complete as soon as its payload ends.
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.pts, 9000)
        XCTAssertEqual([UInt8](events.first?.payload ?? Data()), firstPayload)
        XCTAssertEqual(events.last?.pts, 18000)
        XCTAssertEqual([UInt8](events.last?.payload ?? Data()), [0x80, 0xFF, 0xF0, 0xCC])
        XCTAssertTrue(extractor.flush().isEmpty)
    }

    func testSuperimposeWithoutPTS() throws {
        let pes = makeCaptionPESBytes(
            pts: nil,
            payload: [0x81, 0xFF, 0xF0, 0x11, 0x22]
        )
        var stream = makeStream()
        stream += packetizePES(pid: superimposePID, pes: pes).flatMap { $0 }

        var extractor = CaptionPESExtractor()
        let events = extractor.append(Data(stream))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .superimpose)
        XCTAssertNil(events.first?.pts)
    }

    func testUnknownPIDsAreIgnored() throws {
        let pes = makeCaptionPESBytes(pts: 0, payload: [0x80, 0xFF, 0xF0])
        var stream = makeStream()
        stream += packetizePES(pid: 0x0200, pes: pes).flatMap { $0 }
        var extractor = CaptionPESExtractor()
        XCTAssertTrue(extractor.append(Data(stream)).isEmpty)
        // The PMT still configured the caption PID; the PES on 0x200 was ignored.
        XCTAssertEqual(extractor.captionPID, 0x0130)
    }
}

// MARK: - Live segmenter integration

final class LiveSegmenterCaptionTests: XCTestCase {
    func testSegmentFirstVideoPTSAndCaptionEvents() throws {
        let pmtPID = 0x1000
        let videoPID = 0x0100
        let captionPID = 0x0130

        let pat = sectionPayload(makePATSection(programNumber: 1, pmtPID: pmtPID))
        let pmt = sectionPayload(makeDescriptorPMTSection(
            pcrPID: videoPID,
            streams: [
                (0x1B, videoPID, []),
                (0x06, captionPID, [0x52, 0x01, 0x30]),
            ]
        ))
        var stream: [UInt8] = []
        stream += makeTSPacket(pid: 0, payloadUnitStart: true, payload: pat)
        stream += makeTSPacket(pid: pmtPID, payloadUnitStart: true, payload: pmt)

        // One second apart so every keyframe starts a segment; the third one
        // crosses the 33-bit PTS wrap (0x1FFFFFF... -> 0x000000...).
        let keyframes: [Int64] = [
            PTS.modulus - 180_000,
            PTS.modulus - 90_000,
            0,
            90_000,
        ]
        for (index, pts) in keyframes.enumerated() {
            let captionPES = makeCaptionPESBytes(
                pts: pts,
                payload: [0x80, 0xFF, 0xF0, 0x01, 0x02]
            )
            stream += packetizePES(
                pid: captionPID,
                pes: captionPES,
                continuityStart: UInt8(index)
            ).flatMap { $0 }
            let idrPayload = makePES(
                pts: pts,
                payload: [0x00, 0x00, 0x00, 0x01, 0x65, 0x88]
            )
            stream += makeTSPacket(
                pid: videoPID,
                payloadUnitStart: true,
                payload: idrPayload,
                randomAccess: true,
                continuityCounter: UInt8(index)
            )
        }

        final class Captured: @unchecked Sendable {
            var events: [CaptionPES] = []
        }
        let captured = Captured()

        var segmenter = LiveSegmenter(targetDuration: 1.0)
        segmenter.captionHandler = { captured.events.append($0) }
        let output = segmenter.process(Data(stream))
        var segments = output.segments
        if let final = segmenter.flush() {
            segments.append(final)
        }

        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments.compactMap(\.firstVideoPTS), keyframes)
        XCTAssertEqual(captured.events.count, 4)
        XCTAssertEqual(captured.events.map(\.pts), keyframes)
        XCTAssertEqual(output.captions.count, 4)
        XCTAssertEqual(captured.events.map(\.kind), Array(repeating: .caption, count: 4))
    }
}

// MARK: - HLS media playlist tests

final class HLSMediaPlaylistTests: XCTestCase {
    func testParsesSegmentsAndResolvesURLs() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/hls/media.m3u8"))
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:10
        #EXT-X-DISCONTINUITY-SEQUENCE:3
        #EXTINF:2.000,
        seg0.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:1.500,
        sub/seg1.ts
        #EXT-X-ENDLIST
        """
        let playlist = try XCTUnwrap(HLSMediaPlaylist(text: text, url: baseURL))
        XCTAssertEqual(playlist.targetDuration, 2)
        XCTAssertEqual(playlist.mediaSequence, 10)
        XCTAssertEqual(playlist.discontinuitySequence, 3)
        XCTAssertTrue(playlist.isEndList)
        XCTAssertEqual(playlist.segments.count, 2)
        XCTAssertEqual(playlist.segments[0].sequence, 10)
        XCTAssertEqual(playlist.segments[1].sequence, 11)
        XCTAssertEqual(playlist.segments[0].url.absoluteString, "https://example.com/hls/seg0.ts")
        XCTAssertEqual(playlist.segments[1].url.absoluteString, "https://example.com/hls/sub/seg1.ts")
        XCTAssertFalse(playlist.segments[0].discontinuity)
        XCTAssertTrue(playlist.segments[1].discontinuity)
        XCTAssertEqual(playlist.segments[0].duration, 2.0, accuracy: 0.0001)
        XCTAssertEqual(playlist.segments[1].duration, 1.5, accuracy: 0.0001)
    }

    func testPlaybackTimeAddsPreviousDurations() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/media.m3u8"))
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXTINF:2.0,
        a.ts
        #EXTINF:1.5,
        b.ts
        #EXTINF:2.0,
        c.ts
        #EXT-X-ENDLIST
        """
        let playlist = try XCTUnwrap(HLSMediaPlaylist(text: text, url: baseURL))

        let first = Int64(132_000)
        XCTAssertEqual(
            try XCTUnwrap(playlist.playbackTime(segmentIndex: 0, pts: first + 9_000, firstPTS: first)),
            0.1,
            accuracy: 0.0001
        )
        let second = Int64(312_000)
        XCTAssertEqual(
            try XCTUnwrap(playlist.playbackTime(segmentIndex: 1, pts: second + 45_000, firstPTS: second)),
            2.5,
            accuracy: 0.0001
        )
        let third = Int64(492_000)
        XCTAssertEqual(
            try XCTUnwrap(playlist.playbackTime(segmentIndex: 2, pts: third + 90_000, firstPTS: third)),
            4.5,
            accuracy: 0.0001
        )
        XCTAssertNil(playlist.playbackTime(segmentIndex: 3, pts: 0, firstPTS: 0))
    }

    func testPlaybackTimeHandlesPTSWrapAround() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/media.m3u8"))
        let playlist = try XCTUnwrap(HLSMediaPlaylist(
            text: "#EXTM3U\n#EXTINF:2.0,\na.ts\n#EXT-X-ENDLIST\n",
            url: baseURL
        ))
        let first = PTS.modulus - 45_000
        let pts: Int64 = 45_000
        XCTAssertEqual(
            try XCTUnwrap(playlist.playbackTime(segmentIndex: 0, pts: pts, firstPTS: first)),
            1.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(HLSMediaPlaylist.signedTicks(from: first, to: pts), Int64(90_000))
        XCTAssertEqual(HLSMediaPlaylist.signedTicks(from: 45_000, to: 0), Int64(-45_000))
    }

    func testRejectsPlaylistWithoutSegments() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/media.m3u8"))
        XCTAssertNil(HLSMediaPlaylist(text: "#EXTM3U\n#EXT-X-ENDLIST\n", url: baseURL))
    }
}
