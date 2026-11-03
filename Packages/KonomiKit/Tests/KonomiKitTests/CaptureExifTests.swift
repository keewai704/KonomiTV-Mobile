import Foundation
import XCTest
@testable import KonomiKit

// MARK: - Test-only EXIF reader

/// Minimal TIFF/EXIF reader used to parse the segment the writer produced.
private struct TestTIFF {
    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        let bytes: Data
    }

    let tiff: Data
    let littleEndian: Bool

    init?(jpeg: Data) {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        var tiffStart: Int?
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                index += 2
                continue
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2 else { return nil }
            if marker == 0xE1, length >= 8 {
                let start = index + 4
                let magic: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
                if bytes[start..<(start + 6)].elementsEqual(magic) {
                    tiffStart = start + 6
                    break
                }
            }
            index += 2 + length
        }
        guard let start = tiffStart, start + 8 <= bytes.count else { return nil }
        let header = bytes[start..<(start + 8)]
        if header[start] == 0x49, header[start + 1] == 0x49 {
            littleEndian = true
        } else if header[start] == 0x4D, header[start + 1] == 0x4D {
            littleEndian = false
        } else {
            return nil
        }
        tiff = Data(bytes[start...])
    }

    func uint16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= tiff.count else { return nil }
        let low = UInt16(tiff[tiff.startIndex + offset])
        let high = UInt16(tiff[tiff.startIndex + offset + 1])
        return littleEndian ? (low | high << 8) : (high | low << 8)
    }

    func uint32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= tiff.count else { return nil }
        let values = (0..<4).map { UInt32(tiff[tiff.startIndex + offset + $0]) }
        return littleEndian
            ? values[0] | values[1] << 8 | values[2] << 16 | values[3] << 24
            : values[3] | values[2] << 8 | values[1] << 16 | values[0] << 24
    }

    var firstIFDOffset: Int? {
        guard let value = uint32(4) else { return nil }
        return Int(value)
    }

    func entries(at ifdOffset: Int) -> [Entry]? {
        guard let rawCount = uint16(ifdOffset) else { return nil }
        let count = Int(rawCount)
        var result: [Entry] = []
        for index in 0..<count {
            let entryOffset = ifdOffset + 2 + index * 12
            guard let tag = uint16(entryOffset),
                  let type = uint16(entryOffset + 2),
                  let rawValueCount = uint32(entryOffset + 4),
                  let value = uint32(entryOffset + 8) else {
                return nil
            }
            let size = Self.typeSize(type) * Int(rawValueCount)
            let bytes: Data
            if size <= 4 {
                let start = tiff.startIndex + entryOffset + 8
                bytes = tiff[start..<(start + size)]
            } else {
                let start = tiff.startIndex + Int(value)
                guard start + size <= tiff.endIndex else { return nil }
                bytes = tiff[start..<(start + size)]
            }
            result.append(Entry(tag: tag, type: type, count: Int(rawValueCount), bytes: Data(bytes)))
        }
        return result
    }

    func entry(_ tag: UInt16, in ifdOffset: Int) -> Entry? {
        entries(at: ifdOffset)?.first { $0.tag == tag }
    }

    /// UTF-16LE string of a BYTE entry, NUL terminated (XPComment).
    func utf16String(_ entry: Entry) -> String? {
        var units: [UInt16] = []
        var index = 0
        while index + 1 < entry.bytes.count {
            let unit = UInt16(entry.bytes[entry.bytes.startIndex + index])
                | UInt16(entry.bytes[entry.bytes.startIndex + index + 1]) << 8
            units.append(unit)
            index += 2
        }
        while let last = units.last, last == 0 {
            units.removeLast()
        }
        return String(decoding: units, as: UTF16.self)
    }

    func asciiString(_ entry: Entry) -> String {
        var bytes = entry.bytes
        while bytes.last == 0 {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func typeSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1     // BYTE, ASCII, SBYTE, UNDEFINED
        case 3, 8: return 2           // SHORT, SSHORT
        case 4, 9, 11: return 4       // LONG, SLONG, FLOAT
        case 5, 10, 12: return 8      // RATIONAL, SRATIONAL, DOUBLE
        default: return 1
        }
    }
}

private func makeJPEG(app0: Bool = true) -> Data {
    var data = Data([0xFF, 0xD8])
    if app0 {
        var segment = Data([0xFF, 0xE0])
        let payload = Data([0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00])
        let length = UInt16(payload.count + 2)
        segment.append(UInt8(length >> 8))
        segment.append(UInt8(length & 0xFF))
        segment.append(payload)
        data.append(segment)
    }
    // A scan header followed by some "compressed data" and the EOI marker.
    data.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
    data.append(contentsOf: [0x12, 0x34, 0x56, 0x78])
    data.append(contentsOf: [0xFF, 0xD9])
    return data
}

