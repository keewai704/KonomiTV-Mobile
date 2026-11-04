import SwiftUI
import KonomiKit

/// ビデオ: the full recorded program grid with sort order, paging and search.
struct VideoListView: View {
    let model: AppModel

    /// Sort order menu of the grid (新しい順 / 古い順).
    enum SortOrder: String, CaseIterable, Hashable, Sendable {
        case newest
        case oldest

        var title: String {
            switch self {
            case .newest: return "新しい順"
            case .oldest: return "古い順"
            }
        }

        var order: VideoListOrder {
            switch self {
            case .newest: return .desc
            case .oldest: return .asc
            }
        }
    }

    @State private var items: [RecordedProgram] = []
    @State private var total = 0
    @State private var page = 0
    @State private var order: SortOrder = .newest
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var appliedQuery = ""

    var body: some View {
        content
            .navigationTitle("録画番組")
            .adaptiveSearchable(text: $query, prompt: "ビデオを検索")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
            .task(id: query) {
                await handleQueryChange()
            }
            .onChange(of: order) { _, _ in
                Task { await reload() }
            }
    }

    // MARK: - Views

    private var sortMenu: some View {
        Menu {
            Picker("並び順", selection: $order) {
                ForEach(SortOrder.allCases, id: \.self) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
        } label: {
            Label(order.title, systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("videos.sort")
    }

    @ViewBuilder
    private var content: some View {
        if !items.isEmpty {
            grid
        } else if isLoading {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("ビデオを取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再試行") {
                    Task { await reload() }
                }
            }
        } else if !appliedQuery.isEmpty {
            ContentUnavailableView.search(text: appliedQuery)
        } else {
            ContentUnavailableView("ビデオがありません", systemImage: "film.stack")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(items) { video in
                    NavigationLink(value: SectionRoute.video(video)) {
                        VideoCard(
                            video: video,
                            thumbnailURL: model.client?.thumbnailURL(videoID: video.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("videos.item.\(video.id)")
                    .onAppear { loadMoreIfNeeded(after: video) }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)

            if isLoadingMore {
                ProgressView()
                    .padding(.vertical, 20)
            }
        }
        .accessibilityIdentifier("videos.grid")
        .refreshable { await reload() }
    }

    // MARK: - Search

    private func handleQueryChange() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Debounce typing so the API is not queried on every keystroke.
        if !trimmed.isEmpty {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
        }

        if trimmed == appliedQuery && !items.isEmpty { return }
        appliedQuery = trimmed
        await reload()
    }

    // MARK: - Loading

    private func fetch(page: Int, client: APIClient) async throws -> RecordedPrograms {
        if appliedQuery.isEmpty {
            return try await client.videos(page: page, order: order.order)
        }
        return try await client.searchVideos(query: appliedQuery, page: page, order: order.order)
    }

    private func reload() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        isLoading = items.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await fetch(page: 1, client: client)
            guard !Task.isCancelled else { return }
            items = result.recordedPrograms.filter { !model.isVideoDeleted(id: $0.id) }
            total = result.total
            page = 1
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func loadMoreIfNeeded(after video: RecordedProgram) {
        guard video.id == items.last?.id else { return }
        guard !isLoading, !isLoadingMore, items.count < total else { return }
        guard let client = model.client else { return }

        isLoadingMore = true
        let requestedQuery = appliedQuery
        Task {
            defer { isLoadingMore = false }
            do {
                let nextPage = page + 1
                let result = try await fetch(page: nextPage, client: client)
                // Drop a page that belongs to a search the user has replaced.
                guard !Task.isCancelled, requestedQuery == appliedQuery else { return }
                let known = Set(items.map(\.id))
                items.append(
                    contentsOf: result.recordedPrograms.filter { !known.contains($0.id) }
                )
                total = result.total
                page = nextPage
            } catch {
                // Paging failures keep the already loaded items; the user can
                // pull to refresh to retry.
            }
        }
    }
}
