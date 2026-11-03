import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Maintenance API

/// MaintenanceRouter's maintenance routes.
///
/// Every run route blocks until the task finished on the real server and
/// answers 429 when the task is already running. The status routes report the
/// same tasks, including the scans the server starts on boot.
extension APIClient {

    // MARK: Logs

    /// Request for a log stream (`GET /api/maintenance/logs/{log_type}`).
    ///
    /// The response is `text/event-stream`; read it with `URLSession.bytes`
    /// and feed the bytes to `ServerSentEventParser`. `initial_log_update`
    /// carries a JSON array of every line, `log_update` a JSON string with one
    /// new line. Administrator only.
    public func maintenanceLogRequest(logType: MaintenanceLogType) -> URLRequest {
        var request = makeRequest(
            url: Endpoints.maintenanceLogs(baseURL: baseURL, logType: logType)
        )
        request.timeoutInterval = 3600
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    // MARK: Database

    /// Refreshes the channel, program and account data from the external APIs
    /// (`POST /api/maintenance/update-database`, 204).
    public func updateDatabase() async throws {
        _ = try await sendRaw(
            makeRequest(url: Endpoints.maintenance(baseURL: baseURL, path: ["update-database"]), method: "POST")
        )
    }

    // MARK: Task runs

    /// Starts a maintenance task (`POST /api/maintenance/{task}/run`, 204).
    ///
    /// - Parameter kind: The task to start.
    public func runMaintenanceTask(_ kind: MaintenanceTaskKind) async throws {
        var request = makeRequest(
            url: Endpoints.maintenance(
                baseURL: baseURL,
                path: [kind.pathComponent, "run"]
            ),
            method: "POST"
        )
        // Batch scans can take hours; the web client allows a day.
        request.timeoutInterval = 24 * 60 * 60
        _ = try await sendRaw(request)
    }

    /// Progress of a maintenance task
    /// (`GET /api/maintenance/{task}/status`).
    public func maintenanceTaskStatus(_ kind: MaintenanceTaskKind) async throws -> MaintenanceTaskStatus {
        try await perform(
            makeRequest(
                url: Endpoints.maintenance(
                    baseURL: baseURL,
                    path: [kind.pathComponent, "status"]
                )
            ),
            as: MaintenanceTaskStatus.self
        )
    }

    // MARK: Server control

    /// Restarts the server (`POST /api/maintenance/restart`, 204).
    public func restartServer() async throws {
        _ = try await sendRaw(
            makeRequest(url: Endpoints.maintenance(baseURL: baseURL, path: ["restart"]), method: "POST")
        )
    }

    /// Shuts the server down (`POST /api/maintenance/shutdown`, 204).
    public func shutdownServer() async throws {
        _ = try await sendRaw(
            makeRequest(url: Endpoints.maintenance(baseURL: baseURL, path: ["shutdown"]), method: "POST")
        )
    }
}
