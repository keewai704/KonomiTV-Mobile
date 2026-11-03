import Foundation
import XCTest
import KonomiKit
@testable import KonomiStreaming

// MARK: - Synthetic two-audio stream

private let pmtPID = 0x1000
private let videoPID = 0x0100
private let primaryAudioPID = 0x0110
private let secondaryAudioPID = 0x0111

private func pmtSection(
    streams: [(streamType: UInt8, pid: Int)]
) -> [UInt8] {
    // TestSupport builds the section with a zero CRC; MPEG2CRC fixes it up so
    // the rewritten section can be checked against a valid original.
    var section = makePMTSection(pcrPID: videoPID, streams: streams)
    let body = Array(section[0..<(section.count - 4)])
    let crc = MPEG2CRC.compute(body)
    section[section.count - 4] = UInt8((crc >> 24) & 0xFF)
    section[section.count - 3] = UInt8((crc >> 16) & 0xFF)
    section[section.count - 2] = UInt8((crc >> 8) & 0xFF)
    section[section.count - 1] = UInt8(crc & 0xFF)
    return section
}

private func twoAudioStream(keyframeCount: Int = 3) -> [UInt8] {
    let pat = sectionPayload(makePATSection(programNumber: 1, pmtPID: pmtPID))
    let pmt = sectionPayload(
        pmtSection(streams: [
            (0x1B, videoPID),
            (0x0F, primaryAudioPID),
            (0x0F, secondaryAudioPID),
        ])
    )

    var stream: [UInt8] = []
    stream += makeTSPacket(pid: 0, payloadUnitStart: true, payload: pat)
    stream += makeTSPacket(pid: pmtPID, payloadUnitStart: true, payload: pmt, continuityCounter: 5)

    for index in 0..<keyframeCount {
        let pts = Int64(index) * 90_000
        stream += makeTSPacket(
            pid: videoPID,
            payloadUnitStart: true,
            payload: makePES(pts: pts, payload: [0x00, 0x00, 0x00, 0x01, 0x65, 0x88]),
            randomAccess: true,
            continuityCounter: UInt8(index % 16)
        )
        stream += makeTSPacket(
            pid: primaryAudioPID,
            payloadUnitStart: true,
            payload: makePES(streamID: 0xC0, pts: pts, payload: [0x11, 0x22]),
            continuityCounter: UInt8(index % 16)
        )
        stream += makeTSPacket(
            pid: secondaryAudioPID,
            payloadUnitStart: true,
            payload: makePES(streamID: 0xC1, pts: pts, payload: [0x33, 0x44]),
            continuityCounter: UInt8(index % 16)
        )
    }
    return stream
}

private func segments(from bytes: [UInt8]) -> [TSSegment] {
    var segmenter = LiveSegmenter(targetDuration: 1.0)
    var result = segmenter.append(Data(bytes))
    if let final = segmenter.flush() {
        result.append(final)
    }
    return result
}

private func packets(of data: Data) -> [TSPacket] {
    let bytes = [UInt8](data)
    var result: [TSPacket] = []
    var offset = 0
    while offset + TSPacket.packetSize <= bytes.count {
        if let packet = TSPacket(bytes: Array(bytes[offset..<(offset + TSPacket.packetSize)])) {
            result.append(packet)
        }
        offset += TSPacket.packetSize
    }
    return result
}

// MARK: - PMT audio detection

final class PMTAudioStreamTests: XCTestCase {

    func testTwoAudioStreamsInPMTOrder() throws {
        let pmt = try XCTUnwrap(
            PMT(section: pmtSection(streams: [
                (0x1B, videoPID),
                (0x0F, primaryAudioPID),
                (0x11, secondaryAudioPID),
            ]))
        )
        XCTAssertEqual(pmt.audioPIDs, [primaryAudioPID, secondaryAudioPID])
        XCTAssertEqual(pmt.primaryAudioPID, primaryAudioPID)
        XCTAssertEqual(pmt.secondaryAudioPID, secondaryAudioPID)
        XCTAssertTrue(pmt.hasSecondaryAudio)
        XCTAssertEqual(pmt.audioStreams.map(\.streamType), [0x0F, 0x11])
        XCTAssertEqual(pmt.audioPID, primaryAudioPID, "audioStream stays the first audio PID")
        XCTAssertEqual(pmt.videoPID, videoPID)
    }

