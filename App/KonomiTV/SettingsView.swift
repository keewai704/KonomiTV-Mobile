import SwiftUI
import KonomiKit

/// 設定: server, playback quality, account, client settings and server
/// information.
struct SettingsView: View {
    let model: AppModel

    @State private var serverText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var isLoggingIn = false
    @State private var serverError: String?
    @State private var loginError: String?

    var body: some View {
        Form {
            serverSection
            qualitySection
            jikkyoSection
            accountSection
            televisionSection
            timetableSection
            historySection
            informationSection
        }
        .navigationTitle("設定")
        .task {
            if serverText.isEmpty {
                serverText = model.serverURLString
            }
            await model.refreshVersion()
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section {
            TextField("http://example.local:7000", text: $serverText)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.serverURL")

            HStack(spacing: 8) {
                Button("接続先を変更") { reconnect() }
                    .disabled(isConnecting || trimmedServerText.isEmpty)
                if isConnecting {
                    Spacer(minLength: 0)
                    ProgressView()
                }
            }

            Button("切断", role: .destructive) {
                model.disconnect()
            }
            .accessibilityIdentifier("settings.disconnectButton")

            if let serverError {
                Text(serverError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("サーバー")
        }
    }

    private var qualitySection: some View {
        Section("再生品質") {
            NavigationLink {
                QualitySettingsView()
            } label: {
                Label("画質", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("settings.quality")
        }
    }

    private var jikkyoSection: some View {
        Section {
            NavigationLink {
                NiconicoJikkyoSettingsView(model: model)
            } label: {
                Label("ニコニコ実況", systemImage: "text.bubble")
            }
            .accessibilityIdentifier("settings.jikkyo")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("アカウント") {
            if let user = model.user {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("ユーザー名")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(user.name)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("settings.userName")
                }
                if user.isAdmin {
                    LabeledContent("権限", value: "管理者")
                }

                Toggle("設定をデバイス間で同期する", isOn: syncSettingsBinding)
                    .accessibilityIdentifier("settings.syncSettings")

                Button("ログアウト", role: .destructive) {
                    logout()
                }
                .accessibilityIdentifier("settings.logoutButton")
            } else {
                TextField("ユーザー名", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.username")

                SecureField("パスワード", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("settings.password")

                HStack(spacing: 8) {
                    Button("ログイン") { login() }
                        .disabled(isLoggingIn || username.isEmpty || password.isEmpty)
                        .accessibilityIdentifier("settings.loginButton")
                    if isLoggingIn {
                        Spacer(minLength: 0)
                        ProgressView()
                    }
                }

                if let loginError {
                    Text(loginError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var televisionSection: some View {
        Section("テレビ") {
            Toggle(
                "チャンネル一覧を実況勢いが強い順に並び替える",
                isOn: sortByJikkyoForceBinding
            )
            .accessibilityIdentifier("settings.sortByJikkyoForce")

            NavigationLink(value: SectionRoute.pinnedChannels) {
                LabeledContent("ピン留めチャンネル", value: pinnedChannelCountText)
            }
            .accessibilityIdentifier("settings.pinnedChannels")
        }
    }

    private var timetableSection: some View {
        Section("番組表") {
            Toggle(
                "ショッピング・通販番組を控えめに表示する",
                isOn: dimShoppingProgramsBinding
            )
            .accessibilityIdentifier("settings.dimShoppingPrograms")

            Toggle("時刻を 28 時間表記で表示する", isOn: use28HourClockBinding)
                .accessibilityIdentifier("settings.use28HourClock")
        }
    }

    private var historySection: some View {
        Section("視聴履歴") {
            Stepper(value: watchedHistoryMaxCountBinding, in: 1...100) {
                LabeledContent(
                    "保持件数",
                    value: "\(model.settings.videoWatchedHistoryMaxCount)件"
                )
            }
            .accessibilityIdentifier("settings.historyMaxCount")
        }
    }

    @ViewBuilder
    private var informationSection: some View {
        if let version = model.version {
            Section("サーバー情報") {
                LabeledContent("バージョン", value: version.version)
                LabeledContent("環境", value: version.environment)
                LabeledContent("バックエンド", value: version.backend)
                LabeledContent("エンコーダー", value: version.encoder)
            }
        }
    }

    // MARK: - Bindings

    private var syncSettingsBinding: Binding<Bool> {
        Binding(
            get: { model.syncSettings },
            set: { model.setSyncSettings($0) }
        )
    }

    private var sortByJikkyoForceBinding: Binding<Bool> {
        Binding(
            get: { model.settings.tvChannelSortByJikkyoForce },
            set: { newValue in
                model.mutateSettings { settings in
                    settings.tvChannelSortByJikkyoForce = newValue
                }
            }
        )
    }

    private var dimShoppingProgramsBinding: Binding<Bool> {
        Binding(
            get: { model.settings.timetableDimShoppingPrograms },
            set: { newValue in
                model.mutateSettings { settings in
                    settings.timetableDimShoppingPrograms = newValue
                }
            }
        )
    }

    private var use28HourClockBinding: Binding<Bool> {
        Binding(
            get: { model.settings.use28HourClock },
            set: { newValue in
                model.mutateSettings { settings in
                    settings.use28HourClock = newValue
                }
            }
        )
    }

    private var watchedHistoryMaxCountBinding: Binding<Int> {
        Binding(
            get: { model.settings.videoWatchedHistoryMaxCount },
            set: { newValue in
                model.mutateSettings { settings in
                    settings.videoWatchedHistoryMaxCount = min(max(newValue, 1), 100)
                }
            }
        )
    }

    private var pinnedChannelCountText: String {
        let count = model.settings.pinnedChannelIDs.count
        return count == 0 ? "なし" : "\(count)件"
    }

    // MARK: - Actions

    private var trimmedServerText: String {
        serverText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reconnect() {
        guard !isConnecting, !trimmedServerText.isEmpty else { return }
        isConnecting = true
        serverError = nil

        Task {
            do {
                try await model.connect(rawURL: trimmedServerText)
                serverText = model.serverURLString
            } catch {
                serverError = ErrorText.message(for: error)
            }
            isConnecting = false
        }
    }

    private func login() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        loginError = nil

        Task {
            do {
                try await model.login(username: username, password: password)
                password = ""
            } catch {
                loginError = ErrorText.message(for: error)
            }
            isLoggingIn = false
        }
    }

    private func logout() {
        model.logout()
        username = ""
        password = ""
        loginError = nil
    }
}

/// ピン留めチャンネル: reorder and remove the pinned channels.
struct PinnedChannelsView: View {
    let model: AppModel

    @State private var channels: LiveChannels?

    var body: some View {
        List {
            ForEach(rows) { row in
                Text(row.name)
                    .accessibilityIdentifier("settings.pinnedChannel.\(row.id)")
            }
            .onMove { source, destination in
                model.movePinnedChannels(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                let ids = rows.map(\.id)
                for index in offsets where ids.indices.contains(index) {
                    model.removePinnedChannel(id: ids[index])
                }
            }

            if rows.isEmpty {
                Text("ピン留め中のチャンネルはありません")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("ピン留めチャンネル")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .task {
            guard let client = model.client else { return }
            channels = try? await client.channels()
        }
    }

    private struct Row: Identifiable {
        let id: String
        let name: String
    }

    private var rows: [Row] {
        let all = channels?.allChannels ?? []
        return model.settings.pinnedChannelIDs.map { id in
            let channel = all.first { $0.id == id } ?? all.first { $0.displayChannelID == id }
            return Row(id: id, name: channel?.name ?? id)
        }
    }
}
