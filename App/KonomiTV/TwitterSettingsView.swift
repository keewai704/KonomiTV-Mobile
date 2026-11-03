import SwiftUI
import UIKit
import KonomiKit

/// 設定 → Twitter / Bluesky 連携: linked accounts, account links and every
/// Twitter / Bluesky preference (views/Settings/Twitter.vue).
struct TwitterSettingsView: View {
    let model: AppModel

    @State private var isWorking = false
    @State private var message: String?
    @State private var showsTwitterCookieSheet = false
    @State private var showsBlueskySheet = false
    @State private var showsLinkSheet = false

    var body: some View {
        Form {
            accountsSection
            linksSection
            replyThreadSection
            preferencesSection
            hashtagSection
        }
        .navigationTitle("Twitter / Bluesky")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsTwitterCookieSheet) {
            TwitterCookieSheet(isWorking: isWorking) { cookies in
                Task { await addTwitterAccount(cookies: cookies) }
            }
        }
        .sheet(isPresented: $showsBlueskySheet) {
            BlueskyAuthSheet(isWorking: isWorking) { handle, appPassword in
                Task { await addBlueskyAccount(handle: handle, appPassword: appPassword) }
            }
        }
        .sheet(isPresented: $showsLinkSheet) {
            AccountLinkSheet(
                twitterAccounts: unlinkedTwitterAccounts,
                blueskyAccounts: unlinkedBlueskyAccounts,
                isWorking: isWorking
            ) { twitterID, blueskyID in
                Task { await createLink(twitterID: twitterID, blueskyID: blueskyID) }
            }
        }
        .task {
            if model.user == nil, model.token != nil {
                await model.refreshUser()
            }
        }
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        Section("連携中のアカウント") {
            if model.user == nil {
                Text("Twitter / Bluesky アカウントと連携するには、KonomiTV アカウントにログインしてください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.twitter.loginRequired")
            }

            ForEach(model.user?.twitterAccounts ?? []) { account in
                HStack(spacing: 10) {
                    accountIcon(account.iconURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
                            .font(.subheadline.weight(.semibold))
                        Text("@\(account.screenName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        Task { await removeTwitterAccount(account) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
                    .accessibilityIdentifier("settings.twitter.account.twitter.\(account.id).delete")
                    .accessibilityLabel("連携を解除")
                }
                // Keep the row's own buttons addressable inside the row.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.twitter.account.twitter.\(account.id)")
            }

            ForEach(model.user?.blueskyAccounts ?? []) { account in
                HStack(spacing: 10) {
                    accountIcon(account.iconURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
                            .font(.subheadline.weight(.semibold))
                        Text("@\(account.handle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        Task { await removeBlueskyAccount(account) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
                    .accessibilityIdentifier("settings.twitter.account.bluesky.\(account.id).delete")
                    .accessibilityLabel("連携を解除")
                }
                // Keep the row's own buttons addressable inside the row.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.twitter.account.bluesky.\(account.id)")
            }

            Button {
                showsTwitterCookieSheet = true
            } label: {
                Label("Twitter アカウントを追加", systemImage: "plus")
            }
            .disabled(model.user == nil || isWorking)
            .accessibilityIdentifier("settings.twitter.addTwitter")

            Button {
                showsBlueskySheet = true
            } label: {
                Label("Bluesky アカウントを追加", systemImage: "plus")
            }
            .disabled(model.user == nil || isWorking)
            .accessibilityIdentifier("settings.twitter.addBluesky")

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.twitter.status")
            }
        }
    }

    private func accountIcon(_ rawURL: String) -> some View {
        AsyncImage(url: URL(string: rawURL)) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
    }

    // MARK: - Account links

    private var unlinkedTwitterAccounts: [TwitterAccount] {
        guard let user = model.user else { return [] }
        let linkedIDs = Set(user.accountLinks.map(\.twitterAccount.id))
        return user.twitterAccounts.filter { !linkedIDs.contains($0.id) }
    }

    private var unlinkedBlueskyAccounts: [BlueskyAccount] {
        guard let user = model.user else { return [] }
        let linkedIDs = Set(user.accountLinks.map(\.blueskyAccount.id))
        return user.blueskyAccounts.filter { !linkedIDs.contains($0.id) }
    }

    private var linksSection: some View {
        Section("紐付け中のアカウント") {
            ForEach(model.user?.accountLinks ?? []) { link in
                HStack(spacing: 10) {
                    Text(link.twitterAccount.name)
                        .font(.subheadline)
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(link.blueskyAccount.name)
                        .font(.subheadline)
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        Task { await deleteLink(link) }
                    } label: {
                        Image(systemName: "link.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
                    .accessibilityIdentifier("settings.twitter.link.\(link.id).delete")
                    .accessibilityLabel("紐付けを解除")
                }
                .accessibilityIdentifier("settings.twitter.link.\(link.id)")
            }

            Button {
                showsLinkSheet = true
            } label: {
                Label("紐付けを追加", systemImage: "link.badge.plus")
            }
            .disabled(
                model.user == nil
                    || isWorking
                    || unlinkedTwitterAccounts.isEmpty
                    || unlinkedBlueskyAccounts.isEmpty
            )
            .accessibilityIdentifier("settings.twitter.addLink")
        }
    }

    // MARK: - Reply trees

    private var replyThreadSection: some View {
        Section("リプライツリー実況") {
            Picker("Twitter", selection: replyThreadModeBinding(\.twitterReplyThreadMode)) {
                ForEach(TweetReplyThreadMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("settings.twitter.replyThreadMode")

            Picker("Bluesky", selection: replyThreadModeBinding(\.blueskyReplyThreadMode)) {
                ForEach(TweetReplyThreadMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("settings.twitter.blueskyReplyThreadMode")
        }
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        Section("ツイート") {
            Toggle(
                "ツイート送信後にパネルを折りたたむ",
                isOn: boolBinding(\.foldPanelAfterSendingTweet)
            )
            .accessibilityIdentifier("settings.twitter.foldPanel")

            Toggle(
                "番組が切り替わったときにハッシュタグフォームをリセットする",
                isOn: boolBinding(\.resetHashtagWhenProgramSwitches)
            )
            .accessibilityIdentifier("settings.twitter.resetHashtag")

            Toggle(
                "視聴中のチャンネルに対応する局タグを自動で追加する",
                isOn: boolBinding(\.autoAddWatchingChannelHashtag)
            )
            .accessibilityIdentifier("settings.twitter.autoChannelHashtag")

            Picker("最初に表示するタブ", selection: activeTabBinding) {
                ForEach(TwitterPanelTab.allCases, id: \.self) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .accessibilityIdentifier("settings.twitter.activeTab")

            Picker("ハッシュタグの位置", selection: hashtagPositionBinding) {
                ForEach(TweetHashtagPosition.allCases, id: \.self) { position in
                    Text(position.displayName).tag(position)
                }
            }
            .accessibilityIdentifier("settings.twitter.hashtagPosition")

            Picker("キャプチャの透かし", selection: watermarkPositionBinding) {
                ForEach(TweetCaptureWatermarkPosition.allCases, id: \.self) { position in
                    Text(position.displayName).tag(position)
                }
            }
            .accessibilityIdentifier("settings.twitter.watermarkPosition")
        }
    }

    // MARK: - Saved hashtags

    private var hashtagSection: some View {
        Section("保存したハッシュタグ") {
            ForEach(Array(model.settings.savedTwitterHashtags.enumerated()), id: \.offset) { entry in
                HStack(spacing: 10) {
                    TextField("#ハッシュタグ", text: savedHashtagBinding(entry.offset))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { normalizeSavedHashtag(entry.offset) }
                        .accessibilityIdentifier("settings.twitter.savedHashtag.\(entry.offset)")
                        .accessibilityLabel("保存したハッシュタグ")

                    Button(role: .destructive) {
                        removeSavedHashtag(at: entry.offset)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.twitter.savedHashtag.\(entry.offset).delete")
                    .accessibilityLabel("ハッシュタグを削除")
                }
            }

            Button {
                addSavedHashtag()
            } label: {
                Label("ハッシュタグを追加", systemImage: "plus")
            }
            .accessibilityIdentifier("settings.twitter.addSavedHashtag")
        }
    }

    // MARK: - Bindings

    private func boolBinding(_ keyPath: WritableKeyPath<ClientSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                model.mutateSettings { settings in
                    settings[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func replyThreadModeBinding(
        _ keyPath: WritableKeyPath<ClientSettings, TweetReplyThreadMode>
    ) -> Binding<TweetReplyThreadMode> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                model.mutateSettings { settings in
                    settings[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private var activeTabBinding: Binding<TwitterPanelTab> {
        Binding(
            get: { model.settings.twitterActiveTab },
            set: { newValue in
                model.mutateSettings { $0.twitterActiveTab = newValue }
            }
        )
    }

    private var hashtagPositionBinding: Binding<TweetHashtagPosition> {
        Binding(
            get: { model.settings.tweetHashtagPosition },
            set: { newValue in
                model.mutateSettings { $0.tweetHashtagPosition = newValue }
            }
        )
    }

    private var watermarkPositionBinding: Binding<TweetCaptureWatermarkPosition> {
        Binding(
            get: { model.settings.tweetCaptureWatermarkPosition },
            set: { newValue in
                model.mutateSettings { $0.tweetCaptureWatermarkPosition = newValue }
            }
        )
    }

    private func savedHashtagBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard model.settings.savedTwitterHashtags.indices.contains(index) else {
                    return ""
                }
                return model.settings.savedTwitterHashtags[index]
            },
            set: { newValue in
                model.mutateSettings { settings in
                    guard settings.savedTwitterHashtags.indices.contains(index) else { return }
                    settings.savedTwitterHashtags[index] = newValue
                }
            }
        )
    }

    private func normalizeSavedHashtag(_ index: Int) {
        model.mutateSettings { settings in
            guard settings.savedTwitterHashtags.indices.contains(index) else { return }
            let formatted = TweetHashtagRules.format(settings.savedTwitterHashtags[index])
            if formatted.isEmpty {
                settings.savedTwitterHashtags.remove(at: index)
            } else {
                settings.savedTwitterHashtags[index] = formatted
            }
        }
    }

    private func addSavedHashtag() {
        model.mutateSettings { settings in
            settings.savedTwitterHashtags.append("")
        }
    }

    private func removeSavedHashtag(at index: Int) {
        model.mutateSettings { settings in
            guard settings.savedTwitterHashtags.indices.contains(index) else { return }
            settings.savedTwitterHashtags.remove(at: index)
        }
    }

    // MARK: - Actions

    private func addTwitterAccount(cookies: String) async {
        guard let client = model.client, !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            try await client.twitterAuth(cookiesTxt: cookies)
            await model.refreshUser()
            showsTwitterCookieSheet = false
            message = "Twitter アカウントと連携しました。"
        } catch {
            message = ErrorText.message(for: error)
        }
    }

    private func removeTwitterAccount(_ account: TwitterAccount) async {
        guard let client = model.client, !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            try await client.deleteTwitterAccount(screenName: account.screenName)
            await model.refreshUser()
            message = "Twitter アカウントとの連携を解除しました。"
        } catch {
            message = ErrorText.message(for: error)
        }
    }

    private func addBlueskyAccount(handle: String, appPassword: String) async {
        guard let client = model.client, !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            try await client.blueskyAuth(handle: handle, appPassword: appPassword)
            await model.refreshUser()
            showsBlueskySheet = false
            message = "Bluesky アカウントと連携しました。"
        } catch {
            message = ErrorText.message(for: error)
        }
    }

    private func removeBlueskyAccount(_ account: BlueskyAccount) async {
        guard let client = model.client, !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            try await client.deleteBlueskyAccount(handle: account.handle)
            await model.refreshUser()
            message = "Bluesky アカウントとの連携を解除しました。"
        } catch {
            message = ErrorText.message(for: error)
        }
    }

    private func createLink(twitterID: Int, blueskyID: Int) async {
        guard let client = model.client, !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            _ = try await client.createAccountLink(
                twitterAccountID: twitterID,
                blueskyAccountID: blueskyID
            )
            await model.refreshUser()
            showsLinkSheet = false
            message = "アカウントを紐付けました。"
        } catch {
            message = ErrorText.message(for: error)
        }
    }

    private func deleteLink(_ link: AccountLink) async {
        guard let client = model.client, !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            try await client.deleteAccountLink(id: link.id)
            await model.refreshUser()
            message = "アカウントの紐付けを解除しました。"
        } catch {
            message = ErrorText.message(for: error)
        }
    }
}

// MARK: - Twitter cookie login

/// Cookies.txt (Netscape format) input, the same text the web client asks for.
private struct TwitterCookieSheet: View {
    let isWorking: Bool
    let onLogin: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cookies = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $cookies)
                        .frame(minHeight: 220)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.twitter.cookies")
                        .accessibilityLabel("Cookie (Netscape cookies.txt 形式)")
                } footer: {
                    Text("Web 版 Twitter の Cookie を Netscape 形式 (cookies.txt) で貼り付けてください。")
                }

                Section {
                    Button {
                        if let text = UIPasteboard.general.string {
                            cookies = text
                        }
                    } label: {
                        Label("クリップボードから貼り付け", systemImage: "doc.on.clipboard")
                    }
                    .accessibilityIdentifier("settings.twitter.cookies.paste")
                }
            }
            .navigationTitle("Twitter アカウントを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("ログイン") {
                        onLogin(cookies)
                    }
                    .disabled(
                        isWorking
                            || cookies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("settings.twitter.cookies.login")
                }
            }
        }
    }
}