    func testAudioStreamTypesOtherThanAAC() throws {
        for streamType: UInt8 in [0x0F, 0x11, 0x03, 0x04] {
            let pmt = try XCTUnwrap(
                PMT(section: pmtSection(streams: [(0x1B, videoPID), (streamType, 0x0200)]))
            )
            XCTAssertEqual(pmt.audioPIDs, [0x0200], "stream type \(streamType)")
        }
        // Private data and subtitles are not audio.
        let pmt = try XCTUnwrap(
            PMT(section: pmtSection(streams: [(0x1B, videoPID), (0x06, 0x0200), (0x90, 0x0300)]))
        )
        XCTAssertTrue(pmt.audioPIDs.isEmpty)
        XCTAssertFalse(pmt.hasSecondaryAudio)
    }

    func testSingleAudioStreamHasNoSecondary() throws {
        let pmt = try XCTUnwrap(
            PMT(section: pmtSection(streams: [(0x1B, videoPID), (0x0F, primaryAudioPID)]))
        )
        XCTAssertEqual(pmt.audioPIDs, [primaryAudioPID])
        XCTAssertNil(pmt.secondaryAudioPID)
        XCTAssertFalse(pmt.hasSecondaryAudio)
    }

    func testOriginalPMTSectionIsValid() throws {
        let section = pmtSection(streams: [
            (0x1B, videoPID), (0x0F, primaryAudioPID), (0x0F, secondaryAudioPID),
        ])
        XCTAssertTrue(MPEG2CRC.isValid(section))
    }

    func testMPEG2CRCKnownValue() {
        // CRC-32/MPEG-2 of "123456789" is 0x0376E6E7.
        XCTAssertEqual(MPEG2CRC.compute(Array("123456789".utf8)), 0x0376_E6E7)
    }
}

// MARK: - Segment filtering

final class LiveAudioFilterTests: XCTestCase {

    private func firstSegment() throws -> TSSegment {
        let all = segments(from: twoAudioStream())
        XCTAssertGreaterThanOrEqual(all.count, 2)
        return try XCTUnwrap(all.first)
    }

    func testSegmentCarriesBothAudioPIDs() throws {
        let segment = try firstSegment()
        let pids = Set(packets(of: segment.data).map(\.pid))
        XCTAssertTrue(pids.contains(primaryAudioPID))
        XCTAssertTrue(pids.contains(secondaryAudioPID))
        XCTAssertTrue(segment.hasSecondaryAudio)
        XCTAssertEqual(segment.audioTrackInfo?.audioPIDs, [primaryAudioPID, secondaryAudioPID])
        XCTAssertEqual(segment.audioTrackInfo?.pmtPID, pmtPID)
    }

    func testPrimarySelectionDropsSecondaryAudio() throws {
        let segment = try firstSegment()
        let filtered = segment.filtered(audio: .primary)
        let pids = Set(packets(of: filtered.data).map(\.pid))
        XCTAssertTrue(pids.contains(primaryAudioPID))
        XCTAssertFalse(pids.contains(secondaryAudioPID))
        XCTAssertTrue(pids.contains(0), "PAT must pass through untouched")
        XCTAssertTrue(pids.contains(videoPID))
        XCTAssertEqual(filtered.data.count % TSPacket.packetSize, 0)
        XCTAssertEqual(filtered.sequence, segment.sequence)
        XCTAssertEqual(filtered.duration, segment.duration)
    }

    func testSecondarySelectionDropsPrimaryAudio() throws {
        let segment = try firstSegment()
        let filtered = segment.filtered(audio: .secondary)
        let pids = Set(packets(of: filtered.data).map(\.pid))
        XCTAssertTrue(pids.contains(secondaryAudioPID))
        XCTAssertFalse(pids.contains(primaryAudioPID))
        XCTAssertTrue(pids.contains(0))
        XCTAssertTrue(pids.contains(videoPID))
    }

