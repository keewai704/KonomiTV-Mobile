import Foundation
import XCTest
@testable import KonomiStreaming

// MARK: - Packet builders

func makeTSPacket(
    pid: Int,
    payloadUnitStart: Bool = false,
    payload: [UInt8],
    randomAccess: Bool = false,
    continuityCounter: UInt8 = 0
) -> [UInt8] {
    var bytes = [UInt8](repeating: 0xFF, count: TSPacket.packetSize)
    bytes[0] = 0x47
    bytes[1] = (payloadUnitStart ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F)
    bytes[2] = UInt8(pid & 0xFF)

    if randomAccess {
        precondition(payload.count <= 182, "Payload too large for a packet with an adaptation field")
        bytes[3] = 0x30 | (continuityCounter & 0x0F)
        bytes[4] = 1
        bytes[5] = 0x40
        for (index, byte) in payload.enumerated() {
            bytes[6 + index] = byte
        }
    } else {
        precondition(payload.count <= 184, "Payload too large for a TS packet")
        bytes[3] = 0x10 | (continuityCounter & 0x0F)
        for (index, byte) in payload.enumerated() {
            bytes[4 + index] = byte
        }
    }
    return bytes
}

func makePES(
    streamID: UInt8 = 0xE0,
    pts: Int64?,
    payload: [UInt8]
) -> [UInt8] {
    var bytes: [UInt8] = [
        0x00, 0x00, 0x01, streamID,
        0x00, 0x00,
        0x80,
        pts == nil ? 0x00 : 0x80,
        pts == nil ? 0x00 : 0x05,
    ]
    if let pts {
        bytes.append(contentsOf: encodePTS(pts))
    }
    bytes.append(contentsOf: payload)
    return bytes
}

func encodePTS(_ value: Int64) -> [UInt8] {
    [
        UInt8(((value >> 30) & 0x07) << 1) | 0x21,
        UInt8((value >> 22) & 0xFF),
        UInt8(((value >> 15) & 0x7F) << 1) | 0x01,
        UInt8((value >> 7) & 0xFF),
        UInt8((value & 0x7F) << 1) | 0x01,
    ]
}

func makePATSection(
    programNumber: Int = 1,
    pmtPID: Int,
    transportStreamID: Int = 1
) -> [UInt8] {
    let header: [UInt8] = [
        UInt8((transportStreamID >> 8) & 0xFF),
        UInt8(transportStreamID & 0xFF),
        0xC1, 0x00, 0x00,
    ]
    let entry: [UInt8] = [
        UInt8((programNumber >> 8) & 0xFF),
        UInt8(programNumber & 0xFF),
        0xE0 | UInt8((pmtPID >> 8) & 0x1F),
        UInt8(pmtPID & 0xFF),
    ]
    let body = header + entry
    let sectionLength = body.count + 4
    return [
        0x00,
        0xB0 | UInt8((sectionLength >> 8) & 0x0F),
        UInt8(sectionLength & 0xFF),
    ] + body + [0x00, 0x00, 0x00, 0x00]
}

func makePMTSection(
    programNumber: Int = 1,
    pcrPID: Int,
    streams: [(streamType: UInt8, pid: Int)]
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
        body.append(contentsOf: [
            stream.streamType,
            0xE0 | UInt8((stream.pid >> 8) & 0x1F),
            UInt8(stream.pid & 0xFF),
            0xF0, 0x00,
        ])
    }
    let sectionLength = body.count + 4
    return [
        0x02,
        0xB0 | UInt8((sectionLength >> 8) & 0x0F),
        UInt8(sectionLength & 0xFF),
    ] + body + [0x00, 0x00, 0x00, 0x00]
}

func sectionPayload(_ section: [UInt8]) -> [UInt8] {
    [0x00] + section
}

// MARK: - Segment assertions

func assertSegmentStartsWithPSI(
    _ segment: TSSegment,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let bytes = [UInt8](segment.data)
    XCTAssertEqual(bytes.count % TSPacket.packetSize, 0, "Segment has a partial packet", file: file, line: line)
    XCTAssertGreaterThanOrEqual(bytes.count, TSPacket.packetSize * 2, file: file, line: line)
    guard bytes.count >= TSPacket.packetSize * 2 else { return }
    XCTAssertEqual(bytes[0], 0x47, "Segment does not begin with a sync byte", file: file, line: line)
    guard let pat = TSPacket(bytes: Array(bytes[0..<TSPacket.packetSize])) else {
        return XCTFail("First packet is not a valid TS packet", file: file, line: line)
    }
    XCTAssertEqual(pat.pid, 0, "First packet is not a PAT", file: file, line: line)
    guard let pmt = TSPacket(bytes: Array(bytes[TSPacket.packetSize..<(TSPacket.packetSize * 2)])) else {
        return XCTFail("Second packet is not a valid TS packet", file: file, line: line)
    }
    XCTAssertNotEqual(pmt.pid, 0, "Second packet is not a PMT", file: file, line: line)
    XCTAssertTrue(pmt.payloadUnitStartIndicator, "PMT packet does not start a section", file: file, line: line)
}

func loadSampleTS() throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
    }
    let fileURL = url.appendingPathComponent("MockServer/media/sample.ts")
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw XCTSkip("sample.ts not found at \(fileURL.path)")
    }
    return try Data(contentsOf: fileURL)
}
