import Foundation
import CAribCaption

/// An 8-bit-per-channel RGBA colour as used by ARIB STD-B24.
public struct ARIBCaptionColor: Sendable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(raw: UInt32) {
        red = UInt8(raw & 0xFF)
        green = UInt8((raw >> 8) & 0xFF)
        blue = UInt8((raw >> 16) & 0xFF)
        alpha = UInt8((raw >> 24) & 0xFF)
    }
}

/// Kind of character stored in a caption region.
public enum ARIBCaptionCharacterType: Sendable, Hashable {
    case text
    case drcs
    case drcsReplaced
}

/// One character of a caption region, with the geometry and colours needed to
/// render it without going back to the C structure.
public struct ARIBCaptionCharacter: Sendable, Hashable {
    public let type: ARIBCaptionCharacterType
    /// Unicode code point. 0 for a DRCS character.
    public let codePoint: UInt32
    /// Private Use Area code point, when the library provides one.
    public let puaCodePoint: UInt32
    /// DRCS code, valid for `.drcs` / `.drcsReplaced`.
    public let drcsCode: UInt32
    /// UTF-8 representation, empty for DRCS characters without an alternative.
    public let utf8: String

    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let horizontalSpacing: Int
    public let verticalSpacing: Int
    public let horizontalScale: Float
    public let verticalScale: Float

    public let textColor: ARIBCaptionColor
    public let backgroundColor: ARIBCaptionColor
    public let strokeColor: ARIBCaptionColor
    public let isBold: Bool
    public let isItalic: Bool
    public let isUnderline: Bool
    public let isStroke: Bool
    public let enclosureStyle: UInt32
}

/// One caption region (a block of text on the caption plane).
public struct ARIBCaptionRegion: Sendable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// True when the region is likely furigana (ruby text).
    public let isRuby: Bool
    public let characters: [ARIBCaptionCharacter]

    /// Text of this region, excluding ruby regions.
    public var text: String {
        characters.map(\.utf8).joined()
    }
}

/// A decoded ARIB caption / superimpose.
///
/// This wraps the `aribcc_caption_t` returned by the decoder and frees its
/// buffers in `deinit`. All public properties are immutable snapshots taken in
/// `init`, so sharing an instance between threads is safe; the C structure is
/// only freed once, when the last reference is released.
public final class ARIBCaption: @unchecked Sendable {
    private var raw: aribcc_caption_t

    /// Presentation timestamp in milliseconds, or nil when the PES had no PTS.
    public let ptsMilliseconds: Int64?
    /// Duration in milliseconds, or nil when the caption lasts until the next
    /// caption (ARIBCC_DURATION_INDEFINITE).
    public let waitDurationMilliseconds: Int64?
    /// True when the renderer should clear the screen before presenting this caption.
    public let isClearScreen: Bool
    /// True when the caption lasts until the next caption's PTS.
    public var isDurationIndefinite: Bool {
        waitDurationMilliseconds == nil
    }
    public let flags: UInt32
    /// Plain UTF-8 text of the caption. Ruby text is excluded by the library.
    public let text: String
    /// ISO 639-2 language code, e.g. 0x006A706E for "jpn". 0 when unknown.
    public let iso6392LanguageCode: UInt32
    /// Logical caption plane size (typically 960x540 or 720x480).
    public let planeWidth: Int
    public let planeHeight: Int
    public let regions: [ARIBCaptionRegion]
    public let hasBuiltinSound: Bool
    public let builtinSoundID: UInt8