// MARK: - Bluesky login

/// Bluesky handle and App Password input.
private struct BlueskyAuthSheet: View {
    let isWorking: Bool
    let onLogin: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    @State private var appPassword = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("example.bsky.social", text: $handle)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.twitter.bluesky.handle")
                        .accessibilityLabel("Bluesky ハンドル")

                    SecureField("App Password", text: $appPassword)
                        .textContentType(.password)
                        .accessibilityIdentifier("settings.twitter.bluesky.appPassword")
                        .accessibilityLabel("App Password")
                } footer: {
                    Text("Bluesky で発行した App Password を入力してください。")
                }
            }
            .navigationTitle("Bluesky アカウントを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("ログイン") {
                        onLogin(handle, appPassword)
                    }
                    .disabled(
                        isWorking
                            || handle.trimmingCharacters(in: .whitespaces).isEmpty
                            || appPassword.isEmpty
                    )
                    .accessibilityIdentifier("settings.twitter.bluesky.login")
                }
            }
        }
    }
}

// MARK: - Account link

/// Picks one Twitter and one Bluesky account to pair.
private struct AccountLinkSheet: View {
    let twitterAccounts: [TwitterAccount]
    let blueskyAccounts: [BlueskyAccount]
    let isWorking: Bool
    let onCreate: (Int, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var twitterID: Int?
    @State private var blueskyID: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section("Twitter") {
                    Picker("Twitter アカウント", selection: $twitterID) {
                        ForEach(twitterAccounts) { account in
                            Text("@\(account.screenName)").tag(Optional(account.id))
                        }
                    }
                    .accessibilityIdentifier("settings.twitter.link.twitter")
                }

                Section("Bluesky") {
                    Picker("Bluesky アカウント", selection: $blueskyID) {
                        ForEach(blueskyAccounts) { account in
                            Text("@\(account.handle)").tag(Optional(account.id))
                        }
                    }
                    .accessibilityIdentifier("settings.twitter.link.bluesky")
                }
            }
            .navigationTitle("紐付けを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        if let twitterID, let blueskyID {
                            onCreate(twitterID, blueskyID)
                        }
                    }
                    .disabled(
                        isWorking
                            || twitterID == nil
                            || blueskyID == nil
                    )
                    .accessibilityIdentifier("settings.twitter.link.create")
                }
            }
            .onAppear {
                if twitterID == nil {
                    twitterID = twitterAccounts.first?.id
                }
                if blueskyID == nil {
                    blueskyID = blueskyAccounts.first?.id
                }
            }
        }
    }
}
