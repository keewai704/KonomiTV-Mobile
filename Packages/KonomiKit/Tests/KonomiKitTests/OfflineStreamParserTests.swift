import Foundation
import XCTest
@testable import KonomiKit

// MARK: - Stream builder

/// Builds a KonomiTV offline save stream byte for byte.
struct OfflineStreamBuilder {
    private(set) var data = Data()

    init(metadata: OfflineStreamMetadata? = nil, magic: Data = OfflineStreamParser.magic) {
        data.append(magic)
        if let metadata {
            appendMetadata(metadata)
        }
    }

    mutating func appendMetadata(_ metadata: OfflineStreamMetadata) {
        let json = try! JSONCoding.encode(metadata)
        appendUInt32(UInt32(json.count))
        data.append(json)
    }

    mutating func appendSegment(
        sequence: Int,
        durationMilliseconds: UInt32 = 2000,
        payload: Data
    ) {
        appendUInt32(UInt32(sequence))
        appendUInt32(durationMilliseconds)
        appendUInt32(UInt32(payload.count))
        data.append(payload)
    }

    mutating func appendTerminator(count: Int) {
        appendUInt32(0xFFFF_FFFF)
        appendUInt32(UInt32(count))
    }

    private mutating func appendUInt32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

/// Deterministic random number generator, so a failing split is reproducible.
struct OfflineTestRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(upperBound, 1)))
    }
}

func makeOfflineMetadata(
    videoID: Int = 1,
    fileHash: String = "hash-1",
    quality: String = "720p",
    durationSeconds: Double = 120
) -> OfflineStreamMetadata {
    OfflineStreamMetadata(
        videoID: videoID,
        fileHash: fileHash,
        quality: quality,
        durationSeconds: durationSeconds
    )
}

func makeOfflineStream(segmentCount: Int = 4, segmentLength: Int = 33) -> Data {
    var builder = OfflineStreamBuilder(metadata: makeOfflineMetadata())
    for sequence in 0..<segmentCount {
        let payload = Data((0..<segmentLength).map { UInt8(($0 + sequence * 7) & 0xFF) })
        builder.appendSegment(sequence: sequence, payload: payload)
    }
    builder.appendTerminator(count: segmentCount)
    return builder.data
}

// MARK: - Tests