private func date(_ string: String) -> Date {
    CaptureExifMetadata.parseISO8601(string)!
}

// MARK: - Tests

final class CaptureExifTests: XCTestCase {

    private func sampleMetadata(captionText: String? = "今日のニュースです") -> CaptureExifMetadata {
        CaptureExifMetadata(
            capturedAt: "2026-11-04T00:36:57+09:00",
            capturedPlaybackPosition: 2217.0,
            networkID: 32736,
            serviceID: 1024,
            eventID: 10001,
            title: "ニュース7",
            description: "今日のニュース",
            startTime: "2026-11-03T23:40:00+09:00",
            endTime: nil,
            duration: nil,
            captionText: captionText,
            isCaptionComposited: true,
            isCommentComposited: false
        )
    }

    func testSegmentCarriesTheJSONInXPComment() throws {
        let metadata = sampleMetadata()
        let segment = JPEGExif.segment(
            metadata: metadata,
            capturedAt: date("2026-11-04T00:36:57+09:00"),
            software: JPEGExif.softwareName(version: "1.0.0")
        )
        XCTAssertEqual(segment[segment.startIndex], 0xFF)
        XCTAssertEqual(segment[segment.startIndex + 1], 0xE1)
        let declared = Int(segment[segment.startIndex + 2]) << 8
            | Int(segment[segment.startIndex + 3])
        XCTAssertEqual(declared, segment.count - 2)

        let jpeg = try JPEGExif.insert(segment, into: makeJPEG())
        let tiff = try XCTUnwrap(TestTIFF(jpeg: jpeg))
        let ifd0 = try XCTUnwrap(tiff.firstIFDOffset)

        let comment = try XCTUnwrap(tiff.entry(JPEGExif.Tag.xpComment, in: ifd0))
        XCTAssertEqual(comment.type, 1, "XPComment must be a BYTE entry")
        let json = try XCTUnwrap(tiff.utf16String(comment))
        let decoded = try JSONCoding.decode([String: JSONValue].self, from: json)
        XCTAssertEqual(Set(decoded.keys), CaptureExifMetadata.jsonKeys)
        XCTAssertEqual(decoded["title"]?.stringValue, "ニュース7")
        XCTAssertEqual(decoded["network_id"]?.intValue, 32736)
        XCTAssertEqual(decoded["captured_playback_position"]?.numberValue, 2217.0)
        XCTAssertEqual(decoded["captured_at"]?.stringValue, "2026-11-04T00:36:57+09:00")
        XCTAssertEqual(decoded["is_caption_composited"]?.boolValue, true)
        XCTAssertEqual(decoded["is_comment_composited"]?.boolValue, false)
        XCTAssertTrue(decoded["end_time"]?.isNull ?? false)
        XCTAssertTrue(decoded["duration"]?.isNull ?? false)

        // Exif IFD
        let exifPointer = try XCTUnwrap(tiff.entry(JPEGExif.Tag.exifIFDPointer, in: ifd0))
        let exifOffset = Int(try XCTUnwrap(exifPointer.bytes.first))
        XCTAssertEqual(exifOffset, 110)

        let original = try XCTUnwrap(tiff.entry(JPEGExif.ExifTag.dateTimeOriginal, in: exifOffset))
        XCTAssertEqual(tiff.asciiString(original), "2026:11:04 00:36:57")
        let digitized = try XCTUnwrap(tiff.entry(JPEGExif.ExifTag.dateTimeDigitized, in: exifOffset))
        XCTAssertEqual(tiff.asciiString(digitized), "2026:11:04 00:36:57")
        let version = try XCTUnwrap(tiff.entry(JPEGExif.ExifTag.exifVersion, in: exifOffset))
        XCTAssertEqual(tiff.asciiString(version), "0230")
        let colorSpace = try XCTUnwrap(tiff.entry(JPEGExif.ExifTag.colorSpace, in: exifOffset))
        XCTAssertEqual(colorSpace.bytes, Data([0x01, 0x00]))

        let dateTime = try XCTUnwrap(tiff.entry(JPEGExif.Tag.dateTime, in: ifd0))
        XCTAssertEqual(tiff.asciiString(dateTime), "2026:11:04 00:36:57")
        let software = try XCTUnwrap(tiff.entry(JPEGExif.Tag.software, in: ifd0))
        XCTAssertEqual(tiff.asciiString(software), "KonomiTV iOS 1.0.0")

        // Tags must be ascending for readers that binary search.
        let tags = try XCTUnwrap(tiff.entries(at: ifd0)).map { $0.tag }
        XCTAssertEqual(tags, tags.sorted())
    }

