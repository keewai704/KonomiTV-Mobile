import Foundation

/// Builds a multipart/form-data body.
///
/// The web client uploads a capture with one file part named "image" (and an
/// optional "file_modified_at" text field for local files), so the server
/// expects exactly that. The builder is kept separate from APIClient so tests
/// can assert the produced bytes.
public struct MultipartFormData: Sendable {
    public struct Part: Sendable, Hashable {
        public var name: String
        public var filename: String?
        public var contentType: String?
        public var data: Data
    }

    public let boundary: String

    private var parts: [Part] = []

    /// - Parameter boundary: override for tests; by default a random boundary
    ///   that cannot appear in the payload.
    public init(boundary: String = MultipartFormData.makeBoundary()) {
        self.boundary = boundary
    }

    public static func makeBoundary() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        return "KonomiTVBoundary-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The Content-Type header value, including the boundary.
    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public var partsForTesting: [Part] { parts }

    /// Appends a plain text field.
    public mutating func addField(name: String, value: String) {
        parts.append(
            Part(
                name: Self.escapeName(name),
                filename: nil,
                contentType: nil,
                data: Data(value.utf8)
            )
        )
    }

    /// Appends a file part with its filename and content type.
    public mutating func addFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data
    ) {
        parts.append(
            Part(
                name: Self.escapeName(name),
                filename: Self.escapeName(filename),
                contentType: contentType,
                data: data
            )
        )
    }

    /// Serialises the body. Every part is preceded by its boundary line and the
    /// body ends with the closing boundary.
    public func encoded() -> Data {
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let filename = part.filename {
                disposition += "; filename=\"\(filename)\""
            }
            body.append(Data((disposition + "\r\n").utf8))
            if let contentType = part.contentType {
                body.append(Data("Content-Type: \(contentType)\r\n".utf8))
            }
            body.append(Data("\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// Quotes and line breaks would break the header; replace them instead of
    /// dropping the part.
    private static func escapeName(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"", "\\":
                escaped.append("_")
            case "\r", "\n":
                escaped.append("_")
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}
