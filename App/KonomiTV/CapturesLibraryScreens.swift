import SwiftUI
import KonomiKit

// MARK: - Library

/// キャプチャ: the timeline, the program albums and the tags
/// (views/Captures/*.vue of the web client).
///
/// Only reachable when the server has the captures library (v0.15+); AppModel
/// hides the section on a v0.14.1 server.
struct CapturesLibraryScreen: View {
    let model: AppModel

    enum Tab: String, CaseIterable, Identifiable {
        case timeline
        case programs
        case tags

        var id: String { rawValue }

        var title: String {
            switch self {
            case .timeline: return "タイムライン"
            case .programs: return "番組"
            case .tags: return "タグ"
            }
        }
    }

    @State private var tab: Tab = .timeline

    var body: some View {
        VStack(spacing: 0) {
            Picker("表示", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("captures.tabs")

            switch tab {
            case .timeline:
                CaptureTimelineScreen(model: model)
            case .programs:
                CaptureProgramsScreen(model: model)
            case .tags:
                CaptureTagsScreen(model: model)
            }
        }
        .navigationTitle("キャプチャ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared pieces

/// Index of the capture the viewer opens on.
struct CaptureViewerTarget: Identifiable {
    let id: Int
}

/// Thumbnail of a capture, 16:9 with the server's image.
struct CaptureThumbnail: View {
    let url: URL?
    let isFavorite: Bool
    let isCaptionComposited: Bool
    let isCommentComposited: Bool

    var body: some View {
        AsyncImage(url: url) { phase in
            ZStack {
                Color.secondary.opacity(0.15)
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if phase.error != nil {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if isCaptionComposited {
                    badge("captions.bubble.fill")
                }
                if isCommentComposited {
                    badge("text.bubble.fill")
                }
                if isFavorite {
                    badge("heart.fill")
                }
            }
            .padding(6)
        }
    }

    private func badge(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.55), in: Circle())
    }
}

// MARK: - Timeline

/// キャプチャ → タイムライン: every capture, grouped by day, with infinite
/// scrolling, sorting and filtering.
struct CaptureTimelineScreen: View {
    let model: AppModel

    @State private var captures: [Capture] = []
    @State private var programs: [Int: CaptureProgram] = [:]
    @State private var nextCursor: String?
    @State private var order: CaptureSortOrder = .capturedAtDesc
    @State private var filters = CaptureFilters()
    @State private var channels: [CaptureChannel] = []
    @State private var tags: [CaptureTag] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selection: Set<Int> = []
    @State private var isSelecting = false
    @State private var viewerTarget: CaptureViewerTarget?
    @State private var actionMessage: String?

    private var isLoggedIn: Bool { model.user != nil }
    private var isAdmin: Bool { model.user?.isAdmin == true }

    private struct LoadKey: Hashable {
        let order: CaptureSortOrder
        let filters: CaptureFilters
    }

    private struct DaySection: Identifiable {
        let day: String
        let captures: [Capture]

        var id: String { day }
    }

    var body: some View {
        content
            .accessibilityIdentifier("captures.timeline")
            .task(id: LoadKey(order: order, filters: filters)) {
                await load(reset: true)
            }
            .task(id: isLoggedIn) {
                await loadFilters()
            }
            .alert(
                "エラー",
                isPresented: Binding(
                    get: { actionMessage != nil },
                    set: { if !$0 { actionMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { actionMessage = nil }
            } message: {
                Text(actionMessage ?? "")
            }
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                selectionBar
            }
            .fullScreenCover(item: $viewerTarget) { target in
                CaptureViewer(
                    model: model,
                    initialCaptures: captures,
                    programs: programs,
                    initialIndex: target.id,
                    onCaptureChanged: { updated in
                        if let index = captures.firstIndex(where: { $0.id == updated.id }) {
                            captures[index] = updated
                        }
                    },
                    onCapturesDeleted: { ids in
                        let deleted = Set(ids)
                        captures.removeAll { deleted.contains($0.id) }
                    }
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if captures.isEmpty, isLoading {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, captures.isEmpty {
            ContentUnavailableView {
                Label("キャプチャを取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再試行") {
                    Task { await load(reset: true) }
                }
            }
        } else if captures.isEmpty {
            ContentUnavailableView("キャプチャはありません", systemImage: "photo.on.rectangle")
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                ForEach(daySections) { section in
                    Section {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(section.captures) { capture in
                                cell(capture)
                            }
                        }
                    } header: {
                        Text(section.day)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .background(.bar)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if nextCursor != nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task {
                            await load(reset: false)
                        }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private func cell(_ capture: Capture) -> some View {
        Button {
            if isSelecting {
                toggleSelection(capture.id)
            } else {
                viewerTarget = CaptureViewerTarget(id: index(of: capture))
            }
        } label: {
            ZStack(alignment: .topLeading) {
                CaptureThumbnail(
                    url: imageURL(for: capture),
                    isFavorite: capture.isFavorite == true,
                    isCaptionComposited: capture.isCaptionComposited,
                    isCommentComposited: capture.isCommentComposited
                )
                if isSelecting {
                    Image(systemName: selection.contains(capture.id)
                        ? "checkmark.circle.fill"
                        : "circle")
                        .font(.title3)
                        .foregroundStyle(
                            Color.white,
                            selection.contains(capture.id)
                                ? Color.accentColor
                                : Color.black.opacity(0.4)
                        )
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("captures.item.\(capture.id)")
        .contextMenu {
            favoriteButton(for: [capture.id], isFavorite: capture.isFavorite == true)
            tagMenu(for: [capture.id])
            if isAdmin {
                Button("削除", role: .destructive) {
                    delete([capture.id])
                }
            }
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if isSelecting {
            HStack(spacing: 20) {
                Button {
                    favoriteSelection()
                } label: {
                    Label("お気に入り", systemImage: "heart")
                }
                .disabled(!isLoggedIn || selection.isEmpty)

                Menu {
                    ForEach(tags) { tag in
                        Button(tag.name) {
                            applyTag(tag, to: Array(selection))
                        }
                    }
                } label: {
                    Label("タグ", systemImage: "tag")
                }
                .disabled(!isLoggedIn || selection.isEmpty || tags.isEmpty)
                .accessibilityIdentifier("capture.tag.add")

                Button(role: .destructive) {
                    delete(Array(selection))
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .disabled(!isAdmin || selection.isEmpty)
                .accessibilityIdentifier("capture.delete")

                Spacer(minLength: 0)

                Text("\(selection.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(isSelecting ? "完了" : "選択") {
                isSelecting.toggle()
                if !isSelecting {
                    selection.removeAll()
                }
            }
            .accessibilityIdentifier("captures.select")

            Menu {
                ForEach(CaptureSortOrder.allCases, id: \.self) { value in
                    Button {
                        order = value
                    } label: {
                        if order == value {
                            Label(sortTitle(value), systemImage: "checkmark")
                        } else {
                            Text(sortTitle(value))
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("captures.sort")

            Menu {
                Button {
                    filters.isFavorite = filters.isFavorite == true ? nil : true
                } label: {
                    if filters.isFavorite == true {
                        Label("お気に入りのみ", systemImage: "checkmark")
                    } else {
                        Text("お気に入り")
                    }
                }
                .disabled(!isLoggedIn)

                Menu("タグ") {
                    ForEach(tags) { tag in
                        Button {
                            toggleFilterTag(tag.id)
                        } label: {
                            if filters.tagIDs.contains(tag.id) {
                                Label(tag.name, systemImage: "checkmark")
                            } else {
                                Text(tag.name)
                            }
                        }
                    }
                }
                .disabled(!isLoggedIn || tags.isEmpty)

                Menu("チャンネル") {
                    ForEach(channels) { channel in
                        Button {
                            toggleFilterChannel(channel.id)
                        } label: {
                            if filters.channelIDs.contains(channel.id) {
                                Label(channel.name, systemImage: "checkmark")
                            } else {
                                Text(channel.name)
                            }
                        }
                    }
                }
                .disabled(channels.isEmpty)

                Button {
                    filters.isCaptionComposited = filters.isCaptionComposited == true ? nil : true
                } label: {
                    if filters.isCaptionComposited == true {
                        Label("字幕付きのみ", systemImage: "checkmark")
                    } else {
                        Text("字幕付き")
                    }
                }

                Button {
                    filters.hasCaptionText = filters.hasCaptionText == true ? nil : true
                } label: {
                    if filters.hasCaptionText == true {
                        Label("字幕テキストあり", systemImage: "checkmark")
                    } else {
                        Text("字幕テキストあり")
                    }
                }

                Button {
                    filters.isCommentComposited = filters.isCommentComposited == true ? nil : true
                } label: {
                    if filters.isCommentComposited == true {
                        Label("コメント付きのみ", systemImage: "checkmark")
                    } else {
                        Text("コメント付き")
                    }
                }

                Button {
                    filters.hasMetadata = filters.hasMetadata == true ? nil : true
                } label: {
                    if filters.hasMetadata == true {
                        Label("番組情報ありのみ", systemImage: "checkmark")
                    } else {
                        Text("番組情報あり")
                    }
                }

                Divider()

                Button("絞り込みを解除") {
                    filters = CaptureFilters()
                }
                .disabled(filters == CaptureFilters())
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityIdentifier("captures.filter")
        }
    }

    // MARK: Data

    private var daySections: [DaySection] {
        var order: [String] = []
        var groups: [String: [Capture]] = [:]
        for capture in captures {
            let day = Self.dayString(capture.capturedAt)
            if groups[day] == nil {
                order.append(day)
            }
            groups[day, default: []].append(capture)
        }
        return order.map { DaySection(day: $0, captures: groups[$0] ?? []) }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy/M/d(E)"
        return formatter.string(from: date)
    }

    private func index(of capture: Capture) -> Int {
        captures.firstIndex(where: { $0.id == capture.id }) ?? 0
    }

    private func imageURL(for capture: Capture) -> URL? {
        model.client?.captureImageURL(for: capture)
    }

    private func sortTitle(_ order: CaptureSortOrder) -> String {
        switch order {
        case .capturedAtDesc: return "撮影日時の新しい順"
        case .capturedAtAsc: return "撮影日時の古い順"
        case .broadcastAtDesc: return "放送日時の新しい順"
        case .broadcastAtAsc: return "放送日時の古い順"
        case .playbackPosition: return "再生位置順"
        }
    }

    private func load(reset: Bool) async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }
        guard !isLoading else { return }
        if !reset, nextCursor == nil, !captures.isEmpty {
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await client.captures(
                filter: filters,
                order: order,
                cursor: reset ? nil : nextCursor,
                limit: 60
            )
            guard !Task.isCancelled else { return }
            if reset {
                captures = page.captures
            } else {
                let existing = Set(captures.map { $0.id })
                captures.append(contentsOf: page.captures.filter { !existing.contains($0.id) })
            }
            nextCursor = page.nextCursor
            for program in page.programs {
                programs[program.id] = program
            }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            if reset {
                captures = []
            }
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func loadFilters() async {
        guard let client = model.client else { return }
        if let channels = try? await client.captureChannels() {
            self.channels = channels
        }
        guard model.user != nil else {
            tags = []
            return
        }
        if let tags = try? await client.captureTags() {
            self.tags = tags
        }
    }

    // MARK: Selection

    private func toggleSelection(_ id: Int) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func toggleFilterTag(_ id: Int) {
        if let index = filters.tagIDs.firstIndex(of: id) {
            filters.tagIDs.remove(at: index)
        } else {
            filters.tagIDs.append(id)
        }
    }

    private func toggleFilterChannel(_ id: String) {
        if let index = filters.channelIDs.firstIndex(of: id) {
            filters.channelIDs.remove(at: index)
        } else {
            filters.channelIDs.append(id)
        }
    }

    // MARK: Actions

    private func favoriteButton(for ids: [Int], isFavorite: Bool) -> some View {
        Button {
            setFavorite(ids, isFavorite: !isFavorite)
        } label: {
            Label(
                isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                systemImage: isFavorite ? "heart.slash" : "heart"
            )
        }
        .disabled(!isLoggedIn)
    }

    private func favoriteSelection() {
        let ids = Array(selection)
        let allFavorite = captures
            .filter { selection.contains($0.id) }
            .allSatisfy { $0.isFavorite == true }
        setFavorite(ids, isFavorite: !allFavorite)
    }

    private func setFavorite(_ ids: [Int], isFavorite: Bool) {
        guard let client = model.client, !ids.isEmpty else { return }
        Task {
            do {
                if isFavorite {
                    try await client.addCaptureFavorites(ids: ids)
                } else {
                    try await client.removeCaptureFavorites(ids: ids)
                }
                for id in ids {
                    if let index = captures.firstIndex(where: { $0.id == id }) {
                        captures[index].isFavorite = isFavorite
                    }
                }
            } catch {
                actionMessage = ErrorText.message(for: error)
            }
        }
    }

    @ViewBuilder
    private func tagMenu(for ids: [Int]) -> some View {
        Menu {
            ForEach(tags) { tag in
                Button(tag.name) {
                    applyTag(tag, to: ids)
                }
            }
        } label: {
            Label("タグ", systemImage: "tag")
        }
        .disabled(!isLoggedIn || tags.isEmpty || ids.isEmpty)
    }

    private func applyTag(_ tag: CaptureTag, to ids: [Int]) {
        guard let client = model.client, !ids.isEmpty else { return }
        Task {
            do {
                try await client.addCaptureTagItems(tagID: tag.id, captureIDs: ids)
                for id in ids {
                    if let index = captures.firstIndex(where: { $0.id == id }) {
                        var tagIDs = captures[index].tagIDs ?? []
                        if !tagIDs.contains(tag.id) {
                            tagIDs.append(tag.id)
                        }
                        captures[index].tagIDs = tagIDs
                    }
                }
            } catch {
                actionMessage = ErrorText.message(for: error)
            }
        }
    }

    private func delete(_ ids: [Int]) {
        guard let client = model.client, !ids.isEmpty else { return }
        Task {
            do {
                let result = try await client.deleteCaptures(ids: ids)
                let deleted = Set(result.deletedCaptureIDs)
                captures.removeAll { deleted.contains($0.id) }
                selection.subtract(deleted)
                if !result.failedCaptureIDs.isEmpty {
                    actionMessage = "一部のキャプチャを削除できませんでした。"
                }
            } catch {
                actionMessage = ErrorText.message(for: error)
            }
        }
    }
}

// MARK: - Programs (albums)

/// キャプチャ → 番組: one album per broadcast episode that has captures.
struct CaptureProgramsScreen: View {
    let model: AppModel

    @State private var albums: [CaptureProgramAlbum] = []
    @State private var nextCursor: String?
    @State private var order: CaptureProgramSortOrder = .broadcastAtDesc
    @State private var query = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private struct LoadKey: Hashable {
        let order: CaptureProgramSortOrder
        let query: String
    }

    var body: some View {
        content
            .accessibilityIdentifier("captures.programs")
            .searchable(text: $query, prompt: "番組名・チャンネル名")
            .task(id: LoadKey(order: order, query: query)) {
                await load(reset: true)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(CaptureProgramSortOrder.allCases, id: \.self) { value in
                            Button {
                                order = value
                            } label: {
                                if order == value {
                                    Label(title(value), systemImage: "checkmark")
                                } else {
                                    Text(title(value))
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityIdentifier("captures.programs.sort")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if albums.isEmpty, isLoading {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, albums.isEmpty {
            ContentUnavailableView {
                Label("番組を取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再試行") {
                    Task { await load(reset: true) }
                }
            }
        } else if albums.isEmpty {
            ContentUnavailableView("キャプチャのある番組はありません", systemImage: "rectangle.stack")
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(albums, id: \.id) { album in
                        NavigationLink(value: SectionRoute.captureProgram(album.id)) {
                            albumCell(album)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("captures.program.\(album.id)")
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)

                if nextCursor != nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await load(reset: false) }
                }
            }
        }
    }

    private func albumCell(_ album: CaptureProgramAlbum) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CaptureThumbnail(
                url: model.client?.captureImageURL(for: album.coverCapture),
                isFavorite: false,
                isCaptionComposited: false,
                isCommentComposited: false
            )
            Text(album.program.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if let channel = album.program.channel {
                    Text(channel.name)
                }
                Text(Formatters.date(album.program.startTime))
                Spacer(minLength: 0)
                Label("\(album.captureCount)", systemImage: "photo.on.rectangle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func title(_ order: CaptureProgramSortOrder) -> String {
        switch order {
        case .broadcastAtDesc: return "放送日時の新しい順"
        case .broadcastAtAsc: return "放送日時の古い順"
        }
    }

    private func load(reset: Bool) async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }
        guard !isLoading else { return }
        if !reset, nextCursor == nil, !albums.isEmpty {
            return
        }
        isLoading = true
        defer { isLoading = false }

        let keywords = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let page = try await client.capturePrograms(
                cursor: reset ? nil : nextCursor,
                limit: 60,
                query: keywords.isEmpty ? nil : keywords,
                order: order
            )
            guard !Task.isCancelled else { return }
            if reset {
                albums = page.programs
            } else {
                let existing = Set(albums.map { $0.id })
                albums.append(contentsOf: page.programs.filter { !existing.contains($0.id) })
            }
            nextCursor = page.nextCursor
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            if reset {
                albums = []
            }
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// One album: the captures of a broadcast episode.
struct CaptureProgramScreen: View {
    let model: AppModel
    let programID: Int

    @State private var album: CaptureProgramAlbum?
    @State private var captures: [Capture] = []
    @State private var recordedVideo: RecordedProgram?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var viewerTarget: CaptureViewerTarget?

    var body: some View {
        Group {
            if captures.isEmpty, isLoading {
                ProgressView("読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, captures.isEmpty {
                ContentUnavailableView {
                    Label("番組を取得できませんでした", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(captures) { capture in
                                Button {
                                    viewerTarget = CaptureViewerTarget(
                                        id: captures.firstIndex(where: { $0.id == capture.id }) ?? 0
                                    )
                                } label: {
                                    CaptureThumbnail(
                                        url: model.client?.captureImageURL(for: capture),
                                        isFavorite: capture.isFavorite == true,
                                        isCaptionComposited: capture.isCaptionComposited,
                                        isCommentComposited: capture.isCommentComposited
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("captures.item.\(capture.id)")
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle(album?.program.title ?? "番組")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $viewerTarget) { target in
            CaptureViewer(
                model: model,
                initialCaptures: captures,
                programs: [:],
                initialIndex: target.id,
                onCaptureChanged: { updated in
                    if let index = captures.firstIndex(where: { $0.id == updated.id }) {
                        captures[index] = updated
                    }
                },
                onCapturesDeleted: { ids in
                    let deleted = Set(ids)
                    captures.removeAll { deleted.contains($0.id) }
                }
            )
        }
    }

    @ViewBuilder
    private var header: some View {
        if let album {
            VStack(alignment: .leading, spacing: 6) {
                Text(album.program.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let channel = album.program.channel {
                        Text(channel.name)
                    }
                    Text(Formatters.dateTime(album.program.startTime))
                    Label("\(album.captureCount)", systemImage: "photo.on.rectangle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let recordedVideo {
                    NavigationLink(value: SectionRoute.video(recordedVideo)) {
                        Label("録画番組を開く", systemImage: "play.rectangle")
                            .font(.subheadline)
                    }
                    .accessibilityIdentifier("captures.program.video")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }
        isLoading = captures.isEmpty
        defer { isLoading = false }
        do {
            let loaded = try await client.captureProgram(id: programID)
            guard !Task.isCancelled else { return }
            album = loaded
            let page = try await client.captures(
                filter: CaptureFilters(captureProgramID: programID),
                order: .playbackPosition,
                limit: 200
            )
            guard !Task.isCancelled else { return }
            captures = page.captures
            errorMessage = nil

            if let videoID = loaded.program.recordedProgramIDs.first {
                recordedVideo = try? await client.video(id: videoID)
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - Tags

/// キャプチャ → タグ: create, rename and delete the viewer's tags.
struct CaptureTagsScreen: View {
    let model: AppModel

    @State private var tags: [CaptureTag] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showsCreateSheet = false
    @State private var editingTag: CaptureTag?
    @State private var newTagName = ""
    @State private var renameText = ""

    private var isLoggedIn: Bool { model.user != nil }

    var body: some View {
        Group {
            if !isLoggedIn {
                ContentUnavailableView {
                    Label("ログインが必要です", systemImage: "person.crop.circle")
                } description: {
                    Text("タグの作成・変更・削除にはログインが必要です。")
                }
            } else if tags.isEmpty, isLoading {
                ProgressView("読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tags.isEmpty {
                ContentUnavailableView("タグはありません", systemImage: "tag")
            } else {
                List {
                    ForEach(tags) { tag in
                        Button {
                            renameText = tag.name
                            editingTag = tag
                        } label: {
                            HStack {
                                Text(tag.name)
                                Spacer(minLength: 0)
                                Text("\(tag.captureCount)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("captures.tag.\(tag.id)")
                        .swipeActions {
                            Button(role: .destructive) {
                                delete(tag)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }
                }
                .accessibilityIdentifier("captures.tags")
            }
        }
        .task(id: isLoggedIn) { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newTagName = ""
                    showsCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!isLoggedIn)
                .accessibilityIdentifier("captures.tag.create")
            }
        }
        .alert("タグを作成", isPresented: $showsCreateSheet) {
            TextField("タグ名", text: $newTagName)
                .accessibilityIdentifier("captures.tag.name")
            Button("作成") { create() }
            Button("キャンセル", role: .cancel) {}
        }
        .alert(
            "タグ名を変更",
            isPresented: Binding(
                get: { editingTag != nil },
                set: { if !$0 { editingTag = nil } }
            )
        ) {
            TextField("タグ名", text: $renameText)
            Button("変更") { rename() }
            Button("キャンセル", role: .cancel) { editingTag = nil }
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        guard let client = model.client, model.user != nil else {
            tags = []
            return
        }
        isLoading = tags.isEmpty
        defer { isLoading = false }
        do {
            tags = try await client.captureTags()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func create() {
        guard let client = model.client else { return }
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                let tag = try await client.createCaptureTag(name: name)
                tags.append(tag)
                tags.sort { $0.name < $1.name }
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }

    private func rename() {
        guard let client = model.client, let tag = editingTag else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTag = nil
        guard !name.isEmpty else { return }
        Task {
            do {
                let updated = try await client.renameCaptureTag(id: tag.id, name: name)
                if let index = tags.firstIndex(where: { $0.id == updated.id }) {
                    tags[index] = updated
                }
                tags.sort { $0.name < $1.name }
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }

    private func delete(_ tag: CaptureTag) {
        guard let client = model.client else { return }
        Task {
            do {
                try await client.deleteCaptureTag(id: tag.id)
                tags.removeAll { $0.id == tag.id }
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}

// MARK: - Viewer

/// Full-screen paged viewer of a capture selection.
struct CaptureViewer: View {
    let model: AppModel
    let initialCaptures: [Capture]
    let programs: [Int: CaptureProgram]
    let initialIndex: Int
    let onCaptureChanged: (Capture) -> Void
    let onCapturesDeleted: ([Int]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var items: [Capture] = []
    @State private var index = 0
    @State private var tags: [CaptureTag] = []
    @State private var shares: [Int: URL] = [:]
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showsDeleteConfirmation = false

    private var isLoggedIn: Bool { model.user != nil }
    private var isAdmin: Bool { model.user?.isAdmin == true }

    private var capture: Capture? {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if items.isEmpty {
                    ProgressView()
                        .tint(.white)
                } else {
                    TabView(selection: $index) {
                        ForEach(Array(items.indices), id: \.self) { position in
                            page(items[position])
                                .tag(position)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .navigationTitle(capture.map { Formatters.dateTime($0.capturedAt) } ?? "キャプチャ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                    .accessibilityIdentifier("capture.viewer.close")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    favoriteButton
                    tagMenu
                    shareButton
                    if isAdmin {
                        deleteButton
                    }
                }
            }
            .accessibilityIdentifier("capture.viewer")
        }
        .onAppear {
            if items.isEmpty {
                items = initialCaptures
                index = min(max(initialIndex, 0), max(initialCaptures.count - 1, 0))
            }
        }
        .task { await loadTags() }
        .task(id: capture?.id) { await loadShareFile() }
        .confirmationDialog(
            "本当にキャプチャを削除しますか？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                deleteCurrent()
            }
            .accessibilityIdentifier("capture.delete.confirm")
            Button("キャンセル", role: .cancel) {}
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Page

    @ViewBuilder
    private func page(_ capture: Capture) -> some View {
        VStack(spacing: 0) {
            AsyncImage(url: model.client?.captureImageURL(for: capture)) { phase in
                ZStack {
                    Color.black
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else if phase.error != nil {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let program = program(for: capture) {
                        Text(program.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        HStack(spacing: 8) {
                            if let channel = program.channel {
                                Text(channel.name)
                            }
                            Text(Formatters.dateTime(program.startTime))
                            if let position = capture.playbackPosition {
                                Text(Formatters.offset(position))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    }

                    if let text = capture.captionText, !text.isEmpty {
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(details(capture))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 160)
            .background(Color.black.opacity(0.9))
        }
    }

    private func program(for capture: Capture) -> CaptureProgram? {
        guard let id = capture.captureProgramID else { return nil }
        return programs[id]
    }

    private func details(_ capture: Capture) -> String {
        var parts = ["\(capture.imageWidth)×\(capture.imageHeight)"]
        parts.append(Formatters.bytes(capture.fileSize))
        if capture.isCaptionComposited {
            parts.append("字幕合成あり")
        }
        if capture.isCommentComposited {
            parts.append("コメント合成あり")
        }
        let tagNames = (capture.tagIDs ?? []).compactMap { id in
            tags.first { $0.id == id }?.name
        }
        if !tagNames.isEmpty {
            parts.append(tagNames.joined(separator: "・"))
        }
        return parts.joined(separator: " ・ ")
    }

    // MARK: Toolbar

    private var favoriteButton: some View {
        Button {
            toggleFavorite()
        } label: {
            Image(systemName: capture?.isFavorite == true ? "heart.fill" : "heart")
        }
        .disabled(!isLoggedIn || capture == nil || isWorking)
        .accessibilityIdentifier("capture.favorite")
        .accessibilityLabel("お気に入り")
        .accessibilityValue(capture?.isFavorite == true ? "true" : "false")
    }

    private var tagMenu: some View {
        Menu {
            ForEach(tags) { tag in
                Button {
                    toggleTag(tag)
                } label: {
                    if (capture?.tagIDs ?? []).contains(tag.id) {
                        Label(tag.name, systemImage: "checkmark")
                    } else {
                        Text(tag.name)
                    }
                }
            }
        } label: {
            Image(systemName: "tag")
        }
        .disabled(!isLoggedIn || capture == nil || tags.isEmpty)
        .accessibilityIdentifier("capture.tag.add")
        .accessibilityLabel("タグ")
    }

    @ViewBuilder
    private var shareButton: some View {
        if let capture, let file = shares[capture.id] {
            ShareLink(item: file) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityIdentifier("capture.share")
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showsDeleteConfirmation = true
        } label: {
            Image(systemName: "trash")
        }
        .disabled(capture == nil)
        .accessibilityIdentifier("capture.delete")
        .accessibilityLabel("削除")
    }

    // MARK: Data

    private func loadTags() async {
        guard let client = model.client, model.user != nil else { return }
        tags = (try? await client.captureTags()) ?? []
    }

    /// Downloads the image so ShareLink can share the original file.
    private func loadShareFile() async {
        guard let capture, let url = model.client?.captureImageURL(for: capture) else { return }
        if shares[capture.id] != nil { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Capture_\(capture.id).jpg")
        guard (try? data.write(to: file)) != nil else { return }
        shares[capture.id] = file
    }

    // MARK: Actions

    private func mutate(_ body: (inout Capture) -> Void) {
        guard items.indices.contains(index) else { return }
        body(&items[index])
        onCaptureChanged(items[index])
    }

    private func toggleFavorite() {
        guard let client = model.client, let capture, !isWorking else { return }
        let next = capture.isFavorite != true
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                if next {
                    try await client.addCaptureFavorites(ids: [capture.id])
                } else {
                    try await client.removeCaptureFavorites(ids: [capture.id])
                }
                mutate { $0.isFavorite = next }
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }

    private func toggleTag(_ tag: CaptureTag) {
        guard let client = model.client, let capture, !isWorking else { return }
        let hasTag = (capture.tagIDs ?? []).contains(tag.id)
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                if hasTag {
                    try await client.removeCaptureTagItems(tagID: tag.id, captureIDs: [capture.id])
                } else {
                    try await client.addCaptureTagItems(tagID: tag.id, captureIDs: [capture.id])
                }
                mutate { item in
                    var tagIDs = item.tagIDs ?? []
                    if hasTag {
                        tagIDs.removeAll { $0 == tag.id }
                    } else if !tagIDs.contains(tag.id) {
                        tagIDs.append(tag.id)
                    }
                    item.tagIDs = tagIDs
                }
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }

    private func deleteCurrent() {
        guard let client = model.client, let capture else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let result = try await client.deleteCaptures(ids: [capture.id])
                guard result.deletedCaptureIDs.contains(capture.id) else {
                    errorMessage = "キャプチャを削除できませんでした。"
                    return
                }
                onCapturesDeleted(result.deletedCaptureIDs)
                items.removeAll { $0.id == capture.id }
                if items.isEmpty {
                    dismiss()
                    return
                }
                index = min(index, items.count - 1)
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}
