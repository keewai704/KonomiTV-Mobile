import Foundation

public enum ServerURLError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case unsupportedScheme(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "サーバーのURLを入力してください。"
        case .unsupportedScheme(let scheme):
            return "「\(scheme)」は使用できません。http または https のURLを入力してください。"
        case .invalid(let value):
            return "サーバーのURLが正しくありません（\(value)）。"
        }
    }
}

/// A validated KonomiTV server base URL.
///
/// Normalisation rules:
/// - surrounding whitespace is removed
/// - `https://` is added when no scheme is given
/// - only `http` and `https` are accepted
/// - trailing `/` characters are removed
/// - query strings and fragments are rejected
public struct ServerURL: Hashable, Sendable, CustomStringConvertible {
    public let url: URL

    public init(validating rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServerURLError.empty
        }

        var candidate = trimmed
        if trimmed.range(of: "://") == nil {
            candidate = "https://" + trimmed
        }

        guard !candidate.contains(where: { $0.isWhitespace }) else {
            throw ServerURLError.invalid(trimmed)
        }

        guard let separator = candidate.range(of: "://") else {
            throw ServerURLError.invalid(trimmed)
        }
        let scheme = String(candidate[candidate.startIndex..<separator.lowerBound]).lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw ServerURLError.unsupportedScheme(scheme)
        }

        while candidate.hasSuffix("/") {
            candidate.removeLast()
        }

        guard
            let parsed = URL(string: candidate),
            let host = parsed.host,
            !host.isEmpty,
            parsed.query == nil,
            parsed.fragment == nil
        else {
            throw ServerURLError.invalid(trimmed)
        }

        var normalized = parsed
        if var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) {
            components.scheme = scheme
            if let value = components.url {
                normalized = value
            }
        }

        self.url = normalized
    }

    public init?(_ rawValue: String) {
        try? self.init(validating: rawValue)
    }

    public static func normalize(_ rawValue: String) throws -> URL {
        try ServerURL(validating: rawValue).url
    }

    public var absoluteString: String {
        url.absoluteString
    }

    /// The URL of the API root (`<server>/api`).
    public var apiURL: URL {
        url.appendingPathComponent("api")
    }

    public var description: String {
        absoluteString
    }
}
