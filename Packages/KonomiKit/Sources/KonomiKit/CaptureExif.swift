import Foundation

// MARK: - Metadata

/// The program metadata the web client writes into a capture's EXIF
/// (ICaptureExifData in CaptureCompositor.ts).
///
/// The server links a capture to its program ONLY through this JSON, stored in
/// EXIF IFD0 tag 40092 (XPComment) as UTF-16LE bytes with a NUL terminator, so
/// the key names and the presence of the nullable keys matter.
public struct CaptureExifMetadata: Codable, Sendable, Equatable {
    /// Capture time, ISO 8601 with offset in JST (2026-11-04T00:36:57+09:00).
    public var capturedAt: String
    /// Seconds from the start of the program (live) or of the recording
    /// (video), i.e. the playback position the capture was taken at.
    public var capturedPlaybackPosition: Double
    public var networkID: Int
    public var serviceID: Int
    /// -1 when the capture has no program.
    public var eventID: Int
    public var title: String
    public var description: String
    /// ISO 8601 with offset in JST.
    public var startTime: String
    /// null for a program whose end is unknown (放送時間未定).
    public var endTime: String?
    /// null for a program whose end is unknown (放送時間未定).
    public var duration: Double?
    /// The caption text shown when the capture was taken, whether or not the
    /// caption was composited into the image.
    public var captionText: String?
    public var isCaptionComposited: Bool
    public var isCommentComposited: Bool

    public init(
        capturedAt: String,
        capturedPlaybackPosition: Double = -1,
        networkID: Int = -1,
        serviceID: Int = -1,
        eventID: Int = -1,
        title: String = "",
        description: String = "",
        startTime: String = CaptureExifMetadata.fallbackStartTime,
        endTime: String? = nil,
        duration: Double? = nil,
        captionText: String? = nil,
        isCaptionComposited: Bool = false,
        isCommentComposited: Bool = false
    ) {
        self.capturedAt = capturedAt
        self.capturedPlaybackPosition = capturedPlaybackPosition
        self.networkID = networkID
        self.serviceID = serviceID
        self.eventID = eventID
        self.title = title
        self.description = description
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.captionText = captionText
        self.isCaptionComposited = isCaptionComposited
        self.isCommentComposited = isCommentComposited
    }

    /// The JSON keys of the web client's interface. The server rejects a
    /// capture whose metadata is missing one of the nullable keys, so the
    /// encoder always writes them (as null when empty).
    public static let jsonKeys: Set<String> = [
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

    private enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case capturedPlaybackPosition = "captured_playback_position"
        case networkID = "network_id"
        case serviceID = "service_id"
        case eventID = "event_id"
        case title
        case description
        case startTime = "start_time"
        case endTime = "end_time"
        case duration
        case captionText = "caption_text"
        case isCaptionComposited = "is_caption_composited"
        case isCommentComposited = "is_comment_composited"
    }

