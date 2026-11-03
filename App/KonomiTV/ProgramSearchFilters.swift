import Foundation
import SwiftUI
import KonomiKit

// MARK: - Filter sheet

/// The filter sheet of the program search screen.
///
/// Mirrors the web client's ProgramSearchFilters.vue: keyword / exclude
/// keyword, title-only / case / fuzzy / regex, genres (also excluded), target
/// channels, broadcast date and time ranges (also excluded), program length
/// and the free / paid broadcast type. Every field is sent in the
/// `POST /api/programs/search` body; the sheet only edits a copy and reports
/// it through `onApply`.
struct ProgramSearchFilterSheet: View {
    let channels: [LiveChannel]
    let initialCondition: ProgramSearchCondition
    let onApply: (ProgramSearchCondition) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var keyword: String
    @State private var excludeKeyword: String
    @State private var isTitleOnly: Bool
    @State private var isCaseSensitive: Bool
    @State private var isFuzzySearchEnabled: Bool
    @State private var isRegexSearchEnabled: Bool
    @State private var genreRanges: [Genre]?
    @State private var isExcludeGenreRanges: Bool
    @State private var serviceRanges: [ProgramSearchConditionService]?
    @State private var dateRanges: [ProgramSearchConditionDate]
    @State private var isExcludeDateRanges: Bool
    @State private var durationMin: String
    @State private var durationMax: String
    @State private var broadcastType: ProgramSearchBroadcastType

    init(
        channels: [LiveChannel],
        condition: ProgramSearchCondition,
        onApply: @escaping (ProgramSearchCondition) -> Void
    ) {
        self.channels = channels
        self.initialCondition = condition
        self.onApply = onApply
        _keyword = State(initialValue: condition.keyword)
        _excludeKeyword = State(initialValue: condition.excludeKeyword)
        _isTitleOnly = State(initialValue: condition.isTitleOnly)
        _isCaseSensitive = State(initialValue: condition.isCaseSensitive)
        _isFuzzySearchEnabled = State(initialValue: condition.isFuzzySearchEnabled)
        _isRegexSearchEnabled = State(initialValue: condition.isRegexSearchEnabled)
        _genreRanges = State(initialValue: condition.genreRanges)
        _isExcludeGenreRanges = State(initialValue: condition.isExcludeGenreRanges)
        _serviceRanges = State(initialValue: condition.serviceRanges)
        _dateRanges = State(initialValue: condition.dateRanges ?? [])
        _isExcludeDateRanges = State(initialValue: condition.isExcludeDateRanges)
        _durationMin = State(
            initialValue: condition.durationRangeMin.map(String.init) ?? ""
        )
        _durationMax = State(
            initialValue: condition.durationRangeMax.map(String.init) ?? ""
        )
        _broadcastType = State(initialValue: condition.broadcastType)
    }

