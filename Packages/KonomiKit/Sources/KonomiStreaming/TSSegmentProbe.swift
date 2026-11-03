import Foundation

/// Inspects a self-contained MPEG-TS segment (the kind an HLS media playlist
/// serves) without keeping any state between segments.
///
/// The app uses this on recorded-video segments proxied through the loopback
/// server: the first video PTS lets `HLSMediaPlaylist.playbackTime(segmentIndex:
/// pts:firstPTS:)` turn caption PTS values into playback positions, and the
/// PMT lets a fresh `CaptionPESExtractor` find the caption PIDs.
public enum TSSegmentProbe {
    /// What was found in a segment.
    public struct Result: Sendable, Hashable {
        /// Raw 33-bit PTS (90 kHz) of the first video PES, when the segment has
        /// a video elementary stream and a PAT/PMT.
        public let firstVideoPTS: Int64?
        /// PMT that was in effect in this segment.
        public let pmt: PMT?
        /// PID of `pmt`.
        public let pmtPID: Int?
    }

    /// Scans one segment's transport-stream packets.
    public static func probe(_ data: Data) -> Result {
        var packetizer = TSPacketizer()
        var pmtPID: Int?
        var pmt: PMT?
        var videoPID: Int?
        var firstVideoPTS: Int64?

        for packet in packetizer.append(data) {
            if packet.pid == 0 {
                if packet.payloadUnitStartIndicator,
                   let pat = PAT(payload: packet.payload) {
                    pmtPID = pat.pmtPID
                }
                continue
            }

            if let pmtPID, packet.pid == pmtPID {
                if pmt == nil, packet.payloadUnitStartIndicator,
                   let parsed = PMT(payload: packet.payload) {
                    pmt = parsed
                    videoPID = parsed.videoPID
                }
                continue
            }

            guard firstVideoPTS == nil,
                  let videoPID,
                  packet.pid == videoPID,
                  packet.payloadUnitStartIndicator,
                  let pes = PESPacket(bytes: packet.payload),
                  let pts = pes.pts
            else { continue }

            firstVideoPTS = pts
        }

        return Result(firstVideoPTS: firstVideoPTS, pmt: pmt, pmtPID: pmtPID)
    }

    /// Convenience wrapper for callers that only need the timestamp.
    public static func firstVideoPTS(in data: Data) -> Int64? {
        probe(data).firstVideoPTS
    }

    /// Extracts caption / superimpose PES packets from one segment.
    ///
    /// A fresh extractor is used per segment because HLS media segments must
    /// start with a PAT and PMT, so no state has to cross segment boundaries.
    public static func captionPES(in data: Data) -> [CaptionPES] {
        let result = probe(data)
        var extractor = CaptionPESExtractor()
        if let pmt = result.pmt {
            extractor.configure(pmt: pmt)
        }
        var events = extractor.append(data)
        events.append(contentsOf: extractor.flush())
        return events
    }
}
