import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Account links API

/// Endpoints of UsersRouter for Twitter / Bluesky pairs
/// (/api/users/me/account-links).
extension APIClient {

    /// Links a Twitter account and a Bluesky account
    /// (POST /api/users/me/account-links, 201).
    ///
    /// Both accounts must belong to the logged in user.
    public func createAccountLink(
        twitterAccountID: Int,
        blueskyAccountID: Int
    ) async throws -> AccountLink {
        let body = try encodeJSONBody(
            AccountLinkCreateRequest(
                twitterAccountID: twitterAccountID,
                blueskyAccountID: blueskyAccountID
            )
        )
        let request = makeRequest(
            path: ["users", "me", "account-links"],
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        return try await performJSON(request, as: AccountLink.self)
    }

    /// Removes a Twitter / Bluesky pair
    /// (DELETE /api/users/me/account-links/{link_id}, 204). The accounts
    /// themselves stay linked.
    public func deleteAccountLink(id: Int) async throws {
        _ = try await sendRaw(
            makeRequest(
                path: ["users", "me", "account-links", String(id)],
                method: "DELETE"
            )
        )
    }
}
