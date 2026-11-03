import Foundation

public enum VideoCodec: String, Sendable, Hashable {
    case h264
    case h265

    public init?(streamType: UInt8) {
        switch streamType {
        case 0x1B:
            self = .h264
        case 0x24:
            self = .h265
        default:
            return nil
        }
    }

    public var streamType: UInt8 {
        switch self {
        case .h264: return 0x1B
        case .h265: return 0x24
        }
    }
}

/// 33-bit MPEG presentation timestamps at a 90 kHz clock.
public enum PTS {
    public static let modulus: Int64 = 1 << 33
    public static let clockRate: Double = 90_000

    /// Decodes the 5-byte PTS field starting at `offset`.
    public static func decode(_ bytes: [UInt8], offset: Int = 0) -> Int64? {
        guard bytes.count >= offset + 5 else { return nil }
        let b0 = Int64(bytes[offset])
        let b1 = Int64(bytes[offset + 1])
        let b2 = Int64(bytes[offset + 2])
        let b3 = Int64(bytes[offset + 3])
        let b4 = Int64(bytes[offset + 4])
        return ((b0 >> 1) & 0x07) << 30
            | (b1 << 22)
            | ((b2 >> 1) & 0x7F) << 15
            | (b3 << 7)
            | ((b4 >> 1) & 0x7F)
    }

    public static func seconds(_ ticks: Int64) -> Double {
        Double(ticks) / clockRate
    }
}

/// Unwraps the 33-bit PTS counter into a monotonically increasing timeline.
/// Stream restarts that move the timestamp backwards within half the counter
/// range are reported as-is so the segmenter can flag a discontinuity.
public struct PTSUnwrapper: Sendable {
    private var last: Int64?
    private var offset: Int64 = 0

    public init() {}

    public mutating func unwrap(_ raw: Int64) -> Int64 {
        var normalized = raw % PTS.modulus
        if normalized < 0 {
            normalized += PTS.modulus
        }

        guard let last else {
            self.last = normalized
            return normalized
        }

        var candidate = normalized + offset
        if candidate < last - (PTS.modulus / 2) {
            offset += PTS.modulus
            candidate = normalized + offset
        } else if candidate > last + (PTS.modulus / 2) {
            offset -= PTS.modulus
            candidate = normalized + offset
        }

        self.last = candidate
        return candidate
    }

    public mutating func reset() {
        last = nil
        offset = 0
    }
}

/// A packetized elementary stream, parsed from the first TS packet of a PES.
public struct PESPacket: Sendable, Hashable {
    public let streamID: UInt8
    public let packetLength: Int
    public let pts: Int64?
    public let dts: Int64?
    public let payload: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 6,
              bytes[0] == 0x00,
              bytes[1] == 0x00,
              bytes[2] == 0x01 else {
            return nil
        }

        streamID = bytes[3]
        packetLength = (Int(bytes[4]) << 8) | Int(bytes[5])

        // Streams without the optional PES header.
        let hasOptionalHeader = !Self.streamIDsWithoutOptionalHeader.contains(streamID)
        guard hasOptionalHeader else {
            payload = Array(bytes[6...])
            pts = nil
            dts = nil
            return
        }

        guard bytes.count >= 9 else { return nil }
        let flags = bytes[7]
        let headerLength = Int(bytes[8])
        let payloadStart = 9 + headerLength
        guard payloadStart <= bytes.count else { return nil }

        let ptsDTSFlags = (flags >> 6) & 0x03
        if ptsDTSFlags == 2 || ptsDTSFlags == 3 {
            pts = PTS.decode(bytes, offset: 9)
        } else {
            pts = nil
        }
        if ptsDTSFlags == 3 {
            dts = PTS.decode(bytes, offset: 14)
        } else {
            dts = nil
        }
        payload = payloadStart < bytes.count ? Array(bytes[payloadStart...]) : []
    }

    public init?(data: Data) {
        self.init(bytes: Array(data))
    }

    /// Presentation timestamp in seconds.
    public var ptsSeconds: Double? {
        pts.map(PTS.seconds)
    }

    private static let streamIDsWithoutOptionalHeader: Set<UInt8> = [
        0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xF2, 0xF8, 0xFF,
    ]
}

/// Detects random-access pictures by scanning PES payloads for H.264 IDR or
/// H.265 IRAP NAL units.
public enum KeyframeDetector {

    public static func isKeyframe(pesPayload: [UInt8], codec: VideoCodec) -> Bool {
        switch codec {
        case .h264:
            return containsH264IDR(pesPayload)
        case .h265:
            return containsH265IRAP(pesPayload)
        }
    }

    public static func containsH264IDR(_ bytes: [UInt8]) -> Bool {
        // IDR (5) or SPS (7): the first TS packet of a long access unit may end
        // inside a large SEI before the IDR slice starts, but SPS precedes it.
        containsNALUnit(bytes) { header in
            let type = header & 0x1F
            return type == 5 || type == 7
        }
    }

    public static func containsH265IRAP(_ bytes: [UInt8]) -> Bool {
        containsNALUnit(bytes) { header in
            let type = (header >> 1) & 0x3F
            // IRAP slices (16–21), or VPS (32) / SPS (33) that precede them.
            return (16...21).contains(type) || type == 32 || type == 33
        }
    }

    private static func containsNALUnit(
        _ bytes: [UInt8],
        predicate: (UInt8) -> Bool
    ) -> Bool {
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    if predicate(bytes[index + 3]) {
                        return true
                    }
                    index += 3
                    continue
                }
                if bytes[index + 2] == 0, index + 4 < bytes.count, bytes[index + 3] == 1 {
                    if predicate(bytes[index + 4]) {
                        return true
                    }
                    index += 4
                    continue
                }
            }
            index += 1
        }
        return false
    }
}