    func testRewrittenPMTSectionLengthAndCRC() throws {
        let segment = try firstSegment()
        for selection in AudioSelection.allCases {
            let filtered = segment.filtered(audio: selection)
            let pmtPackets = packets(of: filtered.data).filter {
                $0.pid == pmtPID && $0.payloadUnitStartIndicator
            }
            XCTAssertEqual(pmtPackets.count, 1, "exactly one PMT per segment")
            let packet = try XCTUnwrap(pmtPackets.first)
            XCTAssertEqual(packet.payload.first, 0x00, "pointer_field")
            let section = try XCTUnwrap(PSIParser.section(from: packet.payload))
            XCTAssertTrue(MPEG2CRC.isValid(section), "PMT CRC must be valid after the rewrite")

            // section_length must cover the whole section.
            let sectionLength = (Int(section[1] & 0x0F) << 8) | Int(section[2])
            XCTAssertEqual(section.count, 3 + sectionLength)

            let parsed = try XCTUnwrap(PMT(section: section))
            XCTAssertEqual(parsed.audioPIDs.count, 1)
            XCTAssertEqual(
                parsed.audioPIDs.first,
                selection == .primary ? primaryAudioPID : secondaryAudioPID
            )
            XCTAssertEqual(parsed.videoPID, videoPID)
            XCTAssertEqual(parsed.pcrPID, videoPID)
            XCTAssertEqual(parsed.programNumber, 1)
            XCTAssertFalse(parsed.hasSecondaryAudio)
        }
    }

    func testRewrittenPMTPacketKeepsHeaderAndContinuityCounter() throws {
        let segment = try firstSegment()
        let original = try XCTUnwrap(
            packets(of: segment.data).first { $0.pid == pmtPID && $0.payloadUnitStartIndicator }
        )
        let rewritten = try XCTUnwrap(
            packets(of: segment.filtered(audio: .secondary).data)
                .first { $0.pid == pmtPID && $0.payloadUnitStartIndicator }
        )
        XCTAssertEqual(rewritten.pid, original.pid)
        XCTAssertEqual(rewritten.continuityCounter, original.continuityCounter)
        XCTAssertTrue(rewritten.payloadUnitStartIndicator)
        XCTAssertFalse(rewritten.hasAdaptationField)
    }

    func testPATIsUntouched() throws {
        let segment = try firstSegment()
        let originalPAT = try XCTUnwrap(packets(of: segment.data).first { $0.pid == 0 })
        let filteredPAT = try XCTUnwrap(
            packets(of: segment.filtered(audio: .secondary).data).first { $0.pid == 0 }
        )
        XCTAssertEqual(originalPAT.bytes, filteredPAT.bytes)
    }

    func testSingleAudioStreamPassesThroughUnchanged() throws {
        let stream = {
            var bytes: [UInt8] = []
            bytes += makeTSPacket(
                pid: 0,
                payloadUnitStart: true,
                payload: sectionPayload(makePATSection(pmtPID: pmtPID))
            )
            bytes += makeTSPacket(
                pid: pmtPID,
                payloadUnitStart: true,
                payload: sectionPayload(
                    pmtSection(streams: [(0x1B, videoPID), (0x0F, primaryAudioPID)])
                )
            )
            for index in 0..<3 {
                let pts = Int64(index) * 90_000
                bytes += makeTSPacket(
                    pid: videoPID,
                    payloadUnitStart: true,
                    payload: makePES(pts: pts, payload: [0x00, 0x00, 0x00, 0x01, 0x65]),
                    randomAccess: true
                )
                bytes += makeTSPacket(
                    pid: primaryAudioPID,
                    payloadUnitStart: true,
                    payload: makePES(streamID: 0xC0, pts: pts, payload: [0x11])
                )
            }
            return bytes
        }()

        let all = segments(from: stream)
        let segment = try XCTUnwrap(all.first)
        XCTAssertFalse(segment.hasSecondaryAudio)
        for selection in AudioSelection.allCases {
            XCTAssertEqual(segment.filtered(audio: selection).data, segment.data)
        }
    }

    func testFilteredSegmentWithoutPMTReturnsInput() throws {
        let pmt = try XCTUnwrap(
            PMT(section: pmtSection(streams: [
                (0x1B, videoPID), (0x0F, primaryAudioPID), (0x0F, secondaryAudioPID),
            ]))
        )
        let data = Data(makeTSPacket(pid: videoPID, payloadUnitStart: true, payload: [0x01]))
        XCTAssertEqual(
            LiveAudioFilter.filteredSegment(
                data,
                selection: .secondary,
                pmt: pmt,
                pmtPID: pmtPID
            ),
            data
        )
    }

