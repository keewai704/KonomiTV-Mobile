import Foundation

// MARK: - Metadata

/// Header of KonomiTV's offline save stream
/// (`GET /api/streams/video/{id}/{quality}/offline-stream`).
///
/// The server writes the JSON header right after the `KTVODLP\n` magic, so a
/// client can recognise the stream and check that it belongs to the save job
/// before any segment is stored.
public struct OfflineStreamMetadata: Codable, Sendable, Hashable {
    /// Recorded program ID the stream belongs to.
    public var videoID: Int
    /// Recording file hash, so an ID that now points at another file is caught.
    public var fileHash: String
    /// API quality including `-hevc` / `-10bit` / `-24fps` suffixes.
    public var quality: String
    /// Program duration used for the size estimate and the playlist.
    public var durationSeconds: Double

    public init(videoID: Int, fileHash: String, quality: String, durationSeconds: Double) {
        self.videoID = videoID
        self.fileHash = fileHash
        self.quality = quality
        self.durationSeconds = durationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
        case fileHash = "file_hash"
        case quality
        case durationSeconds = "duration_seconds"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoID = container.lenient(Int.self, forKey: .videoID) ?? -1
        fileHash = container.lenient(String.self, forKey: .fileHash) ?? ""
        quality = container.lenient(String.self, forKey: .quality) ?? ""
        durationSeconds = container.lenient(Double.self, forKey: .durationSeconds) ?? 0
    }

    /// Whether the header belongs to a save of `videoID` at `quality`.
    ///
    /// An empty `fileHash` skips the hash check: programs whose recording file
    /// has no hash cannot be distinguished by it.
    public func matches(videoID: Int, fileHash: String, quality: String) -> Bool {
        guard self.videoID == videoID, self.quality == quality else { return false }
        guard !fileHash.isEmpty else { return true }
        return self.fileHash == fileHash
    }
}

// MARK: - Segments

/// One segment of the offline save stream (MPEG-TS for KonomiTV 0.15).
public struct OfflineStreamSegment: Sendable, Hashable {
    /// Sequence index, 0-based and strictly increasing.
    public let sequence: Int
    /// Segment duration in milliseconds (`#EXTINF` is built from it).
    public let durationMilliseconds: Int
    /// Raw segment bytes.
    public let data: Data

    public init(sequence: Int, durationMilliseconds: Int, data: Data) {
        self.sequence = sequence
        self.durationMilliseconds = durationMilliseconds
        self.data = data
    }

    public var durationSeconds: Double {
        Double(durationMilliseconds) / 1000
    }
}

/// One thing the parser produced from the bytes read so far.
public enum OfflineStreamEvent: Sendable, Hashable {
    case metadata(OfflineStreamMetadata)
    case segment(OfflineStreamSegment)
    /// Terminator record; `segmentCount` is the count the server declared.
    case end(segmentCount: Int)
}

public enum OfflineStreamParserError: Error, LocalizedError, Sendable, Equatable {
    case invalidMagic
    case invalidMetadataLength
    case invalidMetadata
    case unexpectedSequence(expected: Int, actual: Int)
    case invalidSegmentHeader(sequence: Int)
    case segmentCountMismatch(declared: Int, received: Int)
    case truncated

    public var errorDescription: String? {
        switch self {
        case .invalidMagic:
            return "オフライン保存データの形式を認識できません。"
        case .invalidMetadataLength:
            return "オフライン保存データのメタデータ長が不正です。"
        case .invalidMetadata:
            return "オフライン保存データのメタデータを読み取れません。"
        case .unexpectedSequence(let expected, let actual):
            return "オフライン保存データのセグメント順序が不正です。(期待: \(expected) / 実際: \(actual))"
        case .invalidSegmentHeader(let sequence):
            return "オフライン保存データのセグメント \(sequence) のヘッダーが不正です。"
        case .segmentCountMismatch(let declared, let received):
            return "オフライン保存データのセグメント数が一致しません。(宣言: \(declared) / 受信: \(received))"
        case .truncated:
            return "オフライン保存データが途中で切れました。"
        }
    }
}

// MARK: - Parser

/// Incremental parser for KonomiTV's offline save stream.
///
/// The binary layout is:
///
///     "KTVODLP\n"
///     u32 metadata length (big endian), metadata JSON
///     repeat: u32 sequence, u32 duration_ms, u32 length, segment bytes
///     u32 0xFFFFFFFF, u32 segment count
///
/// Network reads split anywhere, so the parser keeps the unread tail and
/// produces whatever completed records the chunk contained. `finish()` reports
/// a stream that ended before its terminator (truncation), which is the case the
/// server relies on to detect a dropped connection.
public struct OfflineStreamParser {
    public static let magic = Data("KTVODLP\n".utf8)
    /// The server rejects headers above 1 MiB (it writes a few hundred bytes).
    public static let maximumMetadataLength = 1024 * 1024
    /// Sanity limit for one segment (about a minute of broadcast video).
    public static let maximumSegmentLength = 128 * 1024 * 1024

