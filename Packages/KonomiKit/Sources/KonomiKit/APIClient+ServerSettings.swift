import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Server settings API

/// SettingsRouter's server settings routes.
extension APIClient {

    /// The settings of the running server (`GET /api/settings/server`).
    ///
    /// The route is anonymous on the server (the web client reads it before
    /// checking the administrator flag), so it is sent without a token too.
    public func serverSettings() async throws -> ServerSettings {
        try await perform(
            makeRequest(url: Endpoints.serverSettings(baseURL: baseURL), authorized: false),
            as: ServerSettings.self
        )
    }

    /// Writes the settings to config.yaml (`PUT /api/settings/server`, 204).
    ///
    /// Administrator only. The server validates the whole body and answers
    /// 422 when a path does not exist or a URL cannot be reached, so the
    /// changes only take effect after a restart.
    public func updateServerSettings(_ settings: ServerSettings) async throws {
        let request = try makeEncodedRequest(
            path: ["settings", "server"],
            method: "PUT",
            body: settings
        )
        _ = try await sendRaw(request)
    }
}
