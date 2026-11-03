import Foundation
import XCTest
@testable import KonomiStreaming

final class TSPacketTests: XCTestCase {

    func testParsePacketHeader() throws {
        let bytes = makeTSPacket(
            pid: 0x0100,
            payloadUnitStart: true,
            payload: [0xAA, 0xBB],
            continuityCounter: 7
        )
        let packet = try XCTUnwrap(TSPacket(bytes: bytes))
        XCTAssertEqual(packet.pid, 0x0100)
        XCTAssertTrue(packet.payloadUnitStartIndicator)
        XCTAssertFalse(packet.transportErrorIndicator)
        XCTAssertEqual(packet.continuityCounter, 7)
        XCTAssertEqual(packet.adaptationFieldControl, 1)
        XCTAssertTrue(packet.hasPayload)
        XCTAssertFalse(packet.hasAdaptationField)
        XCTAssertEqual(Array(packet.payload.prefix(2)), [0xAA, 0xBB])
        XCTAssertEqual(packet.data.count, TSPacket.packetSize)
    }

    func testParseAdaptationFieldRandomAccess() throws {
        let bytes = makeTSPacket(
            pid: 0x0100,
            payloadUnitStart: true,
            payload: [0x00, 0x00, 0x01],
            randomAccess: true
        )
        let packet = try XCTUnwrap(TSPacket(bytes: bytes))
        XCTAssertTrue(packet.hasAdaptationField)
        XCTAssertTrue(packet.randomAccessIndicator)
        XCTAssertEqual(packet.adaptationField, [0x40])
        XCTAssertEqual(Array(packet.payload.prefix(3)), [0x00, 0x00, 0x01])
    }

    func testInvalidPackets() {
        XCTAssertNil(TSPacket(bytes: [0x47]))
        XCTAssertNil(TSPacket(bytes: [UInt8](repeating: 0x00, count: 188)))
        XCTAssertNil(TSPacket(data: Data([0x47, 0x00])))
    }

    func testPacketizerHandlesArbitraryChunksAndGarbage() throws {
        let first = makeTSPacket(pid: 0x0100, payload: [0x01])
        let second = makeTSPacket(pid: 0x0101, payload: [0x02])
        let stream = [0x00, 0x47, 0x12] + first + second

        var packetizer = TSPacketizer()
        var packets: [TSPacket] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 5, stream.count)
            packets.append(contentsOf: packetizer.append(Array(stream[offset..<end])))
            offset = end
        }

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets.map(\.pid), [0x0100, 0x0101])
        XCTAssertEqual(packetizer.bufferedByteCount, 0)
    }

    func testPacketizerKeepsPartialPacket() throws {
        let first = makeTSPacket(pid: 0x0200, payload: [0x05])
        let second = makeTSPacket(pid: 0x0201, payload: [0x06])
        var packetizer = TSPacketizer()
        XCTAssertTrue(packetizer.append(Array(first[0..<100])).isEmpty)
        XCTAssertEqual(packetizer.bufferedByteCount, 100)

        var remainder = Array(first[100...])
        remainder.append(contentsOf: second)
        let packets = packetizer.append(remainder)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets.map(\.pid), [0x0200, 0x0201])
        XCTAssertEqual(packetizer.bufferedByteCount, 0)
    }

    func testResetClearsBuffer() {
        var packetizer = TSPacketizer()
        _ = packetizer.append([0x47, 0x00, 0x00])
        XCTAssertEqual(packetizer.bufferedByteCount, 3)
        packetizer.reset()
        XCTAssertEqual(packetizer.bufferedByteCount, 0)
    }
}

final class PSITests: XCTestCase {

    func testPATSection() throws {
        let section = makePATSection(programNumber: 1, pmtPID: 0x1000, transportStreamID: 0x7FE0)
        let pat = try XCTUnwrap(PAT(section: section))
        XCTAssertEqual(pat.transportStreamID, 0x7FE0)
        XCTAssertEqual(pat.programs[1], 0x1000)
        XCTAssertEqual(pat.pmtPID, 0x1000)
    }

    func testPATPayloadWithPointerField() throws {
        let section = makePATSection(programNumber: 1, pmtPID: 0x0100)
        let fromPayload = try XCTUnwrap(PAT(payload: sectionPayload(section)))
        XCTAssertEqual(fromPayload.programs[1], 0x0100)
    }

    func testPATRejectsOtherTable() {
        var section = makePATSection(pmtPID: 0x1000)
        section[0] = 0x02
        XCTAssertNil(PAT(section: section))
    }