    /// Encodes every key, writing an explicit JSON null for the nullable ones
    /// (the server's model requires end_time / duration / caption_text).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(capturedPlaybackPosition, forKey: .capturedPlaybackPosition)
        try container.encode(networkID, forKey: .networkID)
        try container.encode(serviceID, forKey: .serviceID)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(startTime, forKey: .startTime)
        if let endTime {
            try container.encode(endTime, forKey: .endTime)
        } else {
            try container.encodeNil(forKey: .endTime)
        }
        if let duration, duration.isFinite {
            try container.encode(duration, forKey: .duration)
        } else {
            try container.encodeNil(forKey: .duration)
        }
        if let captionText {
            try container.encode(captionText, forKey: .captionText)
        } else {
            try container.encodeNil(forKey: .captionText)
        }
        try container.encode(isCaptionComposited, forKey: .isCaptionComposited)
        try container.encode(isCommentComposited, forKey: .isCommentComposited)
    }

    /// The JSON the server reads, serialised the same way the web client does.
    public func jsonData() -> Data {
        (try? JSONCoding.encode(self)) ?? Data()
    }

    // MARK: - Builders

    /// The web client's placeholder for a program-less capture.
    public static let fallbackStartTime = "2000-01-01T00:00:00+09:00"

    /// Metadata of a live capture (createCaptureExifData() in
    /// CaptureManager.ts).
    ///
    /// The program of the channel is optional: a channel that is off air has no
    /// EPG entry, and the web client then writes event_id -1 and 放送休止.
    public static func live(
        channel: LiveChannel,
        program: Program?,
        capturedAt: Date,
        captionText: String?
    ) -> CaptureExifMetadata {
        let startTime = program?.startTime ?? fallbackDate
        // A program whose end is unknown has duration Infinity and reuses its
        // start time as the end time, so both are written as null.
        var endTime: String? = iso8601(program?.endTime ?? fallbackDate)
        var duration: Double? = program?.duration ?? 0
        if duration?.isFinite == false {
            endTime = nil
            duration = nil
        }

        return CaptureExifMetadata(
            capturedAt: iso8601(capturedAt),
            capturedPlaybackPosition: finite(capturedAt.timeIntervalSince(startTime)),
            networkID: channel.networkID,
            serviceID: channel.serviceID,
            eventID: program?.eventID ?? -1,
            title: program?.title ?? "放送休止",
            description: program?.description ?? "",
            startTime: iso8601(startTime),
            endTime: endTime,
            duration: duration,
            captionText: captionText
        )
    }

    /// Metadata of a recorded video capture (createCaptureExifData() in
    /// CaptureManager.ts).
    ///
    /// - Parameter position: the player's current time in seconds. The stored
    ///   position is position minus the recording start offset, which makes it
    ///   comparable with a live capture's position.
    public static func video(
        program: RecordedProgram,
        position: Double,
        capturedAt: Date,
        captionText: String?
    ) -> CaptureExifMetadata {
        // The recording start margin is 0 when the recording started inside the
        // program, so the real offset is the difference to the file's start
        // time whenever that is known.
        var recordingStartOffset = program.recordingStartMargin
        if let recordingStartTime = program.recordedVideo.recordingStartTime {
            recordingStartOffset = program.startTime.timeIntervalSince(recordingStartTime)
        }
        let duration = program.duration
        return CaptureExifMetadata(
            capturedAt: iso8601(capturedAt),
            capturedPlaybackPosition: finite(position - recordingStartOffset),
            networkID: program.networkID ?? -1,
            serviceID: program.serviceID ?? -1,
            eventID: program.eventID ?? -1,
            title: program.title,
            description: program.description,
            startTime: iso8601(program.startTime),
            endTime: iso8601(program.endTime),
            duration: duration.isFinite ? duration : nil,
            captionText: captionText
        )
    }

    // MARK: - Formatting

    private static var fallbackDate: Date {
        parseISO8601(fallbackStartTime) ?? Date(timeIntervalSince1970: 0)
    }

    /// ISO 8601 with the offset, in JST: 2026-11-04T00:36:57+09:00.
    public static func iso8601(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    static func parseISO8601(_ string: String) -> Date? {
        isoFormatter.date(from: string)
    }

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = CaptureFilename.jst
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter
    }()

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

// MARK: - JPEG EXIF writing

/// Writes the EXIF APP1 segment ImageIO cannot write (XPComment) into a JPEG.
///
/// piexifjs does the same in CaptureCompositor.ts: build the TIFF block by hand
/// and splice it into the JPEG after the SOI (and the JFIF APP0 when present).
public enum JPEGExif {

    public enum Error: Swift.Error, Equatable {
        /// The data does not start with an SOI marker.
        case notJPEG
        /// A segment length runs past the end of the data.
        case truncated
    }

    /// EXIF tag numbers of IFD0.
    public enum Tag {
        public static let xResolution: UInt16 = 282
        public static let yResolution: UInt16 = 283
        public static let resolutionUnit: UInt16 = 296
        public static let software: UInt16 = 305
        public static let dateTime: UInt16 = 306
        public static let yCbCrPositioning: UInt16 = 531
        public static let exifIFDPointer: UInt16 = 34665
        public static let xpComment: UInt16 = 40092
    }

    /// EXIF tag numbers of the Exif IFD.
    public enum ExifTag {
        public static let exifVersion: UInt16 = 36864
        public static let dateTimeOriginal: UInt16 = 36867
        public static let dateTimeDigitized: UInt16 = 36868
        public static let componentsConfiguration: UInt16 = 37121
        public static let flashpixVersion: UInt16 = 40960
        public static let colorSpace: UInt16 = 40961
    }

    /// Which EXIF Software the client writes, e.g. "KonomiTV iOS 1.0.0".
    public static func softwareName(version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "KonomiTV iOS" : "KonomiTV iOS " + trimmed
    }

    // MARK: Segment