    func testNullCaptionTextIsWrittenExplicitly() throws {
        let metadata = sampleMetadata(captionText: nil)
        let json = String(decoding: metadata.jsonData(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"caption_text\":null"), json)
        let decoded = try JSONCoding.decode([String: JSONValue].self, from: metadata.jsonData())
        XCTAssertTrue(decoded["caption_text"]?.isNull ?? false)
    }

    func testInsertKeepsJFIFInFrontAndReplacesOldExif() throws {
        let metadata = sampleMetadata()
        let first = JPEGExif.segment(
            metadata: metadata,
            capturedAt: date("2026-11-03T20:00:00+09:00"),
            software: "KonomiTV iOS 1.0.0"
        )
        let once = try JPEGExif.insert(first, into: makeJPEG())
        XCTAssertEqual(once[once.startIndex + 2], 0xFF)
        XCTAssertEqual(once[once.startIndex + 3], 0xE0, "JFIF APP0 must stay first")

        // A second insert replaces the first Exif segment instead of stacking.
        let second = JPEGExif.segment(
            metadata: metadata,
            capturedAt: date("2026-11-04T00:36:57+09:00"),
            software: "KonomiTV iOS 1.0.0"
        )
        let twice = try JPEGExif.insert(second, into: once)
        XCTAssertEqual(twice.count, once.count)
        let tiff = try XCTUnwrap(TestTIFF(jpeg: twice))
        let ifd0 = try XCTUnwrap(tiff.firstIFDOffset)
        let exifPointer = try XCTUnwrap(tiff.entry(JPEGExif.Tag.exifIFDPointer, in: ifd0))
        let exifOffset = Int(try XCTUnwrap(exifPointer.bytes.first))
        let original = try XCTUnwrap(tiff.entry(JPEGExif.ExifTag.dateTimeOriginal, in: exifOffset))
        XCTAssertEqual(tiff.asciiString(original), "2026:11:04 00:36:57")

        // The image data after the header is untouched.
        XCTAssertEqual(twice.suffix(6), Data([0x12, 0x34, 0x56, 0x78, 0xFF, 0xD9]))
    }

    func testInsertWithoutAPP0AndTruncatedInput() throws {
        let segment = JPEGExif.segment(
            metadata: sampleMetadata(),
            capturedAt: date("2026-11-04T00:36:57+09:00"),
            software: "KonomiTV iOS 1.0.0"
        )
        let jpeg = try JPEGExif.insert(segment, into: makeJPEG(app0: false))
        XCTAssertEqual(jpeg[jpeg.startIndex + 2], 0xFF)
        XCTAssertEqual(jpeg[jpeg.startIndex + 3], 0xE1)
        XCTAssertNotNil(TestTIFF(jpeg: jpeg))

        XCTAssertThrowsError(try JPEGExif.insert(segment, into: Data("not a jpeg".utf8))) { error in
            XCTAssertEqual(error as? JPEGExif.Error, .notJPEG)
        }
        XCTAssertThrowsError(try JPEGExif.insert(segment, into: Data([0xFF, 0xD8, 0xFF, 0xE1, 0x10]))) { error in
            XCTAssertEqual(error as? JPEGExif.Error, .truncated)
        }
    }

    func testJSONKeysMatchWebInterface() throws {
        let metadata = sampleMetadata()
        let decoded = try JSONCoding.decode([String: JSONValue].self, from: metadata.jsonData())
        // ICaptureExifData in client/src/workers/CaptureCompositor.ts
        XCTAssertEqual(
            Set(decoded.keys),
            [
                "captured_at",
                "captured_playback_position",
                "network_id",
                "service_id",
                "event_id",
                "title",
                "description",
                "start_time",
                "end_time",
                "duration",
                "caption_text",
                "is_caption_composited",
                "is_comment_composited",
            ]
        )
    }