    var body: some View {
        NavigationStack {
            Form {
                keywordSection
                optionSection
                genreSection
                channelSection
                dateSection
                durationSection
                broadcastTypeSection
            }
            .navigationTitle("検索条件")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("search.filter.sheet")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("リセット") {
                        reset()
                    }
                    .accessibilityIdentifier("search.filter.reset")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("検索") {
                        onApply(composedCondition())
                        dismiss()
                    }
                    .accessibilityIdentifier("search.filter.apply")
                }
            }
        }
    }

    // MARK: Sections

    private var keywordSection: some View {
        Section("キーワード") {
            TextField("検索キーワード", text: $keyword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("search.filter.keyword")

            TextField("除外キーワード", text: $excludeKeyword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("search.filter.excludeKeyword")
        }
    }

    private var optionSection: some View {
        Section("検索オプション") {
            Toggle("番組名のみ", isOn: $isTitleOnly)
                .accessibilityIdentifier("search.filter.titleOnly")

            Toggle("大文字小文字を区別", isOn: $isCaseSensitive)
                .accessibilityIdentifier("search.filter.caseSensitive")

            Toggle("あいまい検索", isOn: $isFuzzySearchEnabled)
                .accessibilityIdentifier("search.filter.fuzzy")

            Toggle("正規表現検索", isOn: $isRegexSearchEnabled)
                .accessibilityIdentifier("search.filter.regex")
        }
        .onChange(of: isFuzzySearchEnabled) { _, enabled in
            if enabled { isRegexSearchEnabled = false }
        }
        .onChange(of: isRegexSearchEnabled) { _, enabled in
            if enabled { isFuzzySearchEnabled = false }
        }
    }

    private var genreSection: some View {
        Section {
            NavigationLink {
                ProgramGenreFilterPicker(selection: $genreRanges)
            } label: {
                LabeledContent("ジャンル", value: genreSummary)
            }
            .accessibilityIdentifier("search.filter.genres")

            Toggle("選択したジャンルを除外", isOn: $isExcludeGenreRanges)
                .disabled((genreRanges ?? []).isEmpty)
                .accessibilityIdentifier("search.filter.excludeGenres")
        }
    }

    private var channelSection: some View {
        Section {
            NavigationLink {
                ProgramSearchChannelPicker(
                    channels: channels,
                    selection: $serviceRanges
                )
            } label: {
                LabeledContent("チャンネル", value: channelSummary)
            }
            .accessibilityIdentifier("search.filter.channels")
        }
    }

    private var dateSection: some View {
        Section {
            ForEach(Array(dateRanges.indices), id: \.self) { index in
                ProgramDateRangeEditor(
                    range: dateRangeBinding(index),
                    onDelete: { removeDateRange(index) }
                )
            }

            Button {
                addDateRange()
            } label: {
                Label("日時条件を追加", systemImage: "plus")
            }
            .accessibilityIdentifier("search.filter.addDateRange")

            Toggle("選択した日時を除外", isOn: $isExcludeDateRanges)
                .disabled(dateRanges.isEmpty)
                .accessibilityIdentifier("search.filter.excludeDates")
        } header: {
            Text("放送日時")
        } footer: {
            if dateRanges.isEmpty {
                Text("日時を指定しない場合はすべての放送日時が対象になります。")
            }
        }
    }

    private var durationSection: some View {
        Section("番組長") {
            LabeledContent("最小 (分)") {
                TextField("指定なし", text: $durationMin)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("search.filter.durationMin")
            }
            LabeledContent("最大 (分)") {
                TextField("指定なし", text: $durationMax)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("search.filter.durationMax")
            }
        }
    }

    private var broadcastTypeSection: some View {
        Section {
            Picker("放送種別", selection: $broadcastType) {
                Text("すべて").tag(ProgramSearchBroadcastType.all)
                Text("無料のみ").tag(ProgramSearchBroadcastType.freeOnly)
                Text("有料のみ").tag(ProgramSearchBroadcastType.paidOnly)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("search.filter.broadcastType")
        }
    }

    // MARK: Helpers

    private var genreSummary: String {
        let selected = genreRanges ?? []
        if selected.isEmpty {
            return isExcludeGenreRanges ? "除外オン" : "指定なし"
        }
        return "\(selected.count) 件"
    }

    private var channelSummary: String {
        guard let serviceRanges else { return "すべて" }
        if serviceRanges.isEmpty {
            return "未選択"
        }
        return "\(serviceRanges.count) 件"
    }

    private func dateRangeBinding(_ index: Int) -> Binding<ProgramSearchConditionDate> {
        Binding(
            get: {
                guard dateRanges.indices.contains(index) else {
                    return ProgramSearchConditionDate()
                }
                return dateRanges[index]
            },
            set: { newValue in
                guard dateRanges.indices.contains(index) else { return }
                dateRanges[index] = newValue
            }
        )
    }

    private func addDateRange() {
        dateRanges.append(
            ProgramSearchConditionDate(
                startDayOfWeek: 0,
                startHour: 22,
                startMinute: 0,
                endDayOfWeek: 1,
                endHour: 3,
                endMinute: 59
            )
        )
    }

    private func removeDateRange(_ index: Int) {
        guard dateRanges.indices.contains(index) else { return }
        dateRanges.remove(at: index)
    }

    private func reset() {
        keyword = ""
        excludeKeyword = ""
        isTitleOnly = false
        isCaseSensitive = false
        isFuzzySearchEnabled = false
        isRegexSearchEnabled = false
        genreRanges = nil
        isExcludeGenreRanges = false
        serviceRanges = nil
        dateRanges = []
        isExcludeDateRanges = false
        durationMin = ""
        durationMax = ""
        broadcastType = .all
    }

    private func composedCondition() -> ProgramSearchCondition {
        var condition = initialCondition
        condition.isEnabled = true
        condition.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        condition.excludeKeyword = excludeKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        condition.note = ""
        condition.isTitleOnly = isTitleOnly
        condition.isCaseSensitive = isCaseSensitive
        condition.isFuzzySearchEnabled = isFuzzySearchEnabled
        condition.isRegexSearchEnabled = isRegexSearchEnabled
        condition.genreRanges = (genreRanges ?? []).isEmpty ? nil : genreRanges
        condition.isExcludeGenreRanges = isExcludeGenreRanges
        condition.serviceRanges = serviceRanges
        condition.dateRanges = dateRanges.isEmpty ? nil : dateRanges
        condition.isExcludeDateRanges = isExcludeDateRanges
        condition.durationRangeMin = Int(durationMin.trimmingCharacters(in: .whitespaces))
        condition.durationRangeMax = Int(durationMax.trimmingCharacters(in: .whitespaces))
        condition.broadcastType = broadcastType
        return condition
    }
}

// MARK: - Genre picker

/// Genre ranges of the program search condition.
///
/// Selecting a major genre's "すべて" row is the same shortcut as the web
/// client: it matches every middle genre of that major genre. An empty
/// selection means "every genre" (the server's null).
struct ProgramGenreFilterPicker: View {
    @Binding var selection: [Genre]?

    private let allMiddleLabel = "すべて"

    private var selected: [Genre] { selection ?? [] }

    var body: some View {
        List {
            ForEach(Array(ProgramGenreCatalog.categories.enumerated()), id: \.offset) { majorIndex, category in
                Section {
                    Button {
                        toggleMajor(category.major)
                    } label: {
                        HStack {
                            Text("\(category.major) (すべて)")
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            if isMajorSelected(category.major) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityIdentifier("search.filter.genre.\(majorIndex)")

                    ForEach(Array(category.middles.enumerated()), id: \.offset) { middleIndex, middle in
                        Button {
                            toggleMiddle(major: category.major, middle: middle)
                        } label: {
                            HStack {
                                Text(middle)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                if isSelected(major: category.major, middle: middle) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityIdentifier(
                            "search.filter.genre.\(majorIndex).\(middleIndex)"
                        )
                    }
                } header: {
                    Text(category.major)
                }
            }

            if !selected.isEmpty {
                Section {
                    Button("すべて解除") {
                        selection = nil
                    }
                    .accessibilityIdentifier("search.filter.genre.clear")
                }
            }
        }
        .navigationTitle("ジャンル")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("search.filter.genrePicker")
    }

    private func isMajorSelected(_ major: String) -> Bool {
        selected.contains { $0.major == major && $0.middle == allMiddleLabel }
    }

    private func isSelected(major: String, middle: String) -> Bool {
        isMajorSelected(major) || selected.contains { $0.major == major && $0.middle == middle }
    }

    private func toggleMajor(_ major: String) {
        var updated = selected.filter { $0.major != major }
        if !selected.contains(where: { $0.major == major && $0.middle == allMiddleLabel }) {
            updated.append(Genre(major: major, middle: allMiddleLabel))
        }
        selection = updated.isEmpty ? nil : updated
    }

    private func toggleMiddle(major: String, middle: String) {
        var updated = selected
        let wasMajorSelected = isMajorSelected(major)

        if wasMajorSelected {
            // Expand the "すべて" shortcut into the individual middle genres,
            // leaving out the row that was tapped.
            updated.removeAll { $0.major == major }
            for candidate in ProgramGenreCatalog.middles(of: major) where candidate != middle {
                updated.append(Genre(major: major, middle: candidate))
            }
            selection = updated.isEmpty ? nil : updated
            return
        }

        if let index = updated.firstIndex(where: { $0.major == major && $0.middle == middle }) {
            updated.remove(at: index)
        } else {
            updated.append(Genre(major: major, middle: middle))
        }

        // Every middle genre selected: collapse to the "すべて" shortcut.
        let middles = ProgramGenreCatalog.middles(of: major)
        if !middles.isEmpty, middles.allSatisfy({ candidate in
            updated.contains { $0.major == major && $0.middle == candidate }
        }) {
            updated.removeAll { $0.major == major }
            updated.append(Genre(major: major, middle: allMiddleLabel))
        }
        selection = updated.isEmpty ? nil : updated
    }
}

// MARK: - Channel picker

/// Target channels of the program search condition. `nil` means every
/// channel (the server's null); an empty list explicitly selects nothing.
struct ProgramSearchChannelPicker: View {
    let channels: [LiveChannel]
    @Binding var selection: [ProgramSearchConditionService]?

    var body: some View {
        List {
            Section {
                Button("すべてのチャンネル") {
                    selection = nil
                }
                .accessibilityIdentifier("search.filter.channel.all")
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
                            .accessibilityIdentifier(
                                "search.filter.channel.\(channel.displayChannelID)"
                            )
                        }
                    } header: {
                        Text(type.displayName)
                    }
                }
            }
        }
        .navigationTitle("チャンネル")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("search.filter.channelPicker")
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
}

// MARK: - Date range editor

/// One broadcast date and time range (day of week + time for both ends).
struct ProgramDateRangeEditor: View {
    @Binding var range: ProgramSearchConditionDate
    let onDelete: () -> Void

    private let days = ["日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("日時条件を削除")
                .accessibilityIdentifier("search.filter.deleteDateRange")
            }

            rangeRow(title: "開始", day: $range.startDayOfWeek,
                     hour: $range.startHour, minute: $range.startMinute,
                     prefix: "search.filter.start")
            rangeRow(title: "終了", day: $range.endDayOfWeek,
                     hour: $range.endHour, minute: $range.endMinute,
                     prefix: "search.filter.end")
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let start = "\(days[safe: range.startDayOfWeek] ?? "") \(twoDigits(range.startHour)):\(twoDigits(range.startMinute))"
        let end = "\(days[safe: range.endDayOfWeek] ?? "") \(twoDigits(range.endHour)):\(twoDigits(range.endMinute))"
        return "\(start) 〜 \(end)"
    }

    private func twoDigits(_ value: Int) -> String {
        String(format: "%02d", value)
    }

    private func rangeRow(
        title: String,
        day: Binding<Int>,
        hour: Binding<Int>,
        minute: Binding<Int>,
        prefix: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)

            Picker("曜日", selection: day) {
                ForEach(0..<7, id: \.self) { index in
                    Text(days[index]).tag(index)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("\(prefix).day")

            Picker("時", selection: hour) {
                ForEach(0..<24, id: \.self) { value in
                    Text(twoDigits(value)).tag(value)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("\(prefix).hour")

            Picker("分", selection: minute) {
                ForEach(0..<60, id: \.self) { value in
                    Text(twoDigits(value)).tag(value)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("\(prefix).minute")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Summary

/// Count of the active filters, shown as the badge of the search screen's
/// filter button.
enum ProgramSearchFilterSummary {
    static func activeCount(_ condition: ProgramSearchCondition) -> Int {
        var count = 0
        if !condition.excludeKeyword.isEmpty { count += 1 }
        if condition.isTitleOnly { count += 1 }
        if condition.isCaseSensitive { count += 1 }
        if condition.isFuzzySearchEnabled { count += 1 }
        if condition.isRegexSearchEnabled { count += 1 }
        if !(condition.genreRanges ?? []).isEmpty { count += 1 }
        if condition.isExcludeGenreRanges { count += 1 }
        if condition.serviceRanges != nil { count += 1 }
        if !(condition.dateRanges ?? []).isEmpty { count += 1 }
        if condition.isExcludeDateRanges { count += 1 }
        if condition.durationRangeMin != nil || condition.durationRangeMax != nil { count += 1 }
        if condition.broadcastType != .all { count += 1 }
        return count
    }
}
