import Foundation
import Observation
import KonomiKit

/// Top level navigation sections of the app.
enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case live
    case videos
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "テレビ"
        case .videos: return "ビデオ"
        case .settings: return "設定"
        }
    }

    var systemImage: String {
        switch self {
        case .live: return "tv"
        case .videos: return "film.stack"
        case .settings: return "gearshape"
        }
    }
}

/// `UserDefaults` keys shared by the views' `@AppStorage` properties.
enum PreferenceKeys {
    static let serverURL = "serverURL"
    static let liveQuality = "liveQuality"
    static let videoQuality = "videoQuality"
}

/// Application wide state: configured server, session user and navigation.
@MainActor
@Observable
final class AppModel {
    private(set) var serverURL: URL?
    private(set) var version: VersionInfo?
    private(set) var user: User?
    private(set) var token: String?

    var section: AppSection = .live

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: PreferenceKeys.serverURL),
           let url = try? ServerURL(validating: raw).url {
            self.serverURL = url
        }
        self.token = KeychainStore.read(account: KeychainStore.tokenAccount)
    }

    var isConfigured: Bool { serverURL != nil }

    var serverURLString: String { serverURL?.absoluteString ?? "" }

    /// Client for the configured server, including the bearer token when the
    /// user is logged in.
    var client: APIClient? {
        guard let serverURL else { return nil }
        return APIClient(baseURL: serverURL, token: token)
    }

    // MARK: - Server

    /// Validates the URL, probes `/api/version` and stores the server on
    /// success.
    func connect(rawURL: String) async throws {
        let url = try ServerURL(validating: rawURL).url
        let probe = APIClient(baseURL: url, token: token)
        let info = try await probe.version()
        serverURL = url
        version = info
        defaults.set(url.absoluteString, forKey: PreferenceKeys.serverURL)
    }

    func refreshVersion() async {
        guard let client else { return }
        version = try? await client.version()
    }

    func disconnect() {
        logout()
        defaults.removeObject(forKey: PreferenceKeys.serverURL)
        serverURL = nil
        version = nil
        section = .live
    }

    // MARK: - Session

    /// Restores the saved version information and, when a token is present,
    /// the logged in user.
    func restoreSession() async {
        guard let client else { return }
        if version == nil {
            version = try? await client.version()
        }
        if user == nil, let token, !token.isEmpty {
            user = try? await client.withToken(token).me()
        }
    }

    func login(username: String, password: String) async throws {
        guard let client else { throw APIError.invalidServerURL }
        let result = try await client.login(username: username, password: password)
        guard !result.accessToken.isEmpty else { throw APIError.invalidResponse }

        token = result.accessToken
        KeychainStore.save(result.accessToken, account: KeychainStore.tokenAccount)
        user = try await client.withToken(result.accessToken).me()
    }

    func logout() {
        token = nil
        user = nil
        KeychainStore.delete(account: KeychainStore.tokenAccount)
    }
}
