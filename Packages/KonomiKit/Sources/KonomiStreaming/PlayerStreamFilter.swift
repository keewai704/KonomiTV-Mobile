import Foundation

/// Restricts an MPEG-TS segment to what AVPlayer plays: PAT, PMT, video and
/// audio.
///
/// Broadcast TS (and KonomiTV's HLS, which keeps `-map 0:d?`) carries ARIB
/// caption, superimpose and data-carousel streams as private PES (stream type
/// 0x06 / 0x0D). AVPlayer rejects such segments (CoreMediaErrorDomain -12971),
/// so the app extracts the captions itself from the original bytes and hands
/// AVPlayer this filtered copy. Every PMT in the segment is rewritten (section
/// length and CRC recomputed, continuity counter kept) so none of them still
/// lists a dropped stream.
public enum PlayerStreamFilter {

    /// Returns `data` without the non audio/video elementary streams.
    ///
    /// - Parameters:
    ///   - pmt: The program's PMT when the caller already knows it (a live
    ///     segment may not contain one); otherwise it is read from `data`.
    ///   - pmtPID: The PMT PID that goes with `pmt`.
    /// - Returns: The filtered segment, or `data` unchanged when there is
    ///   nothing to drop or the program cannot be identified.
    public static func audioVideoOnly(
        _ data: Data,
        pmt knownPMT: PMT? = nil,
        pmtPID knownPMTPID: Int? = nil
    ) -> Data {
        let bytes = [UInt8](data)
        let packetCount = bytes.count / TSPacket.packetSize
        guard packetCount > 0 else { return data }

        func packet(at index: Int) -> TSPacket? {
            let start = index * TSPacket.packetSize
            return TSPacket(bytes: Array(bytes[start..<(start + TSPacket.packetSize)]))
        }

        var pmtPID = knownPMTPID
        if pmtPID == nil {
            for index in 0..<packetCount {
                guard let packet = packet(at: index),
                      packet.pid == 0,
                      packet.payloadUnitStartIndicator,
                      let pat = PAT(payload: packet.payload),
                      let pid = pat.pmtPID else {
                    continue
                }
                pmtPID = pid
                break
            }
        }
        guard let pmtPID else { return data }

        // The PMT inside the segment wins over the caller's: it is the one the
        // packets were muxed with (it may already be the audio-filtered one).
        var pmt: PMT?
        for index in 0..<packetCount {
            guard let packet = packet(at: index),
                  packet.pid == pmtPID,
                  packet.payloadUnitStartIndicator,
                  let parsed = PMT(payload: packet.payload) else {
                continue
            }
            pmt = parsed
            break
        }
        pmt = pmt ?? knownPMT
        guard let pmt else { return data }

        let dropPIDs = Set(
            pmt.streams
                .filter { !isPlayable($0) && $0.elementaryPID != pmt.pcrPID }
                .map(\.elementaryPID)
        )
        guard !dropPIDs.isEmpty else { return data }

        let section = pmt.section(keeping: { !dropPIDs.contains($0.elementaryPID) })
        // The rewritten section goes into a single packet; a PMT too large for
        // that is left alone rather than truncated.
        guard section.count <= TSPacket.packetSize - 5 else { return data }

        var output = Data()
        output.reserveCapacity(data.count)
        for index in 0..<packetCount {
            let start = index * TSPacket.packetSize
            let slice = bytes[start..<(start + TSPacket.packetSize)]
            guard let packet = TSPacket(bytes: Array(slice)) else {
                output.append(contentsOf: slice)
                continue
            }
            if dropPIDs.contains(packet.pid) {
                continue
            }
            if packet.pid == pmtPID {
                if packet.payloadUnitStartIndicator {
                    output.append(LiveAudioFilter.rewrittenPMTPacket(packet, section: section))
                }
                continue
            }
            output.append(contentsOf: slice)
        }
        return output
    }

    /// Video (MPEG-2, H.264, H.265) and audio elementary streams.
    static func isPlayable(_ stream: PMT.Stream) -> Bool {
        stream.isAudio || [0x01, 0x02, 0x1B, 0x24].contains(stream.streamType)
    }
}
