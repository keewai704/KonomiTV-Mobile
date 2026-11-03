import Foundation

/// Extracts one complete PSI section from a transport-stream payload.
public enum PSIParser {
    /// Handles the `pointer_field` that precedes a section when the packet's
    /// payload-unit-start indicator is set.
    public static func section(from payload: [UInt8]) -> [UInt8]? {
        guard payload.count >= 4 else { return nil }
        let pointer = Int(payload[0])
        let start = pointer + 1
        guard start + 3 <= payload.count else { return nil }
        let sectionLength = (Int(payload[start + 1] & 0x0F) << 8) | Int(payload[start + 2])
        let total = 3 + sectionLength
        guard total >= 8, start + total <= payload.count else { return nil }
        return Array(payload[start..<(start + total)])
    }

    public static func section(from packet: TSPacket) -> [UInt8]? {
        section(from: packet.payload)
    }
}

/// CRC-32/MPEG-2, the checksum used by PSI sections (no reflection, init and
/// final XOR all ones).
public enum MPEG2CRC {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index) << 24
        for _ in 0..<8 {
            crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
        }
        return crc
    }

    public static func compute(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let index = Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)
            crc = (crc << 8) ^ table[index]
        }
        return crc
    }

    /// Appends the CRC of `section` (which must not contain one yet).
    public static func appending(to section: [UInt8]) -> [UInt8] {
        let crc = compute(section)
        return section + [
            UInt8((crc >> 24) & 0xFF),
            UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 8) & 0xFF),
            UInt8(crc & 0xFF),
        ]
    }

    /// True when the last four bytes of `section` are its valid CRC.
    public static func isValid(_ section: [UInt8]) -> Bool {
        guard section.count >= 4 else { return false }
        let body = Array(section[0..<(section.count - 4)])
        let expected = compute(body)
        let stored = (UInt32(section[section.count - 4]) << 24)
            | (UInt32(section[section.count - 3]) << 16)
            | (UInt32(section[section.count - 2]) << 8)
            | UInt32(section[section.count - 1])
        return expected == stored
    }
}

/// Program Association Table: maps program numbers to PMT PIDs.
public struct PAT: Sendable, Hashable {
    public static let tableID: UInt8 = 0x00

    public let transportStreamID: Int
    /// Program number -> PMT PID.
    public let programs: [Int: Int]

    public init?(section bytes: [UInt8]) {
        guard bytes.count >= 12, bytes[0] == Self.tableID else { return nil }
        let sectionLength = (Int(bytes[1] & 0x0F) << 8) | Int(bytes[2])
        let sectionEnd = min(3 + sectionLength, bytes.count)
        let entriesEnd = sectionEnd - 4
        guard entriesEnd >= 8 else { return nil }

        transportStreamID = (Int(bytes[3]) << 8) | Int(bytes[4])
        var programs: [Int: Int] = [:]
        var offset = 8
        while offset + 4 <= entriesEnd {
            let programNumber = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            let pid = (Int(bytes[offset + 2] & 0x1F) << 8) | Int(bytes[offset + 3])
            if programNumber != 0 {
                programs[programNumber] = pid
            }
            offset += 4
        }
        self.programs = programs
    }

    public init?(payload: [UInt8]) {
        guard let section = PSIParser.section(from: payload) else { return nil }
        self.init(section: section)
    }

    /// First PMT PID in program-number order.
    public var pmtPID: Int? {
        programs.keys.sorted().compactMap { programs[$0] }.first
    }
}

/// Program Map Table: identifies the elementary streams of one program.
public struct PMT: Sendable, Hashable {
    public static let tableID: UInt8 = 0x02

    /// Elementary stream types that carry audio.
    ///
    /// 0x0F = AAC ADTS, 0x11 = AAC LATM, 0x03 / 0x04 = MPEG-1/2 audio.
    public static let audioStreamTypes: Set<UInt8> = [0x0F, 0x11, 0x03, 0x04]

    public struct Stream: Sendable, Hashable {
        public let streamType: UInt8
        public let elementaryPID: Int
        public let language: String?
        /// Raw descriptor bytes of this stream, kept so the PMT can be rebuilt.
        public let descriptors: [UInt8]
        /// `stream_identifier_descriptor` (tag 0x52) component tag, if present.
        public let componentTag: Int?
        /// `data_component_descriptor` (tag 0xFD) data_component_id, if present.
        public let dataComponentID: UInt16?