    init(raw: aribcc_caption_t) {
        self.raw = raw

        if raw.pts == ARIBCaptionDecoder.noPTS {
            ptsMilliseconds = nil
        } else {
            ptsMilliseconds = raw.pts
        }
        if raw.wait_duration == ARIBCaptionDecoder.indefiniteDuration {
            waitDurationMilliseconds = nil
        } else {
            waitDurationMilliseconds = raw.wait_duration
        }

        flags = UInt32(raw.flags.rawValue)
        isClearScreen = (flags & UInt32(ARIBCC_CAPTIONFLAGS_CLEARSCREEN.rawValue)) != 0
        iso6392LanguageCode = raw.iso6392_language_code
        planeWidth = Int(raw.plane_width)
        planeHeight = Int(raw.plane_height)
        hasBuiltinSound = raw.has_builtin_sound
        builtinSoundID = raw.builtin_sound_id
        text = raw.text.map { String(cString: $0) } ?? ""

        var regions: [ARIBCaptionRegion] = []
        if let rawRegions = raw.regions {
            regions.reserveCapacity(Int(raw.region_count))
            for regionIndex in 0..<Int(raw.region_count) {
                let region = rawRegions[regionIndex]
                var characters: [ARIBCaptionCharacter] = []
                if let rawCharacters = region.chars {
                    characters.reserveCapacity(Int(region.char_count))
                    for characterIndex in 0..<Int(region.char_count) {
                        characters.append(Self.character(from: rawCharacters[characterIndex]))
                    }
                }
                regions.append(ARIBCaptionRegion(
                    x: Int(region.x),
                    y: Int(region.y),
                    width: Int(region.width),
                    height: Int(region.height),
                    isRuby: region.is_ruby,
                    characters: characters
                ))
            }
        }
        self.regions = regions
    }

    deinit {
        aribcc_caption_cleanup(&raw)
    }

    /// The C structure, for passing to `aribcc_renderer_append_caption()`.
    var rawCaption: aribcc_caption_t {
        raw
    }

    /// Region texts joined by newlines, excluding ruby regions.
    public var plainText: String {
        let lines = regions.filter { !$0.isRuby }.map(\.text).filter { !$0.isEmpty }
        return lines.isEmpty ? text : lines.joined(separator: "\n")
    }

    private static func character(from c: aribcc_caption_char_t) -> ARIBCaptionCharacter {
        var utf8Field = c.u8str
        let bytes = withUnsafeBytes(of: &utf8Field) { Array($0) }
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        let utf8 = String(decoding: bytes[..<end], as: UTF8.self)

        let type: ARIBCaptionCharacterType
        switch c.type.rawValue {
        case UInt32(ARIBCC_CHARTYPE_DRCS.rawValue): type = .drcs
        case UInt32(ARIBCC_CHARTYPE_DRCS_REPLACED.rawValue): type = .drcsReplaced
        default: type = .text
        }

        let style = c.style.rawValue
        return ARIBCaptionCharacter(
            type: type,
            codePoint: c.codepoint,
            puaCodePoint: c.pua_codepoint,
            drcsCode: c.drcs_code,
            utf8: utf8,
            x: Int(c.x),
            y: Int(c.y),
            width: Int(c.char_width),
            height: Int(c.char_height),
            horizontalSpacing: Int(c.char_horizontal_spacing),
            verticalSpacing: Int(c.char_vertical_spacing),
            horizontalScale: c.char_horizontal_scale,
            verticalScale: c.char_vertical_scale,
            textColor: ARIBCaptionColor(raw: c.text_color),
            backgroundColor: ARIBCaptionColor(raw: c.back_color),
            strokeColor: ARIBCaptionColor(raw: c.stroke_color),
            isBold: (style & UInt32(ARIBCC_CHARSTYLE_BOLD.rawValue)) != 0,
            isItalic: (style & UInt32(ARIBCC_CHARSTYLE_ITALIC.rawValue)) != 0,
            isUnderline: (style & UInt32(ARIBCC_CHARSTYLE_UNDERLINE.rawValue)) != 0,
            isStroke: (style & UInt32(ARIBCC_CHARSTYLE_STROKE.rawValue)) != 0,
            enclosureStyle: c.enclosure_style.rawValue
        )
    }
}
