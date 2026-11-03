import Foundation

// MARK: - JSONValue

/// A dynamically typed JSON value.
///
/// Used where the client has to keep a JSON object intact even when it does not
/// understand every key (client settings sync). Numbers are stored as
/// `Double`; integers round-trip as integers because JSON encoders emit `50` for
/// `50.0`.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    // MARK: Convenience accessors

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// A short name for the kind of value, useful in diagnostics.
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// Reads a nested value at `key`.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    // MARK: Codable bridging

    /// Decodes the value into a concrete type through the shared KonomiTV JSON
    /// decoder.
    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONCoding.encode(self) else { return nil }
        return try? JSONCoding.decode(type, from: data)
    }

    /// Converts any encodable value into a `JSONValue`.
    public static func encode<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? JSONCoding.encode(value) else { return nil }
        return try? JSONCoding.decode(JSONValue.self, from: data)
    }

    /// `true` when the value is an object with no keys, an array with no
    /// elements, or null (mirrors the web client's falsy/empty semantics only
    /// where it matters for settings).
    public var isEmpty: Bool {
        switch self {
        case .null: return true
        case .array(let value): return value.isEmpty
        case .object(let value): return value.isEmpty
        case .string(let value): return value.isEmpty
        default: return false
        }
    }
}
