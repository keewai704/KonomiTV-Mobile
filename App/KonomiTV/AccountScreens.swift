import Foundation
import SwiftUI
import PhotosUI
import UIKit
import KonomiKit

// MARK: - Avatar

/// The round avatar of an account (`GET /api/users/me/icon` or
/// `GET /api/users/{username}/icon`).
///
/// The icon routes need the bearer token, so the image is downloaded through
/// `APIClient` instead of an `AsyncImage` URL. `revision` reloads it after an
/// upload or a rename.
struct UserAvatarView: View {
    let client: APIClient?
    var username: String?
    var revision: Int = 0
    var size: CGFloat = 44

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.15))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: "\(username ?? "me")-\(revision)") {
            guard let client else { return }
            guard let data = try? await client.userIcon(username: username) else { return }
            image = UIImage(data: data)
        }
    }
}

// MARK: - Register

/// アカウントを作成: creates an account and logs in with it, like the web
/// client's Register.vue. The server makes the first account of a server the
/// administrator.
struct RegisterScreen: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("ユーザー名", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.register.username")

                SecureField("パスワード", text: $password)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("settings.register.password")

                SecureField("パスワード (確認)", text: $confirmation)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("settings.register.confirm")
            } footer: {
                Text("ユーザー名は2文字以上、パスワードは4文字以上の半角英数記号で入力してください。")
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 8) {
                        Text("アカウントを作成")
                        if isSubmitting {
                            Spacer(minLength: 0)
                            ProgressView()
                        }
                    }
                }
                .disabled(isSubmitting || username.isEmpty || password.isEmpty)
                .accessibilityIdentifier("settings.register.submit")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings.register.error")
                }
            }
        }
        .navigationTitle("アカウントを作成")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() async {
        guard !isSubmitting else { return }

        if let message = AccountRules.usernameError(username) {
            errorMessage = message
            return
        }
        if let message = AccountRules.passwordError(password) {
            errorMessage = message
            return
        }
        guard password == confirmation else {
            errorMessage = "パスワードが一致しません。"
            return
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await model.register(username: username, password: password)
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - Account settings

/// アカウント設定: rename the account, change the password, upload an avatar
/// and delete the account (views/Settings/Account.vue).
struct AccountSettingsScreen: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingIcon: Data?
    @State private var pendingIconContentType = "image/png"
    @State private var isSavingName = false
    @State private var isSavingPassword = false
    @State private var isSavingIcon = false
    @State private var nameMessage: String?
    @State private var passwordMessage: String?
    @State private var iconMessage: String?
    @State private var showsDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var localIconRevision = 0

    private var user: User? { model.user }

    var body: some View {
        Form {
            accountSection
            nameSection
            passwordSection
            iconSection
            deleteSection
        }
        .navigationTitle("アカウント")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if username.isEmpty {
                username = user?.name ?? ""
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            Task { await loadPhoto(item) }
        }
        .confirmationDialog(
            "本当にアカウントを削除しますか？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("アカウントを削除", role: .destructive) {
                Task { await deleteAccount() }
            }
            .accessibilityIdentifier("settings.account.delete.confirm")

            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("アカウントに紐づくすべてのユーザーデータが削除されます。元に戻すことはできません。")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                UserAvatarView(
                    client: model.client,
                    username: nil,
                    revision: model.accountIconRevision + localIconRevision,
                    size: 64
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(user?.name ?? "")
                            .font(.headline)
                            .accessibilityIdentifier("settings.account.name")
                        if user?.isAdmin == true {
                            Text("管理者")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                    Text("User ID: \(user?.id ?? 0)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var nameSection: some View {
        Section("ユーザー名") {
            TextField("ユーザー名", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.account.username")

            Button {
                Task { await saveName() }
            } label: {
                HStack(spacing: 8) {
                    Text("ユーザー名を更新")
                    if isSavingName {
                        Spacer(minLength: 0)
                        ProgressView()
                    }
                }
            }
            .disabled(isSavingName || username.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("settings.account.usernameSave")

            if let nameMessage {
                Text(nameMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.account.usernameMessage")
            }
        }
    }

    private var passwordSection: some View {
        Section("パスワード") {
            SecureField("現在のパスワード", text: $currentPassword)
                .textContentType(.password)
                .accessibilityIdentifier("settings.account.currentPassword")

            SecureField("新しいパスワード", text: $newPassword)
                .textContentType(.newPassword)
                .accessibilityIdentifier("settings.account.newPassword")

            SecureField("新しいパスワード (確認)", text: $confirmation)
                .textContentType(.newPassword)
                .accessibilityIdentifier("settings.account.confirmPassword")

            Button {
                Task { await savePassword() }
            } label: {
                HStack(spacing: 8) {
                    Text("パスワードを更新")
                    if isSavingPassword {
                        Spacer(minLength: 0)
                        ProgressView()
                    }
                }
            }
            .disabled(
                isSavingPassword
                    || currentPassword.isEmpty
                    || newPassword.isEmpty
                    || confirmation.isEmpty
            )
            .accessibilityIdentifier("settings.account.passwordSave")

            if let passwordMessage {
                Text(passwordMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.account.passwordMessage")
            }
        }
    }

    private var iconSection: some View {
        Section("アイコン画像") {
            HStack(spacing: 12) {
                if let pendingIcon, let image = UIImage(data: pendingIcon) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                } else {
                    UserAvatarView(
                        client: model.client,
                        username: nil,
                        revision: model.accountIconRevision + localIconRevision,
                        size: 64
                    )
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Text("画像を選択")
                }
                .accessibilityIdentifier("settings.account.iconPicker")
            }

            Button {
                Task { await saveIcon() }
            } label: {
                HStack(spacing: 8) {
                    Text("アイコン画像を更新")
                    if isSavingIcon {
                        Spacer(minLength: 0)
                        ProgressView()
                    }
                }
            }
            .disabled(isSavingIcon || pendingIcon == nil)
            .accessibilityIdentifier("settings.account.iconSave")

            Button("選択をリセット") {
                selectedPhoto = nil
                pendingIcon = nil
                iconMessage = nil
                localIconRevision += 1
            }
            .accessibilityIdentifier("settings.account.iconReset")

            if let iconMessage {
                Text(iconMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.account.iconMessage")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                HStack(spacing: 8) {
                    Text("アカウントを削除")
                    if isDeleting {
                        Spacer(minLength: 0)
                        ProgressView()
                    }
                }
            }
            .disabled(isDeleting)
            .accessibilityIdentifier("settings.account.delete")
        } footer: {
            Text("アカウントに紐づくすべてのデータが削除されます。元に戻すことはできません。")
        }
    }

    // MARK: Actions

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            iconMessage = "画像を読み込めませんでした。"
            return
        }
        // The server accepts only JPEG and PNG; photos are often HEIC, so
        // anything else is re-encoded as JPEG.
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            pendingIcon = data
            pendingIconContentType = "image/png"
        } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            pendingIcon = data
            pendingIconContentType = "image/jpeg"
        } else if let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
            pendingIcon = jpeg
            pendingIconContentType = "image/jpeg"
        } else {
            iconMessage = "画像を読み込めませんでした。"
            return
        }
        iconMessage = nil
    }

    private func saveName() async {
        guard !isSavingName else { return }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = AccountRules.usernameError(trimmed) {
            nameMessage = message
            return
        }

        isSavingName = true
        nameMessage = nil
        defer { isSavingName = false }

        do {
            try await model.updateAccountName(trimmed)
            nameMessage = "ユーザー名を更新しました。"
        } catch {
            nameMessage = ErrorText.message(for: error)
        }
    }

    private func savePassword() async {
        guard !isSavingPassword else { return }
        if let message = AccountRules.passwordError(newPassword) {
            passwordMessage = message
            return
        }
        guard newPassword == confirmation else {
            passwordMessage = "新しいパスワードが一致しません。"
            return
        }

        isSavingPassword = true
        passwordMessage = nil
        defer { isSavingPassword = false }

        do {
            try await model.changePassword(current: currentPassword, new: newPassword)
            currentPassword = ""
            newPassword = ""
            confirmation = ""
            passwordMessage = "パスワードを更新しました。"
        } catch {
            passwordMessage = ErrorText.message(for: error)
        }
    }

    private func saveIcon() async {
        guard !isSavingIcon, let pendingIcon else { return }
        isSavingIcon = true
        iconMessage = nil
        defer { isSavingIcon = false }

        do {
            try await model.updateAccountIcon(
                image: pendingIcon,
                contentType: pendingIconContentType
            )
            self.pendingIcon = nil
            selectedPhoto = nil
            localIconRevision += 1
            iconMessage = "アイコン画像を更新しました。"
        } catch {
            iconMessage = ErrorText.message(for: error)
        }
    }

    private func deleteAccount() async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await model.deleteAccount()
            dismiss()
        } catch {
            iconMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - Administrator user management

/// ユーザー管理: every account of the server, with the admin flag and delete
/// action (views/Settings/Account.vue's account management dialog).
struct AdminUsersScreen: View {
    let model: AppModel

    @State private var users: [User] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isAdmin: Bool { model.user?.isAdmin == true }

    var body: some View {
        content
            .navigationTitle("ユーザー管理")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !isAdmin {
            ContentUnavailableView(
                "管理者のみ利用できます",
                systemImage: "person.badge.key",
                description: Text("管理者アカウントでログインしてください。")
            )
        } else if users.isEmpty, isLoading {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if users.isEmpty, let errorMessage {
            ContentUnavailableView {
                Label("ユーザーを取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再試行") {
                    Task { await load() }
                }
            }
        } else {
            List {
                Section {
                    ForEach(users) { user in
                        NavigationLink {
                            AdminUserDetailScreen(model: model, user: user)
                        } label: {
                            AdminUserRow(model: model, user: user)
                        }
                        .accessibilityIdentifier("admin.users.item.\(user.id)")
                    }
                }

                Section {
                    NavigationLink {
                        AccountSettingsScreen(model: model)
                    } label: {
                        Label("自分のアカウント設定", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("admin.users.accountSettings")
                }
            }
            .accessibilityIdentifier("admin.users.list")
            .refreshable { await load() }
            .onAppear {
                // Picks up a renamed / deleted account after returning from
                // the detail screen.
                Task { await load() }
            }
        }
    }

    private func load() async {
        guard isAdmin, let client = model.client else { return }
        isLoading = users.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await client.users()
            guard !Task.isCancelled else { return }
            users = result
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }
}

private struct AdminUserRow: View {
    let model: AppModel
    let user: User

    var body: some View {
        HStack(spacing: 12) {
            UserAvatarView(
                client: model.client,
                username: user.name,
                revision: model.accountIconRevision,
                size: 40
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name)
                    .font(.subheadline.weight(.semibold))
                Text("User ID: \(user.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if user.isAdmin {
                Text("管理者")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        }
    }
}

/// One account: grant / revoke the admin flag and delete the account.
struct AdminUserDetailScreen: View {
    let model: AppModel
    let user: User

    @Environment(\.dismiss) private var dismiss

    @State private var isAdmin: Bool
    @State private var isSaving = false
    @State private var message: String?
    @State private var showsDeleteConfirmation = false

    init(model: AppModel, user: User) {
        self.model = model
        self.user = user
        _isAdmin = State(initialValue: user.isAdmin)
    }

    private var isSelf: Bool { model.user?.id == user.id }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    UserAvatarView(
                        client: model.client,
                        username: user.name,
                        revision: model.accountIconRevision,
                        size: 56
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name)
                            .font(.headline)
                            .accessibilityIdentifier("admin.users.name")
                        Text("User ID: \(user.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }

            Section {
                Toggle("管理者", isOn: $isAdmin)
                    .accessibilityIdentifier("admin.users.isAdmin")

                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 8) {
                        Text("権限を更新")
                        if isSaving {
                            Spacer(minLength: 0)
                            ProgressView()
                        }
                    }
                }
                .disabled(isSaving || isAdmin == user.isAdmin)
                .accessibilityIdentifier("admin.users.save")

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("admin.users.message")
                }
            } footer: {
                Text("ユーザー名とパスワードは、そのアカウントでログインして変更します。")
            }

            if isSelf {
                Section {
                    NavigationLink {
                        AccountSettingsScreen(model: model)
                    } label: {
                        Label("自分のアカウント設定", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("admin.users.accountSettings")
                }
            }

            Section {
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("アカウントを削除", systemImage: "trash")
                }
                .accessibilityIdentifier("admin.users.delete")
            }
        }
        .navigationTitle(user.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "このアカウントを削除しますか？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                Task { await delete() }
            }
            .accessibilityIdentifier("admin.users.delete.confirm")

            Button("キャンセル", role: .cancel) {}
        }
    }

    private func save() async {
        guard let client = model.client, !isSaving else { return }
        isSaving = true
        message = nil
        defer { isSaving = false }

        do {
            try await client.updateUserAsAdmin(username: user.name, isAdmin: isAdmin)
            message = "権限を更新しました。"
        } catch {
            message = ErrorText.message(for: error)
        }
    }

    private func delete() async {
        guard let client = model.client else { return }
        do {
            try await client.deleteUser(username: user.name)
            if isSelf {
                model.logout()
            }
            dismiss()
        } catch {
            message = ErrorText.message(for: error)
        }
    }
}