    /// Builds the APP1 segment (marker, length, Exif identifier, TIFF block)
    /// for the given metadata.
    public static func segment(
        metadata: CaptureExifMetadata,
        capturedAt: Date,
        software: String
    ) -> Data {
        let datetime = datetimeString(capturedAt)
        let datetimeBytes = ascii(datetime)
        let softwareBytes = ascii(software)
        let commentBytes = utf16le(metadata.jsonData())

        // IFD0 entries, ascending by tag (the TIFF specification requires it).
        var ifd0: [Entry] = [
            Entry(tag: Tag.xResolution, type: .rational, count: 1, payload: rational(72, 1)),
            Entry(tag: Tag.yResolution, type: .rational, count: 1, payload: rational(72, 1)),
            Entry(tag: Tag.resolutionUnit, type: .short, count: 1, payload: uint16(2)),
            Entry(tag: Tag.software, type: .ascii, count: UInt32(softwareBytes.count), payload: softwareBytes),
            Entry(tag: Tag.dateTime, type: .ascii, count: UInt32(datetimeBytes.count), payload: datetimeBytes),
            Entry(tag: Tag.yCbCrPositioning, type: .short, count: 1, payload: uint16(1)),
            Entry(tag: Tag.exifIFDPointer, type: .long, count: 1, payload: uint32(0)),
            Entry(tag: Tag.xpComment, type: .byte, count: UInt32(commentBytes.count), payload: commentBytes),
        ]
        ifd0.sort { $0.tag < $1.tag }

        var exif: [Entry] = [
            Entry(tag: ExifTag.exifVersion, type: .ascii, count: 4, payload: ascii("0230", terminate: false)),
            Entry(tag: ExifTag.dateTimeOriginal, type: .ascii, count: UInt32(datetimeBytes.count), payload: datetimeBytes),
            Entry(tag: ExifTag.dateTimeDigitized, type: .ascii, count: UInt32(datetimeBytes.count), payload: datetimeBytes),
            Entry(
                tag: ExifTag.componentsConfiguration,
                type: .undefined,
                count: 4,
                payload: Data([0x01, 0x02, 0x03, 0x00])
            ),
            Entry(tag: ExifTag.flashpixVersion, type: .undefined, count: 4, payload: Data("0100".utf8)),
            Entry(tag: ExifTag.colorSpace, type: .short, count: 1, payload: uint16(1)),
        ]
        exif.sort { $0.tag < $1.tag }

        // Fixed layout: header, IFD0, Exif IFD, then the values that do not fit
        // inline (word aligned).
        let headerSize = 8
        let ifd0Offset = headerSize
        let ifd0Size = 2 + ifd0.count * 12 + 4
        let exifOffset = ifd0Offset + ifd0Size
        let exifSize = 2 + exif.count * 12 + 4
        var valueOffset = exifOffset + exifSize

        func assignOffsets(_ entries: inout [Entry]) {
            for index in entries.indices where entries[index].payload.count > 4 {
                if valueOffset % 2 != 0 {
                    valueOffset += 1
                }
                entries[index].valueOffset = valueOffset
                valueOffset += entries[index].payload.count
            }
        }
        assignOffsets(&ifd0)
        assignOffsets(&exif)

        var tiff = Data(capacity: valueOffset - headerSize)
        tiff.append(contentsOf: [0x49, 0x49])          // "II": little endian
        tiff.append(uint16(42))                        // TIFF magic
        tiff.append(uint32(UInt32(ifd0Offset)))

        func appendIFD(_ entries: [Entry]) {
            let patched = entries.map { entry -> Entry in
                guard entry.tag == Tag.exifIFDPointer else { return entry }
                var copy = entry
                copy.payload = uint32(UInt32(exifOffset))
                return copy
            }
            tiff.append(uint16(UInt16(patched.count)))
            for entry in patched {
                tiff.append(uint16(entry.tag))
                tiff.append(uint16(entry.type.rawValue))
                tiff.append(uint32(entry.count))
                if entry.payload.count > 4 {
                    tiff.append(uint32(UInt32(entry.valueOffset)))
                } else {
                    // Short values are stored inline, left aligned.
                    var inline = entry.payload
                    inline.append(contentsOf: [UInt8](repeating: 0, count: 4 - inline.count))
                    tiff.append(inline)
                }
            }
            tiff.append(uint32(0))                     // no next IFD
        }
        appendIFD(ifd0)
        appendIFD(exif)

        for entry in (ifd0 + exif) where entry.payload.count > 4 {
            if tiff.count % 2 != 0 {
                tiff.append(0)
            }
            tiff.append(entry.payload)
        }

        var segment = Data(capacity: tiff.count + 10)
        segment.append(contentsOf: [0xFF, 0xE1])
        // JPEG segment lengths are big endian (the TIFF block is little endian).
        segment.append(uint16Big(UInt16(tiff.count + 8)))  // includes itself
        segment.append(contentsOf: [0x45, 0x78, 0x69, 0x66, 0x00, 0x00])  // "Exif" + NUL NUL
        segment.append(tiff)
        return segment
    }

