import Foundation
import SwiftUI
import UIKit
import KonomiKit

/// メンテナンス: log viewer, database update, the four maintenance tasks with
/// their progress, and the restart / shutdown controls (the web client's
/// maintenance section of views/Settings/Server.vue).
///
/// Every control is administrator only. The task statuses are polled once a
/// second while a task is running, like the web client does.
struct MaintenanceScreen: View {
    let model: AppModel

    /// State of the restart / shutdown buttons.
    private enum ServerAction {
        case idle
        case working
        case completed(String)
        case failed(String)

        var message: String? {
            switch self {
            case .idle: return nil
            case .working: return "サーバーに要求を送信しています…"
            case .completed(let message): return message
            case .failed(let message): return message
            }
        }
    }

    @State private var statuses: [MaintenanceTaskKind: MaintenanceTaskStatus] = [:]
    @State private var runningKinds: Set<MaintenanceTaskKind> = []
    @State private var pollTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var databaseMessage: String?
    @State private var serverAction: ServerAction = .idle
    @State private var showsRestartConfirmation = false
    @State private var showsShutdownConfirmation = false

    private var isAdmin: Bool { model.user?.isAdmin == true }

    var body: some View {
        Group {
            if !isAdmin {
                ContentUnavailableView(
                    "管理者のみ利用できます",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("管理者アカウントでログインしてください。")
                )
            } else {
                list
            }
        }
        .navigationTitle("メンテナンス")
        .navigationBarTitleDisplayMode(.inline)
        .task { startPolling() }
        .onDisappear { pollTask?.cancel() }
        .confirmationDialog(
            "KonomiTV サーバーを再起動しますか？",
            isPresented: $showsRestartConfirmation,
            titleVisibility: .visible
        ) {
            Button("再起動", role: .destructive) {
                Task { await performServerAction(restart: true) }
            }
            .accessibilityIdentifier("maintenance.restart.confirm")

            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("すべての視聴中セッションが切断されます。")
        }
        .confirmationDialog(
            "KonomiTV サーバーをシャットダウンしますか？",
            isPresented: $showsShutdownConfirmation,
            titleVisibility: .visible
        ) {
            Button("シャットダウン", role: .destructive) {
                Task { await performServerAction(restart: false) }
            }
            .accessibilityIdentifier("maintenance.shutdown.confirm")

            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("手動でサーバーを起動するまで KonomiTV にアクセスできなくなります。")
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("maintenance.error")
                }
            }

