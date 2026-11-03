import SwiftUI
import UIKit
import KonomiKit

/// Day boundaries of the timetable.
///
/// The web client's `TimeTableStore.getTodayStartTime()` treats 00:00–03:59 as
/// the previous broadcast day, so a day runs from 04:00 to the next 04:00.
enum TimeTableDay {
    static let boundaryHour = 4

    /// Start (04:00) of the broadcast day containing `date`.
    static func start(for date: Date, calendar: Calendar = .current) -> Date {
        let boundary = calendar.date(
            bySettingHour: boundaryHour,
            minute: 0,
            second: 0,
            of: date
        ) ?? date

        if calendar.component(.hour, from: date) < boundaryHour {
            return calendar.date(byAdding: .day, value: -1, to: boundary) ?? boundary
        }
        return boundary
    }
}

/// Genre highlight colours of the timetable, mirroring the web client's default
/// `timetable_genre_colors`.
enum TimeTableGenreColors {
    static let defaults: [String: String] = [
        "ニュース・報道": "White",
        "情報・ワイドショー": "White",
        "ドキュメンタリー・教養": "Blue",
        "スポーツ": "Cyan",
        "ドラマ": "Pink",
        "アニメ・特撮": "Yellow",
        "バラエティ": "Lime",
        "音楽": "Orange",
        "映画": "Brown",
        "劇場・公演": "Ochre",
        "趣味・教育": "Teal",
        "福祉": "White",
        "その他": "White",
    ]

    /// Colour of a genre major category, using the user's settings when present.
    static func color(forGenreMajor major: String, settings: ClientSettings) -> Color {
        let configured = settings.value(forKey: "timetable_genre_colors")?.objectValue?
            .compactMapValues { $0.stringValue } ?? [:]
        let table = configured.isEmpty ? defaults : configured

        if let name = table[major] {
            return color(named: name)
        }
        // ARIB uses both "/" and "・" as the separator of the major genre.
        if let name = table[major.replacingOccurrences(of: "/", with: "・")] {
            return color(named: name)
        }
        if let name = table[major.replacingOccurrences(of: "・", with: "/")] {
            return color(named: name)
        }
        return color(named: table["その他"] ?? "White")
    }

    static func color(named name: String) -> Color {
        switch name {
        case "Pink": return Color(red: 0.96, green: 0.45, blue: 0.62)
        case "Red": return Color(red: 0.90, green: 0.30, blue: 0.28)
        case "Orange": return Color(red: 0.96, green: 0.60, blue: 0.20)
        case "Yellow": return Color(red: 0.93, green: 0.80, blue: 0.25)
        case "Lime": return Color(red: 0.62, green: 0.80, blue: 0.28)
        case "Teal": return Color(red: 0.25, green: 0.70, blue: 0.66)
        case "Cyan": return Color(red: 0.30, green: 0.72, blue: 0.88)
        case "Blue": return Color(red: 0.32, green: 0.51, blue: 0.90)
        case "Ochre": return Color(red: 0.80, green: 0.63, blue: 0.24)
        case "Brown": return Color(red: 0.62, green: 0.45, blue: 0.32)
        default: return Color(white: 0.62)
        }
    }
}

/// Horizontal scroll offset of the grid, shared with the channel header so the
/// header follows horizontal scrolling while staying pinned vertically.
///
/// Only mutated from the main actor; `Sendable` so the offset updates can be
/// handed to the main actor from the scroll preference callback.
@Observable
final class TimeTableScrollState: @unchecked Sendable {
    var offset: CGFloat = 0

    func update(_ value: CGFloat) {
        guard abs(value - offset) > 0.5 else { return }
        offset = value
    }
}

private struct TimeTableOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 番組表: the program guide grid.
struct TimeTableScreen: View {
    let model: AppModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var channels: LiveChannels?
    @State private var table: TimeTable?
    @State private var selection: ChannelSelection?
    @State private var dayOffset = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedProgram: TimeTableProgram?
    @State private var scrollState = TimeTableScrollState()
    @State private var now = Date()
    /// Set when the program sheet changed a recording reservation, so the grid
    /// (and its reservation markers) is reloaded once the sheet closes.
    @State private var reservationDidChange = false

