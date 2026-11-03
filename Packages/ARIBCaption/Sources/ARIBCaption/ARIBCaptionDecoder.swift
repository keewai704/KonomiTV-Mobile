import Foundation
import CAribCaption

/// Errors thrown while creating a decoder or renderer.
public enum ARIBCaptionError: Error, Sendable, Equatable {
    /// `aribcc_context_alloc()` returned NULL.
    case contextUnavailable
    /// `aribcc_decoder_alloc()` / `aribcc_renderer_alloc()` returned NULL.
    case allocationFailed
    /// `aribcc_decoder_initialize()` / `aribcc_renderer_initialize()` failed.
    case initializationFailed
}

/// Type of ARIB caption elementary stream.
public enum ARIBCaptionKind: Sendable, Hashable {
    /// 字幕 (caption), data_identifier 0x80.
    case caption
    /// 文字スーパー (superimpose), data_identifier 0x81.
    case superimpose

    var cValue: aribcc_captiontype_t {
        switch self {
        case .caption: return ARIBCC_CAPTIONTYPE_CAPTION
        case .superimpose: return ARIBCC_CAPTIONTYPE_SUPERIMPOSE
        }
    }
}

/// ARIB STD-B24 caption profile.
public enum ARIBCaptionProfile: Sendable, Hashable {
    /// A-Profile, used by full-segment (地上デジタル) broadcasting.
    case a
    /// C-Profile, used by 1seg.
    case c

    var cValue: aribcc_profile_t {
        switch self {
        case .a: return ARIBCC_PROFILE_A
        case .c: return ARIBCC_PROFILE_C
        }
    }
}

/// Character encoding scheme of the caption stream.
public enum ARIBCaptionEncoding: Sendable, Hashable {
    case auto
    /// 8-unit JIS encoding used by Japanese ISDB captions (the usual case).
    case aribStdB24JIS
    /// UTF-8 variant used by ISDB-T Philippines.
    case aribStdB24UTF8
    /// Latin variant used by ISDB-Tb / SBTVD.
    case abntNBR15606_1Latin

    var cValue: aribcc_encoding_scheme_t {
        switch self {
        case .auto: return ARIBCC_ENCODING_SCHEME_AUTO
        case .aribStdB24JIS: return ARIBCC_ENCODING_SCHEME_ARIB_STD_B24_JIS
        case .aribStdB24UTF8: return ARIBCC_ENCODING_SCHEME_ARIB_STD_B24_UTF8
        case .abntNBR15606_1Latin: return ARIBCC_ENCODING_SCHEME_ABNT_NBR_15606_1_LATIN
        }
    }
}

/// Result of decoding one caption PES packet.
public enum ARIBCaptionResult: Sendable {
    /// A caption / superimpose was produced.
    case gotCaption(ARIBCaption)
    /// The PES did not complete a caption (e.g. a retransmission or an empty data group).
    case noCaption
    /// The PES was malformed or the decoder rejected it.
    case error
}

/// Decodes ARIB STD-B24 caption PES packets.
///
/// The decoder keeps state between calls (the caption management data and the
/// currently active language), so callers must feed PES packets for one
/// elementary stream, in order, into the same instance. Not thread-safe.
public final class ARIBCaptionDecoder {
    private let context: OpaquePointer
    private let decoder: OpaquePointer

    public let kind: ARIBCaptionKind
    public let profile: ARIBCaptionProfile
    public let encoding: ARIBCaptionEncoding

