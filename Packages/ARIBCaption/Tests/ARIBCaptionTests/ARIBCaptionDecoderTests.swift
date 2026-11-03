import XCTest
@testable import ARIBCaption

/// Builds ARIB STD-B24 caption PES payloads by hand so the decoder can be
/// tested without any binary fixtures. The layout follows ARIB STD-B24 part 2
/// and matches what libaribcaption's decoder expects:
///
///     data_identifier (0x80/0x81) | private_stream_id 0xFF | header length
///     data_group_id (16 bit) | data_group_size (16 bit) | data_group
///     TMD (1 byte) | data_unit_loop_length (24 bit) | data units
///     unit_separator 0x1F | data_unit_parameter | data_unit_size (24 bit) | body
///
/// Text is encoded with the 8-bit JIS GL (G0 = Kanji) set: writing the JIS
/// bytes with the high bit stripped addresses the same characters.
enum CaptionTestVector {
    /// Katakana "テスト" in JIS X 0208 row 5: 0x2546 0x2539 0x2548.
    static let testText: [UInt8] = [0x25, 0x46, 0x25, 0x39, 0x25, 0x48]

    static func pes(
        statementBody: [UInt8],
        dataIdentifier: UInt8 = 0x80
    ) -> Data {
        let dataUnit = [0x1F, 0x20] + uint24(statementBody.count) + statementBody
        let content = [0x00] + uint24(dataUnit.count) + dataUnit
        // data_group_id, data_group_version/link_number,
        // last_data_group_link_number, data_group_size (ARIB STD-B24 part 2).
        let group = [0x04, 0x00, 0x00] + uint16(content.count) + content
        return Data([dataIdentifier, 0xFF, 0xF0] + group)
    }

    /// Caption statement that clears the screen, moves the active position and
    /// writes テスト. 0x0C = CS (clear screen), 0x1C = APS, 0x25/0x46 = テ ...
    static func testPES(dataIdentifier: UInt8 = 0x80) -> Data {
        let body = [0x0C, 0x1C, 0x10, 0x02] + testText
        return pes(statementBody: body, dataIdentifier: dataIdentifier)
    }

    private static func uint24(_ value: Int) -> [UInt8] {
        [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func uint16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

final class ARIBCaptionDecoderTests: XCTestCase {
    func testDecodeSyntheticCaption() throws {
        let decoder = try ARIBCaptionDecoder(type: .caption, profile: .a)
        let result = decoder.decode(pes: CaptionTestVector.testPES(), pts: 135_000)

        guard case .gotCaption(let caption) = result else {
            return XCTFail("expected a caption, got \(result)")
        }
        XCTAssertEqual(caption.text, "テスト")
        XCTAssertEqual(caption.ptsMilliseconds, 135_000 / 90)
        XCTAssertTrue(caption.isClearScreen)
        XCTAssertEqual(caption.planeWidth, 960)
        XCTAssertEqual(caption.planeHeight, 540)
        XCTAssertFalse(caption.regions.isEmpty)
        XCTAssertEqual(caption.regions.first?.characters.count, 3)
        XCTAssertEqual(caption.regions.first?.text, "テスト")
        XCTAssertEqual(
            caption.regions.first?.characters.map(\.codePoint),
            [0x30C6, 0x30B9, 0x30C8]
        )
        XCTAssertEqual(caption.plainText, "テスト")
    }

    func testDecodeWithoutPTS() throws {
        let decoder = try ARIBCaptionDecoder(type: .caption, profile: .a)
        guard case .gotCaption(let caption) = decoder.decode(pes: CaptionTestVector.testPES(), pts: nil) else {
            return XCTFail("expected a caption")
        }
        XCTAssertNil(caption.ptsMilliseconds)
        XCTAssertEqual(caption.text, "テスト")
    }

    func testDecodeSuperimpose() throws {
        let decoder = try ARIBCaptionDecoder(type: .superimpose, profile: .a)
        let pes = CaptionTestVector.testPES(dataIdentifier: 0x81)
        guard case .gotCaption(let caption) = decoder.decode(pes: pes, pts: nil) else {
            return XCTFail("expected a superimpose caption")
        }
        XCTAssertEqual(caption.text, "テスト")
        XCTAssertTrue(caption.isClearScreen)
    }

    func testDecodesMockServerCaptionStatement() throws {
        // Exact statement body produced by MockServer/caption_injector.py for
        // "テスト字幕" (EUC-JP JIS cells with the high bit stripped).
        let body: [UInt8] = [
            0x0C,
            0x25, 0x46, 0x25, 0x39, 0x25, 0x48, 0x3B, 0x7A, 0x4B, 0x6B,
        ]
        let decoder = try ARIBCaptionDecoder(type: .caption, profile: .a)
        guard case .gotCaption(let caption) = decoder.decode(
            pes: CaptionTestVector.pes(statementBody: body),
            pts: 150_000
        ) else {
            return XCTFail("expected the mock server caption to decode")
        }
        XCTAssertEqual(caption.text, "テスト字幕")
        XCTAssertTrue(caption.isClearScreen)
    }

    func testDataIdentifierMismatchIsRejected() throws {
        let decoder = try ARIBCaptionDecoder(type: .caption, profile: .a)
        let pes = CaptionTestVector.testPES(dataIdentifier: 0x81)
        guard case .error = decoder.decode(pes: pes, pts: 0) else {
            return XCTFail("a superimpose PES must not decode on a caption decoder")
        }
    }

    func testEmptyAndGarbagePESDoNotCrash() throws {
        let decoder = try ARIBCaptionDecoder(type: .caption, profile: .a)
        guard case .error = decoder.decode(pes: Data(), pts: 0) else {
            return XCTFail("empty PES should be an error")
        }
        guard case .error = decoder.decode(pes: Data([0x00, 0x01, 0x02, 0x03]), pts: 0) else {
            return XCTFail("garbage PES should be an error")
        }
        // Valid header with a truncated data group must not crash either.
        let truncated = CaptionTestVector.testPES().prefix(10)
        _ = decoder.decode(pes: Data(truncated), pts: 0)
    }

    func testNoCaptionForEmptyDataGroup() throws {
        let decoder = try ARIBCaptionDecoder(type: .caption, profile: .a)
        // data_identifier / private_stream_id / header length, then a statement
        // group whose data_unit_loop_length is zero.
        let pes = Data([
            0x80, 0xFF, 0xF0,
            0x04, 0x00, 0x00, 0x00, 0x04,
            0x00, 0x00, 0x00, 0x00,
        ])
        let result = decoder.decode(pes: pes, pts: 0)
        switch result {
        case .noCaption, .error:
            break
        case .gotCaption:
            XCTFail("an empty data group must not produce a caption")
        }
    }

    func testSecondStatementWithoutClearScreen() throws {
        let decoder = try ARIBCaptionDecoder(type: .caption, profile: .a)
        let first = CaptionTestVector.testPES()
        guard case .gotCaption = decoder.decode(pes: first, pts: 0) else {
            return XCTFail("first statement")
        }

        // A second statement without a clear-screen code appends to the caption.
        let body = [0x1C, 0x12, 0x02] + CaptionTestVector.testText
        let second = CaptionTestVector.pes(statementBody: body)
        guard case .gotCaption(let caption) = decoder.decode(pes: second, pts: 90_000) else {
            return XCTFail("second statement")
        }
        // Each statement data group produces a caption for that statement;
        // the clear-screen flag is only set when the CS control code appears.
        XCTAssertEqual(caption.text, "テスト")
        XCTAssertFalse(caption.isClearScreen)
    }
}
