import SwiftUI
import KonomiKit

// MARK: - Status labels

/// The status text the web client's reservation list shows.
enum ReservationStatus {
    static func label(_ reservation: Reservation) -> String {
        if reservation.isRecordingInProgress {
            return "録画中"
        }
        if !reservation.recordSettings.isEnabled {
            return "無効"
        }
        return reservation.recordingAvailability.displayName
    }

    static func systemImage(_ reservation: Reservation) -> String {
        if reservation.isRecordingInProgress {
            return "record.circle.fill"
        }
        if !reservation.recordSettings.isEnabled {
            return "pause.circle"
        }
        switch reservation.recordingAvailability {
        case .full: return "checkmark.circle"
        case .partial: return "exclamationmark.triangle"
        case .unavailable: return "xmark.circle"
        }
    }

    static func color(_ reservation: Reservation) -> Color {
        if reservation.isRecordingInProgress {
            return .red
        }
        if !reservation.recordSettings.isEnabled {
            return .secondary
        }
        switch reservation.recordingAvailability {
        case .full: return .green
        case .partial: return .orange
        case .unavailable: return .red
        }
    }
}

/// Sort order of the reservation list (the web client's 放送が近い順 / 遠い順).
enum ReservationSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending: return "放送が近い順"
        case .descending: return "放送が遠い順"
        }
    }

    func sort(_ reservations: [Reservation]) -> [Reservation] {
        reservations.sorted { left, right in
            switch self {
            case .ascending:
                return left.program.startTime < right.program.startTime
            case .descending:
                return left.program.startTime > right.program.startTime
            }
        }
    }
}

/// The groups of the reservations home (recording now / upcoming / tuner
/// conflicts / disabled), like the web client's sections.
struct ReservationGroups {
    var recordingNow: [Reservation] = []
    var upcoming: [Reservation] = []
    var conflicts: [Reservation] = []
    var disabled: [Reservation] = []

    var isEmpty: Bool {
        recordingNow.isEmpty && upcoming.isEmpty && conflicts.isEmpty && disabled.isEmpty
    }

    static func make(_ reservations: [Reservation], now: Date = Date()) -> ReservationGroups {
        var groups = ReservationGroups()
        let comingLimit = now.addingTimeInterval(24 * 3600)

        for reservation in ReservationSortOrder.ascending.sort(reservations) {
            if reservation.isRecordingInProgress {
                groups.recordingNow.append(reservation)
            } else if !reservation.recordSettings.isEnabled {
                groups.disabled.append(reservation)
            } else if reservation.recordingAvailability != .full {
                groups.conflicts.append(reservation)
            } else if reservation.program.startTime <= comingLimit {
                groups.upcoming.append(reservation)
            }
        }
        return groups
    }
}

// MARK: - Row

/// One reservation of a list.
struct ReservationRow: View {
    let reservation: Reservation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(reservation.program.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Label(
                ReservationStatus.label(reservation),
                systemImage: ReservationStatus.systemImage(reservation)
            )
            .labelStyle(.iconOnly)
            .foregroundStyle(ReservationStatus.color(reservation))
            .accessibilityLabel(ReservationStatus.label(reservation))
        }
        .contentShape(Rectangle())
    }

    private var meta: String {
        let channel = reservation.channel.name.isEmpty
            ? reservation.program.channelID
            : reservation.channel.name
        return "\(channel)・\(Formatters.dateTime(reservation.program.startTime))"
    }
}

// MARK: - Home

/// 録画予約: the recording reservations of the server, grouped like the web
/// client's home screen.
struct ReservationsHomeScreen: View {
    let model: AppModel

    @State private var reservations: [Reservation] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var groups: ReservationGroups { ReservationGroups.make(reservations) }

