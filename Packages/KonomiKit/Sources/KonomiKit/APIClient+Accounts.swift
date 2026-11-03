import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Accounts API

/// The account routes of UsersRouter.
///
/// `POST /api/users` and `POST /api/users/token` are anonymous; everything
/// else needs the bearer token. The list and the routes with a username are
/// administrator only.
extension APIClient {

    // MARK: Registration / session

    /// Creates an account (`POST /api/users`, 201).
    ///
    /// The first account on a server becomes the administrator; the server
    /// decides that. The route is anonymous, like the web client's register
    /// screen.
    public func createUser(username: String, password: String) async throws -> User {
        let request = try makeEncodedRequest(
            path: ["users"],
            method: "POST",
            body: UserCreateRequest(username: username, password: password),
            authorized: false
        )
        return try await perform(request, as: User.self)
    }

    // MARK: Current account

    /// Changes the logged in account's name and/or password
    /// (`PUT /api/users/me`, 204).
    ///
    /// Omitted fields are left untouched by the server.
    public func updateUser(username: String? = nil, password: String? = nil) async throws {
        let request = try makeEncodedRequest(
            path: ["users", "me"],
            method: "PUT",
            body: UserUpdateRequest(username: username, password: password)
        )
        _ = try await sendRaw(request)
    }

    /// Downloads the avatar of the logged in account (or of `username`).
    ///
    /// Both routes answer a PNG; the server sends the default avatar when the
    /// account never uploaded one. The image needs the bearer token, so it is
    /// fetched through the transport instead of an `AsyncImage` URL.
    public func userIcon(username: String? = nil) async throws -> Data {
        let (data, _) = try await sendRaw(
            makeRequest(url: Endpoints.userIcon(baseURL: baseURL, username: username))
        )
        return data
    }

    /// Uploads an avatar (`PUT /api/users/me/icon`, 204).
    ///
    /// The file field is named `image`, and the server only accepts
    /// `image/jpeg` and `image/png`.
    public func updateUserIcon(
        image: Data,
        contentType: String = "image/png"
    ) async throws {
        var form = MultipartFormData()
        let fileExtension = contentType == "image/jpeg" ? "jpg" : "png"
        form.addFile(
            name: "image",
            filename: "icon.\(fileExtension)",
            contentType: contentType,
            data: image
        )
        var request = makeRequest(
            url: Endpoints.userIconUpdate(baseURL: baseURL),
            method: "PUT",
            body: form.encoded(),
            contentType: form.contentType
        )
        request.timeoutInterval = 60
        _ = try await sendRaw(request)
    }

    /// Deletes the logged in account (`DELETE /api/users/me`, 204).
    ///
    /// The access token stops working immediately, so the caller logs out.
    public func deleteUser() async throws {
        _ = try await sendRaw(makeRequest(path: ["users", "me"], method: "DELETE"))
    }

    // MARK: Administration

    /// Every account of the server (`GET /api/users`, administrator only).
    public func users() async throws -> [User] {
        try await perform(makeRequest(path: ["users"]), as: [User].self)
    }

    /// One account by user name (`GET /api/users/{username}`).
    public func user(username: String) async throws -> User {
        try await perform(
            makeRequest(url: Endpoints.user(baseURL: baseURL, username: username)),
            as: User.self
        )
    }

    /// Grants or revokes the administrator flag of an account
    /// (`PUT /api/users/{username}`, 204).
    ///
    /// The name and password of another account cannot be changed; that is
    /// what `updateUser` does for the logged in account.
    public func updateUserAsAdmin(username: String, isAdmin: Bool) async throws {
        let request = try makeEncodedRequest(
            path: ["users", username],
            method: "PUT",
            body: UserAdminUpdateRequest(isAdmin: isAdmin)
        )
        _ = try await sendRaw(request)
    }

    /// Deletes another account (`DELETE /api/users/{username}`, 204).
    public func deleteUser(username: String) async throws {
        _ = try await sendRaw(
            makeRequest(url: Endpoints.user(baseURL: baseURL, username: username), method: "DELETE")
        )
    }
}
