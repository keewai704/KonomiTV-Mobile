import SwiftUI
import KonomiKit

/// 設定: server, playback quality, optional login and server information.
struct SettingsView: View {
    let model: AppModel

    @AppStorage(PreferenceKeys.liveQuality) private var liveQualityRaw: String = StreamQuality.p1080.rawValue
    @AppStorage(PreferenceKeys.videoQuality) private var videoQualityRaw: String = StreamQuality.p1080.rawValue

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
            accountSection
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
            Picker("ライブ配信", selection: $liveQualityRaw) {
                ForEach(StreamQuality.liveQualities, id: \.self) { quality in
                    Text(quality.displayName).tag(quality.rawValue)
                }
            }
            .accessibilityIdentifier("settings.liveQuality")

            Picker("ビデオ", selection: $videoQualityRaw) {
                ForEach(StreamQuality.videoQualities, id: \.self) { quality in
                    Text(quality.displayName).tag(quality.rawValue)
                }
            }
            .accessibilityIdentifier("settings.videoQuality")
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