    // MARK: Insert

    /// Splices the segment into a JPEG, replacing any existing Exif APP1
    /// segment. The new segment goes right after the SOI (and after a leading
    /// JFIF APP0, which some readers expect first).
    public static func insert(_ segment: Data, into jpeg: Data) throws -> Data {
        guard jpeg.count >= 4,
              jpeg[jpeg.startIndex] == 0xFF,
              jpeg[jpeg.startIndex + 1] == 0xD8 else {
            throw Error.notJPEG
        }
        let bytes = [UInt8](jpeg)

        // Collect the header segments (everything before SOS / EOI).
        var segments: [(marker: UInt8, range: Range<Int>)] = []
        var index = 2
        while index + 1 < bytes.count {
            guard bytes[index] == 0xFF else { break }
            let marker = bytes[index + 1]
            if marker == 0xFF {
                index += 1
                continue
            }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                index += 2
                continue
            }
            if marker == 0xDA || marker == 0xD9 {
                break
            }
            guard index + 3 < bytes.count else { throw Error.truncated }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2 else { throw Error.truncated }
            let end = index + 2 + length
            guard end <= bytes.count else { throw Error.truncated }
            segments.append((marker: marker, range: index..<end))
            index = end
        }
        let headerEnd = segments.last?.range.upperBound ?? 2

        let exifMagic: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
        func isExifSegment(_ segment: (marker: UInt8, range: Range<Int>)) -> Bool {
            guard segment.marker == 0xE1 else { return false }
            let start = segment.range.lowerBound + 4
            guard start + exifMagic.count <= bytes.count else { return false }
            return bytes[start..<(start + exifMagic.count)].elementsEqual(exifMagic)
        }

        var output = Data(capacity: jpeg.count + segment.count)
        output.append(contentsOf: [0xFF, 0xD8])

        var remaining = segments
        // JFIF APP0 stays in front of the Exif segment.
        if let first = remaining.first, first.marker == 0xE0 {
            output.append(contentsOf: bytes[first.range])
            remaining.removeFirst()
        }
        output.append(segment)
        for item in remaining where !isExifSegment(item) {
            output.append(contentsOf: bytes[item.range])
        }
        output.append(contentsOf: bytes[headerEnd...])
        return output
    }

    // MARK: Helpers

    private enum TIFFType: UInt16 {
        case byte = 1
        case ascii = 2
        case short = 3
        case long = 4
        case rational = 5
        case undefined = 7
    }

    private struct Entry {
        let tag: UInt16
        let type: TIFFType
        let count: UInt32
        var payload: Data
        var valueOffset = 0
    }

    /// YYYY:MM:DD HH:mm:ss in JST, the EXIF datetime format.
    static func datetimeString(_ date: Date) -> String {
        datetimeFormatter.string(from: date)
    }

    private static let datetimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = CaptureFilename.jst
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static func ascii(_ string: String, terminate: Bool = true) -> Data {
        var data = Data(string.utf8)
        if terminate {
            data.append(0)
        }
        return data
    }

    /// UTF-16LE code units of the JSON plus a UTF-16 NUL terminator, which is
    /// what the server decodes (bytes(40092).decode('utf-16-le')).
    private static func utf16le(_ data: Data) -> Data {
        let string = String(decoding: data, as: UTF8.self)
        var output = Data(capacity: string.utf16.count * 2 + 2)
        for unit in string.utf16 {
            output.append(UInt8(unit & 0xFF))
            output.append(UInt8(unit >> 8))
        }
        output.append(contentsOf: [0x00, 0x00])
        return output
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func uint16Big(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    private static func rational(_ numerator: UInt32, _ denominator: UInt32) -> Data {
        uint32(numerator) + uint32(denominator)
    }
}
