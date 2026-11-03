import Foundation
import KonomiKit

/// Turns any `Error` into a Japanese message suitable for the UI.
enum ErrorText {
    static func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            let base = apiError.errorDescription ?? "サーバーでエラーが発生しました。"
            if let suggestion = apiError.recoverySuggestion, !suggestion.isEmpty {
                return "\(base)\n\(suggestion)"
            }
            return base
        }
        if let serverError = error as? ServerURLError, let description = serverError.errorDescription {
            return description
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