    func testFilteredSegmentWithOneAudioPIDReturnsInput() throws {
        let pmt = try XCTUnwrap(
            PMT(section: pmtSection(streams: [(0x1B, videoPID), (0x0F, primaryAudioPID)]))
        )
        var bytes: [UInt8] = []
        bytes += makeTSPacket(
            pid: pmtPID,
            payloadUnitStart: true,
            payload: sectionPayload(
                pmtSection(streams: [(0x1B, videoPID), (0x0F, primaryAudioPID)])
            )
        )
        bytes += makeTSPacket(pid: primaryAudioPID, payloadUnitStart: true, payload: [0x02])
        let data = Data(bytes)
        XCTAssertEqual(
            LiveAudioFilter.filteredSegment(
                data,
                selection: .secondary,
                pmt: pmt,
                pmtPID: pmtPID
            ),
            data
        )
    }

    func testLiveAudioTrackInfoSelection() throws {
        let pmt = try XCTUnwrap(
            PMT(section: pmtSection(streams: [
                (0x1B, videoPID), (0x0F, primaryAudioPID), (0x0F, secondaryAudioPID),
            ]))
        )
        let info = try XCTUnwrap(LiveAudioTrackInfo(pmt: pmt, pmtPID: pmtPID))
        XCTAssertTrue(info.hasSecondaryAudio)
        XCTAssertEqual(info.audioPID(for: .primary), primaryAudioPID)
        XCTAssertEqual(info.audioPID(for: .secondary), secondaryAudioPID)

        let singleAudioPMT = try XCTUnwrap(
            PMT(section: pmtSection(streams: [(0x1B, videoPID), (0x0F, primaryAudioPID)]))
        )
        let single = try XCTUnwrap(LiveAudioTrackInfo(pmt: singleAudioPMT, pmtPID: pmtPID))
        XCTAssertFalse(single.hasSecondaryAudio)
        XCTAssertNil(single.audioPID(for: .secondary))
    }

    func testSegmentStoreFiltersOnServe() async throws {
        let all = segments(from: twoAudioStream())
        let store = SegmentStore(capacity: 8)
        await store.append(contentsOf: all)

        let hasSecondary = await store.hasSecondaryAudio
        XCTAssertTrue(hasSecondary)

        let sequence = try XCTUnwrap(all.first?.sequence)
        let primarySegment = await store.segment(sequence: sequence, audio: .primary)
        let secondarySegment = await store.segment(sequence: sequence, audio: .secondary)
        let unfilteredSegment = await store.segment(sequence: sequence)
        let primary = try XCTUnwrap(primarySegment)
        let secondary = try XCTUnwrap(secondarySegment)
        let unfiltered = try XCTUnwrap(unfilteredSegment)

        let primaryPIDs = Set(packets(of: primary.data).map(\.pid))
        let secondaryPIDs = Set(packets(of: secondary.data).map(\.pid))
        XCTAssertTrue(primaryPIDs.contains(primaryAudioPID))
        XCTAssertFalse(primaryPIDs.contains(secondaryAudioPID))
        XCTAssertTrue(secondaryPIDs.contains(secondaryAudioPID))
        XCTAssertFalse(secondaryPIDs.contains(primaryAudioPID))

        // The stored segment is not modified: switching back and forth yields
        // the same bytes, which is what allows switching without a restart.
        XCTAssertEqual(unfiltered.data, all[0].data)
        let primaryAgainSegment = await store.segment(sequence: sequence, audio: .primary)
        let primaryAgain = try XCTUnwrap(primaryAgainSegment)
        XCTAssertEqual(primaryAgain.data, primary.data)
    }

    func testSegmenterExposesAudioTrackInfo() {
        var segmenter = LiveSegmenter(targetDuration: 1.0)
        XCTAssertNil(segmenter.audioTrackInfo)
        XCTAssertFalse(segmenter.hasSecondaryAudio)
        _ = segmenter.append(Data(twoAudioStream(keyframeCount: 1)))
        XCTAssertTrue(segmenter.hasSecondaryAudio)
        XCTAssertEqual(
            segmenter.audioTrackInfo?.audioPIDs,
            [primaryAudioPID, secondaryAudioPID]
        )
    }
}
