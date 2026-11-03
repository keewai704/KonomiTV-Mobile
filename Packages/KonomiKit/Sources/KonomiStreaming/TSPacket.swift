import Foundation

/// A single 188-byte MPEG transport-stream packet.
public struct TSPacket: Sendable, Hashable {
    public static let packetSize = 188
    public static let syncByte: UInt8 = 0x47

    /// Raw packet bytes including the 0x47 sync byte.
    public let bytes: [UInt8]
    public let pid: Int
    public let payloadUnitStartIndicator: Bool
    public let transportErrorIndicator: Bool
    public let adaptationFieldControl: UInt8
    public let continuityCounter: Int
    public let adaptationField: [UInt8]
    public let payload: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.packetSize, bytes[0] == Self.syncByte else {
            return nil
        }

        let second = bytes[1]
        transportErrorIndicator = (second & 0x80) != 0
        payloadUnitStartIndicator = (second & 0x40) != 0
        pid = (Int(second & 0x1F) << 8) | Int(bytes[2])

        let fourth = bytes[3]
        adaptationFieldControl = (fourth >> 4) & 0x03
        continuityCounter = Int(fourth & 0x0F)

        var payloadStart = 4
        var adaptation: [UInt8] = []
        if adaptationFieldControl == 2 || adaptationFieldControl == 3 {
            let length = Int(bytes[4])
            guard 5 + length <= Self.packetSize else { return nil }
            adaptation = Array(bytes[5..<(5 + length)])
            payloadStart = 5 + length
        }

        adaptationField = adaptation
        if (adaptationFieldControl == 1 || adaptationFieldControl == 3),
           payloadStart < Self.packetSize {
            payload = Array(bytes[payloadStart..<Self.packetSize])
        } else {
            payload = []
        }

        self.bytes = bytes
    }

    public init?(data: Data) {
        self.init(bytes: Array(data))
    }

    public var data: Data {
        Data(bytes)
    }

    /// True when the adaptation field's random-access indicator is set.
    public var randomAccessIndicator: Bool {
        guard let first = adaptationField.first else { return false }
        return (first & 0x40) != 0
    }

    public var hasAdaptationField: Bool {
        adaptationFieldControl == 2 || adaptationFieldControl == 3
    }

    public var hasPayload: Bool {
        adaptationFieldControl == 1 || adaptationFieldControl == 3
    }
}

/// Reassembles 188-byte packets from arbitrary chunks, resynchronising on the
/// 0x47 sync byte when garbage or a partial packet is encountered.
public struct TSPacketizer: Sendable {
    private var buffer: [UInt8] = []
    /// True when the first byte of `buffer` is known to be a packet boundary.
    private var aligned = false

    public init() {}

    public var bufferedByteCount: Int {
        buffer.count
    }

    public mutating func append(_ data: Data) -> [TSPacket] {
        append(Array(data))
    }

    public mutating func append(_ bytes: [UInt8]) -> [TSPacket] {
        buffer.append(contentsOf: bytes)
        var packets: [TSPacket] = []
        var index = 0

        while buffer.count - index >= TSPacket.packetSize {
            guard buffer[index] == TSPacket.syncByte else {
                index += 1
                aligned = false
                continue
            }

            // Verify alignment with the following packet when possible. A
            // candidate at the very start of the stream (or directly after
            // skipped garbage) must be confirmed by a second sync byte. Once
            // a packet has been accepted, a lone trailing packet is trusted.
            let secondPacketStart = index + TSPacket.packetSize
            if buffer.count - secondPacketStart >= TSPacket.packetSize {
                if buffer[secondPacketStart] != TSPacket.syncByte {
                    index += 1
                    aligned = false
                    continue
                }
            } else if !aligned {
                break
            }

            let slice = Array(buffer[index..<(index + TSPacket.packetSize)])
            if let packet = TSPacket(bytes: slice) {
                packets.append(packet)
                index += TSPacket.packetSize
                aligned = true
            } else {
                index += 1
                aligned = false
            }
        }

        if index > 0 {
            buffer.removeFirst(index)
        }
        return packets
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}
