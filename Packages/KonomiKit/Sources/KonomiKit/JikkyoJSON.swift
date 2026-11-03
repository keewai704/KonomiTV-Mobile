import Foundation

/// Builds the compact JSON strings the jikkyo WebSocket protocols expect.
///
/// `JSONEncoder` cannot be used for this: the web client sends hand written
/// objects whose key order and omitted-key behaviour are part of the protocol
/// (e.g. `JSON.stringify` drops `undefined` values, so an unknown comment
/// colour is simply not sent), and the messages are tiny enough that building
/// them directly is the clearest option.
enum JikkyoJSON {

    /// A JSON string literal, escaped like `JSON.stringify` does it: only the
    /// quote, the backslash and the control characters are escaped, everything
    /// else is emitted as UTF-8.
    static func string(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{08}": result += "\\b"
            case "\u{09}": result += "\\t"
            case "\u{0A}": result += "\\n"
            case "\u{0C}": result += "\\f"
            case "\u{0D}": result += "\\r"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }

    /// A JSON number for an integer value.
    static func number(_ value: Int) -> String {
        String(value)
    }

    static func bool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    /// `{"key":value,...}` with the given key order; values must already be
    /// JSON text (use `string`, `number`, `bool`, `object` or `array`).
    static func object(_ members: [(String, String)]) -> String {
        "{" + members.map { string($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
    }

    static func array(_ elements: [String]) -> String {
        "[" + elements.joined(separator: ",") + "]"
    }
}
