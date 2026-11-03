import Foundation
import XCTest
@testable import KonomiStreaming

final class PlayerStreamFilterTests: XCTestCase {
    private let pmtPID = 0x1000
    private let videoPID = 0x0100
    private let audioPID = 0x0110
    private let captionPID = 0x0130
    private let carouselPID = 0x0140

    private func pmtPacket(continuity: UInt8) -> [UInt8] {
        makeTSPacket(
            pid: pmtPID,
            payloadUnitStart: true,
            payload: sectionPayload(makeDescriptorPMTSection(
                pcrPID: videoPID,
                streams: [
                    (0x1B, videoPID, []),
                    (0x0F, audioPID, []),
                    (0x06, captionPID, [0x52, 0x01, 0x30]),
                    (0x0D, carouselPID, [0x52, 0x01, 0x40]),
                ]
            )),
            continuityCounter: continuity
        )
    }

    /// PAT, PMT, A/V and caption packets, then a second PMT like the ones
    /// broadcasts repeat every 100 ms.
    private func makeSegment() -> [UInt8] {
        let pat = makeTSPacket(
            pid: 0,
            payloadUnitStart: true,
            payload: sectionPayload(makePATSection(programNumber: 1, pmtPID: pmtPID))
        )
        var bytes = pat + pmtPacket(continuity: 0)
        bytes += makeTSPacket(pid: videoPID, payloadUnitStart: true, payload: [0x00, 0x00, 0x01, 0xE0])
        bytes += makeTSPacket(pid: audioPID, payloadUnitStart: true, payload: [0x00, 0x00, 0x01, 0xC0])
        bytes += packetizePES(
            pid: captionPID,
            pes: makeCaptionPESBytes(pts: 9000, payload: [0x80, 0xFF, 0xF0])
        ).flatMap { $0 }
        bytes += makeTSPacket(pid: carouselPID, payloadUnitStart: true, payload: [0x00])
        bytes += pmtPacket(continuity: 1)
        bytes += makeTSPacket(pid: videoPID, payloadUnitStart: false, payload: [0x11])
        return bytes
    }

    private func packets(_ data: Data) -> [TSPacket] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: TSPacket.packetSize).compactMap {
            TSPacket(bytes: Array(bytes[$0..<($0 + TSPacket.packetSize)]))
        }
    }

    func testDropsCaptionAndDataStreamsAndRewritesEveryPMT() throws {
        let filtered = PlayerStreamFilter.audioVideoOnly(Data(makeSegment()))
        let result = packets(filtered)

        XCTAssertEqual(filtered.count % TSPacket.packetSize, 0)
        XCTAssertFalse(result.contains { $0.pid == captionPID || $0.pid == carouselPID })
        XCTAssertEqual(result.filter { $0.pid == videoPID }.count, 2)
        XCTAssertEqual(result.filter { $0.pid == audioPID }.count, 1)

        let pmts = result.filter { $0.pid == pmtPID }
        XCTAssertEqual(pmts.map(\.continuityCounter), [0, 1])
        for packet in pmts {
            let pmt = try XCTUnwrap(PMT(payload: packet.payload))
            XCTAssertEqual(pmt.streams.map(\.elementaryPID), [videoPID, audioPID])
            XCTAssertEqual(pmt.pcrPID, videoPID)
            let section = try XCTUnwrap(PSIParser.section(from: packet.payload))
            XCTAssertEqual(MPEG2CRC.compute(section), 0, "CRC must validate")
        }
    }

    func testAudioVideoOnlySegmentIsUnchanged() {
        let pat = makeTSPacket(
            pid: 0,
            payloadUnitStart: true,
            payload: sectionPayload(makePATSection(programNumber: 1, pmtPID: pmtPID))
        )
        let pmt = makeTSPacket(
            pid: pmtPID,
            payloadUnitStart: true,
            payload: sectionPayload(makeDescriptorPMTSection(
                pcrPID: videoPID,
                streams: [(0x1B, videoPID, []), (0x0F, audioPID, [])]
            ))
        )
        let data = Data(pat + pmt + makeTSPacket(pid: videoPID, payloadUnitStart: true, payload: [0]))
        XCTAssertEqual(PlayerStreamFilter.audioVideoOnly(data), data)
    }

    func testSegmentWithoutPMTUsesTheKnownPMT() throws {
        let section = makeDescriptorPMTSection(
            pcrPID: videoPID,
            streams: [(0x1B, videoPID, []), (0x06, captionPID, [0x52, 0x01, 0x30])]
        )
        let pmt = try XCTUnwrap(PMT(section: section))
        let data = Data(
            makeTSPacket(pid: videoPID, payloadUnitStart: true, payload: [0])
                + makeTSPacket(pid: captionPID, payloadUnitStart: true, payload: [0])
        )
        let filtered = PlayerStreamFilter.audioVideoOnly(data, pmt: pmt, pmtPID: pmtPID)
        XCTAssertEqual(packets(filtered).map(\.pid), [videoPID])
    }
}