    private let calendar = Calendar.current

    // MARK: - Geometry

    private var isRegular: Bool { horizontalSizeClass == .regular }
    private var hourHeight: CGFloat { isRegular ? 200 : 120 }
    private var columnWidth: CGFloat { isRegular ? 150 : 112 }
    private var timeScaleWidth: CGFloat { isRegular ? 54 : 40 }
    private var headerHeight: CGFloat { isRegular ? 54 : 46 }
    private var contentHeight: CGFloat { hourHeight * 24 }

    private var displayChannels: [TimeTableChannel] { table?.channels ?? [] }
    private var contentWidth: CGFloat { columnWidth * CGFloat(max(displayChannels.count, 1)) }

    // MARK: - Day

    private var todayStart: Date { TimeTableDay.start(for: Date(), calendar: calendar) }

    private var dayStart: Date {
        calendar.date(byAdding: .day, value: dayOffset, to: todayStart) ?? todayStart
    }

    private var dayEnd: Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    }

    private func dayTitle(_ offset: Int) -> String {
        let start = calendar.date(byAdding: .day, value: offset, to: todayStart) ?? todayStart
        return Formatters.date(start)
    }

    // MARK: - Channel selection

    private var availableTypes: [ChannelType] {
        guard let channels else { return [] }
        return ChannelType.allCases.filter { !channels.channels(for: $0).isEmpty }
    }

    private var pinnedChannels: [LiveChannel] {
        guard let channels else { return [] }
        return model.pinnedChannels(in: channels)
    }

    private var segments: [ChannelSelection] {
        var result: [ChannelSelection] = []
        if !pinnedChannels.isEmpty {
            result.append(.pinned)
        }
        result.append(contentsOf: availableTypes.map { .type($0) })
        return result
    }

    private var activeSelection: ChannelSelection {
        if let selection, segments.contains(selection) {
            return selection
        }
        return segments.first ?? .type(.gr)
    }

    private var selectionBinding: Binding<ChannelSelection> {
        Binding(
            get: { activeSelection },
            set: { selection = $0 }
        )
    }

    // MARK: - Body

    var body: some View {
        content
            .navigationTitle("番組表")
            .task {
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .task(id: reloadKey) {
                await load()
            }
            .sheet(item: $selectedProgram, onDismiss: reloadAfterReservationChange) { item in
                TimeTableProgramDetail(
                    model: model,
                    item: item,
                    channel: channel(for: item),
                    didChangeReservation: $reservationDidChange
                )
            }
    }

    /// Reloads the timetable when the program sheet reserved or cancelled a
    /// reservation, so the program cells show the new marker.
    private func reloadAfterReservationChange() {
        guard reservationDidChange else { return }
        reservationDidChange = false
        Task { await load() }
    }

    private var reloadKey: String {
        let pinned = activeSelection == .pinned
            ? pinnedChannels.map(\.id).joined(separator: ",")
            : ""
        return "\(activeSelection.title)|\(dayOffset)|\(pinned)"
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            controls

            if !displayChannels.isEmpty {
                grid
            } else if isLoading {
                ProgressView("読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("番組表を取得できませんでした", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("再試行") {
                        Task { await load() }
                    }
                }
            } else {
                ContentUnavailableView("番組表がありません", systemImage: "calendar")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Picker("チャンネル種別", selection: selectionBinding) {
                ForEach(segments, id: \.self) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("timetable.typePicker")

            HStack(spacing: 12) {
                Button {
                    dayOffset = max(dayOffset - 1, 0)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(dayOffset == 0)
                .accessibilityIdentifier("timetable.previousDay")

                Menu {
                    ForEach(0..<7, id: \.self) { offset in
                        Button(dayTitle(offset)) {
                            dayOffset = offset
                        }
                        .accessibilityIdentifier("timetable.day.\(offset)")
                    }
                } label: {
                    Text(dayTitle(dayOffset))
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 96)
                }
                .accessibilityIdentifier("timetable.dayPicker")

                Button {
                    dayOffset = min(dayOffset + 1, 6)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(dayOffset >= 6)
                .accessibilityIdentifier("timetable.nextDay")

                Button {
                    dayOffset = 0
                    now = Date()
                } label: {
                    Image(systemName: "clock")
                }
                .accessibilityIdentifier("timetable.now")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // A separate view, so only the header (not the whole grid)
                // re-renders while the grid scrolls horizontally.
                TimeTableHeaderRow(
                    model: model,
                    channels: displayChannels.map(\.channel),
                    scrollState: scrollState,
                    timeScaleWidth: timeScaleWidth,
                    columnWidth: columnWidth,
                    height: headerHeight
                )

                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        timeScale
                        horizontalGrid
                    }
                }
                .accessibilityIdentifier("timetable.grid")
            }
            .onAppear { scrollToInitial(proxy) }
            .onChange(of: reloadKey) { _, _ in
                scrollToInitial(proxy)
            }
            // The first load arrives after the screen appeared, so scroll to
            // the current time once the grid has channels.
            .onChange(of: displayChannels.count) { _, _ in
                scrollToInitial(proxy)
            }
        }
    }

    private var horizontalGrid: some View {
        // Captured by the closure below instead of `self`, which keeps the
        // preference callback free of a non-Sendable view capture.
        let offsetState = self.scrollState

        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(displayChannels) { entry in
                    channelColumn(entry)
                }
            }
            .frame(height: contentHeight, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                currentTimeLine
            }
            .background(offsetReader)
        }
        .frame(height: contentHeight)
        .coordinateSpace(name: "timetable.horizontal")
        .onPreferenceChange(TimeTableOffsetKey.self) { value in
            Task { @MainActor in
                offsetState.update(value)
            }
        }
    }

    private var offsetReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: TimeTableOffsetKey.self,
                value: proxy.frame(in: .named("timetable.horizontal")).minX
            )
        }
    }

    private var timeScale: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: timeScaleWidth, height: hourHeight, alignment: .topTrailing)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 0.5)
                    }
                    .id("hour-\(hour)")
            }
        }
        .frame(width: timeScaleWidth)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .trailing) { Divider() }
    }

    /// Hour of the day at `offset` hours after the 04:00 boundary, using the
    /// 28 hour clock when the user enabled it.
    private func hourLabel(_ offset: Int) -> String {
        let hour = (TimeTableDay.boundaryHour + offset) % 24
        let displayHour = model.settings.use28HourClock ? TimeTableDay.boundaryHour + offset : hour
        return String(format: "%02d", displayHour)
    }

    private func channelColumn(_ entry: TimeTableChannel) -> some View {
        ZStack(alignment: .topLeading) {
            hourLines

            ForEach(entry.programs) { item in
                if let geometry = geometry(for: item.program) {
                    programCell(item)
                        .frame(
                            width: columnWidth - 3,
                            height: geometry.height,
                            alignment: .topLeading
                        )
                        .offset(x: 1.5, y: geometry.offsetY + 1)
                }
            }
        }
        .frame(width: columnWidth, height: contentHeight, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .trailing) { Divider() }
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Color.clear
                    .frame(height: hourHeight)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.12))
                            .frame(height: 0.5)
                    }
            }
        }
        .frame(height: contentHeight, alignment: .top)
    }

    private func programCell(_ item: TimeTableProgram) -> some View {
        let program = item.program
        let color = TimeTableGenreColors.color(
            forGenreMajor: program.genres.first?.major ?? "",
            settings: model.settings
        )
        let isShopping = program.genres.contains { $0.middle == "ショッピング・通販" }
        let isDimmed = isShopping && model.settings.timetableDimShoppingPrograms

        return Button {
            selectedProgram = item
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(program.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(Formatters.timeRange(start: program.startTime, end: program.endTime))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                isDimmed
                    ? Color.secondary.opacity(0.08)
                    : color.opacity(0.22),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isDimmed ? Color.secondary.opacity(0.4) : color)
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(isDimmed ? 0.6 : 1)
            .overlay(alignment: .topTrailing) {
                if let reservation = item.reservation {
                    reservationMarker(reservation, program: program)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("timetable.program.\(program.id)")
        .accessibilityLabel(program.title)
    }

    /// The web client's reservation marker of a timetable cell: an icon in the
    /// corner, coloured by the reservation status.
    private func reservationMarker(
        _ reservation: TimeTableProgramReservation,
        program: Program
    ) -> some View {
        Image(systemName: Self.markerSystemImage(reservation))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Self.markerColor(reservation))
            .padding(2)
            .background(Color(uiColor: .systemBackground).opacity(0.75), in: Circle())
            .padding(2)
            .accessibilityIdentifier("timetable.reserved.\(program.id)")
            .accessibilityLabel(Self.markerLabel(reservation))
    }

    static func markerSystemImage(_ reservation: TimeTableProgramReservation) -> String {
        switch reservation.status {
        case .recording: return "record.circle.fill"
        case .disabled: return "pause.circle.fill"
        case .reserved:
            switch reservation.recordingAvailability {
            case .full: return "checkmark.circle.fill"
            case .partial: return "exclamationmark.triangle.fill"
            case .unavailable: return "xmark.circle.fill"
            }
        }
    }

    static func markerColor(_ reservation: TimeTableProgramReservation) -> Color {
        switch reservation.status {
        case .recording: return .red
        case .disabled: return .secondary
        case .reserved:
            switch reservation.recordingAvailability {
            case .full: return .accentColor
            case .partial: return .orange
            case .unavailable: return .red
            }
        }
    }

    static func markerLabel(_ reservation: TimeTableProgramReservation) -> String {
        switch reservation.status {
        case .recording: return "録画中"
        case .disabled: return "録画予約 (無効)"
        case .reserved:
            switch reservation.recordingAvailability {
            case .full: return "録画予約済み"
            case .partial: return "録画予約済み (一部のみ録画)"
            case .unavailable: return "録画予約済み (チューナー不足)"
            }
        }
    }

    @ViewBuilder
    private var currentTimeLine: some View {
        if isShowingNow {
            Rectangle()
                .fill(Color.red)
                .frame(height: 1.5)
                .offset(y: nowOffset)
                .allowsHitTesting(false)
        }
    }

    private var isShowingNow: Bool {
        now >= dayStart && now < dayEnd
    }

    private var nowOffset: CGFloat {
        CGFloat(now.timeIntervalSince(dayStart) / 3600) * hourHeight
    }

    // MARK: - Layout maths

    private struct CellGeometry {
        let offsetY: CGFloat
        let height: CGFloat
    }

    private func geometry(for program: Program) -> CellGeometry? {
        let start = max(program.startTime, dayStart)
        let end = min(program.endTime, dayEnd)
        guard end > start else { return nil }

        let offset = CGFloat(start.timeIntervalSince(dayStart) / 3600) * hourHeight
        let height = CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight
        return CellGeometry(offsetY: offset, height: max(height - 2, 16))
    }

    private func channel(for item: TimeTableProgram) -> Channel? {
        guard let entry = displayChannels.first(where: { entry in
            entry.programs.contains { $0.program.id == item.program.id }
        }) else {
            return nil
        }
        return entry.channel
    }

    // MARK: - Scrolling

    private func scrollToInitial(_ proxy: ScrollViewProxy) {
        guard !displayChannels.isEmpty else { return }
        proxy.scrollTo("hour-\(initialHourOffset)", anchor: .top)
    }

    /// Current broadcast hour (with one hour of context above) for today, the
    /// first hour of another day.
    private var initialHourOffset: Int {
        guard dayOffset == 0 else { return 0 }
        let hour = calendar.component(.hour, from: Date())
        let broadcastHour = hour < TimeTableDay.boundaryHour ? hour + 24 : hour
        return min(max(broadcastHour - TimeTableDay.boundaryHour - 1, 0), 23)
    }

    // MARK: - Loading

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        isLoading = table == nil
        errorMessage = nil
        defer { isLoading = false }

        do {
            if channels == nil {
                channels = try await client.channels()
            }
            guard !Task.isCancelled else { return }

            let pinned: [String]
            let channelType: ChannelType?
            switch activeSelection {
            case .pinned:
                pinned = pinnedChannels.map(\.id)
                channelType = nil
            case .type(let type):
                pinned = []
                channelType = type
            }

            let result = try await client.timetable(
                startTime: dayStart,
                endTime: dayEnd,
                channelType: channelType,
                pinnedChannelIDs: pinned
            )
            guard !Task.isCancelled else { return }
            table = result
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Channel names above the grid. Pinned vertically, it follows the grid's
/// horizontal scroll offset.
private struct TimeTableHeaderRow: View {
    let model: AppModel
    let channels: [Channel]
    let scrollState: TimeTableScrollState
    let timeScaleWidth: CGFloat
    let columnWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: timeScaleWidth, height: height)
                .overlay(alignment: .trailing) { Divider() }

            HStack(spacing: 0) {
                ForEach(channels) { channel in
                    channelHeader(channel)
                        .frame(width: columnWidth, height: height)
                }
            }
            .frame(width: columnWidth * CGFloat(max(channels.count, 1)), height: height, alignment: .leading)
            .offset(x: -scrollState.offset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .clipped()
        }
        .frame(height: height)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func channelHeader(_ channel: Channel) -> some View {
        HStack(spacing: 6) {
            AsyncImage(url: model.client?.logoURL(channelID: channel.displayChannelID)) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "tv")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(channel.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { Divider() }
    }
}

/// Detail sheet of a timetable program.
private struct TimeTableProgramDetail: View {
    let model: AppModel
    let item: TimeTableProgram
    let channel: Channel?
    /// Set when this sheet reserved, changed or cancelled a reservation, so the
    /// timetable reloads its cells (and markers) after the sheet closes.
    @Binding var didChangeReservation: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var reservation: Reservation?
    @State private var isLoadingReservation = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showsCancelConfirmation = false

    private var program: Program { item.program }

    private var isAiring: Bool {
        let now = Date()
        return program.startTime <= now && now < program.endTime
    }

    private var detailRows: [(key: String, value: String)] {
        program.detail
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }

    private var presets: [RecordSettingsPreset] {
        model.recordingPresets?.presets ?? []
    }

    private var isPastProgram: Bool { program.endTime <= Date() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(program.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("timetable.detail.title")

                    HStack(spacing: 8) {
                        if let channel {
                            Text(channel.name)
                        }
                        Text(Formatters.timeRange(start: program.startTime, end: program.endTime))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if !program.genres.isEmpty {
                        Text(program.genres.map { "\($0.major)／\($0.middle)" }.joined(separator: "・"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if isAiring, let channel {
                        Button {
                            // Through the live stack, so PiP restore and the
                            // shared player behave as for any live channel.
                            dismiss()
                            model.restore(.live(LiveChannel(channel: channel)))
                        } label: {
                            Label("視聴する", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("timetable.detail.watch")
                    }

                    reservationActions

                    if !program.description.isEmpty {
                        Text(program.description)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(detailRows, id: \.key) { row in
                        LabeledContent(row.key, value: row.value)
                            .font(.footnote)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("番組詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
            .task {
                await model.loadDefaultRecordSettings()
                await loadReservation()
            }
            .confirmationDialog(
                "録画予約をキャンセルしますか？",
                isPresented: $showsCancelConfirmation,
                titleVisibility: .visible
            ) {
                Button("予約をキャンセル", role: .destructive) {
                    Task { await cancelReservation() }
                }
                .accessibilityIdentifier("timetable.program.reservation.cancel.confirm")
                Button("戻る", role: .cancel) {}
            }
        }
    }

    /// Reserve / change / cancel, like the web client's timetable cell actions.
    @ViewBuilder
    private var reservationActions: some View {
        if !model.isEDCBBackend {
            EmptyView()
        } else if let reservation {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: ReservationStatus.systemImage(reservation))
                        .foregroundStyle(ReservationStatus.color(reservation))
                    Text(ReservationStatus.label(reservation))
                        .font(.subheadline.weight(.semibold))
                }

                NavigationLink {
                    ReservationDetailScreen(model: model, reservationID: reservation.id)
                } label: {
                    Label("予約の詳細", systemImage: "info.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("timetable.program.reservation.detail")

                if !isPastProgram {
                    Menu {
                        ForEach(presets) { preset in
                            Button {
                                Task { await changeSettings(preset.recordSettings) }
                            } label: {
                                Text(preset.name)
                            }
                        }
                        Divider()
                        Button(reservation.recordSettings.isEnabled ? "予約を無効化" : "予約を有効化") {
                            Task { await setEnabled(!reservation.recordSettings.isEnabled) }
                        }
                    } label: {
                        Label("予約を変更", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking || presets.isEmpty)
                    .accessibilityIdentifier("timetable.program.reservation.change")

                    Button(role: .destructive) {
                        showsCancelConfirmation = true
                    } label: {
                        Label("予約をキャンセル", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                    .accessibilityIdentifier("timetable.program.reservation.cancel")
                }
            }
        } else if !isPastProgram, !isLoadingReservation {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task { await reserve(nil) }
                } label: {
                    Label("録画予約", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
                .accessibilityIdentifier("timetable.program.reserve")

                if presets.count > 1 {
                    Menu {
                        ForEach(presets) { preset in
                            Button {
                                Task { await reserve(preset.recordSettings) }
                            } label: {
                                Text(preset.name)
                            }
                        }
                    } label: {
                        Label("プリセットを選んで予約", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                    .accessibilityIdentifier("timetable.program.reserve.preset")
                }
            }
        }
    }

    // MARK: Actions

    private func loadReservation() async {
        guard let summary = item.reservation, let client = model.client else { return }
        isLoadingReservation = true
        defer { isLoadingReservation = false }
        reservation = try? await client.reservation(id: summary.id)
    }

    private func reserve(_ preset: RecordSettings?) async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }
        isWorking = true
        defer { isWorking = false }

        let settings: RecordSettings
        if let preset {
            settings = preset
        } else {
            settings = await model.loadDefaultRecordSettings()
        }
        do {
            try await client.addReservation(
                programID: program.id,
                recordSettings: settings,
                program: ReservationAddProgram(program: program)
            )
            didChangeReservation = true
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    /// Applies the given settings to the reservation. The enabled flag is kept
    /// as given: a preset must not enable a disabled reservation by accident,
    /// the menu has its own entry for that.
    private func changeSettings(_ settings: RecordSettings) async {
        guard let client = model.client, let reservation else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            self.reservation = try await client.updateReservation(
                id: reservation.id,
                recordSettings: settings
            )
            didChangeReservation = true
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func setEnabled(_ enabled: Bool) async {
        guard var settings = reservation?.recordSettings else { return }
        settings.isEnabled = enabled
        await changeSettings(settings)
    }

    private func cancelReservation() async {
        guard let client = model.client, let reservation else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            try await client.deleteReservation(id: reservation.id)
            didChangeReservation = true
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

extension LiveChannel {
    /// The live channel that corresponds to a timetable / program channel.
    init(channel: Channel) {
        self.init(
            id: channel.id,
            displayChannelID: channel.displayChannelID,
            networkID: channel.networkID,
            serviceID: channel.serviceID,
            transportStreamID: channel.transportStreamID,
            remoconID: channel.remoconID,
            channelNumber: channel.channelNumber,
            type: channel.type,
            name: channel.name,
            isSubChannel: channel.isSubChannel,
            isRadioChannel: channel.isRadioChannel,
            isWatchable: channel.isWatchable,
            isDisplay: true,
            viewerCount: 0,
            programPresent: nil,
            programFollowing: nil,
            jikkyoForce: channel.jikkyoForce
        )
    }
}
