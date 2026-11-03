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

    public struct Stream: Sendable, Hashable {
        public let streamType: UInt8
        public let elementaryPID: Int
        public let language: String?

        public init(streamType: UInt8, elementaryPID: Int, language: String? = nil) {
            self.streamType = streamType
            self.elementaryPID = elementaryPID
            self.language = language
        }
    }

    public let programNumber: Int
    public let pcrPID: Int
    public let streams: [Stream]

    public init?(section bytes: [UInt8]) {
        guard bytes.count >= 16, bytes[0] == Self.tableID else { return nil }
        let sectionLength = (Int(bytes[1] & 0x0F) << 8) | Int(bytes[2])
        let sectionEnd = min(3 + sectionLength, bytes.count)
        let streamsEnd = sectionEnd - 4
        guard streamsEnd >= 12 else { return nil }

        programNumber = (Int(bytes[3]) << 8) | Int(bytes[4])
        pcrPID = (Int(bytes[8] & 0x1F) << 8) | Int(bytes[9])
        let programInfoLength = (Int(bytes[10] & 0x0F) << 8) | Int(bytes[11])
        var offset = 12 + programInfoLength

        var streams: [Stream] = []
        while offset + 5 <= streamsEnd {
            let streamType = bytes[offset]
            let pid = (Int(bytes[offset + 1] & 0x1F) << 8) | Int(bytes[offset + 2])
            let esInfoLength = (Int(bytes[offset + 3] & 0x0F) << 8) | Int(bytes[offset + 4])
            let descriptorStart = offset + 5
            let descriptorEnd = min(descriptorStart + esInfoLength, streamsEnd)
            let language = Self.languageDescriptor(
                bytes: bytes,
                start: descriptorStart,
                end: descriptorEnd
            )
            streams.append(Stream(streamType: streamType, elementaryPID: pid, language: language))
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

    public var audioStream: Stream? {
        streams.first { $0.streamType == 0x0F || $0.streamType == 0x11 }
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
