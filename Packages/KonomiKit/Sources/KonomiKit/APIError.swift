import Foundation

public enum APIError: Error, Equatable, Sendable, LocalizedError {
    /// The server URL is missing or malformed.
    case invalidServerURL
    /// The transport returned something that is not an HTTP response.
    case invalidResponse
    /// The request could not reach the server.
    case network(String)
    /// The server returned a non-2xx status code.
    case httpStatus(Int, String?)
    /// The server returned 401 Unauthorized.
    case unauthorized(String?)
    /// The server response could not be decoded.
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "サーバーのURLが正しくありません。"
        case .invalidResponse:
            return "サーバーから正しい応答がありませんでした。"
        case .network:
            return "サーバーに接続できませんでした。ネットワーク接続を確認してください。"
        case .httpStatus(let code, _):
            return "サーバーでエラーが発生しました（HTTP \(code)）。"
        case .unauthorized:
            return "認証に失敗しました。ユーザー名とパスワードを確認してください。"
        case .decoding:
            return "サーバーの応答を読み取れませんでした。"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .network(let detail), .decoding(let detail):
            return detail.isEmpty ? nil : detail
        case .httpStatus(_, let detail), .unauthorized(let detail):
            guard let detail, !detail.isEmpty else { return nil }
            return detail
        case .invalidServerURL, .invalidResponse:
            return nil
        }
    }

    /// The HTTP status code, when the failure came from an HTTP response.
    public var statusCode: Int? {
        switch self {
        case .httpStatus(let code, _):
            return code
        case .unauthorized:
            return 401
        case .invalidServerURL, .invalidResponse, .network, .decoding:
            return nil
        }
    }
}