final class OfflineStreamParserTests: XCTestCase {
    func testParsesMetadataSegmentsAndTerminator() throws {
        let data = makeOfflineStream(segmentCount: 3, segmentLength: 10)
        var parser = OfflineStreamParser()
        let events = try parser.append(data)

        guard case .metadata(let metadata) = events.first else {
            return XCTFail("metadata event is missing")
        }
        XCTAssertEqual(metadata.videoID, 1)
        XCTAssertEqual(metadata.fileHash, "hash-1")
        XCTAssertEqual(metadata.quality, "720p")
        XCTAssertEqual(metadata.durationSeconds, 120)

        let segments = events.compactMap { event -> OfflineStreamSegment? in
            guard case .segment(let segment) = event else { return nil }
            return segment
        }
        XCTAssertEqual(segments.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(segments.map(\.durationMilliseconds), [2000, 2000, 2000])
        XCTAssertEqual(segments[0].data.count, 10)
        XCTAssertEqual(segments[1].data.first, UInt8(7))

        guard case .end(let count)? = events.last else {
            return XCTFail("terminator event is missing")
        }
        XCTAssertEqual(count, 3)
        XCTAssertTrue(parser.isFinished)
        XCTAssertEqual(parser.receivedSegmentCount, 3)
        XCTAssertNoThrow(try parser.finish())
    }

    func testArbitraryChunkSplitsProduceTheSameResult() throws {
        let data = makeOfflineStream(segmentCount: 5, segmentLength: 64)
        var random = OfflineTestRandom(seed: 20261104)

        for _ in 0..<40 {
            var parser = OfflineStreamParser()
            var events: [OfflineStreamEvent] = []
            var offset = 0
            while offset < data.count {
                let remaining = data.count - offset
                let size = min(random.next(upperBound: 17) + 1, remaining)
                let start = data.startIndex + offset
                let chunk = Data(data[start..<(start + size)])
                events.append(contentsOf: try parser.append(chunk))
                offset += size
            }
            try parser.finish()

            XCTAssertEqual(events.count, 7, "metadata + 5 segments + terminator")
            let sequences = events.compactMap { event -> Int? in
                guard case .segment(let segment) = event else { return nil }
                return segment.sequence
            }
            XCTAssertEqual(sequences, [0, 1, 2, 3, 4])
        }
    }

    func testByteByByteFeedingWorks() throws {
        let data = makeOfflineStream(segmentCount: 2, segmentLength: 5)
        var parser = OfflineStreamParser()
        var events: [OfflineStreamEvent] = []
        for byte in data {
            events.append(contentsOf: try parser.append(Data([byte])))
        }
        try parser.finish()
        XCTAssertEqual(events.filter { if case .segment = $0 { return true } else { return false } }.count, 2)
    }

    func testRejectsWrongMagic() {
        var builder = OfflineStreamBuilder(metadata: nil)
        builder.appendMetadata(makeOfflineMetadata())
        var parser = OfflineStreamParser()
        var wrongMagic = Data("KTVODLX\n".utf8)
        wrongMagic.append(builder.data.dropFirst(OfflineStreamParser.magic.count))

        XCTAssertThrowsError(try parser.append(wrongMagic)) { error in
            XCTAssertEqual(error as? OfflineStreamParserError, .invalidMagic)
        }
    }

    func testRejectsOversizedMetadataLength() {
        var data = OfflineStreamParser.magic
        data.append(contentsOf: [0x00, 0x20, 0x00, 0x00]) // 2 MiB
        var parser = OfflineStreamParser()
        XCTAssertThrowsError(try parser.append(data)) { error in
            XCTAssertEqual(error as? OfflineStreamParserError, .invalidMetadataLength)
        }
    }

    func testRejectsOutOfOrderSegments() {
        var builder = OfflineStreamBuilder(metadata: makeOfflineMetadata())
        builder.appendSegment(sequence: 1, payload: Data([1, 2, 3]))
        var parser = OfflineStreamParser()
        XCTAssertThrowsError(try parser.append(builder.data)) { error in
            XCTAssertEqual(
                error as? OfflineStreamParserError,
                .unexpectedSequence(expected: 0, actual: 1)
            )
        }
    }

    func testRejectsSegmentCountMismatch() {
        var builder = OfflineStreamBuilder(metadata: makeOfflineMetadata())
        builder.appendSegment(sequence: 0, payload: Data([1, 2, 3]))
        builder.appendTerminator(count: 3)
        var parser = OfflineStreamParser()
        XCTAssertThrowsError(try parser.append(builder.data)) { error in
            XCTAssertEqual(
                error as? OfflineStreamParserError,
                .segmentCountMismatch(declared: 3, received: 1)
            )
        }
    }

    func testRejectsZeroLengthSegment() {
        var builder = OfflineStreamBuilder(metadata: makeOfflineMetadata())
        builder.appendSegment(sequence: 0, payload: Data())
        var parser = OfflineStreamParser()
        XCTAssertThrowsError(try parser.append(builder.data)) { error in
            XCTAssertEqual(error as? OfflineStreamParserError, .invalidSegmentHeader(sequence: 0))
        }
    }

    func testTruncatedStreamIsReportedByFinish() throws {
        let full = makeOfflineStream(segmentCount: 3, segmentLength: 12)
        let truncated = Data(full.prefix(full.count - 4))
        var parser = OfflineStreamParser()
        _ = try parser.append(truncated)
        XCTAssertFalse(parser.isFinished)
        XCTAssertThrowsError(try parser.finish()) { error in
            XCTAssertEqual(error as? OfflineStreamParserError, .truncated)
        }
    }

    func testIgnoresBytesAfterTheTerminator() throws {
        var data = makeOfflineStream(segmentCount: 1, segmentLength: 4)
        data.append(contentsOf: [0xAA, 0xBB])
        var parser = OfflineStreamParser()
        let events = try parser.append(data)
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(parser.isFinished)
        XCTAssertTrue(try parser.append(Data([0x01])).isEmpty)
    }

    func testMetadataMatching() {
        let metadata = makeOfflineMetadata(videoID: 7, fileHash: "abc", quality: "720p-hevc")
        XCTAssertTrue(metadata.matches(videoID: 7, fileHash: "abc", quality: "720p-hevc"))
        XCTAssertFalse(metadata.matches(videoID: 8, fileHash: "abc", quality: "720p-hevc"))
        XCTAssertFalse(metadata.matches(videoID: 7, fileHash: "other", quality: "720p-hevc"))
        XCTAssertFalse(metadata.matches(videoID: 7, fileHash: "abc", quality: "720p"))
        // A program without a file hash can only be matched by id and quality.
        XCTAssertTrue(metadata.matches(videoID: 7, fileHash: "", quality: "720p-hevc"))
    }
}
