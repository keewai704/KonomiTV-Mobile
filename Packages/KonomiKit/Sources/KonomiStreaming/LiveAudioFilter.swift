import Foundation
import KonomiKit

/// Audio tracks found in a live program's PMT.
public struct LiveAudioTrackInfo: Sendable, Hashable {
    /// PID of the PMT that describes the program.
    public let pmtPID: Int
    /// Audio elementary PIDs in PMT order: main audio first.
    public let audioPIDs: [Int]

    public init(pmtPID: Int, audioPIDs: [Int]) {
        self.pmtPID = pmtPID
        self.audioPIDs = audioPIDs
    }

    public init?(pmt: PMT, pmtPID: Int) {
        let pids = pmt.audioPIDs
        guard !pids.isEmpty else { return nil }
        self.init(pmtPID: pmtPID, audioPIDs: pids)
    }

    public var primaryAudioPID: Int? {
        audioPIDs.first
    }

    public var secondaryAudioPID: Int? {
        audioPIDs.count >= 2 ? audioPIDs[1] : nil
    }

    /// True when the program carries a second audio elementary stream, i.e.
    /// when the app should offer 主音声 / 副音声.
    public var hasSecondaryAudio: Bool {
        audioPIDs.count >= 2
    }

    /// The audio PID that survives for a selection, or nil when the selection
    /// is not available (no secondary audio).
    public func audioPID(for selection: AudioSelection) -> Int? {
        switch selection {
        case .primary:
            return primaryAudioPID
        case .secondary:
            return secondaryAudioPID
        }
    }
}

/// Rewrites a produced live segment so that it carries exactly one audio
/// elementary stream.
///
/// Design: segments are produced and stored once, unfiltered. The selection is
/// applied when a segment is served, so switching 主音声 / 副音声 takes effect
/// with the next segment request and never restarts the upstream stream.
///
/// Filtering drops the packets of the audio PID that is not selected and
/// rewrites the PMT so only the selected audio stream remains (section length
/// and CRC-32/MPEG-2 recomputed, continuity counter preserved). The PAT and all
/// other PIDs pass through untouched. When the program has a single audio
/// stream the segment is returned unchanged for both selections.
public enum LiveAudioFilter {

    /// Returns `data` with only the selected audio stream left in it.
    public static func filteredSegment(
        _ data: Data,
        selection: AudioSelection,
        pmt: PMT,
        pmtPID: Int
    ) -> Data {
        let audioPIDs = pmt.audioPIDs
        // Nothing to choose between: leave the segment byte-identical.
        guard audioPIDs.count >= 2 else { return data }

        let keepPID: Int
        let dropPID: Int
        switch selection {
        case .primary:
            keepPID = audioPIDs[0]
            dropPID = audioPIDs[1]
        case .secondary:
            keepPID = audioPIDs[1]
            dropPID = audioPIDs[0]
        }

        let bytes = [UInt8](data)
        let packetCount = bytes.count / TSPacket.packetSize
        guard packetCount > 0 else { return data }

        // Only rewrite when the segment actually contains the PMT; otherwise
        // dropping an audio PID would leave a PMT pointing at a missing stream.
        var hasPMT = false
        for index in 0..<packetCount {
            let start = index * TSPacket.packetSize
            guard let packet = TSPacket(bytes: Array(bytes[start..<(start + TSPacket.packetSize)])) else {
                continue
            }
            if packet.pid == pmtPID, packet.payloadUnitStartIndicator {
                hasPMT = true
                break
            }
        }
        guard hasPMT else { return data }

        let rewrittenSection = pmt.section(keepingAudioPID: keepPID)
        // The rewritten section is written into a single packet; a PMT too large
        // for that is left alone rather than truncated.
        guard rewrittenSection.count <= TSPacket.packetSize - 5 else { return data }
        var output = Data()
        output.reserveCapacity(data.count)

        for index in 0..<packetCount {
            let start = index * TSPacket.packetSize
            let slice = Array(bytes[start..<(start + TSPacket.packetSize)])
            guard let packet = TSPacket(bytes: slice) else {
                output.append(contentsOf: slice)
                continue
            }

            if packet.pid == dropPID {
                continue
            }
            if packet.pid == pmtPID {
                // The whole rewritten section goes into the packet that starts
                // the PMT, so continuation packets of a multi-packet PMT are
                // dropped with the rest of the old section.
                if packet.payloadUnitStartIndicator {
                    output.append(rewrittenPMTPacket(packet, section: rewrittenSection))
                }
                continue
            }
            output.append(contentsOf: slice)
        }
        return output
    }

    /// Builds a payload-only TS packet carrying `section` for the PMT PID.
    ///
    /// The continuity counter of the original packet is kept so the rewritten
    /// PMT stays in sequence with the rest of the stream.
    static func rewrittenPMTPacket(_ packet: TSPacket, section: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: TSPacket.packetSize)
        bytes[0] = TSPacket.syncByte
        bytes[1] = 0x40 | UInt8((packet.pid >> 8) & 0x1F)
        bytes[2] = UInt8(packet.pid & 0xFF)
        bytes[3] = 0x10 | UInt8(packet.continuityCounter & 0x0F)
        bytes[4] = 0x00  // pointer_field
        for (offset, byte) in section.enumerated() {
            bytes[5 + offset] = byte
        }
        return Data(bytes)
    }
}
