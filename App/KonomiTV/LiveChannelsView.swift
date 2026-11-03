import SwiftUI
import UIKit
import KonomiKit

/// テレビ: live channel list with a broadcast type picker (plus a ピン留め
/// segment when channels are pinned), and a program search.
struct LiveChannelsView: View {
    let model: AppModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var channels: LiveChannels?
    @State private var selection: ChannelSelection?
    @State private var errorMessage: String?

    @State private var query = ""
    @State private var searchResults: [Program] = []
    @State private var isSearching = false
    @State private var searchError: String?

    private var isCompact: Bool { horizontalSizeClass == .compact }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        content
            .navigationTitle("テレビ")
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "番組を検索"
            )
            .task { await load() }
            .task(id: trimmedQuery) { await search() }
            .toolbar {
                if isCompact {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: SectionRoute.timetable) {
                            Label("番組表", systemImage: AppSection.timetable.systemImage)
                        }
                        .accessibilityIdentifier("live.timetable")
                    }
                }
            }
    }

    // MARK: - Derived state

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

    private var activeChannels: [LiveChannel] {
        switch activeSelection {
        case .pinned:
            return pinnedChannels
        case .type(let type):
            return model.sortedChannels(channels?.channels(for: type) ?? [])
        }
    }

    private var selectionBinding: Binding<ChannelSelection> {
        Binding(
            get: { activeSelection },
            set: { selection = $0 }
        )
    }

    // MARK: - Views

    @ViewBuilder
    private var content: some View {
        if !trimmedQuery.isEmpty {
            searchResultsView
        } else if let channels, !channels.isEmpty {
            channelList
        } else if channels != nil {
            ContentUnavailableView("チャンネルがありません", systemImage: "tv.slash")
        } else if let errorMessage {
            ContentUnavailableView {
                Label("チャンネルを取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再試行") {
                    Task { await load() }
                }
            }
        } else {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var channelList: some View {
        VStack(spacing: 0) {
            Picker("チャンネル種別", selection: selectionBinding) {
                ForEach(segments, id: \.self) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("live.typePicker")

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300), spacing: 16)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(activeChannels) { channel in
                        NavigationLink(value: SectionRoute.live(channel)) {
                            ChannelCard(
                                channel: channel,
                                logoURL: model.client?.logoURL(channelID: channel.displayChannelID)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("live.channel.\(channel.displayChannelID)")
                        .contextMenu {
                            Button(model.isPinned(channel) ? "ピン留めを外す" : "ピン留めする") {
                                model.togglePin(channel)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .refreshable { await load() }
        }
    }

    @ViewBuilder
    private var searchResultsView: some View {
        if isSearching && searchResults.isEmpty {
            ProgressView("検索中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searchError {
            ContentUnavailableView {
                Label("番組を検索できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(searchError)
            }
        } else if searchResults.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(searchResults) { program in
                        searchRow(program)
                        Divider()
                    }
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("live.searchResults")
        }
    }

    @ViewBuilder
    private func searchRow(_ program: Program) -> some View {
        if let channel = liveChannel(for: program), isAiring(program) {
            NavigationLink(value: SectionRoute.live(channel)) {
                searchRowContent(program, channelName: channel.name)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("live.search.\(program.id)")
        } else {
            searchRowContent(program, channelName: liveChannel(for: program)?.name ?? "")
                .accessibilityIdentifier("live.search.\(program.id)")
        }
    }

    private func searchRowContent(_ program: Program, channelName: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(program.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if !channelName.isEmpty {
                    Text(channelName)
                }
                Text(Formatters.timeRange(start: program.startTime, end: program.endTime))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func liveChannel(for program: Program) -> LiveChannel? {
        channels?.allChannels.first { $0.id == program.channelID }
    }

    private func isAiring(_ program: Program) -> Bool {
        let now = Date()
        return program.startTime <= now && now < program.endTime
    }

    // MARK: - Loading

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        errorMessage = nil

        do {
            let result = try await client.channels()
            guard !Task.isCancelled else { return }
            channels = result
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }

    /// Searches the EPG with the keyword, like the web client's 番組検索 screen
    /// (title and description of the programs that have not ended yet).
    private func search() async {
        let keyword = trimmedQuery
        guard !keyword.isEmpty else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }

        // Debounce typing so the API is not queried on every keystroke.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        guard let client = model.client else { return }

        isSearching = true
        searchError = nil

        do {
            let result = try await client.searchPrograms(.keyword(keyword))
            guard !Task.isCancelled, keyword == trimmedQuery else { return }
            searchResults = result.programs
        } catch {
            guard !Task.isCancelled else { return }
            searchError = ErrorText.message(for: error)
            searchResults = []
        }

        isSearching = false
    }
}

/// One live channel card: logo, name, current program progress and next
/// program.
struct ChannelCard: View {
    let channel: LiveChannel
    let logoURL: URL?

    private var now: Date { Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let program = channel.programPresent {
                VStack(alignment: .leading, spacing: 6) {
                    Text(program.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ProgressView(value: program.progress(at: now))
                        .tint(.accentColor)

                    HStack(spacing: 6) {
                        Text(Formatters.timeRange(start: program.startTime, end: program.endTime))
                        Spacer(minLength: 0)
                        Text(Formatters.percent(program.progress(at: now)))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("番組情報がありません")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let following = channel.programFollowing {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("次")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Text(following.title)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            logo

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text("チャンネル \(channel.channelNumber)")
                    if channel.isRadioChannel {
                        Label("ラジオ", systemImage: "radio")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var logo: some View {
        AsyncImage(url: logoURL) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                placeholderLogo
                    .opacity(phase.error == nil ? 0.4 : 1)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholderLogo: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                Image(systemName: "tv")
                    .foregroundStyle(.secondary)
            )
    }
}
