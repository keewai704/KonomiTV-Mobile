import Foundation
import KonomiKit

/// One HLS media segment produced by `LiveSegmenter`.
public struct TSSegment: Sendable, Hashable {
    public let sequence: Int
    public let duration: Double
    public let data: Data
    public let discontinuity: Bool
    /// PMT that was in effect when the segment was cut. Carried so an audio
    /// track selection can be applied later, when the segment is served.
    public let pmt: PMT?
    /// PID of `pmt`.
    public let pmtPID: Int?
    /// Raw 33-bit PTS (90 kHz) of the first video frame in this segment, when
    /// known. Caption PES PTS values are relative to the same clock, so the app
    /// can map them onto the playback timeline.
    public let firstVideoPTS: Int64?

    public init(
        sequence: Int,
        duration: Double,
        data: Data,
        discontinuity: Bool = false,
        pmt: PMT? = nil,
        pmtPID: Int? = nil,
        firstVideoPTS: Int64? = nil
    ) {
        self.sequence = sequence
        self.duration = duration
        self.data = data
        self.discontinuity = discontinuity
        self.pmt = pmt
        self.pmtPID = pmtPID
        self.firstVideoPTS = firstVideoPTS
    }

    public var byteCount: Int {
        data.count
    }

    /// Number of 188-byte TS packets in the segment.
    public var packetCount: Int {
        data.count / TSPacket.packetSize
    }

    /// Audio tracks described by the segment's PMT, if known.
    public var audioTrackInfo: LiveAudioTrackInfo? {
        guard let pmt, let pmtPID else { return nil }
        return LiveAudioTrackInfo(pmt: pmt, pmtPID: pmtPID)
    }

    /// True when the program carries a secondary audio stream, i.e. when the
    /// app should offer 主音声 / 副音声.
    public var hasSecondaryAudio: Bool {
        audioTrackInfo?.hasSecondaryAudio ?? false
    }

    /// Returns a copy of the segment restricted to one audio stream.
    ///
    /// Segments with a single audio stream (or without a known PMT) are
    /// returned unchanged.
    public func filtered(audio selection: AudioSelection) -> TSSegment {
        guard let pmt, let pmtPID else { return self }
        let filteredData = LiveAudioFilter.filteredSegment(
            data,
            selection: selection,
            pmt: pmt,
            pmtPID: pmtPID
        )
        guard filteredData != data else { return self }
        return TSSegment(
            sequence: sequence,
            duration: duration,
            data: filteredData,
            discontinuity: discontinuity,
            pmt: pmt,
            pmtPID: pmtPID,
            firstVideoPTS: firstVideoPTS
        )
    }
}

/// Result of feeding a live stream chunk to `LiveSegmenter.process(_:)`.
public struct LiveSegmenterOutput: Sendable {
    public let segments: [TSSegment]
    /// Caption / superimpose PES packets completed by this chunk, in stream
    /// order, with their PTS. Segment bytes are not modified.
    public let captions: [CaptionPES]
}

/// Converts an endless MPEG-TS byte stream into short HLS media segments cut
/// on video keyframes.
public struct LiveSegmenter: Sendable {
    public var targetDuration: Double
    /// Called for every completed caption / superimpose PES packet.
    public var captionHandler: (@Sendable (CaptionPES) -> Void)?

    private var packetizer = TSPacketizer()
    private var captionExtractor = CaptionPESExtractor()
    private var patPacket: Data?
    private var pmtPacket: Data?
    private var pat: PAT?
    private var pmt: PMT?
    private var pmtPID: Int?
    private var videoPID: Int?
    private var videoCodec: VideoCodec?
    private var unwrapper = PTSUnwrapper()
    private var lastVideoPTS: Int64?
    private var segmentStartPTS: Int64?
    private var segmentFirstVideoPTS: Int64?
    private var segmentBuffer = Data()
    private var segmentDiscontinuity = false
    private var nextSequence = 0

    public init(targetDuration: Double = 1.0) {
        self.targetDuration = targetDuration
    }

    /// Feeds an arbitrary chunk of the transport stream and returns any
    /// segments completed by this chunk.
    public mutating func append(_ data: Data) -> [TSSegment] {
        process(data).segments
    }

    public mutating func append(_ bytes: [UInt8]) -> [TSSegment] {
        append(Data(bytes))
    }

    /// Feeds a chunk and returns both the completed segments and the caption /
    /// superimpose PES packets contained in it.
    public mutating func process(_ data: Data) -> LiveSegmenterOutput {
        var segments: [TSSegment] = []
        var captions: [CaptionPES] = []
        for packet in packetizer.append(data) {
            process(packet, into: &segments)
            captions.append(contentsOf: captionExtractor.append(packet))
        }
        for caption in captions {
            captionHandler?(caption)
        }
        return LiveSegmenterOutput(segments: segments, captions: captions)
    }

    /// Emits the currently open segment, if any. Live streams normally only
    /// need this when the upstream connection ends.
    public mutating func flush() -> TSSegment? {
        for caption in captionExtractor.flush() {
            captionHandler?(caption)
        }
        guard segmentStartPTS != nil else { return nil }
        return emitCurrentSegment(endPTS: lastVideoPTS)
    }

    public mutating func reset() {
        packetizer.reset()
        patPacket = nil
        pmtPacket = nil
        pat = nil
        pmt = nil
        pmtPID = nil
        videoPID = nil
        videoCodec = nil
        unwrapper.reset()
        lastVideoPTS = nil
        segmentStartPTS = nil
        segmentFirstVideoPTS = nil
        captionExtractor.reset()
        segmentBuffer.removeAll(keepingCapacity: true)
        segmentDiscontinuity = false
        nextSequence = 0
    }