    var body: some View {
        content
            .navigationTitle("録画予約")
            .task { await load() }
            .refreshable { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if reservations.isEmpty, isLoading {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if reservations.isEmpty, let errorMessage {
            ContentUnavailableView {
                Label("録画予約を取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再試行") {
                    Task { await load() }
                }
            }
        } else {
            List {
                if !model.isEDCBBackend {
                    Section {
                        Label(
                            "録画予約機能は EDCB バックエンド選択時のみ利用できます。",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if groups.isEmpty && !isLoading {
                    Section {
                        ContentUnavailableView(
                            "録画予約はありません",
                            systemImage: "record.circle",
                            description: Text("番組表から録画予約を追加できます。")
                        )
                    }
                }

                section("録画中", reservations: groups.recordingNow)
                section("放送が近い録画予約", reservations: groups.upcoming)
                section("チューナー不足", reservations: groups.conflicts)
                section("無効な予約", reservations: groups.disabled)

                Section {
                    NavigationLink {
                        ReservationsListScreen(model: model)
                    } label: {
                        Label("すべての録画予約", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier("reservations.all")

                    NavigationLink {
                        ReservationConditionsScreen(model: model)
                    } label: {
                        Label("キーワード自動予約条件", systemImage: "text.magnifyingglass")
                    }
                    .accessibilityIdentifier("conditions.link")
                }
            }
            .accessibilityIdentifier("reservations.list")
            .overlay(alignment: .top) {
                if isLoading {
                    ProgressView()
                        .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, reservations: [Reservation]) -> some View {
        if !reservations.isEmpty {
            Section {
                ForEach(reservations) { reservation in
                    NavigationLink(value: SectionRoute.reservation(reservation.id)) {
                        ReservationRow(reservation: reservation)
                    }
                    .accessibilityIdentifier("reservation.\(reservation.id)")
                }
            } header: {
                Text(title)
            }
        }
    }

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        isLoading = reservations.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await client.reservations()
            guard !Task.isCancelled else { return }
            reservations = result.reservations
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - All reservations

/// 録画予約一覧: every reservation, sorted by start time.
struct ReservationsListScreen: View {
    let model: AppModel

    @State private var reservations: [Reservation] = []
    @State private var sortOrder: ReservationSortOrder = .ascending
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        content
            .navigationTitle("録画予約一覧")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("並び順", selection: $sortOrder) {
                            ForEach(ReservationSortOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityIdentifier("reservations.sort")
                    .accessibilityLabel("並び順")
                }
            }
            .task { await load() }
            .refreshable { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if reservations.isEmpty, isLoading {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if reservations.isEmpty, let errorMessage {
            ContentUnavailableView {
                Label("録画予約を取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再試行") {
                    Task { await load() }
                }
            }
        } else if reservations.isEmpty {
            ContentUnavailableView("録画予約はありません", systemImage: "record.circle")
        } else {
            List {
                ForEach(sortOrder.sort(reservations)) { reservation in
                    NavigationLink(value: SectionRoute.reservation(reservation.id)) {
                        ReservationRow(reservation: reservation)
                    }
                    .accessibilityIdentifier("reservation.\(reservation.id)")
                }
            }
            .accessibilityIdentifier("reservations.all.list")
        }
    }

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        isLoading = reservations.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await client.reservations()
            guard !Task.isCancelled else { return }
            reservations = result.reservations
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - Detail

/// 録画予約の詳細: program information plus every record setting the web
/// client's detail drawer exposes.
struct ReservationDetailScreen: View {
    let model: AppModel
    let reservationID: Int

    @State private var reservation: Reservation?
    @State private var draft = RecordSettings()
    @State private var original = RecordSettings()
    @State private var folderPath = ""
    @State private var fileNameTemplate = ""
    @State private var scriptPath = ""
    @State private var startMargin = 5
    @State private var endMargin = 2
    @State private var usesDefaultMargin = true
    @State private var isDeleted = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var showsDeleteConfirmation = false

    private var presets: [RecordSettingsPreset] {
        model.recordingPresets?.presets ?? []
    }

    private var globalDefaults: RecordSettingsGlobalDefaults? {
        model.recordingPresets?.globalDefaults
    }

    /// The settings as edited in the form (the folder and the margins live in
    /// their own fields, so the draft alone is not enough).
    private var editedSettings: RecordSettings {
        var settings = draft

        let folder = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = fileNameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if folder.isEmpty && template.isEmpty {
            settings.recordingFolders = []
        } else {
            settings.recordingFolders = [
                RecordingFolder(
                    recordingFolderPath: folder,
                    recordingFileNameTemplate: template.isEmpty ? nil : template,
                    isOnesegSeparateRecordingFolder:
                        original.recordingFolders.first?.isOnesegSeparateRecordingFolder ?? false
                )
            ]
        }

        if usesDefaultMargin {
            settings.recordingStartMargin = nil
            settings.recordingEndMargin = nil
        } else {
            settings.recordingStartMargin = startMargin
            settings.recordingEndMargin = endMargin
        }

        let script = scriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.postRecordingBatFilePath = script.isEmpty ? nil : script
        return settings
    }

    private var hasChanges: Bool { editedSettings != original }

    /// The server rejects a caption setting without the matching data
    /// broadcasting setting, so the web client blocks this combination too.
    private var isValidContentModes: Bool {
        (draft.captionRecordingMode == .useDefault)
            == (draft.dataBroadcastingRecordingMode == .useDefault)
    }

    private var isRecording: Bool { reservation?.isRecordingInProgress ?? false }

    private var canEdit: Bool { reservation != nil && !isRecording && !isDeleted }

    var body: some View {
        Group {
            if let reservation {
                form(reservation)
            } else if isLoading {
                ProgressView("読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("録画予約を取得できませんでした", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("再試行") {
                        Task { await load() }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("録画予約")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("保存")
                    }
                }
                .disabled(!hasChanges || isSaving || !canEdit || !isValidContentModes)
                .accessibilityIdentifier("reservation.save")
            }
        }
        .task {
            await model.loadDefaultRecordSettings()
            await load()
        }
        .confirmationDialog(
            "録画予約を削除しますか？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("予約を削除", role: .destructive) {
                Task { await delete() }
            }
            .accessibilityIdentifier("reservation.delete.confirm")
            Button("キャンセル", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func form(_ reservation: Reservation) -> some View {
        Form {
            Section {
                Text(reservation.program.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("チャンネル", value: reservation.channel.name)
                LabeledContent(
                    "放送時間",
                    value: "\(Formatters.dateTime(reservation.program.startTime))〜\(Formatters.time(reservation.program.endTime))"
                )
                if !reservation.program.genres.isEmpty {
                    LabeledContent(
                        "ジャンル",
                        value: reservation.program.genres
                            .map { "\($0.major)／\($0.middle)" }
                            .joined(separator: "・")
                    )
                }
                if !reservation.program.description.isEmpty {
                    Text(reservation.program.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("予約状態") {
                Label(
                    ReservationStatus.label(reservation),
                    systemImage: ReservationStatus.systemImage(reservation)
                )
                .foregroundStyle(ReservationStatus.color(reservation))

                if !reservation.comment.isEmpty {
                    LabeledContent("コメント", value: reservation.comment)
                }
                if !reservation.scheduledRecordingFileName.isEmpty {
                    LabeledContent("録画ファイル名", value: reservation.scheduledRecordingFileName)
                }
                LabeledContent(
                    "想定サイズ",
                    value: Formatters.bytes(reservation.estimatedRecordingFileSize)
                )
            }

            if isDeleted {
                Section {
                    Button {
                        Task { await addAgain() }
                    } label: {
                        HStack {
                            Label("予約を追加", systemImage: "record.circle")
                            if isAdding {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isAdding)
                    .accessibilityIdentifier("reservation.add")
                } footer: {
                    Text("この予約は削除されました。同じ番組をもう一度予約できます。")
                }
            } else if canEdit {
                Section {
                    Toggle("有効", isOn: $draft.isEnabled)
                        .accessibilityIdentifier("reservation.enabled")

                    Picker("優先度", selection: $draft.priority) {
                        ForEach(1...5, id: \.self) { priority in
                            Text(String(priority)).tag(priority)
                        }
                    }
                    .accessibilityIdentifier("reservation.priority")

                    if presets.count >= 2 {
                        Menu {
                            ForEach(presets) { preset in
                                Button {
                                    applyPreset(preset)
                                } label: {
                                    Text(preset.name)
                                }
                            }
                        } label: {
                            Text("プリセット")
                        }
                        .accessibilityIdentifier("reservation.preset")
                    }
                } header: {
                    Text("録画設定")
                } footer: {
                    if !isValidContentModes {
                        Text("字幕データ録画設定・データ放送録画設定を明示的に設定する際は、両方とも「デフォルト設定を使う」以外に設定してください。")
                    }
                }

                Section {
                    TextField("録画フォルダのパス", text: $folderPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("reservation.folder")

                    TextField("録画ファイル名テンプレート", text: $fileNameTemplate)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("reservation.filenameTemplate")
                } footer: {
                    Text("空欄にするとサーバーのデフォルトの録画フォルダ・録画ファイル名テンプレートが使われます。")
                }

                Section("録画マージン (秒)") {
                    Toggle("デフォルト設定を使う", isOn: $usesDefaultMargin)
                        .accessibilityIdentifier("reservation.marginDefault")

                    if !usesDefaultMargin {
                        LabeledContent("番組開始") {
                            marginField($startMargin)
                                .accessibilityIdentifier("reservation.startMargin")
                        }
                        LabeledContent("番組終了") {
                            marginField($endMargin)
                                .accessibilityIdentifier("reservation.endMargin")
                        }
                    }
                }

                Section("字幕・データ放送") {
                    Picker("字幕データ", selection: $draft.captionRecordingMode) {
                        ForEach(RecordingContentMode.allCases, id: \.self) { mode in
                            Text(contentLabel(mode, global: globalDefaults?.captionRecordingMode))
                                .tag(mode)
                        }
                    }
                    .accessibilityIdentifier("reservation.caption")

                    Picker("データ放送", selection: $draft.dataBroadcastingRecordingMode) {
                        ForEach(RecordingContentMode.allCases, id: \.self) { mode in
                            Text(contentLabel(
                                mode,
                                global: globalDefaults?.dataBroadcastingRecordingMode
                            ))
                            .tag(mode)
                        }
                    }
                    .accessibilityIdentifier("reservation.dataBroadcasting")
                }

                Section("録画後動作") {
                    Picker("録画後動作", selection: $draft.postRecordingMode) {
                        ForEach(PostRecordingMode.allCases, id: \.self) { mode in
                            Text(postRecordingLabel(mode, global: globalDefaults?.postRecordingMode))
                                .tag(mode)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("reservation.postRecording")

                    TextField("実行スクリプトのパス", text: $scriptPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("reservation.script")
                }

                Section {
                    Button(role: .destructive) {
                        showsDeleteConfirmation = true
                    } label: {
                        Label("予約を削除", systemImage: "trash")
                    }
                    .accessibilityIdentifier("reservation.delete")
                } footer: {
                    if reservation.isKeywordAutoReservation {
                        Text("この予約はキーワード自動予約で追加されました。削除してもすぐに再追加される可能性があります。録画が不要な場合は削除ではなく「無効」にすることをおすすめします。")
                    }
                }
            } else if isRecording {
                Section {
                    Text("録画中のため録画設定は変更できません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .accessibilityIdentifier("reservation.detail")
    }

    private func marginField(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 80)
    }

    private func contentLabel(
        _ mode: RecordingContentMode,
        global: RecordingContentMode?
    ) -> String {
        guard mode == .useDefault, let global else {
            return mode.displayName
        }
        return "デフォルト設定を使う (\(global.displayName))"
    }

    private func postRecordingLabel(
        _ mode: PostRecordingMode,
        global: PostRecordingMode?
    ) -> String {
        guard mode == .useDefault, let global else {
            return mode.displayName
        }
        return "デフォルト設定を使う (\(global.displayName))"
    }

    // MARK: Loading and saving

    private func apply(_ reservation: Reservation) {
        self.reservation = reservation
        let settings = reservation.recordSettings
        draft = settings
        original = settings
        folderPath = settings.recordingFolders.first?.recordingFolderPath ?? ""
        fileNameTemplate = settings.recordingFolders.first?.recordingFileNameTemplate ?? ""
        scriptPath = settings.postRecordingBatFilePath ?? ""
        usesDefaultMargin =
            settings.recordingStartMargin == nil && settings.recordingEndMargin == nil
        startMargin = settings.recordingStartMargin
            ?? globalDefaults?.recordingStartMargin
            ?? 5
        endMargin = settings.recordingEndMargin
            ?? globalDefaults?.recordingEndMargin
            ?? 2
        errorMessage = nil
    }

    private func applyPreset(_ preset: RecordSettingsPreset) {
        let settings = preset.recordSettings
        draft = settings
        folderPath = settings.recordingFolders.first?.recordingFolderPath ?? ""
        fileNameTemplate = settings.recordingFolders.first?.recordingFileNameTemplate ?? ""
        scriptPath = settings.postRecordingBatFilePath ?? ""
        usesDefaultMargin =
            settings.recordingStartMargin == nil && settings.recordingEndMargin == nil
        startMargin = settings.recordingStartMargin
            ?? globalDefaults?.recordingStartMargin
            ?? 5
        endMargin = settings.recordingEndMargin
            ?? globalDefaults?.recordingEndMargin
            ?? 2
    }

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        isLoading = reservation == nil
        defer { isLoading = false }

        do {
            let loaded = try await client.reservation(id: reservationID)
            guard !Task.isCancelled else { return }
            if isDeleted {
                reservation = loaded
            } else {
                apply(loaded)
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func save() async {
        guard let client = model.client, reservation != nil else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let updated = try await client.updateReservation(
                id: reservationID,
                recordSettings: editedSettings
            )
            apply(updated)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func delete() async {
        guard let client = model.client else { return }
        do {
            try await client.deleteReservation(id: reservationID)
            isDeleted = true
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    /// Re-adds the deleted reservation with the settings shown in the form.
    /// The server does not return the new ID, so the reservation list is
    /// searched for the program instead.
    private func addAgain() async {
        guard let client = model.client, let program = reservation?.program else { return }
        isAdding = true
        defer { isAdding = false }

        do {
            try await client.addReservation(
                programID: program.id,
                recordSettings: editedSettings
            )
            let list = try await client.reservations()
            if let added = list.reservations.first(where: { $0.program.id == program.id }) {
                isDeleted = false
                apply(added)
            }
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - Keyword conditions

/// キーワード自動予約条件: the list of keyword recording conditions.
struct ReservationConditionsScreen: View {
    let model: AppModel

    @State private var conditions: [ReservationCondition] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        content
            .navigationTitle("キーワード条件")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ReservationConditionEditor(model: model, condition: nil) {
                            Task { await load() }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("condition.add")
                    .accessibilityLabel("条件を追加")
                }
            }
            .task { await load() }
            .refreshable { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if conditions.isEmpty, isLoading {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if conditions.isEmpty, let errorMessage {
            ContentUnavailableView {
                Label("キーワード条件を取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再試行") {
                    Task { await load() }
                }
            }
        } else if conditions.isEmpty {
            ContentUnavailableView(
                "キーワード条件はありません",
                systemImage: "text.magnifyingglass"
            )
        } else {
            List {
                ForEach(conditions) { condition in
                    NavigationLink {
                        ReservationConditionEditor(model: model, condition: condition) {
                            Task { await load() }
                        }
                    } label: {
                        ConditionRow(condition: condition)
                    }
                    .accessibilityIdentifier("condition.\(condition.id)")
                }
            }
            .accessibilityIdentifier("conditions.list")
        }
    }

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        isLoading = conditions.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await client.reservationConditions()
            guard !Task.isCancelled else { return }
            conditions = result.reservationConditions
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }
}

struct ConditionRow: View {
    let condition: ReservationCondition

    private var summary: String {
        var parts: [String] = []
        if !condition.programSearchCondition.excludeKeyword.isEmpty {
            parts.append("除外: \(condition.programSearchCondition.excludeKeyword)")
        }
        if condition.reservationCount > 0 {
            parts.append("予約 \(condition.reservationCount) 件")
        }
        return parts.joined(separator: "・")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(condition.programSearchCondition.keyword.isEmpty
                    ? "キーワードなし"
                    : condition.programSearchCondition.keyword)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: condition.programSearchCondition.isEnabled
                ? "checkmark.circle"
                : "pause.circle")
                .foregroundStyle(
                    condition.programSearchCondition.isEnabled ? Color.green : Color.secondary
                )
                .accessibilityLabel(condition.programSearchCondition.isEnabled ? "有効" : "無効")
        }
    }
}

/// Create or edit one keyword condition.
struct ReservationConditionEditor: View {
    let model: AppModel
    /// nil when a new condition is created.
    let condition: ReservationCondition?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var searchCondition = ProgramSearchCondition()
    @State private var isEnabled = true
    @State private var keyword = ""
    @State private var excludeKeyword = ""
    @State private var note = ""
    @State private var durationMin = ""
    @State private var durationMax = ""
    @State private var serviceRanges: [ProgramSearchConditionService]?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showsDeleteConfirmation = false

    private var isNew: Bool { condition == nil }

    var body: some View {
        Form {
            Section {
                Toggle("有効", isOn: $isEnabled)
                    .accessibilityIdentifier("condition.enabled")
                TextField("キーワード", text: $keyword)
                    .accessibilityIdentifier("condition.keyword")
                TextField("除外キーワード", text: $excludeKeyword)
                    .accessibilityIdentifier("condition.excludeKeyword")
                TextField("メモ", text: $note)
            }

            Section("検索オプション") {
                Toggle("番組名のみ", isOn: $searchCondition.isTitleOnly)
                Toggle("大文字小文字を区別", isOn: $searchCondition.isCaseSensitive)
                Toggle("あいまい検索", isOn: $searchCondition.isFuzzySearchEnabled)
                Toggle("正規表現", isOn: $searchCondition.isRegexSearchEnabled)
            }

            Section("対象") {
                NavigationLink {
                    ConditionChannelPicker(model: model, selection: $serviceRanges)
                } label: {
                    LabeledContent(
                        "チャンネル",
                        value: serviceRanges == nil
                            ? "すべて"
                            : "\(serviceRanges?.count ?? 0) 件"
                    )
                }
                .accessibilityIdentifier("condition.channels")

                Picker("放送種別", selection: $searchCondition.broadcastType) {
                    Text("すべて").tag(ProgramSearchBroadcastType.all)
                    Text("無料のみ").tag(ProgramSearchBroadcastType.freeOnly)
                    Text("有料のみ").tag(ProgramSearchBroadcastType.paidOnly)
                }

                LabeledContent("番組長 (分)") {
                    HStack(spacing: 6) {
                        TextField("下限", text: $durationMin)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("condition.durationMin")
                        Text("〜")
                            .foregroundStyle(.secondary)
                        TextField("上限", text: $durationMax)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("condition.durationMax")
                    }
                }
            }

            Section("重複チェック") {
                Picker("既存録画の扱い", selection: $searchCondition.duplicateTitleCheckScope) {
                    Text("何もしない").tag(ProgramDuplicateTitleCheckScope.none)
                    Text("同じチャンネルのみ").tag(ProgramDuplicateTitleCheckScope.sameChannelOnly)
                    Text("すべてのチャンネル").tag(ProgramDuplicateTitleCheckScope.allChannels)
                }
                LabeledContent("対象期間 (日)") {
                    TextField(
                        "",
                        value: $searchCondition.duplicateTitleCheckPeriodDays,
                        format: .number
                    )
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                }
            }

            if !isNew {
                Section {
                    Button(role: .destructive) {
                        showsDeleteConfirmation = true
                    } label: {
                        Label("条件を削除", systemImage: "trash")
                    }
                    .accessibilityIdentifier("condition.delete")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isNew ? "条件を追加" : "キーワード条件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("保存")
                    }
                }
                .disabled(isSaving || keyword.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("condition.save")
            }
        }
        .task {
            await model.loadDefaultRecordSettings()
            loadCondition()
        }
        .confirmationDialog(
            "キーワード条件を削除しますか？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                Task { await delete() }
            }
            .accessibilityIdentifier("condition.delete.confirm")
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func loadCondition() {
        guard let condition else { return }
        searchCondition = condition.programSearchCondition
        isEnabled = condition.programSearchCondition.isEnabled
        keyword = condition.programSearchCondition.keyword
        excludeKeyword = condition.programSearchCondition.excludeKeyword
        note = condition.programSearchCondition.note
        serviceRanges = condition.programSearchCondition.serviceRanges
        durationMin = condition.programSearchCondition.durationRangeMin.map(String.init) ?? ""
        durationMax = condition.programSearchCondition.durationRangeMax.map(String.init) ?? ""
    }

    private func composedSearchCondition() -> ProgramSearchCondition {
        var result = searchCondition
        result.isEnabled = isEnabled
        result.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        result.excludeKeyword = excludeKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        result.note = note
        result.serviceRanges = serviceRanges
        result.durationRangeMin = Int(durationMin.trimmingCharacters(in: .whitespaces))
        result.durationRangeMax = Int(durationMax.trimmingCharacters(in: .whitespaces))
        return result
    }

    private func save() async {
        guard let client = model.client, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let search = composedSearchCondition()
        let settings = condition?.recordSettings
            ?? model.defaultRecordSettings
            ?? RecordSettings.fallback

        do {
            if let condition {
                _ = try await client.updateReservationCondition(
                    id: condition.id,
                    programSearchCondition: search,
                    recordSettings: settings
                )
            } else {
                try await client.addReservationCondition(
                    programSearchCondition: search,
                    recordSettings: settings
                )
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func delete() async {
        guard let client = model.client, let condition else { return }
        do {
            try await client.deleteReservationCondition(id: condition.id)
            onSaved()
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Channel range of a keyword condition: every watchable channel, checked when
/// the condition should only search it.
struct ConditionChannelPicker: View {
    let model: AppModel
    @Binding var selection: [ProgramSearchConditionService]?

    @State private var channels: [LiveChannel] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button("すべてのチャンネル") {
                    selection = nil
                }
                .accessibilityIdentifier("condition.channels.all")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(ChannelType.allCases, id: \.self) { type in
                let typeChannels = channels.filter { $0.type == type }
                if !typeChannels.isEmpty {
                    Section {
                        ForEach(typeChannels) { channel in
                            Button {
                                toggle(channel)
                            } label: {
                                HStack {
                                    Text(channel.name)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                    if isSelected(channel) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityIdentifier("condition.channel.\(channel.displayChannelID)")
                        }
                    } header: {
                        Text(type.displayName)
                    }
                }
            }
        }
        .navigationTitle("チャンネル")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("condition.channels.picker")
        .task { await load() }
    }

    private func range(of channel: LiveChannel) -> ProgramSearchConditionService {
        ProgramSearchConditionService(
            networkID: channel.networkID,
            transportStreamID: channel.transportStreamID ?? 0,
            serviceID: channel.serviceID
        )
    }

    private func isSelected(_ channel: LiveChannel) -> Bool {
        guard let selection else { return true }
        return selection.contains(range(of: channel))
    }

    private func toggle(_ channel: LiveChannel) {
        let target = range(of: channel)

        if let current = selection {
            var updated = current
            if let index = updated.firstIndex(of: target) {
                updated.remove(at: index)
            } else {
                updated.append(target)
            }
            // An empty selection means "every channel" again.
            selection = updated.isEmpty ? nil : updated
            return
        }

        // Everything was selected: start from every channel except this one.
        let updated = channels.map { range(of: $0) }.filter { $0 != target }
        selection = updated.isEmpty ? nil : updated
    }

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }
        do {
            let result = try await client.channels()
            guard !Task.isCancelled else { return }
            channels = result.allChannels
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }
}
