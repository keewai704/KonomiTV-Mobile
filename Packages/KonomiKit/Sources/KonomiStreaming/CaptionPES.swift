import Foundation

/// Kind of ARIB caption elementary stream.
public enum CaptionPESKind: String, Sendable, Hashable {
    /// 字幕 (caption), component tag 0x30–0x37, data_identifier 0x80.
    case caption
    /// 文字スーパー (superimpose), component tag 0x38–0x3F, data_identifier 0x81.
    case superimpose
}

/// One reassembled caption PES packet.
public struct CaptionPES: Sendable, Hashable {
    public let kind: CaptionPESKind
    /// Raw 33-bit PES PTS in 90 kHz units. Nil when the PES header has no PTS
    /// (common for superimpose).
    public let pts: Int64?
    /// PES data bytes starting at the caption `data_identifier` (0x80/0x81),
    /// i.e. exactly what libaribcaption's decoder expects.
    public let payload: Data

    public init(kind: CaptionPESKind, pts: Int64?, payload: Data) {
        self.kind = kind
        self.pts = pts
        self.payload = payload
    }

    /// Presentation timestamp in seconds, when known.
    public var ptsSeconds: Double? {
        pts.map(PTS.seconds)
    }
}

/// Reassembles caption / superimpose PES packets from a transport stream.
///
/// The extractor can either be configured with a PMT
/// (`configure(pmt:)`) or discover the PAT/PMT itself while packets are fed
/// in. PES packets whose `PES_packet_length` is zero are terminated at the
/// next payload-unit start, as ARIB captures do.
public struct CaptionPESExtractor: Sendable {
    private struct PendingPES {
        var bytes: [UInt8] = []
    }

    public private(set) var captionPID: Int?
    public private(set) var superimposePID: Int?

    private var pmtPID: Int?
    private var pending: [Int: PendingPES] = [:]
    private var packetizer = TSPacketizer()

    public init(captionPID: Int? = nil, superimposePID: Int? = nil) {
        self.captionPID = captionPID
        self.superimposePID = superimposePID
    }

    /// Uses the caption and superimpose PIDs of an already parsed PMT.
    public mutating func configure(pmt: PMT) {
        captionPID = pmt.captionPID
        superimposePID = pmt.superimposePID
    }

    /// Forgets reassembly state but keeps the configured PIDs.
    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        packetizer.reset()
    }

    /// Feeds raw transport-stream bytes and returns every PES completed by them.
    public mutating func append(_ data: Data) -> [CaptionPES] {
        var events: [CaptionPES] = []
        for packet in packetizer.append(data) {
            events.append(contentsOf: append(packet))
        }
        return events
    }

    /// Feeds one transport-stream packet.
    public mutating func append(_ packet: TSPacket) -> [CaptionPES] {
        if packet.pid == 0 {
            if packet.payloadUnitStartIndicator, let pat = PAT(payload: packet.payload) {
                pmtPID = pat.pmtPID
            }
            return []
        }
        if let pmtPID, packet.pid == pmtPID {
            if packet.payloadUnitStartIndicator, let pmt = PMT(payload: packet.payload) {
                configure(pmt: pmt)
            }
            return []
        }

        guard let kind = kind(for: packet.pid) else { return [] }

        var events: [CaptionPES] = []
        if packet.payloadUnitStartIndicator {
            if let completed = completePending(for: packet.pid, kind: kind) {
                events.append(completed)
            }
            pending[packet.pid] = PendingPES()
        }
        guard packet.hasPayload, !packet.payload.isEmpty else { return events }

        pending[packet.pid, default: PendingPES()].bytes.append(contentsOf: packet.payload)
        if let completed = takeCompleted(for: packet.pid) {
            events.append(completed)
        }
        return events
    }

    /// Emits PES packets still waiting for the next payload-unit start.
    public mutating func flush() -> [CaptionPES] {
        var events: [CaptionPES] = []
        for pid in pending.keys.sorted() {
            guard let kind = kind(for: pid) else { continue }
            if let completed = completePending(for: pid, kind: kind) {
                events.append(completed)
            }
        }
        return events
    }

    private func kind(for pid: Int) -> CaptionPESKind? {
        if pid == captionPID { return .caption }
        if pid == superimposePID { return .superimpose }
        return nil
    }

    private mutating func takeCompleted(for pid: Int) -> CaptionPES? {
        guard let pendingPES = pending[pid], let kind = kind(for: pid) else {
            return nil
        }
        let bytes = pendingPES.bytes
        guard bytes.count >= 6,
              bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0x01 else {
            return nil
        }
        let declaredLength = (Int(bytes[4]) << 8) | Int(bytes[5])
        guard declaredLength > 0, bytes.count >= 6 + declaredLength else {
            return nil
        }
        pending[pid] = PendingPES()
        return Self.makeEvent(kind: kind, bytes: Array(bytes[0..<(6 + declaredLength)]))
    }

    private mutating func completePending(for pid: Int, kind: CaptionPESKind) -> CaptionPES? {
        guard let pendingPES = pending.removeValue(forKey: pid) else { return nil }
        guard !pendingPES.bytes.isEmpty else { return nil }
        return Self.makeEvent(kind: kind, bytes: pendingPES.bytes)
    }

    private static func makeEvent(kind: CaptionPESKind, bytes: [UInt8]) -> CaptionPES? {
        guard let pes = PESPacket(bytes: bytes) else { return nil }
        return CaptionPES(kind: kind, pts: pes.pts, payload: Data(pes.payload))
    }
}

/// An `AsyncStream` fan-out for caption PES events.
///
/// The app feeds this from its live-stream loop:
///
///     let output = segmenter.process(chunk)
///     for caption in output.captions { await channel.publish(caption) }
///     for await caption in channel.stream() { ... }
///
/// Only one consumer is supported; calling `stream()` again replaces the
/// previous stream. Events published while nobody is listening are buffered up
/// to `bufferLimit`.
public actor CaptionEventChannel {
    public let bufferLimit: Int
    private var continuation: AsyncStream<CaptionPES>.Continuation?
    private var backlog: [CaptionPES] = []

    public init(bufferLimit: Int = 64) {
        self.bufferLimit = max(bufferLimit, 1)
    }

    public func stream() -> AsyncStream<CaptionPES> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(
            of: CaptionPES.self,
            bufferingPolicy: .bufferingNewest(bufferLimit)
        )
        for event in backlog {
            continuation.yield(event)
        }
        backlog.removeAll(keepingCapacity: true)
        self.continuation = continuation
        return stream
    }

    public func publish(_ event: CaptionPES) {
        if let continuation {
            continuation.yield(event)
        } else {
            backlog.append(event)
            if backlog.count > bufferLimit {
                backlog.removeFirst(backlog.count - bufferLimit)
            }
        }
    }

    public func finish() {
        continuation?.finish()
        continuation = nil
        backlog.removeAll(keepingCapacity: true)
    }
}