    public var currentSequence: Int {
        nextSequence
    }

    /// Latest PAT parsed from the stream, if any.
    public var programAssociationTable: PAT? {
        pat
    }

    /// Latest PMT parsed from the stream, if any.
    public var programMapTable: PMT? {
        pmt
    }

    /// Audio tracks of the current program (main audio first). Nil until a PMT
    /// with at least one audio stream has been seen.
    public var audioTrackInfo: LiveAudioTrackInfo? {
        guard let pmt, let pmtPID else { return nil }
        return LiveAudioTrackInfo(pmt: pmt, pmtPID: pmtPID)
    }

    /// True when the current program carries a secondary audio stream.
    public var hasSecondaryAudio: Bool {
        audioTrackInfo?.hasSecondaryAudio ?? false
    }

    // MARK: - Packet handling

    private mutating func process(_ packet: TSPacket, into segments: inout [TSSegment]) {
        if packet.pid == 0 {
            if packet.payloadUnitStartIndicator, let parsed = PAT(payload: packet.payload) {
                pat = parsed
                patPacket = packet.data
                pmtPID = parsed.pmtPID
            }
            appendToSegment(packet.data)
            return
        }

        if let pmtPID, packet.pid == pmtPID {
            if packet.payloadUnitStartIndicator, let parsed = PMT(payload: packet.payload) {
                pmt = parsed
                pmtPacket = packet.data
                videoPID = parsed.videoPID
                videoCodec = parsed.videoCodec
            }
            appendToSegment(packet.data)
            return
        }

        guard let videoPID, packet.pid == videoPID else {
            appendToSegment(packet.data)
            return
        }

        let previousPTS = lastVideoPTS
        var isKeyframe = packet.randomAccessIndicator
        var timestamp: Int64?
        var rawTimestamp: Int64?

        if packet.payloadUnitStartIndicator, let pes = PESPacket(bytes: packet.payload) {
            if let rawPTS = pes.pts {
                rawTimestamp = rawPTS
                let unwrapped = unwrapper.unwrap(rawPTS)
                timestamp = unwrapped
                lastVideoPTS = unwrapped
            }
            if !isKeyframe, let videoCodec {
                isKeyframe = KeyframeDetector.isKeyframe(pesPayload: pes.payload, codec: videoCodec)
            }
        }

        guard isKeyframe, let timestamp, patPacket != nil, pmtPacket != nil else {
            appendToSegment(packet.data)
            return
        }

        if segmentStartPTS != nil {
            if isJump(timestamp, from: previousPTS) {
                if let segment = emitCurrentSegment(endPTS: previousPTS ?? timestamp) {
                    segments.append(segment)
                }
                startSegment(
                    at: timestamp,
                    discontinuity: true,
                    firstPacket: packet.data,
                    firstVideoPTS: rawTimestamp
                )
                return
            }

            let elapsed = timestamp - (segmentStartPTS ?? timestamp)
            if Double(elapsed) >= cutThreshold {
                if let segment = emitCurrentSegment(endPTS: timestamp) {
                    segments.append(segment)
                }
                startSegment(
                    at: timestamp,
                    discontinuity: false,
                    firstPacket: packet.data,
                    firstVideoPTS: rawTimestamp
                )
            } else {
                appendToSegment(packet.data)
            }
        } else {
            startSegment(
                at: timestamp,
                discontinuity: isJump(timestamp, from: previousPTS),
                firstPacket: packet.data,
                firstVideoPTS: rawTimestamp
            )
        }
    }

    private var cutThreshold: Double {
        max(targetDuration, 0.05) * PTS.clockRate - (PTS.clockRate / 10)
    }

    private func isJump(_ timestamp: Int64, from previous: Int64?) -> Bool {
        guard let previous else { return false }
        if timestamp < previous {
            return true
        }
        return timestamp - previous > Int64(5 * PTS.clockRate)
    }

    private mutating func appendToSegment(_ data: Data) {
        guard segmentStartPTS != nil else { return }
        segmentBuffer.append(data)
    }

    private mutating func startSegment(
        at timestamp: Int64,
        discontinuity: Bool,
        firstPacket: Data,
        firstVideoPTS: Int64?
    ) {
        guard let patPacket, let pmtPacket else { return }
        segmentBuffer.removeAll(keepingCapacity: true)
        segmentBuffer.append(patPacket)
        segmentBuffer.append(pmtPacket)
        segmentBuffer.append(firstPacket)
        segmentStartPTS = timestamp
        segmentFirstVideoPTS = firstVideoPTS
        segmentDiscontinuity = discontinuity
    }

    private mutating func emitCurrentSegment(endPTS: Int64?) -> TSSegment? {
        guard let start = segmentStartPTS, !segmentBuffer.isEmpty else { return nil }
        let end = max(endPTS ?? lastVideoPTS ?? start, start)
        let duration = Double(end - start) / PTS.clockRate
        let segment = TSSegment(
            sequence: nextSequence,
            duration: max(duration, 0.001),
            data: segmentBuffer,
            discontinuity: segmentDiscontinuity,
            pmt: pmt,
            pmtPID: pmtPID,
            firstVideoPTS: segmentFirstVideoPTS
        )
        nextSequence += 1
        segmentBuffer.removeAll(keepingCapacity: true)
        segmentStartPTS = nil
        segmentFirstVideoPTS = nil
        segmentDiscontinuity = false
        return segment
    }
}