    func testPMTParsesVideoAndAudio() throws {
        let section = makePMTSection(
            pcrPID: 0x0100,
            streams: [(0x1B, 0x0100), (0x0F, 0x0101)]
        )
        let pmt = try XCTUnwrap(PMT(section: section))
        XCTAssertEqual(pmt.programNumber, 1)
        XCTAssertEqual(pmt.pcrPID, 0x0100)
        XCTAssertEqual(pmt.streams.count, 2)
        XCTAssertEqual(pmt.videoPID, 0x0100)
        XCTAssertEqual(pmt.audioPID, 0x0101)
        XCTAssertEqual(pmt.videoCodec, .h264)
        XCTAssertEqual(pmt.audioStream?.streamType, 0x0F)
    }

    func testPMTDetectsHEVC() throws {
        let section = makePMTSection(
            pcrPID: 0x0200,
            streams: [(0x24, 0x0200), (0x11, 0x0201)]
        )
        let pmt = try XCTUnwrap(PMT(payload: sectionPayload(section)))
        XCTAssertEqual(pmt.videoCodec, .h265)
        XCTAssertEqual(pmt.audioStream?.streamType, 0x11)
    }

    func testPSIParserRejectsTruncatedSection() {
        let section = makePATSection(pmtPID: 0x1000)
        let truncated = Array(sectionPayload(section).dropLast(5))
        XCTAssertNil(PSIParser.section(from: truncated))
    }
}

final class PESTests: XCTestCase {

    func testPESPTSParsing() throws {
        let pes = makePES(pts: 90_000, payload: [0x00, 0x00, 0x00, 0x01, 0x65])
        let packet = try XCTUnwrap(PESPacket(bytes: pes))
        XCTAssertEqual(packet.streamID, 0xE0)
        XCTAssertEqual(packet.pts, 90_000)
        XCTAssertEqual(packet.ptsSeconds, 1.0)
        XCTAssertEqual(Array(packet.payload.prefix(5)), [0x00, 0x00, 0x00, 0x01, 0x65])
    }

    func testPESWithoutPTS() throws {
        let pes = makePES(pts: nil, payload: [0xAA])
        let packet = try XCTUnwrap(PESPacket(bytes: pes))
        XCTAssertNil(packet.pts)
        XCTAssertEqual(packet.payload, [0xAA])
    }

    func testDecodePTS() {
        let value: Int64 = 0x1_2345_6789
        XCTAssertEqual(PTS.decode(encodePTS(value)), value)
        XCTAssertNil(PTS.decode([0x00]))
    }

    func testPTSUnwrapperHandlesWraparound() {
        var unwrapper = PTSUnwrapper()
        let beforeWrap = PTS.modulus - 9_000
        XCTAssertEqual(unwrapper.unwrap(beforeWrap), beforeWrap)
        XCTAssertEqual(unwrapper.unwrap(9_000), PTS.modulus + 9_000)
        XCTAssertEqual(unwrapper.unwrap(18_000), PTS.modulus + 18_000)
    }

    func testPTSUnwrapperReportsBackwardJumpWithinRange() {
        var unwrapper = PTSUnwrapper()
        XCTAssertEqual(unwrapper.unwrap(1_000_000), 1_000_000)
        XCTAssertEqual(unwrapper.unwrap(5_000), 5_000)
    }

    func testH264KeyframeDetection() {
        XCTAssertTrue(KeyframeDetector.containsH264IDR([0x00, 0x00, 0x00, 0x01, 0x65]))
        XCTAssertTrue(KeyframeDetector.containsH264IDR([0x00, 0x00, 0x01, 0x65]))
        XCTAssertFalse(KeyframeDetector.containsH264IDR([0x00, 0x00, 0x00, 0x01, 0x41]))
        XCTAssertFalse(KeyframeDetector.containsH264IDR([0x00, 0x00, 0x01]))
    }

    func testH265KeyframeDetection() {
        // IDR_W_RADL = 19, header byte 19 << 1.
        XCTAssertTrue(KeyframeDetector.containsH265IRAP([0x00, 0x00, 0x00, 0x01, 0x26, 0x01]))
        // CRA = 21.
        XCTAssertTrue(KeyframeDetector.containsH265IRAP([0x00, 0x00, 0x01, 0x2A, 0x01]))
        // TRAIL_R = 1.
        XCTAssertFalse(KeyframeDetector.containsH265IRAP([0x00, 0x00, 0x01, 0x02, 0x01]))
    }

    func testKeyframeDetectorChoosesCodec() {
        XCTAssertTrue(
            KeyframeDetector.isKeyframe(
                pesPayload: [0x00, 0x00, 0x01, 0x65],
                codec: .h264
            )
        )
        XCTAssertTrue(
            KeyframeDetector.isKeyframe(
                pesPayload: [0x00, 0x00, 0x01, 0x26, 0x01],
                codec: .h265
            )
        )
    }
}
