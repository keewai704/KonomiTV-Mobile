import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import KonomiKit

// MARK: - Helpers

/// Transport that records the requests and answers with a fixed body.
actor AccountTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    private let handler: Handler
    private var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try handler(request)
    }

    func recordedRequests() -> [URLRequest] { requests }
    func lastRequest() -> URLRequest? { requests.last }
}

private let accountBaseURL = URL(string: "http://127.0.0.1:7010")!

private func accountResponse(
    for request: URLRequest,
    body: String = "{}",
    status: Int = 200,
    headers: [String: String] = ["Content-Type": "application/json"]
) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? accountBaseURL,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
    return (Data(body.utf8), response)
}

private func accountNoContent(for request: URLRequest) -> (Data, HTTPURLResponse) {
    accountResponse(for: request, body: "", status: 204, headers: [:])
}

private func accountJSONBody(_ request: URLRequest) throws -> [String: Any] {
    let body = try XCTUnwrap(request.httpBody)
    let object = try JSONSerialization.jsonObject(with: body)
    return try XCTUnwrap(object as? [String: Any])
}

private let accountUserJSON = """
{
  "id": 3,
  "name": "新しいユーザー",
  "is_admin": false,
  "niconico_user_id": null,
  "niconico_user_name": null,
  "niconico_user_premium": null,
  "twitter_accounts": [],
  "bluesky_accounts": [],
  "account_links": [],
  "created_at": "2026-11-04T12:00:00+09:00",
  "updated_at": "2026-11-04T12:00:00+09:00"
}
"""

// MARK: - Tests

final class AccountAPITests: XCTestCase {

    func testCreateUserPostsAnonymously() async throws {
        let transport = AccountTransport { request in
            XCTAssertEqual(request.url?.path, "/api/users")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try accountJSONBody(request)
            XCTAssertEqual(body["username"] as? String, "new-user")
            XCTAssertEqual(body["password"] as? String, "secret")
            return accountResponse(for: request, body: accountUserJSON, status: 201)
        }
        // A token is set on purpose: registration must not send it.
        let client = APIClient(baseURL: accountBaseURL, transport: transport, token: "token")
        let user = try await client.createUser(username: "new-user", password: "secret")
        XCTAssertEqual(user.id, 3)
        XCTAssertEqual(user.name, "新しいユーザー")
        XCTAssertFalse(user.isAdmin)
    }

    func testUpdateUserSendsOnlyGivenFields() async throws {
        let transport = AccountTransport { request in
            XCTAssertEqual(request.url?.path, "/api/users/me")
            XCTAssertEqual(request.httpMethod, "PUT")
            let body = try accountJSONBody(request)
            XCTAssertEqual(body.count, 1)
            XCTAssertEqual(body["password"] as? String, "new-password")
            return accountNoContent(for: request)
        }
        let client = APIClient(baseURL: accountBaseURL, transport: transport, token: "token")
        try await client.updateUser(password: "new-password")
    }

