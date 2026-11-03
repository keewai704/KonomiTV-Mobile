import Foundation

// MARK: - Account requests

/// Body of `POST /api/users` (schemas.UserCreateRequest).
///
/// The first account created on a server becomes its administrator; the
/// server decides that, not the client.
public struct UserCreateRequest: Codable, Sendable, Hashable {
    public var username: String
    public var password: String

    public init(username: String = "", password: String = "") {
        self.username = username
        self.password = password
    }
}

/// Body of `PUT /api/users/me` (schemas.UserUpdateRequest).
///
/// Both fields are optional: the server leaves a field alone when it is
/// omitted, so changing only the password does not touch the name.
public struct UserUpdateRequest: Codable, Sendable, Hashable {
    public var username: String?
    public var password: String?

    public init(username: String? = nil, password: String? = nil) {
        self.username = username
        self.password = password
    }
}

/// Body of `PUT /api/users/{username}` (schemas.UserUpdateRequestForAdmin).
///
/// Administrators can only grant or revoke the admin flag through this route;
/// name and password belong to `PUT /api/users/me` of the account itself.
public struct UserAdminUpdateRequest: Codable, Sendable, Hashable {
    public var isAdmin: Bool?

    public init(isAdmin: Bool? = nil) {
        self.isAdmin = isAdmin
    }

    private enum CodingKeys: String, CodingKey {
        case isAdmin = "is_admin"
    }
}

// MARK: - Account validation

/// The rules the web client's register / account forms apply before sending a
/// request (views/Register.vue and views/Settings/Account.vue).
public enum AccountRules {
    /// The web client requires at least two characters for a user name.
    public static func usernameError(_ value: String) -> String? {
        if value.isEmpty {
            return "ユーザー名を入力してください。"
        }
        if value.count < 2 {
            return "ユーザー名は2文字以上で入力してください。"
        }
        // /api/users/me and /api/users/token occupy these names.
        if ["me", "token"].contains(value.lowercased()) {
            return "ユーザー名に me と token は使えません。"
        }
        return nil
    }

    /// The web client accepts four or more half-width letters, digits and
    /// symbols (the bcrypt input is truncated to 72 bytes on the server).
    public static func passwordError(_ value: String) -> String? {
        if value.isEmpty {
            return "パスワードを入力してください。"
        }
        if value.count < 4 {
            return "パスワードは4文字以上の半角英数記号を入力してください。"
        }
        // The web client's character class is every printable ASCII character
        // plus the yen sign.
        let yenSign: UInt32 = 0xA5
        let hasDisallowed = value.unicodeScalars.contains { scalar in
            !(0x21...0x7E).contains(scalar.value) && scalar.value != yenSign
        }
        if hasDisallowed {
            return "パスワードは4文字以上の半角英数記号を入力してください。"
        }
        return nil
    }
}