        public init(
            streamType: UInt8,
            elementaryPID: Int,
            language: String? = nil,
            descriptors: [UInt8] = [],
            componentTag: Int? = nil,
            dataComponentID: UInt16? = nil
        ) {
            self.streamType = streamType
            self.elementaryPID = elementaryPID
            self.language = language
            self.descriptors = descriptors
            self.componentTag = componentTag
            self.dataComponentID = dataComponentID
        }

        public var isAudio: Bool {
            PMT.audioStreamTypes.contains(streamType)
        }

        /// True for an ARIB 字幕 (caption) elementary stream.
        ///
        /// ARIB STD-B10 assigns component tags 0x30–0x37 to captions and
        /// 0x38–0x3F to 文字スーパー (superimpose) in the
        /// `stream_identifier_descriptor`. Streams that only carry a
        /// `data_component_descriptor` with data_component_id 0x0008 are
        /// treated as captions.
        public var isCaption: Bool {
            guard streamType == 0x06 else { return false }
            if let componentTag {
                return (0x30...0x37).contains(componentTag)
            }
            return dataComponentID == 0x0008
        }

        /// True for an ARIB 文字スーパー (superimpose) elementary stream.
        public var isSuperimpose: Bool {
            guard streamType == 0x06, let componentTag else { return false }
            return (0x38...0x3F).contains(componentTag)
        }
    }

    public let programNumber: Int
    public let pcrPID: Int
    public let versionNumber: Int
    /// Program-level descriptor bytes (after `program_info_length`).
    public let programInfo: [UInt8]
    public let streams: [Stream]

    public init?(section bytes: [UInt8]) {
        guard bytes.count >= 16, bytes[0] == Self.tableID else { return nil }
        let sectionLength = (Int(bytes[1] & 0x0F) << 8) | Int(bytes[2])
        let sectionEnd = min(3 + sectionLength, bytes.count)
        let streamsEnd = sectionEnd - 4
        guard streamsEnd >= 12 else { return nil }

        programNumber = (Int(bytes[3]) << 8) | Int(bytes[4])
        versionNumber = Int((bytes[5] >> 1) & 0x1F)
        pcrPID = (Int(bytes[8] & 0x1F) << 8) | Int(bytes[9])
        let programInfoLength = (Int(bytes[10] & 0x0F) << 8) | Int(bytes[11])
        let programInfoStart = 12
        let programInfoEnd = min(programInfoStart + programInfoLength, streamsEnd)
        programInfo = programInfoEnd > programInfoStart
            ? Array(bytes[programInfoStart..<programInfoEnd])
            : []
        var offset = programInfoStart + programInfoLength

        var streams: [Stream] = []
        while offset + 5 <= streamsEnd {
            let streamType = bytes[offset]
            let pid = (Int(bytes[offset + 1] & 0x1F) << 8) | Int(bytes[offset + 2])
            let esInfoLength = (Int(bytes[offset + 3] & 0x0F) << 8) | Int(bytes[offset + 4])
            let descriptorStart = offset + 5
            let descriptorEnd = min(descriptorStart + esInfoLength, streamsEnd)
            let descriptors = descriptorEnd > descriptorStart
                ? Array(bytes[descriptorStart..<descriptorEnd])
                : []
            let language = Self.languageDescriptor(
                bytes: bytes,
                start: descriptorStart,
                end: descriptorEnd
            )
            let component = Self.componentInfo(
                bytes: bytes,
                start: descriptorStart,
                end: descriptorEnd
            )
            streams.append(
                Stream(
                    streamType: streamType,
                    elementaryPID: pid,
                    language: language,
                    descriptors: descriptors,
                    componentTag: component.componentTag,
                    dataComponentID: component.dataComponentID
                )
            )
            offset = descriptorStart + esInfoLength
        }
        self.streams = streams
    }

    public init?(payload: [UInt8]) {
        guard let section = PSIParser.section(from: payload) else { return nil }
        self.init(section: section)
    }

    public var videoStream: Stream? {
        streams.first { $0.streamType == 0x1B || $0.streamType == 0x24 }
    }

    /// First audio stream in PMT order (the main audio).
    public var audioStream: Stream? {
        audioStreams.first
    }

    /// Every audio stream in PMT order: main audio first, secondary audio second.
    public var audioStreams: [Stream] {
        streams.filter(\.isAudio)
    }

    public var audioPIDs: [Int] {
        audioStreams.map(\.elementaryPID)
    }