    private static let terminatorSequence: UInt32 = 0xFFFF_FFFF

    private enum ParseState {
        case magic
        case metadataLength
        case metadata
        case records
    }

    private var state: ParseState = .magic
    private var pending = Data()
    private var metadataLength = 0
    private var receivedSegments = 0

    /// Header of the stream, once it has been read.
    public private(set) var metadata: OfflineStreamMetadata?
    /// True after the terminator record has been read.
    public private(set) var isFinished = false
    /// Number of segments read so far.
    public var receivedSegmentCount: Int { receivedSegments }

    public init() {}

    /// Appends a chunk and returns every complete record it contained.
    ///
    /// Throws as soon as the stream is malformed; the parser then stays unusable
    /// (`isFinished` remains false), which the caller treats as a failed save.
    @discardableResult
    public mutating func append(_ data: Data) throws -> [OfflineStreamEvent] {
        guard !isFinished else { return [] }
        pending.append(data)

        var events: [OfflineStreamEvent] = []
        var isParsing = true
        while isParsing {
            switch state {
            case .magic:
                guard pending.count >= Self.magic.count else {
                    isParsing = false
                    break
                }
                guard pending.starts(with: Self.magic) else {
                    throw OfflineStreamParserError.invalidMagic
                }
                consume(Self.magic.count)
                state = .metadataLength

            case .metadataLength:
                guard pending.count >= 4 else {
                    isParsing = false
                    break
                }
                let length = Int(readUInt32(at: 0))
                guard length > 0, length <= Self.maximumMetadataLength else {
                    throw OfflineStreamParserError.invalidMetadataLength
                }
                metadataLength = length
                consume(4)
                state = .metadata

            case .metadata:
                guard pending.count >= metadataLength else {
                    isParsing = false
                    break
                }
                let json = Data(pending.prefix(metadataLength))
                guard let decoded = try? JSONCoding.decode(OfflineStreamMetadata.self, from: json) else {
                    throw OfflineStreamParserError.invalidMetadata
                }
                consume(metadataLength)
                metadata = decoded
                state = .records
                events.append(.metadata(decoded))

            case .records:
                guard pending.count >= 4 else {
                    isParsing = false
                    break
                }
                let sequence = readUInt32(at: 0)
                if sequence == Self.terminatorSequence {
                    guard pending.count >= 8 else {
                        isParsing = false
                        break
                    }
                    let declared = Int(readUInt32(at: 4))
                    consume(8)
                    guard declared == receivedSegments else {
                        throw OfflineStreamParserError.segmentCountMismatch(
                            declared: declared,
                            received: receivedSegments
                        )
                    }
                    isFinished = true
                    isParsing = false
                    events.append(.end(segmentCount: declared))
                    break
                }

                guard pending.count >= 12 else {
                    isParsing = false
                    break
                }
                guard Int(sequence) == receivedSegments else {
                    throw OfflineStreamParserError.unexpectedSequence(
                        expected: receivedSegments,
                        actual: Int(sequence)
                    )
                }
                let durationMilliseconds = Int(readUInt32(at: 4))
                let length = Int(readUInt32(at: 8))
                guard durationMilliseconds > 0,
                      length > 0,
                      length <= Self.maximumSegmentLength else {
                    throw OfflineStreamParserError.invalidSegmentHeader(sequence: receivedSegments)
                }
                guard pending.count >= 12 + length else {
                    isParsing = false
                    break
                }
                let payload = Data(pending.dropFirst(12).prefix(length))
                consume(12 + length)
                let segment = OfflineStreamSegment(
                    sequence: receivedSegments,
                    durationMilliseconds: durationMilliseconds,
                    data: payload
                )
                receivedSegments += 1
                events.append(.segment(segment))
            }
        }
        return events
    }

    /// Marks the end of the input. Throws when the terminator never arrived.
    public func finish() throws {
        guard isFinished else {
            throw OfflineStreamParserError.truncated
        }
    }

    // MARK: - Buffer

    private mutating func consume(_ count: Int) {
        // Re-base the buffer so indices stay 0-based for the readers below.
        pending = Data(pending.dropFirst(count))
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        let start = pending.startIndex + offset
        return (UInt32(pending[start]) << 24)
            | (UInt32(pending[start + 1]) << 16)
            | (UInt32(pending[start + 2]) << 8)
            | UInt32(pending[start + 3])
    }
}