    func testLiveBuilderAppliesTheWebClientFallbacks() throws {
        let program = Program(
            id: "NID32736-SID1024-EID10001",
            channelID: "NID32736-SID1024",
            networkID: 32736,
            serviceID: 1024,
            eventID: 10001,
            title: "ニュース7",
            description: "今日のニュース",
            startTime: date("2026-11-03T19:00:00+09:00"),
            endTime: date("2026-11-03T19:30:00+09:00"),
            duration: 1800
        )
        let channel = LiveChannel(id: "gr011", networkID: 32736, serviceID: 1024)

        let metadata = CaptureExifMetadata.live(
            channel: channel,
            program: program,
            capturedAt: date("2026-11-03T19:10:00+09:00"),
            captionText: "今日のニュースです"
        )
        XCTAssertEqual(metadata.eventID, 10001)
        XCTAssertEqual(metadata.title, "ニュース7")
        XCTAssertEqual(metadata.startTime, "2026-11-03T19:00:00+09:00")
        XCTAssertEqual(metadata.endTime, "2026-11-03T19:30:00+09:00")
        XCTAssertEqual(metadata.duration ?? -1, 1800, accuracy: 0.001)
        XCTAssertEqual(metadata.capturedPlaybackPosition, 600, accuracy: 0.001)
        XCTAssertEqual(metadata.captionText, "今日のニュースです")
        XCTAssertFalse(metadata.isCaptionComposited)

        // Off air: no EPG entry.
        let offAir = CaptureExifMetadata.live(
            channel: channel,
            program: nil,
            capturedAt: date("2026-11-03T19:10:00+09:00"),
            captionText: nil
        )
        XCTAssertEqual(offAir.eventID, -1)
        XCTAssertEqual(offAir.title, "放送休止")
        XCTAssertEqual(offAir.description, "")
        XCTAssertEqual(offAir.startTime, "2000-01-01T00:00:00+09:00")
        XCTAssertEqual(offAir.endTime, "2000-01-01T00:00:00+09:00")
        XCTAssertEqual(offAir.duration, 0)
        XCTAssertNil(offAir.captionText)

        // A program whose end is undecided reports duration Infinity.
        let undecided = Program(
            id: "undecided",
            networkID: 32736,
            serviceID: 1024,
            eventID: 10002,
            title: "放送時間未定",
            startTime: date("2026-11-03T19:00:00+09:00"),
            endTime: date("2026-11-03T19:00:00+09:00"),
            duration: .infinity
        )
        let metadata2 = CaptureExifMetadata.live(
            channel: channel,
            program: undecided,
            capturedAt: date("2026-11-03T19:10:00+09:00"),
            captionText: nil
        )
        XCTAssertNil(metadata2.endTime)
        XCTAssertNil(metadata2.duration)
    }

    func testVideoBuilderUsesTheRecordingStartOffset() throws {
        let program = RecordedProgram(
            id: 7,
            title: "ニュース7",
            description: "今日のニュース",
            startTime: date("2026-11-03T19:00:00+09:00"),
            endTime: date("2026-11-03T19:30:00+09:00"),
            duration: 1800,
            recordedVideo: RecordedVideo(
                recordingStartTime: date("2026-11-03T18:58:00+09:00"),
                recordingEndTime: date("2026-11-03T19:30:00+09:00")
            ),
            networkID: 32736,
            serviceID: 1024,
            eventID: 10001,
            recordingStartMargin: 0
        )
        // The file starts 120 s before the program, so a player position of
        // 300 s is 180 s after the program start.
        let metadata = CaptureExifMetadata.video(
            program: program,
            position: 300,
            capturedAt: date("2026-11-03T19:07:00+09:00"),
            captionText: nil
        )
        XCTAssertEqual(metadata.capturedPlaybackPosition, 180, accuracy: 0.001)
        XCTAssertEqual(metadata.startTime, "2026-11-03T19:00:00+09:00")
        XCTAssertEqual(metadata.endTime, "2026-11-03T19:30:00+09:00")
        XCTAssertEqual(metadata.duration ?? -1, 1800, accuracy: 0.001)
        XCTAssertEqual(metadata.eventID, 10001)

        // Without a recording start time the margin is used instead.
        let margined = RecordedProgram(
            id: 8,
            title: "ニュース7",
            description: "",
            startTime: date("2026-11-03T19:00:00+09:00"),
            endTime: date("2026-11-03T19:30:00+09:00"),
            duration: 1800,
            networkID: 32736,
            serviceID: 1024,
            eventID: 10001,
            recordingStartMargin: 15
        )
        let marginedMetadata = CaptureExifMetadata.video(
            program: margined,
            position: 60,
            capturedAt: date("2026-11-03T19:07:00+09:00"),
            captionText: nil
        )
        XCTAssertEqual(marginedMetadata.capturedPlaybackPosition, 45, accuracy: 0.001)

        // A program without an event ID (a "番組情報なし" recording).
        let unknown = RecordedProgram(
            id: 9,
            title: "録画",
            startTime: date("2026-11-03T19:00:00+09:00"),
            endTime: date("2026-11-03T19:30:00+09:00"),
            duration: 1800
        )
        let unknownMetadata = CaptureExifMetadata.video(
            program: unknown,
            position: 0,
            capturedAt: date("2026-11-03T19:07:00+09:00"),
            captionText: nil
        )
        XCTAssertEqual(unknownMetadata.networkID, -1)
        XCTAssertEqual(unknownMetadata.serviceID, -1)
        XCTAssertEqual(unknownMetadata.eventID, -1)
    }
}