    func testAdminUserRoutes() async throws {
        let transport = AccountTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/users"):
                return accountResponse(for: request, body: "[\(accountUserJSON)]")
            case ("PUT", "/api/users/viewer"):
                let body = try accountJSONBody(request)
                XCTAssertEqual(body["is_admin"] as? Bool, true)
                return accountNoContent(for: request)
            case ("DELETE", "/api/users/viewer"):
                return accountNoContent(for: request)
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return accountNoContent(for: request)
            }
        }
        let client = APIClient(baseURL: accountBaseURL, transport: transport, token: "token")
        let users = try await client.users()
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?.name, "新しいユーザー")

        try await client.updateUserAsAdmin(username: "viewer", isAdmin: true)
        try await client.deleteUser(username: "viewer")
    }

    func testIconDownloadAndMultipartUpload() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let transport = AccountTransport { request in
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, "/api/users/me/icon")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                let response = HTTPURLResponse(
                    url: request.url ?? accountBaseURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/png"]
                )!
                return (png, response)
            }
            XCTAssertEqual(request.url?.path, "/api/users/me/icon")
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertTrue(
                (request.value(forHTTPHeaderField: "Content-Type") ?? "")
                    .hasPrefix("multipart/form-data; boundary=")
            )
            let body = try XCTUnwrap(request.httpBody)
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"image\""))
            XCTAssertTrue(text.contains("filename=\"icon.png\""))
            XCTAssertTrue(text.contains("Content-Type: image/png"))
            return accountNoContent(for: request)
        }
        let client = APIClient(baseURL: accountBaseURL, transport: transport, token: "token")
        let data = try await client.userIcon()
        XCTAssertEqual(data, png)
        try await client.updateUserIcon(image: png)
    }

    func testDeleteOwnAccount() async throws {
        let transport = AccountTransport { request in
            XCTAssertEqual(request.url?.path, "/api/users/me")
            XCTAssertEqual(request.httpMethod, "DELETE")
            return accountNoContent(for: request)
        }
        let client = APIClient(baseURL: accountBaseURL, transport: transport, token: "token")
        try await client.deleteUser()
    }

    // MARK: Server settings

    func testServerSettingsDecodeFillsMissingSections() async throws {
        let transport = AccountTransport { request in
            XCTAssertEqual(request.url?.path, "/api/settings/server")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = """
            {
              "general": {
                "backend": "Mirakurun",
                "edcb_url": "tcp://192.168.1.10:4510/",
                "encoder": "QSVEncC",
                "program_update_interval": 2.5
              },
              "server": {"port": 7001},
              "video": {"recorded_folders": ["/record"]}
            }
            """
            return accountResponse(for: request, body: body)
        }
        let client = APIClient(baseURL: accountBaseURL, transport: transport)
        let settings = try await client.serverSettings()
        XCTAssertEqual(settings.general.backend, .mirakurun)
        XCTAssertEqual(settings.general.encoder, .qsv)
        XCTAssertEqual(settings.general.programUpdateInterval, 2.5)
        XCTAssertEqual(settings.general.edcbURL, "tcp://192.168.1.10:4510/")
        XCTAssertEqual(settings.server.port, 7001)
        XCTAssertEqual(settings.video.recordedFolders, ["/record"])
        XCTAssertEqual(settings.tv.maxAliveTime, 10)
        XCTAssertNil(settings.tv.preferredTerrestrialRegion)
        XCTAssertEqual(settings.capture.uploadFolders, [])
    }

    func testServerSettingsSaveSendsEverySection() async throws {
        let transport = AccountTransport { request in
            XCTAssertEqual(request.url?.path, "/api/settings/server")
            XCTAssertEqual(request.httpMethod, "PUT")
            let body = try accountJSONBody(request)
            XCTAssertNotNil(body["general"])
            XCTAssertNotNil(body["server"])
            XCTAssertNotNil(body["tv"])
            XCTAssertNotNil(body["video"])
            let capture = try XCTUnwrap(body["capture"] as? [String: Any])
            XCTAssertNotNil(capture["upload_folders"])
            XCTAssertNotNil(capture["upload_folders_polling_interval"])
            return accountNoContent(for: request)
        }
        var settings = ServerSettings()
        settings.capture.uploadFolders = ["/capture"]
        settings.capture.uploadFoldersPollingInterval = 3
        settings.server.customHTTPSCertificate = ""
        settings.normalizeOptionalPaths()
        XCTAssertNil(settings.server.customHTTPSCertificate)

        let client = APIClient(baseURL: accountBaseURL, transport: transport, token: "token")
        try await client.updateServerSettings(settings)
    }

    func testServerSettingsValidation() {
        var settings = ServerSettings()
        XCTAssertNil(settings.validationError())

        settings.server.port = 80
        XCTAssertNotNil(settings.validationError())
        settings.server.port = 7000

        settings.general.programUpdateInterval = 0
        XCTAssertNotNil(settings.validationError())
        settings.general.programUpdateInterval = 5

        settings.video.recordedFoldersPollingInterval = 0.05
        XCTAssertNotNil(settings.validationError())
        settings.video.recordedFoldersPollingInterval = 5

        settings.general.edcbURL = "http://127.0.0.1:4510/"
        XCTAssertNotNil(settings.validationError())
        settings.general.edcbURL = "tcp://127.0.0.1:4510/"

        settings.general.backend = .mirakurun
        settings.general.mirakurunURL = "tcp://127.0.0.1:40772/"
        XCTAssertNotNil(settings.validationError())
    }

    // MARK: Maintenance

    func testMaintenanceTaskStatusDecoding() throws {
        let json = """
        {"is_running": true, "processed_count": 3, "total_count": 8, "has_registered_files": true}
        """
        let status = try JSONCoding.decode(MaintenanceTaskStatus.self, from: json)
        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.processedCount, 3)
        XCTAssertEqual(status.totalCount, 8)
        XCTAssertTrue(status.hasRegisteredFiles)
        XCTAssertEqual(status.progressText, "3 / 8 件")
        XCTAssertEqual(status.fractionCompleted ?? 0, 3.0 / 8.0, accuracy: 0.0001)

        let empty = try JSONCoding.decode(MaintenanceTaskStatus.self, from: "{}")
        XCTAssertFalse(empty.isRunning)
        XCTAssertEqual(empty.progressText, "0 件")
        XCTAssertNil(empty.fractionCompleted)
    }

    func testMaintenanceRunAndStatusRoutes() async throws {
        let transport = AccountTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/status") {
                return accountResponse(
                    for: request,
                    body: "{\"is_running\": true, \"processed_count\": 1, \"total_count\": 2}"
                )
            }
            XCTAssertEqual(request.httpMethod, "POST")
            return accountNoContent(for: request)
        }
        let client = APIClient(baseURL: accountBaseURL, transport: transport, token: "token")

        for kind in MaintenanceTaskKind.allCases {
            try await client.runMaintenanceTask(kind)
            let status = try await client.maintenanceTaskStatus(kind)
            XCTAssertTrue(status.isRunning)
            XCTAssertEqual(status.processedCount, 1)
        }

        try await client.updateDatabase()
        try await client.restartServer()
        try await client.shutdownServer()

        let paths = await transport.recordedRequests().compactMap(\.url?.path)
        XCTAssertTrue(paths.contains("/api/maintenance/update-database"))
        XCTAssertTrue(paths.contains("/api/maintenance/restart"))
        XCTAssertTrue(paths.contains("/api/maintenance/shutdown"))
        XCTAssertTrue(paths.contains("/api/maintenance/batch-scan/run"))
        XCTAssertTrue(paths.contains("/api/maintenance/capture-scan/status"))
    }

    func testMaintenanceLogRequestCarriesStreamHeaders() {
        let client = APIClient(baseURL: accountBaseURL, token: "token")
        let request = client.maintenanceLogRequest(logType: .access)
        XCTAssertEqual(request.url?.path, "/api/maintenance/logs/access")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    // MARK: Version / genres / account rules

    func testVersionUpdateAvailability() {
        XCTAssertTrue(VersionInfo(version: "v2.7.0", latestVersion: "v2.8.0").isUpdateAvailable)
        XCTAssertFalse(VersionInfo(version: "v2.8.0", latestVersion: "v2.8.0").isUpdateAvailable)
        XCTAssertFalse(VersionInfo(version: "v2.8.0", latestVersion: nil).isUpdateAvailable)
        XCTAssertTrue(
            VersionInfo(version: "v2.8.0-dev", latestVersion: "v2.8.0").isUpdateAvailable
        )
        XCTAssertFalse(
            VersionInfo(version: "v2.8.0-dev", latestVersion: "v2.9.0").isUpdateAvailable
        )
    }

    func testProgramGenreCatalogMatchesTheWebClient() {
        XCTAssertEqual(ProgramGenreCatalog.categories.count, 14)
        XCTAssertEqual(ProgramGenreCatalog.categories.first?.major, "ニュース・報道")
        XCTAssertTrue(
            ProgramGenreCatalog.middles(of: "ニュース・報道").contains("定時・総合")
        )
        XCTAssertEqual(ProgramGenreCatalog.middles(of: "不明"), [])
    }

    func testAccountRules() {
        XCTAssertNil(AccountRules.usernameError("ab"))
        XCTAssertNotNil(AccountRules.usernameError("a"))
        XCTAssertNotNil(AccountRules.usernameError("ME"))
        XCTAssertNotNil(AccountRules.passwordError("abc"))
        XCTAssertNil(AccountRules.passwordError("abcd"))
        XCTAssertNotNil(AccountRules.passwordError("パスワード"))
        XCTAssertNotNil(AccountRules.passwordError("ab c"))
        XCTAssertNil(AccountRules.passwordError("ab!c"))
    }
}