    /// - Parameters:
    ///   - type: `.caption` for 字幕 (0x80) or `.superimpose` for 文字スーパー (0x81).
    ///   - profile: A-Profile for full-segment, C-Profile for 1seg.
    ///   - encoding: Usually `.aribStdB24JIS`.
    public init(
        type: ARIBCaptionKind = .caption,
        profile: ARIBCaptionProfile = .a,
        encoding: ARIBCaptionEncoding = .aribStdB24JIS
    ) throws {
        guard let context = aribcc_context_alloc() else {
            throw ARIBCaptionError.contextUnavailable
        }
        guard let decoder = aribcc_decoder_alloc(context) else {
            aribcc_context_free(context)
            throw ARIBCaptionError.allocationFailed
        }
        guard aribcc_decoder_initialize(
            decoder,
            encoding.cValue,
            type.cValue,
            profile.cValue,
            ARIBCC_LANGUAGEID_FIRST
        ) else {
            aribcc_decoder_free(decoder)
            aribcc_context_free(context)
            throw ARIBCaptionError.initializationFailed
        }
        self.context = context
        self.decoder = decoder
        self.kind = type
        self.profile = profile
        self.encoding = encoding
    }

    deinit {
        aribcc_decoder_free(decoder)
        aribcc_context_free(context)
    }

    /// Resets the decoder's internal state. Call after a seek or a discontinuity.
    public func flush() {
        aribcc_decoder_flush(decoder)
    }

    /// Switches between the primary and secondary caption language.
    public func switchLanguage(primary: Bool) {
        aribcc_decoder_switch_language(
            decoder,
            primary ? ARIBCC_LANGUAGEID_FIRST : ARIBCC_LANGUAGEID_SECOND
        )
    }

    /// ISO 639-2 language code of a caption language, e.g. 0x006A706E for "jpn".
    public func iso6392LanguageCode(primary: Bool) -> UInt32 {
        aribcc_decoder_query_iso6392_language_code(
            decoder,
            primary ? ARIBCC_LANGUAGEID_FIRST : ARIBCC_LANGUAGEID_SECOND
        )
    }

    /// Decodes one PES payload.
    ///
    /// - Parameters:
    ///   - pes: PES data bytes starting at the caption `data_identifier`
    ///     (0x80 / 0x81), i.e. the PES header already removed.
    ///   - pts: Presentation timestamp in 90 kHz units (33-bit MPEG PTS), or
    ///     nil for superimpose PES packets without a PTS.
    public func decode(pes: Data, pts: Int64?) -> ARIBCaptionResult {
        guard !pes.isEmpty else { return .error }

        var raw = aribcc_caption_t()
        let status = pes.withUnsafeBytes { buffer -> aribcc_decode_status_t in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return ARIBCC_DECODE_STATUS_ERROR
            }
            return aribcc_decoder_decode(
                decoder,
                base,
                pes.count,
                Self.milliseconds(fromTicks: pts),
                &raw
            )
        }

        switch status {
        case ARIBCC_DECODE_STATUS_GOT_CAPTION:
            return .gotCaption(ARIBCaption(raw: raw))
        case ARIBCC_DECODE_STATUS_NO_CAPTION:
            return .noCaption
        default:
            return .error
        }
    }

    /// Decodes one PES payload whose timestamp is already in milliseconds.
    public func decode(pes: Data, ptsMilliseconds: Int64?) -> ARIBCaptionResult {
        guard !pes.isEmpty else { return .error }

        var raw = aribcc_caption_t()
        let status = pes.withUnsafeBytes { buffer -> aribcc_decode_status_t in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return ARIBCC_DECODE_STATUS_ERROR
            }
            return aribcc_decoder_decode(
                decoder,
                base,
                pes.count,
                ptsMilliseconds ?? Self.noPTS,
                &raw
            )
        }

        switch status {
        case ARIBCC_DECODE_STATUS_GOT_CAPTION:
            return .gotCaption(ARIBCaption(raw: raw))
        case ARIBCC_DECODE_STATUS_NO_CAPTION:
            return .noCaption
        default:
            return .error
        }
    }

    /// `ARIBCC_PTS_NOPTS` from caption.h.
    static let noPTS: Int64 = Int64.min
    /// `ARIBCC_DURATION_INDEFINITE` from caption.h.
    static let indefiniteDuration: Int64 = Int64.max

    /// Converts a 33-bit 90 kHz PTS into the milliseconds libaribcaption wants.
    static func milliseconds(fromTicks ticks: Int64?) -> Int64 {
        guard let ticks else { return noPTS }
        return ticks / 90
    }
}