    public var primaryAudioPID: Int? {
        audioPIDs.first
    }

    public var secondaryAudioPID: Int? {
        audioPIDs.count >= 2 ? audioPIDs[1] : nil
    }

    /// True when the program carries a second audio elementary stream.
    public var hasSecondaryAudio: Bool {
        audioPIDs.count >= 2
    }

    /// PID of the ARIB caption (字幕) elementary stream, if the program has one.
    public var captionPID: Int? {
        streams.first(where: \.isCaption)?.elementaryPID
    }

    /// PID of the ARIB superimpose (文字スーパー) elementary stream, if any.
    public var superimposePID: Int? {
        streams.first(where: \.isSuperimpose)?.elementaryPID
    }

    public var captionStream: Stream? {
        streams.first(where: \.isCaption)
    }

    public var superimposeStream: Stream? {
        streams.first(where: \.isSuperimpose)
    }

    public var videoPID: Int? {
        videoStream?.elementaryPID
    }

    public var audioPID: Int? {
        audioStream?.elementaryPID
    }

    public var videoCodec: VideoCodec? {
        videoStream.flatMap { VideoCodec(streamType: $0.streamType) }
    }

    /// Rebuilds the PMT section, keeping at most one audio stream.
    ///
    /// `keepingAudioPID` selects which audio elementary stream survives; nil
    /// keeps every stream. Non-audio streams are always kept, and the section
    /// length and CRC-32/MPEG-2 are recomputed.
    public func section(keepingAudioPID audioPID: Int?) -> [UInt8] {
        var body: [UInt8] = [
            UInt8((programNumber >> 8) & 0xFF),
            UInt8(programNumber & 0xFF),
            0xC1 | UInt8((versionNumber & 0x1F) << 1),
            0x00, 0x00,
            0xE0 | UInt8((pcrPID >> 8) & 0x1F),
            UInt8(pcrPID & 0xFF),
            0xF0 | UInt8((programInfo.count >> 8) & 0x0F),
            UInt8(programInfo.count & 0xFF),
        ]
        body.append(contentsOf: programInfo)

        for stream in streams {
            if stream.isAudio, let audioPID, stream.elementaryPID != audioPID {
                continue
            }
            body.append(contentsOf: [
                stream.streamType,
                0xE0 | UInt8((stream.elementaryPID >> 8) & 0x1F),
                UInt8(stream.elementaryPID & 0xFF),
                0xF0 | UInt8((stream.descriptors.count >> 8) & 0x0F),
                UInt8(stream.descriptors.count & 0xFF),
            ])
            body.append(contentsOf: stream.descriptors)
        }

        let sectionLength = body.count + 4
        let header: [UInt8] = [
            Self.tableID,
            0xB0 | UInt8((sectionLength >> 8) & 0x0F),
            UInt8(sectionLength & 0xFF),
        ]
        return MPEG2CRC.appending(to: header + body)
    }

    private static func componentInfo(
        bytes: [UInt8],
        start: Int,
        end: Int
    ) -> (componentTag: Int?, dataComponentID: UInt16?) {
        var componentTag: Int?
        var dataComponentID: UInt16?
        var offset = start
        while offset + 2 <= end {
            let tag = bytes[offset]
            let length = Int(bytes[offset + 1])
            let payloadStart = offset + 2
            let payloadEnd = min(payloadStart + length, end)
            if tag == 0x52, payloadEnd - payloadStart >= 1 {
                componentTag = Int(bytes[payloadStart])
            } else if tag == 0xFD, payloadEnd - payloadStart >= 2 {
                dataComponentID = (UInt16(bytes[payloadStart]) << 8)
                    | UInt16(bytes[payloadStart + 1])
            }
            offset = payloadStart + length
        }
        return (componentTag, dataComponentID)
    }

    private static func languageDescriptor(bytes: [UInt8], start: Int, end: Int) -> String? {
        var offset = start
        while offset + 2 <= end {
            let tag = bytes[offset]
            let length = Int(bytes[offset + 1])
            let payloadStart = offset + 2
            let payloadEnd = min(payloadStart + length, end)
            if tag == 0x0A, payloadEnd - payloadStart >= 3 {
                let languageBytes = bytes[payloadStart..<(payloadStart + 3)]
                let language = String(bytes: languageBytes, encoding: .isoLatin1)
                if let language, !language.isEmpty {
                    return language
                }
            }
            offset = payloadStart + length
        }
        return nil
    }
}
