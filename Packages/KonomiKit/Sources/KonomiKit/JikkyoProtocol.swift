import Foundation

// MARK: - Errors

/// Something was wrong with a jikkyo protocol message.
public enum JikkyoProtocolError: Error, Sendable, Hashable {
    /// The WebSocket text frame was not valid UTF-8.
    case invalidUTF8
    /// The JSON payload was not an object.
    case notAnObject
    /// The JSON object had no usable `type` field.
    case missingType
}

// MARK: - Shared decoding helpers

/// Small helpers shared by the two jikkyo protocols. Everything is pure so the
/// whole protocol layer can be unit tested without a socket.
enum JikkyoProtocol {

    static func decodeObject(_ data: Data) throws -> [String: JSONValue] {
        let value: JSONValue
        do {
            value = try JSONCoding.decode(JSONValue.self, from: data)
        } catch {
            throw JikkyoProtocolError.notAnObject
        }
        guard let object = value.objectValue else {
            throw JikkyoProtocolError.notAnObject
        }
        return object
    }

    static func decodeObject(_ text: String) throws -> [String: JSONValue] {
        guard let data = text.data(using: .utf8) else {
            throw JikkyoProtocolError.invalidUTF8
        }
        return try decodeObject(data)
    }

    /// `vposBaseTime` is an ISO 8601 timestamp; a few servers send a UNIX
    /// timestamp in milliseconds instead, so both are accepted.
    static func date(from value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if let string = value.stringValue {
            return JSONCoding.parseISO8601(string)
        }
        if let milliseconds = value.numberValue, milliseconds > 0 {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return nil
    }

    /// Niconico's `premium` flag arrives as a number or as a string, and the
    /// web client compares its string form with "3" (運営コメント), so a
    /// canonical string is all that is needed here.
    static func premiumText(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .number(let number):
            return String(Int(number))
        case .string(let string):
            return string
        case .bool(let flag):
            return flag ? "true" : "false"
        default:
            return nil
        }
    }
}