            logsSection
            databaseSection
            taskSection(kind: .batchScan, title: "録画フォルダの一括スキャン")
            taskSection(kind: .backgroundAnalysis, title: "録画ファイルのバックグラウンド解析")
            taskSection(kind: .captureScan, title: "キャプチャフォルダの一括スキャン")
            taskSection(kind: .databaseVacuum, title: "データベースの最適化")
            serverSection
        }
        .accessibilityIdentifier("maintenance.list")
        .refreshable { await refreshStatuses() }
    }

    private var logsSection: some View {
        Section("サーバーログ") {
            NavigationLink(value: SectionRoute.serverLogs(MaintenanceLogType.server.rawValue)) {
                Label("サーバーログを表示", systemImage: "doc.text")
            }
            .accessibilityIdentifier("maintenance.logs.server")

            NavigationLink(value: SectionRoute.serverLogs(MaintenanceLogType.access.rawValue)) {
                Label("アクセスログを表示", systemImage: "doc.plaintext")
            }
            .accessibilityIdentifier("maintenance.logs.access")
        }
    }

    private var databaseSection: some View {
        Section {
            Button {
                Task { await updateDatabase() }
            } label: {
                Label("データベースを更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("maintenance.updateDatabase")

            if let databaseMessage {
                Text(databaseMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("maintenance.updateDatabase.message")
            }
        } header: {
            Text("データベース")
        } footer: {
            Text("チャンネル情報・番組情報などの外部 API に依存するデータをすべて更新します。")
        }
    }

    private func taskSection(kind: MaintenanceTaskKind, title: String) -> some View {
        Section {
            if let status = statuses[kind] {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(status.isRunning ? "実行中" : "待機中")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Text(status.progressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if status.isRunning {
                        if let fraction = status.fractionCompleted {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("maintenance.\(kind.rawValue).status")
            }

            Button {
                Task { await run(kind) }
            } label: {
                HStack(spacing: 8) {
                    Text(statuses[kind]?.isRunning == true ? "実行中…" : "実行する")
                    if runningKinds.contains(kind) {
                        Spacer(minLength: 0)
                        ProgressView()
                    }
                }
            }
            .disabled(statuses[kind]?.isRunning == true || runningKinds.contains(kind))
            .accessibilityIdentifier("maintenance.\(kind.rawValue).run")
        } header: {
            Text(title)
        }
    }

    private var serverSection: some View {
        Section {
            if let message = serverAction.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("maintenance.server.state")
            }

            Button(role: .destructive) {
                showsRestartConfirmation = true
            } label: {
                Label("KonomiTV サーバーを再起動", systemImage: "arrow.counterclockwise")
            }
            .disabled(isServerActionWorking)
            .accessibilityIdentifier("maintenance.restart")

            Button(role: .destructive) {
                showsShutdownConfirmation = true
            } label: {
                Label("KonomiTV サーバーをシャットダウン", systemImage: "power")
            }
            .disabled(isServerActionWorking)
            .accessibilityIdentifier("maintenance.shutdown")
        } header: {
            Text("サーバー")
        } footer: {
            Text("サーバー設定の変更を反映するには再起動が必要です。")
        }
    }

    // MARK: - Derived state

    private var isAnyRunning: Bool {
        statuses.values.contains { $0.isRunning }
    }

    private var isServerActionWorking: Bool {
        if case .working = serverAction { return true }
        return false
    }

    // MARK: - Actions

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            await refreshStatuses()
            while !Task.isCancelled, isAnyRunning {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                await refreshStatuses()
            }
        }
    }

    private func refreshStatuses() async {
        guard let client = model.client else { return }
        var updated = statuses
        var failed = false
        for kind in MaintenanceTaskKind.allCases {
            do {
                updated[kind] = try await client.maintenanceTaskStatus(kind)
            } catch {
                failed = true
            }
        }
        guard !Task.isCancelled else { return }
        statuses = updated
        errorMessage = failed ? "メンテナンスの進捗を取得できませんでした。" : nil
    }

    private func run(_ kind: MaintenanceTaskKind) async {
        guard let client = model.client, !runningKinds.contains(kind) else { return }
        runningKinds.insert(kind)
        errorMessage = nil
        // 押した直後から実行中として表示し、完了したら進捗を取り直す
        statuses[kind] = MaintenanceTaskStatus(isRunning: true)
        startPolling()

        do {
            try await client.runMaintenanceTask(kind)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }

        runningKinds.remove(kind)
        await refreshStatuses()
        startPolling()
    }

    private func updateDatabase() async {
        guard let client = model.client else { return }
        databaseMessage = "データベースを更新しています…"
        do {
            try await client.updateDatabase()
            databaseMessage = "データベースを更新しました。"
        } catch {
            databaseMessage = ErrorText.message(for: error)
        }
    }

    private func performServerAction(restart: Bool) async {
        guard let client = model.client else { return }
        serverAction = .working

        do {
            if restart {
                try await client.restartServer()
            } else {
                try await client.shutdownServer()
            }
        } catch {
            serverAction = .failed(ErrorText.message(for: error))
            return
        }

        // The server drops the connection while it restarts; poll the version
        // endpoint until it answers again (or give up after 30 seconds).
        var reconnected = false
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            if (try? await client.version()) != nil {
                reconnected = true
                break
            }
        }

        if restart {
            serverAction = .completed(
                reconnected
                    ? "再起動が完了し、サーバーに再接続しました。"
                    : "再起動しています。サーバーに接続できるまで時間がかかる場合があります。"
            )
        } else {
            serverAction = .completed(
                reconnected
                    ? "シャットダウンを要求しました。自動再起動の設定では、まもなく再接続できます。"
                    : "サーバーをシャットダウンしました。"
            )
        }
    }
}

// MARK: - Log viewer

/// サーバーログ: the maintenance log stream
/// (`GET /api/maintenance/logs/{log_type}`) in a monospaced, follow-tail
/// scrollable view.
struct ServerLogScreen: View {
    let model: AppModel
    let initialLogType: MaintenanceLogType

    @State private var logType: MaintenanceLogType
    @State private var lines: [String] = []
    @State private var isFollowing = true
    @State private var statusText = "接続中…"
    @State private var errorMessage: String?
    @State private var generation = 0

    /// The app keeps at most this many lines, so a long-running stream cannot
    /// grow the view without bound.
    private let maximumLineCount = 2000

    init(model: AppModel, initialLogType: MaintenanceLogType) {
        self.model = model
        self.initialLogType = initialLogType
        _logType = State(initialValue: initialLogType)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("ログの種類", selection: $logType) {
                ForEach(MaintenanceLogType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("maintenance.logs.typePicker")

            Toggle("最新の行を追いかける", isOn: $isFollowing)
                .padding(.horizontal)
                .accessibilityIdentifier("maintenance.logs.follow")

            content
        }
        .navigationTitle(logType.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    generation += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("再接続")
                .accessibilityIdentifier("maintenance.logs.reload")
            }
        }
        .task(id: "\(logType.rawValue)-\(generation)") {
            await stream()
        }
        .overlay(alignment: .topLeading) {
            statusLabel(statusText)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("ログを取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再接続") {
                    generation += 1
                }
            }
        } else if lines.isEmpty {
            ProgressView("接続中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("maintenance.logs.line.\(index)")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("maintenance.logs.text")
                .onChange(of: lines.count) { _, count in
                    guard isFollowing, count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }

    /// Invisible status string for the UI tests (connected / failed).
    private func statusLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 1))
            .opacity(0.01)
            .accessibilityLabel(value)
            .accessibilityIdentifier("maintenance.logs.state")
            .allowsHitTesting(false)
    }

    // MARK: - Streaming

    private func stream() async {
        guard let client = model.client else { return }
        lines = []
        errorMessage = nil
        statusText = "接続中…"

        let request = client.maintenanceLogRequest(logType: logType)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw APIError.unauthorized("ログの表示には管理者権限が必要です。")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.httpStatus(http.statusCode, nil)
            }

            statusText = "接続済み"
            var parser = ServerSentEventParser()
            for try await byte in bytes {
                if Task.isCancelled { return }
                for event in parser.append([byte]) {
                    apply(event)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
            statusText = "接続できませんでした"
        }
    }

    private func apply(_ event: ServerSentEvent) {
        guard let data = event.data.data(using: .utf8) else { return }
        switch event.event {
        case "initial_log_update":
            if let decoded = try? JSONCoding.decode([String].self, from: data) {
                lines = decoded.suffix(maximumLineCount).map { $0 }
            }
        case "log_update":
            if let line = try? JSONCoding.decode(String.self, from: data) {
                append(line)
            }
        default:
            break
        }
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > maximumLineCount {
            lines.removeFirst(lines.count - maximumLineCount)
        }
    }
}
