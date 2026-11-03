import Foundation
import SwiftUI
import KonomiKit

/// サーバー設定: every field the web client's views/Settings/Server.vue
/// edits, with the same sections, defaults and validation.
///
/// The server validates the whole body and writes config.yaml; the changes
/// only take effect after a restart, which the screen says after saving.
struct ServerSettingsScreen: View {
    let model: AppModel

    @State private var settings = ServerSettings()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    private var isAdmin: Bool { model.user?.isAdmin == true }

    var body: some View {
        Group {
            if !isAdmin {
                ContentUnavailableView(
                    "管理者のみ利用できます",
                    systemImage: "server.rack",
                    description: Text("管理者アカウントでログインしてください。")
                )
            } else if isLoading {
                ProgressView("読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .navigationTitle("サーバー設定")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            // The save result goes first so it is in view after saving from
            // the navigation bar.
            statusSection
            generalSection
            serverSection
            televisionSection
            videoSection
            captureSection
        }
        .accessibilityIdentifier("settings.server.form")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("保存") {
                        Task { await save() }
                    }
                    .accessibilityIdentifier("settings.server.save")
                }
            }
        }
    }

    private var generalSection: some View {
        Section("全般") {
            Picker("利用するバックエンド", selection: $settings.general.backend) {
                ForEach(ServerBackend.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .accessibilityIdentifier("settings.server.backend")

            TextField("EDCB (EpgTimerNW) の TCP API の URL", text: $settings.general.edcbURL)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.server.edcbURL")

            TextField(
                "Mirakurun / mirakc の HTTP API の URL",
                text: $settings.general.mirakurunURL
            )
            .textContentType(.URL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("settings.server.mirakurunURL")

            Picker("利用するエンコーダー", selection: $settings.general.encoder) {
                ForEach(ServerEncoder.allCases, id: \.self) { encoder in
                    Text(encoder.displayName).tag(encoder)
                }
            }
            .accessibilityIdentifier("settings.server.encoder")

            Stepper(
                value: $settings.general.programUpdateInterval,
                in: 0.5...60,
                step: 0.5
            ) {
                LabeledContent(
                    "番組情報の更新間隔",
                    value: String(format: "%.1f 分", settings.general.programUpdateInterval)
                )
            }
            .accessibilityIdentifier("settings.server.programUpdateInterval")

            Toggle("デバッグモードを有効にする", isOn: $settings.general.debug)
                .accessibilityIdentifier("settings.server.debug")

            Toggle("エンコーダーのログを有効にする", isOn: $settings.general.debugEncoder)
                .accessibilityIdentifier("settings.server.debugEncoder")
        }
    }

    private var serverSection: some View {
        Section {
            TextField("リッスンポート (1024〜65525)", text: portBinding)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("settings.server.port")

            TextField(
                "HTTPS 証明書ファイル (例: /path/to/cert.pem)",
                text: certificateBinding
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("settings.server.certificate")

            TextField(
                "HTTPS 秘密鍵ファイル (例: /path/to/key.pem)",
                text: privateKeyBinding
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("settings.server.privateKey")
        } header: {
            Text("サーバー")
        } footer: {
            Text("リッスンポートは 1024〜65525 の範囲で指定してください。")
        }
    }

    private var televisionSection: some View {
        Section("テレビのライブストリーミング") {
            Toggle(
                "常に Mirakurun / mirakc から放送波を受信する",
                isOn: $settings.general.alwaysReceiveTVFromMirakurun
            )
            .accessibilityIdentifier("settings.server.alwaysReceiveTVFromMirakurun")

            Picker("優先する地デジのエリア", selection: $settings.tv.preferredTerrestrialRegion) {
                Text("未設定").tag(nil as String?)
                ForEach(TerrestrialRegionCatalog.all, id: \.self) { region in
                    Text(region).tag(region as String?)
                }
            }
            .accessibilityIdentifier("settings.server.region")

            Stepper(value: $settings.tv.maxAliveTime, in: 0...60) {
                LabeledContent(
                    "未視聴チャンネルのエンコードタスクを維持する秒数",
                    value: "\(settings.tv.maxAliveTime) 秒"
                )
            }
            .accessibilityIdentifier("settings.server.maxAliveTime")
        }
    }

    private var videoSection: some View {
        Section {
            ForEach(settings.video.recordedFolders.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(
                        "録画フォルダ (例: /recorded)",
                        text: $settings.video.recordedFolders[index]
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.server.recordedFolder.\(index)")

                    Button(role: .destructive) {
                        settings.video.recordedFolders.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("録画フォルダを削除")
                    .accessibilityIdentifier("settings.server.removeRecordedFolder.\(index)")
                }
            }

            Button {
                settings.video.recordedFolders.append("")
            } label: {
                Label("録画フォルダを追加", systemImage: "plus")
            }
            .accessibilityIdentifier("settings.server.addRecordedFolder")

            ForEach(settings.video.excludeScanPaths.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(
                        "スキャン対象から除外するフォルダ",
                        text: $settings.video.excludeScanPaths[index]
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.server.excludeScanPath.\(index)")

                    Button(role: .destructive) {
                        settings.video.excludeScanPaths.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("除外フォルダを削除")
                    .accessibilityIdentifier("settings.server.removeExcludeScanPath.\(index)")
                }
            }

            Button {
                settings.video.excludeScanPaths.append("")
            } label: {
                Label("除外フォルダを追加", systemImage: "plus")
            }
            .accessibilityIdentifier("settings.server.addExcludeScanPath")

            Stepper(
                value: $settings.video.recordedFoldersPollingInterval,
                in: 0.5...60,
                step: 0.5
            ) {
                LabeledContent(
                    "録画フォルダの確認間隔",
                    value: String(
                        format: "%.1f 分",
                        settings.video.recordedFoldersPollingInterval
                    )
                )
            }
            .accessibilityIdentifier("settings.server.recordedFoldersPollingInterval")
        } header: {
            Text("ビデオのオンデマンドストリーミング")
        } footer: {
            Text("指定フォルダ以下の録画ファイルを自動的に見つけ出し、メタデータとサムネイルを解析します。")
        }
    }

    private var captureSection: some View {
        Section("キャプチャ") {
            ForEach(settings.capture.uploadFolders.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(
                        "キャプチャの保存先フォルダ (例: /captures)",
                        text: $settings.capture.uploadFolders[index]
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.server.uploadFolder.\(index)")

                    Button(role: .destructive) {
                        settings.capture.uploadFolders.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("保存先フォルダを削除")
                    .accessibilityIdentifier("settings.server.removeUploadFolder.\(index)")
                }
            }

            Button {
                settings.capture.uploadFolders.append("")
            } label: {
                Label("保存先フォルダを追加", systemImage: "plus")
            }
            .accessibilityIdentifier("settings.server.addUploadFolder")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if errorMessage != nil || savedMessage != nil {
            Section {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings.server.error")
                }

                if let savedMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(savedMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.server.saved")

                        NavigationLink(value: SectionRoute.maintenance) {
                            Label("メンテナンスを開く", systemImage: "wrench.and.screwdriver")
                        }
                        .accessibilityIdentifier("settings.server.maintenanceLink")
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    /// The port as text, so the value is applied as it is typed (a numeric
    /// `TextField(value:format:)` only parses on commit).
    private var portBinding: Binding<String> {
        Binding(
            get: { String(settings.server.port) },
            set: { newValue in
                let digits = newValue.filter { $0.isNumber }
                if let port = Int(digits) {
                    settings.server.port = port
                }
            }
        )
    }

    /// The web client stores an empty certificate field as null.
    private var certificateBinding: Binding<String> {
        Binding(
            get: { settings.server.customHTTPSCertificate ?? "" },
            set: { settings.server.customHTTPSCertificate = $0.isEmpty ? nil : $0 }
        )
    }

    private var privateKeyBinding: Binding<String> {
        Binding(
            get: { settings.server.customHTTPSPrivateKey ?? "" },
            set: { settings.server.customHTTPSPrivateKey = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Loading / saving

    private func load() async {
        guard isAdmin, let client = model.client else {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await client.serverSettings()
            guard !Task.isCancelled else { return }
            settings = loaded
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func save() async {
        guard !isSaving, let client = model.client else { return }

        var payload = settings
        payload.normalizeOptionalPaths()
        if let message = payload.validationError() {
            errorMessage = message
            savedMessage = nil
            return
        }

        isSaving = true
        errorMessage = nil
        savedMessage = nil
        defer { isSaving = false }

        do {
            try await client.updateServerSettings(payload)
            settings = payload
            savedMessage =
                "サーバー設定を更新しました。変更を反映するためには、KonomiTV サーバーを再起動してください。"
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
